// bs2b_bridge (variante CamillaDSP) — versão corrigida
//
// /usr/local/bin/clang -O3 -march=native -mtune=native bs2b_bridge3.c -o bs2b_bridge3
//
// Correcções face ao bs2b_bridge2:
//   1) chunksize. Esteve em 1024, desceu a 128 e voltou a 1024 — a razão da
//      descida deixou de existir. O «chunksize» domina o atraso da ponte:
//      medido em ida-e-volta pelo BlackHole, 1024 dá 69 ms contra 37,9 ms com
//      128. Enquanto a saída do macOS era o dispositivo de saída múltipla
//      («tocaTintas auriculares»), que manda o som seco directamente para os
//      auscultadores E para o BlackHole, ouviam-se as duas cópias e o atraso
//      tinha de ficar abaixo dos 40 ms para o efeito de precedência as fundir.
//      Com a saída do macOS no BlackHole directo não há cópia seca nenhuma com
//      que alinhar, e o atraso deixa de importar: só o vê quem carrega em tocar
//      e espera 69 ms pelo primeiro som. Em troca, 1024 são 23 ms de trabalho
//      por bloco em vez de 2,9 ms — margem que este processo, que corre sem
//      prioridade de tempo real, precisa para não perder blocos. Um bloco
//      perdido é um estalido.
//   2) Compensação de ganho. O libbs2b atenua a saída para não saturar quando
//      soma os dois ramos; a cadeia CamillaDSP não o fazia e ficava 1,1 a
//      1,8 dB acima (medido por resposta ao impulso). Agora atenua o mesmo.
//
// Acrescentos posteriores (todos opcionais, nada muda sem os pedir):
//   3) --eq: equalização dos auscultadores. Sem argumento usa a correcção
//      embutida para os Sony MDR-7506; com um ficheiro lê o formato
//      «ParametricEQ.txt» do AutoEQ, portanto serve para uns auscultadores
//      quaisquer que lá estejam medidos.
//   4) Correcção de deriva entre relógios, LIGADA por omissão. O BlackHole e a
//      saída dos auscultadores correm em relógios independentes; ao fim de
//      horas um enche e o outro esvazia, e ouve-se um estalido. Como o
//      BlackHole deixa ajustar o próprio relógio, o CamillaDSP corrige a
//      deriva a pedir-lhe alterações de velocidade da ordem dos 0,005%, sem
//      reamostrar nada: não custa atraso nenhum e não toca no sinal.
//      (Com um reamostrador explícito — AsyncPoly/Cubic — custava +0,5 ms e o
//      CamillaDSP avisava «Needless 1:1 sample rate conversion»; AsyncSinc/
//      Balanced custava +2,5 ms e 3% de CPU. Daí não usar nenhum.)
//      Verificado que as correcções não interrompem quem está a tocar para o
//      BlackHole ao mesmo tempo. Desliga-se com --sem-ajuste-relogio.
//   5) --volume e --loudness: o fader principal do CamillaDSP mais compensação
//      das curvas isofónicas. Ver a nota em imprimir_uso() sobre porque é que
//      um exige o outro.
//
// Invólucro que reproduz o comportamento do bs2b_bridge original mas delega
// todo o processamento de áudio no CamillaDSP. Mantém a mesma interface de
// linha de comandos do original (as opções novas são todas acrescentos), para
// poder ser chamado pelo programa de música sem qualquer alteração. Basta
// renomear o bs2b_bridge antigo e instalar este com o mesmo nome para
// experimentar; para reverter, renomeia-se de volta.
//
// Uso:
//   ./bs2b_bridge
//   ./bs2b_bridge --perfil default
//   ./bs2b_bridge --perfil cmoy
//   ./bs2b_bridge --perfil jmeier
//   ./bs2b_bridge --perfil=cmoy
//   ./bs2b_bridge --silencioso
//   ./bs2b_bridge --eq
//   ./bs2b_bridge --eq "Sony MDR-7506 ParametricEQ.txt"
//   ./bs2b_bridge --volume -15 --loudness
//   ./bs2b_bridge --sem-ajuste-relogio
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
//   cc -O2 -Wall -Wextra -o bs2b_bridge bs2b_bridge3.c
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
#define OUT_DEV_NAME  "Auscultadores externos"  // saída pré-definida: auriculares Sony

#define SAMPLE_RATE   44100
#define CHUNK_SIZE    1024    // atraso da ponte ~= chunksize; ver nota no topo
#define SAMPLE_FORMAT "F32"   // o que o binario 4.1.3 aceita (S16/S24/S32/F32).
                              // NB: a documentacao do 4.1.3 diz "F32_LE" e mente;
                              // v3 chamava-lhe "FLOAT32LE".

