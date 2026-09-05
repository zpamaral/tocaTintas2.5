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
//  ViewController.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 26/08/2026.
//

#include <wavpack/wavpack.h>   // For WAVpack playback
#include <FLAC/metadata.h>   // For FLAC playback
#include <FLAC/stream_decoder.h>   // Also for FLAC playback
#include <opus/opusfile.h>  // For Ogg Opus playback
#include <string.h>
#include <stdatomic.h>   // For the silence-analysis generation counter

#import <TPCircularBuffer/TPCircularBuffer.h>

#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>   // FSEvents, para vigiar a pasta de músicas
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "ViewController.h"   // Objective-C header
#import "M3UPlaylist.h"
#import "ZPOpusDecoder.h"   // Class for Ogg Opus metadata extraction and decoding
#import <CoreAudio/CoreAudio.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>   // This might be needed
#import "HistogramView.h"   // Histogram for the frequency sonogram
#import <AudioToolbox/AudioToolbox.h>   // CoreAudio
#import <UserNotifications/UserNotifications.h>
#import "PreferencesWindowController.h"

#import "ZPAirPlay.h"
#import "ZPAudioCapture.h"
#import "ZPAirPlayStreamer.h"

#define NUM_BUFFERS 3  // Three is typically a good number for real-time audio playback
#define ENABLE_BS2B_BRIDGE 1 // Running bs2b_bridge

static NSString * const kBS2BHeadphonesNameSubstring = @"Auscultadores externos";

#pragma mark - Salto automático de silêncios longos (constantes e utilitários)

// Só saltamos silêncios com mais do que esta duração
static const double kZPSilenceMinimumGapDuration    = 10.0;
// Resolução da análise (blocos de 50 ms)
static const double kZPSilenceAnalysisBlockDuration = 0.05;
// Limiar de silêncio: RMS por bloco, ≈ -55 dBFS
static const double kZPSilenceThreshold             = 0.0018;
// Margem deixada antes do reinício da música, para não cortar o ataque
static const double kZPSilenceSkipPreRoll           = 0.25;

// Um intervalo de silêncio dentro da faixa, em segundos desde o início do ficheiro
typedef struct {
    double start;
    double end;
} ZPSilenceGap;

// Cada faixa que arranca incrementa este contador; as análises em curso que já não
// correspondem ao valor actual são abandonadas e os seus resultados descartados.
static _Atomic(uint64_t) gSilenceAnalysisGeneration = 0;

// Geração dos metadados à vista. O caminho dos formatos que não são FLAC nem
// WavPack lê o AVAsset com -loadValuesAsynchronouslyForKeys:, cujo handler
// termina fora da fila principal e num instante imprevisível. Com dois saltos
// seguidos no ⏭, o handler da faixa A pode terminar depois de a B já estar no
// ecrã e escrever por cima dela — a capa, as etiquetas e, pior, o ReplayGain,
// que não é cosmético. Cada pedido leva a geração com que nasceu e desiste se
// entretanto tiver havido outro.
static _Atomic(uint64_t) gMetadataGeneration = 0;

// Fila série onde decorre a análise, fora da thread de reprodução
static dispatch_queue_t ZPSilenceAnalysisQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attributes = dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0);
        queue = dispatch_queue_create("com.tocatintas.analise-silencio", attributes);
    });
    return queue;
}

// Acumula o resultado de um bloco de análise. Quando um bloco com som fecha uma
// sequência de silêncio suficientemente longa, essa lacuna é registada.
// Passando blockIsSilent = NO com blockStartFrame = total de frames fecha o ficheiro.
static void ZPSilenceAccumulate(BOOL blockIsSilent,
                                int64_t blockStartFrame,
                                double sampleRate,
                                int64_t *silenceStartFrame,
                                NSMutableArray<NSValue *> *gaps) {
    if (blockIsSilent) {
        if (*silenceStartFrame < 0) {
            *silenceStartFrame = blockStartFrame;
        }
        return;
    }

    if (*silenceStartFrame < 0) {
        return;
    }

    ZPSilenceGap gap;
    gap.start = (double)(*silenceStartFrame) / sampleRate;
    gap.end   = (double)blockStartFrame / sampleRate;
    *silenceStartFrame = -1;

    if (gap.end - gap.start > kZPSilenceMinimumGapDuration) {
        [gaps addObject:[NSValue valueWithBytes:&gap objCType:@encode(ZPSilenceGap)]];
    }
}

// Helper structures and callbacks for reading WavPack data from memory
typedef struct {
    const unsigned char *data;
    size_t size;
    size_t pos;
} MemoryBuffer;

static int read_bytes(void *id, void *data, int bcount)
{
    if (!id || !data || bcount <= 0) return 0;

    MemoryBuffer *mem = (MemoryBuffer *)id;
    if (!mem->data) return 0;

    // Evitar underflow e leituras fora do fim
    if (mem->pos >= mem->size) return 0;

    size_t remaining = mem->size - mem->pos;
    size_t want = (size_t)bcount;
    if (want > remaining) want = remaining;

    memcpy(data, (const unsigned char *)mem->data + mem->pos, want);
    mem->pos += want;

    return (int)want;
}

static unsigned int get_pos(void *id) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    return (unsigned int)mem->pos;
}

static int set_pos_abs(void *id, unsigned int pos) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    if (pos > mem->size) return -1;
    mem->pos = pos;
    return 0;
}

static int set_pos_rel(void *id, int delta, int mode) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    size_t newpos = mem->pos;
    if (mode == SEEK_CUR) newpos += delta;
    else if (mode == SEEK_END) newpos = mem->size + delta;
    else newpos = delta;
    if (newpos > mem->size) return -1;
    mem->pos = newpos;
    return 0;
}

static int push_back_byte(void *id, int c) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    if (mem->pos == 0) return -1;
    mem->pos--;
    return c;
}

static unsigned int get_length(void *id) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    return (unsigned int)mem->size;
}

static int can_seek(void *id) {
    (void)id;
    return 1;
}

static WavpackStreamReader memoryReader = {
    read_bytes,
    get_pos,
    set_pos_abs,
    set_pos_rel,
    push_back_byte,
    get_length,
    can_seek
};
@interface ViewController () <AVAudioPlayerDelegate>

@property (nonatomic, strong) NSTextField *playCountLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *trackPlayCounts;

- (void)loadTrackPlayCounts;
- (void)saveTrackPlayCounts;
- (void)schedulePlayCountIncrementForTrack:(NSURL *)trackURL;
- (void)beginPlayCountTrackingForTrack:(NSURL *)trackURL forceNewPlayback:(BOOL)forceNewPlayback;
- (void)suspendPlayCountTracking;
- (void)resumePlayCountTracking;
- (void)resetPlayCountTracking;
- (void)refreshPlayCountLabel;
- (void)comboBoxSelectionChanged:(NSComboBox *)comboBox;
- (void)playButtonPressed;
- (BOOL)resumePlayback;
- (void)updatePauseButtonAppearance:(BOOL)isActive;
- (BOOL)isPlaybackEngaged;
- (NSInteger)randomShuffledStartIndex;
- (NSArray<NSURL *> *)currentPlaybackList;
- (void)prefetchNextTrack;
- (void)prefetchTrackAtURL:(NSURL *)trackURL;
- (void)discardPrefetchedTrack;
- (NSData *)prefetchedDataForTrack:(NSURL *)trackURL;
- (NSData *)takePrefetchedDataForTrack:(NSURL *)trackURL;

@property (nonatomic, strong) NSImageView *coverArtView;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *albumLabel;
@property (nonatomic, strong) NSTextField *titleLabel;

@property (weak) IBOutlet NSTextField *trackNumberLabel;
@property (weak) IBOutlet NSMenuItem *openRecentMenuItem;

@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *pauseButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSButton *forwardButton;
@property (nonatomic, strong) NSButton *backwardButton;
@property (nonatomic, strong) NSButton *repeatButton;
@property (nonatomic, strong) NSButton *recordButton;

@property (nonatomic, assign) BOOL isRepeatModeActive;
@property (nonatomic, assign) BOOL isCalledFromPlayNextTrack;

@property (nonatomic, strong) NSButton *shuffleButton;

@property (nonatomic, strong) NSProgressIndicator *progressBar;  // Progress bar
@property (nonatomic, strong) HistogramView *histogramView;

@property (nonatomic, strong) ZPOpusDecoder *opusDecoder;

@property (nonatomic, strong) AVAudioPlayer *audioPlayer;

// A faixa adiantada em memória. Ver «Faixa adiantada em memória», mais abaixo:
// nada disto se lê ou escreve directamente, é tudo pelos métodos de lá.
@property (nonatomic, strong) NSData *prefetchedData;
@property (nonatomic, strong) NSURL *prefetchedTrackURL;
@property (nonatomic, assign) uint64_t prefetchGeneration;

// Properties to cache the directory modification date and audio files
@property (nonatomic, strong) NSDate *directoryModificationDate;
@property (nonatomic, strong) NSArray<NSURL *> *cachedAudioFiles;

// Vigilância da pasta de músicas. O mtime da raiz só muda quando se cria ou apaga
// algo diretamente dentro dela, pelo que copiar um álbum para uma pasta de artista
// já existente passava despercebido. O FSEvents cobre a árvore toda.
@property (nonatomic, assign) FSEventStreamRef directoryEventStream;
@property (nonatomic, copy) NSString *watchedDirectoryPath;
@property (nonatomic, assign) BOOL audioLibraryNeedsReload;
@property (nonatomic, assign) BOOL hasCompletedInitialScan;
@property (nonatomic, assign) NSUInteger pendingReloadGeneration;
@property (nonatomic, assign) BOOL isPlaylistModeActive; // Indicates if an M3U8 playlist is loaded

@property (nonatomic, strong) NSArray<NSURL *> *audioFiles;
@property (nonatomic, assign) NSInteger currentTrackIndex;
@property (nonatomic, strong) NSMutableArray<NSURL *> *shuffledAudioFiles; // Shuffled list for shuffle functionality

@property (nonatomic, strong) NSTimer *progressUpdateTimer;  // Timer to update progress bar

@property (strong, nonatomic) NSPanel *aboutPanel; // This makes the panel accessible in your methods
// Contagem de reproduções. Uma faixa conta uma única vez por reprodução, ao fim de
// kPlayCountThreshold segundos de audição efectiva. Avançar antes disso não conta;
// pausar e retomar não volta a contar.
@property (nonatomic, strong) NSTimer *playCountTimer; // Timer to delay play count increment
@property (nonatomic, copy) NSString *playCountTrackPath;   // faixa da sessão de contagem actual
@property (nonatomic, assign) BOOL playCountAlreadyCounted; // já contou nesta reprodução?
@property (nonatomic, strong) NSDate *playCountDeadline;    // instante em que deve contar
@property (nonatomic, assign) NSTimeInterval playCountRemaining; // tempo em falta, enquanto suspenso
// Reprodução suspensa pelo botão ⏸️. É o estado que dá a selecção verde ao botão e
// que permite ao botão ▶️ retomar onde ficou, em vez de recomeçar a faixa.
@property (nonatomic, assign) BOOL isPlaybackPaused;
@property (nonatomic, strong) NSURL *currentTrackURL; // To keep track of the current playing track
@property (nonatomic, strong) NSMutableDictionary<NSURL *, NSURL *> *shuffledToOriginalMap;

@property (strong) NSTask *cavaTask;

@property (nonatomic, strong) ZPAirPlay *airPlayManager;
//@property (nonatomic, strong) NSTimer *refreshTimer;

@property (strong, nonatomic) ZPAudioCapture *audioCapture;
@property (assign, nonatomic) BOOL isRecording;

// AirPlay-related properties
@property (strong) NSButton *airPlayButton;
@property (strong) NSPopover *airPlayPopover;
@property (nonatomic, strong) NSButton *currentlySelectedCheckbox;
@property (nonatomic, strong) NSString *selectedDeviceName; // Store the selected device name
@property (nonatomic, strong) ZPAirPlayStreamer *airPlayStreamer;
@property (nonatomic, assign) BOOL isProgrammaticChange;

// Silêncios longos detectados na faixa actual (NSValue com ZPSilenceGap), por ordem
// crescente de início. Escrita na thread principal, lida pelos temporizadores.
@property (copy) NSArray<NSValue *> *silenceGaps;

// To implement s2b when using headphones (or line out)
@property (strong, nonatomic) NSTask *bs2bTask;
@property (strong, nonatomic) NSTimer *bs2bHeadphonePollTimer;
@property (assign, nonatomic) BOOL bs2bLastHeadphonesConnected;
// Botão que liga e desliga o filtro. O estado que manda é o bs2bUserEnabled;
// o botão é só o espelho dele — desenha-se a partir daí, nunca ao contrário.
@property (strong, nonatomic) NSButton *bs2bToggleButton;
// O utilizador quer o processamento ligado? Só tem significado com
// auscultadores: nas colunas a ponte corre sempre em passagem limpa.
@property (assign, nonatomic) BOOL bs2bUserEnabled;
// Com que configuração é que a ponte que está a correr foi lançada. Serve para
// não a reiniciar à toa: reiniciar corta o som por um instante.
@property (copy,   nonatomic) NSString *bs2bRunningOutputName;
@property (copy,   nonatomic) NSString *bs2bRunningProfile;
@property (copy,   nonatomic) NSString *bs2bRunningEq;
@property (assign, nonatomic) BOOL bs2bRunningProcessing;
// Guarda contra reentrância: ver a nota em -stopBs2bIfRunning.
@property (assign, nonatomic) BOOL bs2bAplicando;
- (void)updateBs2bToggleButtonAppearance;
- (void)applyBs2bConfigurationWithOutput:(NSString *)nomeSaida;

@end

#pragma mark - Botões de transporte

// Os oito botões de transporte usam emojis como título, e os emojis da Apple
// Color Emoji não são símbolos soltos: cada um é um ladrilho quadrado com o
// desenho lá dentro. Isso obriga a dois acertos, um por eixo, porque os fundos
// verde e vermelho da selecção têm de assentar centrados nesse ladrilho.

// Eixo horizontal. A fonte não centra a tinta na própria caixa de avanço: a
// 18 pt o avanço mede 24 pt, a tinta 21 pt, e sobram 1,165 pt à esquerda contra
// 1,834 pt à direita. O AppKit centra o avanço no rectângulo do título — que
// nestes botões é exactamente igual aos bounds, medi-o —, e como o avanço é
// simétrico o centramento está certo do lado dele; é a tinta que fica 0,335 pt
// à esquerda do meio. Num parágrafo centrado, o recuo da primeira linha desloca
// o texto metade do seu valor, portanto 1 pt de recuo empurra o glifo meio ponto
// para a direita e o ladrilho passa a assentar simetricamente sobre a grelha de
// pixéis. Confirmei na janela a correr: 2 px de cor de cada lado, nos oito
// botões. Como o «attributedTitle» ignora o «alignment» do botão, o parágrafo
// tem de trazer o centrar consigo.
static NSAttributedString *ZPTituloDeBotaoDeTransporte(NSString *glifo) {
    NSMutableParagraphStyle *estilo = [[NSMutableParagraphStyle alloc] init];
    estilo.alignment = NSTextAlignmentCenter;
    estilo.firstLineHeadIndent = 1.0;

    return [[NSAttributedString alloc] initWithString:glifo attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold],
        NSParagraphStyleAttributeName: estilo
    }];
}

// Eixo vertical. Aqui não há acerto que sirva, porque o problema não é de
// centramento mas de aritmética: a 18 pt o ladrilho rasteriza com 22 colunas
// mas apenas 21 linhas. Num botão de 26×26 sobram 26 − 22 = 4 px na horizontal,
// que se repartem certos, dois de cada lado; na vertical sobram 26 − 21 = 5 px,
// número ímpar que não há como dividir em dois. Medido na janela a correr, nos
// oito botões: duas linhas vazias acima do ícone e três abaixo.
//
// Mexer no glifo não resolve — deslocá-lo só troca 2/3 por 3/2 — e mexer na
// altura do botão também não, porque o título é recentrado na nova caixa e a
// assimetria acompanha-o. O que resolve é encolher o rectângulo pintado: uma
// linha a menos, tirada por baixo, deixa exactamente 2 px de cor a toda a volta.
//
// Por isso o fundo é pintado aqui, na célula, e não na camada do botão: a
// «layer.backgroundColor» está presa aos bounds e não permite este recorte, e
// uma subcamada não serve porque as subcamadas desenham por cima do conteúdo da
// vista, ou seja tapariam o emoji. Desenhado na célula, fica por baixo do
// título, que é onde tem de estar.
@interface ZPCelulaDeBotaoDeTransporte : NSButtonCell
// Cor da selecção, ou nil quando o botão não está seleccionado.
@property (nonatomic, strong) NSColor *corDeFundo;
@end

@implementation ZPCelulaDeBotaoDeTransporte

- (void)drawWithFrame:(NSRect)frame inView:(NSView *)controlView {
    if (self.corDeFundo) {
        // O NSButton é uma vista invertida (y cresce para baixo), portanto a
        // linha a descontar sai simplesmente da altura.
        NSRect fundo = frame;
        fundo.size.height -= 1.0;
        if (!controlView.isFlipped) {
            fundo.origin.y += 1.0;
        }

        [self.corDeFundo setFill];
        [[NSBezierPath bezierPathWithRoundedRect:fundo xRadius:6.0 yRadius:6.0] fill];
    }

    [super drawWithFrame:frame inView:controlView];
}

@end

// Põe o botão a usar a célula acima e assenta-lhe o título já compensado.
static void ZPPreparaBotaoDeTransporte(NSButton *botao, NSString *glifo) {
    ZPCelulaDeBotaoDeTransporte *celula = [[ZPCelulaDeBotaoDeTransporte alloc] init];
    [celula setButtonType:NSButtonTypeMomentaryPushIn];
    celula.bordered = NO;
    celula.controlSize = NSControlSizeLarge;
    botao.cell = celula;

    botao.attributedTitle = ZPTituloDeBotaoDeTransporte(glifo);
}

// Selecciona ou desselecciona um botão de transporte. Passar nil tira a cor.
static void ZPPintaBotaoDeTransporte(NSButton *botao, NSColor *cor) {
    ZPCelulaDeBotaoDeTransporte *celula = (ZPCelulaDeBotaoDeTransporte *)botao.cell;
    if (![celula isKindOfClass:[ZPCelulaDeBotaoDeTransporte class]]) {
        return;
    }

    celula.corDeFundo = cor;
    botao.needsDisplay = YES;
}


@implementation ViewController

// Structure to hold the audio playback state
typedef struct {
    AudioQueueRef audioQueue;
    AudioQueueBufferRef buffers[NUM_BUFFERS];
    WavpackContext *wpc;  // WAVPack file context
    OggOpusFile *opusFile;  // Opus file context (added for Opus playback)
    int32_t *sampleBuffer;
    UInt32 bufferSize;
    BOOL isPlaying;
    int numChannels;  // Store the number of channels
    __unsafe_unretained ViewController *client_data;
    double totalDuration;  // Track the duration of the current track
    double sampleRate;  // Add sampleRate to track the sample rate of the Opus file
    BOOL didApplyFadeIn;
    // Salto de silêncios: pedido feito pela thread principal (frame de destino na
    // fonte, 0 = sem pedido) e aplicado pelo callback do descodificador.
    volatile int64_t pendingSeekFrame;
    // Total de frames saltadas, para compensar o relógio da AudioQueue
    volatile double skippedFrames;
} CoreAudioPlaybackState;

CoreAudioPlaybackState playbackState;

- (NSString *)playCountFilePath {
    NSString *appSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *tocaTintasDirectory = [appSupportDirectory stringByAppendingPathComponent:@"tocaTintas"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:tocaTintasDirectory]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:tocaTintasDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error creating Application Support directory: %@", error.localizedDescription);
            #endif
        }
    }
    
    NSString *filePath = [tocaTintasDirectory stringByAppendingPathComponent:@"trackPlayCounts.json"];
    #ifdef DEBUG
    NSLog(@"Saving play counts to path: %@", filePath); // Debug log
    #endif
    return filePath;
}

// Path for storing cached audio file information
- (NSString *)audioCacheFilePath {
    NSString *appSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *tocaTintasDirectory = [appSupportDirectory stringByAppendingPathComponent:@"tocaTintas"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:tocaTintasDirectory]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:tocaTintasDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error creating Application Support directory: %@", error.localizedDescription);
            #endif
        }
    }

    return [tocaTintasDirectory stringByAppendingPathComponent:@"audioFilesCache.json"];
}

// Load cached audio files from disk if available
- (void)loadAudioFilesCache {
    NSString *filePath = [self audioCacheFilePath];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        return;
    }

    NSError *error = nil;
    NSDictionary *cache = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![cache isKindOfClass:[NSDictionary class]]) {
        #ifdef DEBUG
        NSLog(@"Failed to read audio cache: %@", error.localizedDescription);
        #endif
        return;
    }

    NSNumber *timestamp = cache[@"modificationDate"];
    NSArray *paths = cache[@"audioFiles"];
    if (timestamp && paths) {
        NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:paths.count];
        for (NSString *path in paths) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }

        self.directoryModificationDate = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
        self.cachedAudioFiles = urls;
        self.audioFiles = urls;
    }
}

// Save the current audio file list to disk for faster subsequent launches
- (void)saveAudioFilesCache {
    if (!self.cachedAudioFiles || !self.directoryModificationDate) {
        return;
    }

    NSString *filePath = [self audioCacheFilePath];
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:self.cachedAudioFiles.count];
    for (NSURL *url in self.cachedAudioFiles) {
        [paths addObject:url.path];
    }

    NSDictionary *cache = @{@"modificationDate": @([self.directoryModificationDate timeIntervalSince1970]),
                            @"audioFiles": paths};

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cache options:NSJSONWritingPrettyPrinted error:&error];
    if (!error) {
        [data writeToFile:filePath atomically:YES];
    } else {
        #ifdef DEBUG
        NSLog(@"Failed to save audio cache: %@", error.localizedDescription);
        #endif
    }
}

- (NSString *)replaceSingleQuoteAndSmartQuotes:(NSString *)input {
    // Replacing single quotes with typographic single quote ‘
    NSString *output = [input stringByReplacingOccurrencesOfString:@"'" withString:@"’"];
    
    // Replacing … with typographic ellipsis …
    output = [output stringByReplacingOccurrencesOfString:@"…" withString:@"…"];
 
    // Replace each pair of quotes with “ and ”
    NSUInteger quoteCount = 0;
    NSMutableString *mutableOutput = [output mutableCopy];
    NSRange searchRange = NSMakeRange(0, [mutableOutput length]);
    NSRange foundRange;

    while ((foundRange = [mutableOutput rangeOfString:@"\"" options:0 range:searchRange]).location != NSNotFound) {
        quoteCount++;
        
        // Only replace if there's an even number of quotes
        if (quoteCount % 2 == 0) {
            [mutableOutput replaceCharactersInRange:foundRange withString:@"”"];
        } else {
            [mutableOutput replaceCharactersInRange:foundRange withString:@"“"];
        }

        // Update the search range to continue searching after the current replacement
        searchRange = NSMakeRange(NSMaxRange(foundRange), [mutableOutput length] - NSMaxRange(foundRange));
    }
    
    // Replace hyphens flanked by spaces with m-dash (—)
    NSRegularExpression *spaceHyphenSpaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s-\\s" options:0 error:nil];
    mutableOutput = [[spaceHyphenSpaceRegex stringByReplacingMatchesInString:mutableOutput
                                            options:0
                                            range:NSMakeRange(0, mutableOutput.length)
                                            withTemplate:@" — "] mutableCopy];
    
    // Replace hyphens flanked by digits with n-dash (–)
    NSRegularExpression *digitHyphenDigitRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d)-(\\d)" options:0 error:nil];
    mutableOutput = [[digitHyphenDigitRegex stringByReplacingMatchesInString:mutableOutput
                                            options:0
                                            range:NSMakeRange(0, mutableOutput.length)
                                            withTemplate:@"$1–$2"] mutableCopy];
    
    // Replace left-double quotes right-adjacent to a digit with inch symbol (“)
    NSRegularExpression *digitQuoteRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d)\\u201C" options:0 error:nil];
    mutableOutput = [[digitQuoteRegex stringByReplacingMatchesInString:mutableOutput
                                      options:0
                                      range:NSMakeRange(0, mutableOutput.length)
                                      withTemplate:@"$1\""] mutableCopy];

    // Apply superscript for specific ordinals
    mutableOutput = [[mutableOutput stringByReplacingOccurrencesOfString:@"1st" withString:@"1ˢᵗ"] mutableCopy];
    mutableOutput = [[mutableOutput stringByReplacingOccurrencesOfString:@"2nd" withString:@"2ⁿᵈ"] mutableCopy];
    mutableOutput = [[mutableOutput stringByReplacingOccurrencesOfString:@"3rd" withString:@"3ʳᵈ"] mutableCopy];

    // Apply superscript for "th" only if preceded by any digit
    NSRegularExpression *thOrdinalRegex = [NSRegularExpression regularExpressionWithPattern:@"(?<=\\d)th\\b" options:0 error:nil];
    mutableOutput = [[thOrdinalRegex stringByReplacingMatchesInString:mutableOutput
                                     options:0
                                     range:NSMakeRange(0, mutableOutput.length)
                                     withTemplate:@"ᵗʰ"] mutableCopy];

    return [mutableOutput copy];
}

- (NSString *)decodeMetadataItem:(AVMetadataItem *)metadataItem {
    NSString *decodedString = nil;

    // First, attempt to decode as UTF-8
    decodedString = [NSString stringWithUTF8String:[metadataItem.stringValue UTF8String]];
    
    // If that fails, try ISO-8859-1 (Latin-1)
    if (!decodedString) {
        decodedString = [[NSString alloc] initWithData:[metadataItem.stringValue                               dataUsingEncoding:NSISOLatin1StringEncoding]
            encoding:NSISOLatin1StringEncoding];
    }

    // If necessary, add more fallbacks to other encodings (e.g., UTF-16)
    if (!decodedString) {
        decodedString = [[NSString alloc] initWithData:[metadataItem.stringValue dataUsingEncoding:NSUTF16StringEncoding]
            encoding:NSUTF16StringEncoding];
    }

    // If all attempts fail, return the original string value or a placeholder
    if (!decodedString) {
        decodedString = metadataItem.stringValue ?: @"Unknown";
    }

    return decodedString;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        // Custom initialization if needed
        [self loadTrackPlayCounts];
    }
    return self;
}

- (BOOL)isDarkMode {
    NSAppearance *appearance = [NSAppearance currentDrawingAppearance] ?: [NSApp effectiveAppearance];
    NSString *appearanceName = appearance.name;
    return [appearanceName containsString:@"Dark"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Ignore SIGPIPE signals to prevent termination
    signal(SIGPIPE, SIG_IGN);
    
    // Set the About menu action and target
    NSMenu *appMenu = [[[NSApplication sharedApplication] mainMenu] itemAtIndex:0].submenu;
    NSMenuItem *aboutMenuItem = [appMenu itemAtIndex:0];
    [aboutMenuItem setAction:@selector(showCustomAboutPanel:)];
    [aboutMenuItem setTarget:self];
    [aboutMenuItem setEnabled:YES];
    
    // **[Addition] Initialize the selected device name from User Defaults if available**
    self.selectedDeviceName = [[NSUserDefaults standardUserDefaults] stringForKey:@"SelectedAirPlayDevice"];
    // If no selection was previously saved, you can default to nil
    if (!self.selectedDeviceName) {
        self.selectedDeviceName = nil;
    }

    // Initialize the AirPlay popover
    self.airPlayPopover = [[NSPopover alloc] init];
    self.airPlayPopover.behavior = NSPopoverBehaviorTransient; // Automatically closes when user clicks outside

    // Create the AirPlay button styled like an icon button
    self.airPlayButton = [[NSButton alloc] initWithFrame:NSMakeRect(710, 60, 20, 20)];
    self.airPlayButton.bezelStyle = NSBezelStyleRegularSquare;
    self.airPlayButton.bordered = NO; // No border for a clean look

    // Load the SF Symbol "airplayaudio" icon
    NSImage *airPlayIcon = [NSImage imageWithSystemSymbolName:@"airplay.audio"
                                    accessibilityDescription:@"AirPlay"];

    // **Set the image as a template to allow tinting**
    [airPlayIcon setTemplate:YES];

    self.airPlayButton.image = airPlayIcon;
    self.airPlayButton.imagePosition = NSImageOnly;

    // **Set the contentTintColor based on whether an AirPlay device is selected**
    [self updateAirPlayButtonTint];

    // Set the target and action for the button to show the popover menu
    [self.airPlayButton setTarget:self];
    [self.airPlayButton setAction:@selector(showAirPlayPopover:)];

    // Other initial setup code…
    [self requestNotificationPermission];
    [self loadTrackPlayCounts];
    [self loadAudioFilesCache];
    [self startWatchingSongsDirectory];
    [self loadAudioFiles];
    [self readFifoDirectly];
    [self setupUI];
    [self createComboBox];
    
    // Add the AirPlay button to the view
    [self.view addSubview:self.airPlayButton];
    
    // Set self as the application's delegate
    [NSApp setDelegate:self];
    
    // Set up the 'Open Recent' menu
    [self setupOpenRecentMenu];
    
    // Handling cava
    //[self startCava];
    [self manageCava];
    
    // Initialize and start the AirPlay manager
    self.airPlayManager = [[ZPAirPlay alloc] init];
    [self.airPlayManager startDiscovery];

    // A descoberta anda sempre a correr e avisa quando a lista muda; é isto que
    // mantém o popover certo enquanto está aberto, e que dispensa o antigo
    // «apagar o ficheiro e recomeçar» a cada clique no ícone.
    __weak typeof(self) fraco = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:kZPAirPlayDispositivosMudaram
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *nota) {
        [fraco atualizarPopoverDeAirPlay];
    }];
    
    // Initialize ZPAudioCapture instance
    self.audioCapture = [[ZPAudioCapture alloc] init];
    self.isRecording = NO;  // Start with recording set to off

    self.isStreaming = NO; // Initialize as not streaming
}

#pragma mark - ZPAirPlay methods (popover)

//Clean-up when tocaTintas restarts
- (void)initializeAirPlaySettings {
    // Clear selected AirPlay device state
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SelectedAirPlayDevice"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.selectedDeviceName = nil;

    // Unmute built-in speakers
    if (![self setMute:NO]) {
        #ifdef DEBUG
        NSLog(@"[Initialization] Failed to unmute built-in speakers.");
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[Initialization] Default output unmuted.");
        #endif
    }

    // Clear current AirPlay streamer if it exists
    if (self.airPlayStreamer) {
        #ifdef DEBUG
        NSLog(@"[Initialization] Stopping any active AirPlay streamer.");
        #endif
        [self.airPlayStreamer stopStreaming];
        self.airPlayStreamer = nil;
    }
}

- (void)setSelectedDeviceName:(NSString *)selectedDeviceName {
    _selectedDeviceName = selectedDeviceName;
    [self updateAirPlayButtonTint];
}

- (void)updateAirPlayButtonTint {
    if (self.selectedDeviceName) {
        self.airPlayButton.contentTintColor = [NSColor systemRedColor];
    } else {
        self.airPlayButton.contentTintColor = [NSColor labelColor]; // Default color
    }
}

// Method to show the AirPlay popover when the AirPlay button is clicked
- (void)showAirPlayPopover:(NSButton *)sender {
    self.airPlayPopover.contentViewController = [self createAirPlayPopoverContentController];

    // Force layout update
    [self.airPlayPopover.contentViewController.view layoutSubtreeIfNeeded];

    [self.airPlayPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}

// A lista é reconstruída em cima quando a descoberta muda: um aparelho que se
// anuncie com o popover aberto aparece na hora. Antes o conteúdo era desenhado
// à abertura e nunca mais mexia — e, pior, um segundo depois a descoberta
// apagava o ficheiro que o tinha alimentado, portanto o que estava à vista já
// não correspondia a nada. Era isso que obrigava a abrir o popover duas e três
// vezes até a selecção pegar.
- (void)atualizarPopoverDeAirPlay {
    if (!self.airPlayPopover.isShown) return;

    NSStackView *pilha = (NSStackView *)self.airPlayPopover.contentViewController.view;
    if (![pilha isKindOfClass:[NSStackView class]]) return;

    for (NSView *filho in [pilha.arrangedSubviews copy]) {
        [pilha removeArrangedSubview:filho];
        [filho removeFromSuperview];
    }

    // As caixas antigas foram-se com as vistas; a referência tem de ser
    // reposta pelo -populate…, senão fica a apontar para um botão órfão.
    self.currentlySelectedCheckbox = nil;

    [self populateAirPlayDevicesInStackView:pilha];
    [pilha layoutSubtreeIfNeeded];
}

- (NSViewController *)createAirPlayPopoverContentController {
    NSViewController *popoverContentController = [[NSViewController alloc] init];
    NSStackView *stackView = [[NSStackView alloc] init];
    stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    stackView.spacing = 0;
    stackView.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10); // Add padding around edges
    stackView.alignment = NSLayoutAttributeLeading;

    // Populate stack view with device names from the file
    [self populateAirPlayDevicesInStackView:stackView];
    
    // Set the stack view as the content of the view controller
    popoverContentController.view = stackView;
    
    // Apply width and height constraints to match contentSize
    [stackView.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;  // Minimum width with padding
    [stackView.heightAnchor constraintGreaterThanOrEqualToConstant:25].active = YES; // Minimum height with padding
    return popoverContentController;
}

- (void)populateAirPlayDevicesInStackView:(NSStackView *)stackView {
    // A lista vem da memória do ZPAirPlay, não de um ficheiro. Tudo o que aqui
    // chega já tem endereço e porta, portanto é seleccionável de imediato — e
    // não há janela nenhuma em que o que está à vista deixe de existir em disco.
    NSArray<ZPAparelhoAirPlay *> *dispositivos = self.airPlayManager.dispositivos;

    if (dispositivos.count == 0) {
        [stackView addArrangedSubview:[self etiquetaDeProcuraDeAirPlay]];
        return;
    }

    for (ZPAparelhoAirPlay *aparelho in dispositivos) {
        NSString *deviceName = aparelho.nome;

        // Horizontal stack for text and checkbox
        NSStackView *deviceStack = [[NSStackView alloc] init];
        deviceStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        deviceStack.distribution = NSStackViewDistributionFillProportionally;
        deviceStack.spacing = 0; // No spacing between elements
        deviceStack.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 0); // No padding

        // Device name label
        NSTextField *deviceLabel = [[NSTextField alloc] init];
        deviceLabel.stringValue = deviceName;
        deviceLabel.editable = NO;
        deviceLabel.bezeled = NO;
        deviceLabel.drawsBackground = NO;
        deviceLabel.alignment = NSTextAlignmentLeft;
        deviceLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [deviceLabel setFont:[NSFont systemFontOfSize:13]];
        [deviceStack addArrangedSubview:deviceLabel];

        // Flexible space to push checkbox to the right
        NSView *flexibleSpace = [[NSView alloc] init];
        [deviceStack addArrangedSubview:flexibleSpace];

        // Checkbox
        NSButton *deviceCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(selectAirPlayDevice:)];
        deviceCheckbox.identifier = deviceName;

        // Set checkbox state
        if ([deviceName isEqualToString:self.selectedDeviceName]) {
            deviceCheckbox.state = NSControlStateValueOn;
            self.currentlySelectedCheckbox = deviceCheckbox;
        } else {
            deviceCheckbox.state = NSControlStateValueOff;
        }

        [deviceStack addArrangedSubview:deviceCheckbox];
        [stackView addArrangedSubview:deviceStack];
    }
}

