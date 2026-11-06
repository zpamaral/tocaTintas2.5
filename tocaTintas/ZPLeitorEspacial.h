//
//  ZPLeitorEspacial.h
//  tocaTintas
//
//  Um AVAudioPlayer que toca pelo AVSampleBufferAudioRenderer, com a
//  espacialização do estéreo permitida. É o que faz o «Espacializar estéreo»
//  dos AirPods ficar disponível para o tocaTintas: só o AVPlayerItem e o
//  AVSampleBufferAudioRenderer têm allowedAudioSpatializationFormats, e o valor
//  por omissão para áudio só espacializa o multicanal. O AVAudioPlayer e a
//  AudioQueue não o têm (confirmado com um protótipo a 2026-11-06).
//
//  É subclasse do AVAudioPlayer de propósito: o ViewController continua a
//  falar com «um AVAudioPlayer» e só a criação muda. Substitui o que o
//  tocaTintas usa — play, pause, stop, isPlaying, currentTime (ler e escrever,
//  para o salto de silêncios) — e avisa o delegate no fim. A duração e o resto
//  vêm do próprio AVAudioPlayer, que lê o ficheiro mas nunca toca.
//
//  Usa-se só com a saída do sistema em Bluetooth (ZPSaidaEBluetooth), escolhido
//  no início de cada faixa. Nas outras saídas fica tudo como estava: a ponte
//  do CamillaDSP e o bit-perfect para o BlackHole não passam por aqui.
//

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ZPLeitorEspacial : AVAudioPlayer
@end

// A saída do sistema é Bluetooth (AirPods e afins)?
BOOL ZPSaidaEBluetooth(void);

NS_ASSUME_NONNULL_END
