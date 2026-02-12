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
//  M3UPlaylist.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 14/09/2026.
//

#import "M3UPlaylist.h"

@implementation M3UPlaylist

// Load an M3U playlist from a file
+ (NSArray<NSString *> *)loadFromFile:(NSString *)filePath {
    NSError *error = nil;
    NSString *fileContents = [NSString stringWithContentsOfFile:filePath encoding:NSUTF8StringEncoding error:&error];

    if (error) {
        #ifdef DEBUG
        NSLog(@"Error loading M3U file: %@", error.localizedDescription);
        #endif
        return nil;
    }

    // Split the file contents into lines
    NSArray<NSString *> *lines = [fileContents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];

    // Create an array to hold the audio file paths
    NSMutableArray<NSString *> *audioFilePaths = [NSMutableArray array];

    // Loop through the lines and add file paths (ignoring comments and empty lines)
    for (__strong NSString *line in lines) {  // Add __strong here
        line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

        if ([line hasPrefix:@"#"] || line.length == 0) {
            // Ignore comments and empty lines
            continue;
        }

        [audioFilePaths addObject:line];
    }

    return [audioFilePaths copy];
}

// Save an array of file paths as an M3U playlist to a file
+ (BOOL)saveToFile:(NSString *)filePath withPlaylist:(NSArray<NSString *> *)audioFilePaths {
    NSError *error = nil;
    NSMutableString *m3uContent = [NSMutableString stringWithString:@"#EXTM3U\n"];  // Start with M3U header

    // Loop through the audio file paths and add them to the M3U content
    for (NSString *trackPath in audioFilePaths) {
        [m3uContent appendFormat:@"%@\n", trackPath];  // Add each track to the M3U file
    }

    // Write the M3U content to the specified file path
    BOOL success = [m3uContent writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:&error];

    if (!success) {
        #ifdef DEBUG
        NSLog(@"Error saving M3U file: %@", error.localizedDescription);
        #endif
        return NO;
    }

    return YES;  // Return YES if the file was saved successfully
}

@end
