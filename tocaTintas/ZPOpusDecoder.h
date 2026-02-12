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
//  ZPOpusDecoder.h
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 14/09/2026.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>  // Use AppKit for macOS images


// Forward declaration to avoid circular dependency
@class ZPAirPlayStreamer;

@interface ZPOpusDecoder : NSObject  // Ensure it inherits from NSObject

@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *album;
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *track;   // Add track property
@property (nonatomic, strong) NSImage *albumArt;
@property (atomic, strong) ZPAirPlayStreamer *airPlayStreamer;
@property (atomic, assign) float replayGainValue;

// Method to initialize decoder with an Opus file
- (instancetype)initWithFilePath:(NSString *)filePath;

// Alternative initializer that accepts already loaded Opus data
- (instancetype)initWithData:(NSData *)data;

// Method to decode Opus file and extract metadata
- (BOOL)decodeFile;

// Helper method to retrieve file duration
- (NSTimeInterval)getDuration;

@end
/* OpusDecoder_h */
