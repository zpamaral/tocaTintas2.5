// bs2b_bridge.c — captura de BlackHole e saída para auriculares filtrada por bs2b
//
// /usr/local/bin/clang -O3 -march=native -mtune=native bs2b_bridge.c -o bs2b_bridge -I/usr/local/include -L/usr/local/lib -lportaudio -lbs2b
//
// Uso:
//   ./bs2b_bridge
//   ./bs2b_bridge --perfil default
//   ./bs2b_bridge --perfil cmoy
//   ./bs2b_bridge --perfil jmeier
//   ./bs2b_bridge --silencioso
//
//   Também aceita:
//   ./bs2b_bridge --perfil=cmoy
//
// Perfis bs2b pré-definidos:
//   default → BS2B_DEFAULT_CLEVEL
//   cmoy    → BS2B_CMOY_CLEVEL
//   jmeier  → BS2B_JMEIER_CLEVEL (pré-definido se nada for passado)

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <portaudio.h>
#include <bs2b/bs2b.h>

#define SAMPLE_RATE        44100
#define FRAMES_PER_BUFFER  512
#define NUM_CHANNELS       2

// Nomes (ou fragmentos de nome) dos dispositivos PortAudio.
// Ajustar estes nomes se os nomes mudarem no macOS.
#define IN_DEV_NAME   "BlackHole 2ch"          // entrada: onde o sistema toca (loopback)
#define OUT_DEV_NAME  "Auscultadores externos" // saída: auriculares

typedef struct {
    t_bs2bdp bs2b;
} UserData;

// modo silencioso (sem stdout normal)
static int g_silencioso = 0;

// Macro simples para comentário em stdout
#define LOGF(...) do { if (!g_silencioso) printf(__VA_ARGS__); } while (0)

static void imprimir_uso(const char *nome_prog) {
    fprintf(stderr,
        "Uso: %s [--perfil default|cmoy|jmeier] [--silencioso]\n"
        "       %s --ajuda\n\n"
        "Opções:\n"
        "  --perfil P   Onde P ∈ {default, cmoy, jmeier}\n"
        "  --silencioso Não escrever mensagens em stdout (apenas erros em stderr)\n\n"
        "Perfis bs2b:\n"
        "  default  -> BS2B_DEFAULT_CLEVEL\n"
        "  cmoy     -> BS2B_CMOY_CLEVEL\n"
        "  jmeier   -> BS2B_JMEIER_CLEVEL (pré-definido)\n",
        nome_prog, nome_prog);
}

// Converte string de perfil no CLEVEL correspondente.
// Devolve 0 em sucesso, -1 se o perfil for desconhecido.
static int escolher_clevel(const char *perfil, int *clevel_out) {
    if (!perfil || !clevel_out) return -1;

    if (strcmp(perfil, "default") == 0) {
        *clevel_out = BS2B_DEFAULT_CLEVEL;
        return 0;
    } else if (strcmp(perfil, "cmoy") == 0) {
        *clevel_out = BS2B_CMOY_CLEVEL;
        return 0;
    } else if (strcmp(perfil, "jmeier") == 0) {
        *clevel_out = BS2B_JMEIER_CLEVEL;
        return 0;
    }

    return -1; // perfil não reconhecido
}

// Lista todos os dispositivos, útil para depuração quando algo corre mal.
static void listar_dispositivos(void) {
    int numDevices = Pa_GetDeviceCount();
    if (numDevices < 0) {
        fprintf(stderr, "Pa_GetDeviceCount: %s\n", Pa_GetErrorText(numDevices));
        return;
    }

    fprintf(stderr, "Dispositivos PortAudio disponíveis:\n\n");
    for (int i = 0; i < numDevices; ++i) {
        const PaDeviceInfo *info = Pa_GetDeviceInfo(i);
        const PaHostApiInfo *api = Pa_GetHostApiInfo(info->hostApi);
        fprintf(stderr,
                "  Device %d: \"%s\" [%s]\n"
                "    Max input  channels: %d\n"
                "    Max output channels: %d\n"
                "    Default sample rate : %.0f\n\n",
                i, info->name, api->name,
                info->maxInputChannels,
                info->maxOutputChannels,
                info->defaultSampleRate);
    }
}

