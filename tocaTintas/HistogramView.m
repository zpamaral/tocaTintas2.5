/*
 --- timestamps (ts), millisecond (ms) and network time protocol (ntp) ---
 
  NTP is starting Jan 1900 (EPOCH) made of 32 high bits (seconds) and 32
  low bits (fraction).
  The player needs timestamp that increment by one for every sample (44100/s), so
  we created an "absolute" timestamp that is direcly based on NTP: it has the same
  "origin" for time.
     - TS = NTP * sample_rate / 2^32 (TS fits in 64bits no matter what)
     - NTP = TS * 2^32 / sample_rate
  Because sample_rate is less than 16 bits, then TS always have the highest 16
  bits available, so this gives, with proper rounding and avoiding overflow:
     - TS  = ((NTP >> 16) * sample_rate) >> 16
     - NTP = ((TS << 16) / sample_rate) << 16
  If we want to use a more convenient millisecond base, it must be derived from
  the same NTP and if we want to use only a 32 bits value, raopcl_time32_to_ntp()
  do the "guess" of a 32 bits ms counter into a proper NTP

  --- head_ts ---
 
  The head_ts value indicates the absolute frame number of the frame to be played
  in latency seconds.
  When starting to play without a special start time, we assume that we want to
  start at the closed opportunity, so by setting the head_ts to the current
  absolute_ts (called now_ts), we are sure that the player will start to play the
  first frame at now_ts + latency, which means it has time to process a frame
  send with now_ts timestamp. We could further optimize that by reducing a bit
  this value.
  When sending the 1st frame after a flush, the head_ts is reset to now_ts.

  --- latency ---
 
  AirPlay devices seem to send everything with a latency of 11025 + the latency
  set in the sync packet, no matter what.

  --- start time ---
 
  As explained in the header of this file, the caller of raopcl_set_start() must
  anticipate by raopcl_latency() if he wants the next frame to be played exactly
  at a given NTP time

  --- raopcl_accept_frame ---
 
  This function must be called before sending any data and forces the right pace
  on the caller. When running, it simply checks that now_ts is above head_ts plus
  chunk_len. But it has a critical role at start and resume. When called after a
  raopcl_stop or raopcl_pause has been called, it will return false until a call
  to raopcl_flush has been finished *or* the start_time has been reached. When
  player has been actually flushed, then it will reset the head_ts to the current
  time or the start_time, force sending of the various airplay sync bits and then
  return true, resume normal mode.

  --- why raopcl_stop/pause and raopcl_flush ---
 
  It seems that they could have been merged into a single function. This allows
  independent threads for audio sending (raopcl_accept_frames/raopcl_send_chunks)
  and player control. The control thread can then call raopcl_stop and queue the
  raopcl_flush in another thread (remember that raopcl_flush is RTSP so it can
  take time). The thread doing the audio can call raopcl_accept_frames as much
  as it wants, it will not be allowed to send anything before the *actual* flush
  is done. The control thread could even ask playback to restart immediately, no
  audio data will be accepted until flush is actually done and synchronization
  will be maintained, even in case of restart at a given time
 */
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
//  HistogramView.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 26/08/2026.
//

#import "HistogramView.h"
#import <QuartzCore/QuartzCore.h>

@interface HistogramView ()
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *leftBarLayers;
@property (nonatomic, strong) NSMutableArray<CAShapeLayer *> *rightBarLayers;
@end

@implementation HistogramView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        // Initialization code here
        self.leftBarLayers = [NSMutableArray array];
        self.rightBarLayers = [NSMutableArray array];
    }
    return self;
}

// Allows for Dark and Light Modes backgrounds
- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    
    // Set background color based on the appearance (Dark Mode or Light Mode)
    if ([self.effectiveAppearance.name isEqualToString:NSAppearanceNameDarkAqua]) {
        [[NSColor blackColor] setFill];  // Dark Mode background (black)
    } else {
        [[NSColor colorWithCalibratedWhite:0.8 alpha:1.0] setFill];  // Light Mode background (custom gray)
    }
    
    // Fill the background with the selected color
    NSRectFill(dirtyRect);
}

- (void)updateHistogramWithLeftChannel:(NSArray<NSNumber *> *)leftChannel rightChannel:(NSArray<NSNumber *> *)rightChannel {
    self.leftChannelValues = leftChannel;
    self.rightChannelValues = rightChannel;

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateBars];
    });
}

- (void)updateBars {
    CGFloat totalBars = self.leftChannelValues.count + self.rightChannelValues.count;
    CGFloat columnWidth = self.bounds.size.width / totalBars;
    CGFloat maxHeight = self.bounds.size.height;

    // Ensure leftBarLayers has enough layers
    while (self.leftBarLayers.count < self.leftChannelValues.count) {
        CAShapeLayer *barLayer = [CAShapeLayer layer];
        barLayer.fillColor = [[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:1.0] CGColor];
        [self.layer addSublayer:barLayer];
        [self.leftBarLayers addObject:barLayer];
    }

    // Update left channel bars
    for (NSUInteger i = 0; i < self.leftChannelValues.count; i++) {
        NSNumber *value = self.leftChannelValues[i];
        CGFloat height = value.floatValue / 1000.0 * maxHeight;

        CAShapeLayer *barLayer = self.leftBarLayers[i];
        CGRect barFrame = CGRectMake(i * columnWidth, 0, columnWidth - 2, height);
        CGPathRef path = CGPathCreateWithRect(barFrame, NULL);
        barLayer.path = path;
        CGPathRelease(path);
    }

    // Ensure rightBarLayers has enough layers
    while (self.rightBarLayers.count < self.rightChannelValues.count) {
        CAShapeLayer *barLayer = [CAShapeLayer layer];
        barLayer.fillColor = [[NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:1.0] CGColor];
        [self.layer addSublayer:barLayer];
        [self.rightBarLayers addObject:barLayer];
    }

    // Update right channel bars
    for (NSUInteger i = 0; i < self.rightChannelValues.count; i++) {
        NSNumber *value = self.rightChannelValues[i];
        CGFloat height = value.floatValue / 1000.0 * maxHeight;

        CAShapeLayer *barLayer = self.rightBarLayers[i];
        CGRect barFrame = CGRectMake((i + self.leftChannelValues.count) * columnWidth, 0, columnWidth - 2, height);
        CGPathRef path = CGPathCreateWithRect(barFrame, NULL);
        barLayer.path = path;
        CGPathRelease(path);
    }

    // Remove extra layers if counts have decreased
    if (self.leftBarLayers.count > self.leftChannelValues.count) {
        for (NSUInteger i = self.leftChannelValues.count; i < self.leftBarLayers.count; i++) {
            CAShapeLayer *barLayer = self.leftBarLayers[i];
            [barLayer removeFromSuperlayer];
        }
        [self.leftBarLayers removeObjectsInRange:NSMakeRange(self.leftChannelValues.count, self.leftBarLayers.count - self.leftChannelValues.count)];
    }

    if (self.rightBarLayers.count > self.rightChannelValues.count) {
        for (NSUInteger i = self.rightChannelValues.count; i < self.rightBarLayers.count; i++) {
            CAShapeLayer *barLayer = self.rightBarLayers[i];
            [barLayer removeFromSuperlayer];
        }
        [self.rightBarLayers removeObjectsInRange:NSMakeRange(self.rightChannelValues.count, self.rightBarLayers.count - self.rightChannelValues.count)];
    }
}

@end
