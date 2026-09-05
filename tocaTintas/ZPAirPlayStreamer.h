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
//  ZPAirPlayStreamer.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 14/11/2026.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "ZPOpusDecoder.h"

#import <sys/stat.h>
#import <unistd.h>
#import <math.h>

@interface ZPAirPlayStreamer : NSObject

@property (nonatomic, strong) id<NSObject> preventSleepActivity;
@property (nonatomic, assign) BOOL cancelPendingStart; // Guard for async start
@property (nonatomic, assign) int raopClockFD;

- (instancetype)initWithIPAddress:(NSString *)ipAddress port:(NSString *)port replayGainValue:(float)replayGainValue;

- (void)updateReplayGainValue:(float)dB; // To update the gain for each streamed song

/// Como o anterior, mas com o `replaygain_track_peak` da faixa (0…1; 0 ou
/// negativo significa «desconhecido»). Com o pico, o ganho é limitado a 1/pico
/// para a normalização não ceifar os picos das faixas mais baixas.
- (void)updateReplayGainValue:(float)dB trackPeak:(float)peak;

- (void)startStreaming;
- (void)stopStreaming;

/// O relógio do raop_play está mesmo a chegar? O raop_play só escreve os tempos
/// no FIFO se for lançado com `-f`, e a escrita vive num subcomando que pode não
/// estar presente na compilação que estiver instalada. Isto é NO enquanto não
/// chegar linha nenhuma, e volta a NO se as linhas pararem (deve vir uma por
/// segundo).
@property (nonatomic, readonly) BOOL raopClockIsRunning;

/// Quanto tempo separa o que está a ser capturado agora do que se ouve no
/// aparelho AirPlay, em segundos. É a soma da latência pedida ao raop_play com o
/// áudio que ainda não saiu — o que está no tubo e dentro do próprio raop_play.
/// Zero significa «não sei», e não «estão sincronizados»: sem relógio não há
/// medição. É este o número com que se pode atrasar a reprodução local para a
/// pôr de acordo com a remota.
@property (nonatomic, readonly) NSTimeInterval remoteAudioLag;

/// Sends a DMAP "play" command to the currently configured AirPlay device.
/// The command is issued with a default session identifier of 1, which
/// mirrors the behaviour of `atvremote` when no session has been negotiated.
- (void)sendPlayCommand;

@end
