/*
Copyright (c) 2024 Zé Pedro do Amaral <amaral@mac.com>

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
//  ZPOpusDecoder.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 14/09/2024.
//

#include <ogg/ogg.h>
#include <opus/opusfile.h>

#import <Cocoa/Cocoa.h>
#import "ZPOpusDecoder.h"
#import "ZPAirPlayStreamer.h"
#import <Foundation/Foundation.h> // For base64 decoding

@implementation ZPOpusDecoder {
    OggOpusFile *opusFile;
    NSString *filePath;
    NSData *memoryData;
    ogg_sync_state oy;   // Ogg sync state
    ogg_stream_state os; // Ogg stream state
}

- (instancetype)initWithFilePath:(NSString *)path {
    self = [super init];
    if (self) {
        filePath = [path copy];

        // Initialize airPlayStreamer. Resolved problem with running the track gain updater.
        self.airPlayStreamer = [[ZPAirPlayStreamer alloc] init];
        if (!self.airPlayStreamer) {
            #ifdef DEBUG
            NSLog(@"[ReplayGain] Opus failed to initialize AirPlayStreamer.");
            #endif
            return nil;
        }

        __block int error = 0;  // Use __block to allow modification inside the block

        __weak typeof(self) weakSelf = self;
        dispatch_block_t openFileBlock = dispatch_block_create(0, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->opusFile = op_open_file([strongSelf->filePath UTF8String], &error);  // 'error' is mutable
            }
        });
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), openFileBlock);

        if (error != 0 || !opusFile) {
            #ifdef DEBUG
            NSLog(@"Error opening Opus file: %d", error);
            #endif
            return nil;
        }
    }
    return self;
}

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) {
        memoryData = [data copy];

        self.airPlayStreamer = [[ZPAirPlayStreamer alloc] init];
        if (!self.airPlayStreamer) {
            #ifdef DEBUG
            NSLog(@"[ReplayGain] Opus failed to initialize AirPlayStreamer.");
            #endif
            return nil;
        }

        __block int error = 0;
        __weak typeof(self) weakSelf = self;
        dispatch_block_t openBlock = dispatch_block_create(0, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf->opusFile = op_open_memory(strongSelf->memoryData.bytes,
                                                   strongSelf->memoryData.length,
                                                   &error);
            }
        });
        dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), openBlock);

        if (error != 0 || !opusFile) {
            #ifdef DEBUG
            NSLog(@"Error opening Opus data: %d", error);
            #endif
            return nil;
        }
    }
    return self;
}

- (BOOL)decodeFile {
    if (!opusFile) {
        return NO;
    }

    __block BOOL success = YES;
    __block float replayGainValue = 0.0f; // Default replay gain

    dispatch_block_t decodeBlock = dispatch_block_create(0, ^{
        if (self && self->opusFile) {
            const OpusTags *tags = op_tags(self->opusFile, -1);
            if (tags) {
                #ifdef DEBUG
                NSLog(@"[ReplayGain] Opus tags found: %d comments", tags->comments);
                #endif

                for (int i = 0; i < tags->comments; ++i) {
                    const char *comment = tags->user_comments[i];
                    #ifdef DEBUG
                    NSLog(@"[ReplayGain] Opus Tag[%d]: %s", i, comment);
                    #endif

                    if (strncasecmp(comment, "ARTIST=", 7) == 0) {
                        self.artist = [NSString stringWithUTF8String:comment + 7];
                    } else if (strncasecmp(comment, "TITLE=", 6) == 0) {
                        self.title = [NSString stringWithUTF8String:comment + 6];
                    } else if (strncasecmp(comment, "ALBUM=", 6) == 0) {
                        self.album = [NSString stringWithUTF8String:comment + 6];
                    } else if (strncasecmp(comment, "TRACKNUMBER=", 12) == 0) {
                        NSString *trackString = [NSString stringWithUTF8String:comment + 12];
                        NSInteger trackNumber = [trackString integerValue];
                        self.track = [NSString stringWithFormat:@"%ld", (long)trackNumber];
                    } else if (strncasecmp(comment, "METADATA_BLOCK_PICTURE=", 23) == 0) {
                        [self extractCoverArtFromMetadata:comment + 23];
                    } else if (strncasecmp(comment, "replaygain_track_gain=", 22) == 0) {
                        NSString *gainString = [NSString stringWithUTF8String:comment + 22];
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] Opus raw replay gain string: %@", gainString);
                        #endif

                        // Remove trailing " dB" if present
                        gainString = [gainString stringByReplacingOccurrencesOfString:@" dB" withString:@""];
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] Opus cleaned replay gain string: %@", gainString);
                        #endif

                        // Validate and convert to float
                        NSCharacterSet *invalidCharacters = [[NSCharacterSet characterSetWithCharactersInString:@"-0123456789."] invertedSet];
                        if ([gainString rangeOfCharacterFromSet:invalidCharacters].location == NSNotFound) {
                            replayGainValue = [gainString floatValue];
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] Opus valid replay gain value: %.2f", replayGainValue);
                            #endif
                        } else {
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] Opus invalid gain string: %@", gainString);
                            #endif
                            success = NO;
                        }
                    }
                }
            } else {
                #ifdef DEBUG
                NSLog(@"[ReplayGain] Opus no tags found.");
                #endif
                success = NO;
            }
        }
    });

    // Execute the block synchronously
    dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), decodeBlock);

    // Update properties on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.airPlayStreamer) {
            // Store ReplayGain in the property
            self.replayGainValue = replayGainValue;

            #ifdef DEBUG
            NSLog(@"[ReplayGain] Updating AirPlayStreamer with replay gain: %.2f", self.replayGainValue);
            #endif
            [self.airPlayStreamer updateReplayGainValue:self.replayGainValue];
        } else {
            NSLog(@"[ReplayGain] Opus error airPlayStreamer is nil when updating replay gain.");
        }
    });

    return success;
}

- (void)extractCoverArtFromMetadata:(const char *)metadata {
    __weak typeof(self) weakSelf = self;
    dispatch_block_t extractBlock = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            NSString *metadataString = [NSString stringWithUTF8String:metadata];
            
            #ifdef DEBUG
            NSLog(@"Raw METADATA_BLOCK_PICTURE string: %@", metadataString);
            #endif
            
            NSRange jpegStartRange = [metadataString rangeOfString:@"/9j/"];
            if (jpegStartRange.location != NSNotFound) {
                NSString *base64EncodedImage = [metadataString substringFromIndex:jpegStartRange.location];
                NSData *imageData = [[NSData alloc] initWithBase64EncodedString:base64EncodedImage
                                                                        options:NSDataBase64DecodingIgnoreUnknownCharacters];
                
                if (imageData) {
                    strongSelf.albumArt = [[NSImage alloc] initWithData:imageData];
                    
                    if (strongSelf.albumArt) {
                        #ifdef DEBUG
                        NSLog(@"Successfully extracted cover art from METADATA_BLOCK_PICTURE.");
                        #endif
                    } else {
                        #ifdef DEBUG
                        NSLog(@"Failed to convert extracted image data into NSImage.");
                        #endif
                    }
                } else {
                    #ifdef DEBUG
                    NSLog(@"Failed to decode base64-encoded image data.");
                    #endif
                }
            } else {
                #ifdef DEBUG
                NSLog(@"JPEG marker not found in METADATA_BLOCK_PICTURE.");
                #endif
            }
        }
    });

    dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), extractBlock);
}

- (NSTimeInterval)getDuration {
    if (!opusFile) {
        return 0;
    }

    __block NSTimeInterval duration = 0;
    __weak typeof(self) weakSelf = self;
    dispatch_block_t durationBlock = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            ogg_int64_t pcmTotal = op_pcm_total(strongSelf->opusFile, -1);
            duration = (double)pcmTotal / 48000.0; // Opus typically uses a 48kHz sample rate
        }
    });

    dispatch_sync(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), durationBlock);

    return duration;
}

- (void)dealloc {
    if (opusFile) {
        op_free(opusFile);
    }
}

@end
