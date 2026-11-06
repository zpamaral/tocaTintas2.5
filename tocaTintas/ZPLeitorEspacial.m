//
//  ZPLeitorEspacial.m
//  tocaTintas
//
//  Ver ZPLeitorEspacial.h.
//
//  Descodifica com o ExtAudioFile — a partir dos bytes adiantados em memória,
//  quando os há, ou do ficheiro — para PCM em vírgula flutuante entrelaçado, e
//  entrega-o ao renderer em blocos de 8192 tramas marcados com a disposição de
//  canais (estéreo, mono, ou a do ficheiro). O relógio é o do sincronizador; a
//  posição de cada bloco é o número da trama a dividir pela frequência, por isso
//  saltar é só ir ao ExtAudioFile, esvaziar o renderer e acertar o relógio.
//

#import "ZPLeitorEspacial.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <CoreMedia/CoreMedia.h>

static const UInt32 kZPTramasPorBloco = 8192;
static const double kZPSegundosDeArranque = 0.5;   // o que se põe na fila antes de o relógio andar

BOOL ZPSaidaEBluetooth(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev) != noErr
        || dev == kAudioObjectUnknown) {
        return NO;
    }
    UInt32 transporte = 0;
    size = sizeof(transporte);
    addr.mSelector = kAudioDevicePropertyTransportType;
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &transporte) != noErr) {
        return NO;
    }
    return transporte == kAudioDeviceTransportTypeBluetooth || transporte == kAudioDeviceTransportTypeBluetoothLE;
}

// O identificador (UID) do BlackHole, para o espelho do cava. nil se não houver.
static NSString *ZPUIDDoBlackHole(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || size == 0) return nil;
    AudioObjectID *ids = malloc(size);
    if (!ids) return nil;
    NSString *uid = nil;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, ids) == noErr) {
        for (UInt32 i = 0; i < size / sizeof(AudioObjectID) && !uid; ++i) {
            CFStringRef nome = NULL;
            UInt32 t = sizeof(nome);
            AudioObjectPropertyAddress a = {
                kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
            };
            if (AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &t, &nome) != noErr || !nome) continue;
            BOOL eBlackHole = [(__bridge NSString *)nome rangeOfString:@"BlackHole" options:NSCaseInsensitiveSearch].location != NSNotFound;
            CFRelease(nome);
            if (!eBlackHole) continue;
            CFStringRef u = NULL;
            t = sizeof(u);
            a.mSelector = kAudioDevicePropertyDeviceUID;
            if (AudioObjectGetPropertyData(ids[i], &a, 0, NULL, &t, &u) == noErr && u) uid = CFBridgingRelease(u);
        }
    }
    free(ids);
    return uid;
}

#pragma mark - Leitura a partir de memória

static OSStatus ZPLerMemoria(void *dados, SInt64 posicao, UInt32 pedido, void *destino, UInt32 *lido) {
    NSData *d = (__bridge NSData *)dados;
    if (posicao < 0 || posicao >= (SInt64)d.length) { *lido = 0; return posicao < 0 ? kAudioFilePositionError : noErr; }
    UInt32 n = (UInt32)MIN((SInt64)pedido, (SInt64)d.length - posicao);
    memcpy(destino, (const uint8_t *)d.bytes + posicao, n);
    *lido = n;
    return noErr;
}

static SInt64 ZPTamanhoMemoria(void *dados) {
    return (SInt64)((__bridge NSData *)dados).length;
}

#pragma mark -

@interface ZPLeitorEspacial ()
@property (strong, nonatomic) AVSampleBufferAudioRenderer *renderer;
// O mesmo som para o BlackHole, onde o cava o lê para o histograma. Com os
// AirPods a saída do sistema não é o BlackHole e a ponte está parada; sem isto o
// histograma ficava vazio. Partilha o relógio do sincronizador, que compensa a
// latência de cada saída, por isso o histograma acompanha o que se ouve.
@property (strong, nonatomic, nullable) AVSampleBufferAudioRenderer *espelho;
@property (strong, nonatomic) AVSampleBufferRenderSynchronizer *sincronizador;
@property (strong, nonatomic) dispatch_queue_t fila;      // tudo o que toca no ExtAudioFile corre aqui
@property (strong, nonatomic, nullable) NSData *bytes;    // mantém viva a memória do AudioFile
@property (strong, nonatomic, nullable) id observadorDoFim;
@end

