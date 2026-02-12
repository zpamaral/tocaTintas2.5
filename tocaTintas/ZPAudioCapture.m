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
//  ZPAudioCapture.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 14/11/2026.
//
#import "ZPAudioCapture.h"
#import <AVFoundation/AVFoundation.h>

@interface ZPAudioCapture ()

// Audio Engine
@property (strong, nonatomic) AVAudioEngine *audioEngine;

// Recording properties
@property (strong, nonatomic) NSOutputStream *fileOutputStream;
@property (assign, nonatomic) BOOL isRecording;

// Streaming properties
@property (strong, nonatomic) NSTask *raopTask;
@property (strong, nonatomic) NSPipe *inputPipe;
@property (assign, nonatomic) BOOL isStreaming;
@property (strong, nonatomic) NSString *ipAddress;
@property (strong, nonatomic) NSString *port;

// Gain adjustment
@property (assign, nonatomic) float gainFactor;

@end

@implementation ZPAudioCapture

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize audio engine
        _audioEngine = [[AVAudioEngine alloc] init];
        _isRecording = NO;
        _isStreaming = NO;
        _gainFactor = 1.0; // Default gain factor (no gain adjustment)
    }
    return self;
}

#pragma mark - Original Method Names (Aliases)

// Start capturing audio (alias for startRecording)
- (void)startCapturingAudio {
    [self startRecording];
}

// Stop capturing audio (alias for stopRecording)
- (void)stopCapturingAudio {
    [self stopRecording];
}

#pragma mark - Recording Methods

- (void)startRecording {
    if (self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Already recording.");
        #endif
        return;
    }

    self.isRecording = YES;
    
    // Set default gain (e.g., +6 dB); it overrides _gainFactor
    [self setGainInDecibels:6.0];

    // Get the Application Support directory
    NSArray<NSURL *> *appSupportURLs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *appSupportURL = [appSupportURLs firstObject];

    // Append your app's directory
    NSURL *appDirectory = [appSupportURL URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES];

    // Ensure the directory exists
    NSError *error = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:[appDirectory path]]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:appDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Audio Capture] Error creating directory: %@", error.localizedDescription);
            #endif
        }
    }

    // Create a unique file name
    NSString *fileName = [NSString stringWithFormat:@"Recording_%@.pcm", [[NSUUID UUID] UUIDString]];
    NSURL *outputFileURL = [appDirectory URLByAppendingPathComponent:fileName];

    // Set up the file output stream
    self.fileOutputStream = [NSOutputStream outputStreamWithURL:outputFileURL append:NO];
    [self.fileOutputStream open];

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Recording started. Saving to %@", [outputFileURL path]);
    #endif

    // Start or update audio capture
    [self startOrUpdateAudioCapture];
}

- (void)stopRecording {
    if (!self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Recording is not running.");
        #endif
        return;
    }

    self.isRecording = NO;

    if (self.fileOutputStream) {
        [self.fileOutputStream close];
        self.fileOutputStream = nil;
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Recording stopped and file output stream closed.");
        #endif
    }

    // Stop audio capture if not streaming
    [self stopAudioCaptureIfNeeded];
}

#pragma mark - Streaming Methods

- (void)startStreamingToIPAddress:(NSString *)ipAddress port:(NSString *)port {
    if (self.isStreaming) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Already streaming.");
        #endif
        return;
    }

    self.isStreaming = YES;
    self.ipAddress = ipAddress;
    self.port = port;

    // Set up the pipe to connect to raop_play's standard input
    self.inputPipe = [NSPipe pipe];

    // Start raop_play as a subprocess
    self.raopTask = [[NSTask alloc] init];
    NSString *raopPlayPath = [[NSBundle mainBundle] pathForResource:@"raop_play" ofType:nil];
    self.raopTask.launchPath = raopPlayPath;

    self.raopTask.arguments = @[
        @"-a", self.ipAddress,
        @"-p", self.port,
        @"-"
    ];

    self.raopTask.standardInput = self.inputPipe;
    self.raopTask.standardOutput = [NSPipe pipe]; // Optional
    self.raopTask.standardError = [NSPipe pipe];  // Optional

    // Launch raop_play
    [self.raopTask launch];

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Streaming started to %@:%@", self.ipAddress, self.port);
    #endif

    // Start or update audio capture
    [self startOrUpdateAudioCapture];
}

