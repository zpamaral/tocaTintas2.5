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
//  ViewController.h
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 26/08/2026.
//

#import <Cocoa/Cocoa.h>
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import "PreferencesWindowController.h"
#import "ZPOpusDecoder.h"

@interface ViewController : NSViewController <NSApplicationDelegate,NSComboBoxDelegate,NSComboBoxDataSource,NSWindowDelegate,NSTextFieldDelegate>
@property (nonatomic, assign) BOOL isShuffleModeActive;
@property (nonatomic, strong, readonly) ZPOpusDecoder *opusDecoder;
@property (strong) PreferencesWindowController *preferencesWindowController;

- (IBAction)showCustomAboutPanel:(id)sender;
// declara explicitamente o IBAction
- (IBAction)exitPlaylistModeAction:(id)sender;
- (void)handleOpusPlayback:(NSURL *)trackURL;
- (void)selectAirPlayDevice:(NSMenuItem *)menuItem;

@property (nonatomic, strong) NSMutableArray *shuffledTracks;

@property (nonatomic, strong) NSComboBox *songComboBox;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *cleanedToFullFileNameMap;
@property (nonatomic, strong) NSArray<NSString *> *fullFileNamesForMatching;

@property (nonatomic, assign) BOOL isPlaying;  // New property to track playback state

@property (nonatomic, strong) NSArray<NSString *> *displayNames;
//@property (nonatomic, strong) NSArray<NSString *> *fullFileNamesForMatching;

@property (nonatomic, assign) float replayGainValue;
@property (nonatomic, assign) BOOL isStreaming;

@end
