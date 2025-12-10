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
//  ViewController.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 26/08/2024.
//

#include <wavpack/wavpack.h>   // For WAVpack playback
#include <FLAC/metadata.h>   // For FLAC playback
#include <FLAC/stream_decoder.h>   // Also for FLAC playback
#include <opus/opusfile.h>  // For Ogg Opus playback
#include <string.h>

#import <TPCircularBuffer/TPCircularBuffer.h>

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "ViewController.h"   // Objective-C header
#import "M3UPlaylist.h"
#import "ZPOpusDecoder.h"   // Class for Ogg Opus metadata extraction and decoding
#import <CoreAudio/CoreAudio.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>   // This might be needed
#import "HistogramView.h"   // Histogram for the frequency sonogram
#import <AudioToolbox/AudioToolbox.h>   // CoreAudio
#import <UserNotifications/UserNotifications.h>
#import "PreferencesWindowController.h"

#import "ZPAirPlay.h"
#import "ZPAudioCapture.h"
#import "ZPAirPlayStreamer.h"

#define NUM_BUFFERS 3  // Three is typically a good number for real-time audio playback
#define ENABLE_BS2B_BRIDGE 1 // Running bs2b_bridge

// Helper structures and callbacks for reading WavPack data from memory
typedef struct {
    const unsigned char *data;
    size_t size;
    size_t pos;
} MemoryBuffer;

static int read_bytes(void *id, void *data, int bcount) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    size_t remaining = mem->size - mem->pos;
    if (bcount > remaining) bcount = (int)remaining;
    memcpy(data, mem->data + mem->pos, bcount);
    mem->pos += bcount;
    return bcount;
}

static unsigned int get_pos(void *id) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    return (unsigned int)mem->pos;
}

static int set_pos_abs(void *id, unsigned int pos) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    if (pos > mem->size) return -1;
    mem->pos = pos;
    return 0;
}

static int set_pos_rel(void *id, int delta, int mode) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    size_t newpos = mem->pos;
    if (mode == SEEK_CUR) newpos += delta;
    else if (mode == SEEK_END) newpos = mem->size + delta;
    else newpos = delta;
    if (newpos > mem->size) return -1;
    mem->pos = newpos;
    return 0;
}

static int push_back_byte(void *id, int c) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    if (mem->pos == 0) return -1;
    mem->pos--;
    return c;
}

static unsigned int get_length(void *id) {
    MemoryBuffer *mem = (MemoryBuffer *)id;
    return (unsigned int)mem->size;
}

static int can_seek(void *id) {
    (void)id;
    return 1;
}

static WavpackStreamReader memoryReader = {
    read_bytes,
    get_pos,
    set_pos_abs,
    set_pos_rel,
    push_back_byte,
    get_length,
    can_seek
};
@interface ViewController () <AVAudioPlayerDelegate>

@property (nonatomic, strong) NSTextField *playCountLabel;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *trackPlayCounts;

- (void)loadTrackPlayCounts;
- (void)saveTrackPlayCounts;
- (void)schedulePlayCountIncrementForTrack:(NSURL *)trackURL;
- (void)comboBoxSelectionChanged:(NSComboBox *)comboBox;

@property (nonatomic, strong) NSImageView *coverArtView;
@property (nonatomic, strong) NSTextField *artistLabel;
@property (nonatomic, strong) NSTextField *albumLabel;
@property (nonatomic, strong) NSTextField *titleLabel;

@property (weak) IBOutlet NSTextField *trackNumberLabel;
@property (weak) IBOutlet NSMenuItem *openRecentMenuItem;

@property (nonatomic, strong) NSButton *playButton;
@property (nonatomic, strong) NSButton *pauseButton;
@property (nonatomic, strong) NSButton *stopButton;
@property (nonatomic, strong) NSButton *forwardButton;
@property (nonatomic, strong) NSButton *backwardButton;
@property (nonatomic, strong) NSButton *repeatButton;
@property (nonatomic, strong) NSButton *recordButton;

@property (nonatomic, assign) BOOL isRepeatModeActive;
@property (nonatomic, assign) BOOL isCalledFromPlayNextTrack;

@property (nonatomic, strong) NSButton *shuffleButton;

@property (nonatomic, strong) NSProgressIndicator *progressBar;  // Progress bar
@property (nonatomic, strong) HistogramView *histogramView;

@property (nonatomic, strong) ZPOpusDecoder *opusDecoder;

@property (nonatomic, strong) AVAudioPlayer *audioPlayer;

// Prefetching the next track to reduce loading latency
@property (nonatomic, strong) NSData *prefetchedData;
@property (nonatomic, strong) NSURL *prefetchedTrackURL;

// Properties to cache the directory modification date and audio files
@property (nonatomic, strong) NSDate *directoryModificationDate;
@property (nonatomic, strong) NSArray<NSURL *> *cachedAudioFiles;
@property (nonatomic, assign) BOOL isPlaylistModeActive; // Indicates if an M3U8 playlist is loaded

@property (nonatomic, strong) NSArray<NSURL *> *audioFiles;
@property (nonatomic, assign) NSInteger currentTrackIndex;
@property (nonatomic, strong) NSMutableArray<NSURL *> *shuffledAudioFiles; // Shuffled list for shuffle functionality

@property (nonatomic, strong) NSTimer *progressUpdateTimer;  // Timer to update progress bar

@property (strong, nonatomic) NSPanel *aboutPanel; // This makes the panel accessible in your methods
@property (nonatomic, strong) NSTimer *playCountTimer; // Timer to delay play count increment
@property (nonatomic, strong) NSURL *currentTrackURL; // To keep track of the current playing track
@property (nonatomic, strong) NSMutableDictionary<NSURL *, NSURL *> *shuffledToOriginalMap;

@property (strong) NSTask *cavaTask;

@property (nonatomic, strong) ZPAirPlay *airPlayManager;
//@property (nonatomic, strong) NSTimer *refreshTimer;

@property (strong, nonatomic) ZPAudioCapture *audioCapture;
@property (assign, nonatomic) BOOL isRecording;

// AirPlay-related properties
@property (strong) NSButton *airPlayButton;
@property (strong) NSPopover *airPlayPopover;
@property (nonatomic, strong) NSButton *currentlySelectedCheckbox;
@property (nonatomic, strong) NSString *selectedDeviceName; // Store the selected device name
@property (nonatomic, strong) ZPAirPlayStreamer *airPlayStreamer;
@property (nonatomic, assign) BOOL isProgrammaticChange;

// To implement s2b when using headphones
@property (strong, nonatomic) NSTask *bs2bTask;

@end

@implementation ViewController

// Structure to hold the audio playback state
typedef struct {
    AudioQueueRef audioQueue;
    AudioQueueBufferRef buffers[NUM_BUFFERS];
    WavpackContext *wpc;  // WAVPack file context
    OggOpusFile *opusFile;  // Opus file context (added for Opus playback)
    int32_t *sampleBuffer;
    UInt32 bufferSize;
    BOOL isPlaying;
    int numChannels;  // Store the number of channels
    __unsafe_unretained ViewController *client_data;
    double totalDuration;  // Track the duration of the current track
    double sampleRate;  // Add sampleRate to track the sample rate of the Opus file
    BOOL didApplyFadeIn;
} CoreAudioPlaybackState;

CoreAudioPlaybackState playbackState;

- (NSString *)playCountFilePath {
    NSString *appSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *tocaTintasDirectory = [appSupportDirectory stringByAppendingPathComponent:@"tocaTintas"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:tocaTintasDirectory]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:tocaTintasDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error creating Application Support directory: %@", error.localizedDescription);
            #endif
        }
    }
    
    NSString *filePath = [tocaTintasDirectory stringByAppendingPathComponent:@"trackPlayCounts.json"];
    #ifdef DEBUG
    NSLog(@"Saving play counts to path: %@", filePath); // Debug log
    #endif
    return filePath;
}

// Path for storing cached audio file information
- (NSString *)audioCacheFilePath {
    NSString *appSupportDirectory = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    NSString *tocaTintasDirectory = [appSupportDirectory stringByAppendingPathComponent:@"tocaTintas"];

    if (![[NSFileManager defaultManager] fileExistsAtPath:tocaTintasDirectory]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:tocaTintasDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error creating Application Support directory: %@", error.localizedDescription);
            #endif
        }
    }

    return [tocaTintasDirectory stringByAppendingPathComponent:@"audioFilesCache.json"];
}

// Load cached audio files from disk if available
- (void)loadAudioFilesCache {
    NSString *filePath = [self audioCacheFilePath];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    if (!data) {
        return;
    }

    NSError *error = nil;
    NSDictionary *cache = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (error || ![cache isKindOfClass:[NSDictionary class]]) {
        #ifdef DEBUG
        NSLog(@"Failed to read audio cache: %@", error.localizedDescription);
        #endif
        return;
    }

    NSNumber *timestamp = cache[@"modificationDate"];
    NSArray *paths = cache[@"audioFiles"];
    if (timestamp && paths) {
        NSMutableArray<NSURL *> *urls = [NSMutableArray arrayWithCapacity:paths.count];
        for (NSString *path in paths) {
            [urls addObject:[NSURL fileURLWithPath:path]];
        }

        self.directoryModificationDate = [NSDate dateWithTimeIntervalSince1970:timestamp.doubleValue];
        self.cachedAudioFiles = urls;
        self.audioFiles = urls;
    }
}

// Save the current audio file list to disk for faster subsequent launches
- (void)saveAudioFilesCache {
    if (!self.cachedAudioFiles || !self.directoryModificationDate) {
        return;
    }

    NSString *filePath = [self audioCacheFilePath];
    NSMutableArray *paths = [NSMutableArray arrayWithCapacity:self.cachedAudioFiles.count];
    for (NSURL *url in self.cachedAudioFiles) {
        [paths addObject:url.path];
    }

    NSDictionary *cache = @{@"modificationDate": @([self.directoryModificationDate timeIntervalSince1970]),
                            @"audioFiles": paths};

    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:cache options:NSJSONWritingPrettyPrinted error:&error];
    if (!error) {
        [data writeToFile:filePath atomically:YES];
    } else {
        #ifdef DEBUG
        NSLog(@"Failed to save audio cache: %@", error.localizedDescription);
        #endif
    }
}

- (NSString *)replaceSingleQuoteAndSmartQuotes:(NSString *)input {
    // Replacing single quotes with typographic single quote ‘
    NSString *output = [input stringByReplacingOccurrencesOfString:@"'" withString:@"’"];
    
    // Replacing … with typographic ellipsis …
    output = [output stringByReplacingOccurrencesOfString:@"…" withString:@"…"];
 
    // Replace each pair of quotes with “ and ”
    NSUInteger quoteCount = 0;
    NSMutableString *mutableOutput = [output mutableCopy];
    NSRange searchRange = NSMakeRange(0, [mutableOutput length]);
    NSRange foundRange;

    while ((foundRange = [mutableOutput rangeOfString:@"\"" options:0 range:searchRange]).location != NSNotFound) {
        quoteCount++;
        
        // Only replace if there's an even number of quotes
        if (quoteCount % 2 == 0) {
            [mutableOutput replaceCharactersInRange:foundRange withString:@"”"];
        } else {
            [mutableOutput replaceCharactersInRange:foundRange withString:@"“"];
        }

        // Update the search range to continue searching after the current replacement
        searchRange = NSMakeRange(NSMaxRange(foundRange), [mutableOutput length] - NSMaxRange(foundRange));
    }
    
    // Replace hyphens flanked by spaces with m-dash (—)
    NSRegularExpression *spaceHyphenSpaceRegex = [NSRegularExpression regularExpressionWithPattern:@"\\s-\\s" options:0 error:nil];
    mutableOutput = [[spaceHyphenSpaceRegex stringByReplacingMatchesInString:mutableOutput
                                            options:0
                                            range:NSMakeRange(0, mutableOutput.length)
                                            withTemplate:@" — "] mutableCopy];
    
    // Replace hyphens flanked by digits with n-dash (–)
    NSRegularExpression *digitHyphenDigitRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d)-(\\d)" options:0 error:nil];
    mutableOutput = [[digitHyphenDigitRegex stringByReplacingMatchesInString:mutableOutput
                                            options:0
                                            range:NSMakeRange(0, mutableOutput.length)
                                            withTemplate:@"$1–$2"] mutableCopy];
    
    // Replace left-double quotes right-adjacent to a digit with inch symbol (“)
    NSRegularExpression *digitQuoteRegex = [NSRegularExpression regularExpressionWithPattern:@"(\\d)\\u201C" options:0 error:nil];
    mutableOutput = [[digitQuoteRegex stringByReplacingMatchesInString:mutableOutput
                                      options:0
                                      range:NSMakeRange(0, mutableOutput.length)
                                      withTemplate:@"$1\""] mutableCopy];

    // Apply superscript for specific ordinals
    mutableOutput = [[mutableOutput stringByReplacingOccurrencesOfString:@"1st" withString:@"1ˢᵗ"] mutableCopy];
    mutableOutput = [[mutableOutput stringByReplacingOccurrencesOfString:@"2nd" withString:@"2ⁿᵈ"] mutableCopy];
    mutableOutput = [[mutableOutput stringByReplacingOccurrencesOfString:@"3rd" withString:@"3ʳᵈ"] mutableCopy];

    // Apply superscript for "th" only if preceded by any digit
    NSRegularExpression *thOrdinalRegex = [NSRegularExpression regularExpressionWithPattern:@"(?<=\\d)th\\b" options:0 error:nil];
    mutableOutput = [[thOrdinalRegex stringByReplacingMatchesInString:mutableOutput
                                     options:0
                                     range:NSMakeRange(0, mutableOutput.length)
                                     withTemplate:@"ᵗʰ"] mutableCopy];

    return [mutableOutput copy];
}

- (NSString *)decodeMetadataItem:(AVMetadataItem *)metadataItem {
    NSString *decodedString = nil;

    // First, attempt to decode as UTF-8
    decodedString = [NSString stringWithUTF8String:[metadataItem.stringValue UTF8String]];
    
    // If that fails, try ISO-8859-1 (Latin-1)
    if (!decodedString) {
        decodedString = [[NSString alloc] initWithData:[metadataItem.stringValue                               dataUsingEncoding:NSISOLatin1StringEncoding]
            encoding:NSISOLatin1StringEncoding];
    }

    // If necessary, add more fallbacks to other encodings (e.g., UTF-16)
    if (!decodedString) {
        decodedString = [[NSString alloc] initWithData:[metadataItem.stringValue dataUsingEncoding:NSUTF16StringEncoding]
            encoding:NSUTF16StringEncoding];
    }

    // If all attempts fail, return the original string value or a placeholder
    if (!decodedString) {
        decodedString = metadataItem.stringValue ?: @"Unknown";
    }

    return decodedString;
}

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        // Custom initialization if needed
        [self loadTrackPlayCounts];
    }
    return self;
}

- (BOOL)isDarkMode {
    NSAppearance *appearance = [NSAppearance currentDrawingAppearance] ?: [NSApp effectiveAppearance];
    NSString *appearanceName = appearance.name;
    return [appearanceName containsString:@"Dark"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Ignore SIGPIPE signals to prevent termination
    signal(SIGPIPE, SIG_IGN);
    
    // Set the About menu action and target
    NSMenu *appMenu = [[[NSApplication sharedApplication] mainMenu] itemAtIndex:0].submenu;
    NSMenuItem *aboutMenuItem = [appMenu itemAtIndex:0];
    [aboutMenuItem setAction:@selector(showCustomAboutPanel:)];
    [aboutMenuItem setTarget:self];
    [aboutMenuItem setEnabled:YES];
    
    // **[Addition] Initialize the selected device name from User Defaults if available**
    self.selectedDeviceName = [[NSUserDefaults standardUserDefaults] stringForKey:@"SelectedAirPlayDevice"];
    // If no selection was previously saved, you can default to nil
    if (!self.selectedDeviceName) {
        self.selectedDeviceName = nil;
    }

    // Initialize the AirPlay popover
    self.airPlayPopover = [[NSPopover alloc] init];
    self.airPlayPopover.behavior = NSPopoverBehaviorTransient; // Automatically closes when user clicks outside

    // Create the AirPlay button styled like an icon button
    self.airPlayButton = [[NSButton alloc] initWithFrame:NSMakeRect(710, 60, 20, 20)];
    self.airPlayButton.bezelStyle = NSBezelStyleRegularSquare;
    self.airPlayButton.bordered = NO; // No border for a clean look

    // Load the SF Symbol "airplayaudio" icon
    NSImage *airPlayIcon = [NSImage imageWithSystemSymbolName:@"airplay.audio"
                                    accessibilityDescription:@"AirPlay"];

    // **Set the image as a template to allow tinting**
    [airPlayIcon setTemplate:YES];

    self.airPlayButton.image = airPlayIcon;
    self.airPlayButton.imagePosition = NSImageOnly;

    // **Set the contentTintColor based on whether an AirPlay device is selected**
    [self updateAirPlayButtonTint];

    // Set the target and action for the button to show the popover menu
    [self.airPlayButton setTarget:self];
    [self.airPlayButton setAction:@selector(showAirPlayPopover:)];

    // Other initial setup code…
    [self requestNotificationPermission];
    [self loadTrackPlayCounts];
    [self loadAudioFilesCache];
    [self loadAudioFiles];
    [self readFifoDirectly];
    [self setupUI];
    [self createComboBox];
    
    // Add the AirPlay button to the view
    [self.view addSubview:self.airPlayButton];
    
    // Set self as the application's delegate
    [NSApp setDelegate:self];
    
    // Set up the 'Open Recent' menu
    [self setupOpenRecentMenu];
    
    // Handling cava
    //[self startCava];
    [self manageCava];
    
    // Initialize and start the AirPlay manager
    self.airPlayManager = [[ZPAirPlay alloc] init];
    [self.airPlayManager startDiscovery];
    
    // Initialize ZPAudioCapture instance
    self.audioCapture = [[ZPAudioCapture alloc] init];
    self.isRecording = NO;  // Start with recording set to off
    
    // Cleanup lock file on app start
    [ZPAirPlayStreamer cleanupRaopPlayLockFile];

    self.isStreaming = NO; // Initialize as not streaming
}

#pragma mark - ZPAirPlay methods (popover)

//Clean-up when tocaTintas restarts
- (void)initializeAirPlaySettings {
    // Clear selected AirPlay device state
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SelectedAirPlayDevice"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.selectedDeviceName = nil;

    // Unmute built-in speakers
    if (![self setMute:NO]) {
        #ifdef DEBUG
        NSLog(@"[Initialization] Failed to unmute built-in speakers.");
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[Initialization] Default output unmuted.");
        #endif
    }

    // Clear current AirPlay streamer if it exists
    if (self.airPlayStreamer) {
        #ifdef DEBUG
        NSLog(@"[Initialization] Stopping any active AirPlay streamer.");
        #endif
        [self.airPlayStreamer stopStreaming];
        self.airPlayStreamer = nil;
    }
}

- (void)setSelectedDeviceName:(NSString *)selectedDeviceName {
    _selectedDeviceName = selectedDeviceName;
    [self updateAirPlayButtonTint];
}

- (void)updateAirPlayButtonTint {
    if (self.selectedDeviceName) {
        self.airPlayButton.contentTintColor = [NSColor systemRedColor];
    } else {
        self.airPlayButton.contentTintColor = [NSColor labelColor]; // Default color
    }
}

// Method to show the AirPlay popover when the AirPlay button is clicked
- (void)showAirPlayPopover:(NSButton *)sender {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self refreshAirPlayDiscovery];
    });

    self.airPlayPopover.contentViewController = [self createAirPlayPopoverContentController];

    // Force layout update
    [self.airPlayPopover.contentViewController.view layoutSubtreeIfNeeded];
    
    [self.airPlayPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMaxY];
}
    
- (NSViewController *)createAirPlayPopoverContentController {
    NSViewController *popoverContentController = [[NSViewController alloc] init];
    NSStackView *stackView = [[NSStackView alloc] init];
    stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    stackView.spacing = 0;
    stackView.edgeInsets = NSEdgeInsetsMake(10, 10, 10, 10); // Add padding around edges
    stackView.alignment = NSLayoutAttributeLeading;

    // Populate stack view with device names from the file
    [self populateAirPlayDevicesInStackView:stackView];
    
    // Set the stack view as the content of the view controller
    popoverContentController.view = stackView;
    
    // Apply width and height constraints to match contentSize
    [stackView.widthAnchor constraintGreaterThanOrEqualToConstant:140].active = YES;  // Minimum width with padding
    [stackView.heightAnchor constraintGreaterThanOrEqualToConstant:25].active = YES; // Minimum height with padding
    return popoverContentController;
}

- (void)populateAirPlayDevicesInStackView:(NSStackView *)stackView {
    // Construct the path to AirPlay_BonJour.txt
    NSString *supportPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"tocaTintas"];
    NSString *filePath = [supportPath stringByAppendingPathComponent:@"AirPlay_BonJour.txt"];
    
    NSError *error = nil;
    NSString *fileContents = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
    
    // If no devices found or file is empty
    if (error || fileContents.length == 0) {
        NSTextField *noDevicesLabel = [[NSTextField alloc] init];
        
        // Configure italic font
        NSFont *systemFont = [NSFont systemFontOfSize:[NSFont systemFontSize]];
        NSFontDescriptor *fontDescriptor = [systemFont.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontItalicTrait];
        NSFont *italicFont = [NSFont fontWithDescriptor:fontDescriptor size:10]; // Set size here
        
        [noDevicesLabel setFont:italicFont];
        noDevicesLabel.stringValue = NSLocalizedString(@"Searching for AirPlay devices", @"Message displayed when no AirPlay devices are found");
        noDevicesLabel.editable = NO;
        noDevicesLabel.bezeled = NO;
        noDevicesLabel.drawsBackground = NO;
        noDevicesLabel.alignment = NSTextAlignmentCenter;
        noDevicesLabel.translatesAutoresizingMaskIntoConstraints = NO;
        
        // Add to the stack view
        [stackView addArrangedSubview:noDevicesLabel];
        return;
    }

    // Parse the file for device lines
    NSArray *lines = [fileContents componentsSeparatedByString:@"\n"];
    BOOL devicesFound = NO;

    for (NSString *line in lines) {
        if (line.length == 0) continue;
        devicesFound = YES;

        NSString *deviceName = [self cleanDeviceName:line];

        // Horizontal stack for text and checkbox
        NSStackView *deviceStack = [[NSStackView alloc] init];
        deviceStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        deviceStack.distribution = NSStackViewDistributionFillProportionally;
        deviceStack.spacing = 0; // No spacing between elements
        deviceStack.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 0); // No padding

        // Device name label
        NSTextField *deviceLabel = [[NSTextField alloc] init];
        deviceLabel.stringValue = deviceName;
        deviceLabel.editable = NO;
        deviceLabel.bezeled = NO;
        deviceLabel.drawsBackground = NO;
        deviceLabel.alignment = NSTextAlignmentLeft;
        deviceLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [deviceLabel setFont:[NSFont systemFontOfSize:13]];
        [deviceStack addArrangedSubview:deviceLabel];

        // Flexible space to push checkbox to the right
        NSView *flexibleSpace = [[NSView alloc] init];
        [deviceStack addArrangedSubview:flexibleSpace];

        // Checkbox
        NSButton *deviceCheckbox = [NSButton checkboxWithTitle:@"" target:self action:@selector(selectAirPlayDevice:)];
        deviceCheckbox.identifier = deviceName;

        // Set checkbox state
        if ([deviceName isEqualToString:self.selectedDeviceName]) {
            deviceCheckbox.state = NSControlStateValueOn;
            self.currentlySelectedCheckbox = deviceCheckbox;
        } else {
            deviceCheckbox.state = NSControlStateValueOff;
        }

        [deviceStack addArrangedSubview:deviceCheckbox];
        [stackView addArrangedSubview:deviceStack];
    }

    // If no devices were found in the file
    if (!devicesFound) {
        NSTextField *noDevicesLabel = [[NSTextField alloc] init];
        
        // Configure italic font
        NSFont *systemFont = [NSFont systemFontOfSize:[NSFont systemFontSize]];
        NSFontDescriptor *fontDescriptor = [systemFont.fontDescriptor fontDescriptorWithSymbolicTraits:NSFontItalicTrait];
        NSFont *italicFont = [NSFont fontWithDescriptor:fontDescriptor size:10]; // Set size here
        
        [noDevicesLabel setFont:italicFont];
        noDevicesLabel.stringValue = NSLocalizedString(@"Searching for AirPlay devices", @"Message displayed when no AirPlay devices are found");
        noDevicesLabel.editable = NO;
        noDevicesLabel.bezeled = NO;
        noDevicesLabel.drawsBackground = NO;
        noDevicesLabel.alignment = NSTextAlignmentLeft;
        noDevicesLabel.translatesAutoresizingMaskIntoConstraints = NO;

        // Add to the stack view
        [stackView addArrangedSubview:noDevicesLabel];
    }
}

