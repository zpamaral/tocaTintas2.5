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
//  ZPAirPlay.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 12/11/2024.
//

#import "ZPAirPlay.h"

@interface ZPAirPlay ()

// Properties for discovery and management
@property (nonatomic, strong) NSTask *discoveryTask;
@property (nonatomic, strong) NSPipe *outputPipe;
@property (nonatomic, strong) NSMutableData *bufferedData;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSTask *> *deviceTasks; // Track tasks for each device

// File paths
@property (nonatomic, strong) NSString *ipFilePath;      // Path to AirPlay_IP.txt in Application Support
@property (nonatomic, strong) NSString *bonjourFilePath; // Path to AirPlay_BonJour.txt in Application Support

@end

@implementation ZPAirPlay

#pragma mark - Initialization

- (instancetype)init {
    self = [super init];
    if (self) {
        // Set up the Application Support path for AirPlay files
        NSString *supportPath = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"tocaTintas"];
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:supportPath withIntermediateDirectories:YES attributes:nil error:&error];
        
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Initialization] Error creating directory at path %@: %@", supportPath, error);
            #endif
        } else {
            #ifdef DEBUG
            NSLog(@"[Initialization] Directory confirmed at path %@", supportPath);
            #endif
        }

        // Initialize file paths
        _ipFilePath = [supportPath stringByAppendingPathComponent:@"AirPlay_IP.txt"];
        _bonjourFilePath = [supportPath stringByAppendingPathComponent:@"AirPlay_BonJour.txt"];

        // Ensure the AirPlay_IP.txt file exists
        if (![[NSFileManager defaultManager] fileExistsAtPath:_ipFilePath]) {
            [[NSFileManager defaultManager] createFileAtPath:_ipFilePath contents:nil attributes:nil];
            #ifdef DEBUG
            NSLog(@"[Initialization] AirPlay_IP.txt created at path %@", _ipFilePath);
            #endif
        }

        // Initialize other properties
        _deviceTasks = [NSMutableDictionary dictionary];
        _capturedAddresses = [NSMutableSet set];
        _bufferedData = [NSMutableData data];
    }
    return self;
}

#pragma mark - Discovery Methods

- (void)startDiscovery {
    if (_discoveryTask && _discoveryTask.isRunning) {
        [self stopDiscovery];
    }

    #ifdef DEBUG
    NSLog(@"[AirPlay devices 01] Starting discovery task...");
    #endif

    _discoveryTask = [[NSTask alloc] init];
    _discoveryTask.launchPath = @"/usr/bin/dns-sd";
    _discoveryTask.arguments = @[@"-B", @"_raop._tcp", @"local"];

    _outputPipe = [NSPipe pipe];
    _discoveryTask.standardOutput = _outputPipe;
    _discoveryTask.standardError = _outputPipe;

    NSFileHandle *fileHandle = [_outputPipe fileHandleForReading];

    __weak typeof(self) weakSelf = self;
    fileHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *outputData = [handle availableData];
        if (outputData.length > 0) {
            [weakSelf.bufferedData appendData:outputData];
            NSString *outputString = [[NSString alloc] initWithData:weakSelf.bufferedData encoding:NSUTF8StringEncoding];
            NSRange range = [outputString rangeOfString:@"\n" options:NSBackwardsSearch];
            if (range.location != NSNotFound) {
                NSString *completeLines = [outputString substringToIndex:range.location];
                weakSelf.bufferedData = [[outputString substringFromIndex:range.location + 1] dataUsingEncoding:NSUTF8StringEncoding].mutableCopy;
                [weakSelf parseAndWriteDevicesToFileFromOutput:completeLines];
            }
        }
    };

    [_discoveryTask launch];
    #ifdef DEBUG
    NSLog(@"[AirPlay devices 02] Discovery task launched and running.");
    #endif
}

