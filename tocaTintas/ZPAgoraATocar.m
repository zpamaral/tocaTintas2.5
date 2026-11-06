//
//  ZPAgoraATocar.m
//  tocaTintas
//
//  Ver ZPAgoraATocar.h.
//

#import "ZPAgoraATocar.h"
#import <MediaPlayer/MediaPlayer.h>

void ZPAgoraATocarConfigurar(BOOL (^mandar)(NSString *comando)) {
    MPRemoteCommandCenter *centro = [MPRemoteCommandCenter sharedCommandCenter];
    MPRemoteCommandHandlerStatus (^tratar)(NSString *) = ^MPRemoteCommandHandlerStatus(NSString *comando) {
        return mandar(comando) ? MPRemoteCommandHandlerStatusSuccess : MPRemoteCommandHandlerStatusCommandFailed;
    };
    [centro.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return tratar(@"play");
    }];
    [centro.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return tratar(@"pause");
    }];
    [centro.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return tratar(@"playpause");
    }];
    [centro.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return tratar(@"stop");
    }];
    [centro.nextTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return tratar(@"next track");
    }];
    [centro.previousTrackCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *e) {
        return tratar(@"previous track");
    }];
    centro.changePlaybackPositionCommand.enabled = NO;
    centro.seekForwardCommand.enabled = NO;
    centro.seekBackwardCommand.enabled = NO;
    centro.skipForwardCommand.enabled = NO;
    centro.skipBackwardCommand.enabled = NO;
}

void ZPAgoraATocarPublicar(NSString *titulo, NSString *artista, NSString *album,
                           double duracao, double posicao, BOOL aTocar, NSImage *capa) {
    NSMutableDictionary *info = [@{
        MPMediaItemPropertyTitle: titulo,
        MPMediaItemPropertyArtist: artista,
        MPMediaItemPropertyAlbumTitle: album,
        MPNowPlayingInfoPropertyMediaType: @(MPNowPlayingInfoMediaTypeAudio),
        MPNowPlayingInfoPropertyElapsedPlaybackTime: @(posicao),
        MPNowPlayingInfoPropertyPlaybackRate: @(aTocar ? 1.0 : 0.0),
    } mutableCopy];
    if (duracao > 0.0) info[MPMediaItemPropertyPlaybackDuration] = @(duracao);
    if (capa.size.width > 0) {
        info[MPMediaItemPropertyArtwork] =
            [[MPMediaItemArtwork alloc] initWithBoundsSize:capa.size requestHandler:^NSImage *(CGSize tamanho) {
                return capa;
            }];
    }
    MPNowPlayingInfoCenter *centro = [MPNowPlayingInfoCenter defaultCenter];
    centro.nowPlayingInfo = info;
    centro.playbackState = aTocar ? MPNowPlayingPlaybackStatePlaying : MPNowPlayingPlaybackStatePaused;
}

void ZPAgoraATocarLimpar(void) {
    MPNowPlayingInfoCenter *centro = [MPNowPlayingInfoCenter defaultCenter];
    centro.nowPlayingInfo = nil;
    centro.playbackState = MPNowPlayingPlaybackStateStopped;
}