// Helper method to clean the device name string
- (NSString *)cleanDeviceName:(NSString *)line {
    NSString *deviceName = [line componentsSeparatedByString:@"\t"].firstObject;
    deviceName = [deviceName stringByReplacingOccurrencesOfString:@".local" withString:@""];
    deviceName = [deviceName stringByReplacingOccurrencesOfString:@"-" withString:@" "];
    deviceName = [deviceName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return deviceName;
}

// Action method for selecting an AirPlay device
// New version
- (void)selectAirPlayDevice:(NSButton *)button {
    // Check if the change is programmatic to prevent recursive calls
    if (self.isProgrammaticChange) {
        #ifdef DEBUG
        NSLog(@"[Popover selection] Ignoring programmatic change to checkbox: %@", button);
        #endif
        return;
    }

    #ifdef DEBUG
    NSLog(@"[Popover selection] selectAirPlayDevice: called with button: %@", button);
    #endif

    // Uncheck the previously selected checkbox if it's different from the current one
    if (self.currentlySelectedCheckbox && self.currentlySelectedCheckbox != button) {
        self.isProgrammaticChange = YES;
        self.currentlySelectedCheckbox.state = NSControlStateValueOff;
        self.isProgrammaticChange = NO;

        #ifdef DEBUG
        NSLog(@"[Popover selection] Unchecking previously selected checkbox: %@", self.currentlySelectedCheckbox);
        #endif
    }

    // Handle device selection
    if (button.state == NSControlStateValueOn) {
        // Update the reference to the currently selected checkbox
        self.currentlySelectedCheckbox = button;

        // Store the selected device name
        self.selectedDeviceName = button.identifier;

        // Persist the selected device name using NSUserDefaults
        [[NSUserDefaults standardUserDefaults] setObject:self.selectedDeviceName forKey:@"SelectedAirPlayDevice"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // Stop any existing AirPlay streamer
        if (self.airPlayStreamer) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Stopping existing AirPlay streamer.");
            #endif
            [self.airPlayStreamer stopStreaming];
            self.airPlayStreamer = nil;
        }

        // Retrieve the device name from the button's identifier
        NSString *deviceName = button.identifier;
        #ifdef DEBUG
        NSLog(@"[Popover selection] Retrieved device name: %@", deviceName);
        #endif

        if (deviceName == nil) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Device name not found for button: %@", button);
            #endif
            return;
        }

        // Retrieve the IP and port for this device name
        NSDictionary *deviceInfo = [self deviceInfoForDeviceName:deviceName];
        NSString *ipAddress = deviceInfo[@"ip"];
        NSString *port = deviceInfo[@"port"];

        #ifdef DEBUG
        NSLog(@"[Popover selection] Device info: %@, IP: %@, Port: %@", deviceName, ipAddress, port);
        #endif

        // Validate the IP and port
        if (ipAddress == nil || port == nil || [ipAddress isEqualToString:@"N/A"] || [port isEqualToString:@"N/A"]) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Invalid IP or port for device: %@", deviceName);
            #endif
            return;
        }

        // Initialize and start the AirPlay streamer
        #ifdef DEBUG
        NSLog(@"[Popover selection] Initializing AirPlay streamer with IP: %@, Port: %@", ipAddress, port);
        #endif
        self.airPlayStreamer = [[ZPAirPlayStreamer alloc] initWithIPAddress:ipAddress port:port replayGainValue:self.replayGainValue];
        [self.airPlayStreamer startStreaming];
        #ifdef DEBUG
        NSLog(@"[Popover selection] AirPlay streaming started.");
        #endif

        // Mute the built-in speakers
        if (![self setMute:YES]) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Failed to mute built-in speakers.");
            #endif
        }
    }
    // Handle device deselection
    else if (button.state == NSControlStateValueOff) {
        // Remove the selected device from NSUserDefaults first so the
        // termination handler in ZPAirPlayStreamer won't restart streaming.
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"SelectedAirPlayDevice"];
        [[NSUserDefaults standardUserDefaults] synchronize];

        // Stop the AirPlay streamer if it exists
        if (self.airPlayStreamer) {
            #ifdef DEBUG
            NSLog(@"[Popover selection] Stopping AirPlay streamer.");
            #endif
            // Set streaming state to NO to prevent restart
            self.isStreaming = NO;
            [self.airPlayStreamer stopStreaming];
            self.airPlayStreamer = nil;
        }

        // Clear the reference to the currently selected checkbox and device name
        self.currentlySelectedCheckbox = nil;
        self.selectedDeviceName = nil;

        // Unmute the built-in speakers
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self setMute:NO]) {
                #ifdef DEBUG
                NSLog(@"[Popover selection] Failed to unmute built-in speakers.");
                #endif
            } else {
                #ifdef DEBUG
                NSLog(@"[Popover selection] Successfully unmuted built-in speakers.");
                #endif
            }
        });
    }
}

- (NSDictionary *)deviceInfoForDeviceName:(NSString *)deviceName {
    // Construct the path to AirPlay_BonJour.txt
    NSString *supportPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"tocaTintas"];
    NSString *filePath = [supportPath stringByAppendingPathComponent:@"AirPlay_BonJour.txt"];

    NSError *error = nil;
    NSString *fileContents = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error reading file: %@", error.localizedDescription);
        #endif
        return nil;
    }
    NSArray *lines = [fileContents componentsSeparatedByString:@"\n"];
    for (NSString *line in lines) {
        if (line.length == 0) continue;

        NSArray *components = [line componentsSeparatedByString:@"\t"];
        if (components.count >= 4) {
            NSString *hostname = components[0];
            NSString *ip = components[2];
            NSString *port = components[3];

            NSString *cleanedDeviceName = [self cleanDeviceName:hostname];

            if ([cleanedDeviceName isEqualToString:deviceName]) {
                return @{@"deviceName": deviceName, @"ip": ip, @"port": port};
            }
        }
    }
    return nil;
}

- (void)refreshAirPlayDiscovery {
    #ifdef DEBUG
    NSLog(@"Refreshing AirPlay discovery…");
    #endif

    // Delete AirPlay_BonJour.txt if it exists
    NSString *bonjourFilePath = self.airPlayManager.bonjourFilePath;
    if ([[NSFileManager defaultManager] fileExistsAtPath:bonjourFilePath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:bonjourFilePath error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error deleting AirPlay_BonJour.txt: %@", error);
            #endif
        } else {
            #ifdef DEBUG
            NSLog(@"AirPlay_BonJour.txt deleted successfully.");
            #endif
        }
    }

    // Clear cached addresses to force Bonjour lookups
    [self.airPlayManager.capturedAddresses removeAllObjects];

    // Restart the AirPlay discovery
    [self.airPlayManager startDiscovery];
}

- (BOOL)setMute:(BOOL)mute {
    // Path to the audio_stuff_info executable in the Resources directory
    NSString *audioStuffPath = [[NSBundle mainBundle] pathForResource:@"ListAudioDevices" ofType:nil];
    
    if (!audioStuffPath) {
        #ifdef DEBUG
        NSLog(@"[Mute] Failed to locate audio_stuff_info executable in Resources.");
        #endif
        return NO;
    }

    // Run the audio_stuff_info executable
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = audioStuffPath;
    
    NSPipe *outputPipe = [NSPipe pipe];
    task.standardOutput = outputPipe;
    task.standardError = outputPipe;

    NSFileHandle *fileHandle = [outputPipe fileHandleForReading];
    
    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        #ifdef DEBUG
        NSLog(@"[Mute] Failed to execute audio_stuff_info: %@", exception.reason);
        #endif
        return NO;
    }
    
    // Read and parse the output
    NSData *outputData = [fileHandle readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
    
    if (!output || [output length] == 0) {
        #ifdef DEBUG
        NSLog(@"[Mute] No output from audio_stuff_info.");
        #endif
        return NO;
    }
    
    // Search for the line containing "Built-in Output" or "Saída integrada"
    __block AudioObjectID targetDevice = 0;
    NSArray<NSString *> *lines = [output componentsSeparatedByString:@"\n"];
    [lines enumerateObjectsUsingBlock:^(NSString *line, NSUInteger idx, BOOL *stop) {
        #ifdef DEBUG
        NSLog(@"[Mute] Processing line: %@", line);
        #endif

        // Check if the line contains "Built-in Output" or "Saída integrada"
        if ([line containsString:@"MacBook Pro Speakers"] || [line containsString:@"Saída integrada"] || [line containsString:@"Colunas (MacBook Pro)"]) {
            // Extract the ID as the digits at the end of the line
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"(\\d+)$" options:0 error:nil];
            NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (match) {
                NSString *idString = [line substringWithRange:[match rangeAtIndex:1]];
                targetDevice = (AudioObjectID)[idString intValue];
                *stop = YES; // Exit loop once the target device is found
            }
        }
    }];

    if (targetDevice == 0) {
        #ifdef DEBUG
        NSLog(@"[Mute] Could not find device ID for 'MacBook Pro Speakers'.");
        #endif
        return NO;
    }

    // Define the property address for muting
    AudioObjectPropertyAddress propertyAddress = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        0 // Use channel 0 for master mute
    };
    
    // Set the mute state: 1 for mute, 0 for unmute
    UInt32 isMuted = mute ? 1 : 0;
    
    // Attempt to set the mute state on the target device
    OSStatus status = AudioObjectSetPropertyData(targetDevice, &propertyAddress, 0, NULL, sizeof(isMuted), &isMuted);
    
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"[Mute] Failed to %@ mute device ID %u. OSStatus: %d", mute ? @"mute" : @"unmute", targetDevice, (int)status);
        #endif
        return NO;
    }
    #ifdef DEBUG
    NSLog(@"[Mute] Successfully %@d device ID %u.", mute ? @"mute" : @"unmute", targetDevice);
    #endif
    return YES;
}

#pragma mark - Need organizing:

// Helper method to detect headphones for s2b
- (BOOL)headphonesAreConnected {
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject,
                                                 &addr,
                                                 0,
                                                 NULL,
                                                 &size,
                                                 &deviceID);
    if (status != noErr || deviceID == kAudioObjectUnknown) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Could not get default output device (status = %d).", (int)status);
        #endif
        return NO;
    }

    CFStringRef deviceNameRef = NULL;
    size = sizeof(deviceNameRef);
    AudioObjectPropertyAddress nameAddr = {
        kAudioDevicePropertyDeviceNameCFString,
        kAudioObjectPropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };

    status = AudioObjectGetPropertyData(deviceID,
                                        &nameAddr,
                                        0,
                                        NULL,
                                        &size,
                                        &deviceNameRef);
    if (status != noErr || !deviceNameRef) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Could not get output device name (status = %d).", (int)status);
        #endif
        return NO;
    }

    NSString *deviceName = CFBridgingRelease(deviceNameRef);

    // Aqui podes refinar o critério; deixo um teste simples:
    NSRange range = [deviceName rangeOfString:@"headphones"
                                      options:NSCaseInsensitiveSearch];
    BOOL isHeadphones = (range.location != NSNotFound);

    #ifdef DEBUG
    NSLog(@"[bs2b] Default output device: %@ (headphones = %@)",
          deviceName, isHeadphones ? @"YES" : @"NO");
    #endif

    return isHeadphones;
}

// Implement the application:openFile: method
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename {
    NSURL *fileURL = [NSURL fileURLWithPath:filename];
    [self loadM3UPlaylist:fileURL];
    return YES;
}

- (void)recordAudio {
    if (self.isRecording) {
        // Stop recording
        [self.audioCapture stopCapturingAudio];
        #ifdef DEBUG
        NSLog(@"[Audio recording] Audio recording stopped.");
        #endif
        self.isRecording = NO;
    } else {
        // Start recording
        [self.audioCapture startCapturingAudio];
        #ifdef DEBUG
        NSLog(@"[Audio recording] Audio recording started.");
        #endif
        self.isRecording = YES;
    }
    [self updateRecordButtonAppearance:self.isRecording];
}

- (void)startCava {
    // Request microphone permissions (macOS)
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
        if (granted) {
            // Proceed to start cava on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                // Initialize the NSTask
                self.cavaTask = [[NSTask alloc] init];

                // Path to the cava executable
                NSString *cavaPath = [[NSBundle mainBundle] pathForResource:@"cava" ofType:@""];

                // Ensure the cava executable exists
                if (![[NSFileManager defaultManager] isExecutableFileAtPath:cavaPath]) {
                    #ifdef DEBUG
                    NSLog(@"cava executable not found at path: %@", cavaPath);
                    #endif
                    return;
                }

                // Get the path to the 'cava' binary directory
                NSString *cavaDirectory = [[[NSBundle mainBundle] pathForResource:@"cava" ofType:@""] stringByDeletingLastPathComponent];

                // Append the config file name to the directory path
                NSString *configPath = [cavaDirectory stringByAppendingPathComponent:@"config_fifo"];

                // Update the arguments array to use the config file path
                NSArray *arguments = @[@"-p", configPath];

                // Log the arguments to verify
                #ifdef DEBUG
                NSLog(@"Launching cava with arguments: %@", arguments);
                #endif

                // Set the launch path and arguments
                self.cavaTask.launchPath = cavaPath;
                self.cavaTask.arguments = arguments;

                // Set environment variables
                self.cavaTask.environment = [[NSProcessInfo processInfo] environment];

                // Set current directory
                self.cavaTask.currentDirectoryPath = @"/var/tmp";

                // Set standard input to null device
                self.cavaTask.standardInput = [NSFileHandle fileHandleWithNullDevice];

                // Capture standard error to log any error messages
                NSPipe *errorPipe = [NSPipe pipe];
                self.cavaTask.standardError = errorPipe;
                [[errorPipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *fileHandle) {
                    NSData *data = [fileHandle availableData];
                    if (data.length > 0) {
                        #ifdef DEBUG
                        NSString *errorOutput = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        NSLog(@"cava error: %@", errorOutput);
                        #endif
                    }
                }];

                // Optionally, capture standard output if needed
                NSPipe *outputPipe = [NSPipe pipe];
                self.cavaTask.standardOutput = outputPipe;
                [[outputPipe fileHandleForReading] setReadabilityHandler:^(NSFileHandle *fileHandle) {
                    NSData *data = [fileHandle availableData];
                    if (data.length > 0) {
                        #ifdef DEBUG
                        NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                        NSLog(@"cava output: %@", output);
                        #endif
                    }
                }];

                // Launch the task
                @try {
                    [self.cavaTask launch];
                    #ifdef DEBUG
                    NSLog(@"cava started with PID: %d", self.cavaTask.processIdentifier);
                    #endif
                } @catch (NSException *exception) {
                    #ifdef DEBUG
                    NSLog(@"Failed to launch cava: %@", exception.reason);
                    #endif
                }
            });
        } else {
            #ifdef DEBUG
            NSLog(@"Microphone access denied.");
            #endif
        }
    }];
}

- (void)manageCava {
    // Step 1: Terminate any extraneous instances of cava
    #ifdef DEBUG
    NSLog(@"Terminating any existing cava instances…");
    #endif
    NSString *killCommand = @"pkill -f cava";
    system([killCommand UTF8String]);

    // Step 2: Check if cava is already running
    #ifdef DEBUG
    NSLog(@"Checking if cava is running…");
    #endif
    NSString *checkCommand = @"pgrep -f cava";
    FILE *pipe = popen([checkCommand UTF8String], "r");
    if (!pipe) {
        #ifdef DEBUG
        NSLog(@"Failed to check cava status.");
        #endif
        return;
    }
    char buffer[128]; // This buffer is outside the block
    BOOL isRunning = fgets(buffer, sizeof(buffer), pipe) != NULL;
    pclose(pipe);

    if (isRunning) {
        #ifdef DEBUG
        NSLog(@"Cava is already running.");
        #endif
        // Proceed to set up health check timer
    } else {
        // Step 3: Start cava
        #ifdef DEBUG
        NSLog(@"Cava is not running. Starting it…");
        #endif
        [self startCava];
    }

    // Step 4: Set up periodic health checks
    #ifdef DEBUG
    NSLog(@"Setting up periodic health checks…");
    #endif
    static NSTimer *healthCheckTimer = nil;
    if (healthCheckTimer) {
        [healthCheckTimer invalidate]; // Ensure any existing timer is stopped
    }

    healthCheckTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                        repeats:YES
                                                          block:^(NSTimer * _Nonnull timer) {
        // Inline health check logic
        #ifdef DEBUG
        NSLog(@"Performing health check for cava…");
        #endif
        char *dynamicBuffer = (char *)malloc(128); // Dynamically allocate buffer
        if (!dynamicBuffer) {
            #ifdef DEBUG
            NSLog(@"Failed to allocate memory for buffer.");
            #endif
            return;
        }
        FILE *innerPipe = popen([checkCommand UTF8String], "r");
        if (!innerPipe) {
            #ifdef DEBUG
            NSLog(@"Failed to check cava status during health check.");
            #endif
            free(dynamicBuffer); // Free allocated memory
            return;
        }
        BOOL isRunning = fgets(dynamicBuffer, 128, innerPipe) != NULL;
        pclose(innerPipe);
        free(dynamicBuffer); // Free allocated memory

        if (!isRunning) {
            #ifdef DEBUG
            NSLog(@"Cava is not running. Restarting…");
            #endif
            [self startCava];
        } else {
            #ifdef DEBUG
            NSLog(@"Cava is running normally.");
            #endif
        }
    }];
}

- (void)startBs2bIfNeeded {
#if ENABLE_BS2B_BRIDGE
    // Já está a correr?
    if (self.bs2bTask && self.bs2bTask.isRunning) {
        return;
    }

    // Só corre se houver auscultadores
    if (![self headphonesAreConnected]) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Headphones not detected; not starting bs2b_bridge.");
        #endif
        return;
    }

    NSString *bridgePath = [[NSBundle mainBundle] pathForResource:@"bs2b_bridge" ofType:nil];
    if (!bridgePath) {
        #ifdef DEBUG
        NSLog(@"[bs2b] bs2b_bridge not found in app bundle.");
        #endif
        return;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = bridgePath;

    // To choose specific options:
    // task.arguments = @[@"--perfil", @"cmoy"];
    task.arguments = @[@"--silencioso"];  // or any other default

    // To avoid spam in stdout, redirect to /dev/null
    task.standardOutput = [NSPipe pipe];
    task.standardError  = [NSPipe pipe];

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (weakSelf.bs2bTask == finishedTask) {
                weakSelf.bs2bTask = nil;
            }
            #ifdef DEBUG
            NSLog(@"[bs2b] bs2b_bridge terminated (exitStatus=%d).",
                  finishedTask.terminationStatus);
            #endif
        });
    };

    @try {
        [task launch];
        self.bs2bTask = task;
        #ifdef DEBUG
        NSLog(@"[bs2b] bs2b_bridge started at path %@", bridgePath);
        #endif
    } @catch (NSException *exception) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Failed to launch bs2b_bridge: %@", exception);
        #endif
        self.bs2bTask = nil;
    }
#endif
}

- (void)stopBs2bIfRunning {
#if ENABLE_BS2B_BRIDGE
    if (self.bs2bTask && self.bs2bTask.isRunning) {
        #ifdef DEBUG
        NSLog(@"[bs2b] Terminating bs2b_bridge…");
        #endif
        [self.bs2bTask terminate];

        // To be sure of an immediate cleanup:
        @try {
            [self.bs2bTask waitUntilExit];
        } @catch (NSException *exception) {
            #ifdef DEBUG
            NSLog(@"[bs2b] Exception waiting for bs2b_bridge to exit: %@", exception);
            #endif
        }
    }
    self.bs2bTask = nil;
#endif
}

- (void)setupOpenRecentMenu {
    // Get the recent documents URLs from NSDocumentController
    NSArray<NSURL *> *recentDocumentsURLs = [[NSDocumentController sharedDocumentController] recentDocumentURLs];

    // Create a new menu for recent documents
    NSMenu *recentDocumentsMenu = [[NSMenu alloc] initWithTitle:@"Open Recent"];

    for (NSURL *documentURL in recentDocumentsURLs) {
        NSString *documentTitle = [documentURL lastPathComponent];
        NSMenuItem *menuItem = [[NSMenuItem alloc] initWithTitle:documentTitle
                                                          action:@selector(openRecentDocument:)
                                                   keyEquivalent:@""];
        [menuItem setRepresentedObject:documentURL];
        [recentDocumentsMenu addItem:menuItem];
    }

    // Set the submenu of the 'Open Recent' menu item
    [self.openRecentMenuItem setSubmenu:recentDocumentsMenu];
}

