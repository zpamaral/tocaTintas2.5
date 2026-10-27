//
//  ZPAudioCapture.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 08/11/2026.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreAudio/CoreAudio.h>

/// Prende a entrada de uma AVAudioEngine ao dispositivo de loopback (BlackHole),
/// em vez de aceitar o dispositivo de entrada por omissão do sistema.
///
/// Sem isto, gravar e transmitir por AirPlay capturam «o que o sistema tiver
/// como entrada» — e bastava alguém pôr a entrada no microfone para se gravar a
/// sala em vez da música, sem aviso nenhum. Com isto, a entrada por omissão
/// fica livre para o microfone e para o resto do Mac.
///
/// Tem de ser chamada com a engine parada e antes de se ler o formato de
/// entrada, que é o do dispositivo. Devolve NO se não houver BlackHole, e nesse
/// caso a engine fica com o dispositivo por omissão, como dantes.
BOOL ZPBindEngineInputToLoopback(AVAudioEngine *engine);

/// O dispositivo de loopback (BlackHole), ou kAudioObjectUnknown se não houver.
/// Exposto porque o caminho do AirPlay também precisa dele — para lhe ler o
/// volume, que é aplicado antes de tudo o resto.
AudioDeviceID ZPLoopbackAudioDevice(void);

/// A frequência nominal do BlackHole, em Hz, ou 0 se não houver BlackHole.
double ZPLoopbackSampleRate(void);

/// Põe o BlackHole a esta frequência e espera, até um segundo, que a mudança
/// pegue. Devolve NO se o dispositivo não a aceitar. Quem a chama tem de parar
/// antes a ponte do bs2b: o CamillaDSP força o BlackHole para a frequência da
/// sua configuração, e desfazia a mudança.
BOOL ZPSetLoopbackSampleRate(double frequencia);

/// A frequência da faixa que o Música está a tocar (a do master, no Apple
/// Music), ou 0 se o Música não estiver aberto, não tiver faixa, ou não deixar
/// perguntar. Nunca abre o Música.
double ZPMusicCurrentTrackSampleRate(void);

/// Manda um comando AppleScript ao Música («pause», «play», «set player
/// position to 0»…), se estiver aberto. Devolve NO se não estiver ou se falhar,
/// incluindo não responder em dois segundos.
BOOL ZPMusicCommand(NSString *comando);

/// O que o Música está a tocar: @"estado" («playing», «paused», «stopped») e,
/// fora de «stopped», @"posicao" e @"duracao" (segundos), @"titulo",
/// @"artista", @"album" e @"faixa" (número). Com o Música fechado, @"estado" é
/// «stopped». nil só se o Música não responder (ocupado, encravado, ou a
/// automação recusada): quem pergunta pode tentar outra vez. Espera no máximo
/// dois segundos. Só no thread principal.
NSDictionary *ZPMusicNowPlaying(void);

/// A capa da faixa que o Música está a tocar, tal como ele a tem (PNG ou JPEG),
/// ou nil.
NSData *ZPMusicCurrentArtworkData(void);

/// Publicada no thread principal quando a gravação tem algo a dizer a quem a
/// pediu: userInfo[@"titulo"] e userInfo[@"texto"], já traduzidos.
extern NSString * const kZPAudioCaptureWarningNotification;

/// O estado da grelha da gravação em curso (ver -vigiarGrelha:tramas:). Só
/// para as gravações pelo BlackHole.
typedef NS_ENUM(NSInteger, ZPEstadoDaGrelha) {
    ZPEstadoDaGrelhaBitExacta = 0,    // nada fora da grelha até agora
    ZPEstadoDaGrelhaHouveFalhas = 1,  // algumas tramas fora, ou esteve mal e já não está
    ZPEstadoDaGrelhaMal = 2,          // mais de metade da última janela fora
};

/// Publicada no thread principal quando o estado da grelha muda:
/// userInfo[@"estado"] é um ZPEstadoDaGrelha. Uma gravação nova começa sempre
/// em ZPEstadoDaGrelhaBitExacta, sem notificação.
extern NSString * const kZPAudioCaptureGridStateNotification;

@interface ZPAudioCapture : NSObject

// Grava para um WAV de vírgula flutuante de 32 bits em
// ~/Library/Application Support/tocaTintas. A fonte é a escolhida nas
// preferências (ZPCurrentRecordSource): o BlackHole, ou o som do app Música por
// captura de processo. Quem trata do AirPlay é o ZPAirPlayStreamer — esta
// classe só grava.
//
// Devolve NO se a gravação não arrancou; o motivo chega antes, pela
// kZPAudioCaptureWarningNotification.
- (BOOL)startCapturingAudio;
- (void)stopCapturingAudio;

// Pára e apaga o ficheiro, em vez de o fechar: para recomeçar a gravação
// quando a frequência do BlackHole tem de mudar antes de haver música nela.
- (void)abandonCapturingAudio;

// Já entrou no ficheiro alguma amostra diferente de zero. Até lá, o que há é
// o silêncio de antes de o Música tocar, e recomeçar não perde nada.
@property (atomic, readonly) BOOL gravouSom;

@end