- (void)stopDiscovery {
    #ifdef DEBUG
    NSLog(@"[AirPlay devices 03] Stopping discovery task...");
    #endif
    if (_discoveryTask) {
        [_discoveryTask terminate];
        _discoveryTask = nil;
        _outputPipe.fileHandleForReading.readabilityHandler = nil;
    }

    // Terminate any running device-specific tasks
    for (NSString *deviceName in _deviceTasks) {
        NSTask *task = _deviceTasks[deviceName];
        [task terminate];
    }
    [_deviceTasks removeAllObjects];
}

#pragma mark - Device Parsing and Writing

- (void)parseAndWriteDevicesToFileFromOutput:(NSString *)output {
    #ifdef DEBUG
    NSLog(@"[AirPlay devices 07] Raw discovery output: %@", output);
    #endif
    
    // Extract all unique instance names (e.g., A0EDCDE18416@Apple TV (NAD))
    NSMutableSet<NSString *> *uniqueDeviceNames = [NSMutableSet set];
    
    NSArray<NSString *> *lines = [output componentsSeparatedByString:@"\n"];
    // Update the regular expression to capture the entire Instance Name, including spaces and symbols
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[A-F0-9]+@.+$" options:0 error:nil];
    
    for (NSString *line in lines) {
        #ifdef DEBUG
        NSLog(@"[AirPlay devices 08] Processing line: %@", line);
        #endif
        
        if ([line containsString:@"Add"]) {  // Only process lines with "Add"
            NSTextCheckingResult *match = [regex firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            
            if (match) {
                NSString *deviceName = [line substringWithRange:match.range];
                [uniqueDeviceNames addObject:deviceName];
            }
        }
    }
    
    // Sort the unique device names alphabetically
    NSArray *sortedDeviceNames = [[uniqueDeviceNames allObjects] sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
    
    // Write sorted device names to AirPlay_IP.txt
    [self writeDeviceNamesToFile:sortedDeviceNames];
    // After writing to AirPlay_IP.txt, start Bonjour lookup
    [self lookupBonjourAddresses];

}

- (void)writeDeviceNamesToFile:(NSArray<NSString *> *)deviceNames {
    // Convert the sorted device names array to a single newline-separated string
    NSString *outputContent = [deviceNames componentsJoinedByString:@"\n"];
    
    NSError *error = nil;
    [outputContent writeToFile:_ipFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error writing to AirPlay_IP.txt: %@", error);
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[AirPlay devices 04] Sorted device names written to AirPlay_IP.txt");
        #endif
    }
}

#pragma mark - Bonjour Lookup

- (void)lookupBonjourAddresses {
    NSError *error = nil;
    NSString *ipFileContents = [NSString stringWithContentsOfFile:_ipFilePath encoding:NSUTF8StringEncoding error:&error];
    if (error) {
        #ifdef DEBUG
        NSLog(@"Error reading AirPlay_IP.txt: %@", error);
        #endif
        return;
    }

    NSArray<NSString *> *deviceNames = [ipFileContents componentsSeparatedByString:@"\n"];
    for (NSString *deviceName in deviceNames) {
        if (deviceName.length > 0) {
            @synchronized (self) {
                if (![_capturedAddresses containsObject:deviceName]) {
                    [_capturedAddresses addObject:deviceName];
                    [self runDnsSdLookupForDevice:deviceName];
                }
            }
        }
    }
}

- (void)runDnsSdLookupForDevice:(NSString *)deviceName {
    NSString *command = [NSString stringWithFormat:@"dns-sd -L \"%@\" _raop._tcp local", deviceName];

    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/bin/sh"];
    [task setArguments:@[@"-c", command]];

    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:pipe];

    NSFileHandle *fileHandle = [pipe fileHandleForReading];

    __weak typeof(self) weakSelf = self;
    fileHandle.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = [handle availableData];
        if (data.length > 0) {
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            [weakSelf parseAndSaveBonjourOutput:output forDevice:deviceName];
        }
        [task terminate];
        
        // **Add these lines to prevent high CPU usage**
        [handle setReadabilityHandler:nil];
        [handle closeFile];
        
        @synchronized (weakSelf) {
            [weakSelf.deviceTasks removeObjectForKey:deviceName];
        }
    };

    @synchronized (self) {
        _deviceTasks[deviceName] = task;
    }
    [task launch];
}