// A etiqueta em itálico do «ainda não encontrei nada». Estava escrita duas vezes
// dentro do mesmo método, com um alinhamento diferente em cada cópia.
- (NSTextField *)etiquetaDeProcuraDeAirPlay {
    NSTextField *noDevicesLabel = [[NSTextField alloc] init];

    NSFont *systemFont = [NSFont systemFontOfSize:[NSFont systemFontSize]];
    NSFontDescriptor *fontDescriptor = [systemFont.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontItalicTrait];
    NSFont *italicFont = [NSFont fontWithDescriptor:fontDescriptor size:10];

    [noDevicesLabel setFont:italicFont];
    noDevicesLabel.stringValue = NSLocalizedString(@"Searching for AirPlay devices", @"Message displayed when no AirPlay devices are found");
    noDevicesLabel.editable = NO;
    noDevicesLabel.bezeled = NO;
    noDevicesLabel.drawsBackground = NO;
    noDevicesLabel.alignment = NSTextAlignmentCenter;
    noDevicesLabel.translatesAutoresizingMaskIntoConstraints = NO;

    return noDevicesLabel;
}

// Action method for selecting an AirPlay device
// New version
- (void)selectAirPlayDevice:(NSButton *)button {
    // Check if the change is programmatic to prevent recursive calls
    if (self.isProgrammaticChange) {
        #ifdef DEBUG
        NSLog(@"[Popover selection] Ignoring programmatic change to checkbox: %@", button);
        #endif
        return;
    }

    #ifdef DEBUG
    NSLog(@"[Popover selection] selectAirPlayDevice: called with button: %@", button);
    #endif

    // Uncheck the previously selected checkbox if it's different from the current one
    if (self.currentlySelectedCheckbox && self.currentlySelectedCheckbox != button) {
        self.isProgrammaticChange = YES;
        self.currentlySelectedCheckbox.state = NSControlStateValueOff;
        self.isProgrammaticChange = NO;

        #ifdef DEBUG
        NSLog(@"[Popover selection] Unchecking previously selected checkbox: %@", self.currentlySelectedCheckbox);
        #endif
    }

    // Handle device selection
    if (button.state == NSControlStateValueOn) {
        // Update the reference to the currently selected checkbox
        self.currentlySelectedCheckbox = button;

        // Store the selected device name
        self.selectedDeviceName = button.identifier;

        // Persist the selected device name using NSUserDefaults
        [[NSUserDefaults standardUserDefaults] setObject:self.selectedDeviceName forKey:@"SelectedAirPlayDevice"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // Stop any existing AirPlay streamer
        if (self.airPlayStreamer) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Stopping existing AirPlay streamer.");
            #endif
            [self.airPlayStreamer stopStreaming];
            self.airPlayStreamer = nil;
        }

        // Retrieve the device name from the button's identifier
        NSString *deviceName = button.identifier;
        #ifdef DEBUG
        NSLog(@"[Popover selection] Retrieved device name: %@", deviceName);
        #endif

        if (deviceName == nil) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Device name not found for button: %@", button);
            #endif
            [self desfazerSeleccaoDeAirPlay:button];
            return;
        }

        // O aparelho vem da memória da descoberta, que só lá põe o que já tem
        // endereço e porta. Vir nil aqui quer dizer uma coisa só: saiu da rede
        // entre o desenho da lista e o clique.
        ZPAparelhoAirPlay *aparelho = [self.airPlayManager dispositivoComNome:deviceName];
        if (aparelho == nil) {
            NSLog(@"[Popover selection] «%@» já não está na rede; a desfazer a selecção.", deviceName);
            [self desfazerSeleccaoDeAirPlay:button];
            return;
        }

        NSString *ipAddress = aparelho.ip;
        NSString *port = aparelho.porta;

        #ifdef DEBUG
        NSLog(@"[Popover selection] Device info: %@, IP: %@, Port: %@", deviceName, ipAddress, port);
        #endif

        // Initialize and start the AirPlay streamer
        #ifdef DEBUG
        NSLog(@"[Popover selection] Initializing AirPlay streamer with IP: %@, Port: %@", ipAddress, port);
        #endif
        self.airPlayStreamer = [[ZPAirPlayStreamer alloc] initWithIPAddress:ipAddress port:port replayGainValue:self.replayGainValue];
        [self.airPlayStreamer startStreaming];
        #ifdef DEBUG
        NSLog(@"[Popover selection] AirPlay streaming started.");
        #endif

        // Colunas ou AirPlay: com a transmissão a começar, a ponte cala as
        // colunas já, sem esperar pelo temporizador de um segundo.
        [self applyBs2bConfiguration];

        // Mute the built-in speakers
        if (![self setMute:YES]) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Failed to mute built-in speakers.");
            #endif
        }
    }
    // Handle device deselection
    else if (button.state == NSControlStateValueOff) {
        // Remove the selected device from NSUserDefaults first so the
        // termination handler in ZPAirPlayStreamer won't restart streaming.
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SelectedAirPlayDevice"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // Stop the AirPlay streamer if it exists
        if (self.airPlayStreamer) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Stopping AirPlay streamer.");
            #endif
            // Set streaming state to NO to prevent restart
            self.isStreaming = NO;
            [self.airPlayStreamer stopStreaming];
            self.airPlayStreamer = nil;

            // Acabada a transmissão, as colunas voltam a ter direito ao som.
            [self applyBs2bConfiguration];
        }

        // Clear the reference to the currently selected checkbox and device name
        self.currentlySelectedCheckbox = nil;
        self.selectedDeviceName = nil;

        // Unmute the built-in speakers
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self setMute:NO]) {
                #ifdef DEBUG
                NSLog(@"[Popover selection] Failed to unmute built-in speakers.");
                #endif
            } else {
                #ifdef DEBUG
                NSLog(@"[Popover selection] Successfully unmuted built-in speakers.");
                #endif
            }
        });
    }
}

// Desfaz uma selecção que não chegou a pegar. Sem isto ficavam três estados
// desencontrados — a caixa ligada, o SelectedAirPlayDevice já gravado e nenhum
// streamer vivo —, e a única saída era desmarcar e voltar a marcar às cegas até
// calhar. Era metade do ritual dos dois ou três ciclos; a outra metade era a
// lista estar a descrever um ficheiro que a descoberta já tinha apagado.
- (void)desfazerSeleccaoDeAirPlay:(NSButton *)button {
    self.isProgrammaticChange = YES;
    button.state = NSControlStateValueOff;
    self.isProgrammaticChange = NO;

    if (self.currentlySelectedCheckbox == button) {
        self.currentlySelectedCheckbox = nil;
    }

    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SelectedAirPlayDevice"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // O setter do -selectedDeviceName é quem repõe a cor do ícone do AirPlay.
    self.selectedDeviceName = nil;
}

- (BOOL)setMute:(BOOL)mute {
    // Path to the audio_stuff_info executable in the Resources directory
    NSString *audioStuffPath = [[NSBundle mainBundle] pathForResource:@"ListAudioDevices" ofType:nil];
    
    if (!audioStuffPath) {
        #ifdef DEBUG
        NSLog(@"[Mute] Failed to locate audio_stuff_info executable in Resources.");
        #endif
        return NO;
    }

    // Run the audio_stuff_info executable
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = audioStuffPath;
    
    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = outputPipe;

    NSFileHandle *fileHandle = [outputPipe fileHandleForReading];
    
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        #ifdef DEBUG
        NSLog(@"[Mute] Failed to execute audio_stuff_info: %@", exception.reason);
        #endif
        return NO;
    }
    
    // Read and parse the output
    NSData *outputData = [fileHandle readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
    
    if (!output || [output length] == 0) {
        #ifdef DEBUG
        NSLog(@"[Mute] No output from audio_stuff_info.");
        #endif
        return NO;
    }
    
    // Search for the line containing "Built-in Output" or "Saída integrada"
    __block AudioObjectID targetDevice = 0;
    NSArray<NSString *> *lines = [output componentsSeparatedByString:@"\n"];
    [lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger idx, BOOL *stop) {
        #ifdef DEBUG
        NSLog(@"[Mute] Processing line: %@", line);
        #endif

        // Check if the line contains "Built-in Output" or "Saída integrada"
        if ([line containsString:@"MacBook Pro Speakers"] || [line containsString:@"Saída integrada"] || [line containsString:@"Colunas (MacBook Pro)"]) {
            // Extract the ID as the digits at the end of the line
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)$" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (match) {
                NSString *idString = [line substringWithRange:[match rangeAtIndex:1]];
                targetDevice = (AudioObjectID)[idString intValue];
                *stop = YES; // Exit loop once the target device is found
            }
        }
    }];

    if (targetDevice == 0) {
        #ifdef DEBUG
        NSLog(@"[Mute] Could not find device ID for 'MacBook Pro Speakers'.");
        #endif
        return NO;
    }

    // Define the property address for muting
    AudioObjectPropertyAddress propertyAddress = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        0 // Use channel 0 for master mute
    };
    
    // Set the mute state: 1 for mute, 0 for unmute
    UInt32 isMuted = mute ? 1 : 0;
    
    // Attempt to set the mute state on the target device
    OSStatus status = AudioObjectSetPropertyData(targetDevice, &propertyAddress, 0, NULL, sizeof(isMuted), &isMuted);
    
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"[Mute] Failed to %@ mute device ID %u. OSStatus: %d", mute ? @"mute" : @"unmute", targetDevice, (int)status);
        #endif
        return NO;
    }
    #ifdef DEBUG
    NSLog(@"[Mute] Successfully %@d device ID %u.", mute ? @"mute" : @"unmute", targetDevice);
    #endif
    return YES;
}

#pragma mark - Need organizing:

// Implement the application:openFile: method
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    NSURL *fileURL = [NSURL fileURLWithPath:filename];
    [self loadM3UPlaylist:fileURL];
    return YES;
}

- (void)recordAudio {
    if (self.isRecording) {
        // Stop recording
        [self.audioCapture stopCapturingAudio];
        #ifdef DEBUG
        NSLog(@"[Audio recording] Audio recording stopped.");
        #endif
        self.isRecording = NO;
    } else {
        // Start recording
        [self.audioCapture startCapturingAudio];
        #ifdef DEBUG
        NSLog(@"[Audio recording] Audio recording started.");
        #endif
        self.isRecording = YES;
    }
    [self updateRecordButtonAppearance:self.isRecording];
}

- (void)startCava {
    // Request microphone permissions (macOS)
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        if (granted) {
            // Proceed to start cava on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // Initialize the NSTask
                self.cavaTask = [[NSTask alloc] init];

                // Path to the cava executable
                NSString *cavaPath = [[NSBundle mainBundle] pathForResource:@"cava" ofType:@""];

                // Ensure the cava executable exists
                if (![[NSFileManager defaultManager] isExecutableFileAtPath:cavaPath]) {
                    #ifdef DEBUG
                    NSLog(@"cava executable not found at path: %@", cavaPath);
                    #endif
                    return;
                }

                // Get the path to the 'cava' binary directory
                NSString *cavaDirectory = [[[NSBundle mainBundle] pathForResource:@"cava" ofType:@""] stringByDeletingLastPathComponent];

                // Append the config file name to the directory path
                NSString *configPath = [cavaDirectory stringByAppendingPathComponent:@"config_fifo"];

                // Update the arguments array to use the config file path
                NSArray *arguments = @[@"-p", configPath];

                // Log the arguments to verify
                #ifdef DEBUG
                NSLog(@"Launching cava with arguments: %@", arguments);
                #endif

                // Set the launch path and arguments
                self.cavaTask.launchPath = cavaPath;
                self.cavaTask.arguments = arguments;

                // Set environment variables
                self.cavaTask.environment = [[NSProcessInfo processInfo] environment];

                // Set current directory
                self.cavaTask.currentDirectoryPath = @"/var/tmp";

                // Set standard input to null device
                self.cavaTask.standardInput = [NSFileHandle fileHandleWithNullDevice];

                // Capture standard error to log any error messages
                NSPipe *errorPipe = [NSPipe pipe];
                self.cavaTask.standardError = errorPipe;
                [[errorPipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *fileHandle) {
                    NSData *data = [fileHandle availableData];
                    if (data.length > 0) {
                        #ifdef DEBUG
                        NSString *errorOutput = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        NSLog(@"cava error: %@", errorOutput);
                        #endif
                    }
                }];

                // Optionally, capture standard output if needed
                NSPipe *outputPipe = [NSPipe pipe];
                self.cavaTask.standardOutput = outputPipe;
                [[outputPipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *fileHandle) {
                    NSData *data = [fileHandle availableData];
                    if (data.length > 0) {
                        #ifdef DEBUG
                        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        NSLog(@"cava output: %@", output);
                        #endif
                    }
                }];

                // Launch the task
                @try {
                    [self.cavaTask launch];
                    #ifdef DEBUG
                    NSLog(@"cava started with PID: %d", self.cavaTask.processIdentifier);
                    #endif
                } @catch (NSException *exception) {
                    #ifdef DEBUG
                    NSLog(@"Failed to launch cava: %@", exception.reason);
                    #endif
                }
            });
        } else {
            #ifdef DEBUG
            NSLog(@"Microphone access denied.");
            #endif
        }
    }];
}

- (void)manageCava {
    // Step 1: Terminate any extraneous instances of cava
    #ifdef DEBUG
    NSLog(@"Terminating any existing cava instances…");
    #endif
    NSString *killCommand = @"pkill -f cava";
    system([killCommand UTF8String]);

    // Step 2: Check if cava is already running
    #ifdef DEBUG
    NSLog(@"Checking if cava is running…");
    #endif
    NSString *checkCommand = @"pgrep -f cava";
    FILE *pipe = popen([checkCommand UTF8String], "r");
    if (!pipe) {
        #ifdef DEBUG
        NSLog(@"Failed to check cava status.");
        #endif
        return;
    }
    char buffer[128]; // This buffer is outside the block
    BOOL isRunning = fgets(buffer, sizeof(buffer), pipe) != NULL;
    pclose(pipe);

    if (isRunning) {
        #ifdef DEBUG
        NSLog(@"Cava is already running.");
        #endif
        // Proceed to set up health check timer
    } else {
        // Step 3: Start cava
        #ifdef DEBUG
        NSLog(@"Cava is not running. Starting it…");
        #endif
        [self startCava];
    }

    // Step 4: Set up periodic health checks
    #ifdef DEBUG
    NSLog(@"Setting up periodic health checks…");
    #endif
    static NSTimer *healthCheckTimer = nil;
    if (healthCheckTimer) {
        [healthCheckTimer invalidate]; // Ensure any existing timer is stopped
    }

    healthCheckTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        repeats:YES
                                                          block:^(NSTimer * _Nonnull timer) {
        // O popen faz fork+exec: corrido no thread principal, bloqueia o runloop
        // uns milissegundos de 30 em 30 segundos, o que se vê como um solavanco
        // periódico no histograma. Vai para uma fila de fundo.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            #ifdef DEBUG
            NSLog(@"Performing health check for cava…");
            #endif
            char healthBuffer[128];
            FILE *innerPipe = popen([checkCommand UTF8String], "r");
            if (!innerPipe) {
                #ifdef DEBUG
                NSLog(@"Failed to check cava status during health check.");
                #endif
                return;
            }
            BOOL isRunning = fgets(healthBuffer, sizeof(healthBuffer), innerPipe) != NULL;
            pclose(innerPipe);

            if (!isRunning) {
                #ifdef DEBUG
                NSLog(@"Cava is not running. Restarting…");
                #endif
                [self startCava];
            } else {
                #ifdef DEBUG
                NSLog(@"Cava is running normally.");
                #endif
            }
        });
    }];
}

#pragma mark - Headsets and bs2b:

// Helper method to detect headphones for s2b
- (BOOL)headphonesAreConnected
{
    // 1) Query the list size for all Core Audio devices
    AudioObjectPropertyAddress devicesAddr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,
                                                     &devicesAddr,
                                                     0,
                                                     NULL,
                                                     &dataSize);
    if (status != noErr || dataSize == 0) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Failed to get device list size (status = %d).", (int)status);
        #endif
        return NO;
    }

    UInt32 deviceCount = dataSize / sizeof(AudioObjectID);
    AudioObjectID *deviceIDs = (AudioObjectID *)malloc(dataSize);
    if (!deviceIDs) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Failed to allocate memory for %u devices.", (unsigned)deviceCount);
        #endif
        return NO;
    }

    status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                        &devicesAddr,
                                        0,
                                        NULL,
                                        &dataSize,
                                        deviceIDs);
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Failed to get device list (status = %d).", (int)status);
        #endif
        free(deviceIDs);
        return NO;
    }

    BOOL foundHeadphones = NO;

    // 2) Iterate over all devices and look for an OUTPUT device
    //    whose name contains our headphones substring
    for (UInt32 i = 0; i < deviceCount; ++i) {
        AudioObjectID devID = deviceIDs[i];

        // 2a) Check if this device actually has output channels
        UInt32 streamsSize = 0;
        AudioObjectPropertyAddress streamAddr = (AudioObjectPropertyAddress) {
            .mSelector = kAudioDevicePropertyStreamConfiguration,
            .mScope    = kAudioDevicePropertyScopeOutput,
            .mElement  = kAudioObjectPropertyElementMain
        };

        status = AudioObjectGetPropertyDataSize(devID,
                                                &streamAddr,
                                                0,
                                                NULL,
                                                &streamsSize);
        if (status != noErr || streamsSize == 0) {
            // No output or error: skip this device
            continue;
        }

        AudioBufferList *bufferList = (AudioBufferList *)malloc(streamsSize);
        if (!bufferList) {
            continue;
        }

        status = AudioObjectGetPropertyData(devID,
                                            &streamAddr,
                                            0,
                                            NULL,
                                            &streamsSize,
                                            bufferList);
        if (status != noErr) {
            free(bufferList);
            continue;
        }

        UInt32 totalOutputChannels = 0;
        for (UInt32 b = 0; b < bufferList->mNumberBuffers; ++b) {
            totalOutputChannels += bufferList->mBuffers[b].mNumberChannels;
        }
        free(bufferList);

        if (totalOutputChannels < 2) {
            // Not enough output channels to be interesting for stereo phones
            continue;
        }

        // 2b) Get the device's output name
        CFStringRef nameRef = NULL;
        UInt32 nameSize = sizeof(nameRef);
        AudioObjectPropertyAddress nameAddr = (AudioObjectPropertyAddress) {
            .mSelector = kAudioDevicePropertyDeviceNameCFString,
            .mScope    = kAudioDevicePropertyScopeOutput,
            .mElement  = kAudioObjectPropertyElementMain
        };

        status = AudioObjectGetPropertyData(devID,
                                            &nameAddr,
                                            0,
                                            NULL,
                                            &nameSize,
                                            &nameRef);
        if (status != noErr || !nameRef) {
            continue;
        }

        NSString *deviceName = CFBridgingRelease(nameRef);

        // 2c) Check if the name contains our headphones substring
        NSRange range = [deviceName rangeOfString:kBS2BHeadphonesNameSubstring
                                          options:NSCaseInsensitiveSearch];
        if (range.location != NSNotFound) {
            foundHeadphones = YES;
            #ifdef DEBUG
            NSLog(@"[bs2b] Found headphones output device: %@", deviceName);
            #endif
            break;
        }
    }

    free(deviceIDs);

    #ifdef DEBUG
    if (!foundHeadphones) {
        NSLog(@"[bs2b] No headphones output device containing \"%@\" found.",
              kBS2BHeadphonesNameSubstring);
    }
    #endif

    return foundHeadphones;
}

// Actualiza o bs2b_bridge em função do estado dos auscultadores
// Versão que não sabe a saída: varre e delega. Fica para quem chama de fora do
// temporizador (o observador de mudança de dispositivo, o arranque).
- (void)updateBs2bForHeadphonesConnected:(BOOL)connected
{
    [self updateBs2bForHeadphonesConnected:connected output:[self bs2bPreferredOutputDeviceName]];
}

- (void)updateBs2bForHeadphonesConnected:(BOOL)connected output:(NSString *)nomeSaida
{
    #if ENABLE_BS2B_BRIDGE
    // Borda ascendente: ligar a cavilha acende o processamento, que é o
    // comportamento de sempre; a partir daí o utilizador desliga-o à mão.
    if (connected && !self.bs2bLastHeadphonesConnected) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Auscultadores ligados.");
        #endif
        self.bs2bUserEnabled = YES;
    }

    // Borda descendente. A ponte NÃO pára: passa a levar o som às colunas, em
    // passagem limpa. Pará-la seria ficar sem som nenhum — com a saída do
    // macOS no BlackHole, é ela o único caminho até um altifalante.
    if (!connected && self.bs2bLastHeadphonesConnected) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Auscultadores desligados.");
        #endif
        self.bs2bUserEnabled = NO;
    }

    self.bs2bLastHeadphonesConnected = connected;
    [self updateBs2bToggleButtonAppearance];
    [self applyBs2bConfigurationWithOutput:nomeSaida];
    #endif
}

// Nome EXACTO do dispositivo CoreAudio para onde a ponte deve tocar: os
// auscultadores se estiverem na cavilha, senão a saída integrada. O CamillaDSP
// não faz correspondência por substring, daí devolver-se o nome tal e qual.
// Devolve nil se não houver saída nenhuma utilizável.
- (NSString *)bs2bPreferredOutputDeviceName
{
    AudioObjectPropertyAddress devicesAddr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioHardwarePropertyDevices,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &devicesAddr, 0, NULL, &dataSize) != noErr
        || dataSize == 0) {
        return nil;
    }

    AudioObjectID *deviceIDs = (AudioObjectID *)malloc(dataSize);
    if (!deviceIDs) {
        return nil;
    }
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &devicesAddr, 0, NULL, &dataSize, deviceIDs) != noErr) {
        free(deviceIDs);
        return nil;
    }

    UInt32 deviceCount = dataSize / sizeof(AudioObjectID);
    NSString *auscultadores = nil;
    NSString *integrada = nil;

    for (UInt32 i = 0; i < deviceCount && !auscultadores; ++i) {
        AudioObjectID devID = deviceIDs[i];

        // Tem saída estéreo?
        UInt32 streamsSize = 0;
        AudioObjectPropertyAddress streamAddr = (AudioObjectPropertyAddress) {
            .mSelector = kAudioDevicePropertyStreamConfiguration,
            .mScope    = kAudioDevicePropertyScopeOutput,
            .mElement  = kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, NULL, &streamsSize) != noErr || streamsSize == 0) {
            continue;
        }
        AudioBufferList *bufferList = (AudioBufferList *)malloc(streamsSize);
        if (!bufferList) {
            continue;
        }
        if (AudioObjectGetPropertyData(devID, &streamAddr, 0, NULL, &streamsSize, bufferList) != noErr) {
            free(bufferList);
            continue;
        }
        UInt32 canais = 0;
        for (UInt32 b = 0; b < bufferList->mNumberBuffers; ++b) {
            canais += bufferList->mBuffers[b].mNumberChannels;
        }
        free(bufferList);
        if (canais < 2) {
            continue;
        }

        // Nome
        CFStringRef nameRef = NULL;
        UInt32 nameSize = sizeof(nameRef);
        AudioObjectPropertyAddress nameAddr = (AudioObjectPropertyAddress) {
            .mSelector = kAudioDevicePropertyDeviceNameCFString,
            .mScope    = kAudioDevicePropertyScopeOutput,
            .mElement  = kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(devID, &nameAddr, 0, NULL, &nameSize, &nameRef) != noErr || !nameRef) {
            continue;
        }
        NSString *nome = CFBridgingRelease(nameRef);

        if ([nome rangeOfString:kBS2BHeadphonesNameSubstring options:NSCaseInsensitiveSearch].location != NSNotFound) {
            auscultadores = nome;
            continue;
        }

        // Saída integrada: escolhida pelo tipo de ligação, não pelo nome, que
        // muda com o idioma do sistema e com o modelo da máquina. O BlackHole é
        // virtual e os agregados são agregados, portanto ficam de fora.
        if (!integrada) {
            UInt32 transporte = 0;
            UInt32 transporteSize = sizeof(transporte);
            AudioObjectPropertyAddress transporteAddr = (AudioObjectPropertyAddress) {
                .mSelector = kAudioDevicePropertyTransportType,
                .mScope    = kAudioObjectPropertyScopeGlobal,
                .mElement  = kAudioObjectPropertyElementMain
            };
            if (AudioObjectGetPropertyData(devID, &transporteAddr, 0, NULL, &transporteSize, &transporte) == noErr
                && transporte == kAudioDeviceTransportTypeBuiltIn) {
                integrada = nome;
            }
        }
    }

    free(deviceIDs);

    // Sem registo aqui: isto é chamado uma vez por segundo pelo temporizador,
    // e o que interessa saber fica no registo de quem lança a ponte.
    return auscultadores ?: integrada;
}

// A ponte só faz sentido enquanto a saída do sistema for o BlackHole: é dela
// que captura. Se o utilizador puser a saída directamente nas colunas ou nuns
// auscultadores, o som já lá vai ter sozinho e a ponte só serviria para
// capturar silêncio e prender um dispositivo.
- (BOOL)systemOutputIsBlackHole
{
    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };

    AudioObjectID devID = kAudioObjectUnknown;
    UInt32 size = sizeof(devID);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, &devID) != noErr
        || devID == kAudioObjectUnknown) {
        return NO;
    }

    CFStringRef nameRef = NULL;
    UInt32 nameSize = sizeof(nameRef);
    AudioObjectPropertyAddress nameAddr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioDevicePropertyDeviceNameCFString,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };
    if (AudioObjectGetPropertyData(devID, &nameAddr, 0, NULL, &nameSize, &nameRef) != noErr || !nameRef) {
        return NO;
    }

    NSString *nome = CFBridgingRelease(nameRef);
    return [nome rangeOfString:@"BlackHole" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Ponto único que põe a ponte de acordo com o estado do mundo. Lança-a, pára-a
// ou relança-a com outra configuração, e só o faz se alguma coisa mudou.
- (void)applyBs2bConfiguration
{
    [self applyBs2bConfigurationWithOutput:[self bs2bPreferredOutputDeviceName]];
}

- (void)applyBs2bConfigurationWithOutput:(NSString *)saida
{
    #if ENABLE_BS2B_BRIDGE
    // Reentrância: este método pára e relança processos, e enquanto o faz não
    // pode ser chamado outra vez — senão a segunda chamada vê um estado a meio
    // e lança uma ponte a mais, que fica órfã. Acontecia mesmo: o temporizador
    // de um segundo entrava pelo meio (ver -stopBs2bIfRunning).
    if (self.bs2bAplicando) {
        return;
    }
    self.bs2bAplicando = YES;

    if (![self systemOutputIsBlackHole]) {
        if (self.bs2bTask && self.bs2bTask.isRunning) {
            #ifdef DEBUG
            NSLog(@"[bs2b] A saída do sistema deixou de ser o BlackHole; a parar a ponte.");
            #endif
            [self stopBs2bIfRunning];
        }
        self.bs2bAplicando = NO;
        return;
    }

    if (!saida) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Sem saída utilizável; a ponte não corre.");
        #endif
        [self stopBs2bIfRunning];
        self.bs2bAplicando = NO;
        return;
    }

    BOOL comAuscultadores =
        [saida rangeOfString:kBS2BHeadphonesNameSubstring options:NSCaseInsensitiveSearch].location != NSNotFound;

    // Colunas OU AirPlay, nunca os dois. Auscultadores com AirPlay pode, porque
    // os auscultadores tiram-se da cabeça; as colunas não se desligam, e a
    // transmissão essa desliga-se aqui mesmo, no tocaTintas.
    //
    // O indicador de transmissão é o próprio objecto: o -isStreaming do
    // controlador nunca chega a ser posto a YES em lado nenhum.
    if (!comAuscultadores && self.airPlayStreamer != nil) {
        if (self.bs2bTask && self.bs2bTask.isRunning) {
            #ifdef DEBUG
            NSLog(@"[bs2b] AirPlay a transmitir e sem auscultadores; a calar as colunas.");
            #endif
            [self stopBs2bIfRunning];
        }
        self.bs2bAplicando = NO;
        return;
    }

    // Processar só com auscultadores: o crossfeed modela a cabeça e a
    // equalização é a dos MDR-7506. Nas colunas a ponte é apenas um fio.
    BOOL processar = comAuscultadores && self.bs2bUserEnabled;

    if (self.bs2bTask && self.bs2bTask.isRunning
        && [self.bs2bRunningOutputName isEqualToString:saida]
        && [self.bs2bRunningProfile isEqualToString:ZPCurrentBS2BProfile()]
        && [self.bs2bRunningEq isEqualToString:ZPCurrentBS2BEq()]
        && self.bs2bRunningProcessing == processar) {
        self.bs2bAplicando = NO;
        return;   // já está como deve estar
    }

    [self stopBs2bIfRunning];
    [self startBs2bWithOutputDevice:saida processing:processar];
    self.bs2bAplicando = NO;
    #endif
}

// Repõe o aspecto do botão a partir do bs2bUserEnabled. Símbolo SF sem borda,
// o mesmo molde do botão de AirPlay desta janela: desenha-se sempre. O radio
// sem etiqueta que aqui estava antes não pintava nada aos 16 px.
// Três estados: sem auscultadores nada acontece; com auscultadores, o círculo
// azul é o processamento ligado e o mesmo círculo em branco é a passagem limpa.
//
//   auscultadores fora        -> auscultadores cinzentos, sem círculo
//   dentro, CamillaDSP activo -> círculo cheio azul
//   dentro, CamillaDSP parado -> o mesmo círculo cheio, branco
//
// «Parado» quer dizer sem crossfeed nem equalização — a ponte continua a
// correr, porque é ela que leva o som do BlackHole aos auscultadores.
- (void)updateBs2bToggleButtonAppearance
{
    NSButton *botao = self.bs2bToggleButton;
    if (!botao) {
        return;
    }

    BOOL comAuscultadores = self.bs2bLastHeadphonesConnected;
    BOOL processar = comAuscultadores && self.bs2bUserEnabled;

    NSString *nomeSimbolo;
    NSColor *cor;
    NSString *dica;

    if (!comAuscultadores) {
        nomeSimbolo = @"headphones";
        cor  = [NSColor secondaryLabelColor];
        dica = @"Sem auscultadores na cavilha. O filtro só se liga com eles.";
    } else if (processar) {
        nomeSimbolo = @"headphones.circle.fill";
        cor  = [NSColor controlAccentColor];
        dica = @"Filtro de áudio ligado (crossfeed e equalização). Carregar para desligar.";
    } else {
        // O mesmo símbolo cheio do estado azul, só que branco: o que distingue
        // os dois estados é a cor, não o desenho. A variante sem «.fill» dava
        // uma circunferência vazia, que se lê como outra coisa.
        nomeSimbolo = @"headphones.circle.fill";
        cor  = [NSColor whiteColor];
        dica = @"Filtro de áudio desligado; o som passa sem tratamento. Carregar para ligar.";
    }

    NSImage *icone = [NSImage imageWithSystemSymbolName:nomeSimbolo
                                accessibilityDescription:@"Filtro de áudio"];
    if (icone) {
        NSImageSymbolConfiguration *config =
            [NSImageSymbolConfiguration configurationWithPointSize:15
                                                            weight:NSFontWeightRegular];
        icone = [icone imageWithSymbolConfiguration:config];
        [icone setTemplate:YES];
        botao.image = icone;
        botao.imagePosition = NSImageOnly;
        botao.title = @"";
    } else {
        // Sem símbolo não ficamos com um botão invisível: cai-se no texto.
        botao.image = nil;
        botao.imagePosition = NSNoImage;
        botao.title = processar ? @"◉" : @"◎";
    }

    botao.contentTintColor = cor;
    botao.toolTip = dica;
}

// Clique no botão: liga ou desliga o processamento. Não pára a ponte.
- (void)toggleBs2bFilter:(id)sender
{
    #if ENABLE_BS2B_BRIDGE
    // Sem auscultadores não há nada para alternar: o crossfeed e a equalização
    // são para eles. Apita e fica tudo na mesma.
    if (![self headphonesAreConnected]) {
        NSBeep();
        self.bs2bUserEnabled = NO;
        [self updateBs2bToggleButtonAppearance];
        return;
    }

    self.bs2bUserEnabled = !self.bs2bUserEnabled;

    #ifdef DEBUG
    NSLog(@"[bs2b] Processamento %@ pelo utilizador.", self.bs2bUserEnabled ? @"ligado" : @"desligado");
    #endif

    [self updateBs2bToggleButtonAppearance];
    // Relança a ponte com o outro perfil. Há um corte de som de uma fracção de
    // segundo: o CamillaDSP não troca de configuração sem reabrir os
    // dispositivos, e não vale a pena montar-lhe o canal de controlo por isto.
    [self applyBs2bConfiguration];
    #else
    self.bs2bUserEnabled = NO;
    [self updateBs2bToggleButtonAppearance];
    #endif
}

- (void)setupBs2bHeadphoneMonitoring
{
    #if ENABLE_BS2B_BRIDGE
    // Mudar a normalização nas preferências reenvia o ganho de imediato.
    __weak typeof(self) weakSelfNorm = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:kAirPlayNormalizationChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *nota) {
        [weakSelfNorm pushReplayGainToStreamer];
    }];

    // Mudar a equalização nas preferências relança a ponte com ela.
    __weak typeof(self) weakSelfEq = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:kBS2BEqChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *nota) {
        [weakSelfEq applyBs2bConfiguration];
    }];

    // Mudar o perfil nas preferências relança a ponte com ele.
    __weak typeof(self) weakSelfPerfil = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:kBS2BProfileChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *nota) {
        [weakSelfPerfil applyBs2bConfiguration];
    }];

    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };

    __weak typeof(self) weakSelf = self;

    AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject,
                                        &addr,
                                        dispatch_get_main_queue(),
                                        ^(UInt32 inNumberAddresses,
                                          const AudioObjectPropertyAddress *inAddresses) {

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        #ifdef DEBUG
        NSLog(@"[bs2b] Default output device changed.");
        #endif

        BOOL connected = [strongSelf headphonesAreConnected];
        [strongSelf updateBs2bForHeadphonesConnected:connected];
    });

    // Estado inicial (app arranca já com phones ligados?)
    BOOL connected = [self headphonesAreConnected];
    self.bs2bLastHeadphonesConnected = !connected;  // força tratamento como "borda"
    [self updateBs2bForHeadphonesConnected:connected];
    #endif
}

- (void)teardownBs2bHeadphoneMonitoring
{
    #if ENABLE_BS2B_BRIDGE
    AudioObjectPropertyAddress addr = (AudioObjectPropertyAddress) {
        .mSelector = kAudioHardwarePropertyDefaultOutputDevice,
        .mScope    = kAudioObjectPropertyScopeGlobal,
        .mElement  = kAudioObjectPropertyElementMain
    };

    AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject,
                                           &addr,
                                           dispatch_get_main_queue(),
                                           ^(UInt32 inNumberAddresses,
                                             const AudioObjectPropertyAddress *inAddresses) {
                                               // Block must match; in prática o runtime trata disto.
                                           });
    #endif
}

