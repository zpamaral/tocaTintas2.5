// bs2b_bridge (variante CamillaDSP) — versão corrigida
//
// /usr/local/bin/clang -O3 -march=native -mtune=native bs2b_bridge3.c -o bs2b_bridge3
//
// Correcções face ao bs2b_bridge2:
//   1) chunksize 1024 -> 128. O «chunksize» domina o atraso da ponte: medido em
//      ida-e-volta pelo BlackHole, 1024 dá 69 ms contra 35 ms do bs2b_bridge
//      original (PortAudio, 512 «frames»). Como o dispositivo de saída múltipla
//      («tocaTintas auriculares») manda o som seco directamente para os
//      auscultadores E para o BlackHole, ouvem-se as duas cópias: com 35 ms o
//      atraso ainda funde (efeito de precedência), com 69 ms passa a eco
//      separado. Com 128 a ida-e-volta é 37,9 ms, igual à do original.
//   2) Compensação de ganho. O libbs2b atenua a saída para não saturar quando
//      soma os dois ramos; a cadeia CamillaDSP não o fazia e ficava 1,1 a
//      1,8 dB acima (medido por resposta ao impulso). Agora atenua o mesmo.
//
// Invólucro que reproduz o comportamento do bs2b_bridge original mas delega
// todo o processamento de áudio no CamillaDSP. Mantém EXACTAMENTE a mesma
// interface de linha de comandos, para poder ser chamado pelo programa de
// música sem qualquer alteração. Basta renomear o bs2b_bridge antigo e
// instalar este com o mesmo nome para experimentar; para reverter, renomeia-se
// de volta.
//
// Uso (idêntico ao original):
//   ./bs2b_bridge
//   ./bs2b_bridge --perfil default
//   ./bs2b_bridge --perfil cmoy
//   ./bs2b_bridge --perfil jmeier
//   ./bs2b_bridge --perfil=cmoy
//   ./bs2b_bridge --silencioso
//   ./bs2b_bridge --ajuda
//
// Extra (não interfere com o original, é só para inspecção):
//   ./bs2b_bridge --perfil cmoy --mostrar-config   (escreve o YAML e sai)
//
// Em vez de abrir o áudio com PortAudio + libbs2b, este programa:
//   1) escolhe o nível de crossfeed equivalente ao perfil bs2b pedido;
//   2) escreve um ficheiro de configuração YAML temporário para o CamillaDSP;
//   3) lança o CamillaDSP (CoreAudio) a capturar do BlackHole e a tocar nos
//      auriculares, com o crossfeed aplicado;
//   4) reenvia os sinais de paragem ao CamillaDSP e apaga o ficheiro
//      temporário à saída.
//
// Não depende de PortAudio nem de libbs2b. Compila sem bibliotecas externas:
//   cc -O2 -Wall -Wextra -o bs2b_bridge bs2b_bridge_camilla.c
//
// Equivalência perfil bs2b -> nível de crossfeed. Os coeficientes são os do
// projecto camilladsp-crossfeed (níveis cx4, cx3, cx2), validados por resposta
// em frequência contra o bs2b/RME ADI-2:
//   default -> 700 Hz / 4,5 dB
//   cmoy    -> 700 Hz / 6,0 dB
//   jmeier  -> 650 Hz / 9,5 dB   (perfil pré-definido, como no original)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <sys/types.h>
#include <sys/wait.h>

// --------------------------------------------------------------------------
// Parâmetros ajustáveis
// --------------------------------------------------------------------------

// Executável CamillaDSP. Caminho absoluto de propósito: quando o programa de
// música o lança (tanto a cópia em /usr/local/bin como a embutida na .app), o
// PATH herdado pode não incluir /usr/local/bin. CAMILLADSP_BIN sobrepõe-no.
#define CAMILLADSP_BIN_DEFAULT  "/usr/local/bin/camilladsp"

// Nomes EXACTOS dos dispositivos CoreAudio. Atenção: ao contrário do PortAudio
// do original, o CamillaDSP NÃO faz correspondência por substring; o nome tem
// de ser exacto. Para os listar:  system_profiler SPAudioDataType
#define IN_DEV_NAME   "BlackHole 2ch"           // captura (loopback do sistema)
#define OUT_DEV_NAME  "Auscultadores externos"  // saída: auriculares Sony

#define SAMPLE_RATE   44100
#define CHUNK_SIZE    128     // atraso da ponte ~= chunksize; ver nota no topo
#define SAMPLE_FORMAT "F32"   // o que o binario 4.1.3 aceita (S16/S24/S32/F32).
                              // NB: a documentacao do 4.1.3 diz "F32_LE" e mente;
                              // v3 chamava-lhe "FLOAT32LE".