- (void)openRecentDocument:(NSMenuItem *)menuItem {
    NSURL *documentURL = [menuItem representedObject];
    
    // Ensure documentURL is not nil
    if (documentURL) {
        [[NSDocumentController sharedDocumentController] openDocumentWithContentsOfURL:documentURL
                                                                               display:YES
                                                                     completionHandler:^(NSDocument * _Nullable document, BOOL documentWasAlreadyOpen, NSError * _Nullable error) {
            if (error) {
                // Handle the error, e.g., show an alert to the user
                NSAlert *alert = [[NSAlert alloc] init];
                alert.messageText = @"Unable to Open Document";
                alert.informativeText = [NSString stringWithFormat:@"An error occurred while opening the document: %@", error.localizedDescription];
                [alert addButtonWithTitle:@"OK"];
                [alert runModal];
            } else {
                // Optionally perform additional actions if needed
                #ifdef DEBUG
                NSLog(@"Document opened successfully.");
                #endif
            }
        }];
    } else {
        // Handle the case where the documentURL is nil
        #ifdef DEBUG
        NSLog(@"Error: documentURL is nil.");
        #endif
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Unable to Open Document";
        alert.informativeText = @"The selected document could not be opened because the file URL is invalid.";
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
    // Access the Application menu (first menu item in the main menu)
    NSMenu *appMenu = [[[NSApplication sharedApplication] mainMenu] itemAtIndex:0].submenu;
    
    // Find the About menu item within the Application menu
    NSMenuItem *aboutMenuItem = [appMenu itemWithTitle:@"About"];
    
    if (aboutMenuItem) {
        [aboutMenuItem setAction:@selector(showCustomAboutPanel:)];
        [aboutMenuItem setTarget:self];
        [aboutMenuItem setEnabled:YES];
    }
    [self initializeAirPlaySettings];
}

- (NSString *)localizedVersionStringWithVersion:(NSString *)version {
    NSString *localizedString = NSLocalizedStringFromTable(@"Version %@ is installed.", @"Localizable", @"Version label with version number");
    return [NSString stringWithFormat:localizedString, version];
}

- (IBAction)showCustomAboutPanel:(id)sender {
    if (!self.aboutPanel) {
        NSRect windowFrame = NSMakeRect(0, 0, 250, 300);  // Updated window width to 250, height remains 300
        self.aboutPanel = [[NSPanel alloc] initWithContentRect:windowFrame
                                                     styleMask:(NSWindowStyleMaskTitled |
                                                                NSWindowStyleMaskClosable)
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
        NSString *localizedTitle = NSLocalizedStringFromTable(@"About tocaTintas", @"Localizable", @"Window title for the About panel");
        [self.aboutPanel setTitle:localizedTitle];
        [self.aboutPanel center];
        self.aboutPanel.delegate = self; // Set delegate

        // Calculate the center of the window
        CGFloat panelHeight = NSHeight(windowFrame);
        CGFloat totalContentHeight = 300; // Approximate total height of content

        CGFloat yOffset = (panelHeight - totalContentHeight) / 2;

        // 1. App Icon (Centered)
        NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(75, yOffset + 180, 100, 100)]; // Adjusted x-position for smaller width
        NSImage *appIcon = [NSImage imageNamed:NSImageNameApplicationIcon];
        [iconView setImage:appIcon];
        [iconView setImageScaling:NSImageScaleProportionallyUpOrDown];
        [[self.aboutPanel contentView] addSubview:iconView];

        // 2. App Name (Centered)
        NSTextField *appNameLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(25, yOffset + 150, 200, 20)]; // Adjusted x-position for smaller width
        [appNameLabel setStringValue:@"tocaTintas"];
        [appNameLabel setBezeled:NO];
        [appNameLabel setDrawsBackground:NO];
        [appNameLabel setEditable:NO];
        [appNameLabel setSelectable:NO];
        [appNameLabel setFont:[NSFont boldSystemFontOfSize:16]];
        [appNameLabel setAlignment:NSTextAlignmentCenter];
        [[self.aboutPanel contentView] addSubview:appNameLabel];

        // 3. Version (Centered)
        NSTextField *versionLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(25, yOffset + 120, 200, 20)]; // Adjusted x-position for smaller width
        
        // Localize the version string
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        NSString *localizedVersion = [self localizedVersionStringWithVersion:version];
        [versionLabel setStringValue:localizedVersion];
        
        [versionLabel setBezeled:NO];
        [versionLabel setDrawsBackground:NO];
        [versionLabel setEditable:NO];
        [versionLabel setSelectable:NO];
        [versionLabel setFont:[NSFont systemFontOfSize:10]];
        [versionLabel setAlignment:NSTextAlignmentCenter];
        [[self.aboutPanel contentView] addSubview:versionLabel];

        // 4. Copyright / Credits (Centered)
        NSTextField *creditsLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(0, yOffset + 50, 250, 60)]; // Adjusted width to match the window size
        [creditsLabel setStringValue:@"© 2025 Zé Pedro do Amaral"];
        [creditsLabel setBezeled:NO];
        [creditsLabel setDrawsBackground:NO];
        [creditsLabel setEditable:NO];
        [creditsLabel setSelectable:NO];
        [creditsLabel setAlignment:NSTextAlignmentCenter];
        [creditsLabel setFont:[NSFont systemFontOfSize:12]];
        [[self.aboutPanel contentView] addSubview:creditsLabel];

        // 5. Close Button (Centered)
        NSButton *closeButton = [[NSButton alloc] initWithFrame:NSMakeRect(75, yOffset + 20, 100, 30)]; // Adjusted x-position for smaller width

        // Localize the button title
        NSString *localizedCloseTitle = NSLocalizedStringFromTable(@"Close", @"Localizable", @"Close button label");
        [closeButton setTitle:localizedCloseTitle];
        [closeButton setButtonType:NSButtonTypeMomentaryPushIn];
        [closeButton setBezelStyle:NSBezelStyleRounded];
        [closeButton setTarget:self];
        [closeButton setAction:@selector(closeAboutPanel:)];
        [[self.aboutPanel contentView] addSubview:closeButton];
    }

    // Show the About panel
    [self.aboutPanel makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES]; // Bring the app to the foreground
}

- (void)closeAboutPanel:(id)sender {
    [self.aboutPanel orderOut:nil]; // Order the panel out, keeping it in memory
}

- (void)viewDidAppear {
    [super viewDidAppear];

    // Log the current responder chain to check if the ViewController is in the chain
    NSResponder *responder = [self.view.window firstResponder];
    while (responder) {
        #ifdef DEBUG
        NSLog(@"Responder: %@", responder);
        #endif
        responder = [responder nextResponder];
    }
}

- (IBAction)openPreferences:(id)sender {
    // Check if the preferences window is already open or created
    if (!self.preferencesWindowController) {
        // Load the Preferences window from the storyboard
        NSStoryboard *storyboard = [NSStoryboard storyboardWithName:@"Main" bundle:nil];
        
        // Instantiate the window controller using the identifier you assigned in the storyboard
        self.preferencesWindowController = [storyboard instantiateControllerWithIdentifier:@"PreferencesWindowController1"];
    }
    
    // Show the Preferences window
    [self.preferencesWindowController showWindow:self];
}

- (void)saveSongsDirectoryPath:(NSString *)path {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:path forKey:@"songsDirectoryPath"];
    [defaults synchronize];  // Save the path to user defaults

    // Debug log to confirm the path is saved correctly
    #ifdef DEBUG
    NSLog(@"Saved songs directory path: %@", path);
    #endif
}

- (NSString *)loadSongsDirectoryPath {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSString *savedPath = [defaults stringForKey:@"songsDirectoryPath"];
    
    // Log to ensure the path is loaded correctly
    #ifdef DEBUG
    NSLog(@"Loaded songs directory path: %@", savedPath);
    #endif
    // If no custom path is set, return the default path
    if (savedPath == nil) {
        savedPath = @"/Users/amaral/Downloads/CDs";  // Default path
    }
    
    return savedPath;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:@"SongsDirectoryPathChanged"
                                                  object:nil];
    // Invalidate the refresh timer to stop it from firing after the view controller is deallocated
    //[self.refreshTimer invalidate];
    
    // Remove any observers added by this instance of ViewController
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// Method to handle the directory path change notification
- (void)handleDirectoryPathChange:(NSNotification *)notification {
    NSString *newPath = notification.userInfo[@"newPath"];
    #ifdef DEBUG
    NSLog(@"New Path from Notification: %@", newPath);
    #endif

    // Save the new path
    [self saveSongsDirectoryPath:newPath];

    // Preserve the currently playing track's path before updating any state
    NSString *currentTrackPath = nil;
    if (self.currentTrackIndex >= 0) {
        NSURL *currentTrackURL = nil;
        if (self.isShuffleModeActive && self.shuffledTracks.count > self.currentTrackIndex) {
            currentTrackURL = self.shuffledTracks[self.currentTrackIndex];
        } else if (self.audioFiles.count > self.currentTrackIndex) {
            currentTrackURL = self.audioFiles[self.currentTrackIndex];
        }
        if (currentTrackURL) {
            currentTrackPath = [currentTrackURL.path stringByStandardizingPath];
        }
    }

    // Clear cached audio files and modification date
    self.cachedAudioFiles = nil;
    self.directoryModificationDate = nil;

    // Exit playlist mode after preserving the current track
    self.isPlaylistModeActive = NO;

    // Reload the audio files from the new directory
    [self loadAudioFiles];  // This will also refresh the combo box

    // Reinitialize shuffled tracks if shuffle mode is active
    if (self.isShuffleModeActive) {
        [self initializeShuffledTrackList];
    }

    // Update combo box selection
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createComboBox];
        NSInteger selectedIndex = self.currentTrackIndex + 1; // Adjust for placeholder
        if (selectedIndex >= 0 && selectedIndex < self.songComboBox.numberOfItems) {
            [self.songComboBox selectItemAtIndex:selectedIndex];
        } else {
            [self.songComboBox selectItemAtIndex:0]; // Placeholder
        }
    });
    // Optionally start playback from the first track
    //if (self.audioFiles.count > 0) {
        //[self playAudio];
    //}
}

- (void)validatePlaylistFiles {
    NSMutableArray<NSURL *> *validFiles = [NSMutableArray array];
    for (NSURL *fileURL in self.audioFiles) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:fileURL.path]) {
            [validFiles addObject:fileURL];
        } else {
            #ifdef DEBUG
            NSLog(@"File not found: %@", fileURL.path);
            #endif
        }
    }

    if (validFiles.count == 0) {
        // All files have been removed, exit playlist mode
        self.isPlaylistModeActive = NO;
        self.currentTrackIndex = 0;
        self.audioFiles = @[];
        [self loadAudioFiles]; // Load from directory
    } else if (validFiles.count < self.audioFiles.count) {
        // Some files have been removed
        self.audioFiles = [validFiles copy];
        // Adjust currentTrackIndex if necessary
        if (self.currentTrackIndex >= self.audioFiles.count) {
            self.currentTrackIndex = self.audioFiles.count - 1;
        }
    }
}

#pragma mark - Play count

// Play count methods
// New method to handle play count increment after the timer fires
- (void)handlePlayCountIncrement:(NSTimer *)timer {
    NSURL *trackURL = (NSURL *)timer.userInfo;
    
    // Ensure the track is still the one being played, and map it to its original counterpart
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;
    #ifdef DEBUG
    NSURL *mappedURL = self.shuffledToOriginalMap[trackURL];

    NSLog(@"Mapped URL: %@", mappedURL);
    NSLog(@"Track URL: %@", trackURL);
    NSLog(@"Original Track URL: %@", originalTrackURL);
    #endif

    // Increment the play count and update the label for the original track URL
    [self incrementPlayCountForTrack:originalTrackURL];
    [self updatePlayCountLabelForTrack:originalTrackURL];

    // Clear the timer
    self.playCountTimer = nil;
}

// Counting playback times
- (void)incrementPlayCountForTrack:(NSURL *)trackURL {
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;
    NSString *trackPath = originalTrackURL.path;
    
    NSNumber *currentCount = [self.trackPlayCounts objectForKey:trackPath];
    
    if (currentCount) {
        [self.trackPlayCounts setObject:@(currentCount.integerValue + 1) forKey:trackPath];
    } else {
        [self.trackPlayCounts setObject:@1 forKey:trackPath];
    }
    
    // Save play count changes
    [self saveTrackPlayCounts];
    
    // Always update the play count label, even if repeat is toggled off
    [self updatePlayCountLabelForTrack:trackURL];
}

- (void)schedulePlayCountIncrementForTrack:(NSURL *)trackURL {
    // Invalidate any existing timer
    if (self.playCountTimer) {
        [self.playCountTimer invalidate];
        self.playCountTimer = nil;
    }

    // Map the shuffled track URL to the original if necessary
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;

    // Start a new timer to increment the play count after 5 seconds
    self.playCountTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                   target:self
                                   selector:@selector(handlePlayCountIncrement:)
                                   userInfo:originalTrackURL
                                   repeats:NO];
}

- (void)updatePlayCountLabelForTrack:(NSURL *)trackURL {
    // Map the shuffled track URL to the original if necessary
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;

    // In order to modify playCount inside the block, declare it with __block
    __block NSNumber *playCount = [self.trackPlayCounts objectForKey:originalTrackURL.path];

    // Perform the task in a background queue to avoid blocking the main thread
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        #ifdef DEBUG
        NSLog(@"Mapped originalTrackURL2: %@", originalTrackURL);
        NSLog(@"Mapped trackURL2: %@", trackURL);
        #endif

        // Ensure UI updates are performed on the main thread after a 5-second delay
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{

            // Now update the UI based on the updated play count
            if (!playCount || playCount.intValue <= 1) {
                [self.playCountLabel setStringValue:NSLocalizedString(@"Played 1 time", @"Play count label when played at least once")];
            } else {
                [self.playCountLabel setStringValue:[NSString stringWithFormat:NSLocalizedString(@"Played %@ times", @"Play count label when played more than once"), playCount]];
            }
        });
        // Call generateNowPlayingPage to update the “Now Playing” webpage
        [self generateNowPlayingPage];
    });
}

- (void)loadTrackPlayCounts {
    NSString *filePath = [self playCountFilePath];
    NSData *data = [NSData dataWithContentsOfFile:filePath];
    
    if (data) {
        NSError *error = nil;
        NSDictionary *savedCounts = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"Error deserializing JSON: %@", error.localizedDescription);
            #endif
        } else {
            self.trackPlayCounts = [savedCounts mutableCopy];
        }
    } else {
        self.trackPlayCounts = [NSMutableDictionary dictionary];
    }
}

- (void)saveTrackPlayCounts {
    NSString *filePath = [self playCountFilePath];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.trackPlayCounts options:NSJSONWritingPrettyPrinted error:&error];
    
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error serializing play counts to JSON: %@", error.localizedDescription);
        #endif
    } else {
        BOOL success = [data writeToFile:filePath atomically:YES];
        if (!success) {
            #ifdef DEBUG
            NSLog(@"Failed to write play counts to file: %@", filePath);
            #endif
        } else {
            #ifdef DEBUG
            NSLog(@"Play counts successfully saved to %@", filePath);
            #endif
        }
    }
}

// M3U Support
- (IBAction)openM3UFile:(id)sender {
    // Create an open panel for selecting the M3U file
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    
    // Set allowed content types using UTType
    if (@available(macOS 11.0, *)) {
        openPanel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"m3u"]];
    } else {
        // Fallback: Earlier macOS versions do not support UTType, but this case would not happen because macOS 12 supports only allowedContentTypes
        #ifdef DEBUG
        NSLog(@"macOS version not supported. Requires macOS 11.0 or later.");
        #endif
    }

    // Present the open panel to the user
    [openPanel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            // Get the selected file URL
            NSURL *fileURL = [openPanel URL];
            
            if (fileURL) {
                // Call your loadM3UPlaylist method with the selected file
                [self loadM3UPlaylist:fileURL];
            }
        }
    }];
}

- (void)loadM3UPlaylist:(NSURL *)playlistURL {
    // Load the playlist
    NSArray<NSString *> *playlistTracks = [M3UPlaylist loadFromFile:playlistURL.path];
    if (!playlistTracks || playlistTracks.count == 0) {
        #ifdef DEBUG
        NSLog(@"[M3U Playlist] Failed to load M3U playlist or the playlist is empty.");
        #endif
        return;
    }

    // Convert the string paths to NSURLs
    NSMutableArray<NSURL *> *trackURLs = [NSMutableArray array];
    for (NSString *trackPath in playlistTracks) {
        NSURL *trackURL = [NSURL fileURLWithPath:trackPath];
        [trackURLs addObject:trackURL];
    }

    // Register the playlist URL with NSDocumentController
    [[NSDocumentController sharedDocumentController] noteNewRecentDocumentURL:playlistURL];

    
    // Preserve the currently playing track's path before updating audioFiles
    NSString *currentTrackPath = nil;
    if (self.currentTrackIndex >= 0) {
        NSURL *currentTrackURL = nil;
        if (self.isPlaylistModeActive && self.audioFiles.count > self.currentTrackIndex) {
            currentTrackURL = self.audioFiles[self.currentTrackIndex];
        } else if (self.cachedAudioFiles.count > self.currentTrackIndex) {
            currentTrackURL = self.cachedAudioFiles[self.currentTrackIndex];
        }
        currentTrackPath = [currentTrackURL.path stringByStandardizingPath];
    }

    // Update the audioFiles property to the loaded tracks
    self.audioFiles = [trackURLs copy];

    // Set playlist mode active
    self.isPlaylistModeActive = YES;
    
    // Reset currentTrackIndex to the first track
    self.currentTrackIndex = 0;

    // Reinitialize shuffled tracks if shuffle mode is active
    if (self.isShuffleModeActive) {
        [self initializeShuffledTrackList];
    }

    // Search for the current track in the new audioFiles
    NSInteger newIndex = NSNotFound;
    if (currentTrackPath) {
        NSArray<NSURL *> *searchArray = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
        for (NSInteger i = 0; i < searchArray.count; i++) {
            NSURL *trackURL = searchArray[i];
            NSString *trackPath = [trackURL.path stringByStandardizingPath];
            if ([trackPath compare:currentTrackPath options:NSCaseInsensitiveSearch] == NSOrderedSame) {
                newIndex = i;
                break;
            }
        }
    }

    if (newIndex != NSNotFound) {
        // Current track exists in the new playlist; update the index
        self.currentTrackIndex = newIndex;
        // Continue playback without interruption
    } else {
        // Current track does not exist in the new playlist
        // Decide whether to stop playback or keep playing the current track
        // We'll keep playing the current track for simplicity
    }

    // Reload the combo box to display the new tracks
    dispatch_async(dispatch_get_main_queue(), ^{
        [self createComboBox];
        // Update combo box selection
        NSInteger selectedIndex = self.currentTrackIndex + 1; // Adjust for placeholder
        if (selectedIndex >= 0 && selectedIndex < self.songComboBox.numberOfItems) {
            [self.songComboBox selectItemAtIndex:selectedIndex];
        } else {
            [self.songComboBox selectItemAtIndex:0]; // Placeholder
        }
        // Do not start playing the first track automatically
        //[self playAudio];
    });

        #ifdef DEBUG
        NSLog(@"Loaded M3U playlist with %lu tracks.", (unsigned long)self.audioFiles.count);
        #endif
}

// Wrapper IBAction para ligação ao Interface Builder
- (IBAction)exitPlaylistModeAction:(id)sender {
    [self exitPlaylistMode];
}

- (void)exitPlaylistMode {
    self.isPlaylistModeActive = NO;
    self.currentTrackIndex = 0;
    [self loadAudioFiles]; // Reload audio files from the directory
    //[self playAudio]; // Start playback from the first track
}

// Add Ogg Opus support
- (void)handleOpusPlayback:(NSURL *)trackURL {
    [self startBs2bIfNeeded];
    // Ensure the current track maps to its original counterpart
    NSURL *originalTrackURL = self.shuffledToOriginalMap[self.currentTrackURL] ?: self.currentTrackURL;

    // Step 1: Clean up previous playback if necessary
    [self terminateOpusPlayback];

    // Step 2: Open the new Opus file
    NSData *dataToUse = nil;
    if (self.prefetchedTrackURL && [self.prefetchedTrackURL isEqual:trackURL]) {
        dataToUse = self.prefetchedData;
        self.prefetchedData = nil;
        self.prefetchedTrackURL = nil;
    }

    int error;
    OggOpusFile *opusFile = NULL;
    if (dataToUse) {
        opusFile = op_open_memory(dataToUse.bytes, dataToUse.length, &error);
    } else {
        const char *filePath = [trackURL.path UTF8String];
        opusFile = op_open_file(filePath, &error);
    }

    if (error != 0 || opusFile == NULL) {
        #ifdef DEBUG
        NSLog(@"Error opening Opus file: %d", error);
        #endif
        return;
    }

    // Step 3: Get stream info (e.g., number of channels) using op_head()
    const OpusHead *opusHead = op_head(opusFile, -1);  // Get the head of the current Opus stream
    int numChannels = opusHead ? opusHead->channel_count : 2;  // Default to stereo if unable to retrieve

    // Always set sampleRate to 48000 for Opus decoding
    int sampleRate = 48000;  // Fixed sample rate for Opus

    // Store the sample rate for progress calculations
    playbackState.sampleRate = sampleRate;

    // Step 4: Extract metadata using ZPOpusDecoder
    ZPOpusDecoder *decoder = nil;
    if (dataToUse) {
        decoder = [[ZPOpusDecoder alloc] initWithData:dataToUse];
    } else {
        decoder = [[ZPOpusDecoder alloc] initWithFilePath:trackURL.path];
    }
    if ([decoder decodeFile]) {
        // Metadata successfully decoded, now display in the UI

        // Update album art image using decoder.albumArt
        dispatch_block_t updateUIBlock = ^{
            if (decoder.albumArt) {
                self.coverArtView.image = decoder.albumArt;        // Update artist label
                self.artistLabel.stringValue = decoder.artist ?: @"Unknown Artist";
                // Update album label
                self.albumLabel.stringValue = decoder.album ?: @"Unknown Album";
            }
        };

        // Dispatch the block asynchronously on the main queue
        dispatch_async(dispatch_get_main_queue(), updateUIBlock);


        // Update track title label with track number and song title
        NSString *trackInfo = @"";
        if (decoder.track) {
            trackInfo = [NSString stringWithFormat:@"%@. ", decoder.track];
        }
        trackInfo = [trackInfo stringByAppendingString:decoder.title ?: @"Unknown Title"];
        dispatch_block_t updateTitleLabelBlock = ^{
            self.titleLabel.stringValue = trackInfo;
        };

        // Dispatch the block on the main queue to update the title label
        dispatch_async(dispatch_get_main_queue(), updateTitleLabelBlock);

    } else {
        // Handle case when metadata extraction fails
        self.coverArtView.image = [NSImage imageNamed:@"defaultAlbumArt"];
        self.artistLabel.stringValue = @"Unknown Artist";
        self.albumLabel.stringValue = @"Unknown Album";
        self.titleLabel.stringValue = @"Unknown Title";
    }

    // Step 5: Initialize Core Audio with the necessary format for Opus playback
    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = sampleRate;  // Use fixed sample rate of 48 kHz
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    audioFormat.mBytesPerPacket = numChannels * 2;  // 2 bytes per sample, adjust for mono or stereo
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mBytesPerFrame = numChannels * 2;
    audioFormat.mChannelsPerFrame = numChannels;
    audioFormat.mBitsPerChannel = 16;

    // Step 6: Calculate dynamic buffer size based on bitrate, with a minimum of 1 second
    int bitrate = op_bitrate(opusFile, -1);  // Get the bitrate of the current stream
    if (bitrate <= 0) {
        #ifdef DEBUG
        NSLog(@"Error retrieving Opus bitrate, using default bitrate of 64000 bps.");
        #endif
        bitrate = 64000;  // Fallback to a default bitrate (e.g., 64 kbps)
    }

    // Correct buffer size calculation based on uncompressed audio data
    double bufferDuration = 1.0;  // Buffer duration in seconds (may adjust)
    size_t bufferSize = audioFormat.mBytesPerFrame * audioFormat.mSampleRate * bufferDuration; // For bufferDuration
    size_t maxBufferSize = 1024 * 1024; // Limit the buffer size to 1MB
    playbackState.bufferSize = (UInt32)MIN(bufferSize, maxBufferSize);

    playbackState.opusFile = opusFile;
    playbackState.isPlaying = YES;

    playbackState.client_data = self;  // Set client_data to self for callback access

    // Step 7: Calculate the total duration of the Opus file in seconds
    int64_t totalSamples = op_pcm_total(opusFile, -1);  // -1 for total across all streams
    playbackState.totalDuration = (double)totalSamples / 48000.0;  // Use 48 kHz for Opus

    // Step 8: Create the audio queue for playback
    OSStatus status = AudioQueueNewOutput(&audioFormat, MyAudioQueueOutputCallback, &playbackState, NULL, NULL, 0, &playbackState.audioQueue);

    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"Error creating audio queue: %d", (int)status);
        #endif
        op_free(opusFile);
        return;
    }

    // Step 9: Allocate audio buffers and start playback
    for (int i = 0; i < NUM_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(playbackState.audioQueue, playbackState.bufferSize, &playbackState.buffers[i]);
        if (status != noErr) {
            #ifdef DEBUG
            NSLog(@"Error allocating buffer: %d", (int)status);
            #endif
            op_free(opusFile);
            AudioQueueDispose(playbackState.audioQueue, true);
            return;
        }
        MyAudioQueueOutputCallback(&playbackState, playbackState.audioQueue, playbackState.buffers[i]);
    }

    // Step 10: Start the queue
    AudioQueueStart(playbackState.audioQueue, NULL);

    // Step 11: Start progress updates using AudioQueueGetCurrentTime for more accuracy
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
    }
    self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:0.1
                                                                target:self
                                                              selector:@selector(updateOpusProgress)
                                                              userInfo:nil
                                                               repeats:YES];
    // Step 12: Count updates
    // Clear the play count label
    dispatch_block_t updateLabelBlock = ^{
        [self.playCountLabel setStringValue:@""];
    };

    // Dispatch to the main thread to clear the play count label immediately
    dispatch_async(dispatch_get_main_queue(), updateLabelBlock);

    // Create a 5-second delay using dispatch_after
    if (self.isRepeatModeActive) {
        // Only execute this block if repeat mode is active
        if (originalTrackURL) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self incrementPlayCountForTrack:originalTrackURL];
                [self updatePlayCountLabelForTrack:originalTrackURL];
            });
        }
    }

}