// Compensação de volume baixo. A audição perde graves e agudos à medida que o
// nível desce; estes valores são a correcção máxima, aplicada a 20 dB abaixo da
// referência e interpolada pelo caminho. Aproximam as curvas ISO 226: aos 20 dB
// abaixo a diferença ronda os +10 dB nos 40 Hz e os +5 dB nos 12 kHz.
#define LOUDNESS_LOW_BOOST   10.0
#define LOUDNESS_HIGH_BOOST   5.0

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
// O perfil «nenhum» não é um crossfeed mais fraco: é a ausência dele. Serve
// para a ponte continuar a levar o áudio do BlackHole aos auscultadores sem lhe
// tocar — que é o que o botão do programa de música quer dizer com «desligado».
// Matar a ponte não servia: ela não é o efeito, é o próprio fio.
#define PERFIL_NENHUM "nenhum"

static const Perfil PERFIS[] = {
    { "default",       "700 Hz / 4,5 dB", 873.89, -2.25, 700.0,  -6.75, -1.81 },
    { "cmoy",          "700 Hz / 6,0 dB", 868.97, -2.00, 700.0,  -8.00, -1.53 },
    { "jmeier",        "650 Hz / 9,5 dB", 824.70, -1.40, 650.0, -10.92, -1.11 },
    { PERFIL_NENHUM,   "sem crossfeed",     0.0,   0.0,    0.0,   0.0,   0.0 },
};
#define NUM_PERFIS ((int)(sizeof(PERFIS) / sizeof(PERFIS[0])))

// --------------------------------------------------------------------------
// Equalização dos auscultadores
// --------------------------------------------------------------------------

// Um filtro biquad tal como o CamillaDSP o quer. «tipo» é o nome que vai para o
// YAML: Peaking, Lowshelf ou Highshelf.
typedef struct {
    const char *tipo;
    double freq;
    double gain;
    double q;
} Biquad;

#define MAX_EQ 32

// Correcção embutida: Sony MDR-7506, medições do oratory1990, alvo Harman
// over-ear 2018, tal como o AutoEQ a publica. O «preamp» negativo é obrigatório
// — sem ele o reforço de graves de +10,3 dB satura a saída.
// Fonte: AutoEq/results/oratory1990/over-ear/Sony MDR-7506/
static const double EQ_MDR7506_PREAMP = -5.8;
static const Biquad EQ_MDR7506[] = {
    { "Lowshelf",    105.0, 10.3, 0.70 },
    { "Peaking",    5435.0, -3.8, 0.90 },
    { "Peaking",     847.0,  1.9, 0.70 },
    { "Peaking",     230.0,  3.7, 2.08 },
    { "Peaking",      48.0, -9.5, 0.52 },
    { "Highshelf", 10000.0,  3.8, 0.70 },
    { "Peaking",    7530.0, -1.4, 3.26 },
    { "Peaking",    2916.0, -1.9, 5.57 },
    { "Peaking",    3748.0,  2.6, 5.91 },
    { "Peaking",    4456.0, -1.6, 6.00 },
};
#define NUM_EQ_MDR7506 ((int)(sizeof(EQ_MDR7506) / sizeof(EQ_MDR7506[0])))

static Biquad g_eq[MAX_EQ];
static int    g_num_eq = 0;
static double g_eq_preamp = 0.0;
static const char *g_eq_origem = NULL;   // texto para as mensagens

// --------------------------------------------------------------------------

// Dispositivo de saída. O pré-definido são os auscultadores, mas quem chama
// pode mandar tocar noutro sítio com --saida: é assim que o programa de música
// leva o som às colunas quando não há auscultadores na cavilha. O nome tem de
// ser exacto (o CamillaDSP não faz correspondência por substring).
static const char *g_saida = OUT_DEV_NAME;

static int g_silencioso = 0;
static int g_ajustar_relogio = 1;        // correcção de deriva, ligada
static int g_tem_volume = 0;
static double g_volume = 0.0;            // dB, <= 0
static int g_loudness = 0;
static volatile pid_t g_filho = -1;      // pid do CamillaDSP, para o «callback» de sinais
static char g_cfg[64] = {0};             // caminho do ficheiro temporário

#define LOGF(...) do { if (!g_silencioso) printf(__VA_ARGS__); } while (0)