// Procura um dispositivo cujo nome contenha 'substring' e que tenha
// pelo menos 'minInput' e 'minOutput' canais.
// Devolve 0 em sucesso e escreve o índice em *index_out, -1 em falha.
static int encontrar_dispositivo_por_nome(const char *substring,
                                          int minInput,
                                          int minOutput,
                                          PaDeviceIndex *index_out)
{
    if (!substring || !index_out) return -1;

    int numDevices = Pa_GetDeviceCount();
    if (numDevices < 0) {
        fprintf(stderr, "Pa_GetDeviceCount: %s\n", Pa_GetErrorText(numDevices));
        return -1;
    }

    for (int i = 0; i < numDevices; ++i) {
        const PaDeviceInfo *info = Pa_GetDeviceInfo(i);
        if (!info) continue;

        // Verifica se o nome contém a substring pedida
        if (strstr(info->name, substring) == NULL) {
            continue;
        }

        // Verifica se cumpre os mínimos de canais
        if (info->maxInputChannels  < minInput)  continue;
        if (info->maxOutputChannels < minOutput) continue;

        *index_out = (PaDeviceIndex)i;
        return 0;
    }

    return -1;
}

static int streamCallback(const void *inputBuffer,
                          void *outputBuffer,
                          unsigned long framesPerBuffer,
                          const PaStreamCallbackTimeInfo* timeInfo,
                          PaStreamCallbackFlags statusFlags,
                          void *userData)
{
    UserData *ud = (UserData*)userData;
    const float *in  = (const float*)inputBuffer;
    float *out       = (float*)outputBuffer;

    (void)timeInfo;
    (void)statusFlags;

    if (!outputBuffer) {
        // Sem tampão de saída não há nada a fazer
        return paContinue;
    }

    if (!inputBuffer) {
        // Se por algum motivo não chega nada ao input, envia silêncio
        memset(out, 0, framesPerBuffer * NUM_CHANNELS * sizeof(float));
        return paContinue;
    }

    // Copia o input para o output tal como chega do BlackHole
    memcpy(out, in, framesPerBuffer * NUM_CHANNELS * sizeof(float));

    // Aplica bs2b IN-PLACE ao áudio em float interleaved
    bs2b_cross_feed_f(ud->bs2b, out, (int)framesPerBuffer);

    return paContinue;
}

