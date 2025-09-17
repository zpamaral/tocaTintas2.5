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
//  PreferencesWindowController.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 12/09/2024.
//

#import "PreferencesWindowController.h"

@implementation PreferencesWindowController

- (void)windowDidLoad {
    [super windowDidLoad];

    // Create the programmatic label and store it as a property
    self.testLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(26, 127, 437, 16)];
    [self.testLabel setBezeled:NO];
    [self.testLabel setDrawsBackground:NO];
    [self.testLabel setEditable:NO];
    [self.testLabel setSelectable:NO];
    
    // Add it to the window's content view
    [self.window.contentView addSubview:self.testLabel];
    
    // Set initial value from user defaults
    [self reloadDirectoryPath];  // Reload and display the saved path
    
    // Manually assign the saveButton using the tag value
    self.saveButton = [self.window.contentView viewWithTag:100];
    
    // Set the target and action programmatically for the "Save" button
    [self.saveButton setTarget:self];
    [self.saveButton setAction:@selector(chooseDirectory:)];

    NSLog(@"Programmatic label added and updated");
}

// Method to reload the directory path from user defaults
- (void)reloadDirectoryPath {
    NSString *currentPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"songsDirectoryPath"];
    
    // Update the programmatic label
    if (currentPath && currentPath.length > 0) {
        self.testLabel.stringValue = currentPath;
    } else {
        self.testLabel.stringValue = @"No path currently defined...";
    }
}

// IBAction for the "Choose Directory" button
- (IBAction)chooseDirectory:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setCanChooseFiles:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setTitle:@"Select Music Directory"];
    
    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *selectedDirectory = panel.URL;
            if (selectedDirectory) {
                // Update the programmatic label with the selected directory's path
                self.testLabel.stringValue = selectedDirectory.path;
                
                // Save the path to user defaults
                [[NSUserDefaults standardUserDefaults] setObject:selectedDirectory.path forKey:@"songsDirectoryPath"];
                [[NSUserDefaults standardUserDefaults] synchronize];

                // Post a notification to inform other parts of the app that the directory has changed
                NSDictionary *userInfo = @{@"newPath": selectedDirectory.path};
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SongsDirectoryPathChanged" object:nil userInfo:userInfo];
            }
        }
    }];
}

@end