// Add this method to update the progress bar based on Opus playback progress
- (void)updateOpusProgress {
    if (playbackState.audioQueue && playbackState.isPlaying) {
        AudioTimeStamp timeStamp;
        Boolean discontinuity;
        OSStatus status = AudioQueueGetCurrentTime(playbackState.audioQueue, NULL, &timeStamp, &discontinuity);

        if (status == noErr && timeStamp.mSampleTime >= 0) { // Ensure valid timestamp
            // Ensure correct sample rate from playback state
            double sampleRate = playbackState.sampleRate > 0 ? playbackState.sampleRate : 48000.0;

            // Calculate the current time in seconds
            double currentTime = timeStamp.mSampleTime / sampleRate;

            // Ensure totalDuration is correctly initialized
            if (playbackState.totalDuration > 0 && currentTime <= playbackState.totalDuration) {
                // Calculate progress percentage
                double progress = (currentTime / playbackState.totalDuration) * 100.0;

                // Update the progress bar on the main thread
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self.progressBar setDoubleValue:progress];
                });

                // Handle playback completion if the progress is near or exceeds 100%
                if (fabs(currentTime - playbackState.totalDuration) < 0.01) {
                    [self handleOpusPlaybackCompletion];
                }
            }
        } else if (discontinuity) {
            #ifdef DEBUG
            NSLog(@"AudioQueue discontinuity detected.");
            #endif
            // Optionally handle discontinuity (e.g., reset progress, pause, etc.)
        }
    }
}

- (void)terminateOpusPlayback {

    if (playbackState.isPlaying) {
        // Stop the audio queue but wait for all pending buffers to be processed
        AudioQueueStop(playbackState.audioQueue, false);
        playbackState.isPlaying = NO;
    }
    
    if (playbackState.opusFile) {
        op_free(playbackState.opusFile);
        playbackState.opusFile = NULL;
    }
    
    if (playbackState.audioQueue) {
        // Dispose of the audio queue after ensuring it has stopped completely
        AudioQueueDispose(playbackState.audioQueue, true);
        playbackState.audioQueue = NULL;
    }
    
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }
    
    // Reset playback state variables
    memset(&playbackState, 0, sizeof(playbackState)); // Properly reset all variables

}

- (void)handleOpusPlaybackCompletion {
    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    // Ensure the current track maps to its original counterpart
    #ifdef DEBUG
    NSURL *originalTrackURL = self.shuffledToOriginalMap[self.currentTrackURL] ?: self.currentTrackURL;

    NSLog(@"Playback completed for track: %@", self.currentTrackURL);
    NSLog(@"Original Track URL: %@", originalTrackURL);
    #endif

    // Check if repeat mode is active, replay the current track if it is
    if (self.isRepeatModeActive) {
        [self playAudio];  // Replay the same track
    } else {
    // Otherwise, move to the next track
        [self playNextTrack];
    }
}

- (void)requestNotificationPermission {
    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert + UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (!granted) {
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"notification_permission_not_granted", @"Notification permission not granted."));
            #endif
        }
    }];
}

- (void)extractAndDisplayFlacMetadataWithLibFLAC:(NSURL *)fileURL {
    // Always default to 1.0 before reading metadata
    self.replayGainValue = 0.0f;

    // Initialize the FLAC decoder
    FLAC__StreamDecoder *decoder = FLAC__stream_decoder_new();
    if (!decoder) {
        #ifdef DEBUG
        NSLog(@"Error: Could not create FLAC decoder");
        #endif
        return;
    }

    // Ensure the decoder responds to all metadata blocks
    FLAC__stream_decoder_set_metadata_respond_all(decoder);

    // Initialize the decoder with file and callbacks
    FLAC__StreamDecoderInitStatus init_status = FLAC__stream_decoder_init_file(
        decoder,
        [fileURL.path UTF8String],
        flac_write_callback,  // Stub write callback
        flac_metadata_callback, // Metadata callback for handling metadata blocks
        flac_error_callback,  // Error handling callback
        (__bridge void *)(self)
    );

    if (init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
        #ifdef DEBUG
        NSLog(@"Error: Could not initialize FLAC decoder for file: %@", fileURL.path);
        #endif
        FLAC__stream_decoder_delete(decoder);
        return;
    }

    // Process the file until all metadata is read
    if (!FLAC__stream_decoder_process_until_end_of_metadata(decoder)) {
        #ifdef DEBUG
        NSLog(@"Error: Failed to process FLAC metadata for file: %@", fileURL.path);
        #endif
    } else {
        // Create a dispatch block for UI updates
        dispatch_block_t updateUI = ^{
            // Access the UI elements safely on the main thread
            NSString *artist = self.artistLabel.stringValue;
            NSString *album = self.albumLabel.stringValue;
            NSString *title = self.titleLabel.stringValue;

            // Trigger the notification now that metadata is fully extracted
            [self triggerNowPlayingNotificationWithTitle:title artist:artist album:album];
        };

        // Dispatch the block to the main thread to update the UI
        dispatch_async(dispatch_get_main_queue(), updateUI);
    }

    // Clean up
    FLAC__stream_decoder_finish(decoder);
    FLAC__stream_decoder_delete(decoder);
}

// Stub for write callback (no audio data is being processed)
FLAC__StreamDecoderWriteStatus flac_write_callback(const FLAC__StreamDecoder *decoder,
                                                   const FLAC__Frame *frame,
                                                   const FLAC__int32 * const buffer[],
                                                   void *client_data) {
    return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
}

// Error callback function for handling errors during decoding
void flac_error_callback(const FLAC__StreamDecoder *decoder,
                         FLAC__StreamDecoderErrorStatus status,
                         void *client_data) {
    #ifdef DEBUG
    NSLog(@"FLAC decoding error: %d", status);
    #endif
}

// Helper function to print the VORBIS comment (adapted for Objective-C)
NSString *print_vorbis_comment(const FLAC__StreamMetadata_VorbisComment_Entry *entry, ViewController *self) {
    NSString *entry_str = [[NSString alloc] initWithBytes:entry->entry
                                                   length:entry->length
                                                 encoding:NSUTF8StringEncoding];
    if (!entry_str) {
        #ifdef DEBUG
        NSLog(@"Error: Failed to decode Vorbis comment");
        #endif
        return nil;
    }

    // Variables to hold metadata
    static NSString *trackNumber = @"Unknown Track";
    static NSString *artist      = @"Unknown Artist";
    static NSString *album       = @"Unknown Album";
    static NSString *title       = @"Unknown Title";

    // Check if this line starts with ARTIST=, ALBUM=, TITLE=, TRACKNUMBER=, or REPLAYGAIN_TRACK_GAIN=
    if ([entry_str hasPrefix:@"ARTIST="]) {
        artist = [self replaceSingleQuoteAndSmartQuotes:[entry_str substringFromIndex:7]];
        #ifdef DEBUG
        NSLog(@"Artist is: %@", artist);
        #endif
    }
    else if ([entry_str hasPrefix:@"ALBUM="]) {
        album = [self replaceSingleQuoteAndSmartQuotes:[entry_str substringFromIndex:6]];
        #ifdef DEBUG
        NSLog(@"Album is: %@", album);
        #endif
    }
    else if ([entry_str hasPrefix:@"TITLE="]) {
        title = [self replaceSingleQuoteAndSmartQuotes:[entry_str substringFromIndex:6]];
        #ifdef DEBUG
        NSLog(@"Title is: %@", title);
        #endif
    }
    else if ([entry_str hasPrefix:@"TRACKNUMBER="]) {
        trackNumber = [entry_str substringFromIndex:12];
        if ([trackNumber hasPrefix:@"0"]) {
            trackNumber = [trackNumber substringFromIndex:1];
        }
        #ifdef DEBUG
        NSLog(@"Track Number is: %@", trackNumber);
        #endif
    }
    else if ([entry_str hasPrefix:@"REPLAYGAIN_TRACK_GAIN="]) {
        // Example: "REPLAYGAIN_TRACK_GAIN=-5.66 dB" or "REPLAYGAIN_TRACK_GAIN=+2.0 dB"
        NSString *gainString = [entry_str substringFromIndex:22];
        // Remove the trailing " dB" if present
        gainString = [gainString stringByReplacingOccurrencesOfString:@" dB" withString:@""];
        // Convert to float
        float gainValue = [gainString floatValue];
        
        // Store it in the property on the main thread (if UI code might be triggered)
        dispatch_async(dispatch_get_main_queue(), ^{
            // If you haven’t already set self.replayGainValue,
            // you can set it here. Or do additional logic if needed.
            self.replayGainValue = gainValue;
            #ifdef DEBUG
            NSLog(@"[ReplayGain] FLAC track gain: %f dB", self.replayGainValue);
            #endif
            [self.airPlayStreamer updateReplayGainValue:self.replayGainValue];
        });
    }

    // Format the title with the track number
    NSString *formattedTitle = [NSString stringWithFormat:@"%@. %@", trackNumber, title];

    // Update the UI elements on the main thread
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.artistLabel setStringValue:artist];
        [self.albumLabel setStringValue:album];
        [self.titleLabel setStringValue:formattedTitle];
        [self.trackNumberLabel setStringValue:trackNumber];
    });

    return entry_str;
}

// Metadata callback function
void flac_metadata_callback(const FLAC__StreamDecoder *decoder,
                               const FLAC__StreamMetadata *metadata,
                               void *client_data) {
    ViewController *self = (__bridge ViewController *)client_data;

    // Log the type of metadata received
    #ifdef DEBUG
    NSLog(@"Metadata block type: %d", metadata->type);
    #endif

    switch (metadata->type) {
        case FLAC__METADATA_TYPE_VORBIS_COMMENT: {
            #ifdef DEBUG
            NSLog(@"\nVORBIS Comment block detected");
            #endif

            // Iterate through all VORBIS comments and process each one
            for (unsigned i = 0; i < metadata->data.vorbis_comment.num_comments; i++) {
                NSString *comment = print_vorbis_comment(&metadata->data.vorbis_comment.comments[i], self);
                
                // If replaceSingleQuoteAndSmartQuotes interacts with UI, ensure it's on the main thread
                dispatch_block_t processComment = ^{
                    [self replaceSingleQuoteAndSmartQuotes:comment];
                };
                dispatch_async(dispatch_get_main_queue(), processComment);
            }
            break;
        }
        case FLAC__METADATA_TYPE_PICTURE: {
            #ifdef DEBUG
            NSLog(@"\nPICTURE block detected");
            #endif
            // Log image dimensions and MIME type if present
            if (metadata->data.picture.mime_type) {
                #ifdef DEBUG
                NSString *mimeType = [NSString stringWithUTF8String:metadata->data.picture.mime_type];
                NSLog(@"MIME type: %@", mimeType);
                #endif
            }
            #ifdef DEBUG
            NSLog(@"Dimensions: %ux%u pixels", metadata->data.picture.width, metadata->data.picture.height);
            #endif

            // Process and display the cover art if data exists
            NSUInteger dataLength = metadata->data.picture.data_length;
            if (dataLength > 0) {
                NSData *imageData = [NSData dataWithBytes:metadata->data.picture.data length:dataLength];
                if (imageData) {
                    NSImage *coverArt = [[NSImage alloc] initWithData:imageData];
                    if (coverArt) {
                        // Use a block to update the UI on the main thread
                        dispatch_block_t updateCoverArt = ^{
                            [self.coverArtView setImage:coverArt];
                            #ifdef DEBUG
                            NSLog(@"Cover Art updated successfully.");
                            #endif
                        };
                        dispatch_async(dispatch_get_main_queue(), updateCoverArt);
                    } else {
                        #ifdef DEBUG
                        NSLog(@"Failed to create NSImage from the extracted data.");
                        #endif
                    }
                }
            } else {
                #ifdef DEBUG
                NSLog(@"Image data length is zero.");
                #endif
            }
            break;
        }
        default: {
            #ifdef DEBUG
            NSLog(@"Skipping metadata block type: %d", metadata->type);
            #endif
            break;
        }
    }

}

#pragma mark - WavPack

// Para evitar os pops no início de cada reprodução
- (void)applyFadeInToAudioBuffer:(int16_t *)buffer
                  totalSamples:(uint32_t)samples
                  numChannels:(int)numChannels
                   sampleRate:(int)sampleRate {
    uint32_t fadeSamples = sampleRate / 20; // 50 ms
    fadeSamples = MIN(fadeSamples, samples);
    
    for (uint32_t i = 0; i < fadeSamples; i++) {
        float factor = (float)i / (float)fadeSamples;
        for (int ch = 0; ch < numChannels; ch++) {
            int index = i * numChannels + ch;
            buffer[index] = (int16_t)(buffer[index] * factor);
        }
    }
}

// Add this method to update the progress bar based on WavPack playback progress
- (void)updateWavPackProgress {
    if (playbackState.wpc && playbackState.isPlaying) {
        // Retrieve the progress of the current WavPack file
        double progress = WavpackGetProgress(playbackState.wpc);
        
        if (progress >= 0.0 && progress <= 1.0) {
            // Create a dispatch block for updating the progress bar
            dispatch_block_t updateProgressBar = ^{
                // Convert progress to a percentage and update the progress bar
                [self.progressBar setDoubleValue:progress * 100.0];
            };
            
            // Dispatch the block to the main thread to update the UI
            dispatch_async(dispatch_get_main_queue(), updateProgressBar);
        } else {
            #ifdef DEBUG
            NSLog(@"Unknown progress.");
            #endif
        }
    }
}

// Start playback for the WavPack file and set up the timer to update progress
- (void)playWavPack:(NSURL *)trackURL {
    [self startBs2bIfNeeded];
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;  // Use original if available

    // Convert the file URL path to a UTF-8 string for WavPack
    const char *filePath = [trackURL.path UTF8String];

    // Open the WAVPack file and extract metadata
    [self extractAndDisplayMetadataForWavPack:trackURL];

    NSData *dataToUse = nil;
    if (self.prefetchedTrackURL && [self.prefetchedTrackURL isEqual:trackURL]) {
        dataToUse = self.prefetchedData;
        self.prefetchedData = nil;
        self.prefetchedTrackURL = nil;
    }

    char error[80];
    if (dataToUse) {
        // Memory reader setup for WavPack
        MemoryBuffer buffer = { .data = dataToUse.bytes, .size = dataToUse.length, .pos = 0 };
        playbackState.wpc = WavpackOpenFileInputEx(&memoryReader, &buffer, NULL, error, 0, 0);
    } else {
        playbackState.wpc = WavpackOpenFileInput(filePath, error, 0, 0);
    }
    if (!playbackState.wpc) {
        #ifdef DEBUG
        NSLog(@"Error opening WAVPack file: %s", error);
        #endif
        return;
    }
    
    playbackState.client_data = self;
    
    // Retrieve WAVPack file properties
    int numChannels = WavpackGetNumChannels(playbackState.wpc);
    int sampleRate = WavpackGetSampleRate(playbackState.wpc);
    int bitsPerSample = WavpackGetBitsPerSample(playbackState.wpc);
    int bytesPerSample = WavpackGetBytesPerSample(playbackState.wpc);
    
    playbackState.numChannels = numChannels;
    #ifdef DEBUG
    NSLog(@"WAVPack File Info: %d channels, %d Hz, %d bits/sample, %d bytes/sample",
          numChannels, sampleRate, bitsPerSample, bytesPerSample);
    #endif
    
    // Initialize audio format description
    AudioStreamBasicDescription audioFormat = {0};
    audioFormat.mSampleRate = sampleRate;
    audioFormat.mFormatID = kAudioFormatLinearPCM;
    audioFormat.mFramesPerPacket = 1;
    audioFormat.mChannelsPerFrame = numChannels;
    audioFormat.mBitsPerChannel = bitsPerSample;
    audioFormat.mBytesPerFrame = (bitsPerSample / 8) * numChannels;
    audioFormat.mBytesPerPacket = audioFormat.mBytesPerFrame;
    audioFormat.mReserved = 0;
    
    // Check if the WavPack file has floating-point audio
    if (WavpackGetMode(playbackState.wpc) & MODE_FLOAT) {
        audioFormat.mFormatFlags = kLinearPCMFormatFlagIsFloat | kLinearPCMFormatFlagIsPacked;
        #ifdef DEBUG
        NSLog(@"WAVPack file contains floating-point data.");
        #endif
    } else {
        audioFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    }
    
    // Cleanup previous playback if necessary
    [self cleanupCoreAudioPlayback];
    
    // Calculate the total bytes per frame (including all channels)
    int bytesPerFrame = bytesPerSample * numChannels;
    
    // Calculate buffer size based on file properties (0.5 seconds of audio originally)
    playbackState.bufferSize = sampleRate * bytesPerFrame * 2.0;
    
    // Allocate memory for the audio sample buffer
    playbackState.sampleBuffer = malloc(playbackState.bufferSize);
    
    // Initialise fade-in flag
    playbackState.didApplyFadeIn = NO;
    
    // Indicate that playback has started
    playbackState.isPlaying = YES;
    
    // Create the new audio queue with the properly initialized format
    OSStatus status = AudioQueueNewOutput(&audioFormat, MyAudioQueueOutputCallback, &playbackState, NULL, NULL, 0, &playbackState.audioQueue);
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"Error creating audio output queue: %d", (int)status);
        #endif
        free(playbackState.sampleBuffer);
        WavpackCloseFile(playbackState.wpc);  // Close the WavPack file on error
        playbackState.wpc = NULL;  // Reset to NULL after closing
        return;
    }
    
    // Allocate buffers and prime the queue
    for (int i = 0; i < NUM_BUFFERS; i++) {
        status = AudioQueueAllocateBuffer(playbackState.audioQueue, playbackState.bufferSize, &playbackState.buffers[i]);
        if (status == noErr) {
            MyAudioQueueOutputCallback(&playbackState, playbackState.audioQueue, playbackState.buffers[i]);
        } else {
            #ifdef DEBUG
            NSLog(@"Error allocating buffer: %d", (int)status);
            #endif
            free(playbackState.sampleBuffer);
            WavpackCloseFile(playbackState.wpc);  // Close the WavPack file on error
            playbackState.wpc = NULL;  // Reset to NULL after closing
            return;
        }
    }
    
    // Start playback
    status = AudioQueueStart(playbackState.audioQueue, NULL);
    if (status != noErr) {
        #ifdef DEBUG
        NSLog(@"Error starting audio queue: %d", (int)status);
        #endif
        free(playbackState.sampleBuffer);
        for (int i = 0; i < NUM_BUFFERS; i++) {
            AudioQueueFreeBuffer(playbackState.audioQueue, playbackState.buffers[i]);
        }
        WavpackCloseFile(playbackState.wpc);  // Close the WavPack file on error
        playbackState.wpc = NULL;  // Reset to NULL after closing
        return;
    }
    
    // Start the progress bar updates
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];  // Stop any previous timer
    }
    
    self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                target:self
                                                              selector:@selector(updateWavPackProgress)
                                                              userInfo:nil
                                                               repeats:YES];

    // Create a 5-second delay using dispatch_after
    if (self.isRepeatModeActive) {
        // Clear the play count display on the main thread
        dispatch_block_t clearPlayCount = ^{
            [self.playCountLabel setStringValue:@""]; // Clear the tally on display
        };

        // Dispatch the block asynchronously to the main queue
        dispatch_async(dispatch_get_main_queue(), clearPlayCount);

        // Only execute this block if repeat mode is active
        if (originalTrackURL) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self incrementPlayCountForTrack:originalTrackURL];
                [self updatePlayCountLabelForTrack:originalTrackURL];
            });
        }
    }

}