- (void)pollBs2bHeadphones
{
    #if ENABLE_BS2B_BRIDGE
    // UMA varredura de dispositivos por sondagem, e o resultado serve para as
    // duas perguntas: há auscultadores? e para onde deve a ponte tocar?
    //
    // Isto não é micro-optimização. Cada varredura consulta o HAL quatro vezes
    // por dispositivo, e há aqui nove dispositivos (três deles agregados).
    // Estava a correr três varreduras por segundo — a de -headphonesAreConnected,
    // a de -bs2bPreferredOutputDeviceName e a de novo dentro do apply — na
    // thread principal, contra o mesmo coreaudiod de que dependem o camilladsp
    // e a captura do AirPlay. São cerca de 180 consultas por segundo em vez de 60.
    NSString *saida = [self bs2bPreferredOutputDeviceName];
    BOOL connected = (saida != nil) &&
        [saida rangeOfString:kBS2BHeadphonesNameSubstring options:NSCaseInsensitiveSearch].location != NSNotFound;

    [self updateBs2bForHeadphonesConnected:connected output:saida];
    #endif

    // Fora do #if de propósito: o atraso do histograma não depende da ponte, e
    // a sondagem de um segundo é a cadência certa — o raop_play escreve os
    // tempos uma vez por segundo, não há resolução mais fina para aproveitar.
    [self actualizarAtrasoDoHistograma];
}

// Quanto tem o histograma de se atrasar para coincidir com o que se está mesmo
// a ouvir.
//
// Com auscultadores na cavilha ouve-se o som local, sem atraso nenhum, e nesse
// caso o histograma tem de acertar com esse — mesmo que o AirPlay esteja a
// transmitir ao mesmo tempo, que é caso permitido (as colunas é que não, ver
// -applyBs2bConfiguration). Sem auscultadores, o que se ouve é o aparelho
// AirPlay, e aí o histograma atrasa-se o que o ZPAirPlayStreamer medir.
//
// Zero de `remoteAudioLag` significa «não sei», e não «estão sincronizados»:
// por isso a pergunta é feita ao `raopClockIsRunning` primeiro.
- (void)actualizarAtrasoDoHistograma {
    double atraso = 0.0;

    ZPAirPlayStreamer *streamer = self.airPlayStreamer;
    if (streamer && !self.bs2bLastHeadphonesConnected && streamer.raopClockIsRunning) {
        atraso = streamer.remoteAudioLag;
    }

    if (!(atraso > 0.0)) atraso = 0.0;                                  // NaN incluído
    if (atraso > kZPAtrasoMaximoDoHistograma) atraso = kZPAtrasoMaximoDoHistograma;

    atomic_store(&gAtrasoDoHistograma, atraso);
}

- (void)startBs2bHeadphoneAutoStart
{
    #if ENABLE_BS2B_BRIDGE
    if (self.bs2bHeadphonePollTimer) {
        return; // já está activo
    }

    // Estado inicial forçado via poll
    self.bs2bLastHeadphonesConnected = NO;
    [self pollBs2bHeadphones];

    self.bs2bHeadphonePollTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                         target:self
                                       selector:@selector(pollBs2bHeadphones)
                                       userInfo:nil
                                        repeats:YES];
    #endif
}

- (void)stopBs2bHeadphoneAutoStart
{
    #if ENABLE_BS2B_BRIDGE
    [self.bs2bHeadphonePollTimer invalidate];
    self.bs2bHeadphonePollTimer = nil;
    #endif
}

// Mantido para os sítios que ligam a ponte à reprodução (mudar de faixa,
// carregar em tocar): hoje é só um pedido para pôr tudo de acordo.
- (void)startBs2bIfNeeded {
    [self applyBs2bConfiguration];
}

- (void)startBs2bWithOutputDevice:(NSString *)nomeSaida processing:(BOOL)processar {
    #if ENABLE_BS2B_BRIDGE
    if (self.bs2bTask && self.bs2bTask.isRunning) {
        NSLog(@"[bs2b] ARRANQUE recusado: já há uma ponte viva (pid %d).",
              self.bs2bTask.processIdentifier);
        return;
    }

    NSString *bridgePath = [[NSBundle mainBundle] pathForResource:@"bs2b_bridge" ofType:nil];
    if (!bridgePath) {
        #ifdef DEBUG
        NSLog(@"[bs2b] bs2b_bridge not found in app bundle.");
        #endif
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = bridgePath;

    // --saida: o destino é sempre dito de fora, porque muda com a cavilha.
    // Note-se que «desligado» não pára a ponte: ela continua a ser o caminho do
    // som. São três casos, não dois:
    //
    //   auscultadores, tratamento ligado  -> crossfeed e equalização
    //   auscultadores, tratamento parado  -> --sem-processamento: passagem
    //       limpa, mas atenuada nos mesmos 7,33 dB que o crossfeed e o «preamp»
    //       da equalização lhe tirariam. O botão passa a comparar o efeito e
    //       não o volume, que é o que engana o ouvido.
    //   colunas                           -> --perfil nenhum: passagem limpa a
    //       0 dB. Aqui não há nada com que igualar o nível.
    BOOL comAuscultadores =
        [nomeSaida rangeOfString:kBS2BHeadphonesNameSubstring options:NSCaseInsensitiveSearch].location != NSNotFound;

    // O perfil e a equalização vêm das preferências. A equalização é vazia
    // (nenhuma), "builtin" (a dos MDR-7506) ou o caminho de um ParametricEQ.txt.
    NSString *perfil = ZPCurrentBS2BProfile();
    NSString *eq     = ZPCurrentBS2BEq();

    NSArray<NSString *> * (^argumentosEq)(void) = ^NSArray<NSString *> *{
        if ([eq isEqualToString:@"builtin"]) return @[@"--eq"];
        if (eq.length > 0)                   return @[@"--eq", eq];
        return @[];
    };

    NSMutableArray<NSString *> *argumentos = [@[@"--saida", nomeSaida] mutableCopy];

    // Dois interruptores escondidos, sem interface, para experimentar com os
    // estalidos de arranque sem recompilar. Nenhum mexe em nada por omissão:
    //
    //   defaults write JPSdA.tocaTintas bs2bSemAjusteRelogio -bool YES
    //   defaults write JPSdA.tocaTintas bs2bNivelAlvo -int 3072
    //
    // O primeiro desliga a correcção de deriva entre relógios; o segundo dá
    // folga ao tampão (tem de ser >= chunksize, que são 1024 tramas).
    NSUserDefaults *prefs = [NSUserDefaults standardUserDefaults];

    // Terceiro interruptor escondido: um caminho de ficheiro onde despejar o
    // que a ponte e o CamillaDSP escrevem. Com ele, tira-se também o
    // --silencioso, e o CamillaDSP sobe de «error» para «warn» — que é o nível
    // onde ele diz «buffer underrun» e «clipping detected».
    //
    //   defaults write JPSdA.tocaTintas bs2bRegisto -string /tmp/bs2b.log
    //
    NSString *caminhoRegisto = [prefs stringForKey:@"bs2bRegisto"];

    if ([prefs boolForKey:@"bs2bSemAjusteRelogio"]) {
        [argumentos addObject:@"--sem-ajuste-relogio"];
    }
    NSInteger nivelAlvo = [prefs integerForKey:@"bs2bNivelAlvo"];
    if (nivelAlvo > 0) {
        [argumentos addObjectsFromArray:@[@"--nivel-alvo", [NSString stringWithFormat:@"%ld", (long)nivelAlvo]]];
    }
    if (processar) {
        [argumentos addObjectsFromArray:@[@"--perfil", perfil]];
        [argumentos addObjectsFromArray:argumentosEq()];
    } else if (comAuscultadores) {
        // A equalização vai na mesma, para o --sem-processamento poder contar
        // com o «preamp» dela ao igualar o nível.
        [argumentos addObjectsFromArray:@[@"--perfil", perfil]];
        [argumentos addObjectsFromArray:argumentosEq()];
        [argumentos addObject:@"--sem-processamento"];
    } else {
        [argumentos addObjectsFromArray:@[@"--perfil", @"nenhum"]];
    }
    if (!caminhoRegisto.length) {
        [argumentos addObject:@"--silencioso"];
    }
    task.arguments = argumentos;

    // Para onde vai o que a ponte escreve. Isto NÃO pode ser um NSPipe que
    // ninguém leia: o cano tem 64 KB, e quando enche o processo do outro lado
    // BLOQUEIA na escrita — com o CamillaDSP, bloquear é ficar sem áudio.
    // Sem registo pedido, vai tudo para o dispositivo nulo.
    NSFileHandle *destinoRegisto = [NSFileHandle fileHandleWithNullDevice];
    if (caminhoRegisto.length) {
        // Criar só se não existir: truncar a cada relançamento apagava
        // precisamente o que interessa ler.
        if (![[NSFileManager defaultManager] fileExistsAtPath:caminhoRegisto]) {
            [[NSFileManager defaultManager] createFileAtPath:caminhoRegisto contents:nil attributes:nil];
        }
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:caminhoRegisto];
        if (f) {
            [f seekToEndOfFile];
            destinoRegisto = f;
        }
    }
    task.standardOutput = destinoRegisto;
    task.standardError  = destinoRegisto;

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.bs2bTask == finishedTask) {
                weakSelf.bs2bTask = nil;
                weakSelf.bs2bRunningOutputName = nil;
            }
            #ifdef DEBUG
            NSLog(@"[bs2b] bs2b_bridge terminated (exitStatus=%d).",
                  finishedTask.terminationStatus);
            #endif
        });
    };

    @try {
        [task launch];
        self.bs2bTask = task;
        self.bs2bRunningOutputName = nomeSaida;
        self.bs2bRunningProfile = perfil;
        self.bs2bRunningEq = eq;
        self.bs2bRunningProcessing = processar;
        NSLog(@"[bs2b] ARRANQUE pid %d: perfil «%@», eq «%@», processamento %@, saída «%@».",
              task.processIdentifier, perfil, eq.length ? eq.lastPathComponent : @"nenhuma",
              processar ? @"ligado" : @"desligado", nomeSaida);
    } @catch (NSException *exception) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Failed to launch bs2b_bridge: %@", exception);
        #endif
        self.bs2bTask = nil;
        self.bs2bRunningOutputName = nil;
    }
    #endif
}

- (void)stopBs2bIfRunning {
        #if ENABLE_BS2B_BRIDGE
    NSLog(@"[bs2b] PARAGEM pedida: task=%@ pid=%d aRcorrer=%d",
          self.bs2bTask ? @"sim" : @"NIL",
          self.bs2bTask ? self.bs2bTask.processIdentifier : -1,
          self.bs2bTask ? self.bs2bTask.isRunning : -1);

    if (self.bs2bTask && self.bs2bTask.isRunning) {
        NSTask *aMorrer = self.bs2bTask;
        [aMorrer terminate];

        // Esperar SEM bombear o run loop.
        //
        // O -waitUntilExit do NSTask não bloqueia: corre o run loop enquanto
        // espera. Isso deixava entrar aqui pelo meio o temporizador de um
        // segundo, que chamava outra vez o -applyBs2bConfiguration, via um
        // -stopBs2bIfRunning aninhado — e no fim ficavam duas pontes vivas por
        // cada mudança de perfil, uma delas órfã. Medido no registo: duas
        // paragens do mesmo pid com 6 ms de intervalo.
        //
        // Esperamos na mesma, porque o CamillaDSP pede acesso exclusivo ao
        // dispositivo e o seguinte falharia se o anterior ainda o tivesse. Mas
        // esperamos a dormir, não a correr o run loop, e com um tecto.
        for (int i = 0; i < 60 && aMorrer.isRunning; ++i) {
            usleep(10 * 1000);
        }
        if (aMorrer.isRunning) {
            NSLog(@"[bs2b] A ponte pid %d não morreu em 600 ms.", aMorrer.processIdentifier);
        }
    }
    self.bs2bTask = nil;
    self.bs2bRunningOutputName = nil;
    self.bs2bRunningProfile = nil;
    self.bs2bRunningEq = nil;
            #endif
}

#pragma mark - Recent Menu and Documents:

- (void)setupOpenRecentMenu {
    // Get the recent documents URLs from NSDocumentController
    NSArray<NSURL *> *recentDocumentsURLs = [[NSDocumentController sharedDocumentController] recentDocumentURLs];

    // Create a new menu for recent documents
    NSMenu *recentDocumentsMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];

    for (NSURL *documentURL in recentDocumentsURLs) {
        NSString *documentTitle = [documentURL lastPathComponent];
        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:documentTitle
                                                          action:@selector(openRecentDocument:)
                                                   keyEquivalent:@""];
        [menuItem setRepresentedObject:documentURL];
        [recentDocumentsMenu addItem:menuItem];
    }

    // Set the submenu of the 'Open Recent' menu item
    [self.openRecentMenuItem setSubmenu:recentDocumentsMenu];
}

- (void)openRecentDocument:(NSMenuItem *)menuItem {
    NSURL *documentURL = [menuItem representedObject];
    
    // Ensure documentURL is not nil
    if (documentURL) {
        [[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL:documentURL
                                                                               display:YES
                                                                     completionHandler:^(NSDocument * _Nullable document, BOOL documentWasAlreadyOpen, NSError * _Nullable error) {
            if (error) {
                // Handle the error, e.g., show an alert to the user
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Unable to Open Document";
                alert.informativeText = [NSString stringWithFormat:@"An error occurred while opening the document: %@", error.localizedDescription];
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
            } else {
                // Optionally perform additional actions if needed
                #ifdef DEBUG
                NSLog(@"Document opened successfully.");
                #endif
            }
        }];
    } else {
        // Handle the case where the documentURL is nil
        #ifdef DEBUG
        NSLog(@"Error: documentURL is nil.");
        #endif
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Unable to Open Document";
        alert.informativeText = @"The selected document could not be opened because the file URL is invalid.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Access the Application menu (first menu item in the main menu)
    NSMenu *appMenu = [[[NSApplication sharedApplication] mainMenu] itemAtIndex:0].submenu;
    
    // Find the About menu item within the Application menu
    NSMenuItem *aboutMenuItem = [appMenu itemWithTitle:@"About"];
    
    if (aboutMenuItem) {
        [aboutMenuItem setAction:@selector(showCustomAboutPanel:)];
        [aboutMenuItem setTarget:self];
        [aboutMenuItem setEnabled:YES];
    }
    [self initializeAirPlaySettings];
    [self startBs2bHeadphoneAutoStart];
    [self setupBs2bHeadphoneMonitoring];
}

- (NSString *)localizedVersionStringWithVersion:(NSString *)version {
    NSString *localizedString = NSLocalizedStringFromTable(@"Version %@ is installed.", @"Localizable", @"Version label with version number");
    return [NSString stringWithFormat:localizedString, version];
}

- (IBAction)showCustomAboutPanel:(id)sender {
    if (!self.aboutPanel) {
        NSRect windowFrame = NSMakeRect(0, 0, 250, 300);  // Updated window width to 250, height remains 300
        self.aboutPanel = [[NSPanel alloc] initWithContentRect:windowFrame
                                                     styleMask:(NSWindowStyleMaskTitled |
                                                                NSWindowStyleMaskClosable)
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        NSString *localizedTitle = NSLocalizedStringFromTable(@"About tocaTintas", @"Localizable", @"Window title for the About panel");
        [self.aboutPanel setTitle:localizedTitle];
        [self.aboutPanel center];
        self.aboutPanel.delegate = self; // Set delegate

        // Calculate the center of the window
        CGFloat panelHeight = NSHeight(windowFrame);
        CGFloat totalContentHeight = 300; // Approximate total height of content

        CGFloat yOffset = (panelHeight - totalContentHeight) / 2;

        // 1. App Icon (Centered)
        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(75, yOffset + 180, 100, 100)]; // Adjusted x-position for smaller width
        NSImage *appIcon = [NSImage imageNamed:NSImageNameApplicationIcon];
        [iconView setImage:appIcon];
        [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [[self.aboutPanel contentView] addSubview:iconView];

        // 2. App Name (Centered)
        NSTextField *appNameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(25, yOffset + 150, 200, 20)]; // Adjusted x-position for smaller width
        [appNameLabel setStringValue:@"tocaTintas"];
        [appNameLabel setBezeled:NO];
        [appNameLabel setDrawsBackground:NO];
        [appNameLabel setEditable:NO];
        [appNameLabel setSelectable:NO];
        [appNameLabel setFont:[NSFont boldSystemFontOfSize:16]];
        [appNameLabel setAlignment:NSTextAlignmentCenter];
        [[self.aboutPanel contentView] addSubview:appNameLabel];

        // 3. Version (Centered)
        NSTextField *versionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(25, yOffset + 120, 200, 20)]; // Adjusted x-position for smaller width
        
        // Localize the version string
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *localizedVersion = [self localizedVersionStringWithVersion:version];
        [versionLabel setStringValue:localizedVersion];
        
        [versionLabel setBezeled:NO];
        [versionLabel setDrawsBackground:NO];
        [versionLabel setEditable:NO];
        [versionLabel setSelectable:NO];
        [versionLabel setFont:[NSFont systemFontOfSize:10]];
        [versionLabel setAlignment:NSTextAlignmentCenter];
        [[self.aboutPanel contentView] addSubview:versionLabel];

        // 4. Copyright / Credits (Centered)
        NSTextField *creditsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, yOffset + 50, 250, 60)]; // Adjusted width to match the window size
        [creditsLabel setStringValue:@"© 2026 Zé Pedro do Amaral"];
        [creditsLabel setBezeled:NO];
        [creditsLabel setDrawsBackground:NO];
        [creditsLabel setEditable:NO];
        [creditsLabel setSelectable:NO];
        [creditsLabel setAlignment:NSTextAlignmentCenter];
        [creditsLabel setFont:[NSFont systemFontOfSize:12]];
        [[self.aboutPanel contentView] addSubview:creditsLabel];

        // 5. Close Button (Centered)
        NSButton *closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(75, yOffset + 20, 100, 30)]; // Adjusted x-position for smaller width

        // Localize the button title
        NSString *localizedCloseTitle = NSLocalizedStringFromTable(@"Close", @"Localizable", @"Close button label");
        [closeButton setTitle:localizedCloseTitle];
        [closeButton setButtonType:NSButtonTypeMomentaryPushIn];
        [closeButton setBezelStyle:NSBezelStyleRounded];
        [closeButton setTarget:self];
        [closeButton setAction:@selector(closeAboutPanel:)];
        [[self.aboutPanel contentView] addSubview:closeButton];
    }

    // Show the About panel
    [self.aboutPanel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES]; // Bring the app to the foreground
}

- (void)closeAboutPanel:(id)sender {
    [self.aboutPanel orderOut:nil]; // Order the panel out, keeping it in memory
}

- (void)viewDidAppear {
    [super viewDidAppear];

    // Log the current responder chain to check if the ViewController is in the chain
    NSResponder *responder = [self.view.window firstResponder];
    while (responder) {
        #ifdef DEBUG
        NSLog(@"Responder: %@", responder);
        #endif
        responder = [responder nextResponder];
    }
}

- (IBAction)openPreferences:(id)sender {
    // Check if the preferences window is already open or created
    if (!self.preferencesWindowController) {
        // Load the Preferences window from the storyboard
        NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
        
        // Instantiate the window controller using the identifier you assigned in the storyboard
        self.preferencesWindowController = [storyboard instantiateControllerWithIdentifier:@"PreferencesWindowController1"];
    }
    
    // Show the Preferences window
    [self.preferencesWindowController showWindow:self];
}

- (void)saveSongsDirectoryPath:(NSString *)path {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:path forKey:@"songsDirectoryPath"];
    [defaults synchronize];  // Save the path to user defaults

    // Debug log to confirm the path is saved correctly
    #ifdef DEBUG
    NSLog(@"Saved songs directory path: %@", path);
    #endif
}

- (NSString *)loadSongsDirectoryPath {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedPath = [defaults stringForKey:@"songsDirectoryPath"];
    
    // Log to ensure the path is loaded correctly
    #ifdef DEBUG
    NSLog(@"Loaded songs directory path: %@", savedPath);
    #endif
    // If no custom path is set, return the default path
    if (savedPath == nil) {
        savedPath = @"/Users/amaral/Downloads/CDs";  // Default path
    }
    
    return savedPath;
}

- (void)dealloc {
    // O FSEventStream guarda um ponteiro não retido para self; tem de ser parado aqui.
    [self stopWatchingSongsDirectory];

    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:@"SongsDirectoryPathChanged"
                                                  object:nil];
    // Invalidate the refresh timer to stop it from firing after the view controller is deallocated
    //[self.refreshTimer invalidate];
    
    // Remove any observers added by this instance of ViewController
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Method to handle the directory path change notification
- (void)handleDirectoryPathChange:(NSNotification *)notification {
    NSString *newPath = notification.userInfo[@"newPath"];
    #ifdef DEBUG
    NSLog(@"New Path from Notification: %@", newPath);
    #endif

    // Save the new path
    [self saveSongsDirectoryPath:newPath];

    // Preserve the currently playing track's path before updating any state
    NSString *currentTrackPath = nil;
    if (self.currentTrackIndex >= 0) {
        NSURL *currentTrackURL = nil;
        if (self.isShuffleModeActive && self.shuffledTracks.count > self.currentTrackIndex) {
            currentTrackURL = self.shuffledTracks[self.currentTrackIndex];
        } else if (self.audioFiles.count > self.currentTrackIndex) {
            currentTrackURL = self.audioFiles[self.currentTrackIndex];
        }
        if (currentTrackURL) {
            currentTrackPath = [currentTrackURL.path stringByStandardizingPath];
        }
    }

    // Clear cached audio files and modification date
    self.cachedAudioFiles = nil;
    self.directoryModificationDate = nil;
    self.hasCompletedInitialScan = NO;

    // Passar a vigiar a pasta nova
    [self startWatchingSongsDirectory];

    // Exit playlist mode after preserving the current track
    self.isPlaylistModeActive = NO;

    // Reload the audio files from the new directory
    [self loadAudioFiles];  // This will also refresh the combo box

    // Reinitialize shuffled tracks if shuffle mode is active
    if (self.isShuffleModeActive) {
        [self initializeShuffledTrackList];
    }

    // Search for the current track in the new directory. -loadAudioFiles já repõe o
    // índice, mas a baralhação acima cria uma ordem nova, pelo que é preciso voltar
    // a localizar a faixa em reprodução.
    NSInteger newIndex = NSNotFound;
    if (currentTrackPath) {
        NSArray<NSURL *> *searchArray = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
        for (NSInteger i = 0; i < (NSInteger)searchArray.count; i++) {
            NSString *trackPath = [searchArray[i].path stringByStandardizingPath];
            if ([trackPath compare:currentTrackPath options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                newIndex = i;
                break;
            }
        }
    }

    if (newIndex != NSNotFound) {
        // A faixa em reprodução também existe na nova directoria: continua sem
        // interrupção e a faixa seguinte é a que lhe sucede na nova lista.
        self.currentTrackIndex = newIndex;
    } else {
        // A faixa deixou de existir na nova directoria; a reprodução actual não é
        // interrompida, mas a lista recomeça do princípio.
        self.currentTrackIndex = 0;
    }

    #ifdef DEBUG
    NSLog(@"Directory changed: current track %@ (index %ld)",
          (newIndex != NSNotFound) ? @"preserved" : @"not found in the new directory",
          (long)self.currentTrackIndex);
    #endif

    // Update combo box selection
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createComboBox];
        [self.songComboBox selectItemAtIndex:[self comboBoxIndexForCurrentTrack]];
    });
    // Optionally start playback from the first track
    //if (self.audioFiles.count > 0) {
        //[self playAudio];
    //}
}

- (void)validatePlaylistFiles {
    NSMutableArray<NSURL *> *validFiles = [NSMutableArray array];
    for (NSURL *fileURL in self.audioFiles) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            [validFiles addObject:fileURL];
        } else {
            #ifdef DEBUG
            NSLog(@"File not found: %@", fileURL.path);
            #endif
        }
    }

    if (validFiles.count == 0) {
        // All files have been removed, exit playlist mode
        self.audioFiles = @[];
        // Pela porta do costume, para que a lista baralhada e o índice fiquem a
        // contar posições na biblioteca e não na lista que desapareceu.
        [self exitPlaylistMode];
    } else if (validFiles.count < self.audioFiles.count) {
        // Some files have been removed
        self.audioFiles = [validFiles copy];
        // Adjust currentTrackIndex if necessary
        if (self.currentTrackIndex >= (NSInteger)self.audioFiles.count) {
            self.currentTrackIndex = (NSInteger)self.audioFiles.count - 1;
        }
    }
}

#pragma mark - Play count

// Segundos de audição a partir dos quais uma faixa conta como tocada.
static const NSTimeInterval kPlayCountThreshold = 5.0;

// Play count methods
// New method to handle play count increment after the timer fires
- (void)handlePlayCountIncrement:(NSTimer *)timer {
    NSString *trackPath = (NSString *)timer.userInfo;

    self.playCountTimer = nil;
    self.playCountDeadline = nil;

    // Só conta se a faixa acompanhada ainda for esta (não se avançou entretanto) e
    // se esta reprodução ainda não tiver sido contada.
    if (![trackPath isKindOfClass:[NSString class]] ||
        ![trackPath isEqualToString:self.playCountTrackPath] ||
        self.playCountAlreadyCounted) {
        #ifdef DEBUG
        NSLog(@"Contagem ignorada para %@ (faixa acompanhada: %@, já contada: %d)",
              trackPath, self.playCountTrackPath, self.playCountAlreadyCounted);
        #endif
        return;
    }

    self.playCountAlreadyCounted = YES;
    self.playCountRemaining = 0.0;

    // Increment the play count and update the label for the original track URL
    [self incrementPlayCountForTrack:[NSURL fileURLWithPath:trackPath]];
}

// Counting playback times
- (void)incrementPlayCountForTrack:(NSURL *)trackURL {
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;
    NSString *trackPath = originalTrackURL.path;
    
    NSNumber *currentCount = [self.trackPlayCounts objectForKey:trackPath];
    
    if (currentCount) {
        [self.trackPlayCounts setObject:@(currentCount.integerValue + 1) forKey:trackPath];
    } else {
        [self.trackPlayCounts setObject:@1 forKey:trackPath];
    }
    
    // Save play count changes
    [self saveTrackPlayCounts];

    // Always update the play count label, even if repeat is toggled off
    [self refreshPlayCountLabel];

    // Update the “Now Playing” webpage with the new tally
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self generateNowPlayingPage];
    });
}

// Ponto de entrada usado por quem inicia reprodução. Não força uma contagem nova:
// se for a mesma faixa que já está a ser acompanhada, trata-se de uma retoma.
- (void)schedulePlayCountIncrementForTrack:(NSURL *)trackURL {
    [self beginPlayCountTrackingForTrack:trackURL forceNewPlayback:NO];
}

// Inicia — ou retoma — o acompanhamento da contagem de uma faixa.
//
// forceNewPlayback: YES quando a mesma faixa recomeça de facto do início (modo de
// repetição depois de terminar), e por isso deve poder voltar a contar. NO nos
// restantes casos: se a faixa acompanhada não mudou, isto é uma retoma e o estado
// existente é preservado — nem se volta a contar, nem se reinicia o prazo.
- (void)beginPlayCountTrackingForTrack:(NSURL *)trackURL forceNewPlayback:(BOOL)forceNewPlayback {
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;
    NSString *trackPath = originalTrackURL.path;
    if (trackPath.length == 0) {
        return;
    }

    dispatch_block_t beginBlock = ^{
        if (!forceNewPlayback && [self.playCountTrackPath isEqualToString:trackPath]) {
            // Mesma faixa: retoma. Se o prazo ainda não tinha terminado, continua
            // de onde ficou; se já contou, não conta outra vez.
            #ifdef DEBUG
            NSLog(@"Retoma de %@ — contagem mantida (já contada: %d, faltam %.1f s)",
                  trackPath.lastPathComponent, self.playCountAlreadyCounted, self.playCountRemaining);
            #endif
            [self resumePlayCountTracking];

            // Repor o rótulo: quem chamou pode tê-lo limpado ao reiniciar a
            // reprodução, e esta faixa já tem a contagem feita.
            [self refreshPlayCountLabel];
            return;
        }

        // Faixa nova (ou reprodução genuinamente nova): começar do zero.
        [self resetPlayCountTracking];
        self.playCountTrackPath = trackPath;
        self.playCountRemaining = kPlayCountThreshold;
        [self resumePlayCountTracking];

        // Faixa nova ainda não contada: o rótulo fica vazio até o prazo terminar.
        [self refreshPlayCountLabel];
    };

    // Guarantee the timer is always created on the main thread
    if ([NSThread isMainThread]) {
        beginBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), beginBlock);
    }
}

// Suspende a contagem decrescente sem perder o estado: o prazo é de audição, não
// de relógio, por isso uma pausa longa não pode fazer a faixa contar sozinha.
- (void)suspendPlayCountTracking {
    if (!self.playCountTimer) {
        return;
    }

    // Mínimo positivo: um prazo já esgotado tem de contar assim que se retomar, e
    // não pode ser confundido com "estado por iniciar" em -resumePlayCountTracking.
    self.playCountRemaining = MAX(0.01, self.playCountDeadline.timeIntervalSinceNow);
    [self.playCountTimer invalidate];
    self.playCountTimer = nil;
    self.playCountDeadline = nil;
}

// Volta a armar o temporizador com o tempo que faltava.
- (void)resumePlayCountTracking {
    if (self.playCountTimer || self.playCountAlreadyCounted || self.playCountTrackPath.length == 0) {
        return;
    }

    NSTimeInterval remaining = self.playCountRemaining > 0.0 ? self.playCountRemaining : kPlayCountThreshold;
    self.playCountDeadline = [NSDate dateWithTimeIntervalSinceNow:remaining];
    self.playCountTimer = [NSTimer scheduledTimerWithTimeInterval:remaining
                                                           target:self
                                                         selector:@selector(handlePlayCountIncrement:)
                                                         userInfo:self.playCountTrackPath
                                                          repeats:NO];
}

// Esquece a faixa acompanhada. A reprodução seguinte, mesmo que seja da mesma
// faixa, passa a ser uma reprodução nova e volta a poder contar.
- (void)resetPlayCountTracking {
    [self.playCountTimer invalidate];
    self.playCountTimer = nil;
    self.playCountDeadline = nil;
    self.playCountTrackPath = nil;
    self.playCountAlreadyCounted = NO;
    self.playCountRemaining = kPlayCountThreshold;
}

// O rótulo é sempre derivado do estado do acompanhamento: mostra a contagem da
// faixa acompanhada, e só depois de esta reprodução já ter contado.
//
// Por ser derivado, pode ser chamado em qualquer altura — ao pausar, ao retomar, ao
// reiniciar o descodificador — sem apagar o que já lá estava. É isso que garante
// que o texto, uma vez visível, se mantém enquanto a faixa estiver carregada:
// antes, cada sítio limpava o rótulo à mão com um dispatch_async, e essas limpezas
// chegavam a correr *depois* de o texto ter sido reposto, deixando-o vazio.
- (void)refreshPlayCountLabel {
    dispatch_block_t updateBlock = ^{
        NSString *trackPath = self.playCountTrackPath;

        // Sem faixa acompanhada, ou reprodução ainda por contar: nada a mostrar.
        if (trackPath.length == 0 || !self.playCountAlreadyCounted) {
            [self.playCountLabel setStringValue:@""];
            return;
        }

        // Ler a contagem no momento de a mostrar, e não uma cópia tirada antes.
        NSNumber *playCount = [self.trackPlayCounts objectForKey:trackPath];

        if (!playCount || playCount.integerValue <= 0) {
            [self.playCountLabel setStringValue:@""];
        } else if (playCount.integerValue == 1) {
            [self.playCountLabel setStringValue:NSLocalizedString(@"Played 1 time", @"Play count label when played at least once")];
        } else {
            [self.playCountLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Played %@ times", @"Play count label when played more than once"), playCount]];
        }
    };

    if ([NSThread isMainThread]) {
        updateBlock();
    } else {
        dispatch_async(dispatch_get_main_queue(), updateBlock);
    }
}

- (void)loadTrackPlayCounts {
    NSString *filePath = [self playCountFilePath];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    
    if (data) {
        NSError *error = nil;
        NSDictionary *savedCounts = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error deserializing JSON: %@", error.localizedDescription);
            #endif
        } else {
            self.trackPlayCounts = [savedCounts mutableCopy];
        }
    } else {
        self.trackPlayCounts = [NSMutableDictionary dictionary];
    }
}

- (void)saveTrackPlayCounts {
    NSString *filePath = [self playCountFilePath];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.trackPlayCounts options:NSJSONWritingPrettyPrinted error:&error];
    
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error serializing play counts to JSON: %@", error.localizedDescription);
        #endif
    } else {
        BOOL success = [data writeToFile:filePath atomically:YES];
        if (!success) {
            #ifdef DEBUG
            NSLog(@"Failed to write play counts to file: %@", filePath);
            #endif
        } else {
            #ifdef DEBUG
            NSLog(@"Play counts successfully saved to %@", filePath);
            #endif
        }
    }
}

// M3U Support
- (IBAction)openM3UFile:(id)sender {
    // Create an open panel for selecting the M3U file
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    
    // Set allowed content types using UTType
    if (@available(macOS 11.0, *)) {
        openPanel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"m3u"]];
    } else {
        // Fallback: Earlier macOS versions do not support UTType, but this case would not happen because macOS 12 supports only allowedContentTypes
        #ifdef DEBUG
        NSLog(@"macOS version not supported. Requires macOS 11.0 or later.");
        #endif
    }

    // Present the open panel to the user
    [openPanel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            // Get the selected file URL
            NSURL *fileURL = [openPanel URL];
            
            if (fileURL) {
                // Call your loadM3UPlaylist method with the selected file
                [self loadM3UPlaylist:fileURL];
            }
        }
    }];
}

