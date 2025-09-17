//
//  ZPAudioCapture.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 08/11/2024.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@interface ZPAudioCapture : NSObject

@property (nonatomic, strong) NSURL *audioSaveDirectory; // Directory to save audio recordings
- (void)startCapturingAudio;
- (void)stopCapturingAudio;

@end