// Callback to handle audio buffer playback
void MyAudioQueueOutputCallback(void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) {
    CoreAudioPlaybackState *playbackState = (CoreAudioPlaybackState *)inUserData;

    // Handling WAVPack decoding
    if (playbackState->wpc) {
        // WAVPack decoding logic
        int bytesPerSample = WavpackGetBytesPerSample(playbackState->wpc);
        int numChannels = playbackState->numChannels;

        // Determine the maximum number of samples that can be decoded into the buffer
        uint32_t maxSamplesToDecode = MIN(inBuffer->mAudioDataBytesCapacity / (bytesPerSample * numChannels), 10000);
        
        // Decode WAVPack samples into the sample buffer
        int32_t samplesDecoded = WavpackUnpackSamples(playbackState->wpc, playbackState->sampleBuffer, maxSamplesToDecode);

        if (samplesDecoded > 0) {
            size_t dataSize = samplesDecoded * bytesPerSample * numChannels;

            // Ensure buffer size fits the decoded data
            if (dataSize > inBuffer->mAudioDataBytesCapacity) {
                #ifdef DEBUG
                NSLog(@"Warning: Data size exceeds buffer capacity. Truncating data.");
                #endif
                dataSize = inBuffer->mAudioDataBytesCapacity;
            }
            
            // Interleave the samples correctly
            for (uint32_t i = 0; i < samplesDecoded; i++) {
                for (int channel = 0; channel < numChannels; channel++) {
                    ((int16_t *)inBuffer->mAudioData)[i * numChannels + channel] =
                        playbackState->sampleBuffer[i * numChannels + channel];
                }
            }

            /* ───── fade-in só no 1.º buffer ───── */
            ViewController *vc = (ViewController *)playbackState->client_data;
            if (!playbackState->didApplyFadeIn &&
                [vc respondsToSelector:@selector(applyFadeInToAudioBuffer:totalSamples:numChannels:sampleRate:)])
            {
                [vc applyFadeInToAudioBuffer:(int16_t *)inBuffer->mAudioData
                                totalSamples:samplesDecoded
                                 numChannels:numChannels
                                  sampleRate:WavpackGetSampleRate(playbackState->wpc)];

                playbackState->didApplyFadeIn = YES;          // não volta a aplicar
            }
            /* ───────────────────────────────────── */
            
            inBuffer->mAudioDataByteSize = (UInt32)dataSize;
            
            // Enqueue buffer for playback
            OSStatus status = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
            if (status != noErr) {
                #ifdef DEBUG
                NSLog(@"Error enqueuing buffer: %d", status);
                #endif
            }
        } else {
            // No more samples to decode, stop playback
            AudioQueueStop(inAQ, false);
            playbackState->isPlaying = NO;
            #ifdef DEBUG
            NSLog(@"WAVPack playback finished.");
            #endif

            // Close the WavPack file when playback finishes
            if (playbackState->wpc) {
                WavpackCloseFile(playbackState->wpc);
                playbackState->wpc = NULL;
            }

            // Handle repeat or transition to next song
            ViewController *viewController = playbackState->client_data;
            if (viewController.isRepeatModeActive) {
                #ifdef DEBUG
                NSLog(@"Repeat mode is active. Restarting the current WAVPack track.");
                #endif
                [viewController cleanupCoreAudioPlayback]; // Clean up the previous playback state
                [viewController playWavPack:viewController.audioFiles[viewController.currentTrackIndex]];
            } else {
                [viewController handlePlaybackCompletion];
            }
        }

    // Handling Opus decoding
    } else if (playbackState->opusFile) {
        // Opus decoding logic
        int16_t pcmBuffer[4096 * 2]; // Stereo buffer for decoded samples
        int samplesDecoded = op_read_stereo(playbackState->opusFile, pcmBuffer, sizeof(pcmBuffer) / sizeof(pcmBuffer[0]));

        if (samplesDecoded > 0) {
            size_t dataSize = samplesDecoded * sizeof(int16_t) * 2; // 2 channels

            // Ensure buffer size fits the decoded data
            if (dataSize > inBuffer->mAudioDataBytesCapacity) {
                #ifdef DEBUG
                NSLog(@"Warning: Data size exceeds buffer capacity. Truncating data.");
                #endif
                dataSize = inBuffer->mAudioDataBytesCapacity;
            }

            // Copy the decoded data into the buffer
            memcpy(inBuffer->mAudioData, pcmBuffer, dataSize);
            inBuffer->mAudioDataByteSize = (UInt32)dataSize;

            // Enqueue buffer for playback
            OSStatus status = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
            if (status != noErr) {
                #ifdef DEBUG
                NSLog(@"Error enqueuing buffer: %d", status);
                #endif
            }
        } else {
            // No more samples to decode, stop playback
            AudioQueueStop(inAQ, false);
            playbackState->isPlaying = NO;
            #ifdef DEBUG
            NSLog(@"Opus playback finished.");
            #endif

            // Clean up Opus resources
            if (playbackState->opusFile) {
                op_free(playbackState->opusFile);
                playbackState->opusFile = NULL;
            }

            // Handle repeat or transition to the next song
            ViewController *viewController = playbackState->client_data;
            if (viewController.isRepeatModeActive) {
                #ifdef DEBUG
                NSLog(@"Repeat mode is active. Restarting the current Opus track.");
                #endif
                [viewController cleanupCoreAudioPlayback]; // Clean up the previous playback state
                [viewController handleOpusPlayback:viewController.audioFiles[viewController.currentTrackIndex]];
            } else {
                [viewController handlePlaybackCompletion];  // Move to the next track in the playlist
            }
        }
    } else {
        #ifdef DEBUG
        NSLog(@"Error: Unknown audio format in playback state.");
        #endif
    }
}

- (void)handlePlaybackCompletion {
    //self.replayGainValue = 0.0f;
    if (self.isShuffleModeActive) {
        #ifdef DEBUG
        NSLog(NSLocalizedString(@"shuffle_mode_activated", @"Shuffle mode activated."));
        #endif
        [self playNextTrack];  // Play next shuffled track
    } else {
        // Check if we're at the end of the track list
        if (self.currentTrackIndex < self.audioFiles.count - 1) {
            // Move to the next track in the list
            self.currentTrackIndex++;
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"playing_next_track", @"Playing next track."));
            #endif
            [self playAudio];  // Play next track in order
        } else {
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"reached_end_of_playlist", @"Reached the end of the playlist."));
            #endif
            // If repeat mode is active, loop back to the first track and play again
            if (self.isRepeatModeActive) {
                self.currentTrackIndex = 0;
                [self playAudio];
            } else {
                #ifdef DEBUG
                NSLog(NSLocalizedString(@"playback_completed_no_repeat", @"Playback completed with no repeat."));
                #endif
                // Optionally, you can stop playback here if you don't want to repeat the playlist automatically.
                //[self stopAudio];  // Stop the audio if playlist is completed
            }
        }
    }
}

- (void)playNextTrack {
    //self.replayGainValue = 0.0f;
    self.isCalledFromPlayNextTrack = YES;
    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }

    // Clear any existing progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    if (self.isShuffleModeActive) {
        #ifdef DEBUG
        NSLog(@"Shuffle mode is active. Playing next shuffled track.");
        #endif
        if (self.shuffledTracks.count > 0) {
            // Move to the next track in shuffledTracks
            self.currentTrackIndex = (self.currentTrackIndex + 1) % self.shuffledTracks.count;
            NSURL *nextTrackURL = self.shuffledTracks[self.currentTrackIndex];

            // Update the current track URL
            self.currentTrackURL = nextTrackURL;

            // Stop any current playback
            dispatch_block_t stopAudioBlock = ^{
                [self stopAudio];
            };
            dispatch_async(dispatch_get_main_queue(), stopAudioBlock);

            // Reset the progress bar
            dispatch_block_t resetProgressBarBlock = ^{
                [self.progressBar setDoubleValue:0];
            };
            dispatch_async(dispatch_get_main_queue(), resetProgressBarBlock);

            // Get the extension of the next track
            NSString *extension = nextTrackURL.pathExtension.lowercaseString;

            if ([extension isEqualToString:@"wv"]) {
                // WAVPack playback
                dispatch_block_t playWavPackBlock = ^{
                    [self playWavPack:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playWavPackBlock);

                // Restart progress updates for WAVPack
                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateWavPackProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else if ([extension isEqualToString:@"flac"]) {
                // FLAC playback
                dispatch_block_t playFlacBlock = ^{
                    [self handleFlacPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playFlacBlock);
            } else if ([extension isEqualToString:@"opus"]) {
                // Opus playback
                dispatch_block_t playOpusBlock = ^{
                    [self handleOpusPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playOpusBlock);

                // Restart progress updates for Opus
                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateOpusProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else {
                // Standard audio playback
                dispatch_block_t playStandardAudioBlock = ^{
                    [self handleStandardAudioPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playStandardAudioBlock);

                // Restart progress updates for standard audio formats
                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateProgressBar)
                                                                          userInfo:nil
                                                                           repeats:YES];
            }

            // Schedule play count increment
            dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
            dispatch_after(delay, dispatch_get_main_queue(), ^{
                dispatch_block_t clearPlayCount = ^{
                    [self.playCountLabel setStringValue:@""]; // Clear the tally on display
                };

                // Dispatch the block asynchronously to the main queue
                dispatch_async(dispatch_get_main_queue(), clearPlayCount);

                dispatch_block_t updatePlayCountBlock = ^{
                    [self schedulePlayCountIncrementForTrack:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), updatePlayCountBlock);
            });

            // Force UI updates
            dispatch_block_t forceUIUpdateBlock = ^{
                [self.view setNeedsDisplay:YES];
            };
            dispatch_async(dispatch_get_main_queue(), forceUIUpdateBlock);

            // Update the combo box to reflect the current track being played
            NSInteger index = [self.audioFiles indexOfObject:self.currentTrackURL];
            NSUInteger comboBoxIndex;

            if (index != NSNotFound) {
                comboBoxIndex = index + 1; // Offset by 1 for placeholder
            } else {
                comboBoxIndex = 0; // Placeholder index
            }

            dispatch_block_t updateComboBox = ^{
                [self.songComboBox selectItemAtIndex:comboBoxIndex];
            };
            dispatch_async(dispatch_get_main_queue(), updateComboBox);

            // Prefetch the subsequent track
            [self prefetchNextTrack];

        } else {
            #ifdef DEBUG
            NSLog(@"No shuffled tracks available.");
            #endif
        }
    } else {
        if (self.currentTrackIndex < self.audioFiles.count - 1) {
            self.currentTrackIndex++;
            NSURL *nextTrackURL = self.audioFiles[self.currentTrackIndex];

            // Update the current track URL
            self.currentTrackURL = nextTrackURL;

            // Stop current playback and reset progress bar
            dispatch_block_t stopAudioBlock = ^{
                [self stopAudio];
                [self.progressBar setDoubleValue:0.0];
            };
            dispatch_async(dispatch_get_main_queue(), stopAudioBlock);

            // Get the file extension of the next track
            NSString *extension = nextTrackURL.pathExtension.lowercaseString;

            if ([extension isEqualToString:@"wv"]) {
                dispatch_block_t playWavPackBlock = ^{
                    [self playWavPack:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playWavPackBlock);

                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateWavPackProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else if ([extension isEqualToString:@"flac"]) {
                dispatch_block_t playFlacBlock = ^{
                    [self handleFlacPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playFlacBlock);
            } else if ([extension isEqualToString:@"opus"]) {
                dispatch_block_t playOpusBlock = ^{
                    [self handleOpusPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playOpusBlock);

                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateOpusProgress)
                                                                          userInfo:nil
                                                                           repeats:YES];
            } else {
                dispatch_block_t playStandardAudioBlock = ^{
                    [self handleStandardAudioPlayback:nextTrackURL];
                };
                dispatch_async(dispatch_get_main_queue(), playStandardAudioBlock);

                self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                            target:self
                                                                          selector:@selector(updateProgressBar)
                                                                          userInfo:nil
                                                                           repeats:YES];
            }

            // Schedule play count increment
            dispatch_block_t updatePlayCountBlock = ^{
                [self schedulePlayCountIncrementForTrack:nextTrackURL];
            };
            dispatch_async(dispatch_get_main_queue(), updatePlayCountBlock);

            // Force UI updates
            dispatch_block_t forceUIUpdateBlock = ^{
                [self.view setNeedsDisplay:YES];
            };
            dispatch_async(dispatch_get_main_queue(), forceUIUpdateBlock);

            // Update the combo box to reflect the current track being played
            NSInteger index = [self.audioFiles indexOfObject:self.currentTrackURL];
            NSUInteger comboBoxIndex;

            if (index != NSNotFound) {
                comboBoxIndex = index + 1; // Offset by 1 for placeholder
            } else {
                comboBoxIndex = 0; // Placeholder index
            }

            dispatch_block_t updateComboBox = ^{
                [self.songComboBox selectItemAtIndex:comboBoxIndex];
            };
            dispatch_async(dispatch_get_main_queue(), updateComboBox);

            // Prefetch the subsequent track
            [self prefetchNextTrack];

        } else {
            #ifdef DEBUG
            NSLog(@"End of playlist reached.");
            #endif
            self.currentTrackIndex = 0;
            dispatch_block_t playAudioBlock = ^{
                [self playAudio];
            };
            dispatch_async(dispatch_get_main_queue(), playAudioBlock);
        }
    }
    self.isCalledFromPlayNextTrack = NO;
}

- (void)playAudio {
    [self startBs2bIfNeeded];
    //self.replayGainValue = 0.0f;

    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }

    if (self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(NSLocalizedString(@"no_audio_files_to_play", @"No audio files to play."));
        #endif
        return;
    }
    
    #ifdef DEBUG
    NSLog(NSLocalizedString(@"starting_playback_for_track", @"Starting playback for track index: %ld"), (long)self.currentTrackIndex);
    #endif
    
    // Stop any current playback to avoid overlapping
    [self stopAudio];

    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    // Determine the track to play based on the current mode (shuffle or not)
    NSURL *trackURL = self.isShuffleModeActive ? self.shuffledTracks[self.currentTrackIndex] : self.audioFiles[self.currentTrackIndex];
    NSURL *originalTrackURL = self.shuffledToOriginalMap[trackURL] ?: trackURL;  // Use original if available

    NSString *extension = trackURL.pathExtension.lowercaseString;
    #ifdef DEBUG
    NSLog(@"Playing track URL: %@", trackURL.absoluteString);
    #endif

    // Cancel any previous play count increment timer
    if (self.playCountTimer) {
        [self.playCountTimer invalidate];
        self.playCountTimer = nil;
    }

    // Clear the play count display on the main thread
    dispatch_block_t clearPlayCount = ^{
        [self.playCountLabel setStringValue:@""]; // Clear the tally on display
    };

    // Dispatch the block asynchronously to the main queue
    dispatch_async(dispatch_get_main_queue(), clearPlayCount);
    
    // Update the current track URL
    self.currentTrackURL = trackURL;

    // Schedule the play count increment for the original track URL
    [self schedulePlayCountIncrementForTrack:originalTrackURL];

    // Update the combo box to reflect the current track being played
    NSInteger index = [self.audioFiles indexOfObject:self.currentTrackURL];
    NSUInteger comboBoxIndex;

    if (index != NSNotFound) {
        comboBoxIndex = index + 1; // Offset by 1 for placeholder
    } else {
        comboBoxIndex = 0; // Placeholder index
    }

    dispatch_block_t updateComboBox = ^{
        [self.songComboBox selectItemAtIndex:comboBoxIndex];
    };
    dispatch_async(dispatch_get_main_queue(), updateComboBox);

    // Proceed with playback depending on the file format
    if ([extension isEqualToString:@"wv"]) {
        [self handleWavPackPlayback:trackURL];
    } else if ([extension isEqualToString:@"flac"]) {
        [self handleFlacPlayback:trackURL];
    } else if ([extension isEqualToString:@"opus"]) {
        [self handleOpusPlayback:trackURL];  // Add Opus playback support here
    } else {
        [self handleStandardAudioPlayback:trackURL];
    }

    // Prefetch the next track after current playback starts
    [self prefetchNextTrack];

}

- (void)extractAndDisplayMetadataForWavPack:(NSURL *)trackURL {
    // 1. Parse the WavPack metadata.
    const char *filePath = [trackURL.path UTF8String];

    // Open the WAVPack file to extract metadata
    NSData *dataToUse = nil;
    if (self.prefetchedTrackURL && [self.prefetchedTrackURL isEqual:trackURL]) {
        dataToUse = self.prefetchedData;
    }
    char error[80];
    WavpackContext *wpc = NULL;
    if (dataToUse) {
        MemoryBuffer buffer = { .data = dataToUse.bytes, .size = dataToUse.length, .pos = 0 };
        wpc = WavpackOpenFileInputEx(&memoryReader, &buffer, NULL, error, OPEN_TAGS, 0);
    } else {
        wpc = WavpackOpenFileInput(filePath, error, OPEN_TAGS, 0);
    }
    if (!wpc) {
        #ifdef DEBUG
        NSLog(@"Error opening WAVPack file: %s", error);
        #endif
        return; // or handle differently if you must keep streaming anyway
    }

    // Variables to hold metadata values
    NSString *artist       = @"Unknown Artist";
    NSString *album        = @"Unknown Album";
    NSString *title        = @"Unknown Title";
    NSString *trackNumber  = @"0";  // default
    float gainDbValue      = 0.0f;  // We'll store raw dB here

    // Helper pointer(s)
    char *tagValue;
    int tagSize;

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Artist"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Artist", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Artist", tagValue, tagSize + 1);
        artist = [self replaceSingleQuoteAndSmartQuotes:[NSString stringWithUTF8String:tagValue]];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Album"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Album", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Album", tagValue, tagSize + 1);
        album = [self replaceSingleQuoteAndSmartQuotes:[NSString stringWithUTF8String:tagValue]];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Title"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Title", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Title", tagValue, tagSize + 1);
        title = [self replaceSingleQuoteAndSmartQuotes:[NSString stringWithUTF8String:tagValue]];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract "Track"
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "Track", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "Track", tagValue, tagSize + 1);
        
        trackNumber = [NSString stringWithUTF8String:tagValue];
        // Remove leading zeros, but leave a single zero if the track number is actually 0
        NSRegularExpression *leadingZerosRegex = [NSRegularExpression regularExpressionWithPattern:@"^0+(?!$)"
                                                    options:0
                                                    error:nil];
        trackNumber = [leadingZerosRegex stringByReplacingMatchesInString:trackNumber
                                                    options:0
                                                    range:NSMakeRange(0, trackNumber.length)
                                                    withTemplate:@""];
        free(tagValue);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract replaygain_track_gain (dB)
    // ─────────────────────────────────────────────────────────────────────────────
    tagSize = WavpackGetTagItem(wpc, "replaygain_track_gain", NULL, 0);
    if (tagSize > 0) {
        tagValue = (char *)malloc(tagSize + 1);
        WavpackGetTagItem(wpc, "replaygain_track_gain", tagValue, tagSize + 1);

        NSString *gainString = [NSString stringWithUTF8String:tagValue];
        free(tagValue);

        // Remove trailing " dB" if present
        gainString = [gainString stringByReplacingOccurrencesOfString:@" dB" withString:@""];

        // Convert to float
        if (gainString && [gainString length] > 0) {
            gainDbValue = [gainString floatValue];
        } else {
            #ifdef DEBUG
            NSLog(@"[ReplayGain] WavPack invalid gainString extracted: %@", gainString);
            #endif
            gainDbValue = 0.0; // Default fallback value
        }

        // Store it in the property on the main thread (if UI code might be triggered)
        dispatch_async(dispatch_get_main_queue(), ^{
            self.replayGainValue = gainDbValue;

            #ifdef DEBUG
            NSLog(@"[ReplayGain] WavPack track gain: %.2f dB", self.replayGainValue);
            #endif

            if (self.airPlayStreamer) {
                [self.airPlayStreamer updateReplayGainValue:self.replayGainValue];
            } else {
                NSLog(@"[ReplayGain] AirPlayStreamer is nil, unable to update replay gain value.");
            }
        });
}

    // ─────────────────────────────────────────────────────────────────────────────
    // Extract Cover Art (if any)
    // ─────────────────────────────────────────────────────────────────────────────
    NSData *coverArtData = nil;
    tagSize = WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", NULL, 0);
    if (tagSize > 0) {
        void *binaryData = malloc(tagSize);
        WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", binaryData, tagSize);

        // Skip the filename portion
        unsigned char *imageData = (unsigned char *)binaryData;
        while (*imageData != '\0') { imageData++; }
        imageData++;

        NSUInteger imageDataLength = tagSize - (imageData - (unsigned char *)binaryData);
        coverArtData = [NSData dataWithBytes:imageData length:imageDataLength];
        
        free(binaryData);
    }

    // Close WavPack
    WavpackCloseFile(wpc);

    // 2. Update the UI & apply the new ReplayGain after we've parsed
    dispatch_block_t updateUIBlock = ^{
        // Update labels
        NSString *formattedTitle = [NSString stringWithFormat:@"%@. %@", trackNumber, title];
        [self.artistLabel setStringValue:artist];
        [self.albumLabel setStringValue:album];
        [self.titleLabel setStringValue:formattedTitle];

        // Display cover art, if any
        if (coverArtData) {
            NSImage *coverImage = [[NSImage alloc] initWithData:coverArtData];
            if (coverImage && coverImage.size.width > 0) {
                [self.coverArtView setImage:coverImage];
            } else {
                #ifdef DEBUG
                NSLog(@"Failed to create image from cover art data.");
                #endif
                [self.coverArtView setImage:nil];
            }
        } else {
            [self.coverArtView setImage:nil]; // no cover art
        }

        // Trigger notification
        [self triggerNowPlayingNotificationWithTitle:formattedTitle
                                              artist:artist
                                               album:album];
    };

    // 3. Dispatch the UI updates (and ReplayGain update) to the main queue
    dispatch_async(dispatch_get_main_queue(), updateUIBlock);
}

- (void)cleanupCoreAudioPlayback {
    if (playbackState.isPlaying) {
        // Set playbackState.isPlaying to NO to prevent further callbacks
        playbackState.isPlaying = NO;
        
        // Stop the AudioQueue
        AudioQueueStop(playbackState.audioQueue, true);
    }

    // Invalidate the progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    dispatch_block_t resetProgressBarBlock = ^{
        [self.progressBar setDoubleValue:0.0];
    };

    // Execute the block asynchronously on the main thread
    dispatch_async(dispatch_get_main_queue(), resetProgressBarBlock);

    // Free audio buffers
    for (int i = 0; i < NUM_BUFFERS; i++) {
        if (playbackState.buffers[i]) {
            AudioQueueFreeBuffer(playbackState.audioQueue, playbackState.buffers[i]);
            playbackState.buffers[i] = NULL;
        }
    }

    // Dispose of the audio queue
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);
        playbackState.audioQueue = NULL;
    }

    // Free the sample buffer
    if (playbackState.sampleBuffer) {
        free(playbackState.sampleBuffer);
        playbackState.sampleBuffer = NULL;
    }

    // Note: DO NOT close playbackState.wpc or reset other fields here
    // This ensures that WavPack playback can initialize correctly
}