@implementation ZPLeitorEspacial {
    AudioFileID _ficheiro;          // só com bytes em memória
    ExtAudioFileRef _descodificador;
    AudioStreamBasicDescription _formato;   // PCM float32 entrelaçado
    AudioChannelLayout *_disposicao;
    UInt32 _tamanhoDisposicao;
    SInt64 _proximaTrama;           // a próxima a pôr na fila (fila)
    SInt64 _totalDeTramas;
    BOOL _descodificacaoAcabou;     // (fila)
    BOOL _arrancou;
    BOOL _terminou;
    float *_bloco;
}

- (nullable instancetype)initWithData:(NSData *)data error:(NSError **)outError {
    self = [super initWithData:data error:outError];
    if (!self) return nil;
    _bytes = data;
    OSStatus s = AudioFileOpenWithCallbacks((__bridge void *)_bytes, ZPLerMemoria, NULL, ZPTamanhoMemoria, NULL, 0, &_ficheiro);
    if (s == noErr) s = ExtAudioFileWrapAudioFileID(_ficheiro, false, &_descodificador);
    return [self prepararComEstado:s erro:outError] ? self : nil;
}

- (nullable instancetype)initWithContentsOfURL:(NSURL *)url error:(NSError **)outError {
    self = [super initWithContentsOfURL:url error:outError];
    if (!self) return nil;
    OSStatus s = ExtAudioFileOpenURL((__bridge CFURLRef)url, &_descodificador);
    return [self prepararComEstado:s erro:outError] ? self : nil;
}

// Formato do cliente, disposição de canais, renderer e sincronizador.
- (BOOL)prepararComEstado:(OSStatus)s erro:(NSError **)outError {
    AudioStreamBasicDescription doFicheiro = {0};
    UInt32 size = sizeof(doFicheiro);
    if (s == noErr) s = ExtAudioFileGetProperty(_descodificador, kExtAudioFileProperty_FileDataFormat, &size, &doFicheiro);
    if (s == noErr) {
        UInt32 canais = MAX(doFicheiro.mChannelsPerFrame, 1u);
        _formato = (AudioStreamBasicDescription){
            .mSampleRate = doFicheiro.mSampleRate,
            .mFormatID = kAudioFormatLinearPCM,
            .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            .mBytesPerPacket = 4 * canais, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * canais,
            .mChannelsPerFrame = canais, .mBitsPerChannel = 32,
        };
        s = ExtAudioFileSetProperty(_descodificador, kExtAudioFileProperty_ClientDataFormat, sizeof(_formato), &_formato);
    }
    if (s == noErr) {
        size = sizeof(_totalDeTramas);
        s = ExtAudioFileGetProperty(_descodificador, kExtAudioFileProperty_FileLengthFrames, &size, &_totalDeTramas);
    }
    if (s != noErr) {
        if (outError) *outError = [NSError errorWithDomain:NSOSStatusErrorDomain code:s userInfo:nil];
        return NO;
    }

    // Disposição: estéreo e mono marcados como tal — é a marca que o renderer
    // olha para decidir espacializar; com mais canais, a do ficheiro, se a houver.
    if (_formato.mChannelsPerFrame <= 2) {
        _tamanhoDisposicao = sizeof(AudioChannelLayout);
        _disposicao = calloc(1, _tamanhoDisposicao);
        _disposicao->mChannelLayoutTag = _formato.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono
                                                                         : kAudioChannelLayoutTag_Stereo;
    } else {
        UInt32 t = 0;
        if (ExtAudioFileGetPropertyInfo(_descodificador, kExtAudioFileProperty_FileChannelLayout, &t, NULL) == noErr && t > 0) {
            _disposicao = calloc(1, t);
            if (ExtAudioFileGetProperty(_descodificador, kExtAudioFileProperty_FileChannelLayout, &t, _disposicao) == noErr) {
                _tamanhoDisposicao = t;
            } else {
                free(_disposicao); _disposicao = NULL;
            }
        }
    }

    _bloco = malloc((size_t)kZPTramasPorBloco * _formato.mBytesPerFrame);
    _renderer = [AVSampleBufferAudioRenderer new];
    _renderer.allowedAudioSpatializationFormats = AVAudioSpatializationFormatMonoStereoAndMultichannel;
    _sincronizador = [AVSampleBufferRenderSynchronizer new];
    [_sincronizador addRenderer:_renderer];
    NSString *blackHole = ZPUIDDoBlackHole();
    if (blackHole) {
        _espelho = [AVSampleBufferAudioRenderer new];
        _espelho.audioOutputDeviceUniqueID = blackHole;
        [_sincronizador addRenderer:_espelho];
    }
    _fila = dispatch_queue_create("JPSdA.tocaTintas.leitorEspacial", DISPATCH_QUEUE_SERIAL);
    return YES;
}