int main(int argc, char *argv[])
{
    PaError err;
    PaStream *stream = NULL;
    PaStreamParameters inParams, outParams;
    UserData ud;
    int clevel = BS2B_JMEIER_CLEVEL;   // perfil pré-definido
    const char *perfil_str = "jmeier"; // texto correspondente para imprimir

    // --------------------------------------------------
    // 0) Leitura muito simples dos argumentos
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

        // Formato --perfil=x
        if (strncmp(arg, "--perfil=", 9) == 0) {
            const char *valor = arg + 9;
            if (*valor == '\0') {
                fprintf(stderr, "Erro: --perfil= precisa de um valor.\n\n");
                imprimir_uso(argv[0]);
                return 1;
            }
            if (escolher_clevel(valor, &clevel) != 0) {
                fprintf(stderr, "Erro: perfil desconhecido \"%s\".\n\n", valor);
                imprimir_uso(argv[0]);
                return 1;
            }
            perfil_str = valor;
            continue;
        }

        // Formato --perfil x
        if (strcmp(arg, "--perfil") == 0) {
            if (i + 1 >= argc) {
                fprintf(stderr, "Erro: --perfil precisa de um valor.\n\n");
                imprimir_uso(argv[0]);
                return 1;
            }
            const char *valor = argv[++i];
            if (escolher_clevel(valor, &clevel) != 0) {
                fprintf(stderr, "Erro: perfil desconhecido \"%s\".\n\n", valor);
                imprimir_uso(argv[0]);
                return 1;
            }
            perfil_str = valor;
            continue;
        }

        // Quaisquer outras coisas
        fprintf(stderr, "Aviso: argumento ignorado: %s\n", arg);
    }

    // --------------------------------------------------
    // 1) Inicializar bs2b
    // --------------------------------------------------
    ud.bs2b = bs2b_open();
    if (!ud.bs2b) {
        fprintf(stderr, "Erro a abrir bs2b\n");
        return 1;
    }

    // Ajusta taxa de amostragem e nível de «crossfeed»
    bs2b_set_srate(ud.bs2b, SAMPLE_RATE);
    bs2b_set_level(ud.bs2b, clevel);

    // --------------------------------------------------
    // 2) Inicializar PortAudio
    // --------------------------------------------------
    err = Pa_Initialize();
    if (err != paNoError) {
        fprintf(stderr, "Pa_Initialize: %s\n", Pa_GetErrorText(err));
        bs2b_close(ud.bs2b);
        return 1;
    }

    // Encontrar dispositivos pelo nome (substring) em vez de índice fixo
    PaDeviceIndex inDev  = paNoDevice;
    PaDeviceIndex outDev = paNoDevice;

    if (encontrar_dispositivo_por_nome(IN_DEV_NAME, 2, 0, &inDev) != 0) {
        fprintf(stderr,
                "Erro: não encontrei dispositivo de ENTRADA com nome contendo \"%s\" e pelo menos 2 canais de entrada.\n\n",
                IN_DEV_NAME);
        listar_dispositivos();
        goto cleanup;
    }

    if (encontrar_dispositivo_por_nome(OUT_DEV_NAME, 0, 2, &outDev) != 0) {
        fprintf(stderr,
                "Erro: não encontrei dispositivo de SAÍDA com nome contendo \"%s\" e pelo menos 2 canais de saída.\n\n",
                OUT_DEV_NAME);
        listar_dispositivos();
        goto cleanup;
    }

    const PaDeviceInfo *inInfo  = Pa_GetDeviceInfo(inDev);
    const PaDeviceInfo *outInfo = Pa_GetDeviceInfo(outDev);

    if (!inInfo || !outInfo) {
        fprintf(stderr, "Dispositivos inválidos (in=%d, out=%d)\n",
                (int)inDev, (int)outDev);
        goto cleanup;
    }

    LOGF("Entrada : %d — «%s»\n", (int)inDev,  inInfo->name);
    LOGF("Saída   : %d — «%s»\n", (int)outDev, outInfo->name);
    LOGF("Frequência pedida: %d Hz\n", SAMPLE_RATE);
    LOGF("Perfil bs2b: %s\n\n", perfil_str);

    // --------------------------------------------------
    // 3) Configurar parâmetros de passagem (float32 interleaved)
    // --------------------------------------------------
    inParams.device = inDev;
    inParams.channelCount = NUM_CHANNELS;
    inParams.sampleFormat = paFloat32;
    inParams.suggestedLatency = inInfo->defaultLowInputLatency;
    inParams.hostApiSpecificStreamInfo = NULL;

    outParams.device = outDev;
    outParams.channelCount = NUM_CHANNELS;
    outParams.sampleFormat = paFloat32;
    outParams.suggestedLatency = outInfo->defaultLowOutputLatency;
    outParams.hostApiSpecificStreamInfo = NULL;

    err = Pa_OpenStream(&stream,
                        &inParams,
                        &outParams,
                        SAMPLE_RATE,
                        FRAMES_PER_BUFFER,
                        paNoFlag,
                        streamCallback,
                        &ud);
    if (err != paNoError) {
        fprintf(stderr, "Pa_OpenStream: %s\n", Pa_GetErrorText(err));
        goto cleanup;
    }

    err = Pa_StartStream(stream);
    if (err != paNoError) {
        fprintf(stderr, "Pa_StartStream: %s\n", Pa_GetErrorText(err));
        goto cleanup;
    }

    LOGF("A correr com perfil «%s». Ctrl+C para sair.\n", perfil_str);

    // Ciclo bloqueante simples; o PortAudio chama o «callback» atrás
    while (Pa_IsStreamActive(stream) == 1) {
        Pa_Sleep(200);
    }

cleanup:
    if (stream) {
        Pa_StopStream(stream);
        Pa_CloseStream(stream);
    }
    Pa_Terminate();
    if (ud.bs2b) {
        bs2b_close(ud.bs2b);
    }
    return 0;
}
