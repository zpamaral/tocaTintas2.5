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

// RIFF (12) + fmt  (24) + fact (12) + cabeçalho de data (8). O troço «fact» é
// exigido pela norma para formatos que não sejam PCM inteiro; sem ele há
// leitores esquisitos que recusam WAV de vírgula flutuante.
enum { kZPWavHeaderSize = 56 };   // constante de compilação: serve de dimensão do vector

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

// Streaming properties
@property (strong, nonatomic) NSTask *raopTask;
@property (strong, nonatomic) NSPipe *inputPipe;
@property (assign, nonatomic) BOOL isStreaming;
@property (strong, nonatomic) NSString *ipAddress;
@property (strong, nonatomic) NSString *port;

// Gain adjustment
@property (assign, nonatomic) float gainFactor;

// Reutilizados entre callbacks (criados uma vez por tap)
@property (strong, nonatomic) AVAudioConverter *audioConverter;      // Int16, para o AirPlay
@property (strong, nonatomic) AVAudioPCMBuffer *convertedBuffer;
@property (strong, nonatomic) AVAudioConverter *recordConverter;     // float de 32 bits, para o ficheiro
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
        _isStreaming = NO;
        _gainFactor = 1.0; // Default gain factor (no gain adjustment)
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

    // Sem ganho na gravação. O ganho fixo de +6 dB que aqui estava só fazia
    // sentido enquanto se gravava em Int16, para aproveitar escala; agora que o
    // ficheiro é de vírgula flutuante não há escala a aproveitar e o ganho só
    // arriscava ceifar picos. Quem normaliza é o Audacity, sem perdas.
    self.gainFactor = 1.0;

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
    [self startOrUpdateAudioCapture];
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

    // Stop audio capture if not streaming
    [self stopAudioCaptureIfNeeded];
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

#pragma mark - Streaming Methods

- (void)startStreamingToIPAddress:(NSString *)ipAddress port:(NSString *)port {
    if (self.isStreaming) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Already streaming.");
        #endif
        return;
    }

    self.isStreaming = YES;
    self.ipAddress = ipAddress;
    self.port = port;

    // Set up the pipe to connect to raop_play's standard input
    self.inputPipe = [NSPipe pipe];

    // Start raop_play as a subprocess
    self.raopTask = [[NSTask alloc] init];
    NSString *raopPlayPath = [[NSBundle mainBundle] pathForResource:@"raop_play" ofType:nil];
    self.raopTask.launchPath = raopPlayPath;

    self.raopTask.arguments = @[
        @"-a", self.ipAddress,
        @"-p", self.port,
        @"-"
    ];

    self.raopTask.standardInput = self.inputPipe;
    self.raopTask.standardOutput = [NSPipe pipe]; // Optional
    self.raopTask.standardError = [NSPipe pipe];  // Optional

    // Launch raop_play
    [self.raopTask launch];

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Streaming started to %@:%@", self.ipAddress, self.port);
    #endif

    // Start or update audio capture
    [self startOrUpdateAudioCapture];
}

- (void)stopStreaming {
    if (!self.isStreaming) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Streaming is not running.");
        #endif
        return;
    }

    self.isStreaming = NO;

    // Close pipe and terminate raop_play
    if (self.inputPipe && self.inputPipe.fileHandleForWriting) {
        [self.inputPipe.fileHandleForWriting closeFile];
        self.inputPipe = nil;
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Input pipe closed.");
        #endif
    }

    if (self.raopTask) {
        [self.raopTask terminate];
        self.raopTask = nil;
        #ifdef DEBUG
        NSLog(@"[Audio Capture] RAOP task terminated.");
        #endif
    }

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Streaming stopped.");
    #endif

    // Stop audio capture if not recording
    [self stopAudioCaptureIfNeeded];
}

#pragma mark - Audio Capture Management

- (void)startOrUpdateAudioCapture {
    // If the audio engine is already running, no need to reinstall the tap
    if (self.audioEngine.isRunning) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio engine is already running.");
        #endif
        return;
    }

    // Install the audio tap
    [self installAudioTap];

    // Start the audio engine
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