- (void)dealloc {
    [self pararDeAlimentar];
    if (_observadorDoFim) [_sincronizador removeTimeObserver:_observadorDoFim];
    [_sincronizador setRate:0.0];
    [_renderer flush];
    [_espelho flush];
    ExtAudioFileRef d = _descodificador;
    AudioFileID f = _ficheiro;
    float *b = _bloco;
    AudioChannelLayout *l = _disposicao;
    NSData *bytes = _bytes;   // o AudioFile lê destes bytes até ser fechado
    dispatch_async(_fila, ^{
        if (d) ExtAudioFileDispose(d);
        if (f) AudioFileClose(f);
        free(b);
        free(l);
        (void)bytes;
    });
}

#pragma mark - Descodificação (na fila)

// Cada bloco vai para os AirPods e, se o houver, para o espelho do cava. O
// espelho consome ao mesmo ritmo, por isso não se lhe pergunta se está pronto.
- (void)entregar:(CMSampleBufferRef)amostras {
    [self.renderer enqueueSampleBuffer:amostras];
    [self.espelho enqueueSampleBuffer:amostras];
}

// O bloco seguinte, ou NULL no fim do ficheiro.
- (nullable CMSampleBufferRef)proximoBloco CF_RETURNS_RETAINED {
    if (_descodificacaoAcabou) return NULL;
    AudioBufferList lista = { .mNumberBuffers = 1 };
    lista.mBuffers[0] = (AudioBuffer){ _formato.mChannelsPerFrame, kZPTramasPorBloco * _formato.mBytesPerFrame, _bloco };
    UInt32 tramas = kZPTramasPorBloco;
    if (ExtAudioFileRead(_descodificador, &tramas, &lista) != noErr || tramas == 0) {
        _descodificacaoAcabou = YES;
        return NULL;
    }

    CMAudioFormatDescriptionRef descricao = NULL;
    CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &_formato, _tamanhoDisposicao, _disposicao, 0, NULL, NULL, &descricao);
    size_t bytes = (size_t)tramas * _formato.mBytesPerFrame;
    CMBlockBufferRef memoria = NULL;
    CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, bytes, kCFAllocatorDefault, NULL, 0, bytes,
                                       kCMBlockBufferAssureMemoryNowFlag, &memoria);
    CMBlockBufferReplaceDataBytes(_bloco, memoria, 0, bytes);
    CMSampleBufferRef amostras = NULL;
    CMAudioSampleBufferCreateReadyWithPacketDescriptions(kCFAllocatorDefault, memoria, descricao, tramas,
                                                         CMTimeMake(_proximaTrama, (int32_t)_formato.mSampleRate),
                                                         NULL, &amostras);
    CFRelease(memoria);
    CFRelease(descricao);
    _proximaTrama += tramas;
    return amostras;
}

// Põe na fila do renderer o que ele aceitar. Na fila.
- (void)alimentar {
    while (self.renderer.isReadyForMoreMediaData) {
        CMSampleBufferRef amostras = [self proximoBloco];
        if (!amostras) {
            [self.renderer stopRequestingMediaData];
            SInt64 fim = _proximaTrama;
            __weak typeof(self) fraco = self;
            dispatch_async(dispatch_get_main_queue(), ^{ [fraco vigiarOFimEm:fim]; });
            return;
        }
        [self entregar:amostras];
        CFRelease(amostras);
    }
}

- (void)comecarAAlimentar {
    __weak typeof(self) fraco = self;
    [self.renderer requestMediaDataWhenReadyOnQueue:self.fila usingBlock:^{
        [fraco alimentar];
    }];
}

