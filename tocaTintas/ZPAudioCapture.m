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
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

// RIFF (12) + fmt  (24) + fact (12) + cabeçalho de data (8). O troço «fact» é
// exigido pela norma para formatos que não sejam PCM inteiro; sem ele há
// leitores esquisitos que recusam WAV de vírgula flutuante.
enum { kZPWavHeaderSize = 56 };   // constante de compilação: serve de dimensão do vector

// Substring do nome do dispositivo de loopback. É o mesmo BlackHole para onde a
// saída do sistema aponta; o nome exacto («BlackHole 2ch») pode mudar com a
// versão, daí procurar-se por pedaço.
static NSString * const kZPLoopbackNameSubstring = @"BlackHole";

// Procura o dispositivo de loopback entre os que têm entrada estéreo.
static AudioDeviceID ZPLoopbackInputDevice(void) {
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

    AudioDeviceID dispositivo = ZPLoopbackInputDevice();
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

@end

@implementation ZPAudioCapture

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
- (void)startCapturingAudio {
    [self startRecording];
}

// Stop capturing audio (alias for stopRecording)
- (void)stopCapturingAudio {
    [self stopRecording];
}

#pragma mark - Recording Methods

- (void)startRecording {
    if (self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Already recording.");
        #endif
        return;
    }

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
    NSString *fileName = [NSString stringWithFormat:@"Recording_%@.wav", [[NSUUID UUID] UUIDString]];
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
        return;
    }

    NSError *handleError = nil;
    self.recordFileHandle = [NSFileHandle fileHandleForWritingToURL:outputFileURL error:&handleError];
    if (!self.recordFileHandle) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Não consegui abrir %@: %@", [outputFileURL path], handleError.localizedDescription);
        #endif
        self.isRecording = NO;
        return;
    }
    [self.recordFileHandle seekToEndOfFile];

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Recording started. Saving to %@", [outputFileURL path]);
    #endif

    // Start or update audio capture
    [self startAudioCapture];
}

- (void)stopRecording {
    if (!self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Recording is not running.");
        #endif
        return;
    }

    self.isRecording = NO;

    // O fecho vai para a fila de I/O, atrás de tudo o que já lá esteja: é uma
    // fila em série, portanto as últimas amostras entram no ficheiro antes de
    // o cabeçalho ser escrito e o descritor fechado.
    if (self.recordFileHandle) {
        dispatch_async(self.ioQueue, ^{
            [self finalizeRecordingFile];
        });
    }

    [self stopAudioCapture];
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

    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:inputFormat
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
}

- (void)dealloc {
    if (_engineConfigObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_engineConfigObserver];
    }
}

@end