// --------------------------------------------------------------------------

typedef struct {
    const char *nome;       // identificador do perfil (igual ao bs2b)
    const char *descricao;  // fcut / feed equivalentes (para mensagens)
    double hi_freq;         // Lowshelf: frequência central (Hz)
    double hi_gain;         // Lowshelf: ganho (dB)
    double lo_freq;         // LowpassFO: frequência de corte (Hz)
    double lo_gain;         // ganho do ramo de crossfeed (dB)
    double comp_gain;       // atenuação final, como a do libbs2b (dB)
} Perfil;

// Níveis cx4 / cx3 / cx2 do projecto camilladsp-crossfeed.
// A última coluna é a atenuação que o libbs2b aplica à saída e que faltava
// aqui: medida por comparação das respostas ao impulso das duas cadeias.
static const Perfil PERFIS[] = {
    { "default", "700 Hz / 4,5 dB", 873.89, -2.25, 700.0,  -6.75, -1.81 },
    { "cmoy",    "700 Hz / 6,0 dB", 868.97, -2.00, 700.0,  -8.00, -1.53 },
    { "jmeier",  "650 Hz / 9,5 dB", 824.70, -1.40, 650.0, -10.92, -1.11 },
};
#define NUM_PERFIS ((int)(sizeof(PERFIS) / sizeof(PERFIS[0])))

static int g_silencioso = 0;
static volatile pid_t g_filho = -1;     // pid do CamillaDSP, para o «callback» de sinais
static char g_cfg[64] = {0};            // caminho do ficheiro temporário

#define LOGF(...) do { if (!g_silencioso) printf(__VA_ARGS__); } while (0)

static void imprimir_uso(const char *nome_prog) {
    fprintf(stderr,
        "Uso: %s [--perfil default|cmoy|jmeier] [--silencioso] [--mostrar-config]\n"
        "       %s --ajuda\n\n"
        "Opções:\n"
        "  --perfil P       Onde P pertence a {default, cmoy, jmeier}\n"
        "  --silencioso     Não escrever mensagens em stdout (apenas erros)\n"
        "  --mostrar-config Escrever o YAML gerado em stdout e sair (sem tocar)\n\n"
        "Perfis (equivalentes bs2b, via CamillaDSP):\n"
        "  default  -> 700 Hz / 4,5 dB\n"
        "  cmoy     -> 700 Hz / 6,0 dB\n"
        "  jmeier   -> 650 Hz / 9,5 dB   (pré-definido)\n\n"
        "Ambiente:\n"
        "  CAMILLADSP_BIN   Caminho do executável CamillaDSP\n"
        "                   (pré-definido: %s)\n",
        nome_prog, nome_prog, CAMILLADSP_BIN_DEFAULT);
}

static const Perfil *escolher_perfil(const char *nome) {
    if (!nome) return NULL;
    for (int i = 0; i < NUM_PERFIS; ++i)
        if (strcmp(nome, PERFIS[i].nome) == 0)
            return &PERFIS[i];
    return NULL;
}