- (void)loadM3UPlaylist:(NSURL *)playlistURL {
    // Load the playlist
    NSArray<NSString *> *playlistTracks = [M3UPlaylist loadFromFile:playlistURL.path];
    if (!playlistTracks || playlistTracks.count == 0) {
        #ifdef DEBUG
        NSLog(@"[M3U Playlist] Failed to load M3U playlist or the playlist is empty.");
        #endif
        return;
    }

    // Convert the string paths to NSURLs
    NSMutableArray<NSURL *> *trackURLs = [NSMutableArray array];
    for (NSString *trackPath in playlistTracks) {
        NSURL *trackURL = [NSURL fileURLWithPath:trackPath];
        [trackURLs addObject:trackURL];
    }

    // Register the playlist URL with NSDocumentController
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:playlistURL];

    
    // Abrir uma lista não interrompe o que se está a ouvir: se a faixa em curso
    // também pertencer à lista, a reprodução continua nela. Com o tocador parado
    // não há faixa em curso nenhuma, e era esse o erro de antes — tomava-se o
    // índice à letra, pelo que à cabeça da aplicação a primeira música da
    // biblioteca passava por «a tocar» e a lista arrancava na posição em que ela
    // calhasse aparecer.
    NSString *currentTrackPath = nil;
    if ([self isPlaybackEngaged]) {
        NSURL *currentTrackURL = self.currentTrackURL;
        if (!currentTrackURL && self.currentTrackIndex >= 0) {
            if (self.isPlaylistModeActive && (NSInteger)self.audioFiles.count > self.currentTrackIndex) {
                currentTrackURL = self.audioFiles[self.currentTrackIndex];
            } else if ((NSInteger)self.cachedAudioFiles.count > self.currentTrackIndex) {
                currentTrackURL = self.cachedAudioFiles[self.currentTrackIndex];
            }
        }
        currentTrackPath = [currentTrackURL.path stringByStandardizingPath];
    }

    // Update the audioFiles property to the loaded tracks
    self.audioFiles = [trackURLs copy];

    // Set playlist mode active
    self.isPlaylistModeActive = YES;
    
    // −1 marca «desta lista ainda não se tocou nada», que é diferente de «está-se
    // na primeira faixa». O -playAudio normaliza-o para a primeira faixa, portanto
    // o ▶️ arranca no princípio; e a passagem automática de faixa, que incrementa
    // antes de tocar, passa a entrar na lista pela primeira música. Com 0 entrava
    // pela segunda: a primeira dava-se por tocada sem nunca o ter sido.
    self.currentTrackIndex = -1;

    // Sem faixa em curso também não há faixa seleccionada: a lista de músicas tem
    // de mostrar o marcador, e não a última faixa que se ouviu da biblioteca, que
    // podia por acaso pertencer também a esta lista.
    if (!currentTrackPath) {
        self.currentTrackURL = nil;
    }

    // Reinitialize shuffled tracks if shuffle mode is active
    if (self.isShuffleModeActive) {
        [self initializeShuffledTrackList];
    }

    // Search for the current track in the new audioFiles
    NSInteger newIndex = NSNotFound;
    if (currentTrackPath) {
        NSArray<NSURL *> *searchArray = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
        for (NSInteger i = 0; i < searchArray.count; i++) {
            NSURL *trackURL = searchArray[i];
            NSString *trackPath = [trackURL.path stringByStandardizingPath];
            if ([trackPath compare:currentTrackPath options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                newIndex = i;
                break;
            }
        }
    }

    if (newIndex != NSNotFound) {
        // Current track exists in the new playlist; update the index
        self.currentTrackIndex = newIndex;
        // Continue playback without interruption
    } else {
        // Current track does not exist in the new playlist
        // Decide whether to stop playback or keep playing the current track
        // We'll keep playing the current track for simplicity
    }

    // Reload the combo box to display the new tracks
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createComboBox];
        // Update combo box selection
        [self.songComboBox selectItemAtIndex:[self comboBoxIndexForCurrentTrack]];
        // A fila é outra, e a faixa adiantada quase de certeza também.
        [self prefetchNextTrack];
        // Do not start playing the first track automatically
        //[self playAudio];
    });

        #ifdef DEBUG
        NSLog(@"Loaded M3U playlist with %lu tracks.", (unsigned long)self.audioFiles.count);
        #endif
}

// Wrapper IBAction para ligação ao Interface Builder
- (IBAction)exitPlaylistModeAction:(id)sender {
    [self exitPlaylistMode];
}

- (void)exitPlaylistMode {
    // Sair da lista não interrompe o que se está a ouvir: a faixa em curso passa
    // apenas a ser contada na biblioteca. Antes punha-se o índice a 0 antes de
    // recarregar, e como em modo aleatório o índice conta posições na lista
    // baralhada, a faixa que se dava por «em curso» passava a ser a que calhara em
    // primeiro lugar no baralho da lista de reprodução. Daí que desligar o
    // aleatório a seguir saltasse para uma música qualquer em vez de continuar
    // naquela que se estava mesmo a ouvir.
    NSURL *faixaEmCurso = nil;
    if ([self isPlaybackEngaged]) {
        faixaEmCurso = self.currentTrackURL;
        if (!faixaEmCurso && self.currentTrackIndex >= 0) {
            NSArray<NSURL *> *listaActual = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
            if (self.currentTrackIndex < (NSInteger)listaActual.count) {
                faixaEmCurso = listaActual[self.currentTrackIndex];
            }
        }
    }

    self.isPlaylistModeActive = NO;

    // −1 marca «da biblioteca ainda não se tocou nada», tal como ao abrir uma
    // lista. Se a faixa em curso também estiver na biblioteca, o índice certo é
    // reposto mais abaixo. Sem faixa em curso também não há faixa seleccionada.
    self.currentTrackIndex = -1;
    if (!faixaEmCurso) {
        self.currentTrackURL = nil;
    }

    [self loadAudioFiles]; // Reload audio files from the directory

    // A lista baralhada tinha sido construída a partir da lista de reprodução; com
    // a biblioteca de volta tem de ser refeita, senão o ⏭️ e o fim de faixa
    // continuariam a ir buscar músicas à lista de que já se saiu.
    if (self.isShuffleModeActive) {
        [self initializeShuffledTrackList];
    }

    // Voltar a localizar a faixa em curso na lista onde o índice passa a ser
    // contado: a baralhada, com o aleatório ligado; a biblioteca, sem ele. Assim
    // desligar o aleatório mantém-se na mesma música e segue depois para a que lhe
    // sucede na biblioteca.
    if (faixaEmCurso) {
        NSArray<NSURL *> *listaDeReproducao = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
        NSString *caminhoEmCurso = [faixaEmCurso.path stringByStandardizingPath];
        for (NSInteger i = 0; i < (NSInteger)listaDeReproducao.count; i++) {
            NSString *caminho = [listaDeReproducao[i].path stringByStandardizingPath];
            if ([caminho compare:caminhoEmCurso options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                self.currentTrackIndex = i;
                break;
            }
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [self createComboBox];
        [self.songComboBox selectItemAtIndex:[self comboBoxIndexForCurrentTrack]];
        // Idem: volta-se à biblioteca, a vizinha da faixa em curso é outra.
        [self prefetchNextTrack];
    });
    //[self playAudio]; // Start playback from the first track
}

// Add Ogg Opus support
- (void)handleOpusPlayback:(NSURL *)trackURL {
    [self startBs2bIfNeeded];

    // Step 1: Clean up previous playback if necessary
    [self terminateOpusPlayback];

    // Step 2: Open the new Opus file
    NSData *dataToUse = [self takePrefetchedDataForTrack:trackURL];

    int error;
    OggOpusFile *opusFile = NULL;
    if (dataToUse) {
        opusFile = op_open_memory(dataToUse.bytes, dataToUse.length, &error);
    } else {
        const char *filePath = [trackURL.path UTF8String];
        opusFile = op_open_file(filePath, &error);
    }

    if (error != 0 || opusFile == NULL) {
        #ifdef DEBUG
        NSLog(@"Error opening Opus file: %d", error);
        #endif
        return;
    }

    // Step 3: Get stream info (e.g., number of channels) using op_head()
    const OpusHead *opusHead = op_head(opusFile, -1);  // Get the head of the current Opus stream
    int numChannels = opusHead ? opusHead->channel_count : 2;  // Default to stereo if unable to retrieve

    // Always set sampleRate to 48000 for Opus decoding
    int sampleRate = 48000;  // Fixed sample rate for Opus

    // Store the sample rate for progress calculations
    playbackState.sampleRate = sampleRate;

    // Step 4: Extract metadata using ZPOpusDecoder
    ZPOpusDecoder *decoder = nil;
    if (dataToUse) {
        decoder = [[ZPOpusDecoder alloc] initWithData:dataToUse];
    } else {
        decoder = [[ZPOpusDecoder alloc] initWithFilePath:trackURL.path];
    }
    if ([decoder decodeFile]) {
        // Metadata successfully decoded, now display in the UI

        // Update album art image using decoder.albumArt
        dispatch_block_t updateUIBlock = ^{
            if (decoder.albumArt) {
                self.coverArtView.image = decoder.albumArt;        // Update artist label
                self.artistLabel.stringValue = decoder.artist ?: @"Unknown Artist";
                // Update album label
                self.albumLabel.stringValue = decoder.album ?: @"Unknown Album";
            }
        };

        // Dispatch the block asynchronously on the main queue
        dispatch_async(dispatch_get_main_queue(), updateUIBlock);


        // Update track title label with track number and song title
        NSString *trackInfo = @"";
        if (decoder.track) {
            trackInfo = [NSString stringWithFormat:@"%@. ", decoder.track];
        }
        trackInfo = [trackInfo stringByAppendingString:decoder.title ?: @"Unknown Title"];
        dispatch_block_t updateTitleLabelBlock = ^{
            self.titleLabel.stringValue = trackInfo;
        };

        // Dispatch the block on the main queue to update the title label
        dispatch_async(dispatch_get_main_queue(), updateTitleLabelBlock);

    } else {
        // Handle case when metadata extraction fails
        self.coverArtView.image = [NSImage imageNamed:@"defaultAlbumArt"];
        self.artistLabel.stringValue = @"Unknown Artist";
        self.albumLabel.stringValue = @"Unknown Album";
        self.titleLabel.stringValue = @"Unknown Title";
    }

    // Step 5: Initialize Core Audio with the necessary format for Opus playback
    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = sampleRate;  // Use fixed sample rate of 48 kHz
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mBytesPerPacket = numChannels * 2;  // 2 bytes per sample, adjust for mono or stereo
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = numChannels * 2;
    audioFormat.mChannelsPerFrame = numChannels;
    audioFormat.mBitsPerChannel = 16;

    // Step 6: Calculate dynamic buffer size based on bitrate, with a minimum of 1 second
    int bitrate = op_bitrate(opusFile, -1);  // Get the bitrate of the current stream
    if (bitrate <= 0) {
        #ifdef DEBUG
        NSLog(@"Error retrieving Opus bitrate, using default bitrate of 64000 bps.");
        #endif
        bitrate = 64000;  // Fallback to a default bitrate (e.g., 64 kbps)
    }

    // Correct buffer size calculation based on uncompressed audio data
    double bufferDuration = 1.0;  // Buffer duration in seconds (may adjust)
    size_t bufferSize = audioFormat.mBytesPerFrame * audioFormat.mSampleRate * bufferDuration; // For bufferDuration
    size_t maxBufferSize = 1024 * 1024; // Limit the buffer size to 1MB
    playbackState.bufferSize = (UInt32)MIN(bufferSize, maxBufferSize);

    playbackState.opusFile = opusFile;
    playbackState.isPlaying = YES;

    playbackState.client_data = self;  // Set client_data to self for callback access

    // Step 7: Calculate the total duration of the Opus file in seconds
    int64_t totalSamples = op_pcm_total(opusFile, -1);  // -1 for total across all streams
    playbackState.totalDuration = (double)totalSamples / 48000.0;  // Use 48 kHz for Opus

    // Step 8: Create the audio queue for playback
    OSStatus status = AudioQueueNewOutput(&audioFormat, MyAudioQueueOutputCallback, &playbackState, NULL, NULL, 0, &playbackState.audioQueue);

    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"Error creating audio queue: %d", (int)status);
        #endif
        op_free(opusFile);
        return;
    }

    // Step 9: Allocate audio buffers and start playback
    for (int i = 0; i < NUM_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(playbackState.audioQueue, playbackState.bufferSize, &playbackState.buffers[i]);
        if (status != noErr) {
            #ifdef DEBUG
            NSLog(@"Error allocating buffer: %d", (int)status);
            #endif
            op_free(opusFile);
            AudioQueueDispose(playbackState.audioQueue, true);
            return;
        }
        MyAudioQueueOutputCallback(&playbackState, playbackState.audioQueue, playbackState.buffers[i]);
    }

    // Step 10: Start the queue
    AudioQueueStart(playbackState.audioQueue, NULL);

    // Procura de silêncios longos nesta faixa
    [self beginSilenceAnalysisForTrack:trackURL];

    // Step 11: Start progress updates using AudioQueueGetCurrentTime for more accuracy
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
    }
    self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                target:self
                                                              selector:@selector(updateOpusProgress)
                                                              userInfo:nil
                                                               repeats:YES];
    // Step 12: Count updates
    // O rótulo segue o estado do acompanhamento: numa faixa nova fica vazio, numa
    // retoma mantém a contagem que já estava visível.
    [self refreshPlayCountLabel];

    // A contagem é tratada pelo acompanhamento comum, armado por -playAudio e por
    // -playNextTrack. Aqui havia um dispatch_after que incrementava directamente em
    // modo de repetição: não era cancelável ao avançar de faixa e, como o caminho
    // comum também contava, a mesma reprodução era contada duas vezes.
}

// Add this method to update the progress bar based on Opus playback progress
- (void)updateOpusProgress {
    if (playbackState.audioQueue && playbackState.isPlaying) {
        AudioTimeStamp timeStamp;
        Boolean discontinuity;
        OSStatus status = AudioQueueGetCurrentTime(playbackState.audioQueue, NULL, &timeStamp, &discontinuity);

        if (status == noErr && timeStamp.mSampleTime >= 0) { // Ensure valid timestamp
            // Ensure correct sample rate from playback state
            double sampleRate = playbackState.sampleRate > 0 ? playbackState.sampleRate : 48000.0;

            // Calculate the current time in seconds. A AudioQueue só conta o que
            // reproduziu, por isso somam-se as frames saltadas nos silêncios.
            double currentTime = (timeStamp.mSampleTime + playbackState.skippedFrames) / sampleRate;

            // Ensure totalDuration is correctly initialized
            if (playbackState.totalDuration > 0) {
                currentTime = MIN(currentTime, playbackState.totalDuration);

                // Calculate progress percentage
                double progress = (currentTime / playbackState.totalDuration) * 100.0;

                // Update the progress bar on the main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.progressBar setDoubleValue:progress];
                });

                // Handle playback completion if the progress is near or exceeds 100%
                if (fabs(currentTime - playbackState.totalDuration) < 0.01) {
                    [self handleOpusPlaybackCompletion];
                }
            }
        } else if (discontinuity) {
            #ifdef DEBUG
            NSLog(@"AudioQueue discontinuity detected.");
            #endif
            // Optionally handle discontinuity (e.g., reset progress, pause, etc.)
        }
    }

    // Verifica se estamos dentro de um silêncio longo e, se for o caso, salta-o
    [self checkForSilenceAndSkip];
}

- (void)terminateOpusPlayback {

    if (playbackState.isPlaying) {
        // Stop the audio queue but wait for all pending buffers to be processed
        AudioQueueStop(playbackState.audioQueue, false);
        playbackState.isPlaying = NO;
    }
    
    if (playbackState.opusFile) {
        op_free(playbackState.opusFile);
        playbackState.opusFile = NULL;
    }
    
    if (playbackState.audioQueue) {
        // Dispose of the audio queue after ensuring it has stopped completely
        AudioQueueDispose(playbackState.audioQueue, true);
        playbackState.audioQueue = NULL;
    }
    
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }
    
    // Reset playback state variables
    memset(&playbackState, 0, sizeof(playbackState)); // Properly reset all variables

}

- (void)handleOpusPlaybackCompletion {
    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    // Ensure the current track maps to its original counterpart
    #ifdef DEBUG
    NSURL *originalTrackURL = self.shuffledToOriginalMap[self.currentTrackURL] ?: self.currentTrackURL;

    NSLog(@"Playback completed for track: %@", self.currentTrackURL);
    NSLog(@"Original Track URL: %@", originalTrackURL);
    #endif

    // Check if repeat mode is active, replay the current track if it is
    if (self.isRepeatModeActive) {
        // A faixa chegou ao fim: a repetição é uma reprodução nova e deve contar
        // outra vez, ao contrário de uma simples retoma.
        [self resetPlayCountTracking];
        [self playAudio];  // Replay the same track
    } else {
    // Otherwise, move to the next track
        [self playNextTrack];
    }
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert + UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (!granted) {
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"notification_permission_not_granted", @"Notification permission not granted."));
            #endif
        }
    }];
}

// Empurra ganho e pico juntos para o streamer. São lidos de sítios diferentes
// das etiquetas e por ordem imprevisível, por isso manda-se sempre o par
// completo com o que já se souber — a última chamada é a que fica a valer.
- (void)pushReplayGainToStreamer {
    if (!self.airPlayStreamer) {
        #ifdef DEBUG
        NSLog(@"[ReplayGain] AirPlayStreamer é nil; ganho não actualizado.");
        #endif
        return;
    }

    // A política — nenhuma, por faixa ou por álbum — está nas preferências, e
    // é resolvida num sítio só para o leitor de Opus poder usar a mesma.
    float ganho = 0.0f, pico = 0.0f;
    ZPResolveReplayGain(self.replayGainValue, self.replayGainPeak,
                        self.replayGainAlbumValue, self.replayGainAlbumPeak,
                        &ganho, &pico);

    #ifdef DEBUG
    NSLog(@"[ReplayGain] A enviar %.2f dB (pico %.4f) — faixa %.2f/%.4f, álbum %.2f/%.4f.",
          ganho, pico, self.replayGainValue, self.replayGainPeak,
          self.replayGainAlbumValue, self.replayGainAlbumPeak);
    #endif

    [self.airPlayStreamer updateReplayGainValue:ganho trackPeak:pico];
}

- (void)extractAndDisplayFlacMetadataWithLibFLAC:(NSURL *)fileURL {
    // Always default to 1.0 before reading metadata
    self.replayGainValue = 0.0f;
    self.replayGainPeak  = 0.0f;
    self.replayGainAlbumValue = 0.0f;
    self.replayGainAlbumPeak  = 0.0f;

    // Initialize the FLAC decoder
    FLAC__StreamDecoder *decoder = FLAC__stream_decoder_new();
    if (!decoder) {
        #ifdef DEBUG
        NSLog(@"Error: Could not create FLAC decoder");
        #endif
        return;
    }

    // Ensure the decoder responds to all metadata blocks
    FLAC__stream_decoder_set_metadata_respond_all(decoder);

    // Initialize the decoder with file and callbacks
    FLAC__StreamDecoderInitStatus init_status = FLAC__stream_decoder_init_file(
        decoder,
        [fileURL.path UTF8String],
        flac_write_callback,  // Stub write callback
        flac_metadata_callback, // Metadata callback for handling metadata blocks
        flac_error_callback,  // Error handling callback
        (__bridge void *)(self)
    );

    if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        #ifdef DEBUG
        NSLog(@"Error: Could not initialize FLAC decoder for file: %@", fileURL.path);
        #endif
        FLAC__stream_decoder_delete(decoder);
        return;
    }

    // Process the file until all metadata is read
    if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder)) {
        #ifdef DEBUG
        NSLog(@"Error: Failed to process FLAC metadata for file: %@", fileURL.path);
        #endif
    } else {
        // Create a dispatch block for UI updates
        dispatch_block_t updateUI = ^{
            // Access the UI elements safely on the main thread
            NSString *artist = self.artistLabel.stringValue;
            NSString *album = self.albumLabel.stringValue;
            NSString *title = self.titleLabel.stringValue;

            // Trigger the notification now that metadata is fully extracted
            [self triggerNowPlayingNotificationWithTitle:title artist:artist album:album];
        };

        // Dispatch the block to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue(), updateUI);
    }

    // Clean up
    FLAC__stream_decoder_finish(decoder);
    FLAC__stream_decoder_delete(decoder);
}

// Stub for write callback (no audio data is being processed)
FLAC__StreamDecoderWriteStatus flac_write_callback(const FLAC__StreamDecoder *decoder,
                                                   const FLAC__Frame *frame,
                                                   const FLAC__int32 * const buffer[],
                                                   void *client_data) {
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

// Error callback function for handling errors during decoding
void flac_error_callback(const FLAC__StreamDecoder *decoder,
                         FLAC__StreamDecoderErrorStatus status,
                         void *client_data) {
    #ifdef DEBUG
    NSLog(@"FLAC decoding error: %d", status);
    #endif
}

// Helper function to print the VORBIS comment (adapted for Objective-C)
NSString *print_vorbis_comment(const FLAC__StreamMetadata_VorbisComment_Entry *entry, ViewController *self) {
    NSString *entry_str = [[NSString alloc] initWithBytes:entry->entry
                                                   length:entry->length
                                                 encoding:NSUTF8StringEncoding];
    if (!entry_str) {
        #ifdef DEBUG
        NSLog(@"Error: Failed to decode Vorbis comment");
        #endif
        return nil;
    }

    // Variables to hold metadata
    static NSString *trackNumber = @"Unknown Track";
    static NSString *artist      = @"Unknown Artist";
    static NSString *album       = @"Unknown Album";
    static NSString *title       = @"Unknown Title";

    // Check if this line starts with ARTIST=, ALBUM=, TITLE=, TRACKNUMBER=, or REPLAYGAIN_TRACK_GAIN=
    if ([entry_str hasPrefix:@"ARTIST="]) {
        artist = [self replaceSingleQuoteAndSmartQuotes:[entry_str substringFromIndex:7]];
        #ifdef DEBUG
        NSLog(@"Artist is: %@", artist);
        #endif
    }
    else if ([entry_str hasPrefix:@"ALBUM="]) {
        album = [self replaceSingleQuoteAndSmartQuotes:[entry_str substringFromIndex:6]];
        #ifdef DEBUG
        NSLog(@"Album is: %@", album);
        #endif
    }
    else if ([entry_str hasPrefix:@"TITLE="]) {
        title = [self replaceSingleQuoteAndSmartQuotes:[entry_str substringFromIndex:6]];
        #ifdef DEBUG
        NSLog(@"Title is: %@", title);
        #endif
    }
    else if ([entry_str hasPrefix:@"TRACKNUMBER="]) {
        trackNumber = [entry_str substringFromIndex:12];
        if ([trackNumber hasPrefix:@"0"]) {
            trackNumber = [trackNumber substringFromIndex:1];
        }
        #ifdef DEBUG
        NSLog(@"Track Number is: %@", trackNumber);
        #endif
    }
    else if ([entry_str hasPrefix:@"REPLAYGAIN_TRACK_GAIN="]) {
        // Example: "REPLAYGAIN_TRACK_GAIN=-5.66 dB" or "REPLAYGAIN_TRACK_GAIN=+2.0 dB"
        NSString *gainString = [entry_str substringFromIndex:22];
        // Remove the trailing " dB" if present
        gainString = [gainString stringByReplacingOccurrencesOfString:@" dB" withString:@""];
        // Convert to float
        float gainValue = [gainString floatValue];
        
        // Store it in the property on the main thread (if UI code might be triggered)
        dispatch_async(dispatch_get_main_queue(), ^{
            // If you haven’t already set self.replayGainValue,
            // you can set it here. Or do additional logic if needed.
            self.replayGainValue = gainValue;
            #ifdef DEBUG
            NSLog(@"[ReplayGain] FLAC track gain: %f dB", self.replayGainValue);
            #endif
            [self pushReplayGainToStreamer];
        });
    }
    else if ([entry_str hasPrefix:@"REPLAYGAIN_ALBUM_GAIN="]) {
        NSString *gainString = [[entry_str substringFromIndex:22]
                                stringByReplacingOccurrencesOfString:@" dB" withString:@""];
        float gainValue = [gainString floatValue];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.replayGainAlbumValue = gainValue;
            #ifdef DEBUG
            NSLog(@"[ReplayGain] FLAC album gain: %f dB", self.replayGainAlbumValue);
            #endif
            [self pushReplayGainToStreamer];
        });
    }
    else if ([entry_str hasPrefix:@"REPLAYGAIN_ALBUM_PEAK="]) {
        float peakValue = [[entry_str substringFromIndex:22] floatValue];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.replayGainAlbumPeak = peakValue;
            #ifdef DEBUG
            NSLog(@"[ReplayGain] FLAC album peak: %f", self.replayGainAlbumPeak);
            #endif
            [self pushReplayGainToStreamer];
        });
    }
    else if ([entry_str hasPrefix:@"REPLAYGAIN_TRACK_PEAK="]) {
        // Exemplo: "REPLAYGAIN_TRACK_PEAK=0.988525"
        float peakValue = [[entry_str substringFromIndex:22] floatValue];

        dispatch_async(dispatch_get_main_queue(), ^{
            self.replayGainPeak = peakValue;
            #ifdef DEBUG
            NSLog(@"[ReplayGain] FLAC track peak: %f", self.replayGainPeak);
            #endif
            [self pushReplayGainToStreamer];
        });
    }

    // Format the title with the track number
    NSString *formattedTitle = [NSString stringWithFormat:@"%@. %@", trackNumber, title];

    // Update the UI elements on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.artistLabel setStringValue:artist];
        [self.albumLabel setStringValue:album];
        [self.titleLabel setStringValue:formattedTitle];
        [self.trackNumberLabel setStringValue:trackNumber];
    });

    return entry_str;
}

// Metadata callback function
void flac_metadata_callback(const FLAC__StreamDecoder *decoder,
                               const FLAC__StreamMetadata *metadata,
                               void *client_data) {
    ViewController *self = (__bridge ViewController *)client_data;

    // Log the type of metadata received
    #ifdef DEBUG
    NSLog(@"Metadata block type: %d", metadata->type);
    #endif

    switch (metadata->type) {
        case FLAC__METADATA_TYPE_VORBIS_COMMENT: {
            #ifdef DEBUG
            NSLog(@"\nVORBIS Comment block detected");
            #endif

            // Iterate through all VORBIS comments and process each one
            for (unsigned i = 0; i < metadata->data.vorbis_comment.num_comments; i++) {
                NSString *comment = print_vorbis_comment(&metadata->data.vorbis_comment.comments[i], self);
                
                // If replaceSingleQuoteAndSmartQuotes interacts with UI, ensure it's on the main thread
                dispatch_block_t processComment = ^{
                    [self replaceSingleQuoteAndSmartQuotes:comment];
                };
                dispatch_async(dispatch_get_main_queue(), processComment);
            }
            break;
        }
        case FLAC__METADATA_TYPE_PICTURE: {
            #ifdef DEBUG
            NSLog(@"\nPICTURE block detected");
            #endif
            // Log image dimensions and MIME type if present
            if (metadata->data.picture.mime_type) {
                #ifdef DEBUG
                NSString *mimeType = [NSString stringWithUTF8String:metadata->data.picture.mime_type];
                NSLog(@"MIME type: %@", mimeType);
                #endif
            }
            #ifdef DEBUG
            NSLog(@"Dimensions: %ux%u pixels", metadata->data.picture.width, metadata->data.picture.height);
            #endif

            // Process and display the cover art if data exists
            NSUInteger dataLength = metadata->data.picture.data_length;
            if (dataLength > 0) {
                NSData *imageData = [NSData dataWithBytes:metadata->data.picture.data length:dataLength];
                if (imageData) {
                    NSImage *coverArt = [[NSImage alloc] initWithData:imageData];
                    if (coverArt) {
                        // Use a block to update the UI on the main thread
                        dispatch_block_t updateCoverArt = ^{
                            [self.coverArtView setImage:coverArt];
                            #ifdef DEBUG
                            NSLog(@"Cover Art updated successfully.");
                            #endif
                        };
                        dispatch_async(dispatch_get_main_queue(), updateCoverArt);
                    } else {
                        #ifdef DEBUG
                        NSLog(@"Failed to create NSImage from the extracted data.");
                        #endif
                    }
                }
            } else {
                #ifdef DEBUG
                NSLog(@"Image data length is zero.");
                #endif
            }
            break;
        }
        default: {
            #ifdef DEBUG
            NSLog(@"Skipping metadata block type: %d", metadata->type);
            #endif
            break;
        }
    }

}

#pragma mark - WavPack

// Para evitar os pops no início de cada reprodução
- (void)applyFadeInToAudioBuffer:(int16_t *)buffer
                  totalSamples:(uint32_t)samples
                  numChannels:(int)numChannels
                   sampleRate:(int)sampleRate {
    uint32_t fadeSamples = sampleRate / 20; // 50 ms
    fadeSamples = MIN(fadeSamples, samples);
    
    for (uint32_t i = 0; i < fadeSamples; i++) {
        float factor = (float)i / (float)fadeSamples;
        for (int ch = 0; ch < numChannels; ch++) {
            int index = i * numChannels + ch;
            buffer[index] = (int16_t)(buffer[index] * factor);
        }
    }
}

// Add this method to update the progress bar based on WavPack playback progress
- (void)updateWavPackProgress {
    if (playbackState.wpc && playbackState.isPlaying) {
        [self updateProgressBarForWavPack];
    }

    // Verifica se estamos dentro de um silêncio longo e, se for o caso, salta-o
    [self checkForSilenceAndSkip];
}

// Progresso do WavPack a partir do relógio da AudioQueue (que já contabiliza os
// silêncios saltados). WavpackGetProgress fica como reserva para os ficheiros cujo
// número total de amostras não é conhecido.
- (void)updateProgressBarForWavPack {
    double currentTime = 0.0;
    double duration = 0.0;
    double progress = -1.0;

    if ([self currentPlaybackTime:&currentTime duration:&duration] && duration > 0.0) {
        progress = MIN(currentTime / duration, 1.0);
    } else if (playbackState.wpc) {
        progress = WavpackGetProgress(playbackState.wpc);
    }

    if (progress >= 0.0 && progress <= 1.0) {
        // Create a dispatch block for updating the progress bar
        dispatch_block_t updateProgressBar = ^{
            // Convert progress to a percentage and update the progress bar
            [self.progressBar setDoubleValue:progress * 100.0];
        };

        // Dispatch the block to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue(), updateProgressBar);
    } else {
        #ifdef DEBUG
        NSLog(@"Unknown progress.");
        #endif
    }
}

static MemoryBuffer *gWvMemBuffer = NULL;
static NSData *gWvKeptData = nil;

// Start playback for the WavPack file and set up the timer to update progress
- (void)playWavPack:(NSURL *)trackURL {
    [self startBs2bIfNeeded];
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;

    // Convert the file URL path to a UTF-8 string for WavPack
    const char *filePath = [trackURL.path UTF8String];

    // Open the WAVPack file and extract metadata
    [self extractAndDisplayMetadataForWavPack:trackURL];

    NSData *dataToUse = [self takePrefetchedDataForTrack:trackURL];

    char error[80];
    if (dataToUse) {
        if (gWvMemBuffer) { free(gWvMemBuffer); gWvMemBuffer = NULL; }
        gWvKeptData = nil;
        // Sem cópia: -takePrefetchedDataForTrack: já esvaziou a ranhura, portanto
        // estes bytes são nossos e ninguém lhes mexe. O -dataWithData: que aqui
        // estava duplicava o ficheiro todo em memória.
        gWvKeptData = dataToUse;
        gWvMemBuffer = (MemoryBuffer *)malloc(sizeof(MemoryBuffer));
        gWvMemBuffer->data = gWvKeptData.bytes;
        gWvMemBuffer->size = gWvKeptData.length;
        gWvMemBuffer->pos  = 0;
        playbackState.wpc = WavpackOpenFileInputEx(&memoryReader, gWvMemBuffer, NULL, error, 0, 0);
    } else {
        playbackState.wpc = WavpackOpenFileInput(filePath, error, 0, 0);
    }

    if (!playbackState.wpc) {
        #ifdef DEBUG
        NSLog(@"Error opening WAVPack file: %s", error);
        #endif
        if (gWvMemBuffer) { free(gWvMemBuffer); gWvMemBuffer = NULL; }
        gWvKeptData = nil;
        return;
    }

    playbackState.client_data = self;

    int numChannels   = WavpackGetNumChannels(playbackState.wpc);
    int sampleRate    = WavpackGetSampleRate(playbackState.wpc);
    int bitsPerSample = WavpackGetBitsPerSample(playbackState.wpc);
    playbackState.numChannels = numChannels;

    // Relógio da faixa, usado pela barra de progresso e pelo salto de silêncios
    playbackState.sampleRate = sampleRate;
    int64_t totalSamples = WavpackGetNumSamples64(playbackState.wpc);
    playbackState.totalDuration = (totalSamples > 0 && sampleRate > 0) ? (double)totalSamples / (double)sampleRate : 0.0;

    #ifdef DEBUG
    NSLog(@"WAVPack File Info: %d channels, %d Hz, %d bits/sample",
          numChannels, sampleRate, bitsPerSample);
    #endif

    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = sampleRate;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = numChannels;
    audioFormat.mBitsPerChannel = 16;
    audioFormat.mBytesPerFrame  = (16 / 8) * numChannels;
    audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame;
    audioFormat.mFormatFlags    = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    audioFormat.mReserved = 0;
    if (WavpackGetMode(playbackState.wpc) & MODE_FLOAT) {
        #ifdef DEBUG
        NSLog(@"WAVPack file contains floating-point data (nota: este caminho converte para int16).");
        #endif
    }
    [self cleanupCoreAudioPlayback];
    int bytesPerFrame = 2 * numChannels;
    playbackState.bufferSize = (UInt32)(sampleRate * bytesPerFrame * 2.0);
    uint32_t maxSamplesToDecode = 10000;
    playbackState.sampleBuffer = malloc((size_t)maxSamplesToDecode * (size_t)numChannels * sizeof(int32_t));
    playbackState.didApplyFadeIn = NO;
    playbackState.isPlaying = YES;
    OSStatus status = AudioQueueNewOutput(&audioFormat, MyAudioQueueOutputCallback, &playbackState, NULL, NULL, 0, &playbackState.audioQueue);
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"Error creating audio output queue: %d", (int)status);
        #endif
        free(playbackState.sampleBuffer);
        playbackState.sampleBuffer = NULL;
        WavpackCloseFile(playbackState.wpc);
        playbackState.wpc = NULL;
        if (gWvMemBuffer) { free(gWvMemBuffer); gWvMemBuffer = NULL; }
        gWvKeptData = nil;
        return;
    }
    for (int i = 0; i < NUM_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(playbackState.audioQueue, playbackState.bufferSize, &playbackState.buffers[i]);
        if (status == noErr) {
            MyAudioQueueOutputCallback(&playbackState, playbackState.audioQueue, playbackState.buffers[i]);
        } else {
            #ifdef DEBUG
            NSLog(@"Error allocating buffer: %d", (int)status);
            #endif
            free(playbackState.sampleBuffer);
            playbackState.sampleBuffer = NULL;
            WavpackCloseFile(playbackState.wpc);
            playbackState.wpc = NULL;
            if (gWvMemBuffer) { free(gWvMemBuffer); gWvMemBuffer = NULL; }
            gWvKeptData = nil;
            return;
        }
    }
    status = AudioQueueStart(playbackState.audioQueue, NULL);
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"Error starting audio queue: %d", (int)status);
        #endif
        free(playbackState.sampleBuffer);
        playbackState.sampleBuffer = NULL;
        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueFreeBuffer(playbackState.audioQueue, playbackState.buffers[i]);
        }
        WavpackCloseFile(playbackState.wpc);
        playbackState.wpc = NULL;
        if (gWvMemBuffer) { free(gWvMemBuffer); gWvMemBuffer = NULL; }
        gWvKeptData = nil;
        return;
    }

    // Procura de silêncios longos nesta faixa
    [self beginSilenceAnalysisForTrack:trackURL];

    // Progress bar timer
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.progressUpdateTimer) {
                [self.progressUpdateTimer invalidate];
            }
            self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                        target:self
                                                                      selector:@selector(updateWavPackProgress)
                                                                      userInfo:nil
                                                                       repeats:YES];
        });
    // Now using the common scheduler
        if (originalTrackURL) {
            [self schedulePlayCountIncrementForTrack:originalTrackURL];
        }
        [self refreshPlayCountLabel];
}