- (void)parseAndSaveBonjourOutput:(NSString *)output forDevice:(NSString *)deviceName {
    #ifdef DEBUG
    NSLog(@"[Bonjour lookup] Output for %@: %@", deviceName, output);
    #endif

    // Regular expression to parse the Bonjour output
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"can be reached at ([^\\s]+)\\.:([0-9]+)" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];

    if (match) {
        NSString *address = [output substringWithRange:[match rangeAtIndex:1]];
        NSString *port = [output substringWithRange:[match rangeAtIndex:2]];

        // Obtain IP address by running ping -c 1
        NSString *ipAddress = [self resolveIPAddressForHostname:address];

        // Load AirPlay_IP.txt to find the human-readable device name
        NSString *airPlayIPFilePath = @"/Users/amaral/Library/Application Support/tocaTintas/AirPlay_IP.txt";
        NSError *error = nil;
        NSString *airPlayIPContents = [NSString stringWithContentsOfFile:airPlayIPFilePath encoding:NSUTF8StringEncoding error:&error];

        if (error) {
            #ifdef DEBUG
            NSLog(@"Error reading AirPlay_IP.txt: %@", error.localizedDescription);
            #endif
            return;
        }

        // Parse the AirPlay_IP.txt file to find the matching device name
        NSString *deviceHumanName = @"";
        NSArray<NSString *> *lines = [airPlayIPContents componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line containsString:deviceName]) {
                NSArray<NSString *> *components = [line componentsSeparatedByString:@"@"];
                if (components.count == 2) {
                    deviceHumanName = components[1]; // Human-readable name
                    break;
                }
            }
        }

        if (deviceHumanName.length == 0) {
            #ifdef DEBUG
            NSLog(@"Device name not found in AirPlay_IP.txt for %@", deviceName);
            #endif
            return;
        }

        // Prepare output line with the new format
        NSString *outputLine = [NSString stringWithFormat:@"%@\t%@\t%@\t%@\n", deviceHumanName, address, ipAddress, port];
        [self saveBonjourResultToFile:outputLine];

        #ifdef DEBUG
        NSLog(@"Parsed and saved: %@\t%@\t%@\t%@", deviceHumanName, address, ipAddress, port);
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"Failed to parse Bonjour output for device: %@", deviceName);
        #endif
    }
}

#pragma mark - IP Resolution

- (NSString *)resolveIPAddressForHostname:(NSString *)hostname {
    NSString *command = [NSString stringWithFormat:@"ping -c 1 %@", hostname];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/bin/sh";
    task.arguments = @[@"-c", command];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    NSFileHandle *fileHandle = [pipe fileHandleForReading];
    [task launch];
    [task waitUntilExit];

    NSData *outputData = [fileHandle readDataToEndOfFile];
    NSString *output = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];

    NSRegularExpression *ipRegex = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d+\\.\\d+\\.\\d+\\.\\d+)\\)" options:0 error:nil];
    NSTextCheckingResult *match = [ipRegex firstMatchInString:output options:0 range:NSMakeRange(0, output.length)];

    return match ? [output substringWithRange:[match rangeAtIndex:1]] : @"N/A";
}

#pragma mark - Saving Results