// Escreve a configuração completa do CamillaDSP (v3) no fluxo dado.
//
// Topologia (modelo bs2b): expande 2 -> 4 canais; o ramo directo recebe um
// Lowshelf de compensação; o ramo de crossfeed recebe um passa-baixo de 1.ª
// ordem mais atenuação; depois recombina 4 -> 2 cruzando o ramo passa-baixo de
// cada canal para a saída oposta.
//   canal 0: L directo   (xfeed_hi)
//   canal 1: L -> cruza para R   (xfeed_lo + xfeed_lo_gain)
//   canal 2: R -> cruza para L   (xfeed_lo + xfeed_lo_gain)
//   canal 3: R directo   (xfeed_hi)
// No fim, «comp» repõe a mesma margem de saturação que o libbs2b usa.
static void gerar_config(FILE *f, const Perfil *p) {
    fprintf(f,
        "title: \"bs2b_bridge (perfil %s)\"\n"
        "\n"
        "devices:\n"
        "  samplerate: %d\n"
        "  chunksize: %d\n"
        "  capture:\n"
        "    type: CoreAudio\n"
        "    channels: 2\n"
        "    device: \"%s\"\n"
        "    format: %s\n"
        "  playback:\n"
        "    type: CoreAudio\n"
        "    channels: 2\n"
        "    device: \"%s\"\n"
        "    format: %s\n"
        "\n"
        "filters:\n"
        "  xfeed_hi:\n"
        "    type: Biquad\n"
        "    parameters:\n"
        "      type: Lowshelf\n"
        "      freq: %g\n"
        "      gain: %g\n"
        "      q: 0.5\n"
        "  xfeed_lo:\n"
        "    type: Biquad\n"
        "    parameters:\n"
        "      type: LowpassFO\n"
        "      freq: %g\n"
        "  xfeed_lo_gain:\n"
        "    type: Gain\n"
        "    parameters:\n"
        "      gain: %g\n"
        "      scale: dB\n"
        "  comp:\n"
        "    type: Gain\n"
        "    parameters:\n"
        "      gain: %g\n"
        "      scale: dB\n"
        "\n"
        "mixers:\n"
        "  2to4:\n"
        "    channels:\n"
        "      in: 2\n"
        "      out: 4\n"
        "    mapping:\n"
        "      - dest: 0\n"
        "        sources:\n"
        "          - channel: 0\n"
        "      - dest: 1\n"
        "        sources:\n"
        "          - channel: 0\n"
        "      - dest: 2\n"
        "        sources:\n"
        "          - channel: 1\n"
        "      - dest: 3\n"
        "        sources:\n"
        "          - channel: 1\n"
        "  4to2:\n"
        "    channels:\n"
        "      in: 4\n"
        "      out: 2\n"
        "    mapping:\n"
        "      - dest: 0\n"
        "        sources:\n"
        "          - channel: 0\n"
        "          - channel: 2\n"
        "      - dest: 1\n"
        "        sources:\n"
        "          - channel: 1\n"
        "          - channel: 3\n"
        "\n"
        "pipeline:\n"
        "  - type: Mixer\n"
        "    name: 2to4\n"
        "  - type: Filter\n"
        "    channels: [0]\n"
        "    names:\n"
        "      - xfeed_hi\n"
        "  - type: Filter\n"
        "    channels: [1]\n"
        "    names:\n"
        "      - xfeed_lo\n"
        "      - xfeed_lo_gain\n"
        "  - type: Filter\n"
        "    channels: [2]\n"
        "    names:\n"
        "      - xfeed_lo\n"
        "      - xfeed_lo_gain\n"
        "  - type: Filter\n"
        "    channels: [3]\n"
        "    names:\n"
        "      - xfeed_hi\n"
        "  - type: Mixer\n"
        "    name: 4to2\n"
        "  - type: Filter\n"
        "    channels: [0, 1]\n"
        "    names:\n"
        "      - comp\n",
        p->nome,
        SAMPLE_RATE, CHUNK_SIZE,
        IN_DEV_NAME, SAMPLE_FORMAT,
        OUT_DEV_NAME, SAMPLE_FORMAT,
        p->hi_freq, p->hi_gain,
        p->lo_freq,
        p->lo_gain,
        p->comp_gain);
}

// Reenvia o sinal de paragem ao CamillaDSP. O filho corre no seu próprio grupo
// de processos (ver fork), por isso recebe o sinal uma única vez, venha o
// Ctrl+C do terminal ou um SIGTERM enviado pelo programa de música.
static void reencaminhar_sinal(int sig) {
    if (g_filho > 0)
        kill(g_filho, sig);
}