// Callback to handle audio buffer playback
void MyAudioQueueOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    CoreAudioPlaybackState *playbackState = (CoreAudioPlaybackState *)inUserData;

    // Handling WAVPack decoding
    if (playbackState->wpc) {
        // Salto de um silêncio longo pedido pelo temporizador de progresso: é
        // aplicado aqui porque libwavpack só pode ser usada nesta thread.
        int64_t seekFrame = playbackState->pendingSeekFrame;
        if (seekFrame > 0) {
            int64_t currentFrame = WavpackGetSampleIndex64(playbackState->wpc);
            if (seekFrame > currentFrame && WavpackSeekSample64(playbackState->wpc, seekFrame)) {
                playbackState->skippedFrames += (double)(seekFrame - currentFrame);
                playbackState->didApplyFadeIn = NO;  // fade-in curto ao retomar a música
            }
            playbackState->pendingSeekFrame = 0;
        }

        int numChannels = playbackState->numChannels;

        // AudioQueue output: 16-bit
        const int outBytesPerSample = 2;

        // Determine the maximum number of samples that can be decoded into the buffer
        uint32_t maxSamplesToDecode = (uint32_t)(inBuffer->mAudioDataBytesCapacity / (outBytesPerSample * numChannels));
        maxSamplesToDecode = MIN(maxSamplesToDecode, 10000);

        // Decode WAVPack samples into the sample buffer (int32_t samples)
        int32_t samplesDecoded = WavpackUnpackSamples(playbackState->wpc, playbackState->sampleBuffer, maxSamplesToDecode);

        if (samplesDecoded > 0) {
            // Converter int32 -> int16 no buffer da AudioQueue
            int16_t *out = (int16_t *)inBuffer->mAudioData;

            int bitsPerSample = WavpackGetBitsPerSample(playbackState->wpc);
            int shift = 0;
            if (bitsPerSample > 16) shift = bitsPerSample - 16;

            for (uint32_t i = 0; i < (uint32_t)samplesDecoded; i++) {
                for (int ch = 0; ch < numChannels; ch++) {
                    int32_t s = ((int32_t *)playbackState->sampleBuffer)[i * numChannels + ch];

                    if (shift > 0) s >>= shift;

                    if (s > 32767) s = 32767;
                    else if (s < -32768) s = -32768;

                    out[i * numChannels + ch] = (int16_t)s;
                }
            }

            /* ───── fade-in só no 1.º buffer ───── */
            ViewController *vc = (ViewController *)playbackState->client_data;
            if (!playbackState->didApplyFadeIn &&
                [vc respondsToSelector:@selector(applyFadeInToAudioBuffer:totalSamples:numChannels:sampleRate:)])
            {
                [vc applyFadeInToAudioBuffer:(int16_t *)inBuffer->mAudioData
                                totalSamples:(uint32_t)samplesDecoded
                                 numChannels:numChannels
                                  sampleRate:WavpackGetSampleRate(playbackState->wpc)];

                playbackState->didApplyFadeIn = YES;
            }
            /* ───────────────────────────────────── */

            size_t dataSize = (size_t)samplesDecoded * (size_t)outBytesPerSample * (size_t)numChannels;

            if (dataSize > inBuffer->mAudioDataBytesCapacity) {
                #ifdef DEBUG
                NSLog(@"Warning: Data size exceeds buffer capacity. Truncating data.");
                #endif
                dataSize = inBuffer->mAudioDataBytesCapacity;
            }

            inBuffer->mAudioDataByteSize = (UInt32)dataSize;

            OSStatus status = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
            if (status != noErr) {
                #ifdef DEBUG
                NSLog(@"Error enqueuing buffer: %d", (int)status);
                #endif
            }
        } else {
            // No more samples to decode, stop playback
            AudioQueueStop(inAQ, true);
            playbackState->isPlaying = NO;
            #ifdef DEBUG
            NSLog(@"WAVPack playback finished.");
            #endif

            // Close the WavPack file when playback finishes
            if (playbackState->wpc) {
                WavpackCloseFile(playbackState->wpc);
                playbackState->wpc = NULL;
            }

            // Libertar sampleBuffer (int32)
            if (playbackState->sampleBuffer) {
                free(playbackState->sampleBuffer);
                playbackState->sampleBuffer = NULL;
            }

            // Libertar estado de memória do prefetch
            if (gWvMemBuffer) { free(gWvMemBuffer); gWvMemBuffer = NULL; }
            gWvKeptData = nil;

            // Handle repeat or transition to next song
            ViewController *viewController = playbackState->client_data;
            if (viewController.isRepeatModeActive) {
                #ifdef DEBUG
                NSLog(@"Repeat mode is active. Restarting the current WAVPack track.");
                #endif
                [viewController cleanupCoreAudioPlayback];
                [viewController playWavPack:viewController.audioFiles[viewController.currentTrackIndex]];
            } else {
                [viewController handlePlaybackCompletion];
            }
        }
    } else if (playbackState->opusFile) {
        // Salto de um silêncio longo pedido pelo temporizador de progresso: é
        // aplicado aqui porque libopusfile só pode ser usada nesta thread.
        int64_t seekFrame = playbackState->pendingSeekFrame;
        if (seekFrame > 0) {
            int64_t currentFrame = op_pcm_tell(playbackState->opusFile);
            if (seekFrame > currentFrame && op_pcm_seek(playbackState->opusFile, seekFrame) == 0) {
                playbackState->skippedFrames += (double)(seekFrame - currentFrame);
            }
            playbackState->pendingSeekFrame = 0;
        }

        // Opus decoding logic (inalterado)
        int16_t pcmBuffer[4096 * 2];
        int samplesDecoded = op_read_stereo(playbackState->opusFile, pcmBuffer, sizeof(pcmBuffer) / sizeof(pcmBuffer[0]));

        if (samplesDecoded > 0) {
            size_t dataSize = (size_t)samplesDecoded * sizeof(int16_t) * 2;

            if (dataSize > inBuffer->mAudioDataBytesCapacity) {
                #ifdef DEBUG
                NSLog(@"Warning: Data size exceeds buffer capacity. Truncating data.");
                #endif
                dataSize = inBuffer->mAudioDataBytesCapacity;
            }

            memcpy(inBuffer->mAudioData, pcmBuffer, dataSize);
            inBuffer->mAudioDataByteSize = (UInt32)dataSize;

            OSStatus status = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
            if (status != noErr) {
                #ifdef DEBUG
                NSLog(@"Error enqueuing buffer: %d", (int)status);
                #endif
            }
        } else {
            AudioQueueStop(inAQ, false);
            playbackState->isPlaying = NO;
            #ifdef DEBUG
            NSLog(@"Opus playback finished.");
            #endif

            if (playbackState->opusFile) {
                op_free(playbackState->opusFile);
                playbackState->opusFile = NULL;
            }

            ViewController *viewController = playbackState->client_data;
            if (viewController.isRepeatModeActive) {
                #ifdef DEBUG
                NSLog(@"Repeat mode is active. Restarting the current Opus track.");
                #endif
                [viewController cleanupCoreAudioPlayback];
                [viewController handleOpusPlayback:viewController.audioFiles[viewController.currentTrackIndex]];
            } else {
                [viewController handlePlaybackCompletion];
            }
        }
    } else {
        #ifdef DEBUG
        NSLog(@"Error: Unknown audio format in playback state.");
        #endif
    }
}
- (void)handlePlaybackCompletion {
    //self.replayGainValue = 0.0f;
    if (self.isShuffleModeActive) {
        #ifdef DEBUG
        NSLog(NSLocalizedString(@"shuffle_mode_activated", @"Shuffle mode activated."));
        #endif
        [self playNextTrack];  // Play next shuffled track
    } else {
        // Check if we're at the end of the track list
        if (self.currentTrackIndex + 1 < (NSInteger)self.audioFiles.count) {
            // Move to the next track in the list
            self.currentTrackIndex++;
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"playing_next_track", @"Playing next track."));
            #endif
            [self playAudio];  // Play next track in order
        } else {
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"reached_end_of_playlist", @"Reached the end of the playlist."));
            #endif
            // If repeat mode is active, loop back to the first track and play again
            if (self.isRepeatModeActive) {
                self.currentTrackIndex = 0;
                [self playAudio];
            } else {
                #ifdef DEBUG
                NSLog(NSLocalizedString(@"playback_completed_no_repeat", @"Playback completed with no repeat."));
                #endif
                // Optionally, you can stop playback here if you don't want to repeat the playlist automatically.
                //[self stopAudio];  // Stop the audio if playlist is completed
            }
        }
    }
}

- (void)playNextTrack {
    //self.replayGainValue = 0.0f;
    self.isCalledFromPlayNextTrack = YES;
    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }

    // Clear any existing progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    if (self.isShuffleModeActive) {
        #ifdef DEBUG
        NSLog(@"Shuffle mode is active. Playing next shuffled track.");
        #endif
        if (self.shuffledTracks.count > 0) {
            // Move to the next track in shuffledTracks
            self.currentTrackIndex = (self.currentTrackIndex + 1) % self.shuffledTracks.count;
            NSURL *nextTrackURL = self.shuffledTracks[self.currentTrackIndex];

            // Update the current track URL
            self.currentTrackURL = nextTrackURL;

            // Stop any current playback
            dispatch_block_t stopAudioBlock = ^{
                [self stopAudio];
            };
            dispatch_async(dispatch_get_main_queue(), stopAudioBlock);

            // Reset the progress bar
            dispatch_block_t resetProgressBarBlock = ^{
                [self.progressBar setDoubleValue:0];
            };
            dispatch_async(dispatch_get_main_queue(), resetProgressBarBlock);

            // Get the extension of the next track
            NSString *extension = nextTrackURL.pathExtension.lowercaseString;

            if ([extension isEqualToString:@"wv"]) {
                // WAVPack playback
                dispatch_block_t playWavPackBlock = ^{
                    [self handleWavPackPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playWavPackBlock);

                // Restart progress updates for WAVPack
                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateWavPackProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else if ([extension isEqualToString:@"flac"]) {
                // FLAC playback
                dispatch_block_t playFlacBlock = ^{
                    [self handleFlacPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playFlacBlock);
            } else if ([extension isEqualToString:@"opus"]) {
                // Opus playback
                dispatch_block_t playOpusBlock = ^{
                    [self handleOpusPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playOpusBlock);

                // Restart progress updates for Opus
                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateOpusProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else {
                // Standard audio playback
                dispatch_block_t playStandardAudioBlock = ^{
                    [self handleStandardAudioPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playStandardAudioBlock);

                // Restart progress updates for standard audio formats
                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateProgressBar)
                                                                          userInfo:nil
                                                                           repeats:YES];
            }

            // Schedule play count increment.
            // Isto tem de ser feito já, e não dentro de um dispatch_after: um atraso
            // aqui deixava a faixa anterior a ser armada depois de já se ter mudado
            // de música, contando-a mesmo tendo-se avançado, e roubando o
            // temporizador à faixa nova.
            dispatch_block_t updatePlayCountBlock = ^{
                [self schedulePlayCountIncrementForTrack:nextTrackURL];
                [self refreshPlayCountLabel];
            };
            dispatch_async(dispatch_get_main_queue(), updatePlayCountBlock);

            // Force UI updates
            dispatch_block_t forceUIUpdateBlock = ^{
                [self.view setNeedsDisplay:YES];
            };
            dispatch_async(dispatch_get_main_queue(), forceUIUpdateBlock);

            // Update the combo box to reflect the current track being played
            NSInteger index = [self.audioFiles indexOfObject:self.currentTrackURL];
            NSUInteger comboBoxIndex;

            if (index != NSNotFound) {
                comboBoxIndex = index + 1; // Offset by 1 for placeholder
            } else {
                comboBoxIndex = 0; // Placeholder index
            }

            dispatch_block_t updateComboBox = ^{
                [self.songComboBox selectItemAtIndex:comboBoxIndex];
            };
            dispatch_async(dispatch_get_main_queue(), updateComboBox);

            // Adiantar a faixa a seguir a esta — mas só depois de esta ter ido
            // buscar a sua à ranhura. A reprodução, acima, foi despachada para a
            // fila principal; pedir o adiantamento já fazia a ranhura passar a
            // apontar para a faixa seguinte antes de esta a consumir, e a
            // transição no fim da música — que é o caso para que o adiantamento
            // foi feito — acabava sempre a ler do disco.
            dispatch_block_t prefetchBlock = ^{
                [self prefetchNextTrack];
            };
            dispatch_async(dispatch_get_main_queue(), prefetchBlock);

        } else {
            #ifdef DEBUG
            NSLog(@"No shuffled tracks available.");
            #endif
        }
    } else {
        if (self.currentTrackIndex + 1 < (NSInteger)self.audioFiles.count) {
            self.currentTrackIndex++;
            NSURL *nextTrackURL = self.audioFiles[self.currentTrackIndex];

            // Update the current track URL
            self.currentTrackURL = nextTrackURL;

            // Stop current playback and reset progress bar
            dispatch_block_t stopAudioBlock = ^{
                [self stopAudio];
                [self.progressBar setDoubleValue:0.0];
            };
            dispatch_async(dispatch_get_main_queue(), stopAudioBlock);

            // Get the file extension of the next track
            NSString *extension = nextTrackURL.pathExtension.lowercaseString;

            if ([extension isEqualToString:@"wv"]) {
                dispatch_block_t playWavPackBlock = ^{
                    [self handleWavPackPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playWavPackBlock);

                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateWavPackProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else if ([extension isEqualToString:@"flac"]) {
                dispatch_block_t playFlacBlock = ^{
                    [self handleFlacPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playFlacBlock);
            } else if ([extension isEqualToString:@"opus"]) {
                dispatch_block_t playOpusBlock = ^{
                    [self handleOpusPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playOpusBlock);

                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateOpusProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else {
                dispatch_block_t playStandardAudioBlock = ^{
                    [self handleStandardAudioPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playStandardAudioBlock);

                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateProgressBar)
                                                                          userInfo:nil
                                                                           repeats:YES];
            }

            // Schedule play count increment
            dispatch_block_t updatePlayCountBlock = ^{
                [self schedulePlayCountIncrementForTrack:nextTrackURL];
            };
            dispatch_async(dispatch_get_main_queue(), updatePlayCountBlock);

            // Force UI updates
            dispatch_block_t forceUIUpdateBlock = ^{
                [self.view setNeedsDisplay:YES];
            };
            dispatch_async(dispatch_get_main_queue(), forceUIUpdateBlock);

            // Update the combo box to reflect the current track being played
            NSInteger index = [self.audioFiles indexOfObject:self.currentTrackURL];
            NSUInteger comboBoxIndex;

            if (index != NSNotFound) {
                comboBoxIndex = index + 1; // Offset by 1 for placeholder
            } else {
                comboBoxIndex = 0; // Placeholder index
            }

            dispatch_block_t updateComboBox = ^{
                [self.songComboBox selectItemAtIndex:comboBoxIndex];
            };
            dispatch_async(dispatch_get_main_queue(), updateComboBox);

            // Adiantar a faixa a seguir a esta — mas só depois de esta ter ido
            // buscar a sua à ranhura. A reprodução, acima, foi despachada para a
            // fila principal; pedir o adiantamento já fazia a ranhura passar a
            // apontar para a faixa seguinte antes de esta a consumir, e a
            // transição no fim da música — que é o caso para que o adiantamento
            // foi feito — acabava sempre a ler do disco.
            dispatch_block_t prefetchBlock = ^{
                [self prefetchNextTrack];
            };
            dispatch_async(dispatch_get_main_queue(), prefetchBlock);

        } else {
            #ifdef DEBUG
            NSLog(@"End of playlist reached.");
            #endif
            self.currentTrackIndex = 0;
            dispatch_block_t playAudioBlock = ^{
                [self playAudio];
            };
            dispatch_async(dispatch_get_main_queue(), playAudioBlock);
        }
    }
    self.isCalledFromPlayNextTrack = NO;
}

- (void)playAudio {
    // Arrancar uma faixa nunca deixa o tocador em pausa: a selecção verde sai,
    // venha o pedido do botão ▶️, da lista de músicas ou do fim da faixa anterior.
    dispatch_block_t clearPauseSelection = ^{
        self.isPlaybackPaused = NO;
        [self updatePauseButtonAppearance:NO];
    };
    if ([NSThread isMainThread]) {
        clearPauseSelection();
    } else {
        dispatch_async(dispatch_get_main_queue(), clearPauseSelection);
    }

    [self startBs2bIfNeeded];
    //self.replayGainValue = 0.0f;

    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }

    if (self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(NSLocalizedString(@"no_audio_files_to_play", @"No audio files to play."));
        #endif
        return;
    }
    
    #ifdef DEBUG
    NSLog(NSLocalizedString(@"starting_playback_for_track", @"Starting playback for track index: %ld"), (long)self.currentTrackIndex);
    #endif
    
    // Stop any current playback to avoid overlapping
    [self stopAudio];

    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    // Determine the track to play based on the current mode (shuffle or not)
    NSArray<NSURL *> *playbackList = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
    if (playbackList.count == 0) {
        #ifdef DEBUG
        NSLog(NSLocalizedString(@"no_audio_files_to_play", @"No audio files to play."));
        #endif
        return;
    }
    // Índice fora da lista (biblioteca recarregada, ficheiros removidos): em modo
    // aleatório sorteia-se uma faixa, em modo sequencial recomeça-se do princípio.
    if (self.currentTrackIndex < 0 || self.currentTrackIndex >= (NSInteger)playbackList.count) {
        self.currentTrackIndex = self.isShuffleModeActive ? [self randomShuffledStartIndex] : 0;
    }
    NSURL *trackURL = playbackList[self.currentTrackIndex];
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;  // Use original if available

    NSString *extension = trackURL.pathExtension.lowercaseString;
    #ifdef DEBUG
    NSLog(@"Playing track URL: %@", trackURL.absoluteString);
    #endif

    // Suspender o temporizador anterior sem perder o tempo já decorrido. Invalidá-lo
    // à mão aqui deitava fora essa contabilidade, e -schedulePlayCountIncrementForTrack:
    // logo a seguir decide se isto é faixa nova ou retoma.
    [self suspendPlayCountTracking];

    // Update the current track URL
    self.currentTrackURL = trackURL;

    // Schedule the play count increment for the original track URL
    [self schedulePlayCountIncrementForTrack:originalTrackURL];

    // Só depois de o acompanhamento estar armado é que o rótulo é reposto: numa
    // faixa nova fica vazio, numa retoma da mesma faixa mantém a contagem.
    [self refreshPlayCountLabel];

    // Update the combo box to reflect the current track being played
    NSInteger index = [self.audioFiles indexOfObject:self.currentTrackURL];
    NSUInteger comboBoxIndex;

    if (index != NSNotFound) {
        comboBoxIndex = index + 1; // Offset by 1 for placeholder
    } else {
        comboBoxIndex = 0; // Placeholder index
    }

    dispatch_block_t updateComboBox = ^{
        [self.songComboBox selectItemAtIndex:comboBoxIndex];
    };
    dispatch_async(dispatch_get_main_queue(), updateComboBox);

    // Proceed with playback depending on the file format
    if ([extension isEqualToString:@"wv"]) {
        [self handleWavPackPlayback:trackURL];
    } else if ([extension isEqualToString:@"flac"]) {
        [self handleFlacPlayback:trackURL];
    } else if ([extension isEqualToString:@"opus"]) {
        [self handleOpusPlayback:trackURL];  // Add Opus playback support here
    } else {
        [self handleStandardAudioPlayback:trackURL];
    }

    // Prefetch the next track after current playback starts
    [self prefetchNextTrack];

}

- (void)extractAndDisplayMetadataForWavPack:(NSURL *)trackURL {
    // 1. Parse the WavPack metadata.
    const char *filePath = [trackURL.path UTF8String];

    // Open the WAVPack file to extract metadata. Espreita-se a ranhura sem a
    // esvaziar: quem a consome é o -playWavPack: que vem logo a seguir.
    NSData *dataToUse = [self prefetchedDataForTrack:trackURL];
    char error[80];
    WavpackContext *wpc = NULL;
    if (dataToUse) {
        MemoryBuffer buffer = { .data = dataToUse.bytes, .size = dataToUse.length, .pos = 0 };
        wpc = WavpackOpenFileInputEx(&memoryReader, &buffer, NULL, error, OPEN_TAGS, 0);
    } else {
        wpc = WavpackOpenFileInput(filePath, error, OPEN_TAGS, 0);
    }
    if (!wpc) {
        #ifdef DEBUG
        NSLog(@"Error opening WAVPack file: %s", error);
        #endif
        return; // or handle differently if you must keep streaming anyway
    }

    // Variables to hold metadata values
    NSString *artist       = @"Unknown Artist";
    NSString *album        = @"Unknown Album";
    NSString *title        = @"Unknown Title";
    NSString *trackNumber  = @"0";  // default
    float gainDbValue      = 0.0f;  // We'll store raw dB here

    // Helper pointer(s)
    char *tagValue;
    int tagSize;

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Artist"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Artist", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Artist", tagValue, tagSize + 1);
        artist = [self replaceSingleQuoteAndSmartQuotes:[NSString stringWithUTF8String:tagValue]];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Album"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Album", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Album", tagValue, tagSize + 1);
        album = [self replaceSingleQuoteAndSmartQuotes:[NSString stringWithUTF8String:tagValue]];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Title"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Title", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Title", tagValue, tagSize + 1);
        title = [self replaceSingleQuoteAndSmartQuotes:[NSString stringWithUTF8String:tagValue]];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Track"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Track", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Track", tagValue, tagSize + 1);
        
        trackNumber = [NSString stringWithUTF8String:tagValue];
        // Remove leading zeros, but leave a single zero if the track number is actually 0
        NSRegularExpression *leadingZerosRegex = [NSRegularExpression regularExpressionWithPattern:@"^0+(?!$)"
                                                    options:0
                                                    error:nil];
        trackNumber = [leadingZerosRegex stringByReplacingMatchesInString:trackNumber
                                                    options:0
                                                    range:NSMakeRange(0, trackNumber.length)
                                                    withTemplate:@""];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract replaygain_track_gain (dB)
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "replaygain_track_gain", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "replaygain_track_gain", tagValue, tagSize + 1);

        NSString *gainString = [NSString stringWithUTF8String:tagValue];
        free(tagValue);

        // Remove trailing " dB" if present
        gainString = [gainString stringByReplacingOccurrencesOfString:@" dB" withString:@""];

        // Convert to float
        if (gainString && [gainString length] > 0) {
            gainDbValue = [gainString floatValue];
        } else {
            #ifdef DEBUG
            NSLog(@"[ReplayGain] WavPack invalid gainString extracted: %@", gainString);
            #endif
            gainDbValue = 0.0; // Default fallback value
        }

        // Store it in the property on the main thread (if UI code might be triggered)
        dispatch_async(dispatch_get_main_queue(), ^{
            self.replayGainValue = gainDbValue;

            #ifdef DEBUG
            NSLog(@"[ReplayGain] WavPack track gain: %.2f dB", self.replayGainValue);
            #endif

            [self pushReplayGainToStreamer];
        });
}

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract replaygain_album_gain / _peak
    // ─────────────────────────────────────────────────────────────────────────────
    for (int alvo = 0; alvo < 2; ++alvo) {
        const char *chave = alvo == 0 ? "replaygain_album_gain" : "replaygain_album_peak";
        tagSize = WavpackGetTagItem(wpc, chave, NULL, 0);
        if (tagSize <= 0) {
            continue;
        }
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, chave, tagValue, tagSize + 1);
        NSString *texto = [NSString stringWithUTF8String:tagValue];
        free(tagValue);

        float valor = [[texto stringByReplacingOccurrencesOfString:@" dB" withString:@""] floatValue];
        BOOL ehGanho = (alvo == 0);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ehGanho) {
                self.replayGainAlbumValue = valor;
            } else {
                self.replayGainAlbumPeak = valor;
            }
            #ifdef DEBUG
            NSLog(@"[ReplayGain] WavPack album %@: %.4f", ehGanho ? @"gain" : @"peak", valor);
            #endif
            [self pushReplayGainToStreamer];
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract replaygain_track_peak (0…1)
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "replaygain_track_peak", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "replaygain_track_peak", tagValue, tagSize + 1);

        NSString *peakString = [NSString stringWithUTF8String:tagValue];
        free(tagValue);

        float peakValue = [peakString floatValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.replayGainPeak = peakValue;

            #ifdef DEBUG
            NSLog(@"[ReplayGain] WavPack track peak: %.4f", self.replayGainPeak);
            #endif

            [self pushReplayGainToStreamer];
        });
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract Cover Art (if any)
    // ─────────────────────────────────────────────────────────────────────────────
    NSData *coverArtData = nil;
    tagSize = WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", NULL, 0);
    if (tagSize > 0) {
        void *binaryData = malloc(tagSize);
        WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", binaryData, tagSize);

        // Skip the filename portion
        unsigned char *imageData = (unsigned char *)binaryData;
        while (*imageData != '\0') { imageData++; }
        imageData++;

        NSUInteger imageDataLength = tagSize - (imageData - (unsigned char *)binaryData);
        coverArtData = [NSData dataWithBytes:imageData length:imageDataLength];
        
        free(binaryData);
    }

    // Close WavPack
    WavpackCloseFile(wpc);

    // 2. Update the UI & apply the new ReplayGain after we've parsed
    dispatch_block_t updateUIBlock = ^{
        // Update labels
        NSString *formattedTitle = [NSString stringWithFormat:@"%@. %@", trackNumber, title];
        [self.artistLabel setStringValue:artist];
        [self.albumLabel setStringValue:album];
        [self.titleLabel setStringValue:formattedTitle];

        // Display cover art, if any
        if (coverArtData) {
            NSImage *coverImage = [[NSImage alloc] initWithData:coverArtData];
            if (coverImage && coverImage.size.width > 0) {
                [self.coverArtView setImage:coverImage];
            } else {
                #ifdef DEBUG
                NSLog(@"Failed to create image from cover art data.");
                #endif
                [self.coverArtView setImage:nil];
            }
        } else {
            [self.coverArtView setImage:nil]; // no cover art
        }

        // Trigger notification
        [self triggerNowPlayingNotificationWithTitle:formattedTitle
                                              artist:artist
                                               album:album];
    };

    // 3. Dispatch the UI updates (and ReplayGain update) to the main queue
    dispatch_async(dispatch_get_main_queue(), updateUIBlock);
}

- (void)cleanupCoreAudioPlayback {
    if (playbackState.isPlaying) {
        // Set playbackState.isPlaying to NO to prevent further callbacks
        playbackState.isPlaying = NO;
        
        // Stop the AudioQueue
        AudioQueueStop(playbackState.audioQueue, true);
    }

    // Invalidate the progress update timer
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressUpdateTimer) {
            [self.progressUpdateTimer invalidate];
            self.progressUpdateTimer = nil;
        }

        // Execute the block asynchronously on the main thread
        [self.progressBar setDoubleValue:0.0];
    });

    // Free audio buffers
    for (int i = 0; i < NUM_BUFFERS; i++) {
        if (playbackState.buffers[i]) {
            AudioQueueFreeBuffer(playbackState.audioQueue, playbackState.buffers[i]);
            playbackState.buffers[i] = NULL;
        }
    }

    // Dispose of the audio queue
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);
        playbackState.audioQueue = NULL;
    }

    // Free the sample buffer
    if (playbackState.sampleBuffer) {
        free(playbackState.sampleBuffer);
        playbackState.sampleBuffer = NULL;
    }

    // Note: DO NOT close playbackState.wpc or reset other fields here
    // This ensures that WavPack playback can initialize correctly
}

- (void)setupUI {
    // Static dimensions for the window: 750x250
    CGFloat windowWidth = 750;

    // CD cover art position
    self.coverArtView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 120, 120, 120)];
    self.coverArtView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.coverArtView.imageAlignment = NSImageAlignCenter;
    self.coverArtView.wantsLayer = YES; // ajuda com vibrancy e repaints
    self.coverArtView.layer.masksToBounds = YES;
    [self.view addSubview:self.coverArtView];

    // Histogram position (same height as CD art, twice as wide)
    CGFloat histogramWidth = 240;   // 2x CD art width (2 * 120)
    CGFloat histogramHeight = 120;  // Same as CD art height
    CGFloat histogramXPosition = 490;

    self.histogramView = [[HistogramView alloc] initWithFrame:NSMakeRect(histogramXPosition, 120, histogramWidth, histogramHeight)];
    [self.view addSubview:self.histogramView];

    // Labels for Artist, Album, and Title
    CGFloat labelXPosition = 160;   // 20 padding + 120 cover
    CGFloat labelMaxWidth  = 320;   // (440 - 160)

    // Artist label
    self.artistLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelXPosition, 205, labelMaxWidth, 30)];
    self.artistLabel.font = [NSFont systemFontOfSize:22];
    self.artistLabel.alignment = NSTextAlignmentLeft;
    self.artistLabel.bezeled = NO;
    self.artistLabel.drawsBackground = NO;
    self.artistLabel.editable = NO;
    self.artistLabel.selectable = NO;
    self.artistLabel.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.artistLabel];

    // Album label
    self.albumLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelXPosition, 165, labelMaxWidth, 30)];
    self.albumLabel.font = [NSFont systemFontOfSize:22];
    self.albumLabel.alignment = NSTextAlignmentLeft;
    self.albumLabel.bezeled = NO;
    self.albumLabel.drawsBackground = NO;
    self.albumLabel.editable = NO;
    self.albumLabel.selectable = NO;
    self.albumLabel.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.albumLabel];

    // Title label
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelXPosition, 125, labelMaxWidth, 30)];
    self.titleLabel.font = [NSFont systemFontOfSize:22];
    self.titleLabel.alignment = NSTextAlignmentLeft;
    self.titleLabel.bezeled = NO;
    self.titleLabel.drawsBackground = NO;
    self.titleLabel.editable = NO;
    self.titleLabel.selectable = NO;
    self.titleLabel.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.titleLabel];

    // Buttons (centered horizontally at the bottom)
    CGFloat buttonWidth = 26;
    CGFloat buttonHeight = 26;
    NSInteger numberOfButtons = 8;
    CGFloat totalButtonWidth = buttonWidth * numberOfButtons;
    CGFloat startX = (windowWidth - totalButtonWidth) / 2.0;
    CGFloat buttonYPosition = 20;

    // ⏮️
    self.backwardButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.backwardButton, @"⏮️");
    self.backwardButton.target = self;
    self.backwardButton.action = @selector(backwardTrack);
    [self.view addSubview:self.backwardButton];

    // ▶️
    startX += buttonWidth;
    self.playButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.playButton, @"▶️");
    self.playButton.target = self;
    self.playButton.action = @selector(playButtonPressed);
    [self.view addSubview:self.playButton];

    // ⏸️
    startX += buttonWidth;
    self.pauseButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.pauseButton, @"⏸️");
    self.pauseButton.target = self;
    self.pauseButton.action = @selector(pauseAudio);
    [self.view addSubview:self.pauseButton];

    // ⏹️
    startX += buttonWidth;
    self.stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.stopButton, @"⏹️");
    self.stopButton.target = self;
    self.stopButton.action = @selector(stopButtonPressed);
    [self.view addSubview:self.stopButton];

    // ⏭️
    startX += buttonWidth;
    self.forwardButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.forwardButton, @"⏭️");
    self.forwardButton.target = self;
    self.forwardButton.action = @selector(forwardTrack);
    [self.view addSubview:self.forwardButton];

    // 🔁
    startX += buttonWidth;
    self.repeatButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.repeatButton, @"🔁");
    self.repeatButton.target = self;
    self.repeatButton.action = @selector(repeatTracks);
    [self.view addSubview:self.repeatButton];

    // 🔀
    startX += buttonWidth;
    self.shuffleButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.shuffleButton, @"🔀");
    self.shuffleButton.target = self;
    self.shuffleButton.action = @selector(shuffleTracks);
    [self.view addSubview:self.shuffleButton];

    // ⏺️
    startX += buttonWidth;
    self.recordButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    ZPPreparaBotaoDeTransporte(self.recordButton, @"⏺️");
    self.recordButton.target = self;
    self.recordButton.action = @selector(recordAudio);
    [self.view addSubview:self.recordButton];

    // Progress bar
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(160, 80, windowWidth - 320, 20)];
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 100.0;
    self.progressBar.doubleValue = 0.0;
    [self.view addSubview:self.progressBar];

    // Play count label (lower-right)
    CGFloat labelWidth = 200, labelHeight = 30, padding = 10;
    self.playCountLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(windowWidth - labelWidth - padding, -5, labelWidth, labelHeight)];
    self.playCountLabel.font = [NSFont systemFontOfSize:11];
    self.playCountLabel.alignment = NSTextAlignmentRight;
    self.playCountLabel.bezeled = NO;
    self.playCountLabel.drawsBackground = NO;
    self.playCountLabel.editable = NO;
    self.playCountLabel.selectable = NO;
    [self.view addSubview:self.playCountLabel];

    // Combo box
    [self createComboBox];

    // **Garante que a capa fica por cima de tudo o que foi adicionado depois**
    [self.view addSubview:self.coverArtView positioned:NSWindowAbove relativeTo:nil];

    // Botão do filtro: por baixo da capa, na faixa livre entre ela e os botões
    // de transporte. Centrado no meio da capa (x = 80) e à mesma altura que a
    // barra de progresso (centro em y = 90), tirando ambas as medidas das
    // vistas em vez de as fixar à mão.
    //
    // Entra em último lugar e explicitamente por cima de tudo, e isso não é
    // capricho: nesta janela a subvista que fica no fundo da pilha (índice 0)
    // não chega a ser desenhada. Verifiquei-o com o lldb na aplicação a correr —
    // o botão estava na hierarquia, com moldura certa, visível e opaco, e mesmo
    // assim invisível; pôr o botão do AirPlay no índice 0 fá-lo desaparecer
    // exactamente da mesma maneira. Como a capa é reposicionada por cima de
    // tudo mesmo aqui acima, quem for adicionado antes dela acaba no fundo.
    CGFloat ladoBotaoFiltro = 20;
    NSRect botaoFiltro = NSMakeRect(NSMidX(self.coverArtView.frame) - ladoBotaoFiltro / 2.0,
                                    NSMidY(self.progressBar.frame)  - ladoBotaoFiltro / 2.0,
                                    ladoBotaoFiltro,
                                    ladoBotaoFiltro);
    self.bs2bToggleButton = [[NSButton alloc] initWithFrame:botaoFiltro];
    self.bs2bToggleButton.bezelStyle = NSBezelStyleRegularSquare;
    self.bs2bToggleButton.bordered = NO;
    // Fica sempre activo por uma questão de visibilidade: desactivado, é
    // desenhado tão esbatido que não se vê. A regra dos auscultadores é imposta
    // na acção (recusa e apita), não no aspecto.
    self.bs2bToggleButton.enabled = YES;
    self.bs2bToggleButton.target = self;
    self.bs2bToggleButton.action = @selector(toggleBs2bFilter:);
    [self updateBs2bToggleButtonAppearance];
    [self.view addSubview:self.bs2bToggleButton positioned:NSWindowAbove relativeTo:nil];

    #ifdef DEBUG
    NSLog(@"[bs2b] Botão do filtro: moldura %@, imagem %@, índice %lu de %lu subvistas",
          NSStringFromRect(self.bs2bToggleButton.frame),
          self.bs2bToggleButton.image,
          (unsigned long)[self.view.subviews indexOfObject:self.bs2bToggleButton],
          (unsigned long)self.view.subviews.count);
    #endif
}

#pragma mark - HTML ”Now Playing“