- (void)saveBonjourResultToFile:(NSString *)outputLine {
    NSError *error = nil;
    #ifdef DEBUG
    NSLog(@"Attempting to save to AirPlay_BonJour.txt: %@", outputLine);
    #endif

    NSString *directoryPath = [_bonjourFilePath stringByDeletingLastPathComponent];
    if (![[NSFileManager defaultManager] fileExistsAtPath:directoryPath]) {
        BOOL dirSuccess = [[NSFileManager defaultManager] createDirectoryAtPath:directoryPath withIntermediateDirectories:YES attributes:nil error:&error];
        if (!dirSuccess || error) {
            #ifdef DEBUG
            NSLog(@"[Bonjour save] Error creating directory at path: %@, error: %@", directoryPath, error);
            #endif
            return;
        } else {
            #ifdef DEBUG
            NSLog(@"[Bonjour save] Directory created successfully at path: %@", directoryPath);
            #endif
        }
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:_bonjourFilePath]) {
        BOOL fileSuccess = [[NSFileManager defaultManager] createFileAtPath:_bonjourFilePath contents:nil attributes:nil];
        if (!fileSuccess) {
            #ifdef DEBUG
            NSLog(@"[Bonjour save] Error creating AirPlay_BonJour.txt at path: %@", _bonjourFilePath);
            #endif
            return;
        } else {
            #ifdef DEBUG
            NSLog(@"[Bonjour save] AirPlay_BonJour.txt created successfully.");
            #endif
        }
    }

    NSString *currentFileContents = [NSString stringWithContentsOfFile:_bonjourFilePath encoding:NSUTF8StringEncoding error:&error];
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    if (error) {
        #ifdef DEBUG
        NSLog(@"[Bonjour save] Error reading AirPlay_BonJour.txt: %@", error);
        #endif
        currentFileContents = @"";
    } else if (currentFileContents.length > 0) {
        entries = [[currentFileContents componentsSeparatedByString:@"\n"] mutableCopy];
    }

    NSArray<NSString *> *outputColumns = [outputLine componentsSeparatedByString:@"\t"];
    if (outputColumns.count < 3) {
        #ifdef DEBUG
        NSLog(@"[Bonjour save] Invalid output line, skipping save: %@", outputLine);
        #endif
        return;
    }
    NSString *hostname = outputColumns[0];
    BOOL found = NO;
    
    for (NSInteger i = 0; i < entries.count; i++) {
        NSString *entry = entries[i];
        NSArray<NSString *> *columns = [entry componentsSeparatedByString:@"\t"];
        if (columns.count >= 3 && [columns[0] isEqualToString:hostname]) {
            entries[i] = [outputLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            found = YES;
            break;
        }
    }
    if (!found) {
        [entries addObject:[outputLine stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]];
    }

    NSMutableSet<NSString *> *uniqueEntries = [NSMutableSet set];
    for (NSString *entry in entries) {
        NSString *trimmedEntry = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmedEntry.length > 0) {
            [uniqueEntries addObject:trimmedEntry];
        }
    }

    NSArray<NSString *> *sortedEntries = [[uniqueEntries allObjects] sortedArrayUsingComparator:^NSComparisonResult(NSString *obj1, NSString *obj2) {
        NSString *hostname1 = [[obj1 componentsSeparatedByString:@"\t"] firstObject];
        NSString *hostname2 = [[obj2 componentsSeparatedByString:@"\t"] firstObject];
        return [hostname1 caseInsensitiveCompare:hostname2];
    }];

    NSString *updatedContents = [sortedEntries componentsJoinedByString:@"\n"];
    BOOL writeSuccess = [updatedContents writeToFile:_bonjourFilePath atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!writeSuccess || error) {
        #ifdef DEBUG
        NSLog(@"[Bonjour save] Error writing to AirPlay_BonJour.txt: %@", error);
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[Bonjour save] Successfully updated AirPlay_BonJour.txt with device info.");
        #endif
    }
}

#pragma mark - Cleanup

- (void)cleanupBonjourFile {
    if ([[NSFileManager defaultManager] fileExistsAtPath:_bonjourFilePath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:_bonjourFilePath error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Cleanup] Error deleting AirPlay_BonJour.txt: %@", error);
            #endif
        } else {
            #ifdef DEBUG
            NSLog(@"[Cleanup] AirPlay_BonJour.txt has been reset.");
            #endif
        }
    }
}

@end
