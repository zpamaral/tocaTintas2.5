//
//  ZPAudioCapture.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 08/11/2026.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface ZPAudioCapture : NSObject

// Grava a entrada de áudio para um WAV de vírgula flutuante de 32 bits em
// ~/Library/Application Support/tocaTintas. Quem trata do AirPlay é o
// ZPAirPlayStreamer — esta classe só grava.
- (void)startCapturingAudio;
- (void)stopCapturingAudio;

@end