- (void)stopStreaming {
    if (!self.isStreaming) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Streaming is not running.");
        #endif
        return;
    }

    self.isStreaming = NO;

    // Close pipe and terminate raop_play
    if (self.inputPipe && self.inputPipe.fileHandleForWriting) {
        [self.inputPipe.fileHandleForWriting closeFile];
        self.inputPipe = nil;
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Input pipe closed.");
        #endif
    }

    if (self.raopTask) {
        [self.raopTask terminate];
        self.raopTask = nil;
        #ifdef DEBUG
        NSLog(@"[Audio Capture] RAOP task terminated.");
        #endif
    }

    #ifdef DEBUG
    NSLog(@"[Audio Capture] Streaming stopped.");
    #endif

    // Stop audio capture if not recording
    [self stopAudioCaptureIfNeeded];
}

#pragma mark - Audio Capture Management

- (void)startOrUpdateAudioCapture {
    // If the audio engine is already running, no need to reinstall the tap
    if (self.audioEngine.isRunning) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio engine is already running.");
        #endif
        return;
    }

    // Install the audio tap
    [self installAudioTap];

    // Start the audio engine
    NSError *engineError = nil;
    if (![self.audioEngine startAndReturnError:&engineError]) {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Error starting audio engine: %@", engineError.localizedDescription);
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio capturing started.");
        #endif
    }
}

- (void)stopAudioCaptureIfNeeded {
    // Stop the audio engine if neither recording nor streaming is active
    if (!self.isRecording && !self.isStreaming) {
        if (self.audioEngine.isRunning) {
            [self.audioEngine.inputNode removeTapOnBus:0];
            [self.audioEngine stop];
            #ifdef DEBUG
            NSLog(@"[Audio Capture] Audio engine stopped.");
            #endif
        }
    } else {
        #ifdef DEBUG
        NSLog(@"[Audio Capture] Audio engine continues running (recording or streaming is active).");
        #endif
    }
}

- (void)installAudioTap {
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];

    // Configure the target format to 16-bit PCM, 44.1 kHz, 2 channels, interleaved
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                   sampleRate:44100.0
                                                                     channels:2
                                                                  interleaved:YES];

    // Install a tap on the input node to capture audio data
    __weak typeof(self) weakSelf = self; // Prevent retain cycles
    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:inputFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (buffer.frameLength > 0) {
            // Apply gain if needed
            if (strongSelf.gainFactor != 1.0) {
                for (AVAudioChannelCount channel = 0; channel < buffer.format.channelCount; channel++) {
                    float *channelData = buffer.floatChannelData[channel];
                    for (AVAudioFrameCount frame = 0; frame < buffer.frameLength; frame++) {
                        // Apply gain
                        channelData[frame] *= strongSelf.gainFactor;

                        // Clamp to 16-bit PCM range
                        if (channelData[frame] > 32767.0) channelData[frame] = 32767.0;
                        if (channelData[frame] < -32768.0) channelData[frame] = -32768.0;
                    }
                }
            }

            // Convert the buffer to the target format
            AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat frameCapacity:buffer.frameCapacity];
            NSError *error = nil;
            AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];

            [converter convertToBuffer:convertedBuffer fromBuffer:buffer error:&error];
            if (error) {
                #ifdef DEBUG
                NSLog(@"[Audio Capture] Error converting audio buffer: %@", error.localizedDescription);
                #endif
                return;
            }

            // Prepare PCM data
            NSData *pcmData = [NSData dataWithBytes:convertedBuffer.int16ChannelData[0]
                                             length:(convertedBuffer.frameLength * targetFormat.streamDescription->mBytesPerFrame)];

            // Write PCM data to the file if recording
            if (strongSelf.isRecording && strongSelf.fileOutputStream) {
                NSInteger bytesWritten = [strongSelf.fileOutputStream write:pcmData.bytes maxLength:pcmData.length];
                if (bytesWritten < 0) {
                    #ifdef DEBUG
                    NSLog(@"[Audio Capture] Error writing to file: %@", strongSelf.fileOutputStream.streamError.localizedDescription);
                    #endif
                }
            }

            // Write PCM data to raop_play via the pipe if streaming
            if (strongSelf.isStreaming && strongSelf.inputPipe) {
                NSFileHandle *pipeWriteHandle = [strongSelf.inputPipe fileHandleForWriting];
                [pipeWriteHandle writeData:pcmData];
            }
        }
    }];
}

#pragma mark - Gain Adjustment

- (void)setGainInDecibels:(float)gainInDb {
    // Convert dB gain to linear scale factor
    self.gainFactor = powf(10.0, gainInDb / 20.0);
    #ifdef DEBUG
    NSLog(@"[Audio Capture] Gain factor set to %.2f for %.2f dB gain.", self.gainFactor, gainInDb);
    #endif
}

@end