- (void)pararDeAlimentar {
    [_renderer stopRequestingMediaData];
}

#pragma mark - Fim da faixa

- (void)vigiarOFimEm:(SInt64)trama {
    if (self.observadorDoFim) [self.sincronizador removeTimeObserver:self.observadorDoFim];
    __weak typeof(self) fraco = self;
    self.observadorDoFim = [self.sincronizador addBoundaryTimeObserverForTimes:
                                @[[NSValue valueWithCMTime:CMTimeMake(trama, (int32_t)_formato.mSampleRate)]]
                                                                         queue:dispatch_get_main_queue()
                                                                    usingBlock:^{
        [fraco terminar];
    }];
}

- (void)terminar {
    if (_terminou) return;
    _terminou = YES;
    [self.sincronizador setRate:0.0];
    id<AVAudioPlayerDelegate> d = self.delegate;
    if ([d respondsToSelector:@selector(audioPlayerDidFinishPlaying:successfully:)]) {
        [d audioPlayerDidFinishPlaying:self successfully:YES];
    }
}

#pragma mark - O que o tocaTintas usa

- (BOOL)prepareToPlay {
    return YES;
}

- (BOOL)play {
    if (_terminou) return NO;
    if (!_arrancou) {
        _arrancou = YES;
        // Meio segundo na fila antes de o relógio andar: com o relógio a andar e
        // a fila vazia, os primeiros blocos chegavam já atrasados. O início pode
        // não ser zero: a troca de motor a meio da faixa (ver o ViewController,
        // -acertarMotorASaida) põe a posição antes de tocar.
        __block SInt64 inicio = 0;
        dispatch_sync(self.fila, ^{
            inicio = self->_proximaTrama;
            SInt64 alvo = inicio + (SInt64)(kZPSegundosDeArranque * self->_formato.mSampleRate);
            while (self->_proximaTrama < alvo && self.renderer.isReadyForMoreMediaData) {
                CMSampleBufferRef amostras = [self proximoBloco];
                if (!amostras) break;
                [self entregar:amostras];
                CFRelease(amostras);
            }
        });
        [self comecarAAlimentar];
        [self.sincronizador setRate:1.0 time:CMTimeMake(inicio, (int32_t)_formato.mSampleRate)];
        return YES;
    }
    self.sincronizador.rate = 1.0;
    return YES;
}

- (void)pause {
    self.sincronizador.rate = 0.0;
}

- (void)stop {
    self.sincronizador.rate = 0.0;
}

- (BOOL)isPlaying {
    return _arrancou && !_terminou && self.sincronizador.rate > 0.0;
}

- (NSTimeInterval)currentTime {
    if (!_arrancou) return (double)_proximaTrama / _formato.mSampleRate;
    double t = CMTimeGetSeconds(self.sincronizador.currentTime);
    return t > 0.0 ? MIN(t, self.duration) : 0.0;
}

// Saltar: ir ao ExtAudioFile, esvaziar o renderer e pôr o relógio na trama.
// Serve o salto de silêncios, que é quem escreve isto.
- (void)setCurrentTime:(NSTimeInterval)tempo {
    SInt64 trama = (SInt64)llround(MAX(tempo, 0.0) * _formato.mSampleRate);
    if (_totalDeTramas > 0) trama = MIN(trama, _totalDeTramas);
    float rate = self.sincronizador.rate;
    [self pararDeAlimentar];
    if (self.observadorDoFim) {
        [self.sincronizador removeTimeObserver:self.observadorDoFim];
        self.observadorDoFim = nil;
    }
    dispatch_sync(self.fila, ^{
        ExtAudioFileSeek(self->_descodificador, trama);
        self->_proximaTrama = trama;
        self->_descodificacaoAcabou = NO;
    });
    [self.renderer flush];
    [self.espelho flush];
    _terminou = NO;
    if (_arrancou) {
        [self comecarAAlimentar];
        [self.sincronizador setRate:rate time:CMTimeMake(trama, (int32_t)_formato.mSampleRate)];
    }
}

- (float)volume {
    return self.renderer.volume;
}

- (void)setVolume:(float)volume {
    self.renderer.volume = volume;
}

@end