- (void)generateNowPlayingPage {
    // Get the data from the UI elements
    // Declare variables to hold UI data
    __block NSString *artistName = @"";
    __block NSString *albumName = @"";
    __block NSString *songTitle = @"";
    __block NSImage *coverArtImage = nil;
    __block NSURL *trackURL = nil;

    // Access UI elements on the main thread
    dispatch_sync(dispatch_get_main_queue(), ^{
        artistName = self.artistLabel.stringValue ?: @"";
        albumName = self.albumLabel.stringValue ?: @"";
        songTitle = self.titleLabel.stringValue ?: @"";
        coverArtImage = self.coverArtView.image;
        trackURL = self.currentTrackURL;
    });

    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;
    NSNumber *playCount = [self.trackPlayCounts objectForKey:originalTrackURL.path];

    // Define the paths
    NSString *homeDirectory = NSHomeDirectory();
    NSString *sitesDirectory = [homeDirectory stringByAppendingPathComponent:@"Sites"];
    NSString *htmlFilePath = [sitesDirectory stringByAppendingPathComponent:@"now_playing.html"];
    NSString *coverImagePath = [sitesDirectory stringByAppendingPathComponent:@"cover.png"];

    // Ensure the Sites directory exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:sitesDirectory]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:sitesDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[HTML] Error creating Sites directory: %@", error);
            #endif
            return;
        }
    }

    // Save the resized cover art image as cover.png in ~/Sites/
    if (coverArtImage) {
        // Get the CGImage from NSImage
        CGImageRef cgImage = [coverArtImage CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage) {
            CGSize targetSize = CGSizeMake(600, 600); // Desired size
            CGFloat oversampleFactor = 4.0; // Oversampling factor (e.g., 2x)
            CGSize oversampledSize = CGSizeMake(targetSize.width * oversampleFactor, targetSize.height * oversampleFactor);

            // Create an oversampled bitmap context
            CGContextRef oversampleContext = CGBitmapContextCreate(NULL,
                                                                   oversampledSize.width,
                                                                   oversampledSize.height,
                                                                   CGImageGetBitsPerComponent(cgImage),
                                                                   0,
                                                                   CGImageGetColorSpace(cgImage),
                                                                   CGImageGetBitmapInfo(cgImage));

            if (oversampleContext) {
                // Set interpolation quality for oversampling
                CGContextSetInterpolationQuality(oversampleContext, kCGInterpolationHigh);
                CGContextSetShouldAntialias(oversampleContext, true);

                // Draw the image into the oversampled context
                CGContextDrawImage(oversampleContext, CGRectMake(0, 0, oversampledSize.width, oversampledSize.height), cgImage);

                // Create a CGImage from the oversampled context
                CGImageRef oversampledImage = CGBitmapContextCreateImage(oversampleContext);

                // Now downscale the oversampled image to the target size
                CGContextRef targetContext = CGBitmapContextCreate(NULL,
                                                                   targetSize.width,
                                                                   targetSize.height,
                                                                   CGImageGetBitsPerComponent(oversampledImage),
                                                                   0,
                                                                   CGImageGetColorSpace(oversampledImage),
                                                                   CGImageGetBitmapInfo(oversampledImage));

                if (targetContext) {
                    // Set interpolation quality for downscaling
                    CGContextSetInterpolationQuality(targetContext, kCGInterpolationHigh);
                    CGContextSetShouldAntialias(targetContext, true);

                    // Draw the oversampled image into the target context
                    CGContextDrawImage(targetContext, CGRectMake(0, 0, targetSize.width, targetSize.height), oversampledImage);

                    // Create the final downscaled image
                    CGImageRef finalImage = CGBitmapContextCreateImage(targetContext);

                    // Save the resized image as PNG
                    NSURL *outputURL = [NSURL fileURLWithPath:coverImagePath];

                    // Use the new UTTypePNG
                    CFStringRef uti = (__bridge CFStringRef)UTTypePNG.identifier;

                    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
                        (__bridge CFURLRef)outputURL,
                        uti,
                        1,
                        NULL);

                    if (destination) {
                        CGImageDestinationAddImage(destination, finalImage, NULL); // No quality setting needed for PNG
                        if (!CGImageDestinationFinalize(destination)) {
                            #ifdef DEBUG
                            NSLog(@"[HTML] Failed to write image to %@", coverImagePath);
                            #endif
                        }
                        CFRelease(destination);
                    } else {
                        #ifdef DEBUG
                        NSLog(@"[HTML] Failed to create CGImageDestination for %@", coverImagePath);
                        #endif
                    }

                    // Clean up
                    CGImageRelease(finalImage);
                    CGContextRelease(targetContext);
                } else {
                    #ifdef DEBUG
                    NSLog(@"[HTML] Failed to create target context");
                    #endif
                }

                // Clean up
                CGImageRelease(oversampledImage);
                CGContextRelease(oversampleContext);
            } else {
                #ifdef DEBUG
                NSLog(@"[HTML] Failed to create oversampled context");
                #endif
            }
        } else {
            #ifdef DEBUG
            NSLog(@"[HTML] Failed to get CGImage from NSImage");
            #endif
        }
    } else {
        // Use a default placeholder image if cover art is not available
        NSString *placeholderPath = [[NSBundle mainBundle] pathForResource:@"placeholder" ofType:@"png"];
        if (placeholderPath) {
            [fileManager copyItemAtPath:placeholderPath toPath:coverImagePath error:nil];
        } else {
            #ifdef DEBUG
            NSLog(@"[HTML] Placeholder image not found in app bundle");
            #endif
        }
    }

    // Generate the HTML content
    NSMutableString *htmlContent = [NSMutableString stringWithString:
    @"<!DOCTYPE html>\n"
    @"<html>\n"
    @"<head>\n"
    @"    <meta charset=\"UTF-8\">\n"
    @"    <meta name=\"generator\" content=\"tocaTintas\">\n"
    @"    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
    @"    <meta name=\"disabled-adaptations\" content=\"watch\">\n"
    @"    <meta http-equiv=\"refresh\" content=\"10\">\n"
    ];

    if (songTitle.length > 0 && artistName.length > 0 && albumName.length > 0) {
        [htmlContent appendFormat:
         @"    <meta property=\"og:title\" content=\"Now Playing: %@\">\n", songTitle];
        [htmlContent appendFormat:
         @"    <meta property=\"og:description\" content=\"Enjoy the latest track by %@ from the album %@.\">\n", artistName, albumName];
    } else {
        [htmlContent appendString:
         @"    <meta property=\"og:title\" content=\"Now Playing\">\n"];
        [htmlContent appendString:
         @"    <meta property=\"og:description\" content=\"Discover the latest music.\">\n"];
    }

    [htmlContent appendString:
    @"    <meta property=\"og:image\" content=\"cover.png\">\n"
    @"    <meta property=\"og:image:type\" content=\"image/png\">\n"
    @"    <meta property=\"og:image:width\" content=\"150\">\n"
    @"    <meta property=\"og:image:height\" content=\"150\">\n"
    @"    <meta property=\"og:url\" content=\"https://zpsurfistaprateadopreto.local/~amaral/now_playing.html\">\n"
    @"    <meta property=\"og:type\" content=\"music.song\">\n"
    @"    <title>tocaTintas</title>\n"
    @"    <link rel=\"icon\" type=\"image/png\" href=\"images/pedro-logotipo-caixa.png\">\n"
    @"\n"
    @"    <style>\n"
    @"        body {\n"
    @"            margin: 0;\n"
    @"            padding: 0;\n"
    @"            text-align: center;\n"
    @"            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;\n"
    @"            background-color: black;\n"
    @"            color: white;\n"
    @"        }\n"
    @"        .cover {\n"
    @"            margin-top: 33vh; /* 33% da altura da janela visível */\n"
    @"        }\n"
    @"        .cover img {\n"
    @"            width: 150px;\n"
    @"            height: 150px;\n"
    @"            border-radius: 15px;\n"
    @"            cursor: pointer;\n"
    @"        }\n"
    @"        .info {\n"
    @"            padding: 5px;\n"
    @"        }\n"
    @"        .info h1, .info h2, .info h3 {\n"
    @"            margin: 5px;\n"
    @"            font-size: 14px;\n"
    @"            line-height: 1.2;\n"
    @"        }\n"
    @"        .play-count {\n"
    @"            margin: 5px;\n"
    @"            font-size: 11px;\n"
    @"            color: #888888;\n"
    @"        }\n"
    @"    </style>\n"
    @"</head>\n"
    @"<body>\n"
    @"    <!-- Add the cover art image as a link -->\n"
    @"    <div class=\"cover\">\n"
    @"        <a href=\"now_playing.html\">\n"
    @"            <img src=\"cover.png?timestamp\" alt=\"Cover Art\">\n"
    @"        </a>\n"
    @"    </div>\n"
    @"\n"
    @"    <!-- Add the song information -->\n"
    @"    <div class=\"info\">\n"];

    if (artistName.length > 0) {
        [htmlContent appendFormat:@"<!-- ARTIST -->\n<h1>%@</h1>\n", artistName];
    }
    if (albumName.length > 0) {
        [htmlContent appendFormat:@"<!-- ALBUM -->\n<h2>%@</h2>\n", albumName];
    }
    if (songTitle.length > 0) {
        [htmlContent appendFormat:@"<!-- SONG -->\n<h3>%@</h3>\n", songTitle];
    }
    if (playCount && playCount.intValue > 0) {
        NSString *playCountLabel = playCount.intValue == 1
            ? NSLocalizedString(@"Played 1 time", @"Play count label when played at least once")
            : [NSString stringWithFormat:NSLocalizedString(@"Played %@ times", @"Play count label when played more than once"), playCount];
        [htmlContent appendFormat:@"<p class=\"play-count\">%@</p>\n", playCountLabel];
    }

    [htmlContent appendString:
    @"    </div>\n"
    @"</body>\n"
    @"</html>\n"];

    // Write the HTML content to now_playing.html
    NSError *writeError = nil;
    [htmlContent writeToFile:htmlFilePath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (writeError) {
        #ifdef DEBUG
        NSLog(@"[HTML] Error writing HTML file: %@", writeError);
        #endif
    }

    // Save the refresh icon image to ~/Sites/refresh_icon.png
    // Ensure you have a 'refresh_icon.png' in your app bundle
    NSString *refreshIconPath = [sitesDirectory stringByAppendingPathComponent:@"refresh_icon.png"];
    NSString *bundleRefreshIconPath = [[NSBundle mainBundle] pathForResource:@"refresh_icon" ofType:@"png"];
    if (bundleRefreshIconPath) {
        [fileManager removeItemAtPath:refreshIconPath error:nil]; // Remove existing file if it exists
        [fileManager copyItemAtPath:bundleRefreshIconPath toPath:refreshIconPath error:nil];
    } else {
        #ifdef DEBUG
        NSLog(@"[HTML] Refresh icon image not found in app bundle");
        #endif
    }
}

#pragma mark - NSComboBoxDataSource Methods

// Returns the number of items in the combo box
- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)comboBox {
    return self.displayNames.count;
}

// Returns the object value for the item at the specified index
- (id)comboBox:(NSComboBox *)comboBox objectValueForItemAtIndex:(NSInteger)index {
    return self.displayNames[index];
}

// Returns the index of the item matching the given string
- (NSUInteger)comboBox:(NSComboBox *)comboBox indexOfItemWithStringValue:(NSString *)string {
    NSString *lowercaseInput = [string lowercaseString];
    for (NSUInteger i = 0; i < self.displayNames.count; i++) {
        NSString *item = [self.displayNames[i] lowercaseString];
        if ([item isEqualToString:lowercaseInput]) {
            return i;
        }
    }
    return NSNotFound;
}

// Returns the completed string for the given input
- (NSString *)comboBox:(NSComboBox *)comboBox completedString:(NSString *)string {
    #ifdef DEBUG
    NSLog(@"comboBox:completedString: called with input string: %@", string);
    #endif

    NSString *lowercaseInput = [string lowercaseString];

    // Corrected regular expression to remove leading numbers and specific special characters
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9-]+\\s*"
                                                                           options:0
                                                                             error:nil];

    // Iterate through the display names
    for (NSString *displayName in self.displayNames) {
        // Convert display name to lowercase for case-insensitive matching
        NSString *lowercaseDisplayName = [displayName lowercaseString];

        // Remove leading digits and special characters from the display name
        NSString *cleanedDisplayName = [regex stringByReplacingMatchesInString:lowercaseDisplayName
                                                                       options:0
                                                                         range:NSMakeRange(0, lowercaseDisplayName.length)
                                                                  withTemplate:@""];

        #ifdef DEBUG
        NSLog(@"Checking displayName: %@, Cleaned displayName: %@", displayName, cleanedDisplayName);
        #endif

        // Check if the input string matches the prefix of the cleaned display name
        if ([cleanedDisplayName hasPrefix:lowercaseInput]) {
            #ifdef DEBUG
            NSLog(@"Found match: %@", displayName);
            #endif
            return displayName; // Return the display name for auto-completion
        }
    }

    #ifdef DEBUG
    NSLog(@"No match found.");
    #endif
    return nil;
}

#pragma mark - NSComboBoxDelegate Methods

- (void)comboBoxWillPopUp:(NSNotification *)notification {
    if (self.isPlaylistModeActive) {
        // Check if the files in the playlist still exist
        [self validatePlaylistFiles];
    } else {
        [self loadAudioFiles];
    }
    // Update the combo box items
    [self createComboBox];
}

- (void)comboBoxSelectionChanged:(NSComboBox *)comboBox {
    NSInteger selectedIndex = comboBox.indexOfSelectedItem;

    if (selectedIndex > 0 && selectedIndex <= self.audioFiles.count) {
        [self stopAudio];

        // Get the selected track URL from the original audioFiles array
        NSURL *selectedTrackURL = self.audioFiles[selectedIndex - 1];
        self.currentTrackURL = selectedTrackURL;

        if (self.isShuffleModeActive) {
            // Find the index of the selected track in the shuffled array
            NSUInteger shuffledIndex = [self.shuffledTracks indexOfObject:selectedTrackURL];
            if (shuffledIndex != NSNotFound) {
                self.currentTrackIndex = shuffledIndex;
            } else {
                #ifdef DEBUG
                NSLog(@"Error: Selected track not found in shuffledAudioFiles.");
                #endif
                return;
            }
        } else {
            self.currentTrackIndex = selectedIndex - 1;
        }

        // Play audio for the selected track
        [self playAudio];

        // Ensure combobox reflects the correct item
        [self.songComboBox selectItemAtIndex:selectedIndex];
    } else if (selectedIndex == 0) {
        #ifdef DEBUG
        NSLog(@"User selected the placeholder 'choose a song'. No track selected.");
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"Invalid song selection.");
        #endif
    }
}

#pragma mark - Combo Box Setup

// The combo box rows follow self.audioFiles order; in shuffle mode
// currentTrackIndex points into shuffledTracks, so the selected row
// must be derived from the current track URL, not from the index.
- (NSInteger)comboBoxIndexForCurrentTrack {
    NSURL *trackURL = self.currentTrackURL;
    if (!trackURL && self.currentTrackIndex >= 0) {
        if (self.isShuffleModeActive) {
            if (self.currentTrackIndex < (NSInteger)self.shuffledTracks.count) {
                trackURL = self.shuffledTracks[self.currentTrackIndex];
            }
        } else if (self.currentTrackIndex < (NSInteger)self.audioFiles.count) {
            trackURL = self.audioFiles[self.currentTrackIndex];
        }
    }
    if (!trackURL) {
        return 0; // Placeholder
    }
    NSUInteger index = [self.audioFiles indexOfObject:trackURL];
    return (index != NSNotFound) ? (NSInteger)(index + 1) : 0;
}

- (void)createComboBox {
    if (!self.audioFiles || self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(@"No audio files to populate the combo box.");
        #endif
        return;
    }

    NSMutableArray<NSString *> *displayNames = [NSMutableArray array];
    [displayNames addObject:NSLocalizedString(@"choose_song_here", @"Prompt for choosing a song")]; // Placeholder

    NSMutableArray<NSString *> *fullFileNames = [NSMutableArray array];

    // Remove leading digits and special characters from the song name
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9-]+\\s*"
                                                                           options:0
                                                                             error:nil];

    for (NSURL *fileURL in self.audioFiles) {
        NSString *fileName = fileURL.lastPathComponent;
        [fullFileNames addObject:fileName]; // Store full name for matching

        // Extract the song name and extension
        NSString *songName = [fileName stringByDeletingPathExtension];
        NSString *extension = [fileName pathExtension];

        // Remove leading digits and special characters from the song name
        NSString *cleanedSongName = [regex stringByReplacingMatchesInString:songName
                                                                    options:0
                                                                      range:NSMakeRange(0, songName.length)
                                                               withTemplate:@""];

        // Construct the display string in the desired format
        NSString *displayName = [NSString stringWithFormat:@"%@ (%@)", cleanedSongName, extension];

        // Log the display name
        #ifdef DEBUG
        NSLog(@"Display Name: %@", displayName);
        #endif

        [displayNames addObject:displayName];
    }

    // Store display names and full file names for delegate methods
    self.displayNames = [displayNames copy];
    self.fullFileNamesForMatching = [fullFileNames copy];

    if (self.songComboBox) {
        // Reload the combo box data
        [self.songComboBox reloadData];

        [self.songComboBox selectItemAtIndex:[self comboBoxIndexForCurrentTrack]];
    } else {
        self.songComboBox = [[NSComboBox alloc] initWithFrame:NSMakeRect(20, 20, 190, 26)];

        // Set up the combo box to use a data source
        [self.songComboBox setUsesDataSource:YES];
        self.songComboBox.dataSource = self;

        [self.songComboBox setNumberOfVisibleItems:40];
        [self.songComboBox selectItemAtIndex:[self comboBoxIndexForCurrentTrack]];
        [self.songComboBox setTarget:self];
        [self.songComboBox setAction:@selector(comboBoxSelectionChanged:)];
        self.songComboBox.delegate = self;

        // Enable autocomplete for the combo box
        [self.songComboBox setCompletes:YES];

        [self.view addSubview:self.songComboBox];
    }

    // Log the stored full file names
    #ifdef DEBUG
    NSLog(@"Full file names stored for matching: %@", self.fullFileNamesForMatching);
    #endif
}

// Formato do fluxo escrito pelo cava (output method = raw, data_format = binary,
// bit_format = 16bit, channels = stereo, bars = 30 no config_fifo): cada trama são
// exactamente 30 uint16 nativos — os primeiros 15 do canal esquerdo, os últimos 15
// do direito — sem qualquer delimitador entre tramas. Como o cava escreve barra a
// barra (write() de 2 bytes), o FIFO pode ser lido a meio de uma trama; é por isso
// que a leitura tem de manter o alinhamento entre chamadas, senão as barras aparecem
// rodadas (o espectro «desliza» para a esquerda ou para a direita).
enum {
    kCavaBars           = 30,
    kCavaBarsPerChannel = kCavaBars / 2,
    kCavaFrameBytes     = kCavaBars * 2,

    // Tramas guardadas na linha de atraso. Enfileiram-se ~25 por segundo, e o
    // atraso está limitado a kZPAtrasoMaximoDoHistograma, portanto isto dá
    // folga de sobra. São 68 bytes cada, ~17 KB no total.
    kCavaFilaMax        = 256
};

// Uma trama do cava com a hora a que foi lida.
typedef struct {
    NSTimeInterval instante;
    uint16_t barras[kCavaBars];
} ZPTramaCava;

// Quanto tempo o histograma se atrasa a si próprio para coincidir com o que se
// ouve. O cava lê o BlackHole, ou seja mostra o áudio no instante da captura, à
// cabeça da cadeia; o que sai do aparelho AirPlay é o mesmo áudio uns segundos
// depois. Escrito pelo thread principal na sondagem de um segundo, lido pelo
// thread do FIFO — daí ser atómico.
static _Atomic(double) gAtrasoDoHistograma = 0.0;

// Tecto do atraso. O corte de deriva do ZPAirPlayStreamer não deixa o áudio em
// trânsito passar dos seis segundos, e a latência pedida ao raop_play é um;
// acima disto é mais provável que o relógio esteja a mentir do que o áudio
// estar mesmo tanto tempo no ar.
static const double kZPAtrasoMaximoDoHistograma = 8.0;

// Quanto tempo sem nada para desenhar antes de se apagarem as colunas. Em regime
// chega uma trama a cada 40 ms, portanto há cinco vezes de folga: isto nunca
// dispara por acaso, só quando a linha de atraso está mesmo a encher.
static const NSTimeInterval kCavaEsperaAteApagar = 0.2;

// Read data from the FIFO file and update the histogram
- (void)readFifoDirectly {
    NSString *fifoPath = @"/var/tmp/cava_fifo";

    int fileDescriptor = open([fifoPath UTF8String], O_RDONLY | O_NONBLOCK);
    if (fileDescriptor < 0) {
        perror("[FIFO] Failed to open FIFO file");
        #ifdef DEBUG
        NSLog(@"[FIFO] Failed to open FIFO file at path: %@", fifoPath);
        #endif
        return;
    }
    #ifdef DEBUG
    NSLog(@"[FIFO] FIFO file opened successfully.");
    #endif
    dispatch_queue_t fifoQueue = dispatch_queue_create("com.example.cavahistogram.fifoqueue", DISPATCH_QUEUE_SERIAL);

    dispatch_async(fifoQueue, ^{
        uint8_t chunk[kCavaFrameBytes * 64];   // bloco de leitura
        uint8_t partial[kCavaFrameBytes];      // trama incompleta guardada entre leituras
        size_t partialCount = 0;
        uint16_t frame[kCavaBars];             // última trama completa lida
        NSTimeInterval ultimoEnfileiramento = 0;

        // Linha de atraso. As tramas entram aqui com a hora a que foram lidas e
        // só saem quando o áudio a que correspondem já se está mesmo a ouvir do
        // outro lado — ver kZPAtrasoMaximoDoHistograma.
        ZPTramaCava *fila = calloc(kCavaFilaMax, sizeof(ZPTramaCava));
        if (!fila) {
            NSLog(@"[FIFO] Sem memória para a linha de atraso do histograma.");
            close(fileDescriptor);
            return;
        }
        size_t cauda = 0;        // a próxima a sair
        size_t ocupadas = 0;

        NSTimeInterval ultimoDesenho = 0;
        BOOL vazioDesenhado = NO;

        // Tramas de zeros, construídas uma vez: é o que se manda desenhar quando
        // não há nada para mostrar.
        NSMutableArray<NSNumber *> *vazioEsquerdo = [NSMutableArray arrayWithCapacity:kCavaBarsPerChannel];
        NSMutableArray<NSNumber *> *vazioDireito  = [NSMutableArray arrayWithCapacity:kCavaBarsPerChannel];
        for (NSUInteger i = 0; i < kCavaBarsPerChannel; i++) {
            [vazioEsquerdo addObject:@0];
            [vazioDireito addObject:@0];
        }

        while (1) { @autoreleasepool {
            BOOL leuAlgo = NO;
            BOOL esperaLonga = NO;

            ssize_t size = read(fileDescriptor, chunk, sizeof(chunk));

            if (size < 0) {
                if (errno == EINTR) {
                    continue;
                }
                if (!(errno == EAGAIN || errno == EWOULDBLOCK)) {
                    perror("[FIFO] Failed to read from FIFO");
                    #ifdef DEBUG
                    NSLog(@"[FIFO] Failed to read from FIFO");
                    #endif
                    break;
                }
                // Sem dados por agora. Não se salta o resto do ciclo: a fila
                // pode ter tramas vencidas à espera de serem desenhadas, e com
                // um `continue` aqui a imagem congelava sempre que o cava
                // ficasse calado.
                #ifdef DEBUG
                NSLog(@"[FIFO] No data available yet, continuing to read…");
                #endif
            } else if (size == 0) {
                // O cava fechou o FIFO (por exemplo, foi reiniciado). O fluxo
                // recomeça numa fronteira de trama, portanto deita-se fora o resto.
                #ifdef DEBUG
                NSLog(@"[FIFO] No data available, sleeping…");
                #endif
                partialCount = 0;
                esperaLonga = YES;
            } else {
                leuAlgo = YES;
                #ifdef DEBUG
                NSLog(@"[FIFO] Data read from FIFO: %ld bytes", size);
                #endif

                // Consumir só tramas completas e guardar o resto para a leitura
                // seguinte: é isto que mantém a correspondência barra/contentor.
                const uint8_t *cursor = chunk;
                size_t remaining = (size_t)size;
                BOOL haveFrame = NO;

                while (remaining > 0) {
                    size_t take = MIN((size_t)kCavaFrameBytes - partialCount, remaining);
                    memcpy(partial + partialCount, cursor, take);
                    partialCount += take;
                    cursor += take;
                    remaining -= take;

                    if (partialCount == kCavaFrameBytes) {
                        memcpy(frame, partial, kCavaFrameBytes);   // fica a mais recente
                        partialCount = 0;
                        haveFrame = YES;
                    }
                }

                // Limitar as tramas guardadas a ~25 por segundo. O limiar (35 ms)
                // fica entre um e dois períodos de espera (20 ms), portanto o ritmo
                // engata em «uma em cada duas» sem ficar dependente de
                // arredondamentos. O travão está no enfileiramento, e não no
                // desenho, para a fila não crescer ao ritmo a que o cava escreve.
                NSTimeInterval agora = [NSDate timeIntervalSinceReferenceDate];
                if (haveFrame && agora - ultimoEnfileiramento >= 0.035) {
                    ultimoEnfileiramento = agora;

                    if (ocupadas == kCavaFilaMax) {
                        // Cheia. Só acontece com um atraso absurdo, que o
                        // -actualizarAtrasoDoHistograma já limita; deita-se fora
                        // a mais velha, que é a que menos falta faz.
                        cauda = (cauda + 1) % kCavaFilaMax;
                        ocupadas--;
                    }

                    size_t cabeca = (cauda + ocupadas) % kCavaFilaMax;
                    fila[cabeca].instante = agora;
                    memcpy(fila[cabeca].barras, frame, kCavaFrameBytes);
                    ocupadas++;
                }
            }

            // Escoar tudo o que já é devido e desenhar só a última.
            //
            // Desenhar todas seria reproduzi-las aceleradas, e isso acontece de
            // cada vez que o corte de deriva do ZPAirPlayStreamer faz o atraso
            // cair vários segundos de uma vez: nesse instante a fila inteira
            // fica vencida. Saltar para a mais recente é o comportamento certo —
            // o mesmo que o áudio faz, que também salta.
            const double atraso = atomic_load(&gAtrasoDoHistograma);
            NSTimeInterval agora = [NSDate timeIntervalSinceReferenceDate];
            const ZPTramaCava *aDesenhar = NULL;

            while (ocupadas > 0 && (agora - fila[cauda].instante) >= atraso) {
                aDesenhar = &fila[cauda];
                cauda = (cauda + 1) % kCavaFilaMax;
                ocupadas--;
            }

            if (aDesenhar) {
                NSMutableArray<NSNumber *> *parsedLeftValues = [NSMutableArray arrayWithCapacity:kCavaBarsPerChannel];
                NSMutableArray<NSNumber *> *parsedRightValues = [NSMutableArray arrayWithCapacity:kCavaBarsPerChannel];

                for (NSUInteger i = 0; i < kCavaBarsPerChannel; i++) {
                    [parsedLeftValues addObject:@((aDesenhar->barras[i] * 1000) / 65535)];
                }
                for (NSUInteger i = kCavaBarsPerChannel; i < kCavaBars; i++) {
                    [parsedRightValues addObject:@((aDesenhar->barras[i] * 1000) / 65535)];
                }

                // As barras são CAShapeLayers: basta actualizar os paths. Forçar aqui um
                // -setNeedsDisplay:/-displayIfNeeded redesenhava a view inteira 20 vezes
                // por segundo só para repintar um fundo que nunca muda.
                [(HistogramView *)self.histogramView updateHistogramWithLeftChannel:parsedLeftValues
                                                                       rightChannel:parsedRightValues];
                ultimoDesenho = agora;
                vazioDesenhado = NO;

            } else if (!vazioDesenhado && ultimoDesenho > 0 &&
                       agora - ultimoDesenho >= kCavaEsperaAteApagar) {
                // Não há nada para mostrar há mais de um quinto de segundo. Em
                // regime chega uma trama a cada 40 ms, portanto isto só acontece
                // quando o atraso acabou de crescer — ao ligar o AirPlay — e a
                // fila ainda está a encher.
                //
                // Deixar a última trama à vista durante esse tempo era mostrar o
                // passado a fingir que era o presente. Apagam-se as colunas e
                // espera-se: uma barra de altura zero não desenha nada, e o
                // ecrã vazio diz a verdade — ainda não há som que corresponda ao
                // que se está a ouvir.
                [(HistogramView *)self.histogramView updateHistogramWithLeftChannel:vazioEsquerdo
                                                                       rightChannel:vazioDireito];
                vazioDesenhado = YES;
            }

            if (esperaLonga) {
                [NSThread sleepForTimeInterval:0.1];
            } else if (!leuAlgo) {
                // Este intervalo não pode ser igual ao do debounce: com os dois a
                // 50 ms entravam em batimento, e de vez em quando a trama chegava
                // uns microssegundos cedo de mais, era descartada, e a imagem
                // ficava parada 100 ms. A 20 ms acordamos a meio do passo de
                // 40 ms, portanto nenhuma actualização se perde por arredondamento.
                [NSThread sleepForTimeInterval:0.02];
            }
        }}

        free(fila);

        close(fileDescriptor);
    });
}

#pragma mark - Show button selection with colors

// Give visual feedback for when repeat is active
- (void)updateRepeatButtonAppearance:(BOOL)isActive {
    ZPPintaBotaoDeTransporte(self.repeatButton, isActive ? [NSColor systemGreenColor] : nil);
}

// Give visual feedback for when repeat is active
- (void)updateShuffleButtonAppearance:(BOOL)isActive {
    ZPPintaBotaoDeTransporte(self.shuffleButton, isActive ? [NSColor systemGreenColor] : nil);
}

// Give visual feedback for when pause is active
- (void)updatePauseButtonAppearance:(BOOL)isActive {
    ZPPintaBotaoDeTransporte(self.pauseButton, isActive ? [NSColor systemGreenColor] : nil);
}

// Add visual feedback for when recording is active
- (void)updateRecordButtonAppearance:(BOOL)isActive {
    ZPPintaBotaoDeTransporte(self.recordButton, isActive ? [NSColor systemRedColor] : nil);
}

- (void)repeatTracks {
    if (self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(@"No audio files to repeat.");
        #endif
        return;
    }

    // Toggle repeat mode
    self.isRepeatModeActive = !self.isRepeatModeActive;

    // Update the appearance of the repeat button
    [self updateRepeatButtonAppearance:self.isRepeatModeActive];

    if (self.isRepeatModeActive) {
        #ifdef DEBUG
        NSLog(@"Repeat mode activated.");
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"Repeat mode deactivated.");
        #endif
    }

    // Ensure the current track maps to its original counterpart
    #ifdef DEBUG
    NSURL *originalTrackURL = self.shuffledToOriginalMap[self.currentTrackURL] ?: self.currentTrackURL;

    NSLog(@"Current Track URL: %@", self.currentTrackURL);
    NSLog(@"Original Track URL: %@", originalTrackURL);
    #endif

    // Ensure the delegate is set for track completion
    self.audioPlayer.delegate = self;

    // Na última faixa da biblioteca, e só aí, o repetir muda quem vem a seguir:
    // sem ele não vem nada, com ele volta-se ao princípio. Nos outros sítios da
    // lista isto não dá trabalho nenhum — a faixa adiantada continua a ser a
    // mesma e o pedido não faz nada.
    [self prefetchNextTrack];
}

// Audio player delegate method - Handle completion of a track
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (flag) {
        // Não se apaga aqui a informação da faixa que acabou.
        //
        // Apagava-se, e era isto que punha o painel todo preto nas transições:
        // os campos ficavam vazios até a faixa seguinte os reescrever, e num
        // FLAC essa espera é longa porque a capa vem da miniatura, que é
        // assíncrona. Entre duas faixas do mesmo álbum o artista, o álbum e a
        // capa nem sequer mudam — desapareciam e voltavam iguais.
        //
        // Não fica informação velha a sobrar: quem escreve estes campos é o
        // caminho dos metadados da faixa seguinte, e esse escreve-os todos,
        // incluindo pôr a capa a nil quando a faixa não traz nenhuma. O que se
        // ganha é a informação manter-se estável à vista até haver melhor.

        // Move to the next track or repeat the current one
        if (self.isRepeatModeActive) {
            #ifdef DEBUG
            NSLog(@"Repeat mode is active. Replaying the current track.");
            #endif
            // A faixa terminou: a repetição conta como reprodução nova.
            [self resetPlayCountTracking];
            [self playAudio];

            // O rótulo volta a ser preenchido pelo acompanhamento da contagem,
            // quando esta nova reprodução contar.
            [self refreshPlayCountLabel];
        } else {
            #ifdef DEBUG
            NSLog(@"Playing next track.");
            #endif
            [self playNextTrack];  // Play the next track
        }
    } else {
        #ifdef DEBUG
        NSLog(@"Track did not finish successfully.");
        #endif
    }
}

// Há faixa em curso — a tocar ou apenas em pausa — que não deva ser interrompida?
// Serve para distinguir "ligar o aleatório a meio de uma música" de "ligar o
// aleatório com o tocador parado".
- (BOOL)isPlaybackEngaged {
    return playbackState.isPlaying || self.audioPlayer.isPlaying || self.isPlaybackPaused;
}

// Sorteia uma posição da lista baralhada. Todas as faixas têm a mesma
// probabilidade de sair, incluindo a que calhou em primeiro lugar.
- (NSInteger)randomShuffledStartIndex {
    if (self.shuffledTracks.count == 0) {
        return 0;
    }
    return (NSInteger)arc4random_uniform((uint32_t)self.shuffledTracks.count);
}

// Qual é a fila de reprodução em vigor: a baralhada com o aleatório ligado, a
// biblioteca sem ele.
- (NSArray<NSURL *> *)currentPlaybackList {
    return self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
}

// Linha da lista de músicas correspondente à posição actual da fila. A lista
// mostra sempre a biblioteca por ordem alfabética, portanto o índice tem de ser
// traduzido pela faixa, não copiado.
//
// Parece-se com -comboBoxIndexForCurrentTrack mas parte do outro extremo, e é de
// propósito: ali manda o URL carregado, porque quem o chama acabou de reler a
// biblioteca e o índice é que pode ter ficado desactualizado; aqui manda o
// índice, porque quem chama acabou de lhe mexer e o URL é que pode ser o de uma
// reprodução anterior, já parada.
- (NSInteger)comboBoxIndexForPlaybackPosition {
    NSArray<NSURL *> *lista = [self currentPlaybackList];
    if (self.currentTrackIndex < 0 || self.currentTrackIndex >= (NSInteger)lista.count) {
        return 0; // Marcador
    }
    NSUInteger index = [self.audioFiles indexOfObject:lista[self.currentTrackIndex]];
    return (index != NSNotFound) ? (NSInteger)(index + 1) : 0;
}