- (void)stopAudioCaptureIfNeeded {
    // Stop the audio engine if neither recording nor streaming is active
    if (!self.isRecording && !self.isStreaming) {
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
    } else {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio engine continues running (recording or streaming is active).");
        #endif
    }
}

- (void)installAudioTap {
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];

    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                   sampleRate:44100.0
                                                                     channels:2
                                                                  interleaved:YES];

    self.audioConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];
    // 8192 frames cobre o pior caso de upsampling (ex.: entrada a 32 kHz → saída a 44,1 kHz)
    self.convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat frameCapacity:8192];

    // A gravação segue por um caminho próprio, em vírgula flutuante de 32 bits
    // e à frequência do próprio dispositivo.
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
        if (!strongSelf.isRecording && !strongSelf.isStreaming) return;
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
        if (!strongSelf) return;

        if (buffer.frameLength > 0) {
            // A gravação leva o sinal tal como chegou: converte-se antes de
            // qualquer ganho, para o ficheiro ficar com o original.
            if (strongSelf.isRecording) {
                NSError *recError = nil;
                [strongSelf.recordConverter convertToBuffer:strongSelf.recordBuffer fromBuffer:buffer error:&recError];
                if (recError) {
                    #ifdef DEBUG
                    NSLog(@"[Audio Capture] Erro a converter para float: %@", recError.localizedDescription);
                    #endif
                } else {
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
                        // O descritor é posto a nil no -finalizeRecordingFile,
                        // nesta mesma fila: o que chegue depois disso é tarde.
                        NSFileHandle *handle = strongSelf.recordFileHandle;
                        if (!handle) return;
                        NSError *writeError = nil;
                        if (![handle writeData:floatData error:&writeError]) {
                            #ifdef DEBUG
                            NSLog(@"[Audio Capture] Error writing to file: %@", writeError.localizedDescription);
                            #endif
                            return;
                        }
                        strongSelf.recordDataBytes += floatData.length;
                    });
                }
            }

            if (!strongSelf.isStreaming) {
                return;
            }

            // Daqui para baixo é o caminho do AirPlay, que continua em Int16.
            if (strongSelf.gainFactor != 1.0) {
                for (AVAudioChannelCount channel = 0; channel < buffer.format.channelCount; channel++) {
                    float *channelData = buffer.floatChannelData[channel];
                    for (AVAudioFrameCount frame = 0; frame < buffer.frameLength; frame++) {
                        channelData[frame] *= strongSelf.gainFactor;
                        // As amostras vêm normalizadas a ±1,0, não em contagens
                        // de Int16: o limite de antes (±32768) nunca pegava.
                        if (channelData[frame] >  1.0f) channelData[frame] =  1.0f;
                        if (channelData[frame] < -1.0f) channelData[frame] = -1.0f;
                    }
                }
            }

            NSError *error = nil;
            [strongSelf.audioConverter convertToBuffer:strongSelf.convertedBuffer fromBuffer:buffer error:&error];
            if (error) {
                #ifdef DEBUG
                NSLog(@"[Audio Capture] Error converting audio buffer: %@", error.localizedDescription);
                #endif
                return;
            }

            // Copiar os bytes antes de sair do thread de áudio
            NSUInteger dataLength = strongSelf.convertedBuffer.frameLength
                                    * strongSelf.audioConverter.outputFormat.streamDescription->mBytesPerFrame;
            NSData *pcmData = [NSData dataWithBytes:strongSelf.convertedBuffer.int16ChannelData[0]
                                             length:dataLength];

            dispatch_async(strongSelf.ioQueue, ^{
                if (strongSelf.inputPipe) {
                    [[strongSelf.inputPipe fileHandleForWriting] writeData:pcmData];
                }
            });
        }
    }];
}

#pragma mark - Gain Adjustment

- (void)setGainInDecibels:(float)gainInDb {
    // Convert dB gain to linear scale factor
    self.gainFactor = powf(10.0, gainInDb / 20.0);
    #ifdef DEBUG
    NSLog(@"[Audio Capture] Gain factor set to %.2f for %.2f dB gain.", self.gainFactor, gainInDb);
    #endif
}

@end