static void imprimir_uso(const char *nome_prog) {
    fprintf(stderr,
        "Uso: %s [--perfil default|cmoy|jmeier|nenhum] [--saida NOME]\n"
        "       %*s [--eq [ficheiro]] [--volume dB]\n"
        "       %*s [--loudness] [--sem-ajuste-relogio] [--silencioso] [--mostrar-config]\n"
        "       %s --ajuda\n\n"
        "Opções:\n"
        "  --perfil P       Onde P pertence a {default, cmoy, jmeier, nenhum}.\n"
        "                   «nenhum» é passagem limpa: a ponte continua a levar o\n"
        "                   áudio do BlackHole à saída, sem crossfeed nenhum\n"
        "  --saida NOME     Nome EXACTO do dispositivo de saída CoreAudio\n"
        "                   (pré-definido: \"%s\"). Para os listar:\n"
        "                   system_profiler SPAudioDataType\n"
        "  --eq [ficheiro]  Equalização dos auscultadores. Sem argumento usa a\n"
        "                   correcção embutida dos Sony MDR-7506; com argumento lê\n"
        "                   um ParametricEQ.txt do AutoEQ (tipos PK, LSC e HSC)\n"
        "  --volume dB      Atenuação do fader principal do CamillaDSP (dB, <= 0)\n"
        "  --loudness       Compensação das curvas isofónicas. Só faz alguma coisa\n"
        "                   com --volume, porque a correcção é proporcional ao que\n"
        "                   o fader está abaixo da referência: se o volume for feito\n"
        "                   fora do CamillaDSP (teclas do macOS), o fader fica a 0 e\n"
        "                   não há nada a compensar\n"
        "  --sem-ajuste-relogio  Desliga a correcção de deriva entre relógios\n"
        "  --silencioso     Não escrever mensagens em stdout (apenas erros)\n"
        "  --mostrar-config Escrever o YAML gerado em stdout e sair (sem tocar)\n\n"
        "Perfis (equivalentes bs2b, via CamillaDSP):\n"
        "  default  -> 700 Hz / 4,5 dB\n"
        "  cmoy     -> 700 Hz / 6,0 dB\n"
        "  jmeier   -> 650 Hz / 9,5 dB   (pré-definido)\n"
        "  nenhum   -> sem crossfeed (passagem limpa)\n\n"
        "Ambiente:\n"
        "  CAMILLADSP_BIN   Caminho do executável CamillaDSP\n"
        "                   (pré-definido: %s)\n",
        nome_prog, (int)strlen(nome_prog), "", (int)strlen(nome_prog), "",
        nome_prog, OUT_DEV_NAME, CAMILLADSP_BIN_DEFAULT);
}

static const Perfil *escolher_perfil(const char *nome) {
    if (!nome) return NULL;
    for (int i = 0; i < NUM_PERFIS; ++i)
        if (strcmp(nome, PERFIS[i].nome) == 0)
            return &PERFIS[i];
    return NULL;
}

// Carrega a correcção embutida dos MDR-7506.
static void eq_embutido(void) {
    g_num_eq = NUM_EQ_MDR7506;
    memcpy(g_eq, EQ_MDR7506, sizeof(EQ_MDR7506));
    g_eq_preamp = EQ_MDR7506_PREAMP;
    g_eq_origem = "Sony MDR-7506 (embutido)";
}

