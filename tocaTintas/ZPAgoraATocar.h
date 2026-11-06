//
//  ZPAgoraATocar.h
//  tocaTintas
//
//  O «A tocar» do sistema (MPNowPlayingInfoCenter) e os comandos que chegam
//  pelo MPRemoteCommandCenter: AirPods, teclas ⏯ ⏭ ⏮, Centro de Controlo.
//
//  À parte do ViewController de propósito: os cabeçalhos da MediaPlayer
//  declaram -objectForKeyedSubscript: na MPMediaEntity como indisponível no
//  macOS, e, vistos pelo ViewController, cada subscrito num `id` passava a
//  escolher essa declaração e a dar erro (12, a 2026-11-06).
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Regista os comandos. O bloco recebe o nome do comando, igual ao dos comandos
// AppleScript do tocaTintas: «play», «pause», «playpause», «stop», «next track»,
// «previous track». Devolve NO se o comando não foi aceite. Saltar para uma
// posição não se oferece.
void ZPAgoraATocarConfigurar(BOOL (^mandar)(NSString *comando));

// Publica o que está a tocar. duracao <= 0 se não se souber; capa pode ser nil.
void ZPAgoraATocarPublicar(NSString *titulo, NSString *artista, NSString *album,
                           double duracao, double posicao, BOOL aTocar, NSImage * _Nullable capa);

// Sai do «A tocar», para o sistema dar as teclas a quem estiver a tocar.
void ZPAgoraATocarLimpar(void);

NS_ASSUME_NONNULL_END
