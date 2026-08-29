//
//  ZPAudioCapture.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 08/11/2026.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

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

@interface ZPAudioCapture : NSObject

// Grava a entrada de áudio para um WAV de vírgula flutuante de 32 bits em
// ~/Library/Application Support/tocaTintas. Quem trata do AirPlay é o
// ZPAirPlayStreamer — esta classe só grava.
- (void)startCapturingAudio;
- (void)stopCapturingAudio;

@end