- (void)setupUI {
    // Static dimensions for the window: 750x250
    CGFloat windowWidth = 750;

    // CD cover art position
    self.coverArtView = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 120, 120, 120)];
    self.coverArtView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.coverArtView.imageAlignment = NSImageAlignCenter;
    self.coverArtView.wantsLayer = YES; // ajuda com vibrancy e repaints
    self.coverArtView.layer.masksToBounds = YES;
    [self.view addSubview:self.coverArtView];

    // Histogram position (same height as CD art, twice as wide)
    CGFloat histogramWidth = 240;   // 2x CD art width (2 * 120)
    CGFloat histogramHeight = 120;  // Same as CD art height
    CGFloat histogramXPosition = 490;

    self.histogramView = [[HistogramView alloc] initWithFrame:NSMakeRect(histogramXPosition, 120, histogramWidth, histogramHeight)];
    [self.view addSubview:self.histogramView];

    // Labels for Artist, Album, and Title
    CGFloat labelXPosition = 160;   // 20 padding + 120 cover
    CGFloat labelMaxWidth  = 320;   // (440 - 160)

    // Artist label
    self.artistLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelXPosition, 205, labelMaxWidth, 30)];
    self.artistLabel.font = [NSFont systemFontOfSize:22];
    self.artistLabel.alignment = NSTextAlignmentLeft;
    self.artistLabel.bezeled = NO;
    self.artistLabel.drawsBackground = NO;
    self.artistLabel.editable = NO;
    self.artistLabel.selectable = NO;
    self.artistLabel.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.artistLabel];

    // Album label
    self.albumLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelXPosition, 165, labelMaxWidth, 30)];
    self.albumLabel.font = [NSFont systemFontOfSize:22];
    self.albumLabel.alignment = NSTextAlignmentLeft;
    self.albumLabel.bezeled = NO;
    self.albumLabel.drawsBackground = NO;
    self.albumLabel.editable = NO;
    self.albumLabel.selectable = NO;
    self.albumLabel.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.albumLabel];

    // Title label
    self.titleLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(labelXPosition, 125, labelMaxWidth, 30)];
    self.titleLabel.font = [NSFont systemFontOfSize:22];
    self.titleLabel.alignment = NSTextAlignmentLeft;
    self.titleLabel.bezeled = NO;
    self.titleLabel.drawsBackground = NO;
    self.titleLabel.editable = NO;
    self.titleLabel.selectable = NO;
    self.titleLabel.cell.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.view addSubview:self.titleLabel];

    // Buttons (centered horizontally at the bottom)
    CGFloat buttonWidth = 26;
    CGFloat buttonHeight = 26;
    NSInteger numberOfButtons = 8;
    CGFloat totalButtonWidth = buttonWidth * numberOfButtons;
    CGFloat startX = (windowWidth - totalButtonWidth) / 2.0;
    CGFloat buttonYPosition = 20;

    // ⏮️
    self.backwardButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.backwardButton.bordered = NO;
    self.backwardButton.controlSize = NSControlSizeLarge;
    self.backwardButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.backwardButton.alignment = NSTextAlignmentCenter;
    self.backwardButton.title = @"⏮️";
    self.backwardButton.target = self;
    self.backwardButton.action = @selector(backwardTrack);
    [self.view addSubview:self.backwardButton];

    // ▶️
    startX += buttonWidth;
    self.playButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.playButton.bordered = NO;
    self.playButton.controlSize = NSControlSizeLarge;
    self.playButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.playButton.alignment = NSTextAlignmentCenter;
    self.playButton.title = @"▶️";
    self.playButton.target = self;
    self.playButton.action = @selector(playAudio);
    [self.view addSubview:self.playButton];

    // ⏸️
    startX += buttonWidth;
    self.pauseButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.pauseButton.bordered = NO;
    self.pauseButton.controlSize = NSControlSizeLarge;
    self.pauseButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.pauseButton.alignment = NSTextAlignmentCenter;
    self.pauseButton.title = @"⏸️";
    self.pauseButton.target = self;
    self.pauseButton.action = @selector(pauseAudio);
    [self.view addSubview:self.pauseButton];

    // ⏹️
    startX += buttonWidth;
    self.stopButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.stopButton.bordered = NO;
    self.stopButton.controlSize = NSControlSizeLarge;
    self.stopButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.stopButton.alignment = NSTextAlignmentCenter;
    self.stopButton.title = @"⏹️";
    self.stopButton.target = self;
    self.stopButton.action = @selector(stopAudio);
    [self.view addSubview:self.stopButton];

    // ⏭️
    startX += buttonWidth;
    self.forwardButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.forwardButton.bordered = NO;
    self.forwardButton.controlSize = NSControlSizeLarge;
    self.forwardButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.forwardButton.alignment = NSTextAlignmentCenter;
    self.forwardButton.title = @"⏭️";
    self.forwardButton.target = self;
    self.forwardButton.action = @selector(forwardTrack);
    [self.view addSubview:self.forwardButton];

    // 🔁
    startX += buttonWidth;
    self.repeatButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.repeatButton.bordered = NO;
    self.repeatButton.controlSize = NSControlSizeLarge;
    self.repeatButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.repeatButton.alignment = NSTextAlignmentCenter;
    self.repeatButton.title = @"🔁";
    self.repeatButton.target = self;
    self.repeatButton.action = @selector(repeatTracks);
    [self.view addSubview:self.repeatButton];

    // 🔀
    startX += buttonWidth;
    self.shuffleButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.shuffleButton.bordered = NO;
    self.shuffleButton.controlSize = NSControlSizeLarge;
    self.shuffleButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.shuffleButton.alignment = NSTextAlignmentCenter;
    self.shuffleButton.title = @"🔀";
    self.shuffleButton.target = self;
    self.shuffleButton.action = @selector(shuffleTracks);
    [self.view addSubview:self.shuffleButton];

    // ⏺️
    startX += buttonWidth;
    self.recordButton = [[NSButton alloc] initWithFrame:NSMakeRect(startX, buttonYPosition, buttonWidth, buttonHeight)];
    self.recordButton.bordered = NO;
    self.recordButton.controlSize = NSControlSizeLarge;
    self.recordButton.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    self.recordButton.alignment = NSTextAlignmentCenter;
    self.recordButton.title = @"⏺️";
    self.recordButton.target = self;
    self.recordButton.action = @selector(recordAudio);
    [self.view addSubview:self.recordButton];

    // Progress bar
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(160, 80, windowWidth - 320, 20)];
    self.progressBar.indeterminate = NO;
    self.progressBar.minValue = 0.0;
    self.progressBar.maxValue = 100.0;
    self.progressBar.doubleValue = 0.0;
    [self.view addSubview:self.progressBar];

    // Play count label (lower-right)
    CGFloat labelWidth = 200, labelHeight = 30, padding = 10;
    self.playCountLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(windowWidth - labelWidth - padding, -5, labelWidth, labelHeight)];
    self.playCountLabel.font = [NSFont systemFontOfSize:11];
    self.playCountLabel.alignment = NSTextAlignmentRight;
    self.playCountLabel.bezeled = NO;
    self.playCountLabel.drawsBackground = NO;
    self.playCountLabel.editable = NO;
    self.playCountLabel.selectable = NO;
    [self.view addSubview:self.playCountLabel];

    // Combo box
    [self createComboBox];

    // **Garante que a capa fica por cima de tudo o que foi adicionado depois**
    [self.view addSubview:self.coverArtView positioned:NSWindowAbove relativeTo:nil];
}

#pragma mark - HTML ”Now Playing“

- (void)generateNowPlayingPage {
    // Get the data from the UI elements
    // Declare variables to hold UI data
    __block NSString *artistName = @"";
    __block NSString *albumName = @"";
    __block NSString *songTitle = @"";
    __block NSImage *coverArtImage = nil;

    // Access UI elements on the main thread
    dispatch_sync(dispatch_get_main_queue(), ^{
        artistName = self.artistLabel.stringValue ?: @"";
        albumName = self.albumLabel.stringValue ?: @"";
        songTitle = self.titleLabel.stringValue ?: @"";
        coverArtImage = self.coverArtView.image;
    });

    // Define the paths
    NSString *homeDirectory = NSHomeDirectory();
    NSString *sitesDirectory = [homeDirectory stringByAppendingPathComponent:@"Sites"];
    NSString *htmlFilePath = [sitesDirectory stringByAppendingPathComponent:@"now_playing.html"];
    NSString *coverImagePath = [sitesDirectory stringByAppendingPathComponent:@"cover.png"];

    // Ensure the Sites directory exists
    NSFileManager *fileManager = [NSFileManager defaultManager];
    if (![fileManager fileExistsAtPath:sitesDirectory]) {
        NSError *error = nil;
        [fileManager createDirectoryAtPath:sitesDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[HTML] Error creating Sites directory: %@", error);
            #endif
            return;
        }
    }

    // Save the resized cover art image as cover.png in ~/Sites/
    if (coverArtImage) {
        // Get the CGImage from NSImage
        CGImageRef cgImage = [coverArtImage CGImageForProposedRect:NULL context:nil hints:nil];
        if (cgImage) {
            CGSize targetSize = CGSizeMake(600, 600); // Desired size
            CGFloat oversampleFactor = 4.0; // Oversampling factor (e.g., 2x)
            CGSize oversampledSize = CGSizeMake(targetSize.width * oversampleFactor, targetSize.height * oversampleFactor);

            // Create an oversampled bitmap context
            CGContextRef oversampleContext = CGBitmapContextCreate(NULL,
                                                                   oversampledSize.width,
                                                                   oversampledSize.height,
                                                                   CGImageGetBitsPerComponent(cgImage),
                                                                   0,
                                                                   CGImageGetColorSpace(cgImage),
                                                                   CGImageGetBitmapInfo(cgImage));

            if (oversampleContext) {
                // Set interpolation quality for oversampling
                CGContextSetInterpolationQuality(oversampleContext, kCGInterpolationHigh);
                CGContextSetShouldAntialias(oversampleContext, true);

                // Draw the image into the oversampled context
                CGContextDrawImage(oversampleContext, CGRectMake(0, 0, oversampledSize.width, oversampledSize.height), cgImage);

                // Create a CGImage from the oversampled context
                CGImageRef oversampledImage = CGBitmapContextCreateImage(oversampleContext);

                // Now downscale the oversampled image to the target size
                CGContextRef targetContext = CGBitmapContextCreate(NULL,
                                                                   targetSize.width,
                                                                   targetSize.height,
                                                                   CGImageGetBitsPerComponent(oversampledImage),
                                                                   0,
                                                                   CGImageGetColorSpace(oversampledImage),
                                                                   CGImageGetBitmapInfo(oversampledImage));

                if (targetContext) {
                    // Set interpolation quality for downscaling
                    CGContextSetInterpolationQuality(targetContext, kCGInterpolationHigh);
                    CGContextSetShouldAntialias(targetContext, true);

                    // Draw the oversampled image into the target context
                    CGContextDrawImage(targetContext, CGRectMake(0, 0, targetSize.width, targetSize.height), oversampledImage);

                    // Create the final downscaled image
                    CGImageRef finalImage = CGBitmapContextCreateImage(targetContext);

                    // Save the resized image as PNG
                    NSURL *outputURL = [NSURL fileURLWithPath:coverImagePath];

                    // Use the new UTTypePNG
                    CFStringRef uti = (__bridge CFStringRef)UTTypePNG.identifier;

                    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
                        (__bridge CFURLRef)outputURL,
                        uti,
                        1,
                        NULL);

                    if (destination) {
                        CGImageDestinationAddImage(destination, finalImage, NULL); // No quality setting needed for PNG
                        if (!CGImageDestinationFinalize(destination)) {
                            #ifdef DEBUG
                            NSLog(@"[HTML] Failed to write image to %@", coverImagePath);
                            #endif
                        }
                        CFRelease(destination);
                    } else {
                        #ifdef DEBUG
                        NSLog(@"[HTML] Failed to create CGImageDestination for %@", coverImagePath);
                        #endif
                    }

                    // Clean up
                    CGImageRelease(finalImage);
                    CGContextRelease(targetContext);
                } else {
                    #ifdef DEBUG
                    NSLog(@"[HTML] Failed to create target context");
                    #endif
                }

                // Clean up
                CGImageRelease(oversampledImage);
                CGContextRelease(oversampleContext);
            } else {
                #ifdef DEBUG
                NSLog(@"[HTML] Failed to create oversampled context");
                #endif
            }
        } else {
            #ifdef DEBUG
            NSLog(@"[HTML] Failed to get CGImage from NSImage");
            #endif
        }
    } else {
        // Use a default placeholder image if cover art is not available
        NSString *placeholderPath = [[NSBundle mainBundle] pathForResource:@"placeholder" ofType:@"png"];
        if (placeholderPath) {
            [fileManager copyItemAtPath:placeholderPath toPath:coverImagePath error:nil];
        } else {
            #ifdef DEBUG
            NSLog(@"[HTML] Placeholder image not found in app bundle");
            #endif
        }
    }

    // Generate the HTML content
    NSMutableString *htmlContent = [NSMutableString stringWithString:
    @"<!DOCTYPE html>\n"
    @"<html>\n"
    @"<head>\n"
    @"    <meta charset=\"UTF-8\">\n"
    @"    <meta name=\"generator\" content=\"tocaTintas\">\n"
    @"    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">\n"
    @"    <meta name=\"disabled-adaptations\" content=\"watch\">\n"
    @"    <meta http-equiv=\"refresh\" content=\"10\">\n"
    ];

    if (songTitle.length > 0 && artistName.length > 0 && albumName.length > 0) {
        [htmlContent appendFormat:
         @"    <meta property=\"og:title\" content=\"Now Playing: %@\">\n", songTitle];
        [htmlContent appendFormat:
         @"    <meta property=\"og:description\" content=\"Enjoy the latest track by %@ from the album %@.\">\n", artistName, albumName];
    } else {
        [htmlContent appendString:
         @"    <meta property=\"og:title\" content=\"Now Playing\">\n"];
        [htmlContent appendString:
         @"    <meta property=\"og:description\" content=\"Discover the latest music.\">\n"];
    }

    [htmlContent appendString:
    @"    <meta property=\"og:image\" content=\"cover.png\">\n"
    @"    <meta property=\"og:image:type\" content=\"image/png\">\n"
    @"    <meta property=\"og:image:width\" content=\"150\">\n"
    @"    <meta property=\"og:image:height\" content=\"150\">\n"
    @"    <meta property=\"og:url\" content=\"https://zpsurfistaprateadopreto.local/~amaral/now_playing.html\">\n"
    @"    <meta property=\"og:type\" content=\"music.song\">\n"
    @"    <title>tocaTintas</title>\n"
    @"    <link rel=\"icon\" type=\"image/png\" href=\"images/pedro-logotipo-caixa.png\">\n"
    @"\n"
    @"    <style>\n"
    @"        body {\n"
    @"            margin: 0;\n"
    @"            padding: 0;\n"
    @"            text-align: center;\n"
    @"            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, 'Open Sans', 'Helvetica Neue', sans-serif;\n"
    @"            background-color: black;\n"
    @"            color: white;\n"
    @"        }\n"
    @"        .cover {\n"
    @"            margin-top: 33vh; /* 33% da altura da janela visível */\n"
    @"        }\n"
    @"        .cover img {\n"
    @"            width: 150px;\n"
    @"            height: 150px;\n"
    @"            border-radius: 15px;\n"
    @"            cursor: pointer;\n"
    @"        }\n"
    @"        .info {\n"
    @"            padding: 5px;\n"
    @"        }\n"
    @"        .info h1, .info h2, .info h3 {\n"
    @"            margin: 5px;\n"
    @"            font-size: 14px;\n"
    @"            line-height: 1.2;\n"
    @"        }\n"
    @"    </style>\n"
    @"</head>\n"
    @"<body>\n"
    @"    <!-- Add the cover art image as a link -->\n"
    @"    <div class=\"cover\">\n"
    @"        <a href=\"now_playing.html\">\n"
    @"            <img src=\"cover.png?timestamp\" alt=\"Cover Art\">\n"
    @"        </a>\n"
    @"    </div>\n"
    @"\n"
    @"    <!-- Add the song information -->\n"
    @"    <div class=\"info\">\n"];

    if (artistName.length > 0) {
        [htmlContent appendFormat:@"<!-- ARTIST -->\n<h1>%@</h1>\n", artistName];
    }
    if (albumName.length > 0) {
        [htmlContent appendFormat:@"<!-- ALBUM -->\n<h2>%@</h2>\n", albumName];
    }
    if (songTitle.length > 0) {
        [htmlContent appendFormat:@"<!-- SONG -->\n<h3>%@</h3>\n", songTitle];
    }

    [htmlContent appendString:
    @"    </div>\n"
    @"</body>\n"
    @"</html>\n"];

    // Write the HTML content to now_playing.html
    NSError *writeError = nil;
    [htmlContent writeToFile:htmlFilePath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
    if (writeError) {
        #ifdef DEBUG
        NSLog(@"[HTML] Error writing HTML file: %@", writeError);
        #endif
    }

    // Save the refresh icon image to ~/Sites/refresh_icon.png
    // Ensure you have a 'refresh_icon.png' in your app bundle
    NSString *refreshIconPath = [sitesDirectory stringByAppendingPathComponent:@"refresh_icon.png"];
    NSString *bundleRefreshIconPath = [[NSBundle mainBundle] pathForResource:@"refresh_icon" ofType:@"png"];
    if (bundleRefreshIconPath) {
        [fileManager removeItemAtPath:refreshIconPath error:nil]; // Remove existing file if it exists
        [fileManager copyItemAtPath:bundleRefreshIconPath toPath:refreshIconPath error:nil];
    } else {
        #ifdef DEBUG
        NSLog(@"[HTML] Refresh icon image not found in app bundle");
        #endif
    }
}

#pragma mark - NSComboBoxDataSource Methods

// Returns the number of items in the combo box
- (NSInteger)numberOfItemsInComboBox:(NSComboBox *)comboBox {
    return self.displayNames.count;
}

// Returns the object value for the item at the specified index
- (id)comboBox:(NSComboBox *)comboBox objectValueForItemAtIndex:(NSInteger)index {
    return self.displayNames[index];
}

// Returns the index of the item matching the given string
- (NSUInteger)comboBox:(NSComboBox *)comboBox indexOfItemWithStringValue:(NSString *)string {
    NSString *lowercaseInput = [string lowercaseString];
    for (NSUInteger i = 0; i < self.displayNames.count; i++) {
        NSString *item = [self.displayNames[i] lowercaseString];
        if ([item isEqualToString:lowercaseInput]) {
            return i;
        }
    }
    return NSNotFound;
}

// Returns the completed string for the given input
- (NSString *)comboBox:(NSComboBox *)comboBox completedString:(NSString *)string {
    #ifdef DEBUG
    NSLog(@"comboBox:completedString: called with input string: %@", string);
    #endif

    NSString *lowercaseInput = [string lowercaseString];

    // Corrected regular expression to remove leading numbers and specific special characters
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9-]+\\s*"
                                                                           options:0
                                                                             error:nil];

    // Iterate through the display names
    for (NSString *displayName in self.displayNames) {
        // Convert display name to lowercase for case-insensitive matching
        NSString *lowercaseDisplayName = [displayName lowercaseString];

        // Remove leading digits and special characters from the display name
        NSString *cleanedDisplayName = [regex stringByReplacingMatchesInString:lowercaseDisplayName
                                                                       options:0
                                                                         range:NSMakeRange(0, lowercaseDisplayName.length)
                                                                  withTemplate:@""];

        #ifdef DEBUG
        NSLog(@"Checking displayName: %@, Cleaned displayName: %@", displayName, cleanedDisplayName);
        #endif

        // Check if the input string matches the prefix of the cleaned display name
        if ([cleanedDisplayName hasPrefix:lowercaseInput]) {
            #ifdef DEBUG
            NSLog(@"Found match: %@", displayName);
            #endif
            return displayName; // Return the display name for auto-completion
        }
    }

    #ifdef DEBUG
    NSLog(@"No match found.");
    #endif
    return nil;
}

#pragma mark - NSComboBoxDelegate Methods

- (void)comboBoxWillPopUp:(NSNotification *)notification {
    if (self.isPlaylistModeActive) {
        // Check if the files in the playlist still exist
        [self validatePlaylistFiles];
    } else {
        [self loadAudioFiles];
    }
    // Update the combo box items
    [self createComboBox];
}

- (void)comboBoxSelectionChanged:(NSComboBox *)comboBox {
    NSInteger selectedIndex = comboBox.indexOfSelectedItem;

    if (selectedIndex > 0 && selectedIndex <= self.audioFiles.count) {
        [self stopAudio];

        // Get the selected track URL from the original audioFiles array
        NSURL *selectedTrackURL = self.audioFiles[selectedIndex - 1];
        self.currentTrackURL = selectedTrackURL;

        if (self.isShuffleModeActive) {
            // Find the index of the selected track in the shuffled array
            NSUInteger shuffledIndex = [self.shuffledTracks indexOfObject:selectedTrackURL];
            if (shuffledIndex != NSNotFound) {
                self.currentTrackIndex = shuffledIndex;
            } else {
                #ifdef DEBUG
                NSLog(@"Error: Selected track not found in shuffledAudioFiles.");
                #endif
                return;
            }
        } else {
            self.currentTrackIndex = selectedIndex - 1;
        }

        // Play audio for the selected track
        [self playAudio];

        // Ensure combobox reflects the correct item
        [self.songComboBox selectItemAtIndex:selectedIndex];
    } else if (selectedIndex == 0) {
        #ifdef DEBUG
        NSLog(@"User selected the placeholder 'choose a song'. No track selected.");
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"Invalid song selection.");
        #endif
    }
}

#pragma mark - Combo Box Setup

- (void)createComboBox {
    if (!self.audioFiles || self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(@"No audio files to populate the combo box.");
        #endif
        return;
    }

    NSMutableArray<NSString *> *displayNames = [NSMutableArray array];
    [displayNames addObject:NSLocalizedString(@"choose_song_here", @"Prompt for choosing a song")]; // Placeholder

    NSMutableArray<NSString *> *fullFileNames = [NSMutableArray array];

    // Remove leading digits and special characters from the song name
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^[0-9-]+\\s*"
                                                                           options:0
                                                                             error:nil];

    for (NSURL *fileURL in self.audioFiles) {
        NSString *fileName = fileURL.lastPathComponent;
        [fullFileNames addObject:fileName]; // Store full name for matching

        // Extract the song name and extension
        NSString *songName = [fileName stringByDeletingPathExtension];
        NSString *extension = [fileName pathExtension];

        // Remove leading digits and special characters from the song name
        NSString *cleanedSongName = [regex stringByReplacingMatchesInString:songName
                                                                    options:0
                                                                      range:NSMakeRange(0, songName.length)
                                                               withTemplate:@""];

        // Construct the display string in the desired format
        NSString *displayName = [NSString stringWithFormat:@"%@ (%@)", cleanedSongName, extension];

        // Log the display name
        #ifdef DEBUG
        NSLog(@"Display Name: %@", displayName);
        #endif

        [displayNames addObject:displayName];
    }

    // Store display names and full file names for delegate methods
    self.displayNames = [displayNames copy];
    self.fullFileNamesForMatching = [fullFileNames copy];

    if (self.songComboBox) {
        // Reload the combo box data
        [self.songComboBox reloadData];

        NSInteger selectedIndex = self.currentTrackIndex + 1; // Adjust for placeholder
        if (selectedIndex >= 0 && selectedIndex < self.displayNames.count) {
            [self.songComboBox selectItemAtIndex:selectedIndex];
        } else {
            [self.songComboBox selectItemAtIndex:0]; // Placeholder
        }
    } else {
        self.songComboBox = [[NSComboBox alloc] initWithFrame:NSMakeRect(20, 20, 190, 26)];

        // Set up the combo box to use a data source
        [self.songComboBox setUsesDataSource:YES];
        self.songComboBox.dataSource = self;

        [self.songComboBox setNumberOfVisibleItems:40];
        NSInteger selectedIndex = self.currentTrackIndex + 1; // Adjust for placeholder
        if (selectedIndex >= 0 && selectedIndex < displayNames.count) {
            [self.songComboBox selectItemAtIndex:selectedIndex];
        } else {
            [self.songComboBox selectItemAtIndex:0]; // Placeholder
        }
        [self.songComboBox setTarget:self];
        [self.songComboBox setAction:@selector(comboBoxSelectionChanged:)];
        self.songComboBox.delegate = self;

        // Enable autocomplete for the combo box
        [self.songComboBox setCompletes:YES];

        [self.view addSubview:self.songComboBox];
    }

    // Log the stored full file names
    #ifdef DEBUG
    NSLog(@"Full file names stored for matching: %@", self.fullFileNamesForMatching);
    #endif
}

