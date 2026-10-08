/*
Copyright (c) 2026 Zé Pedro do Amaral <amaral@mac.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/
//
//  ZPAudioCapture.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 14/11/2026.
//
#import "ZPAudioCapture.h"
#import "PreferencesWindowController.h"
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreMotion/CoreMotion.h>

NSString * const kZPAudioCaptureWarningNotification = @"ZPAudioCaptureWarning";

// Vigia do seguimento da cabeça: janelas de meio segundo, as últimas 40
// (20 s). Ver -vigiarJanelaComEsquerda:direita:.
enum { kZPJanelasVigia = 40 };

// RIFF (12) + fmt  (24) + fact (12) + cabeçalho de data (8). O troço «fact» é
// exigido pela norma para formatos que não sejam PCM inteiro; sem ele há
// leitores esquisitos que recusam WAV de vírgula flutuante.
enum { kZPWavHeaderSize = 56 };   // constante de compilação: serve de dimensão do vector

// Substring do nome do dispositivo de loopback. É o mesmo BlackHole para onde a
// saída do sistema aponta; o nome exacto («BlackHole 16ch») pode mudar com a
// versão ou com o número de canais, daí procurar-se por pedaço.
static NSString * const kZPLoopbackNameSubstring = @"BlackHole";

// Procura o dispositivo de loopback entre os que têm pelo menos dois canais de entrada.
AudioDeviceID ZPLoopbackAudioDevice(void) {
    AudioObjectPropertyAddress devicesAddr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddr, 0, NULL, &dataSize) != noErr
        || dataSize == 0) {
        return kAudioObjectUnknown;
    }

    AudioDeviceID *ids = (AudioDeviceID *)malloc(dataSize);
    if (!ids) {
        return kAudioObjectUnknown;
    }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddr, 0, NULL, &dataSize, ids) != noErr) {
        free(ids);
        return kAudioObjectUnknown;
    }

    AudioDeviceID encontrado = kAudioObjectUnknown;
    UInt32 total = dataSize / sizeof(AudioDeviceID);

    for (UInt32 i = 0; i < total && encontrado == kAudioObjectUnknown; ++i) {
        // Tem canais de ENTRADA? O BlackHole tem os dois lados; só nos serve a entrada.
        UInt32 streamsSize = 0;
        AudioObjectPropertyAddress streamAddr = (AudioObjectPropertyAddress) {
            .mSelector = kAudioDevicePropertyStreamConfiguration,
            .mScope    = kAudioDevicePropertyScopeInput,
            .mElement  = kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyDataSize(ids[i], &streamAddr, 0, NULL, &streamsSize) != noErr || streamsSize == 0) {
            continue;
        }
        AudioBufferList *lista = (AudioBufferList *)malloc(streamsSize);
        if (!lista) {
            continue;
        }
        if (AudioObjectGetPropertyData(ids[i], &streamAddr, 0, NULL, &streamsSize, lista) != noErr) {
            free(lista);
            continue;
        }
        UInt32 canais = 0;
        for (UInt32 b = 0; b < lista->mNumberBuffers; ++b) {
            canais += lista->mBuffers[b].mNumberChannels;
        }
        free(lista);
        if (canais < 2) {
            continue;
        }

        CFStringRef nameRef = NULL;
        UInt32 nameSize = sizeof(nameRef);
        AudioObjectPropertyAddress nameAddr = (AudioObjectPropertyAddress) {
            .mSelector = kAudioDevicePropertyDeviceNameCFString,
            .mScope    = kAudioObjectPropertyScopeGlobal,
            .mElement  = kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(ids[i], &nameAddr, 0, NULL, &nameSize, &nameRef) != noErr || !nameRef) {
            continue;
        }
        NSString *nome = CFBridgingRelease(nameRef);
        if ([nome rangeOfString:kZPLoopbackNameSubstring options:NSCaseInsensitiveSearch].location != NSNotFound) {
            encontrado = ids[i];
        }
    }

    free(ids);
    return encontrado;
}

BOOL ZPBindEngineInputToLoopback(AVAudioEngine *engine) {
    if (!engine) {
        return NO;
    }

    AudioDeviceID dispositivo = ZPLoopbackAudioDevice();
    if (dispositivo == kAudioObjectUnknown) {
        NSLog(@"[Audio Capture] Não encontrei nenhum dispositivo de entrada com \"%@\" no nome; "
               "a entrada fica no dispositivo por omissão do sistema.", kZPLoopbackNameSubstring);
        return NO;
    }

    AudioUnit unidade = engine.inputNode.audioUnit;
    if (!unidade) {
        return NO;
    }

    OSStatus estado = AudioUnitSetProperty(unidade,
                                           kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global,
                                           0,
                                           &dispositivo,
                                           sizeof(dispositivo));
    if (estado != noErr) {
        NSLog(@"[Audio Capture] Não consegui prender a entrada ao loopback (estado %d).", (int)estado);
        return NO;
    }

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Entrada presa ao dispositivo de loopback (id %u).", (unsigned)dispositivo);
    #endif
    return YES;
}

@interface ZPAudioCapture ()

// Audio Engine
@property (strong, nonatomic) AVAudioEngine *audioEngine;

// Recording properties
// A gravação escreve WAV de vírgula flutuante de 32 bits, não Int16: ver a nota
// em -installAudioTap. Precisa de um NSFileHandle (e não de um NSOutputStream)
// porque o cabeçalho só se pode fechar no fim, voltando ao início do ficheiro.
@property (strong, nonatomic) NSFileHandle *recordFileHandle;
@property (strong, nonatomic) NSURL *recordFileURL;
@property (assign, nonatomic) unsigned long long recordDataBytes;
@property (assign, nonatomic) double recordSampleRate;
@property (assign, nonatomic) NSUInteger recordChannels;
@property (assign, nonatomic) BOOL isRecording;

// Reutilizados entre callbacks (criados uma vez por tap)
@property (strong, nonatomic) AVAudioConverter *recordConverter;
@property (strong, nonatomic) AVAudioPCMBuffer *recordBuffer;

// Fila serial para I/O fora do thread de áudio
@property (strong, nonatomic) dispatch_queue_t ioQueue;

// Observer da reconfiguração do engine
@property (strong, nonatomic) id engineConfigObserver;

// Captura do app Música: um tap de processo, lido por um dispositivo agregado
// privado. Ver -iniciarCapturaDoMusica.
@property (assign, nonatomic) BOOL aGravarDoMusica;
@property (assign, nonatomic) AudioObjectID tapMusica;
@property (assign, nonatomic) AudioObjectID agregadoMusica;
@property (assign, nonatomic) AudioDeviceIOProcID ioProcMusica;

// Movimento da cabeça, dos AirPods. Só durante a captura do Música.
@property (strong, nonatomic) CMHeadphoneMotionManager *movimentoCabeca;

@end

// Estado do vigia do seguimento da cabeça. Mexido só na ioQueue: lá chegam as
// amostras (com o ficheiro) e a orientação da cabeça (do CoreMotion).
typedef struct {
    double somaEsq, somaDir;          // energia da janela em curso
    unsigned long long tramas;        // tramas da janela em curso
    double guinada;                   // graus, desenrolada (sem saltos de 360°)
    double guinadaBruta;              // a última lida, em radianos, para desenrolar
    BOOL   haCabeca;                  // já chegou alguma orientação
    double guinadas[kZPJanelasVigia]; // por janela: guinada…
    double equilibrios[kZPJanelasVigia]; // …e equilíbrio esquerdo−direito, em dB
    int    n, proxima;                // anel
    BOOL   activo;                    // há CoreMotion a alimentar o vigia
    BOOL   avisado;
} ZPVigiaCabeca;

@implementation ZPAudioCapture {
    ZPVigiaCabeca _vigia;   // só na ioQueue
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize audio engine
        _audioEngine = [[AVAudioEngine alloc] init];
        _isRecording = NO;
        _ioQueue = dispatch_queue_create("com.tocaTintas.audioCapture.io", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

#pragma mark - Original Method Names (Aliases)

// Start capturing audio (alias for startRecording)
- (BOOL)startCapturingAudio {
    return [self startRecording];
}

// Stop capturing audio (alias for stopRecording)
- (void)stopCapturingAudio {
    [self stopRecording];
}

#pragma mark - Recording Methods

- (BOOL)startRecording {
    if (self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Already recording.");
        #endif
        return YES;
    }

    // A fonte lê-se aqui e fica até ao fim: mudar a preferência a meio não
    // muda a gravação em curso.
    BOOL doMusica = [ZPCurrentRecordSource() isEqualToString:@"music"];

    self.isRecording = YES;

    // Get the Application Support directory
    NSArray<NSURL *> *appSupportURLs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *appSupportURL = [appSupportURLs firstObject];

    // Append your app's directory
    NSURL *appDirectory = [appSupportURL URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES];

    // Ensure the directory exists
    NSError *error = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:[appDirectory path]]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:appDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Audio Capture] Error creating directory: %@", error.localizedDescription);
            #endif
        }
    }

    // Create a unique file name
    NSString *fileName = [NSString stringWithFormat:doMusica ? @"Recording_Music_%@.wav" : @"Recording_%@.wav",
                          [[NSUUID UUID] UUIDString]];
    NSURL *outputFileURL = [appDirectory URLByAppendingPathComponent:fileName];

    // Ficheiro novo com o cabeçalho reservado a zeros: as dimensões e a
    // frequência de amostragem só se sabem no fim, e são lá escritas por cima.
    self.recordFileURL = outputFileURL;
    self.recordDataBytes = 0;
    self.recordSampleRate = 0.0;
    self.recordChannels = 2;

    NSMutableData *reserva = [NSMutableData dataWithLength:kZPWavHeaderSize];
    if (![reserva writeToURL:outputFileURL atomically:NO]) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Não consegui criar %@", [outputFileURL path]);
        #endif
        self.isRecording = NO;
        return NO;
    }

    NSError *handleError = nil;
    self.recordFileHandle = [NSFileHandle fileHandleForWritingToURL:outputFileURL error:&handleError];
    if (!self.recordFileHandle) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Não consegui abrir %@: %@", [outputFileURL path], handleError.localizedDescription);
        #endif
        self.isRecording = NO;
        return NO;
    }
    [self.recordFileHandle seekToEndOfFile];

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Recording started. Saving to %@", [outputFileURL path]);
    #endif

    if (doMusica) {
        if (![self iniciarCapturaDoMusica]) {
            // Nada foi gravado: o ficheiro vazio sai, para não ficar um WAV
            // de 56 bytes a confundir quem for à pasta.
            [self.recordFileHandle closeFile];
            self.recordFileHandle = nil;
            [[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:NULL];
            self.isRecording = NO;
            return NO;
        }
        self.aGravarDoMusica = YES;
        return YES;
    }

    // Start or update audio capture
    [self startAudioCapture];
    return YES;
}

- (void)stopRecording {
    if (!self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Recording is not running.");
        #endif
        return;
    }

    self.isRecording = NO;

    // Parar a captura primeiro: as duas paragens são síncronas, e depois delas
    // já não entra nenhum bloco novo na fila de I/O.
    if (self.aGravarDoMusica) {
        [self pararCapturaDoMusica];
        self.aGravarDoMusica = NO;
    } else {
        [self stopAudioCapture];
    }

    // O fecho vai para a fila de I/O, atrás de tudo o que já lá esteja: é uma
    // fila em série, portanto as últimas amostras entram no ficheiro antes de
    // o cabeçalho ser escrito e o descritor fechado.
    if (self.recordFileHandle) {
        dispatch_async(self.ioQueue, ^{
            [self finalizeRecordingFile];
        });
    }
}

#pragma mark - Ficheiro WAV

// Cabeçalho canónico de WAV em vírgula flutuante de 32 bits.
static void ZPPutU32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}

static void ZPPutU16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v & 0xFF);
    p[1] = (uint8_t)((v >> 8) & 0xFF);
}

static NSData *ZPWavHeader(double sampleRate, NSUInteger channels, unsigned long long dataBytes) {
    const uint16_t bitsPerSample = 32;
    const uint16_t blockAlign    = (uint16_t)(channels * bitsPerSample / 8);
    const uint32_t byteRate      = (uint32_t)llround(sampleRate) * blockAlign;
    const uint32_t frames        = blockAlign ? (uint32_t)(dataBytes / blockAlign) : 0;
    // O RIFF conta tudo menos os primeiros 8 bytes.
    const uint32_t riffSize      = (uint32_t)(kZPWavHeaderSize - 8 + dataBytes);

    uint8_t h[kZPWavHeaderSize];
    memset(h, 0, sizeof(h));
    memcpy(h + 0,  "RIFF", 4);   ZPPutU32(h + 4,  riffSize);
    memcpy(h + 8,  "WAVE", 4);
    memcpy(h + 12, "fmt ", 4);   ZPPutU32(h + 16, 16);
    ZPPutU16(h + 20, 3);                        // WAVE_FORMAT_IEEE_FLOAT
    ZPPutU16(h + 22, (uint16_t)channels);
    ZPPutU32(h + 24, (uint32_t)llround(sampleRate));
    ZPPutU32(h + 28, byteRate);
    ZPPutU16(h + 32, blockAlign);
    ZPPutU16(h + 34, bitsPerSample);
    memcpy(h + 36, "fact", 4);   ZPPutU32(h + 40, 4);
    ZPPutU32(h + 44, frames);
    memcpy(h + 48, "data", 4);   ZPPutU32(h + 52, (uint32_t)dataBytes);
    return [NSData dataWithBytes:h length:sizeof(h)];
}

// Corre sempre na ioQueue, depois da última escrita de amostras.
- (void)finalizeRecordingFile {
    NSFileHandle *handle = self.recordFileHandle;
    if (!handle) {
        return;
    }
    self.recordFileHandle = nil;

    double taxa = self.recordSampleRate > 0.0 ? self.recordSampleRate : 44100.0;

    // O WAV guarda as dimensões em 32 bits sem sinal: acima de 4 GiB (cerca de
    // 3 h 20 m em estéreo float a 44,1 kHz) o cabeçalho deixa de as poder
    // descrever. As amostras estão todas no ficheiro; é a contagem que trunca.
    if (self.recordDataBytes > UINT32_MAX) {
        NSLog(@"[Audio Capture] Gravação com %llu bytes excede os 4 GiB que o cabeçalho WAV descreve; %@ vai indicar menos do que tem.",
              self.recordDataBytes, [self.recordFileURL lastPathComponent]);
    }

    NSData *cabecalho = ZPWavHeader(taxa, self.recordChannels, self.recordDataBytes);

    NSError *erro = nil;
    if (![handle seekToOffset:0 error:&erro] || ![handle writeData:cabecalho error:&erro]) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Erro a fechar o cabeçalho WAV: %@", erro.localizedDescription);
        #endif
    }
    [handle closeFile];

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Gravação fechada: %llu bytes de amostras, %.0f Hz, %lu canais, float de 32 bits (%@).",
          self.recordDataBytes, taxa, (unsigned long)self.recordChannels, [self.recordFileURL lastPathComponent]);
    #endif
}

#pragma mark - Captura do app Música

// Porque um tap de processo, e não o BlackHole: o Música só faz o binaural do
// Dolby Atmos quando toca para auscultadores com áudio espacial (os AirPods), e
// fá-lo dentro do próprio processo — o que entrega ao sistema já são os dois
// canais binaurais. Para o BlackHole entrega uma mistura estéreo comum, mesmo
// com o selo Dolby aceso: medido em 2026-10, com a mesma faixa e o mesmo
// instante, a coerência entre as duas cai de 0,99 nos graves para menos de 0,3
// acima de 10 kHz. O tap apanha o que o Música entrega, antes da compressão do
// Bluetooth e do equalizador dos AirPods.
//
// O seguimento da cabeça também é feito dentro do Música, e por isso fica
// gravado. Os AirPods têm de estar em «Fixo» (menu do som da barra de menus,
// com o Música a tocar para eles); o vigia, mais abaixo, avisa se não estiverem.

static void ZPAvisar(NSString *titulo, NSString *texto) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kZPAudioCaptureWarningNotification
                                                            object:nil
                                                          userInfo:@{ @"titulo": titulo ?: @"",
                                                                      @"texto":  texto  ?: @"" }];
    });
}

static NSString *ZPNomeDoDispositivo(AudioObjectID dispositivo) {
    CFStringRef nome = NULL;
    UInt32 tamanho = sizeof(nome);
    AudioObjectPropertyAddress endereco = { kAudioObjectPropertyName,
                                            kAudioObjectPropertyScopeGlobal,
                                            kAudioObjectPropertyElementMain };
    if (AudioObjectGetPropertyData(dispositivo, &endereco, 0, NULL, &tamanho, &nome) != noErr || !nome) {
        return @"?";
    }
    return (__bridge_transfer NSString *)nome;
}

// Para onde o Música está a tocar: os dispositivos de saída do processo, e se
// algum deles é Bluetooth (os AirPods). Vazio se o Música ainda não abriu a
// saída — em pausa desde que arrancou, por exemplo.
static NSArray<NSString *> *ZPSaidasDoProcesso(AudioObjectID processo, BOOL *haBluetooth) {
    *haBluetooth = NO;
    AudioObjectPropertyAddress endereco = { kAudioProcessPropertyDevices,
                                            kAudioObjectPropertyScopeOutput,
                                            kAudioObjectPropertyElementMain };
    UInt32 tamanho = 0;
    if (AudioObjectGetPropertyDataSize(processo, &endereco, 0, NULL, &tamanho) != noErr || tamanho == 0) {
        return @[];
    }
    UInt32 n = tamanho / sizeof(AudioObjectID);
    AudioObjectID dispositivos[n];
    if (AudioObjectGetPropertyData(processo, &endereco, 0, NULL, &tamanho, dispositivos) != noErr) {
        return @[];
    }
    NSMutableArray<NSString *> *nomes = [NSMutableArray array];
    for (UInt32 i = 0; i < n; ++i) {
        UInt32 transporte = 0, t = sizeof(transporte);
        AudioObjectPropertyAddress ta = { kAudioDevicePropertyTransportType,
                                          kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain };
        AudioObjectGetPropertyData(dispositivos[i], &ta, 0, NULL, &t, &transporte);
        if (transporte == kAudioDeviceTransportTypeBluetooth || transporte == kAudioDeviceTransportTypeBluetoothLE) {
            *haBluetooth = YES;
        }
        [nomes addObject:ZPNomeDoDispositivo(dispositivos[i])];
    }
    return nomes;
}

// Corre no thread de tempo real do agregado. Copia o par estéreo intercalado e
// passa-o à ioQueue, como o tap do AVAudioEngine faz no outro caminho.
static OSStatus ZPIOProcMusica(AudioObjectID dispositivo, const AudioTimeStamp *agora,
                               const AudioBufferList *entrada, const AudioTimeStamp *instanteEntrada,
                               AudioBufferList *saida, const AudioTimeStamp *instanteSaida,
                               void *cliente) {
    if (!entrada || entrada->mNumberBuffers == 0) return noErr;
    ZPAudioCapture *eu = (__bridge ZPAudioCapture *)cliente;

    // O tap é uma mistura estéreo, normalmente num só tampão intercalado. Os
    // outros arranjos ficam cobertos: dois tampões separados, ou mono.
    const AudioBuffer *b0 = &entrada->mBuffers[0];
    UInt32 canais0 = b0->mNumberChannels ?: 1;
    UInt32 tramas = b0->mDataByteSize / (UInt32)(sizeof(float) * canais0);
    if (tramas == 0 || !b0->mData) return noErr;

    NSMutableData *par = [NSMutableData dataWithLength:tramas * 2 * sizeof(float)];
    float *d = par.mutableBytes;
    const float *x0 = b0->mData;
    if (canais0 >= 2) {
        for (UInt32 i = 0; i < tramas; ++i) { d[2*i] = x0[i*canais0]; d[2*i+1] = x0[i*canais0 + 1]; }
    } else if (entrada->mNumberBuffers >= 2 && entrada->mBuffers[1].mData) {
        const float *x1 = entrada->mBuffers[1].mData;
        for (UInt32 i = 0; i < tramas; ++i) { d[2*i] = x0[i]; d[2*i+1] = x1[i]; }
    } else {
        for (UInt32 i = 0; i < tramas; ++i) { d[2*i] = d[2*i+1] = x0[i]; }
    }

    dispatch_async(eu.ioQueue, ^{
        NSFileHandle *handle = eu.recordFileHandle;
        if (!handle) return;
        NSError *erro = nil;
        if (![handle writeData:par error:&erro]) {
            #ifdef DEBUG
            NSLog(@"[Audio Capture] Erro a escrever no ficheiro: %@", erro.localizedDescription);
            #endif
            return;
        }
        eu.recordDataBytes += par.length;
        [eu vigiarAmostras:par.bytes tramas:tramas];
    });
    return noErr;
}

- (BOOL)iniciarCapturaDoMusica {
    // A autorização para gravar o áudio de outras apps pede-se com esta chave;
    // sem ela o tap não traz nada, ou nem se cria.
    if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSAudioCaptureUsageDescription"]) {
        NSLog(@"[Audio Capture] Falta NSAudioCaptureUsageDescription no Info.plist.");
        ZPAvisar(NSLocalizedString(@"rec_music_failed_title", @"Não foi possível gravar o Música"),
                 NSLocalizedString(@"rec_music_failed_text", @"Ver a permissão de gravação de áudio"));
        return NO;
    }

    NSRunningApplication *musica =
        [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.Music"].firstObject;

    AudioObjectID processo = kAudioObjectUnknown;
    if (musica) {
        pid_t pid = musica.processIdentifier;
        UInt32 tamanho = sizeof(processo);
        AudioObjectPropertyAddress endereco = { kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                kAudioObjectPropertyScopeGlobal,
                                                kAudioObjectPropertyElementMain };
        AudioObjectGetPropertyData(kAudioObjectSystemObject, &endereco, sizeof(pid), &pid, &tamanho, &processo);
    }
    // O Música só aparece ao CoreAudio depois de ter tocado alguma coisa.
    if (processo == kAudioObjectUnknown) {
        ZPAvisar(NSLocalizedString(@"rec_music_absent_title", @"O Música não está a tocar"),
                 NSLocalizedString(@"rec_music_absent_text", @"Abrir o Música e pôr a tocar"));
        return NO;
    }

    // Mistura estéreo do processo, e não o tap preso a um dispositivo: assim a
    // gravação continua se o Música mudar de saída a meio.
    CATapDescription *descricao = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(processo)]];
    descricao.name = @"tocaTintas";
    descricao.privateTap = YES;

    AudioObjectID tap = kAudioObjectUnknown;
    OSStatus estado = AudioHardwareCreateProcessTap(descricao, &tap);
    if (estado != noErr) {
        NSLog(@"[Audio Capture] AudioHardwareCreateProcessTap falhou (%d).", (int)estado);
        ZPAvisar(NSLocalizedString(@"rec_music_failed_title", @"Não foi possível gravar o Música"),
                 NSLocalizedString(@"rec_music_failed_text", @"Ver a permissão de gravação de áudio"));
        return NO;
    }

    AudioStreamBasicDescription formato = {0};
    UInt32 tamanho = sizeof(formato);
    AudioObjectPropertyAddress fa = { kAudioTapPropertyFormat,
                                      kAudioObjectPropertyScopeGlobal,
                                      kAudioObjectPropertyElementMain };
    AudioObjectGetPropertyData(tap, &fa, 0, NULL, &tamanho, &formato);

    // Um tap não se lê sozinho: entra como sub-tap de um agregado privado, que
    // só existe enquanto se grava e não aparece a mais ninguém.
    NSDictionary *agregado = @{
        @kAudioAggregateDeviceNameKey:         @"tocaTintas — Música",
        @kAudioAggregateDeviceUIDKey:          [NSUUID UUID].UUIDString,
        @kAudioAggregateDeviceIsPrivateKey:    @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @YES,
        @kAudioAggregateDeviceTapListKey:      @[ @{ @kAudioSubTapUIDKey: descricao.UUID.UUIDString } ],
    };
    AudioObjectID dispositivo = kAudioObjectUnknown;
    estado = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)agregado, &dispositivo);
    AudioDeviceIOProcID ioProc = NULL;
    if (estado == noErr) {
        estado = AudioDeviceCreateIOProcID(dispositivo, ZPIOProcMusica, (__bridge void *)self, &ioProc);
    }
    if (estado == noErr) {
        // Os campos lêem-se na ioQueue (o cabeçalho, o vigia); escrevem-se lá
        // também, antes de chegar a primeira amostra.
        double taxa = formato.mSampleRate > 0 ? formato.mSampleRate : 48000.0;
        dispatch_sync(self.ioQueue, ^{
            self.recordSampleRate = taxa;
            self.recordChannels = 2;
            memset(&self->_vigia, 0, sizeof(self->_vigia));
        });
        estado = AudioDeviceStart(dispositivo, ioProc);
    }
    if (estado != noErr) {
        NSLog(@"[Audio Capture] Agregado do tap do Música falhou (%d).", (int)estado);
        if (ioProc) AudioDeviceDestroyIOProcID(dispositivo, ioProc);
        if (dispositivo != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(dispositivo);
        AudioHardwareDestroyProcessTap(tap);
        ZPAvisar(NSLocalizedString(@"rec_music_failed_title", @"Não foi possível gravar o Música"),
                 NSLocalizedString(@"rec_music_failed_text", @"Ver a permissão de gravação de áudio"));
        return NO;
    }

    self.tapMusica = tap;
    self.agregadoMusica = dispositivo;
    self.ioProcMusica = ioProc;

    NSLog(@"[Audio Capture] A gravar do Música: %.0f Hz, %u canais no tap.",
          formato.mSampleRate, (unsigned)formato.mChannelsPerFrame);

    // Fora dos AirPods não há binaural: grava-se, mas diz-se o que se está a
    // gravar. Sem saída aberta (o Música em pausa) não se sabe, e cala-se.
    BOOL haBluetooth = NO;
    NSArray<NSString *> *saidas = ZPSaidasDoProcesso(processo, &haBluetooth);
    if (saidas.count > 0 && !haBluetooth) {
        ZPAvisar(NSLocalizedString(@"rec_music_not_headphones_title", @"Isto não é o binaural do Atmos"),
                 [NSString stringWithFormat:NSLocalizedString(@"rec_music_not_headphones_text", @"O Música toca para «%@»"),
                  [saidas componentsJoinedByString:@", "]]);
    }

    [self comecarAVigiarACabeca];
    return YES;
}

- (void)pararCapturaDoMusica {
    [self.movimentoCabeca stopDeviceMotionUpdates];
    self.movimentoCabeca = nil;

    // AudioDeviceStop só volta quando o IOProc já não corre: depois disto não
    // entra mais nada na ioQueue.
    if (self.agregadoMusica != kAudioObjectUnknown) {
        AudioDeviceStop(self.agregadoMusica, self.ioProcMusica);
        AudioDeviceDestroyIOProcID(self.agregadoMusica, self.ioProcMusica);
        AudioHardwareDestroyAggregateDevice(self.agregadoMusica);
    }
    if (self.tapMusica != kAudioObjectUnknown) {
        AudioHardwareDestroyProcessTap(self.tapMusica);
    }
    self.agregadoMusica = kAudioObjectUnknown;
    self.tapMusica = kAudioObjectUnknown;
    self.ioProcMusica = NULL;
}

#pragma mark - Vigia do seguimento da cabeça

// Não há maneira de ler se os AirPods estão em «Fixo»: a escolha é guardada
// pelo sistema, fora do alcance das apps. Infere-se do efeito. Com o
// seguimento ligado, rodar a cabeça desloca o som para o lado contrário — à
// esquerda, o direito sobe — e a gravação apanha-o: medido, uns 2,5 dB de
// diferença entre os canais por cada 90°. Em «Fixo», o equilíbrio fica onde a
// música o põe, rode a cabeça o que rodar.
//
// Por isso: guinada da cabeça (CoreMotion) e equilíbrio esquerdo−direito, em
// janelas de meio segundo. Com a cabeça a ter rodado pelo menos 45° nos
// últimos 20 s, se o equilíbrio a acompanhar de perto (correlação de 0,7 ou
// mais) e se mexer pelo menos 1,5 dB, há seguimento — avisa-se uma vez por
// gravação. Sem a cabeça a mexer não há nada para medir, mas também não há
// estrago: é precisamente o movimento que fica gravado.

- (void)comecarAVigiarACabeca {
    // Sem esta chave no Info.plist, o CoreMotion termina a app ao pedir a
    // autorização. Sem ela grava-se na mesma; só não há vigia.
    if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSMotionUsageDescription"]) {
        NSLog(@"[Audio Capture] Falta NSMotionUsageDescription no Info.plist: sem vigia do seguimento da cabeça.");
        return;
    }
    CMHeadphoneMotionManager *movimento = [[CMHeadphoneMotionManager alloc] init];
    if (!movimento.isDeviceMotionAvailable
        || CMHeadphoneMotionManager.authorizationStatus == CMAuthorizationStatusDenied
        || CMHeadphoneMotionManager.authorizationStatus == CMAuthorizationStatusRestricted) {
        return;
    }
    self.movimentoCabeca = movimento;

    NSOperationQueue *fila = [[NSOperationQueue alloc] init];
    fila.maxConcurrentOperationCount = 1;
    __weak typeof(self) fraco = self;
    [movimento startDeviceMotionUpdatesToQueue:fila withHandler:^(CMDeviceMotion *dados, NSError *erro) {
        if (!dados) return;
        double bruta = dados.attitude.yaw;
        __strong typeof(fraco) forte = fraco;
        if (!forte) return;
        dispatch_async(forte.ioQueue, ^{
            ZPVigiaCabeca *v = &forte->_vigia;
            if (!v->haCabeca) {
                v->guinada = bruta * 180.0 / M_PI;
                v->haCabeca = YES;
            } else {
                // Desenrolar: a guinada salta de +π para −π ao passar para trás.
                double passo = bruta - v->guinadaBruta;
                if (passo >  M_PI) passo -= 2 * M_PI;
                if (passo < -M_PI) passo += 2 * M_PI;
                v->guinada += passo * 180.0 / M_PI;
            }
            v->guinadaBruta = bruta;
            v->activo = YES;
        });
    }];
}

// Na ioQueue, com cada bloco que entrou no ficheiro.
- (void)vigiarAmostras:(const float *)par tramas:(UInt32)tramas {
    ZPVigiaCabeca *v = &_vigia;
    if (!v->activo || v->avisado) return;

    for (UInt32 i = 0; i < tramas; ++i) {
        v->somaEsq += (double)par[2*i]   * par[2*i];
        v->somaDir += (double)par[2*i+1] * par[2*i+1];
    }
    v->tramas += tramas;
    if (v->tramas < (unsigned long long)(self.recordSampleRate * 0.5)) return;

    // Fecha-se a janela. As silenciosas (abaixo de −60 dBFS) não contam: o
    // equilíbrio de quase nada é ruído.
    double mediaEsq = v->somaEsq / v->tramas, mediaDir = v->somaDir / v->tramas;
    v->somaEsq = v->somaDir = 0;
    v->tramas = 0;
    if (!v->haCabeca || (mediaEsq + mediaDir) / 2 < 1e-6) return;

    v->guinadas[v->proxima] = v->guinada;
    v->equilibrios[v->proxima] = 10.0 * log10((mediaEsq + 1e-12) / (mediaDir + 1e-12));
    v->proxima = (v->proxima + 1) % kZPJanelasVigia;
    if (v->n < kZPJanelasVigia) v->n++;
    if (v->n < 8) return;

    double mg = 0, me = 0, gMin = 1e9, gMax = -1e9;
    for (int i = 0; i < v->n; ++i) {
        mg += v->guinadas[i];
        me += v->equilibrios[i];
        gMin = fmin(gMin, v->guinadas[i]);
        gMax = fmax(gMax, v->guinadas[i]);
    }
    mg /= v->n;
    me /= v->n;
    if (gMax - gMin < 45.0) return;

    double sgg = 0, see = 0, sge = 0;
    for (int i = 0; i < v->n; ++i) {
        double g = v->guinadas[i] - mg, e = v->equilibrios[i] - me;
        sgg += g * g;
        see += e * e;
        sge += g * e;
    }
    if (sgg <= 0 || see <= 0) return;
    double r = sge / sqrt(sgg * see);
    double variacao = fabs(sge / sgg) * (gMax - gMin);   // dB que a cabeça explica
    if (fabs(r) < 0.7 || variacao < 1.5) return;

    v->avisado = YES;
    NSLog(@"[Audio Capture] Seguimento da cabeça na gravação: r = %.2f, %.1f dB em %.0f°.",
          r, variacao, gMax - gMin);
    ZPAvisar(NSLocalizedString(@"rec_head_tracking_title", @"O seguimento da cabeça está a ficar gravado"),
             NSLocalizedString(@"rec_head_tracking_text", @"Pôr o áudio espacial em Fixo"));
}

#pragma mark - Audio Capture Management

- (void)startAudioCapture {
    // If the audio engine is already running, no need to reinstall the tap
    if (self.audioEngine.isRunning) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio engine is already running.");
        #endif
        return;
    }

    [self installAudioTap];

    NSError *engineError = nil;
    if (![self.audioEngine startAndReturnError:&engineError]) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Error starting audio engine: %@", engineError.localizedDescription);
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio capturing started.");
        #endif
    }
}

- (void)stopAudioCapture {
    if (self.engineConfigObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.engineConfigObserver];
        self.engineConfigObserver = nil;
    }
    if (self.audioEngine.isRunning) {
        [self.audioEngine.inputNode removeTapOnBus:0];
        [self.audioEngine stop];
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio engine stopped.");
        #endif
    }
}

- (void)installAudioTap {
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;

    // Antes de ler o formato: a entrada é o BlackHole, não o que o sistema
    // tiver como dispositivo por omissão. Repete-se aqui e não só no arranque
    // porque este método volta a correr a cada reconfiguração de áudio.
    ZPBindEngineInputToLoopback(self.audioEngine);

    // Remover um tap anterior antes de instalar: instalar por cima de um tap
    // existente lança excepção, e este método volta a correr sempre que o
    // dispositivo de áudio muda (ver o observador mais abaixo) — trocar de
    // saída a meio de uma gravação passava por aqui.
    [inputNode removeTapOnBus:0];

    AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];

    if (!inputFormat || inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Formato de entrada inválido: %.0f Hz, %u canais.",
              inputFormat.sampleRate, inputFormat.channelCount);
        #endif
        return;
    }

    // Grava-se em vírgula flutuante de 32 bits, à frequência do próprio
    // dispositivo.
    //
    // Porquê: com o volume de saída a 25 %, o sinal chega ao tap a −12 dB e
    // ocupa só um quarto da escala. Passá-lo a Int16 aí atirava fora dois bits
    // de resolução, que nenhuma normalização posterior no Audacity recupera —
    // amplificar depois é amplificar também o ruído de quantização já gravado.
    // Em float de 32 bits a atenuação não custa resolução nenhuma (são 24 bits
    // de mantissa a acompanhar o expoente), e a normalização passa a ser
    // exacta. Manter a frequência do dispositivo evita ainda a reamostragem.
    AVAudioFormat *recordFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                   sampleRate:inputFormat.sampleRate
                                                                     channels:2
                                                                  interleaved:YES];

    self.recordConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:recordFormat];
    // Com o BlackHole de 16 canais, disposição discreta: sem mapa o conversor
    // não acha «esquerdo» nem «direito» e grava silêncio. Ver a mesma nota no
    // ZPAirPlayStreamer.
    if (inputFormat.channelCount > 2) {
        self.recordConverter.channelMap = @[@0, @1];
    }
    self.recordBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:recordFormat frameCapacity:8192];

    __weak typeof(self) weakSelf = self;

    if (self.engineConfigObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:self.engineConfigObserver];
    }
    self.engineConfigObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:self.audioEngine
                     queue:nil
                usingBlock:^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.isRecording) return;
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Reconfiguração do engine detectada — a reinstalar tap.");
        #endif
        [strongSelf installAudioTap];
        NSError *engineError = nil;
        if (![strongSelf.audioEngine startAndReturnError:&engineError]) {
            #ifdef DEBUG
            NSLog(@"[Audio Capture] Erro ao reiniciar engine após reconfiguração: %@", engineError.localizedDescription);
            #endif
        }
    }];

    // A versão sem «error:» ficou obsoleta no macOS 27, e a nova é melhor do que
    // uma simples troca de nome: a antiga falhava com excepção, esta diz o que
    // correu mal e deixa-nos registá-lo.
    NSError *erroDoTap = nil;
    BOOL tapInstalado = [inputNode installTapOnBus:0
                                        bufferSize:4096
                                            format:inputFormat
                                             error:&erroDoTap
                                             block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isRecording || buffer.frameLength == 0) {
            return;
        }

        NSError *recError = nil;
        [strongSelf.recordConverter convertToBuffer:strongSelf.recordBuffer fromBuffer:buffer error:&recError];
        if (recError) {
            #ifdef DEBUG
            NSLog(@"[Audio Capture] Erro a converter para float: %@", recError.localizedDescription);
            #endif
            return;
        }

        // A frequência e o número de canais do ficheiro são os do primeiro
        // bloco que entrar; é com eles que o cabeçalho é escrito no fim.
        if (strongSelf.recordSampleRate <= 0.0) {
            strongSelf.recordSampleRate = strongSelf.recordConverter.outputFormat.sampleRate;
            strongSelf.recordChannels   = strongSelf.recordConverter.outputFormat.channelCount;
        }

        NSUInteger recLength = strongSelf.recordBuffer.frameLength
                               * strongSelf.recordConverter.outputFormat.streamDescription->mBytesPerFrame;
        // Copiar os bytes antes de sair do thread de áudio
        NSData *floatData = [NSData dataWithBytes:strongSelf.recordBuffer.floatChannelData[0]
                                           length:recLength];

        dispatch_async(strongSelf.ioQueue, ^{
            // O descritor é posto a nil no -finalizeRecordingFile, nesta mesma
            // fila em série: o que chegue depois disso vem tarde.
            NSFileHandle *handle = strongSelf.recordFileHandle;
            if (!handle) return;

            NSError *writeError = nil;
            if (![handle writeData:floatData error:&writeError]) {
                #ifdef DEBUG
                NSLog(@"[Audio Capture] Erro a escrever no ficheiro: %@", writeError.localizedDescription);
                #endif
                return;
            }
            strongSelf.recordDataBytes += floatData.length;
        });
    }];

    if (!tapInstalado) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Não foi possível instalar o tap: %@", erroDoTap.localizedDescription);
        #endif
    }
}

- (void)dealloc {
    if (_engineConfigObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_engineConfigObserver];
    }
}

@end