// Ligar ou desligar o aleatório só muda a ordem por que se hão-de escolher as
// faixas *seguintes*. A que está em curso não é abrangida pela mudança: fica a
// tocar, no mesmo ponto, sem se recarregar.
//
// Recarregá-la — como se fazia, com -playAudio seguido de -setCurrentTime: —
// custava caro e ouvia-se: -playAudio passa por -stopAudio, que deita fora o
// AVAudioPlayer (estalido no corte) e repõe a barra de duração a zero, e só
// depois é que o novo tocador saltava para o ponto guardado, o que redesenhava a
// barra do princípio para a posição de origem. Nos formatos que não passam pelo
// AVAudioPlayer — FLAC, WavPack, Opus — nem sequer havia ponto guardado para
// onde saltar, e a faixa recomeçava do zero. Nada disto era preciso: a lista
// baralhada é uma permutação da biblioteca, tem os mesmos objectos lá dentro, e
// portanto a faixa em curso continua a estar na fila nova — muda-lhe só a
// posição. Basta reapontar o índice para ela. É o que o botão de repetir sempre
// fez, e por isso nunca teve este defeito.
- (void)shuffleTracks {
    if (self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(@"No audio files to shuffle.");
        #endif
        return;
    }

    // Há faixa carregada — a tocar ou em pausa — que a mudança de modo não deva
    // tocar? É isso que distingue «ligar o aleatório a meio de uma música» de
    // «ligar o aleatório com o tocador parado».
    BOOL comFaixaEmCurso = [self isPlaybackEngaged];

    // A faixa a que o índice aponta antes da mudança: em marcha, a que se está a
    // ouvir; parado, a que estava à espera de arrancar. Só com o tocador em
    // marcha é que o URL carregado manda, porque parado pode ter ficado para trás
    // de uma reprodução anterior.
    NSArray<NSURL *> *listaAnterior = [self currentPlaybackList];
    NSURL *faixaAnterior = comFaixaEmCurso ? self.currentTrackURL : nil;
    if (!faixaAnterior && self.currentTrackIndex >= 0 &&
        self.currentTrackIndex < (NSInteger)listaAnterior.count) {
        faixaAnterior = listaAnterior[self.currentTrackIndex];
    }

    self.isShuffleModeActive = !self.isShuffleModeActive;
    [self updateShuffleButtonAppearance:self.isShuffleModeActive];

    if (self.isShuffleModeActive) {
        #ifdef DEBUG
        NSLog(@"Shuffle mode activated.");
        #endif

        // A fila baralha-se de novo de cada vez que o aleatório se liga.
        [self initializeShuffledTrackList];
    } else {
        #ifdef DEBUG
        NSLog(@"Shuffle mode deactivated.");
        #endif
    }

    // Reapontar o índice para a mesma faixa, agora contada na fila nova.
    NSArray<NSURL *> *lista = [self currentPlaybackList];
    NSUInteger posicao = faixaAnterior ? [lista indexOfObject:faixaAnterior] : NSNotFound;

    if (!comFaixaEmCurso && self.isShuffleModeActive) {
        // Ligar o aleatório com o tocador parado: não há faixa em curso a
        // respeitar e a de arranque sorteia-se. Herdar a que lá estivesse fazia
        // com que a primeira música do modo aleatório fosse sempre a primeira da
        // biblioteca — o índice 0 com que a aplicação abre —, com probabilidade
        // de 100 % quando devia ter 1/N como qualquer outra.
        self.currentTrackIndex = [self randomShuffledStartIndex];
    } else if (posicao != NSNotFound) {
        self.currentTrackIndex = (NSInteger)posicao;
    } else if (!comFaixaEmCurso) {
        self.currentTrackIndex = 0;
    }
    // Faixa em curso que não esteja na fila nova não devia acontecer — as duas
    // listas têm os mesmos ficheiros —, mas se acontecer o índice fica como
    // estava: mais vale a faixa seguinte sair trocada do que interromper esta.

    // A linha seleccionada na lista de músicas não muda de faixa, só de índice de
    // origem, portanto isto costuma ser um não-evento; deixá-la no marcador, como
    // se fazia ao ligar o aleatório, é que dava pela mudança.
    [self.songComboBox selectItemAtIndex:[self comboBoxIndexForPlaybackPosition]];

    // O que muda mesmo é a faixa seguinte: a que estava adiantada em memória já
    // não é a que vem a seguir nesta fila.
    [self prefetchNextTrack];
}

// Initialize and shuffle the track list
- (void)initializeShuffledTrackList {
    #ifdef DEBUG
    NSLog(@"Initializing and shuffling the track list.");
    #endif

    // Create a mutable copy of audioFiles
    self.shuffledTracks = [self.audioFiles mutableCopy];

    // Shuffle the array
    [self shuffleArray:self.shuffledTracks];

    // Initialize the map between shuffled tracks and original tracks
    self.shuffledToOriginalMap = [NSMutableDictionary dictionary];
    for (NSURL *trackURL in self.shuffledTracks) {
        // Since we're shuffling the same objects, the mapping can be direct
        self.shuffledToOriginalMap[trackURL] = trackURL;
    }
}

// Helper method to shuffle an array
- (void)shuffleArray:(NSMutableArray *)array {
    for (NSUInteger i = array.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [array exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
}

#pragma mark - Vigilância da pasta de músicas

// Extensões que a biblioteca reconhece. Partilhado entre o filtro do FSEvents e
// -loadAudioFiles, para que os dois não possam divergir.
static NSSet<NSString *> *ZPSupportedAudioExtensions(void) {
    static NSSet<NSString *> *extensions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithObjects:@"mp3", @"m4a", @"wav", @"aac", @"flac", @"wv", @"opus", @"aiff", nil];
    });
    return extensions;
}

// Callback do FSEvents: chamado na fila principal (ver -startWatchingSongsDirectory).
// Só as alterações que possam mexer na *lista* de faixas é que forçam uma releitura.
// Reler a árvore custa centenas de milissegundos de thread principal, portanto vale
// a pena olhar bem para os eventos antes de o fazer: um script a escrever um ficheiro
// de somas MD5 dentro da pasta, artwork, .DS_Store ou logs não mudam nada para nós.
static void ZPSongsDirectoryEventsCallback(ConstFSEventStreamRef streamRef,
                                           void *clientCallBackInfo,
                                           size_t numEvents,
                                           void *eventPaths,
                                           const FSEventStreamEventFlags eventFlags[],
                                           const FSEventStreamEventId eventIds[]) {
    ViewController *controller = (__bridge ViewController *)clientCallBackInfo;
    if (!controller || numEvents == 0) {
        return;
    }

    NSArray<NSString *> *paths = (__bridge NSArray<NSString *> *)eventPaths;
    NSSet<NSString *> *audioExtensions = ZPSupportedAudioExtensions();

    // Estas obrigam a reler sem sequer olhar para os caminhos: perdemos eventos, a
    // raiz mudou de sítio, ou o volume foi montado/desmontado.
    const FSEventStreamEventFlags mustReloadFlags = kFSEventStreamEventFlagMustScanSubDirs |
                                                    kFSEventStreamEventFlagRootChanged |
                                                    kFSEventStreamEventFlagMount |
                                                    kFSEventStreamEventFlagUnmount |
                                                    kFSEventStreamEventFlagUserDropped |
                                                    kFSEventStreamEventFlagKernelDropped;

    // Só estas mexem na lista. Escrever dentro de um ficheiro que já existe, ou
    // mudar-lhe metadados, atributos estendidos ou dono, deixa a lista igual.
    const FSEventStreamEventFlags listChangingFlags = kFSEventStreamEventFlagItemCreated |
                                                      kFSEventStreamEventFlagItemRemoved |
                                                      kFSEventStreamEventFlagItemRenamed;

    BOOL affectsLibrary = NO;
    for (size_t i = 0; i < numEvents; i++) {
        FSEventStreamEventFlags flags = eventFlags[i];

        if (flags & mustReloadFlags) {
            affectsLibrary = YES;
            break;
        }
        if (!(flags & listChangingFlags)) {
            continue;
        }

        if (flags & kFSEventStreamEventFlagItemIsDir) {
            // Uma pasta de artista, álbum ou CD apareceu, desapareceu ou mudou de nome.
            affectsLibrary = YES;
            break;
        }
        if (flags & kFSEventStreamEventFlagItemIsFile) {
            NSString *path = (i < paths.count) ? paths[i] : nil;
            if (path && [audioExtensions containsObject:path.pathExtension.lowercaseString]) {
                affectsLibrary = YES;
                break;
            }
        }
    }

    if (!affectsLibrary) {
        #ifdef DEBUG
        NSLog(@"FSEvents: %zu alteração(ões) sem efeito na lista de faixas; ignorada(s).", numEvents);
        #endif
        return;
    }

    #ifdef DEBUG
    NSLog(@"FSEvents: %zu alteração(ões) na pasta de músicas.", numEvents);
    #endif

    controller.audioLibraryNeedsReload = YES;

    // A releitura percorre a árvore toda na thread principal, por isso convém
    // esperar que a cópia (ou a extracção de um CD) assente antes de a fazer.
    // Cada evento adia a leitura; só a última geração agendada é que lê.
    // O adiamento TEM de ser maior do que a latência do FSEventStream (2 s): com
    // 1,5 s, uma cópia demorada — que entrega um lote de eventos de 2 em 2
    // segundos — disparava uma releitura completa a cada lote, em vez de as
    // agrupar todas numa só no fim.
    controller.pendingReloadGeneration = controller.pendingReloadGeneration + 1;
    NSUInteger generation = controller.pendingReloadGeneration;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != controller.pendingReloadGeneration) {
            return;   // chegaram mais alterações entretanto
        }
        [controller loadAudioFiles];
    });
}

// Começa a vigiar a pasta de músicas actual. Se já estiver a vigiar essa mesma
// pasta, não faz nada.
- (void)startWatchingSongsDirectory {
    NSString *directoryPath = [self loadSongsDirectoryPath];
    if (directoryPath.length == 0) {
        return;
    }

    if (self.directoryEventStream && [self.watchedDirectoryPath isEqualToString:directoryPath]) {
        return;
    }

    [self stopWatchingSongsDirectory];

    FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    // kFSEventStreamCreateFlagWatchRoot avisa-nos se a própria pasta for movida,
    // renomeada, ou se o volume for desmontado e voltar a montar.
    // kFSEventStreamCreateFlagFileEvents é o que faz chegar um evento por ficheiro,
    // com as flags kFSEventStreamEventFlagItem*. Sem ela os caminhos entregues são
    // de pastas e as flags de item vêm a zero — o filtro do callback não teria por
    // onde decidir e teríamos de reler a árvore a cada alteração, fosse qual fosse.
    FSEventStreamCreateFlags flags = kFSEventStreamCreateFlagUseCFTypes |
                                     kFSEventStreamCreateFlagNoDefer |
                                     kFSEventStreamCreateFlagWatchRoot |
                                     kFSEventStreamCreateFlagFileEvents;

    FSEventStreamRef stream = FSEventStreamCreate(kCFAllocatorDefault,
                                                  &ZPSongsDirectoryEventsCallback,
                                                  &context,
                                                  (__bridge CFArrayRef)@[directoryPath],
                                                  kFSEventStreamEventIdSinceNow,
                                                  2.0,   // segundos de latência, para agrupar cópias grandes
                                                  flags);
    if (!stream) {
        #ifdef DEBUG
        NSLog(@"Não foi possível criar o FSEventStream para: %@", directoryPath);
        #endif
        return;
    }

    FSEventStreamSetDispatchQueue(stream, dispatch_get_main_queue());

    if (!FSEventStreamStart(stream)) {
        #ifdef DEBUG
        NSLog(@"Não foi possível iniciar o FSEventStream para: %@", directoryPath);
        #endif
        FSEventStreamInvalidate(stream);
        FSEventStreamRelease(stream);
        return;
    }

    self.directoryEventStream = stream;
    self.watchedDirectoryPath = directoryPath;

    #ifdef DEBUG
    NSLog(@"A vigiar alterações em: %@", directoryPath);
    #endif
}

- (void)stopWatchingSongsDirectory {
    if (!self.directoryEventStream) {
        return;
    }

    FSEventStreamStop(self.directoryEventStream);
    FSEventStreamInvalidate(self.directoryEventStream);
    FSEventStreamRelease(self.directoryEventStream);
    self.directoryEventStream = NULL;
    self.watchedDirectoryPath = nil;
}

// Optimized method to load audio files with correct sorting
- (void)loadAudioFiles {
    // Check if we are in playlist mode
    if (self.isPlaylistModeActive) {
        // If a playlist is loaded, do not reload audio files from the directory
        return;
    }

    // Load the directory path from user defaults or use a default path
    NSString *directoryPath = [self loadSongsDirectoryPath];
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Get the attributes of the directory to check for changes
    NSError *attributesError = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:directoryPath error:&attributesError];
    if (attributesError) {
        #ifdef DEBUG
        NSLog(@"Error accessing directory attributes: %@", attributesError.localizedDescription);
        #endif
        return;
    }
    NSDate *modificationDate = attributes[NSFileModificationDate];

    // Só se pode confiar na cache quando todas estas condições se verificam:
    //   - já houve uma leitura completa nesta sessão (a cache lida do disco pode
    //     estar desactualizada em relação a alterações feitas com a app fechada);
    //   - o FSEvents está activo, ou seja, teríamos sido avisados de alterações em
    //     qualquer subpasta — o mtime da raiz sozinho não as detecta;
    //   - não há nenhuma alteração por processar;
    //   - o mtime da raiz continua igual.
    BOOL canTrustCache = self.cachedAudioFiles &&
                         self.hasCompletedInitialScan &&
                         self.directoryEventStream != NULL &&
                         !self.audioLibraryNeedsReload &&
                         [self.directoryModificationDate isEqualToDate:modificationDate];

    if (canTrustCache) {
        self.audioFiles = self.cachedAudioFiles;
        return;
    }

    // Update the cached modification date
    self.directoryModificationDate = modificationDate;
    self.audioLibraryNeedsReload = NO;

    // Define the keys to prefetch
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLNameKey, NSURLPathKey];

    // Enumerate through the directory to find audio files
    NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:directoryURL
                                                   includingPropertiesForKeys:keys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:^BOOL(NSURL *url, NSError *error) {
        #ifdef DEBUG
        NSLog(@"Error loading file: %@", error.localizedDescription);
        #endif
        return YES; // Continue enumerating
    }];

    NSMutableArray<NSURL *> *foundAudioFiles = [NSMutableArray array];
    NSSet<NSString *> *allowedExtensions = ZPSupportedAudioExtensions();

    // Filter and collect audio files
    for (NSURL *fileURL in enumerator) {
        NSDictionary *resourceValues = [fileURL resourceValuesForKeys:keys error:nil];

        // Skip if it's not a regular file
        if (![resourceValues[NSURLIsRegularFileKey] boolValue]) {
            continue;
        }

        NSString *extension = fileURL.pathExtension.lowercaseString;

        // Exclude .m4p files and include supported audio formats
        if (![extension isEqualToString:@"m4p"] && [allowedExtensions containsObject:extension]) {
            [foundAudioFiles addObject:fileURL];
        }
    }

    // Ordenar por artista, álbum, número de CD e nome da faixa. As chaves são
    // calculadas uma única vez por ficheiro: dentro do comparador custavam dois
    // -pathComponents e duas extracções de número de CD por comparação, ou seja
    // O(n log n) alocações. Com alguns milhares de faixas isso são segundos de
    // thread principal bloqueada de cada vez que o FSEvents pede uma releitura —
    // e é durante esses segundos que o histograma fica parado.
    NSInteger baseIndex = directoryURL.pathComponents.count;
    NSMutableArray<NSArray *> *decoratedFiles = [NSMutableArray arrayWithCapacity:foundAudioFiles.count];
    for (NSURL *fileURL in foundAudioFiles) {
        NSArray<NSString *> *components = fileURL.pathComponents;
        NSString *artist = (components.count > baseIndex)     ? components[baseIndex]     : @"";
        NSString *album  = (components.count > baseIndex + 1) ? components[baseIndex + 1] : @"";
        NSString *cdDir  = (components.count > baseIndex + 2) ? components[baseIndex + 2] : @"";
        [decoratedFiles addObject:@[fileURL,
                                    artist,
                                    album,
                                    [self extractCDNumberFromString:cdDir],
                                    fileURL.lastPathComponent]];
    }

    [decoratedFiles sortUsingComparator:^NSComparisonResult(NSArray *entry1, NSArray *entry2) {
        NSComparisonResult artistComparison = [entry1[1] compare:entry2[1] options:NSCaseInsensitiveSearch];
        if (artistComparison != NSOrderedSame) {
            return artistComparison;
        }

        NSComparisonResult albumComparison = [entry1[2] compare:entry2[2] options:NSCaseInsensitiveSearch];
        if (albumComparison != NSOrderedSame) {
            return albumComparison;
        }

        NSComparisonResult cdComparison = [entry1[3] compare:entry2[3] options:NSNumericSearch];
        if (cdComparison != NSOrderedSame) {
            return cdComparison;
        }

        return [entry1[4] compare:entry2[4] options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];

    NSMutableArray<NSURL *> *sortedFiles = [NSMutableArray arrayWithCapacity:decoratedFiles.count];
    for (NSArray *entry in decoratedFiles) {
        [sortedFiles addObject:entry[0]];
    }
    NSArray<NSURL *> *sortedAudioFiles = sortedFiles;

    // Preserve the current track URL
    NSURL *currentTrackURL = nil;
    if (self.currentTrackIndex >= 0) {
        if (self.isShuffleModeActive && self.shuffledTracks.count > self.currentTrackIndex) {
            currentTrackURL = self.shuffledTracks[self.currentTrackIndex];
        } else if (self.audioFiles.count > self.currentTrackIndex) {
            currentTrackURL = self.audioFiles[self.currentTrackIndex];
        }
    }

    // Guardar sempre a cache, mesmo quando a lista não mudou: assim a data gravada
    // em disco acompanha a da pasta e não fica a divergir da que está em memória.
    BOOL fileListChanged = ![self.cachedAudioFiles isEqualToArray:sortedAudioFiles];
    self.cachedAudioFiles = sortedAudioFiles;
    self.audioFiles = sortedAudioFiles;
    self.hasCompletedInitialScan = YES;
    [self saveAudioFilesCache];

    // Refresh the UI only if there are changes
    if (fileListChanged) {
        // Recreate shuffled tracks if shuffle mode is active
        if (self.isShuffleModeActive) {
            [self initializeShuffledTrackList]; // Ensure this method is up to date
        }

        // Update the current track index
        BOOL currentTrackExists = NO;
        if (currentTrackURL) {
            NSString *currentTrackPath = [currentTrackURL.path stringByStandardizingPath];
            NSArray<NSURL *> *searchArray = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
            NSUInteger newIndex = NSNotFound;

            for (NSUInteger i = 0; i < searchArray.count; i++) {
                NSURL *trackURL = searchArray[i];
                NSString *trackPath = [trackURL.path stringByStandardizingPath];
                if ([currentTrackPath isEqualToString:trackPath]) {
                    newIndex = i;
                    break;
                }
            }

            if (newIndex != NSNotFound) {
                self.currentTrackIndex = newIndex;
                currentTrackExists = YES;
            } else {
                // Current track is no longer in the list
                self.currentTrackIndex = 0; // Start from the first song
                currentTrackExists = NO;
            }
        } else {
            // No current track, reset index to 0
            self.currentTrackIndex = 0;
        }

        #ifdef DEBUG
        NSLog(@"Loaded %lu audio files from directory: %@", (unsigned long)self.audioFiles.count, directoryPath);
        #endif

        // Refresh the combo box and update selection
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createComboBox];

            if (currentTrackExists) {
                [self.songComboBox selectItemAtIndex:[self comboBoxIndexForCurrentTrack]];
            } else {
                [self.songComboBox selectItemAtIndex:0]; // Select placeholder
                // Stop playback since the current track was removed
                //[self stopAudio];
            }

            // A biblioteca mudou: a faixa que estava adiantada pode já não ser a
            // vizinha da actual, ou pode nem existir. Se continuar a ser, o
            // pedido não faz nada e a leitura já feita aproveita-se.
            [self prefetchNextTrack];
        });
    }
}

// Helper method to extract CD number from directory name
- (NSString *)extractCDNumberFromString:(NSString *)cdString {
    if (cdString.length == 0) {
        // No CD directory, assign a CD number of "0" to sort these tracks first
        return @"0";
    }

    // Compilar a expressão uma única vez: este método é chamado uma vez por pasta
    // de CD durante a leitura da biblioteca, e compilar a regex de cada vez era
    // uma das partes mais caras da releitura.
    static NSRegularExpression *regex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"^CD\\s*(\\d+)$" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:cdString options:0 range:NSMakeRange(0, cdString.length)];

    if (match && match.numberOfRanges >= 2) {
        NSRange numberRange = [match rangeAtIndex:1];
        NSString *numberString = [cdString substringWithRange:numberRange];
        return numberString;
    }
    // If no CD number is found, assign a high number to sort such directories last
    return @"999";
}

// Existing method for WavPack playback
- (void)handleWavPackPlayback:(NSURL *)trackURL {
    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    #ifdef DEBUG
    NSLog(@"Playing WAVPack file using AudioQueue and libwavpack.");
    #endif
    
    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }

    // Clear current metadata before handling WAVPack metadata
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.artistLabel setStringValue:@""];
        [self.albumLabel setStringValue:@""];
        [self.titleLabel setStringValue:@""];
    });

    // Extract metadata and update UI elements
    [self extractAndDisplayMetadataForWavPack:trackURL];
    [self playWavPack:trackURL];  // Start WavPack playback

    // Extract metadata for notification
    // Create a dispatch block for getting the artist, album, and title
    dispatch_block_t retrieveTrackInfo = ^{
        NSString *artist = self.artistLabel.stringValue;
        NSString *album = self.albumLabel.stringValue;
        NSString *title = self.titleLabel.stringValue;
        
        // Process the retrieved values as needed
        #ifdef DEBUG
        NSLog(@"Artist: %@, Album: %@, Title: %@", artist, album, title);
        #endif
        
        // Trigger the Now Playing notification with the retrieved values
        [self triggerNowPlayingNotificationWithTitle:title artist:artist album:album];
    };

    // Dispatch the block to the main thread to access the UI elements and trigger the notification
    dispatch_async(dispatch_get_main_queue(), retrieveTrackInfo);
}

- (void)handleFlacPlayback:(NSURL *)trackURL {
    #ifdef DEBUG
    NSLog(@"Playing FLAC file using AVAudioPlayer.");
    #endif

    // Aqui também não se apaga nada — ver a nota em
    // -audioPlayerDidFinishPlaying:. Este era o segundo apagão da mesma
    // transição: um ao acabar a faixa, outro ao começar a seguinte.


    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }
    
    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }
    
    // Initialize the audio player with the FLAC file, using prefetched data if available
    NSError *error = nil;
    NSData *dataToUse = [self takePrefetchedDataForTrack:trackURL];

    if (dataToUse) {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:dataToUse error:&error];
    } else {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:trackURL error:&error];
    }

    if (error) {
        #ifdef DEBUG
        NSLog(@"Error initializing audio player: %@", error.localizedDescription);
        #endif
        return;
    }

    // Set the delegate to self to handle playback completion
    self.audioPlayer.delegate = self;

    // Procura de silêncios longos nesta faixa
    [self beginSilenceAnalysisForTrack:trackURL];

    // Start playback
    [self.audioPlayer play];

    // Define a block for starting progress bar updates
    dispatch_block_t startProgressBarUpdatesBlock = ^{
        [self startProgressBarUpdates];
    };
    // Dispatch to the main queue
    dispatch_async(dispatch_get_main_queue(), startProgressBarUpdatesBlock);

    // Define a block for extracting and displaying metadata using libFLAC
    dispatch_block_t extractMetadataBlock = ^{
        [self extractAndDisplayFlacMetadataWithLibFLAC:trackURL];
    };
    // Dispatch to the main queue
    dispatch_async(dispatch_get_main_queue(), extractMetadataBlock);

}

// Standard audio formats (MP3, WAV, etc.) playback and metadata handling
- (void)handleStandardAudioPlayback:(NSURL *)trackURL {
    NSError *error = nil;

    NSData *dataToUse = [self takePrefetchedDataForTrack:trackURL];

    if (dataToUse) {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:dataToUse error:&error];
    } else {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:trackURL error:&error];
    }
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error initializing audio player: %@", error.localizedDescription);
        #endif
        return;
    }

    self.audioPlayer.delegate = self;  // Ensure delegate is set

    // Procura de silêncios longos nesta faixa
    [self beginSilenceAnalysisForTrack:trackURL];

    [self.audioPlayer play];
    #ifdef DEBUG
    NSLog(@"Playing track: %@", trackURL.lastPathComponent);
    #endif
    [self startProgressBarUpdates];  // Update progress bar
    [self extractAndDisplayMetadataFromURL:trackURL];  // Extract and display metadata
    self.replayGainValue = 0.0f;
    self.replayGainPeak  = 0.0f;
    self.replayGainAlbumValue = 0.0f;
    self.replayGainAlbumPeak  = 0.0f;
}

// Start updating the progress bar every second
// Method to start progress bar updates
- (void)startProgressBarUpdates {
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
    }

    self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                target:self
                                                              selector:@selector(updateProgressBar)
                                                              userInfo:nil
                                                               repeats:YES];
}

// Update the progress bar based on the current playback time
- (void)updateProgressBar {
    // Handle AVAudioPlayer progress
    if (self.audioPlayer) {
        double currentTime = self.audioPlayer.currentTime;
        double duration = self.audioPlayer.duration;

        if (duration > 0) {
            double progress = (currentTime / duration) * 100;

            // Execute the block on the main queue to ensure UI update happens on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.progressBar setDoubleValue:progress];
            });
        }
    }

    // Handle Opus file progress
    if (playbackState.opusFile && playbackState.isPlaying) {
        // Get the current position in the file
        int64_t currentSample = op_pcm_tell(playbackState.opusFile);
        double currentTime = (double)currentSample / 48000.0;  // Convert current sample to seconds

        // Calculate the progress percentage
        double progress = (currentTime / playbackState.totalDuration) * 100.0;

        // Update the progress bar on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressBar setDoubleValue:progress];
        });
    }

    // Handle WAVPack file progress
    if (playbackState.wpc && playbackState.isPlaying) {
        [self updateProgressBarForWavPack];
    }

    // Verifica se estamos dentro de um silêncio longo e, se for o caso, salta-o
    [self checkForSilenceAndSkip];
}

#pragma mark - Salto automático de silêncios longos

// Arranca, em segundo plano, a análise da faixa à procura de silêncios com mais de
// kZPSilenceMinimumGapDuration segundos. O resultado fica em self.silenceGaps e é
// consumido por -checkForSilenceAndSkip a partir dos temporizadores de progresso.
// Pode ser chamado de qualquer thread (o modo de repetição chama-o do callback áudio).
- (void)beginSilenceAnalysisForTrack:(NSURL *)trackURL {
    // Invalida qualquer análise anterior ainda em curso
    uint64_t generation = atomic_fetch_add(&gSilenceAnalysisGeneration, 1) + 1;

    self.silenceGaps = nil;

    // O relógio de salto pertence à faixa que agora arranca
    playbackState.pendingSeekFrame = 0;
    playbackState.skippedFrames = 0.0;

    if (!trackURL.isFileURL) {
        return;
    }

    dispatch_async(ZPSilenceAnalysisQueue(), ^{
        NSArray<NSValue *> *gaps = [self silenceGapsForTrackAtURL:trackURL generation:generation];
        if (gaps.count == 0) {
            return;
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            // A faixa pode ter mudado enquanto a análise decorria
            if (atomic_load(&gSilenceAnalysisGeneration) != generation) {
                return;
            }

            self.silenceGaps = gaps;

            #ifdef DEBUG
            NSLog(@"Silêncios longos detectados em %@: %lu", trackURL.lastPathComponent, (unsigned long)gaps.count);
            for (NSValue *value in gaps) {
                ZPSilenceGap gap;
                [value getValue:&gap size:sizeof(gap)];
                NSLog(@"  %.2f s → %.2f s (%.2f s)", gap.start, gap.end, gap.end - gap.start);
            }
            #endif
        });
    });
}

// Descarta a análise e o estado de salto (usado ao parar a reprodução)
- (void)cancelSilenceAnalysis {
    atomic_fetch_add(&gSilenceAnalysisGeneration, 1);
    self.silenceGaps = nil;
    playbackState.pendingSeekFrame = 0;
    playbackState.skippedFrames = 0.0;
}

// Método chamado pelos temporizadores de progresso: se a reprodução entrou num
// silêncio com mais de 10 segundos, avança directamente para o reinício da música.
- (void)checkForSilenceAndSkip {
    NSArray<NSValue *> *gaps = self.silenceGaps;
    if (gaps.count == 0) {
        return;
    }

    // Um salto anterior ainda não foi aplicado pelo descodificador
    if (playbackState.pendingSeekFrame > 0) {
        return;
    }

    double currentTime = 0.0;
    double duration = 0.0;
    if (![self currentPlaybackTime:&currentTime duration:&duration]) {
        return;
    }

    for (NSValue *value in gaps) {
        ZPSilenceGap gap;
        [value getValue:&gap size:sizeof(gap)];

        // A lista está ordenada: as restantes lacunas ainda estão à frente
        if (gap.start > currentTime) {
            break;
        }

        // Já passámos esta lacuna (ou estamos no seu final)
        if (currentTime >= gap.end - kZPSilenceSkipPreRoll) {
            continue;
        }

        // Se o silêncio se estende até ao fim do ficheiro, o salto leva-nos ao
        // final da faixa e a transição normal para a faixa seguinte encarrega-se
        // do resto.
        double target = MAX(gap.start, gap.end - kZPSilenceSkipPreRoll);
        #ifdef DEBUG
        NSLog(@"Silêncio de %.2f s em %.2f s: a avançar para %.2f s", gap.end - gap.start, currentTime, target);
        #endif
        [self skipSilenceToTime:target duration:duration];
        return;
    }
}

// Posição de reprodução audível e duração total da faixa, para qualquer dos motores
- (BOOL)currentPlaybackTime:(double *)outTime duration:(double *)outDuration {
    // WavPack e Opus: relógio da AudioQueue, corrigido pelas frames já saltadas
    if (playbackState.audioQueue && playbackState.isPlaying &&
        (playbackState.wpc || playbackState.opusFile)) {

        if (playbackState.totalDuration <= 0.0) {
            return NO;
        }

        AudioTimeStamp timeStamp;
        Boolean discontinuity = false;
        OSStatus status = AudioQueueGetCurrentTime(playbackState.audioQueue, NULL, &timeStamp, &discontinuity);
        if (status != noErr || timeStamp.mSampleTime < 0) {
            return NO;
        }

        double sampleRate = playbackState.sampleRate > 0 ? playbackState.sampleRate : 48000.0;
        if (outTime) {
            *outTime = (timeStamp.mSampleTime + playbackState.skippedFrames) / sampleRate;
        }
        if (outDuration) {
            *outDuration = playbackState.totalDuration;
        }
        return YES;
    }

    // FLAC e formatos padrão
    if (self.audioPlayer && self.audioPlayer.duration > 0.0) {
        if (outTime) {
            *outTime = self.audioPlayer.currentTime;
        }
        if (outDuration) {
            *outDuration = self.audioPlayer.duration;
        }
        return YES;
    }

    return NO;
}

// Avança a reprodução para targetTime, respeitando o relógio de cada motor, e
// actualiza imediatamente a barra de progresso.
- (void)skipSilenceToTime:(double)targetTime duration:(double)duration {
    if (duration <= 0.0) {
        return;
    }

    double target = MAX(0.0, MIN(targetTime, duration));

    if (playbackState.audioQueue && (playbackState.wpc || playbackState.opusFile)) {
        // O salto é aplicado no callback do descodificador, na thread onde este
        // corre; libwavpack e libopusfile não podem ser usados a partir daqui.
        double sampleRate = playbackState.sampleRate > 0 ? playbackState.sampleRate : 48000.0;
        int64_t frame = (int64_t)llround(target * sampleRate);
        if (frame <= 0) {
            return;
        }
        playbackState.pendingSeekFrame = frame;
    } else if (self.audioPlayer) {
        BOOL wasPlaying = self.audioPlayer.isPlaying;
        self.audioPlayer.currentTime = target;
        if (wasPlaying && !self.audioPlayer.isPlaying) {
            [self.audioPlayer play];
        }
    } else {
        return;
    }

    double progress = MIN(target / duration, 1.0) * 100.0;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressBar setDoubleValue:progress];
    });
}

#pragma mark - Análise de silêncio por formato

- (NSArray<NSValue *> *)silenceGapsForTrackAtURL:(NSURL *)url generation:(uint64_t)generation {
    NSString *extension = url.pathExtension.lowercaseString;

    if ([extension isEqualToString:@"wv"]) {
        return [self silenceGapsInWavPackFileAtURL:url generation:generation];
    }
    if ([extension isEqualToString:@"opus"]) {
        return [self silenceGapsInOpusFileAtURL:url generation:generation];
    }
    return [self silenceGapsInDecodableFileAtURL:url generation:generation];
}

// FLAC, MP3, WAV, AIFF, AAC… — tudo o que a AVFoundation sabe descodificar
- (NSArray<NSValue *> *)silenceGapsInDecodableFileAtURL:(NSURL *)url generation:(uint64_t)generation {
    NSError *error = nil;
    AVAudioFile *file = [[AVAudioFile alloc] initForReading:url error:&error];
    if (!file) {
        #ifdef DEBUG
        NSLog(@"Análise de silêncio: não foi possível ler %@ (%@)", url.lastPathComponent, error.localizedDescription);
        #endif
        return nil;
    }

    AVAudioFormat *format = file.processingFormat;
    double sampleRate = format.sampleRate;
    AVAudioChannelCount channels = format.channelCount;
    if (sampleRate <= 0.0 || channels == 0) {
        return nil;
    }

    AVAudioFrameCount blockFrames = (AVAudioFrameCount)MAX(1.0, round(sampleRate * kZPSilenceAnalysisBlockDuration));
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:blockFrames * 20];
    if (!buffer) {
        return nil;
    }

    BOOL interleaved = format.isInterleaved;
    NSMutableArray<NSValue *> *gaps = [NSMutableArray array];
    int64_t silenceStartFrame = -1;
    int64_t frameIndex = 0;

    while (atomic_load(&gSilenceAnalysisGeneration) == generation) {
        if (![file readIntoBuffer:buffer error:&error]) {
            #ifdef DEBUG
            NSLog(@"Análise de silêncio interrompida em %@: %@", url.lastPathComponent, error.localizedDescription);
            #endif
            break;
        }

        AVAudioFrameCount available = buffer.frameLength;
        if (available == 0) {
            break;
        }

        float * const *channelData = buffer.floatChannelData;
        if (!channelData) {
            return nil;
        }

        for (AVAudioFrameCount offset = 0; offset < available; offset += blockFrames) {
            AVAudioFrameCount count = MIN(blockFrames, available - offset);
            double sum = 0.0;

            if (interleaved) {
                const float *samples = channelData[0] + (size_t)offset * channels;
                for (AVAudioFrameCount i = 0; i < count * channels; i++) {
                    sum += (double)samples[i] * (double)samples[i];
                }
            } else {
                for (AVAudioChannelCount channel = 0; channel < channels; channel++) {
                    const float *samples = channelData[channel] + offset;
                    for (AVAudioFrameCount i = 0; i < count; i++) {
                        sum += (double)samples[i] * (double)samples[i];
                    }
                }
            }

            double rms = sqrt(sum / (double)((size_t)count * channels));
            ZPSilenceAccumulate(rms < kZPSilenceThreshold, frameIndex + offset, sampleRate, &silenceStartFrame, gaps);
        }

        frameIndex += available;
    }

    if (atomic_load(&gSilenceAnalysisGeneration) != generation) {
        return nil;
    }

    // Fecha um eventual silêncio final
    ZPSilenceAccumulate(NO, frameIndex, sampleRate, &silenceStartFrame, gaps);
    return gaps;
}