// Read data from the FIFO file and update the histogram
- (void)readFifoDirectly {
    NSString *fifoPath = @"/var/tmp/cava_fifo";
    
    int fileDescriptor = open([fifoPath UTF8String], O_RDONLY | O_NONBLOCK);
    if (fileDescriptor < 0) {
        perror("[FIFO] Failed to open FIFO file");
        #ifdef DEBUG
        NSLog(@"[FIFO] Failed to open FIFO file at path: %@", fifoPath);
        #endif
        return;
    }
    #ifdef DEBUG
    NSLog(@"[FIFO] FIFO file opened successfully.");
    #endif
    dispatch_queue_t fifoQueue = dispatch_queue_create("com.example.cavahistogram.fifoqueue", DISPATCH_QUEUE_SERIAL);
    
    dispatch_async(fifoQueue, ^{
        while (1) {
            uint16_t buffer[31];  // Reading as 16-bit unsigned integers
            ssize_t size = read(fileDescriptor, buffer, sizeof(buffer));

            if (size > 0) {
                #ifdef DEBUG
                NSLog(@"[FIFO] Data read from FIFO: %ld bytes", size);
                #endif
                if (size == sizeof(buffer)) {
                    NSMutableArray<NSNumber *> *parsedLeftValues = [NSMutableArray array];
                    NSMutableArray<NSNumber *> *parsedRightValues = [NSMutableArray array];
                    
                    for (NSUInteger i = 0; i < 15; i++) {
                        uint16_t rawValue = buffer[i];
                        uint16_t scaledValue = (rawValue * 1000) / 65535;
                        [parsedLeftValues addObject:@(scaledValue)];
                    }
                    for (NSUInteger i = 15; i < 30; i++) {
                        uint16_t rawValue = buffer[i];
                        uint16_t scaledValue = (rawValue * 1000) / 65535;
                        [parsedRightValues addObject:@(scaledValue)];
                    }

                    // Debounce to prevent jittery updates
                    static NSTimeInterval lastUpdateTime = 0;
                    NSTimeInterval currentTime = [NSDate timeIntervalSinceReferenceDate];
                    if (currentTime - lastUpdateTime > 0.05) {  // Update every 50ms
                        dispatch_async(dispatch_get_main_queue(), ^{
                            HistogramView *histogramView = (HistogramView *)self.histogramView;
                            [histogramView updateHistogramWithLeftChannel:parsedLeftValues rightChannel:parsedRightValues];
                            [histogramView setNeedsDisplay:YES];
                            [histogramView displayIfNeeded];
                        });
                        lastUpdateTime = currentTime;
                    }
                } else {
                    #ifdef DEBUG
                    NSLog(@"[FIFO] Warning: Incomplete data chunk received.");
                    #endif
                }
            } else if (size == 0) {
                #ifdef DEBUG
                NSLog(@"[FIFO] No data available, sleeping…");
                #endif
                [NSThread sleepForTimeInterval:0.1];
            } else {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    #ifdef DEBUG
                    NSLog(@"[FIFO] No data available yet, continuing to read…");
                    #endif
                    [NSThread sleepForTimeInterval:0.1];
                    continue;
                } else {
                    perror("[FIFO] Failed to read from FIFO");
                    #ifdef DEBUG
                    NSLog(@"[FIFO] Failed to read from FIFO");
                    #endif
                    break;
                }
            }
        }
        
        close(fileDescriptor);
    });
}

#pragma mark - Show button selection with colors

// Give visual feedback for when repeat is active
- (void)updateRepeatButtonAppearance:(BOOL)isActive {
    self.repeatButton.wantsLayer = YES;

    if (isActive) {
        self.repeatButton.layer.backgroundColor = [[NSColor systemGreenColor] CGColor];
        self.repeatButton.layer.cornerRadius = 6.0;
        self.repeatButton.layer.masksToBounds = YES;
    } else {
        self.repeatButton.layer.backgroundColor = [[NSColor clearColor] CGColor];
        self.repeatButton.layer.cornerRadius = 0.0;
        self.repeatButton.layer.masksToBounds = NO;
    }
}

// Give visual feedback for when repeat is active
- (void)updateShuffleButtonAppearance:(BOOL)isActive {
    self.shuffleButton.wantsLayer = YES;

    if (isActive) {
        self.shuffleButton.layer.backgroundColor = [[NSColor systemGreenColor] CGColor];
        self.shuffleButton.layer.cornerRadius = 6.0;
        self.shuffleButton.layer.masksToBounds = YES;
    } else {
        self.shuffleButton.layer.backgroundColor = [[NSColor clearColor] CGColor];
        self.shuffleButton.layer.cornerRadius = 0.0;
        self.shuffleButton.layer.masksToBounds = NO;
    }
}

// Give visual feedback for when pause is active
- (void)updatePauseButtonAppearance:(BOOL)isActive {
    self.pauseButton.wantsLayer = YES;

    if (isActive) {
        self.pauseButton.layer.backgroundColor = [[NSColor systemGreenColor] CGColor];
        self.pauseButton.layer.cornerRadius = 6.0;
        self.pauseButton.layer.masksToBounds = YES;
    } else {
        self.pauseButton.layer.backgroundColor = [[NSColor clearColor] CGColor];
        self.pauseButton.layer.cornerRadius = 0.0;
        self.pauseButton.layer.masksToBounds = NO;
    }
}

// Add visual feedback for when recording is active
- (void)updateRecordButtonAppearance:(BOOL)isActive {
    self.recordButton.wantsLayer = YES;

    if (isActive) {
        self.recordButton.layer.backgroundColor = [[NSColor systemRedColor] CGColor];
        self.recordButton.layer.cornerRadius = 6.0;
        self.recordButton.layer.masksToBounds = YES;
    } else {
        self.recordButton.layer.backgroundColor = [[NSColor clearColor] CGColor];
        self.recordButton.layer.cornerRadius = 0.0;
        self.recordButton.layer.masksToBounds = NO;
    }
}

- (void)repeatTracks {
    if (self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(@"No audio files to repeat.");
        #endif
        return;
    }

    // Toggle repeat mode
    self.isRepeatModeActive = !self.isRepeatModeActive;

    // Update the appearance of the repeat button
    [self updateRepeatButtonAppearance:self.isRepeatModeActive];

    if (self.isRepeatModeActive) {
        #ifdef DEBUG
        NSLog(@"Repeat mode activated.");
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"Repeat mode deactivated.");
        #endif
    }

    // Ensure the current track maps to its original counterpart
    #ifdef DEBUG
    NSURL *originalTrackURL = self.shuffledToOriginalMap[self.currentTrackURL] ?: self.currentTrackURL;

    NSLog(@"Current Track URL: %@", self.currentTrackURL);
    NSLog(@"Original Track URL: %@", originalTrackURL);
    #endif

    // Ensure the delegate is set for track completion
    self.audioPlayer.delegate = self;
}

// Audio player delegate method - Handle completion of a track
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (flag) {
        // Check if the file that finished playing is FLAC
        if ([[self.currentTrackURL pathExtension].lowercaseString isEqualToString:@"flac"]) {
            // Clear metadata only when the FLAC track finishes
            dispatch_block_t clearMetadataBlock = ^{
                [self.artistLabel setStringValue:@""];
                [self.albumLabel setStringValue:@""];
                [self.titleLabel setStringValue:@""];
                [self.coverArtView setImage:nil];
                [self.trackNumberLabel setStringValue:@""];
            };

            // Dispatch the clear metadata block to the main queue
            dispatch_async(dispatch_get_main_queue(), clearMetadataBlock);
        }

        // Increment the play count and update the label
        NSURL *originalTrackURL = self.shuffledToOriginalMap[self.currentTrackURL] ?: self.currentTrackURL;

        // Move to the next track or repeat the current one
        if (self.isRepeatModeActive) {
            #ifdef DEBUG
            NSLog(@"Repeat mode is active. Replaying the current track.");
            #endif
            [self playAudio];
            
            // Clear the play count label
            dispatch_block_t updateLabelBlock = ^{
                [self.playCountLabel setStringValue:@""];
            };

            // Dispatch to the main thread to clear the play count label immediately
            dispatch_async(dispatch_get_main_queue(), updateLabelBlock);

            // Delay the label update by 5 seconds
            dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC);
            dispatch_after(delay, dispatch_get_main_queue(), ^{
                // Update the play count label after 5 seconds
                [self updatePlayCountLabelForTrack:originalTrackURL];
            });
        } else {
            #ifdef DEBUG
            NSLog(@"Playing next track.");
            #endif
            [self playNextTrack];  // Play the next track
        }
    } else {
        #ifdef DEBUG
        NSLog(@"Track did not finish successfully.");
        #endif
    }
}

// Shuffle tracks method: Initialize and shuffle the track list
- (void)shuffleTracks {
    if (self.audioFiles.count == 0) {
        #ifdef DEBUG
        NSLog(@"No audio files to shuffle.");
        #endif
        return;
    }

    // Capture the current playback time to resume later if needed
    NSTimeInterval currentPlaybackTime = 0;
    if (self.audioPlayer.isPlaying) {
        currentPlaybackTime = self.audioPlayer.currentTime;
    }

    // Toggle shuffle mode
    self.isShuffleModeActive = !self.isShuffleModeActive;

    // Update shuffle button appearance (implement this method as needed)
    [self updateShuffleButtonAppearance:self.isShuffleModeActive];

    if (self.isShuffleModeActive) {
        #ifdef DEBUG
        NSLog(@"Shuffle mode activated.");
        #endif

        // Initialize shuffled track list
        [self initializeShuffledTrackList];

        // Set currentTrackIndex to the corresponding index in shuffledTracks
        if (self.currentTrackIndex >= 0 && self.currentTrackIndex < self.audioFiles.count) {
            NSURL *currentTrackURL = self.audioFiles[self.currentTrackIndex];
            NSUInteger shuffledIndex = [self.shuffledTracks indexOfObject:currentTrackURL];
            self.currentTrackIndex = (shuffledIndex != NSNotFound) ? shuffledIndex : 0;
        } else {
            self.currentTrackIndex = 0;
        }

        // Start playing from the shuffled list
        if (self.shuffledTracks.count > 0) {
            [self playAudio];
            // Resume playback from the captured position
            [self.audioPlayer setCurrentTime:currentPlaybackTime];
        }

        // Update combo box to show placeholder in shuffle mode
        [self.songComboBox selectItemAtIndex:0]; // Placeholder at index 0

    } else {
        #ifdef DEBUG
        NSLog(@"Shuffle mode deactivated.");
        #endif

        // Map the current shuffled track back to the original track
        NSURL *currentShuffledTrackURL = nil;
        if (self.currentTrackIndex >= 0 && self.currentTrackIndex < self.shuffledTracks.count) {
            currentShuffledTrackURL = self.shuffledTracks[self.currentTrackIndex];
        }

        NSUInteger originalIndex = NSNotFound;
        if (currentShuffledTrackURL) {
            originalIndex = [self.audioFiles indexOfObject:currentShuffledTrackURL];
        }

        self.currentTrackIndex = (originalIndex != NSNotFound) ? originalIndex : 0;

        // Resume playback from the original track
        if (self.audioFiles.count > 0) {
            [self playAudio];
            // Resume playback from the captured position
            [self.audioPlayer setCurrentTime:currentPlaybackTime];
        } else {
            [self stopAudio];
        }

        // Update combo box to show the currently playing track
        [self.songComboBox selectItemAtIndex:self.currentTrackIndex + 1]; // Adjust for placeholder
    }
}

// Initialize and shuffle the track list
- (void)initializeShuffledTrackList {
    #ifdef DEBUG
    NSLog(@"Initializing and shuffling the track list.");
    #endif

    // Create a mutable copy of audioFiles
    self.shuffledTracks = [self.audioFiles mutableCopy];

    // Shuffle the array
    [self shuffleArray:self.shuffledTracks];

    // Initialize the map between shuffled tracks and original tracks
    self.shuffledToOriginalMap = [NSMutableDictionary dictionary];
    for (NSURL *trackURL in self.shuffledTracks) {
        // Since we're shuffling the same objects, the mapping can be direct
        self.shuffledToOriginalMap[trackURL] = trackURL;
    }
}

// Helper method to shuffle an array
- (void)shuffleArray:(NSMutableArray *)array {
    for (NSUInteger i = array.count; i > 1; i--) {
        NSUInteger j = arc4random_uniform((uint32_t)i);
        [array exchangeObjectAtIndex:i - 1 withObjectAtIndex:j];
    }
}

// Optimized method to load audio files with correct sorting
- (void)loadAudioFiles {
    // Check if we are in playlist mode
    if (self.isPlaylistModeActive) {
        // If a playlist is loaded, do not reload audio files from the directory
        return;
    }

    // Load the directory path from user defaults or use a default path
    NSString *directoryPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"songsDirectoryPath"] ?: @"/Users/amaral/Downloads/CDs";
    NSURL *directoryURL = [NSURL fileURLWithPath:directoryPath];
    NSFileManager *fileManager = [NSFileManager defaultManager];

    // Get the attributes of the directory to check for changes
    NSError *attributesError = nil;
    NSDictionary *attributes = [fileManager attributesOfItemAtPath:directoryPath error:&attributesError];
    if (attributesError) {
        #ifdef DEBUG
        NSLog(@"Error accessing directory attributes: %@", attributesError.localizedDescription);
        #endif
        return;
    }
    NSDate *modificationDate = attributes[NSFileModificationDate];

    // If the directory hasn't changed, use the cached audio files
    if ([self.directoryModificationDate isEqualToDate:modificationDate] && self.cachedAudioFiles) {
        self.audioFiles = self.cachedAudioFiles;
        return;
    }

    // Update the cached modification date
    self.directoryModificationDate = modificationDate;

    // Define the keys to prefetch
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLNameKey, NSURLPathKey];

    // Enumerate through the directory to find audio files
    NSDirectoryEnumerator<NSURL *> *enumerator = [fileManager enumeratorAtURL:directoryURL
                                                   includingPropertiesForKeys:keys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:^BOOL(NSURL *url, NSError *error) {
        #ifdef DEBUG
        NSLog(@"Error loading file: %@", error.localizedDescription);
        #endif
        return YES; // Continue enumerating
    }];

    NSMutableArray<NSURL *> *foundAudioFiles = [NSMutableArray array];
    NSSet *allowedExtensions = [NSSet setWithObjects:@"mp3", @"m4a", @"wav", @"aac", @"flac", @"wv", @"opus", @"aiff", nil];

    // Filter and collect audio files
    for (NSURL *fileURL in enumerator) {
        NSDictionary *resourceValues = [fileURL resourceValuesForKeys:keys error:nil];

        // Skip if it's not a regular file
        if (![resourceValues[NSURLIsRegularFileKey] boolValue]) {
            continue;
        }

        NSString *extension = fileURL.pathExtension.lowercaseString;

        // Exclude .m4p files and include supported audio formats
        if (![extension isEqualToString:@"m4p"] && [allowedExtensions containsObject:extension]) {
            [foundAudioFiles addObject:fileURL];
        }
    }

    // Sort the audio files by artist name, album name, CD number, and track name
    NSArray<NSURL *> *sortedAudioFiles = [foundAudioFiles sortedArrayUsingComparator:^NSComparisonResult(NSURL *url1, NSURL *url2) {
        // Get path components
        NSArray<NSString *> *directoryComponents = directoryURL.pathComponents;
        NSInteger baseIndex = directoryComponents.count;

        NSArray<NSString *> *pathComponents1 = url1.pathComponents;
        NSArray<NSString *> *pathComponents2 = url2.pathComponents;

        // Extract artist names
        NSString *artist1 = (pathComponents1.count > baseIndex) ? pathComponents1[baseIndex] : @"";
        NSString *artist2 = (pathComponents2.count > baseIndex) ? pathComponents2[baseIndex] : @"";

        // Compare artist names
        NSComparisonResult artistComparison = [artist1 compare:artist2 options:NSCaseInsensitiveSearch];
        if (artistComparison != NSOrderedSame) {
            return artistComparison;
        }

        // Extract album names
        NSString *album1 = (pathComponents1.count > baseIndex + 1) ? pathComponents1[baseIndex + 1] : @"";
        NSString *album2 = (pathComponents2.count > baseIndex + 1) ? pathComponents2[baseIndex + 1] : @"";

        // Compare album names
        NSComparisonResult albumComparison = [album1 compare:album2 options:NSCaseInsensitiveSearch];
        if (albumComparison != NSOrderedSame) {
            return albumComparison;
        }

        // Extract CD directories (if any)
        NSString *cd1 = (pathComponents1.count > baseIndex + 2) ? pathComponents1[baseIndex + 2] : @"";
        NSString *cd2 = (pathComponents2.count > baseIndex + 2) ? pathComponents2[baseIndex + 2] : @"";

        // Extract CD numbers
        NSString *cdNumber1 = [self extractCDNumberFromString:cd1];
        NSString *cdNumber2 = [self extractCDNumberFromString:cd2];

        // Compare CD numbers numerically
        NSComparisonResult cdComparison = [cdNumber1 compare:cdNumber2 options:NSNumericSearch];
        if (cdComparison != NSOrderedSame) {
            return cdComparison;
        }

        // Compare track names numerically and case-insensitively
        NSString *track1 = url1.lastPathComponent;
        NSString *track2 = url2.lastPathComponent;
        return [track1 compare:track2 options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];

    // Preserve the current track URL
    NSURL *currentTrackURL = nil;
    if (self.currentTrackIndex >= 0) {
        if (self.isShuffleModeActive && self.shuffledTracks.count > self.currentTrackIndex) {
            currentTrackURL = self.shuffledTracks[self.currentTrackIndex];
        } else if (self.audioFiles.count > self.currentTrackIndex) {
            currentTrackURL = self.audioFiles[self.currentTrackIndex];
        }
    }

    // Update the cached audio files and refresh the UI if there are changes
    if (![self.cachedAudioFiles isEqualToArray:sortedAudioFiles]) {
        self.cachedAudioFiles = sortedAudioFiles;
        self.audioFiles = sortedAudioFiles;
        [self saveAudioFilesCache];

        // Recreate shuffled tracks if shuffle mode is active
        if (self.isShuffleModeActive) {
            [self initializeShuffledTrackList]; // Ensure this method is up to date
        }

        // Update the current track index
        BOOL currentTrackExists = NO;
        if (currentTrackURL) {
            NSString *currentTrackPath = [currentTrackURL.path stringByStandardizingPath];
            NSArray<NSURL *> *searchArray = self.isShuffleModeActive ? self.shuffledTracks : self.audioFiles;
            NSUInteger newIndex = NSNotFound;

            for (NSUInteger i = 0; i < searchArray.count; i++) {
                NSURL *trackURL = searchArray[i];
                NSString *trackPath = [trackURL.path stringByStandardizingPath];
                if ([currentTrackPath isEqualToString:trackPath]) {
                    newIndex = i;
                    break;
                }
            }

            if (newIndex != NSNotFound) {
                self.currentTrackIndex = newIndex;
                currentTrackExists = YES;
            } else {
                // Current track is no longer in the list
                self.currentTrackIndex = 0; // Start from the first song
                currentTrackExists = NO;
            }
        } else {
            // No current track, reset index to 0
            self.currentTrackIndex = 0;
        }

        #ifdef DEBUG
        NSLog(@"Loaded %lu audio files from directory: %@", (unsigned long)self.audioFiles.count, directoryPath);
        #endif

        // Refresh the combo box and update selection
        dispatch_async(dispatch_get_main_queue(), ^{
            [self createComboBox];

            if (currentTrackExists) {
                NSInteger selectedIndex = self.currentTrackIndex + 1; // Adjust for placeholder
                [self.songComboBox selectItemAtIndex:selectedIndex];
            } else {
                [self.songComboBox selectItemAtIndex:0]; // Select placeholder
                // Stop playback since the current track was removed
                //[self stopAudio];
            }
        });
    }
}

// Helper method to extract CD number from directory name
- (NSString *)extractCDNumberFromString:(NSString *)cdString {
    if (cdString.length == 0) {
        // No CD directory, assign a CD number of "0" to sort these tracks first
        return @"0";
    }

    // Regular expression to match 'CD' followed by optional space(s) and a number
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^CD\\s*(\\d+)$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:cdString options:0 range:NSMakeRange(0, cdString.length)];

    if (match && match.numberOfRanges >= 2) {
        NSRange numberRange = [match rangeAtIndex:1];
        NSString *numberString = [cdString substringWithRange:numberRange];
        return numberString;
    }
    // If no CD number is found, assign a high number to sort such directories last
    return @"999";
}

// Existing method for WavPack playback
- (void)handleWavPackPlayback:(NSURL *)trackURL {
    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    #ifdef DEBUG
    NSLog(@"Playing WAVPack file using AudioQueue and libwavpack.");
    #endif
    
    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }

    // Clear current metadata before handling WAVPack metadata
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.artistLabel setStringValue:@""];
        [self.albumLabel setStringValue:@""];
        [self.titleLabel setStringValue:@""];
    });

    // Extract metadata and update UI elements
    [self extractAndDisplayMetadataForWavPack:trackURL];
    [self playWavPack:trackURL];  // Start WavPack playback

    // Extract metadata for notification
    // Create a dispatch block for getting the artist, album, and title
    dispatch_block_t retrieveTrackInfo = ^{
        NSString *artist = self.artistLabel.stringValue;
        NSString *album = self.albumLabel.stringValue;
        NSString *title = self.titleLabel.stringValue;
        
        // Process the retrieved values as needed
        #ifdef DEBUG
        NSLog(@"Artist: %@, Album: %@, Title: %@", artist, album, title);
        #endif
        
        // Trigger the Now Playing notification with the retrieved values
        [self triggerNowPlayingNotificationWithTitle:title artist:artist album:album];
    };

    // Dispatch the block to the main thread to access the UI elements and trigger the notification
    dispatch_async(dispatch_get_main_queue(), retrieveTrackInfo);
}

- (void)handleFlacPlayback:(NSURL *)trackURL {
    #ifdef DEBUG
    NSLog(@"Playing FLAC file using AVAudioPlayer.");
    #endif

    // Define a block to clear the previous metadata before starting playback
    dispatch_block_t clearMetadataBlock = ^{
        [self.artistLabel setStringValue:@""];
        [self.albumLabel setStringValue:@""];
        [self.titleLabel setStringValue:@""];
        [self.coverArtView setImage:nil];
        [self.trackNumberLabel setStringValue:@""];
    };

    // Dispatch the clear metadata block to the main queue
    dispatch_async(dispatch_get_main_queue(), clearMetadataBlock);
    
    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }
    
    // Dispose of any existing audio queue before starting a new track
    if (playbackState.audioQueue) {
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose the previous queue
        playbackState.audioQueue = NULL;
    }
    
    // Initialize the audio player with the FLAC file, using prefetched data if available
    NSError *error = nil;
    NSData *dataToUse = nil;
    if (self.prefetchedTrackURL && [self.prefetchedTrackURL isEqual:trackURL]) {
        dataToUse = self.prefetchedData;
        self.prefetchedData = nil;
        self.prefetchedTrackURL = nil;
    }

    if (dataToUse) {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:dataToUse error:&error];
    } else {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:trackURL error:&error];
    }

    if (error) {
        #ifdef DEBUG
        NSLog(@"Error initializing audio player: %@", error.localizedDescription);
        #endif
        return;
    }

    // Set the delegate to self to handle playback completion
    self.audioPlayer.delegate = self;

    // Start playback
    [self.audioPlayer play];

    // Define a block for starting progress bar updates
    dispatch_block_t startProgressBarUpdatesBlock = ^{
        [self startProgressBarUpdates];
    };
    // Dispatch to the main queue
    dispatch_async(dispatch_get_main_queue(), startProgressBarUpdatesBlock);

    // Define a block for extracting and displaying metadata using libFLAC
    dispatch_block_t extractMetadataBlock = ^{
        [self extractAndDisplayFlacMetadataWithLibFLAC:trackURL];
    };
    // Dispatch to the main queue
    dispatch_async(dispatch_get_main_queue(), extractMetadataBlock);

}