// Lê um ParametricEQ.txt do AutoEQ. As linhas que interessam são:
//   Preamp: -5.8 dB
//   Filter 1: ON LSC Fc 105 Hz Gain 10.3 dB Q 0.70
// Filtros OFF e tipos que o CamillaDSP não faz da mesma maneira são saltados,
// com aviso. Devolve 0 em sucesso.
static int eq_de_ficheiro(const char *caminho) {
    FILE *f = fopen(caminho, "r");
    if (!f) {
        fprintf(stderr, "Erro a abrir \"%s\": %s\n", caminho, strerror(errno));
        return -1;
    }

    char linha[512];
    int n = 0;
    g_eq_preamp = 0.0;

    while (fgets(linha, sizeof(linha), f)) {
        double v;
        if (sscanf(linha, " Preamp: %lf dB", &v) == 1) {
            g_eq_preamp = v;
            continue;
        }

        int idx;
        char estado[8], tipo[8];
        double fc, ganho, q;
        if (sscanf(linha, " Filter %d: %7s %7s Fc %lf Hz Gain %lf dB Q %lf",
                   &idx, estado, tipo, &fc, &ganho, &q) != 6)
            continue;

        if (strcmp(estado, "ON") != 0)
            continue;

        const char *tipo_camilla = NULL;
        if      (strcmp(tipo, "PK")  == 0) tipo_camilla = "Peaking";
        else if (strcmp(tipo, "LSC") == 0) tipo_camilla = "Lowshelf";
        else if (strcmp(tipo, "HSC") == 0) tipo_camilla = "Highshelf";
        else {
            fprintf(stderr, "Aviso: filtro %d ignorado, tipo \"%s\" não suportado.\n",
                    idx, tipo);
            continue;
        }

        if (n >= MAX_EQ) {
            fprintf(stderr, "Aviso: mais de %d filtros; os restantes são ignorados.\n",
                    MAX_EQ);
            break;
        }

        g_eq[n].tipo = tipo_camilla;
        g_eq[n].freq = fc;
        g_eq[n].gain = ganho;
        g_eq[n].q    = q;
        ++n;
    }

    fclose(f);

    if (n == 0) {
        fprintf(stderr, "Erro: não encontrei nenhum filtro em \"%s\".\n", caminho);
        return -1;
    }

    g_num_eq = n;
    g_eq_origem = caminho;
    return 0;
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
// No fim, «comp» repõe a mesma margem de saturação que o libbs2b usa, e a
// seguir vem o que corrige os auscultadores (o crossfeed modela a cabeça, a
// equalização modela o transdutor: primeiro um, depois o outro).
static void gerar_config(FILE *f, const Perfil *p) {
    fprintf(f,
        "title: \"bs2b_bridge (perfil %s)\"\n"
        "\n"
        "devices:\n"
        "  samplerate: %d\n"
        "  chunksize: %d\n",
        p->nome, SAMPLE_RATE, CHUNK_SIZE);

    const int sem_crossfeed = (strcmp(p->nome, PERFIL_NENHUM) == 0);

    // Correcção de deriva: de 10 em 10 segundos o CamillaDSP compara o nível
    // do tampão com o alvo e pede ao BlackHole que ande um nadinha mais depressa
    // ou mais devagar. Sem reamostrador — o relógio do dispositivo é ajustável,
    // e o sinal passa intacto.
    if (g_ajustar_relogio) {
        fprintf(f,
            "  enable_rate_adjust: true\n"
            "  target_level: %d\n"
            "  adjust_period: 10\n",
            CHUNK_SIZE);
    }

    fprintf(f,
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
        "filters:\n",
        IN_DEV_NAME, SAMPLE_FORMAT,
        g_saida, SAMPLE_FORMAT);

    if (!sem_crossfeed) {
        fprintf(f,
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
            "      scale: dB\n",
            p->hi_freq, p->hi_gain,
            p->lo_freq,
            p->lo_gain);
    }

    // O «comp» existe sempre, ainda que a 0 dB no perfil «nenhum»: é ele que
    // garante que a cadeia nunca fica vazia, e o CamillaDSP quer um pipeline.
    fprintf(f,
        "  comp:\n"
        "    type: Gain\n"
        "    parameters:\n"
        "      gain: %g\n"
        "      scale: dB\n",
        p->comp_gain);

    if (g_num_eq > 0) {
        fprintf(f,
            "  eq_preamp:\n"
            "    type: Gain\n"
            "    parameters:\n"
            "      gain: %g\n"
            "      scale: dB\n",
            g_eq_preamp);

        for (int i = 0; i < g_num_eq; ++i) {
            fprintf(f,
                "  eq%d:\n"
                "    type: Biquad\n"
                "    parameters:\n"
                "      type: %s\n"
                "      freq: %g\n"
                "      gain: %g\n"
                "      q: %g\n",
                i + 1, g_eq[i].tipo, g_eq[i].freq, g_eq[i].gain, g_eq[i].q);
        }
    }

    if (g_loudness) {
        fprintf(f,
            "  loud:\n"
            "    type: Loudness\n"
            "    parameters:\n"
            "      reference_level: 0\n"
            "      low_boost: %g\n"
            "      high_boost: %g\n"
            "      attenuate_mid: false\n"
            "      fader: Main\n",
            LOUDNESS_LOW_BOOST, LOUDNESS_HIGH_BOOST);
    }

    if (sem_crossfeed) {
        // Passagem limpa: sem mistura de 2->4->2, sem crossfeed. Fica só o
        // «comp» (a 0 dB) e, se tiverem sido pedidos, a equalização e o
        // loudness.
        fprintf(f,
            "\n"
            "pipeline:\n"
            "  - type: Filter\n"
            "    channels: [0, 1]\n"
            "    names:\n"
            "      - comp\n");
    } else {
    fprintf(f,
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
        "      - comp\n");
    }

    if (g_num_eq > 0) {
        fprintf(f, "      - eq_preamp\n");
        for (int i = 0; i < g_num_eq; ++i)
            fprintf(f, "      - eq%d\n", i + 1);
    }

    if (g_loudness)
        fprintf(f, "      - loud\n");
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
        if (strcmp(arg, "--sem-ajuste-relogio") == 0) {
            g_ajustar_relogio = 0;
            continue;
        }
        if (strncmp(arg, "--saida=", 8) == 0) {
            if (arg[8] == '\0') {
                fprintf(stderr, "Erro: --saida= precisa de um nome de dispositivo.\n\n");
                imprimir_uso(argv[0]);
                return 1;
            }
            g_saida = arg + 8;
            continue;
        }
        if (strcmp(arg, "--saida") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Erro: --saida precisa de um nome de dispositivo.\n\n");
                imprimir_uso(argv[0]);
                return 1;
            }
            g_saida = argv[++i];
            continue;
        }
        if (strcmp(arg, "--loudness") == 0) {
            g_loudness = 1;
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
        if (strncmp(arg, "--eq=", 5) == 0) {
            if (eq_de_ficheiro(arg + 5) != 0)
                return 1;
            continue;
        }
        if (strcmp(arg, "--eq") == 0) {
            // O argumento é opcional: só conta como ficheiro se o que vier a
            // seguir não for outra opção.
            if (i + 1 < argc && strncmp(argv[i + 1], "--", 2) != 0) {
                if (eq_de_ficheiro(argv[++i]) != 0)
                    return 1;
            } else {
                eq_embutido();
            }
            continue;
        }
        if (strncmp(arg, "--volume=", 9) == 0 || strcmp(arg, "--volume") == 0) {
            const char *valor;
            if (strcmp(arg, "--volume") == 0) {
                if (i + 1 >= argc) {
                    fprintf(stderr, "Erro: --volume precisa de um valor em dB.\n\n");
                    imprimir_uso(argv[0]);
                    return 1;
                }
                valor = argv[++i];
            } else {
                valor = arg + 9;
            }
            char *fim = NULL;
            double v = strtod(valor, &fim);
            if (!fim || *fim != '\0' || v > 0.0 || v < -60.0) {
                fprintf(stderr, "Erro: --volume espera dB entre -60 e 0 (recebi \"%s\").\n\n",
                        valor);
                imprimir_uso(argv[0]);
                return 1;
            }
            g_volume = v;
            g_tem_volume = 1;
            continue;
        }
        fprintf(stderr, "Aviso: argumento ignorado: %s\n", arg);
    }

    if (g_loudness && !g_tem_volume) {
        fprintf(stderr,
                "Aviso: --loudness sem --volume não faz nada. A compensação é\n"
                "       proporcional ao que o fader está abaixo da referência, e\n"
                "       sem --volume o fader fica a 0 dB.\n");
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
    LOGF("Equalização: %s\n", g_num_eq > 0 ? g_eq_origem : "nenhuma");
    if (g_num_eq > 0)
        LOGF("  %d filtros, preamp %+.1f dB\n", g_num_eq, g_eq_preamp);
    LOGF("Deriva de relógios: %s\n",
         g_ajustar_relogio ? "corrigida (ajuste do relógio do BlackHole)"
                           : "sem correcção");
    if (g_tem_volume)
        LOGF("Volume: %+.1f dB%s\n", g_volume, g_loudness ? " (com loudness)" : "");
    LOGF("Configuração: %s\n\n", g_cfg);

    // --------------------------------------------------
    // 4) Lançar o CamillaDSP
    // --------------------------------------------------
    // Em silêncio, abafa o registo do CamillaDSP até ao nível de erro; caso
    // contrário mostra avisos e erros (mas não o «info» verboso de arranque).
    const char *nivel = g_silencioso ? "error" : "warn";
    char volume_txt[32];
    char *cd_argv[8];
    int n = 0;

    cd_argv[n++] = (char *)bin;
    cd_argv[n++] = (char *)"-l";
    cd_argv[n++] = (char *)nivel;
    if (g_tem_volume) {
        // O fader principal é o que o filtro Loudness segue; daí passar o
        // volume por aqui em vez de um Gain no pipeline.
        //
        // Tem de ir tudo num só argumento: o CamillaDSP 4.1.3 usa o clap, que
        // lê o «-15» de «-g -15» como sendo outra opção e recusa-se a arrancar.
        // A forma «--gain=-15» é a única que passa.
        snprintf(volume_txt, sizeof(volume_txt), "--gain=%g", g_volume);
        cd_argv[n++] = volume_txt;
    }
    cd_argv[n++] = g_cfg;
    cd_argv[n++] = NULL;

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