int main(int argc, char *argv[]) {
    const Perfil *perfil = escolher_perfil("jmeier");  // pré-definido, como no original
    int mostrar_config = 0;

    // --------------------------------------------------
    // 0) Leitura dos argumentos (mesma gramática do original)
    // --------------------------------------------------
    for (int i = 1; i < argc; ++i) {
        const char *arg = argv[i];

        if (strcmp(arg, "--ajuda") == 0 || strcmp(arg, "-h") == 0) {
            imprimir_uso(argv[0]);
            return 0;
        }
        if (strcmp(arg, "--silencioso") == 0 || strcmp(arg, "--quiet") == 0) {
            g_silencioso = 1;
            continue;
        }
        if (strcmp(arg, "--mostrar-config") == 0) {
            mostrar_config = 1;
            continue;
        }
        if (strncmp(arg, "--perfil=", 9) == 0) {
            const char *valor = arg + 9;
            if (*valor == '\0') {
                fprintf(stderr, "Erro: --perfil= precisa de um valor.\n\n");
                imprimir_uso(argv[0]);
                return 1;
            }
            perfil = escolher_perfil(valor);
            if (!perfil) {
                fprintf(stderr, "Erro: perfil desconhecido \"%s\".\n\n", valor);
                imprimir_uso(argv[0]);
                return 1;
            }
            continue;
        }
        if (strcmp(arg, "--perfil") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Erro: --perfil precisa de um valor.\n\n");
                imprimir_uso(argv[0]);
                return 1;
            }
            const char *valor = argv[++i];
            perfil = escolher_perfil(valor);
            if (!perfil) {
                fprintf(stderr, "Erro: perfil desconhecido \"%s\".\n\n", valor);
                imprimir_uso(argv[0]);
                return 1;
            }
            continue;
        }
        fprintf(stderr, "Aviso: argumento ignorado: %s\n", arg);
    }

    // --------------------------------------------------
    // 1) Modo de inspecção: só escreve o YAML e sai
    // --------------------------------------------------
    if (mostrar_config) {
        gerar_config(stdout, perfil);
        return 0;
    }

    // --------------------------------------------------
    // 2) Localizar o executável CamillaDSP
    // --------------------------------------------------
    const char *bin = getenv("CAMILLADSP_BIN");
    if (!bin || *bin == '\0')
        bin = CAMILLADSP_BIN_DEFAULT;

    if (strchr(bin, '/') != NULL && access(bin, X_OK) != 0) {
        fprintf(stderr, "Erro: CamillaDSP não executável em \"%s\": %s\n",
                bin, strerror(errno));
        fprintf(stderr, "Instala-o em %s ou define CAMILLADSP_BIN.\n", CAMILLADSP_BIN_DEFAULT);
        return 1;
    }

    // --------------------------------------------------
    // 3) Escrever a configuração num ficheiro temporário
    // --------------------------------------------------
    // YAML gerado para um ficheiro temporário a cada arranque e descartado à
    // saída. Não fica nada ao lado do binário, logo serve as duas cópias igual.
    strcpy(g_cfg, "/tmp/bs2b_camilla_XXXXXX");
    int fd = mkstemp(g_cfg);
    if (fd < 0) {
        fprintf(stderr, "Erro a criar ficheiro temporário: %s\n", strerror(errno));
        return 1;
    }
    FILE *f = fdopen(fd, "w");
    if (!f) {
        fprintf(stderr, "Erro a abrir ficheiro temporário: %s\n", strerror(errno));
        close(fd);
        unlink(g_cfg);
        return 1;
    }
    gerar_config(f, perfil);
    if (fclose(f) != 0) {
        fprintf(stderr, "Erro a escrever configuração: %s\n", strerror(errno));
        unlink(g_cfg);
        return 1;
    }

    LOGF("Entrada : «%s»\n", IN_DEV_NAME);
    LOGF("Saída   : «%s»\n", OUT_DEV_NAME);
    LOGF("Frequência: %d Hz\n", SAMPLE_RATE);
    LOGF("Perfil bs2b: %s (%s)\n", perfil->nome, perfil->descricao);
    LOGF("Configuração: %s\n\n", g_cfg);

    // --------------------------------------------------
    // 4) Lançar o CamillaDSP
    // --------------------------------------------------
    // Em silêncio, abafa o registo do CamillaDSP até ao nível de erro; caso
    // contrário mostra avisos e erros (mas não o «info» verboso de arranque).
    const char *nivel = g_silencioso ? "error" : "warn";
    char *const cd_argv[] = {
        (char *)bin,
        (char *)"-l", (char *)nivel,
        g_cfg,
        NULL
    };

    // Apanha os sinais de paragem para os reencaminhar e poder limpar.
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = reencaminhar_sinal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    sigaction(SIGINT,  &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGHUP,  &sa, NULL);

    pid_t pid = fork();
    if (pid < 0) {
        fprintf(stderr, "Erro em fork: %s\n", strerror(errno));
        unlink(g_cfg);
        return 1;
    }

    if (pid == 0) {
        // Filho: isola-se num grupo de processos próprio para receber o sinal
        // de paragem só do pai, e substitui-se pelo CamillaDSP.
        setpgid(0, 0);
        execvp(bin, cd_argv);
        // Só chega aqui se o exec falhar.
        fprintf(stderr, "Erro a executar CamillaDSP (\"%s\"): %s\n",
                bin, strerror(errno));
        _exit(127);
    }

    // Pai: espera pelo CamillaDSP, depois apaga a configuração temporária.
    g_filho = pid;

    LOGF("A correr perfil «%s» via CamillaDSP. Ctrl+C para sair.\n", perfil->nome);

    int status = 0;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            fprintf(stderr, "Erro em waitpid: %s\n", strerror(errno));
            break;
        }
    }

    unlink(g_cfg);

    if (WIFEXITED(status))
        return WEXITSTATUS(status);
    if (WIFSIGNALED(status))
        return 128 + WTERMSIG(status);
    return 0;
}