// Standard audio formats (MP3, WAV, etc.) playback and metadata handling
- (void)handleStandardAudioPlayback:(NSURL *)trackURL {
    NSError *error = nil;

    NSData *dataToUse = nil;
    if (self.prefetchedTrackURL && [self.prefetchedTrackURL isEqual:trackURL]) {
        dataToUse = self.prefetchedData;
    }

    if (dataToUse) {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithData:dataToUse error:&error];
        self.prefetchedData = nil;
        self.prefetchedTrackURL = nil;
    } else {
        self.audioPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:trackURL error:&error];
    }
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error initializing audio player: %@", error.localizedDescription);
        #endif
        return;
    }

    self.audioPlayer.delegate = self;  // Ensure delegate is set

    [self.audioPlayer play];
    #ifdef DEBUG
    NSLog(@"Playing track: %@", trackURL.lastPathComponent);
    #endif
    [self startProgressBarUpdates];  // Update progress bar
    [self extractAndDisplayMetadataFromURL:trackURL];  // Extract and display metadata
    self.replayGainValue = 0.0f;
}

// Start updating the progress bar every second
// Method to start progress bar updates
- (void)startProgressBarUpdates {
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
    }

    self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                target:self
                                                              selector:@selector(updateProgressBar)
                                                              userInfo:nil
                                                               repeats:YES];
}

// Update the progress bar based on the current playback time
- (void)updateProgressBar {
    // Handle AVAudioPlayer progress
    if (self.audioPlayer) {
        double currentTime = self.audioPlayer.currentTime;
        double duration = self.audioPlayer.duration;

        if (duration > 0) {
            double progress = (currentTime / duration) * 100;

            // Execute the block on the main queue to ensure UI update happens on the main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.progressBar setDoubleValue:progress];
            });
        }
    }

    // Handle Opus file progress
    if (playbackState.opusFile && playbackState.isPlaying) {
        // Get the current position in the file
        int64_t currentSample = op_pcm_tell(playbackState.opusFile);
        double currentTime = (double)currentSample / 48000.0;  // Convert current sample to seconds

        // Calculate the progress percentage
        double progress = (currentTime / playbackState.totalDuration) * 100.0;

        // Update the progress bar on the main thread
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressBar setDoubleValue:progress];
        });
    }

    // Handle WAVPack file progress
    if (playbackState.wpc && playbackState.isPlaying) {
        double progress = WavpackGetProgress(playbackState.wpc) * 100.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.progressBar setDoubleValue:progress];
        });
    }
}

// Go back to the previous track in the directory
- (void)backwardTrack {
    if (self.audioFiles.count == 0) {
        return;
    }

    // Clean up current playback before switching to a new track
    [self stopAudio];

    // Move to the previous track (loop back if at the first track)
    self.currentTrackIndex = (self.currentTrackIndex - 1 + self.audioFiles.count) % self.audioFiles.count;

    // Reset the progress bar to zero
    [self.progressBar setDoubleValue:0];

    // Play the new track
    [self playAudio];
}

- (void)forwardTrack {
    if (self.audioFiles.count == 0) {
        return;
    }

    // Clean up current playback before switching to a new track
    [self stopAudio];

    // Move to the next track (loop to the first track if at the last track)
    self.currentTrackIndex = (self.currentTrackIndex + 1) % self.audioFiles.count;

    // Reset the progress bar to zero
    [self.progressBar setDoubleValue:0];

    // Play the new track
    [self playAudio];
}

// Ensure the timer is invalidated if playback is stopped or a new track is played
- (void)stopAudio {
    [self stopBs2bIfRunning];
    // Invalidate the previous progress update timer
    if (self.progressUpdateTimer) {
        [self.progressUpdateTimer invalidate];
        self.progressUpdateTimer = nil;
    }

    // Stop and clean up the WAVPack playback state
    if (playbackState.audioQueue) {
        AudioQueueStop(playbackState.audioQueue, true);  // Stop AudioQueue
        playbackState.isPlaying = NO;

        for (int i = 0; i < NUM_BUFFERS; i++) {
            if (playbackState.buffers[i]) {
                AudioQueueFreeBuffer(playbackState.audioQueue, playbackState.buffers[i]);  // Free buffers
                playbackState.buffers[i] = NULL;
            }
        }
        AudioQueueDispose(playbackState.audioQueue, true);  // Dispose of the audio queue
        playbackState.audioQueue = NULL;
    }

    // Clean up Opus playback state
    if (playbackState.opusFile) {
        // Free Opus resources
        op_free(playbackState.opusFile);
        playbackState.opusFile = NULL;
    }

    // Stop the AVAudioPlayer if it's playing
    if (self.audioPlayer) {
        [self.audioPlayer stop];  // Stop the AVAudioPlayer
        self.audioPlayer = nil;   // Clear the audio player
    }

    // Reset the progress bar
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.progressBar setDoubleValue:0.0];
    });

    // Invalidate the play count timer
    if (self.playCountTimer) {
        [self.playCountTimer invalidate];
        self.playCountTimer = nil;
    }

    // Clear the play count label
    dispatch_block_t updateLabelBlock = ^{
        [self.playCountLabel setStringValue:@""];
    };

    // Now dispatch it on the main thread
    dispatch_async(dispatch_get_main_queue(), updateLabelBlock);

}

// Also update `pauseAudio` to manage the timer appropriately
- (void)pauseAudio {
    if (playbackState.isPlaying) {
        // Handle WAVPack AudioQueue pause
        if (playbackState.audioQueue && playbackState.wpc) {
            AudioQueuePause(playbackState.audioQueue); // Pause the AudioQueue
            playbackState.isPlaying = NO;

            // Invalidate the progress update timer
            if (self.progressUpdateTimer) {
                [self.progressUpdateTimer invalidate];
                self.progressUpdateTimer = nil;
            }
            #ifdef DEBUG
            NSLog(@"WAVPack audio paused.");
            #endif
        }

        // Handle Opus AudioQueue pause
        if (playbackState.opusFile && playbackState.audioQueue) {
            AudioQueuePause(playbackState.audioQueue); // Pause the Opus AudioQueue
            playbackState.isPlaying = NO;
            
            // Invalidate the progress update timer
            if (self.progressUpdateTimer) {
                [self.progressUpdateTimer invalidate];
                self.progressUpdateTimer = nil;
            }
            #ifdef DEBUG
            NSLog(@"Opus audio paused.");
            #endif
        }

        // Update button appearance to indicate it's paused
        [self updatePauseButtonAppearance:YES];

    } else if (self.audioPlayer.isPlaying) {
        // Handle AVAudioPlayer pause
        [self.audioPlayer pause];

        // Invalidate the progress update timer
        if (self.progressUpdateTimer) {
            [self.progressUpdateTimer invalidate];
            self.progressUpdateTimer = nil;
        }
        #ifdef DEBUG
        NSLog(@"AudioPlayer paused.");
        #endif
        // Update button appearance to indicate it's paused
        [self updatePauseButtonAppearance:YES];

    } else {
        // Resume playback for WAVPack
        if (playbackState.wpc && playbackState.audioQueue) {
            AudioQueueStart(playbackState.audioQueue, NULL); // Resume the AudioQueue
            playbackState.isPlaying = YES;

            // Restart the progress update timer
            self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                        target:self
                                                                      selector:@selector(updateProgressBar)
                                                                      userInfo:nil
                                                                       repeats:YES];
            #ifdef DEBUG
            NSLog(@"WAVPack audio resumed.");
            #endif
            // Update button appearance to indicate it's playing
            [self updatePauseButtonAppearance:NO];

        } else if (playbackState.opusFile && playbackState.audioQueue) {
            // Resume playback for Opus
            AudioQueueStart(playbackState.audioQueue, NULL); // Resume the Opus AudioQueue
            playbackState.isPlaying = YES;

            // Restart the progress update timer
            self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                        target:self
                                                                      selector:@selector(updateProgressBar)
                                                                      userInfo:nil
                                                                       repeats:YES];
            #ifdef DEBUG
            NSLog(@"Opus audio resumed.");
            #endif
            // Update button appearance to indicate it's playing
            [self updatePauseButtonAppearance:NO];

        } else if (self.audioPlayer) {
            // Resume AVAudioPlayer playback
            [self.audioPlayer play];

            // Restart the progress update timer
            self.progressUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                                        target:self
                                                                      selector:@selector(updateProgressBar)
                                                                      userInfo:nil
                                                                       repeats:YES];
            #ifdef DEBUG
            NSLog(@"AudioPlayer resumed.");
            #endif
            // Update button appearance to indicate it's playing
            [self updatePauseButtonAppearance:NO];
        }
    }
}

- (void)extractAndDisplayMetadataFromURL:(NSURL *)url {
    NSString *extension = url.pathExtension.lowercaseString;

    // Define a block to extract and display metadata for FLAC files
    dispatch_block_t flacMetadataBlock = ^{
        [self extractAndDisplayFlacMetadataWithLibFLAC:url];
    };

    // Define a block to extract and display metadata for WavPack files
    dispatch_block_t wavPackMetadataBlock = ^{
        [self extractAndDisplayMetadataForWavPack:url];
    };

    // Define a block to handle other formats and metadata extraction (macOS 15+ only)
    dispatch_block_t otherFormatsMetadataBlock = ^{
        AVAsset *asset = [AVAsset assetWithURL:url];

        // Load base properties before reading asset.metadata/commonMetadata
        [asset loadValuesAsynchronouslyForKeys:@[@"metadata", @"commonMetadata"] completionHandler:^{
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *error = nil;
                AVKeyValueStatus metadataStatus = [asset statusOfValueForKey:@"metadata" error:&error];
                if (metadataStatus != AVKeyValueStatusLoaded || error) {
                    #ifdef DEBUG
                    NSLog(@"[ReplayGain] Failed to load metadata for asset. Error: %@", error.localizedDescription);
                    #endif
                    return;
                }

                #ifdef DEBUG
                NSLog(@"[ReplayGain] Full metadata dump for asset at URL: %@", url);

                NSLog(@"[ReplayGain] Common Metadata:");
                for (AVMetadataItem *metadataItem in asset.commonMetadata) {
                    NSLog(@"[ReplayGain] [CommonMetadata] Key: %@, Value: %@, KeySpace: %@, CommonKey: %@",
                          metadataItem.key,
                          metadataItem.value,
                          metadataItem.keySpace,
                          metadataItem.commonKey);
                }

                NSLog(@"[ReplayGain] Full Metadata:");
                for (AVMetadataItem *metadataItem in asset.metadata) {
                    NSLog(@"[ReplayGain] [Metadata] Identifier: %@, Key: %@, KeySpace: %@, Value: %@",
                          metadataItem.identifier,
                          metadataItem.key,
                          metadataItem.keySpace,
                          metadataItem.value);
                }
                #endif

                // Defaults
                __block NSString *artist = @"Unknown Artist";
                __block NSString *album = @"Unknown Album";
                __block NSString *title = @"Unknown Title";
                __block NSImage *coverArt = nil;
                __block NSString *trackNumberString = @"0";
                __block float replayGainValue = 0.0f;
                __block BOOL foundReplayGain = NO;

                // Common metadata → artist/album/title/cover
                for (AVMetadataItem *metadataItem in asset.commonMetadata) {
                    if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyArtist]) {
                        artist = [self replaceSingleQuoteAndSmartQuotes:[self decodeMetadataItem:metadataItem]];
                    } else if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyAlbumName]) {
                        album = [self replaceSingleQuoteAndSmartQuotes:[self decodeMetadataItem:metadataItem]];
                    } else if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyTitle]) {
                        title = [self replaceSingleQuoteAndSmartQuotes:[self decodeMetadataItem:metadataItem]];
                    } else if ([metadataItem.commonKey isEqualToString:AVMetadataCommonKeyArtwork]) {
                        NSData *imageData = (NSData *)metadataItem.value;
                        coverArt = [[NSImage alloc] initWithData:imageData];
                    }
                }

                // Block to close (track number + UI + notifications)
                void (^finishAndUpdateUI)(void) = ^{
                    for (AVMetadataItem *metadataItem in asset.metadata) {
                        if ([metadataItem.identifier isEqualToString:@"itsk/trkn"]) {
                            NSData *trackNumberData = (NSData *)metadataItem.value;
                            if (trackNumberData.length == 8) {
                                uint32_t trackNumber = 0;
                                [trackNumberData getBytes:&trackNumber range:NSMakeRange(0, 4)];
                                trackNumber = CFSwapInt32BigToHost(trackNumber);
                                trackNumberString = [NSString stringWithFormat:@"%u", trackNumber];
                            }
                        } else if ([metadataItem.identifier isEqualToString:@"id3/TRCK"]) {
                            NSString *trackInfo = (NSString *)metadataItem.value;
                            NSArray<NSString *> *components = [trackInfo componentsSeparatedByString:@"/"];
                            if (components.count > 0) {
                                trackNumberString = components[0];
                                if (trackNumberString.length > 1 && [trackNumberString hasPrefix:@"0"]) {
                                    trackNumberString = [trackNumberString substringFromIndex:1];
                                }
                            }
                        }
                    }

                    NSString *formattedTitle = [NSString stringWithFormat:@"%@. %@", trackNumberString, title];

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.artistLabel setStringValue:artist];
                        [self.albumLabel setStringValue:album];
                        [self.titleLabel setStringValue:formattedTitle];
                        [self.coverArtView setImage:coverArt ?: nil];
                    });

                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self triggerNowPlayingNotificationWithTitle:formattedTitle artist:artist album:album];
                    });
                };

                // ---------- ReplayGain (iTunes/ID3) on macOS 15+ (new API) ----------
                NSArray *replayGainKeys = @[
                    @"com.apple.iTunes.REPLAYGAIN_TRACK_GAIN",
                    @"org.hydrogenaudio.replaygain.replaygain_track_gain",
                    @"replaygain_track_gain",
                    @"replaygain track gain",
                    @"REPLAYGAIN_TRACK_GAIN"
                ];

                dispatch_group_t g = dispatch_group_create();
                __block NSArray<AVMetadataItem *> *iTunesItems = @[];
                __block NSArray<AVMetadataItem *> *id3Items = @[];

                dispatch_group_enter(g);
                [asset loadMetadataForFormat:AVMetadataFormatiTunesMetadata
                          completionHandler:^(NSArray<AVMetadataItem *> * _Nullable items, NSError * _Nullable err) {
                    iTunesItems = items ?: @[];
                    dispatch_group_leave(g);
                }];

                dispatch_group_enter(g);
                [asset loadMetadataForFormat:AVMetadataFormatID3Metadata
                          completionHandler:^(NSArray<AVMetadataItem *> * _Nullable items, NSError * _Nullable err) {
                    id3Items = items ?: @[];
                    dispatch_group_leave(g);
                }];

                dispatch_group_notify(g, dispatch_get_main_queue(), ^{
                    // ---- iTunes (AAC/ALAC) ----
                    for (AVMetadataItem *metadataItem in iTunesItems) {
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] iTunes Key:%@ Val:%@ KS:%@ id:%@ free:%@",
                              metadataItem.key, metadataItem.value, metadataItem.keySpace,
                              metadataItem.identifier, metadataItem.extraAttributes[AVMetadataExtraAttributeInfoKey]);
                        #endif
                        // Check with itendifiers/keys “freeform”
                        NSString *freeName = metadataItem.extraAttributes[AVMetadataExtraAttributeInfoKey] ?: @"";
                        NSString *keyStr = [metadataItem.key isKindOfClass:NSString.class] ? (NSString *)metadataItem.key : @"";
                        NSString *hay = [[@[ (metadataItem.identifier ?: @""), freeName, keyStr ]
                                           componentsJoinedByString:@"|"] lowercaseString];

                        BOOL match = NO;
                        for (NSString *k in replayGainKeys) {
                            if ([hay containsString:k.lowercaseString]) { match = YES; break; }
                        }
                        if (!match) continue;

                        NSString *valueString = nil;
                        if ([metadataItem.value isKindOfClass:NSString.class]) {
                            valueString = [(NSString *)metadataItem.value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        } else if ([metadataItem.value isKindOfClass:NSData.class]) {
                            valueString = [[NSString alloc] initWithData:(NSData *)metadataItem.value encoding:NSUTF8StringEncoding];
                            valueString = [valueString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        }
                        if (!valueString.length) continue;

                        NSRange dbRange = [valueString rangeOfString:@" dB" options:NSCaseInsensitiveSearch];
                        if (dbRange.location != NSNotFound) valueString = [valueString substringToIndex:dbRange.location];

                        float rg = [valueString floatValue];
                        // The old structure of the line below caused the distortions via AirPlay
                        if (fabsf(rg) < 0.0005f || rg != 0.0f) {
                            replayGainValue = rg;
                            foundReplayGain = YES;
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] AAC/ALAC track replayGain: %f dB", replayGainValue);
                            #endif
                            self.replayGainValue = replayGainValue;
                            [self.airPlayStreamer updateReplayGainValue:self.replayGainValue];
                            break;
                        }

                        if ([hay containsString:@"itunnorm"]) {
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] iTunNORM detectado (converter noutro passo).");
                            #endif
                        }
                    }

                    // ---- ID3 fallback (MP3) ----
                    if (!foundReplayGain) {
                        for (AVMetadataItem *metadataItem in id3Items) {
                            #ifdef DEBUG
                            NSLog(@"[ReplayGain] ID3 Key:%@ Val:%@ KS:%@", metadataItem.key, metadataItem.value, metadataItem.keySpace);
                            #endif
                            if ([metadataItem.keySpace isEqualToString:@"org.id3"] &&
                                [metadataItem.key isKindOfClass:[NSString class]] &&
                                [(NSString *)metadataItem.key isEqualToString:@"TXXX"]) {
                                NSString *valueString = [metadataItem.value description];
                                valueString = [valueString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                if ([valueString hasSuffix:@" dB"]) {
                                    NSString *gainValueString = [valueString substringToIndex:(valueString.length - 3)];
                                    float rg = [gainValueString floatValue];
                                    replayGainValue = rg;
                                    foundReplayGain = YES;
                                    #ifdef DEBUG
                                    NSLog(@"[ReplayGain] MP3 (inferred track gain): %f dB", replayGainValue);
                                    #endif
                                    self.replayGainValue = replayGainValue;
                                    [self.airPlayStreamer updateReplayGainValue:self.replayGainValue];
                                    break;
                                }
                            }
                        }
                    }

                    if (!foundReplayGain) {
                        #ifdef DEBUG
                        NSLog(@"[ReplayGain] No valid ReplayGain metadata found.");
                        #endif
                        replayGainValue = 0.0f;
                    }

                    // Closing: track number + UI + notifications
                    finishAndUpdateUI();
                });
                // ---------- end ReplayGain macOS 15+ ----------
            });
        }];
    };

    // Handle different formats based on file extension
    if ([extension isEqualToString:@"flac"]) {
        dispatch_async(dispatch_get_main_queue(), flacMetadataBlock);
    } else if ([extension isEqualToString:@"wv"]) {
        dispatch_async(dispatch_get_main_queue(), wavPackMetadataBlock);
    } else {
        dispatch_async(dispatch_get_main_queue(), otherFormatsMetadataBlock);
    }
}

- (void)triggerNowPlayingNotificationWithTitle:(NSString *)title artist:(NSString *)artist album:(NSString *)album {
    // Clear any previous Now Playing notifications
    [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:@[@"NowPlaying"]];

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [NSString stringWithFormat:NSLocalizedString(@"now_playing_title", @"Now Playing: %@"), title];
    content.subtitle = [NSString stringWithFormat:NSLocalizedString(@"now_playing_artist", @"Now Playing: %@"), artist];
    content.body = [NSString stringWithFormat:NSLocalizedString(@"now_playing_album", @"Album: %@"), album];
    content.sound = [UNNotificationSound defaultSound];

    // Attach cover art if available
    if (self.coverArtView.image) {
        // Convert NSImage to NSData
        CGImageRef cgRef = [self.coverArtView.image CGImageForProposedRect:nil context:nil hints:nil];
        NSBitmapImageRep *newRep = [[NSBitmapImageRep alloc] initWithCGImage:cgRef];
        [newRep setSize:[self.coverArtView.image size]];   // Ensure the size remains the same
        NSData *pngData = [newRep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        
        // Save the image to a temporary file
        NSString *tempDirectory = NSTemporaryDirectory();
        NSString *tempFilePath = [tempDirectory stringByAppendingPathComponent:@"coverArt.png"];
        [pngData writeToFile:tempFilePath atomically:YES];
            #ifdef DEBUG
            NSLog(@"Temporary cover art directory: %@", NSTemporaryDirectory());
            #endif
        
        // Create a UNNotificationAttachment from the file
        NSError *attachmentError = nil;
        UNNotificationAttachment *attachment = [UNNotificationAttachment attachmentWithIdentifier:@"coverArt"
                                 URL:[NSURL fileURLWithPath:tempFilePath]
                                 options:nil
                                 error:&attachmentError];
        if (!attachmentError) {
            content.attachments = @[attachment];
        } else {
            #ifdef DEBUG
            NSLog(NSLocalizedString(@"error_attaching_cover_art", @"Error attaching cover art: %@"), attachmentError.localizedDescription);
            #endif
        }
    }
    
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:@"NowPlaying"
                          content:content
                          trigger:nil];
    
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request
                          withCompletionHandler:nil];
}

- (void)stopCava {
    if (self.cavaTask && self.cavaTask.isRunning) {
        [self.cavaTask terminate];
        [self.cavaTask waitUntilExit];
        #ifdef DEBUG
        NSLog(@"cava terminated.");
        #endif
        self.cavaTask = nil;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self stopCava];
    [self stopBs2bIfRunning];
    [self saveTrackPlayCounts];
    [self.airPlayManager stopDiscovery];
    // Ensure AirPlay_BonJour.txt is reset on app termination
    [self.airPlayManager cleanupBonjourFile];
    // Cleanup lock file on app termination
    [ZPAirPlayStreamer cleanupRaopPlayLockFile];
}

// Prefetch the data for the next track in the playlist to reduce latency
- (void)prefetchNextTrack {
    NSInteger nextIndex;
    NSURL *nextURL = nil;

    if (self.isShuffleModeActive) {
        if (self.shuffledTracks.count == 0) return;
        nextIndex = (self.currentTrackIndex + 1) % self.shuffledTracks.count;
        nextURL = self.shuffledTracks[nextIndex];
    } else {
        if (self.audioFiles.count == 0) return;
        nextIndex = self.currentTrackIndex + 1;
        if (nextIndex >= self.audioFiles.count) {
            if (self.isRepeatModeActive) {
                nextIndex = 0;
            } else {
                self.prefetchedTrackURL = nil;
                self.prefetchedData = nil;
                return;
            }
        }
        nextURL = self.audioFiles[nextIndex];
    }

    if (!nextURL) return;

    self.prefetchedTrackURL = nextURL;

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSData *data = [NSData dataWithContentsOfURL:nextURL options:NSDataReadingMappedIfSafe error:nil];
        @synchronized (self) {
            self.prefetchedData = data;
        }
    });
}

@end