- (NSArray<NSValue *> *)silenceGapsInWavPackFileAtURL:(NSURL *)url generation:(uint64_t)generation {
    char error[80] = {0};
    WavpackContext *context = WavpackOpenFileInput([url.path UTF8String], error, 0, 0);
    if (!context) {
        #ifdef DEBUG
        NSLog(@"Análise de silêncio: não foi possível abrir %@ (%s)", url.lastPathComponent, error);
        #endif
        return nil;
    }

    int numChannels = WavpackGetNumChannels(context);
    int bitsPerSample = WavpackGetBitsPerSample(context);
    double sampleRate = WavpackGetSampleRate(context);
    BOOL isFloat = (WavpackGetMode(context) & MODE_FLOAT) != 0;

    if (numChannels <= 0 || sampleRate <= 0.0 || bitsPerSample <= 0) {
        WavpackCloseFile(context);
        return nil;
    }

    uint32_t blockFrames = (uint32_t)MAX(1.0, round(sampleRate * kZPSilenceAnalysisBlockDuration));
    int32_t *samples = malloc((size_t)blockFrames * (size_t)numChannels * sizeof(int32_t));
    if (!samples) {
        WavpackCloseFile(context);
        return nil;
    }

    double scale = 1.0 / (double)(1LL << (bitsPerSample - 1));
    NSMutableArray<NSValue *> *gaps = [NSMutableArray array];
    int64_t silenceStartFrame = -1;
    int64_t frameIndex = 0;

    while (atomic_load(&gSilenceAnalysisGeneration) == generation) {
        uint32_t decoded = WavpackUnpackSamples(context, samples, blockFrames);
        if (decoded == 0) {
            break;
        }

        size_t total = (size_t)decoded * (size_t)numChannels;
        double sum = 0.0;
        for (size_t i = 0; i < total; i++) {
            double value;
            if (isFloat) {
                float sample;
                memcpy(&sample, &samples[i], sizeof(sample));
                value = (double)sample;
            } else {
                value = (double)samples[i] * scale;
            }
            sum += value * value;
        }

        double rms = sqrt(sum / (double)total);
        ZPSilenceAccumulate(rms < kZPSilenceThreshold, frameIndex, sampleRate, &silenceStartFrame, gaps);
        frameIndex += decoded;
    }

    BOOL cancelled = (atomic_load(&gSilenceAnalysisGeneration) != generation);

    free(samples);
    WavpackCloseFile(context);

    if (cancelled) {
        return nil;
    }

    // Fecha um eventual silêncio final
    ZPSilenceAccumulate(NO, frameIndex, sampleRate, &silenceStartFrame, gaps);
    return gaps;
}

- (NSArray<NSValue *> *)silenceGapsInOpusFileAtURL:(NSURL *)url generation:(uint64_t)generation {
    int error = 0;
    OggOpusFile *opusFile = op_open_file([url.path UTF8String], &error);
    if (error != 0 || opusFile == NULL) {
        #ifdef DEBUG
        NSLog(@"Análise de silêncio: não foi possível abrir %@ (%d)", url.lastPathComponent, error);
        #endif
        return nil;
    }

    // O Opus descodifica sempre a 48 kHz; op_read_stereo entrega dois canais.
    const double sampleRate = 48000.0;
    const int numChannels = 2;
    int blockFrames = (int)MAX(1.0, round(sampleRate * kZPSilenceAnalysisBlockDuration));
    int bufferSamples = blockFrames * numChannels;
    int16_t *samples = malloc((size_t)bufferSamples * sizeof(int16_t));
    if (!samples) {
        op_free(opusFile);
        return nil;
    }

    NSMutableArray<NSValue *> *gaps = [NSMutableArray array];
    int64_t silenceStartFrame = -1;
    int64_t frameIndex = 0;

    while (atomic_load(&gSilenceAnalysisGeneration) == generation) {
        // Devolve o número de frames por canal; pode ser menos do que o pedido,
        // o que apenas torna o bloco de análise mais curto.
        int decoded = op_read_stereo(opusFile, samples, bufferSamples);
        if (decoded <= 0) {
            break;
        }

        size_t total = (size_t)decoded * (size_t)numChannels;
        double sum = 0.0;
        for (size_t i = 0; i < total; i++) {
            double value = (double)samples[i] / 32768.0;
            sum += value * value;
        }

        double rms = sqrt(sum / (double)total);
        ZPSilenceAccumulate(rms < kZPSilenceThreshold, frameIndex, sampleRate, &silenceStartFrame, gaps);
        frameIndex += decoded;
    }

    BOOL cancelled = (atomic_load(&gSilenceAnalysisGeneration) != generation);

    free(samples);
    op_free(opusFile);

    if (cancelled) {
        return nil;
    }

    // Fecha um eventual silêncio final
    ZPSilenceAccumulate(NO, frameIndex, sampleRate, &silenceStartFrame, gaps);
    return gaps;
}

// Os botões ⏮️ e ⏭️ andam pela fila que estiver em vigor — a baralhada com o
// aleatório ligado, a biblioteca sem ele. Andarem sempre por -audioFiles, como
// faziam, dava um tocador de duas cabeças: com o aleatório ligado, o fim de uma
// música seguia a baralhada mas os botões seguiam a ordem alfabética, e recuar
// logo a seguir a avançar podia nem sequer voltar à faixa de onde se tinha
// vindo.
- (void)backwardTrack {
    NSArray<NSURL *> *lista = [self currentPlaybackList];
    if (lista.count == 0) {
        return;
    }

    // Clean up current playback before switching to a new track
    [self stopAudio];

    // Move to the previous track (loop back if at the first track)
    self.currentTrackIndex = (self.currentTrackIndex <= 0) ? (NSInteger)lista.count - 1
                                                           : self.currentTrackIndex - 1;

    // Reset the progress bar to zero
    [self.progressBar setDoubleValue:0];

    // Play the new track
    [self playAudio];
}

- (void)forwardTrack {
    NSArray<NSURL *> *lista = [self currentPlaybackList];
    if (lista.count == 0) {
        return;
    }

    // Clean up current playback before switching to a new track
    [self stopAudio];

    // Move to the next track (loop to the first track if at the last track).
    // Índice fora da lista conta como «antes da primeira», para o ⏭️ dar a
    // primeira faixa em vez de a segunda.
    NSInteger actual = self.currentTrackIndex;
    if (actual < 0 || actual >= (NSInteger)lista.count) {
        actual = -1;
    }
    self.currentTrackIndex = (actual + 1) % (NSInteger)lista.count;

    // Reset the progress bar to zero
    [self.progressBar setDoubleValue:0];

    // Play the new track
    [self playAudio];
}

// O botão ⏹️. Parar é o fim da audição, não uma transição: além de calar o
// tocador, deita-se fora a faixa adiantada em memória, que são dezenas de MB à
// espera de alguém que já não vem. Tem de ser um método à parte do -stopAudio
// porque este também é o primeiro passo de -playAudio, e aí a ranhura é
// justamente o que a faixa que vai arrancar está prestes a consumir.
- (void)stopButtonPressed {
    [self stopAudio];
    [self discardPrefetchedTrack];
}

// Ensure the timer is invalidated if playback is stopped or a new track is played
- (void)stopAudio {
    // Descartar a análise de silêncios da faixa que estava a tocar
    [self cancelSilenceAnalysis];

    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    // Stop and clean up the WAVPack playback state
    if (playbackState.audioQueue) {
        AudioQueueStop(playbackState.audioQueue, true);  // Stop AudioQueue
        playbackState.isPlaying = NO;

        for (int i = 0; i < NUM_BUFFERS; i++) {
            if (playbackState.buffers[i]) {
                AudioQueueFreeBuffer(playbackState.audioQueue, playbackState.buffers[i]);  // Free buffers
                playbackState.buffers[i] = NULL;
            }
        }
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose of the audio queue
        playbackState.audioQueue = NULL;
    }

    // Clean up Opus playback state
    if (playbackState.opusFile) {
        // Free Opus resources
        op_free(playbackState.opusFile);
        playbackState.opusFile = NULL;
    }

    // Stop the AVAudioPlayer if it's playing
    if (self.audioPlayer) {
        [self.audioPlayer stop];  // Stop the AVAudioPlayer
        self.audioPlayer = nil;   // Clear the audio player
    }

    // Reset the progress bar
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressBar setDoubleValue:0.0];
    });

    // Suspender — e não descartar — o acompanhamento da contagem. -playAudio chama
    // -stopAudio antes de arrancar, incluindo quando se carrega em Play para
    // retomar a mesma faixa; se aqui se esquecesse a faixa acompanhada, essa retoma
    // parecia uma reprodução nova e voltava a contar.
    [self suspendPlayCountTracking];

    // O rótulo acompanha esse estado: a faixa continua carregada, por isso a
    // contagem que já estivesse visível mantém-se.
    [self refreshPlayCountLabel];

    // Parar não é pausar: a selecção verde do botão de pausa tem de sair.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.isPlaybackPaused = NO;
        [self updatePauseButtonAppearance:NO];
    });
}

// Also update `pauseAudio` to manage the timer appropriately
- (void)pauseAudio {
    if (playbackState.isPlaying) {
        // Handle WAVPack AudioQueue pause
        if (playbackState.audioQueue && playbackState.wpc) {
            AudioQueuePause(playbackState.audioQueue); // Pause the AudioQueue
            playbackState.isPlaying = NO;

            // Invalidate the progress update timer
            if (self.progressUpdateTimer) {
                [self.progressUpdateTimer invalidate];
                self.progressUpdateTimer = nil;
            }
            #ifdef DEBUG
            NSLog(@"WAVPack audio paused.");
            #endif
        }

        // Handle Opus AudioQueue pause
        if (playbackState.opusFile && playbackState.audioQueue) {
            AudioQueuePause(playbackState.audioQueue); // Pause the Opus AudioQueue
            playbackState.isPlaying = NO;
            
            // Invalidate the progress update timer
            if (self.progressUpdateTimer) {
                [self.progressUpdateTimer invalidate];
                self.progressUpdateTimer = nil;
            }
            #ifdef DEBUG
            NSLog(@"Opus audio paused.");
            #endif
        }

        // Suspender a contagem: o prazo conta audição, não tempo de relógio.
        [self suspendPlayCountTracking];

        // Update button appearance to indicate it's paused
        self.isPlaybackPaused = YES;
        [self updatePauseButtonAppearance:YES];

    } else if (self.audioPlayer.isPlaying) {
        // Handle AVAudioPlayer pause
        [self.audioPlayer pause];

        // Suspender a contagem enquanto está em pausa
        [self suspendPlayCountTracking];

        // Invalidate the progress update timer
        if (self.progressUpdateTimer) {
            [self.progressUpdateTimer invalidate];
            self.progressUpdateTimer = nil;
        }
        #ifdef DEBUG
        NSLog(@"AudioPlayer paused.");
        #endif
        // Update button appearance to indicate it's paused
        self.isPlaybackPaused = YES;
        [self updatePauseButtonAppearance:YES];

    } else {
        // Já estava em pausa: o próprio botão ⏸️ retoma.
        [self resumePlayback];
    }
}

// O botão ▶️. Se a reprodução está apenas em pausa, retoma no ponto onde ficou —
// tal como o botão ⏸️ — em vez de recomeçar a faixa; caso contrário arranca a
// faixa seleccionada. Em qualquer dos casos a selecção verde do botão de pausa
// sai, porque em nenhum deles se fica em pausa.
- (void)playButtonPressed {
    if (self.isPlaybackPaused) {
        [self resumePlayback];
    } else {
        [self playAudio];
    }
}

// Retoma a reprodução suspensa, no formato que estiver carregado. Devolve NO se
// não houver nada para retomar (nesse caso a pausa deixa de fazer sentido e a
// selecção do botão sai à mesma).
- (BOOL)resumePlayback {
    BOOL resumed = NO;

    // Resume playback for WAVPack
    if (playbackState.wpc && playbackState.audioQueue) {
        AudioQueueStart(playbackState.audioQueue, NULL); // Resume the AudioQueue
        playbackState.isPlaying = YES;

        // Restart the progress update timer
        self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                    target:self
                                                                  selector:@selector(updateProgressBar)
                                                                  userInfo:nil
                                                                   repeats:YES];
        #ifdef DEBUG
        NSLog(@"WAVPack audio resumed.");
        #endif
        resumed = YES;

    } else if (playbackState.opusFile && playbackState.audioQueue) {
        // Resume playback for Opus
        AudioQueueStart(playbackState.audioQueue, NULL); // Resume the Opus AudioQueue
        playbackState.isPlaying = YES;

        // Restart the progress update timer
        self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                    target:self
                                                                  selector:@selector(updateProgressBar)
                                                                  userInfo:nil
                                                                   repeats:YES];
        #ifdef DEBUG
        NSLog(@"Opus audio resumed.");
        #endif
        resumed = YES;

    } else if (self.audioPlayer) {
        // Resume AVAudioPlayer playback
        [self.audioPlayer play];

        // Restart the progress update timer
        self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                    target:self
                                                                  selector:@selector(updateProgressBar)
                                                                  userInfo:nil
                                                                   repeats:YES];
        #ifdef DEBUG
        NSLog(@"AudioPlayer resumed.");
        #endif
        resumed = YES;
    }

    if (resumed) {
        // Retomar a contagem com o tempo que faltava, sem voltar a contar
        [self resumePlayCountTracking];

        // A contagem já feita continua visível; a que faltava retoma o prazo.
        [self refreshPlayCountLabel];
    }

    // Quer se tenha retomado, quer não houvesse nada para retomar, já não se está
    // em pausa: desligar a selecção verde do botão.
    self.isPlaybackPaused = NO;
    [self updatePauseButtonAppearance:NO];

    return resumed;
}

- (void)extractAndDisplayMetadataFromURL:(NSURL *)url {
    NSString *extension = url.pathExtension.lowercaseString;

    // Este pedido passa a ser o mais recente; qualquer um anterior que ainda
    // venha a terminar fica com a geração desactualizada e cala-se.
    const uint64_t geracao = atomic_fetch_add(&gMetadataGeneration, 1) + 1;

    // Define a block to extract and display metadata for FLAC files
    dispatch_block_t flacMetadataBlock = ^{
        [self extractAndDisplayFlacMetadataWithLibFLAC:url];
    };

    // Define a block to extract and display metadata for WavPack files
    dispatch_block_t wavPackMetadataBlock = ^{
        [self extractAndDisplayMetadataForWavPack:url];
    };

    // Define a block to handle other formats and metadata extraction (macOS 15+ only)
    dispatch_block_t otherFormatsMetadataBlock = ^{
        AVAsset *asset = [AVAsset assetWithURL:url];

        // Load base properties before reading asset.metadata/commonMetadata
        [asset loadValuesAsynchronouslyForKeys:@[@"metadata", @"commonMetadata"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                // O guarda fica aqui, à cabeça, e não só à volta da escrita das
                // etiquetas: deste bloco sai também o ReplayGain da faixa, e
                // aplicar o ganho da faixa anterior ouve-se.
                if (atomic_load(&gMetadataGeneration) != geracao) {
                    #ifdef DEBUG
                    NSLog(@"[Metadados] Chegaram tarde os de %@ (geração %llu, actual %llu); ignorados.",
                          url.lastPathComponent, geracao, atomic_load(&gMetadataGeneration));
                    #endif
                    return;
                }

                NSError *error = nil;
                AVKeyValueStatus metadataStatus = [asset statusOfValueForKey:@"metadata" error:&error];
                if (metadataStatus != AVKeyValueStatusLoaded || error) {
                    #ifdef DEBUG
                    NSLog(@"[ReplayGain] Failed to load metadata for asset. Error: %@", error.localizedDescription);
                    #endif
                    return;
                }

                #ifdef DEBUG
                NSLog(@"[ReplayGain] Full metadata dump for asset at URL: %@", url);

                NSLog(@"[ReplayGain] Common Metadata:");
                for (AVMetadataItem *metadataItem in asset.commonMetadata) {
                    NSLog(@"[ReplayGain] [CommonMetadata] Key: %@, Value: %@, KeySpace: %@, CommonKey: %@",
                          metadataItem.key,
                          metadataItem.value,
                          metadataItem.keySpace,
                          metadataItem.commonKey);
                }

                NSLog(@"[ReplayGain] Full Metadata:");
                for (AVMetadataItem *metadataItem in asset.metadata) {
                    NSLog(@"[ReplayGain] [Metadata] Identifier: %@, Key: %@, KeySpace: %@, Value: %@",
                          metadataItem.identifier,
                          metadataItem.key,
                          metadataItem.keySpace,
                          metadataItem.value);
                }
                #endif

                // Defaults
                __block NSString *artist = @"Unknown Artist";
                __block NSString *album = @"Unknown Album";
                __block NSString *title = @"Unknown Title";
                __block NSImage *coverArt = nil;
                __block NSString *trackNumberString = @"0";
                __block float replayGainValue = 0.0f;
                __block float replayGainPeak = 0.0f;
                __block BOOL foundReplayGain = NO;

                // Common metadata → artist/album/title/cover
                for (AVMetadataItem *metadataItem in asset.commonMetadata) {
                    if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyArtist]) {
                        artist = [self replaceSingleQuoteAndSmartQuotes:[self decodeMetadataItem:metadataItem]];
                    } else if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyAlbumName]) {
                        album = [self replaceSingleQuoteAndSmartQuotes:[self decodeMetadataItem:metadataItem]];
                    } else if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyTitle]) {
                        title = [self replaceSingleQuoteAndSmartQuotes:[self decodeMetadataItem:metadataItem]];
                    } else if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyArtwork]) {
                        NSData *imageData = (NSData *)metadataItem.value;
                        coverArt = [[NSImage alloc] initWithData:imageData];
                    }
                }

                // Block to close (track number + UI + notifications)
                void (^finishAndUpdateUI)(void) = ^{
                    for (AVMetadataItem *metadataItem in asset.metadata) {
                        if ([metadataItem.identifier isEqualToString:@"itsk/trkn"]) {
                            NSData *trackNumberData = (NSData *)metadataItem.value;
                            if (trackNumberData.length == 8) {
                                uint32_t trackNumber = 0;
                                [trackNumberData getBytes:&trackNumber range:NSMakeRange(0, 4)];
                                trackNumber = CFSwapInt32BigToHost(trackNumber);
                                trackNumberString = [NSString stringWithFormat:@"%u", trackNumber];
                            }
                        } else if ([metadataItem.identifier isEqualToString:@"id3/TRCK"]) {
                            NSString *trackInfo = (NSString *)metadataItem.value;
                            NSArray<NSString *> *components = [trackInfo componentsSeparatedByString:@"/"];
                            if (components.count > 0) {
                                trackNumberString = components[0];
                                if (trackNumberString.length > 1 && [trackNumberString hasPrefix:@"0"]) {
                                    trackNumberString = [trackNumberString substringFromIndex:1];
                                }
                            }
                        }
                    }

                    NSString *formattedTitle = [NSString stringWithFormat:@"%@. %@", trackNumberString, title];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.artistLabel setStringValue:artist];
                        [self.albumLabel setStringValue:album];
                        [self.titleLabel setStringValue:formattedTitle];
                        [self.coverArtView setImage:coverArt ?: nil];
                    });

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self triggerNowPlayingNotificationWithTitle:formattedTitle artist:artist album:album];
                    });
                };

                // ---------- ReplayGain (iTunes/ID3) on macOS 15+ (new API) ----------
                NSArray *replayGainKeys = @[
                    @"com.apple.iTunes.REPLAYGAIN_TRACK_GAIN",
                    @"org.hydrogenaudio.replaygain.replaygain_track_gain",
                    @"replaygain_track_gain",
                    @"replaygain track gain",
                    @"REPLAYGAIN_TRACK_GAIN"
                ];

                NSArray *replayGainPeakKeys = @[
                    @"com.apple.iTunes.REPLAYGAIN_TRACK_PEAK",
                    @"org.hydrogenaudio.replaygain.replaygain_track_peak",
                    @"replaygain_track_peak",
                    @"replaygain track peak",
                    @"REPLAYGAIN_TRACK_PEAK"
                ];

                // A palha onde se procura o nome da etiqueta, e o texto do
                // valor. Serviam a busca do ganho em código repetido; agora que
                // também se procura o pico, ficam num sítio só.
                NSString * (^palhaDoItem)(AVMetadataItem *) = ^NSString *(AVMetadataItem *item) {
                    NSString *freeName = item.extraAttributes[AVMetadataExtraAttributeInfoKey] ?: @"";
                    NSString *keyStr = [item.key isKindOfClass:NSString.class] ? (NSString *)item.key : @"";
                    return [[@[ (item.identifier ?: @""), freeName, keyStr ]
                              componentsJoinedByString:@"|"] lowercaseString];
                };

                NSString * (^textoDoItem)(AVMetadataItem *) = ^NSString *(AVMetadataItem *item) {
                    NSString *valueString = nil;
                    if ([item.value isKindOfClass:NSString.class]) {
                        valueString = (NSString *)item.value;
                    } else if ([item.value isKindOfClass:NSData.class]) {
                        valueString = [[NSString alloc] initWithData:(NSData *)item.value encoding:NSUTF8StringEncoding];
                    }
                    return [valueString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                };

                dispatch_group_t g = dispatch_group_create();
                __block NSArray<AVMetadataItem *> *iTunesItems = @[];
                __block NSArray<AVMetadataItem *> *id3Items = @[];

                dispatch_group_enter(g);
                [asset loadMetadataForFormat:AVMetadataFormatiTunesMetadata
                          completionHandler:^(NSArray<AVMetadataItem *> * _Nullable items, NSError * _Nullable err) {
                    iTunesItems = items ?: @[];
                    dispatch_group_leave(g);
                }];

                dispatch_group_enter(g);
                [asset loadMetadataForFormat:AVMetadataFormatID3Metadata
                          completionHandler:^(NSArray<AVMetadataItem *> * _Nullable items, NSError * _Nullable err) {
                    id3Items = items ?: @[];
                    dispatch_group_leave(g);
                }];

                dispatch_group_notify(g, dispatch_get_main_queue(), ^{
                    // ---- Pico, procurado primeiro para já estar à mão quando
                    // o ganho for encontrado e empurrado para o streamer ----
                    for (AVMetadataItem *metadataItem in [iTunesItems arrayByAddingObjectsFromArray:id3Items]) {
                        NSString *hay = palhaDoItem(metadataItem);
                        BOOL match = NO;
                        for (NSString *k in replayGainPeakKeys) {
                            if ([hay containsString:k.lowercaseString]) { match = YES; break; }
                        }
                        if (!match) continue;

                        NSString *valueString = textoDoItem(metadataItem);
                        if (!valueString.length) continue;

                        replayGainPeak = [valueString floatValue];
                        self.replayGainPeak = replayGainPeak;
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] AAC/ALAC/MP3 track peak: %f", replayGainPeak);
                        #endif
                        break;
                    }

                    // ---- Ganho e pico de álbum ----
                    NSArray *paresAlbum = @[ @[@"replaygain_album_gain", @"g"], @[@"replaygain_album_peak", @"p"] ];
                    for (NSArray *par in paresAlbum) {
                        for (AVMetadataItem *metadataItem in [iTunesItems arrayByAddingObjectsFromArray:id3Items]) {
                            if (![palhaDoItem(metadataItem) containsString:par[0]]) continue;
                            NSString *valueString = textoDoItem(metadataItem);
                            if (!valueString.length) continue;
                            NSRange dbRange = [valueString rangeOfString:@" dB" options:NSCaseInsensitiveSearch];
                            if (dbRange.location != NSNotFound) valueString = [valueString substringToIndex:dbRange.location];
                            if ([par[1] isEqualToString:@"g"]) {
                                self.replayGainAlbumValue = [valueString floatValue];
                            } else {
                                self.replayGainAlbumPeak = [valueString floatValue];
                            }
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] AAC/ALAC/MP3 %@: %@", par[0], valueString);
                            #endif
                            break;
                        }
                    }

                    // ---- iTunes (AAC/ALAC) ----
                    for (AVMetadataItem *metadataItem in iTunesItems) {
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] iTunes Key:%@ Val:%@ KS:%@ id:%@ free:%@",
                              metadataItem.key, metadataItem.value, metadataItem.keySpace,
                              metadataItem.identifier, metadataItem.extraAttributes[AVMetadataExtraAttributeInfoKey]);
                        #endif
                        // Check with itendifiers/keys “freeform”
                        NSString *freeName = metadataItem.extraAttributes[AVMetadataExtraAttributeInfoKey] ?: @"";
                        NSString *keyStr = [metadataItem.key isKindOfClass:NSString.class] ? (NSString *)metadataItem.key : @"";
                        NSString *hay = [[@[ (metadataItem.identifier ?: @""), freeName, keyStr ]
                                           componentsJoinedByString:@"|"] lowercaseString];

                        BOOL match = NO;
                        for (NSString *k in replayGainKeys) {
                            if ([hay containsString:k.lowercaseString]) { match = YES; break; }
                        }
                        if (!match) continue;

                        NSString *valueString = nil;
                        if ([metadataItem.value isKindOfClass:NSString.class]) {
                            valueString = [(NSString *)metadataItem.value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        } else if ([metadataItem.value isKindOfClass:NSData.class]) {
                            valueString = [[NSString alloc] initWithData:(NSData *)metadataItem.value encoding:NSUTF8StringEncoding];
                            valueString = [valueString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        }
                        if (!valueString.length) continue;

                        NSRange dbRange = [valueString rangeOfString:@" dB" options:NSCaseInsensitiveSearch];
                        if (dbRange.location != NSNotFound) valueString = [valueString substringToIndex:dbRange.location];

                        float rg = [valueString floatValue];
                        // The old structure of the line below caused the distortions via AirPlay
                        if ([hay containsString:@"itunnorm"]) {
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] iTunNORM detectado (converter noutro passo).");
                            #endif
                        }
                        replayGainValue = rg;
                        foundReplayGain = YES;
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] AAC/ALAC track replayGain: %f dB", replayGainValue);
                        #endif
                        self.replayGainValue = replayGainValue;
                        [self pushReplayGainToStreamer];
                        break;

                    }

                    // ---- ID3 fallback (MP3) ----
                    if (!foundReplayGain) {
                        for (AVMetadataItem *metadataItem in id3Items) {
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] ID3 Key:%@ Val:%@ KS:%@", metadataItem.key, metadataItem.value, metadataItem.keySpace);
                            #endif
                            if ([metadataItem.keySpace isEqualToString:@"org.id3"] &&
                                [metadataItem.key isKindOfClass:[NSString class]] &&
                                [(NSString *)metadataItem.key isEqualToString:@"TXXX"]) {
                                NSString *valueString = [metadataItem.value description];
                                valueString = [valueString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                if ([valueString hasSuffix:@" dB"]) {
                                    NSString *gainValueString = [valueString substringToIndex:(valueString.length - 3)];
                                    float rg = [gainValueString floatValue];
                                    replayGainValue = rg;
                                    foundReplayGain = YES;
                                    #ifdef DEBUG
                                    NSLog(@"[ReplayGain] MP3 (inferred track gain): %f dB", replayGainValue);
                                    #endif
                                    self.replayGainValue = replayGainValue;
                                    [self pushReplayGainToStreamer];
                                    break;
                                }
                            }
                        }
                    }

                    if (!foundReplayGain) {
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] No valid ReplayGain metadata found.");
                        #endif
                        replayGainValue = 0.0f;
                    }

                    // Closing: track number + UI + notifications
                    finishAndUpdateUI();
                });
                // ---------- end ReplayGain macOS 15+ ----------
            });
        }];
    };

    // Handle different formats based on file extension
    if ([extension isEqualToString:@"flac"]) {
        dispatch_async(dispatch_get_main_queue(), flacMetadataBlock);
    } else if ([extension isEqualToString:@"wv"]) {
        dispatch_async(dispatch_get_main_queue(), wavPackMetadataBlock);
    } else {
        dispatch_async(dispatch_get_main_queue(), otherFormatsMetadataBlock);
    }
}

- (void)triggerNowPlayingNotificationWithTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album {
    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString stringWithFormat:NSLocalizedString(@"now_playing_title", @"Now Playing: %@"), title];
    content.subtitle = [NSString stringWithFormat:NSLocalizedString(@"now_playing_artist", @"Now Playing: %@"), artist];
    content.body = [NSString stringWithFormat:NSLocalizedString(@"now_playing_album", @"Album: %@"), album];
    content.sound = [UNNotificationSound defaultSound];

    // Attach cover art if available
    if (self.coverArtView.image) {
        // Convert NSImage to NSData
        CGImageRef cgRef = [self.coverArtView.image CGImageForProposedRect:nil context:nil hints:nil];
        NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
        [newRep setSize:[self.coverArtView.image size]];   // Ensure the size remains the same
        NSData *pngData = [newRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        
        // Save the image to a temporary file
        NSString *tempDirectory = NSTemporaryDirectory();
        NSString *tempFilePath = [tempDirectory stringByAppendingPathComponent:@"coverArt.png"];
        [pngData writeToFile:tempFilePath atomically:YES];
            #ifdef DEBUG
            NSLog(@"Temporary cover art directory: %@", NSTemporaryDirectory());
            #endif
        
        // Create a UNNotificationAttachment from the file
        NSError *attachmentError = nil;
        UNNotificationAttachment *attachment = [UNNotificationAttachment attachmentWithIdentifier:@"coverArt"
                                 URL:[NSURL fileURLWithPath:tempFilePath]
                                 options:nil
                                 error:&attachmentError];
        if (!attachmentError) {
            content.attachments = @[attachment];
        } else {
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"error_attaching_cover_art", @"Error attaching cover art: %@"), attachmentError.localizedDescription);
            #endif
        }
    }
    
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"NowPlaying"
                          content:content
                          trigger:nil];
    
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                          withCompletionHandler:nil];
}

- (void)stopCava {
    if (self.cavaTask && self.cavaTask.isRunning) {
        [self.cavaTask terminate];
        [self.cavaTask waitUntilExit];
        #ifdef DEBUG
        NSLog(@"cava terminated.");
        #endif
        self.cavaTask = nil;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopCava];
    [self stopBs2bIfRunning];
    [self teardownBs2bHeadphoneMonitoring];
    [self stopBs2bHeadphoneAutoStart];
    [self saveTrackPlayCounts];
    [self.airPlayManager stopDiscovery];
}

#pragma mark - Faixa adiantada em memória

// A ranhura do adiantamento leva uma faixa só: os bytes do ficheiro e o URL a
// que eles pertencem. Ler um ficheiro inteiro para memória enquanto a faixa
// anterior ainda toca é o que permite que a transição não espere pelo disco —
// que aqui é externo e tem a biblioteca toda —, nem para as etiquetas nem para
// o arranque.
//
// Tudo o que lhe toca passa por estes métodos, e todos eles fecham
// `@synchronized (self)`: o URL é escrito pela thread que pede o adiantamento, os
// bytes por uma fila de fundo, e os consumidores estão espalhados por quatro
// formatos. Antes disto só a escrita dos bytes é que estava trancada.
//
// O `prefetchGeneration` é o que amarra os bytes ao URL. Sem ele, uma leitura
// lançada para a faixa A que só terminasse depois de a ranhura já apontar para B
// — dois saltos seguidos no ⏭️, ou o disco a demorar — publicava os bytes de A
// por baixo do URL de B, e a seguir tocava-se A a pensar que era B. Cada leitura
// leva o número da geração em que nasceu e só publica se ele ainda for o
// corrente; quem mexe na ranhura faz o número avançar.

// Deita fora o que estiver adiantado e invalida a leitura que esteja a caminho.
- (void)discardPrefetchedTrack {
    @synchronized (self) {
        self.prefetchGeneration++;
        self.prefetchedTrackURL = nil;
        self.prefetchedData = nil;
    }
}

// Manda ler uma faixa para memória. Pedir a que já lá está não faz nada — é o
// que permite chamar isto sempre que alguma coisa mexe na fila, sem se estar a
// reler o mesmo ficheiro.
- (void)prefetchTrackAtURL:(NSURL *)trackURL {
    if (!trackURL) {
        [self discardPrefetchedTrack];
        return;
    }

    uint64_t geracao;
    @synchronized (self) {
        if ([self.prefetchedTrackURL isEqual:trackURL]) {
            return;
        }
        self.prefetchGeneration++;
        geracao = self.prefetchGeneration;
        self.prefetchedTrackURL = trackURL;
        self.prefetchedData = nil;  // os bytes que lá estavam são de outra faixa
    }

    // QOS_CLASS_UTILITY, e não a prioridade «background» que aqui estava: o
    // macOS estrangula deliberadamente a entrada e saída das threads de fundo
    // (IOPOL_THROTTLE), e isto tem prazo — a leitura tem de estar feita antes de
    // a faixa actual acabar. «Utility» continua a ser trabalho de segundo plano,
    // que não disputa a thread principal, mas sem o estrangulamento do disco.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:trackURL options:NSDataReadingMappedIfSafe error:nil];
        @synchronized (self) {
            if (self.prefetchGeneration != geracao) {
                return;  // a ranhura mudou de faixa enquanto se lia
            }
            self.prefetchedData = data;
        }
    });
}

// Os bytes desta faixa, se forem os que estão adiantados, sem esvaziar a
// ranhura. Serve a leitura de etiquetas do WavPack, que acontece mesmo antes de
// -playWavPack: os ir buscar a sério.
- (NSData *)prefetchedDataForTrack:(NSURL *)trackURL {
    @synchronized (self) {
        if (trackURL && [self.prefetchedTrackURL isEqual:trackURL]) {
            return self.prefetchedData;
        }
        return nil;
    }
}

// Como o anterior, mas esvaziando a ranhura: é assim que se arranca uma faixa.
// Devolver nil com a leitura ainda a meio é o que se quer — quem chama vai ao
// disco, e a leitura em curso deixa de interessar a alguém.
- (NSData *)takePrefetchedDataForTrack:(NSURL *)trackURL {
    @synchronized (self) {
        if (!trackURL || ![self.prefetchedTrackURL isEqual:trackURL]) {
            return nil;
        }
        NSData *data = self.prefetchedData;
        self.prefetchGeneration++;
        self.prefetchedTrackURL = nil;
        self.prefetchedData = nil;
        return data;
    }
}

// Qual é a faixa que vem a seguir à actual, na fila que estiver em vigor. É a
// mesma conta que -playNextTrack faz para andar para a frente, e tem de ser: o
// adiantamento é uma aposta, e uma aposta noutra faixa não serve para nada.
- (NSURL *)upcomingTrackURL {
    NSArray<NSURL *> *lista = [self currentPlaybackList];
    if (lista.count == 0) {
        return nil;
    }

    // Sem faixa escolhida ainda, a seguinte é a primeira: assim o primeiro ▶️
    // também arranca de memória.
    NSInteger actual = self.currentTrackIndex;
    if (actual < 0 || actual >= (NSInteger)lista.count) {
        actual = -1;
    }

    if (self.isShuffleModeActive) {
        return lista[(actual + 1) % (NSInteger)lista.count];
    }

    NSInteger seguinte = actual + 1;
    if (seguinte >= (NSInteger)lista.count) {
        // Fim da biblioteca: só há faixa seguinte se o repetir estiver ligado.
        return self.isRepeatModeActive ? lista.firstObject : nil;
    }
    return lista[seguinte];
}

// Adianta a faixa que vier a seguir à actual. Chamado de todos os sítios que
// possam mudar quem é essa faixa: ao arrancar uma música, ao saltar de uma para
// a outra, ao ligar ou desligar o aleatório e o repetir, e ao recarregar a
// biblioteca.
- (void)prefetchNextTrack {
    [self prefetchTrackAtURL:[self upcomingTrackURL]];
}

@end


