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
//  ZPAirPlayStreamer.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 14/11/2026.
//

#import "ZPAirPlayStreamer.h"
#import <TPCircularBuffer/TPCircularBuffer.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <errno.h>

@interface ZPAirPlayStreamer ()

// Existing properties
@property (nonatomic, strong) NSString *ipAddress;
@property (nonatomic, assign) NSInteger latency;
@property (nonatomic, strong) NSString *port;
@property (nonatomic, strong) NSTask *raopTask;
@property (nonatomic, strong) NSPipe *inputPipe;
@property (nonatomic, strong) AVAudioEngine *audioEngine;

// New properties
@property (nonatomic, strong) NSOutputStream *fileOutputStream;
@property (nonatomic, assign) BOOL isStreaming;
@property (nonatomic, assign) BOOL isRecording;

// Circular buffer
@property (nonatomic, assign) TPCircularBuffer circularBuffer;

// Gain adjustment
@property (assign, nonatomic) float gainFactor2;

// Opus Decoder
@property (nonatomic, strong) ZPOpusDecoder *opusDecoder;

@property (nonatomic, strong) dispatch_source_t healthCheckTimer;
@property (nonatomic, assign) int lockFileDescriptor; // File descriptor for the lock file

// Private helper used to send a DMAP "play" command
- (void)sendPlayCommandToDeviceWithIP:(NSString *)deviceIP
                                  port:(NSInteger)port
                              sessionID:(NSInteger)sessionID;

// New helper that wakes up the device using `atvremote`
- (void)sendWakeUpCallToDeviceWithIP:(NSString *)deviceIP;

// Continuation of streaming setup executed after the wake-up call
- (void)startStreamingAfterWakeUp;

@end

// Default pairing GUID used when issuing DMAP login requests. This mirrors
// the credentials printed by `atvremote --scan` for the target Apple TV.
static NSString *const kDMAPPairingGUID = @"00000000-0008-2083-cd93-e7745ad24855";

// Runs a small Python helper script that invokes `atvremote` to establish a
// DMAP session and returns the headers printed by the tool as a dictionary.
static NSDictionary *runPythonScriptAndParseJSON(NSString *deviceIP) {
    NSString *pyScript = [NSString stringWithFormat:
        @"#!/usr/bin/env python3\n"
        "# -*- coding: utf-8 -*-\n"
        "import subprocess\n"
        "import json\n"
        "import re\n"
        "import sys\n"
        "import os\n"
        "import shutil\n"
        "\n"
        "DEVICE_ID = \"B6534AF50FB3320F\"\n"
        "PROTOCOL = \"dmap\"\n"
        "ADDRESS = \"%@\"\n"
        "PORT = 3689\n"
        "\n"
        "# Localização do atvremote: primeiro PATH, depois fallback (o teu caminho actual)\n"
        "atv = shutil.which(\"atvremote\")\n"
        "if not atv:\n"
        "    atv = \"/Users/amaral/.local/bin/atvremote\"\n"
        "\n"
        "if not atv or not os.path.exists(atv):\n"
        "    print(\"[Acordar ATV] atvremote não encontrado (PATH e fallback falharam)\")\n"
        "    sys.exit(1)\n"
        "\n"
        "# Forçar modo manual para evitar discovery (scan) falhar silenciosamente\n"
        "command = [\n"
        "    atv,\n"
        "    \"--manual\",\n"
        "    \"--address\", ADDRESS,\n"
        "    \"--port\", str(PORT),\n"
        "    \"--protocol\", PROTOCOL,\n"
        "    \"--id\", DEVICE_ID,\n"
        "    \"play\",\n"
        "    \"--debug\",\n"
        "]\n"
        "\n"
        "try:\n"
        "    proc = subprocess.run(\n"
        "        command,\n"
        "        stdout=subprocess.PIPE,\n"
        "        stderr=subprocess.STDOUT,\n"
        "        text=True,\n"
        "        timeout=8,\n"
        "    )\n"
        "    output = proc.stdout or \"\"\n"
        "except subprocess.TimeoutExpired:\n"
        "    print(\"[Acordar ATV] Timeout ao executar atvremote\")\n"
        "    sys.exit(1)\n"
        "except Exception as e:\n"
        "    print(f\"[Acordar ATV] Erro ao executar atvremote: {e}\")\n"
        "    sys.exit(1)\n"
        "\n"
        "if proc.returncode != 0:\n"
        "    # Mantém output para diagnóstico\n"
        "    print(f\"[Acordar ATV] atvremote terminou com erro (returncode={proc.returncode})\")\n"
        "    print(output)\n"
        "    sys.exit(1)\n"
        "\n"
        "headers = {\n"
        "    \"Host\": None,\n"
        "    \"Session-Id\": None,\n"
        "    \"Active-Remote\": None,\n"
        "    # Mantém compatibilidade: usa o mesmo valor que tinhas\n"
        "    \"X-Apple-Device-Guid\": DEVICE_ID,\n"
        "}\n"
        "\n"
        "# Regexes robustos para o formato actual (pyatv 0.17.x) e fallback para formatos antigos\n"
        "re_url_host = re.compile(r\"URL:\\s+https?://([^/]+)\")\n"
        "re_old_host = re.compile(r\"\\bat\\s+([^\\s]+)\")\n"
        "re_session = re.compile(r\"\\bsession id\\s+(\\d+)\")\n"
        "re_cmsr = re.compile(r\"\\bcmsr:\\s+(\\d+)\\b\")\n"
        "\n"
        "for line in output.splitlines():\n"
        "    if headers[\"Host\"] is None:\n"
        "        m = re_url_host.search(line)\n"
        "        if m:\n"
        "            headers[\"Host\"] = m.group(1)\n"
        "        elif \"via Protocol.DMAP\" in line and \" at \" in line:\n"
        "            m2 = re_old_host.search(line)\n"
        "            if m2:\n"
        "                headers[\"Host\"] = m2.group(1)\n"
        "\n"
        "    if headers[\"Session-Id\"] is None and (\"session id\" in line):\n"
        "        ms = re_session.search(line)\n"
        "        if ms:\n"
        "            headers[\"Session-Id\"] = ms.group(1)\n"
        "\n"
        "    if headers[\"Active-Remote\"] is None and (\"cmsr:\" in line):\n"
        "        mr = re_cmsr.search(line)\n"
        "        if mr:\n"
        "            headers[\"Active-Remote\"] = mr.group(1)\n"
        "\n"
        "# Normalizar Host: se vier sem porta, acrescenta :3689\n"
        "if headers[\"Host\"] and (\":\" not in headers[\"Host\"]):\n"
        "    headers[\"Host\"] = f\"{headers['Host']}:{PORT}\"\n"
        "\n"
        "# Caminho portável (derivado de ~) + criação de pasta\n"
        "app_support = os.path.join(os.path.expanduser(\"~\"), \"Library\", \"Application Support\", \"tocaTintas\")\n"
        "os.makedirs(app_support, exist_ok=True)\n"
        "json_path = os.path.join(app_support, \"acordar.json\")\n"
        "\n"
        "if all(headers.values()):\n"
        "    try:\n"
        "        tmp_path = json_path + \".tmp\"\n"
        "        with open(tmp_path, \"w\", encoding=\"utf-8\") as f:\n"
        "            json.dump(headers, f, indent=2)\n"
        "        os.replace(tmp_path, json_path)\n"
        "    except Exception as e:\n"
        "        print(f\"[Acordar ATV] Erro ao gravar JSON: {e}\")\n"
        "        sys.exit(1)\n"
        "    print(json.dumps(headers), flush=True)\n"
        "else:\n"
        "    print(\"[Acordar ATV] Falha na extração dos cabeçalhos\", headers)\n"
        "    # Para diagnóstico, também imprime o output completo\n"
        "    print(output)\n"
        , deviceIP];

    NSString *tempPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pyatv_embutido.py"];
    NSError *error = nil;

    if (![pyScript writeToFile:tempPath atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        #ifdef DEBUG
        NSLog(@"[Acordar ATV] Erro ao escrever script Python: %@", error);
        #endif
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/local/bin/python3";
    task.arguments = @[tempPath];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    [task launch];
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    [task waitUntilExit];

    [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];

    if (data.length == 0) {
        #ifdef DEBUG
        NSLog(@"[Acordar ATV] Sem output do script Python.");
        #endif
        return nil;
    }

    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    (void)raw;
    #ifdef DEBUG
    NSLog(@"[Acordar ATV] Python Output: %@", raw);
    #endif
    NSError *jsonError = nil;
    NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError || ![parsed isKindOfClass:[NSDictionary class]]) {
        #ifdef DEBUG
        NSLog(@"[Acordar ATV] Erro ao interpretar JSON: %@; Output bruto: %@", jsonError, raw);
        #endif
        return nil;
    }

    return parsed;
}

// Sends a DMAP command using information returned from `runPythonScriptAndParseJSON`.
static void sendCommandWithInfo(NSDictionary *info, NSString *command) {
    NSString *ip = info[@"ip"];
    NSNumber *session = info[@"session_id"];
    NSString *guid = info[@"guid"];
    id active = info[@"active_remote"];

    if (!ip || !session || !guid || !command || command.length == 0) {
        #ifdef DEBUG
        NSLog(@"[Acordar ATV] Dados insuficientes para enviar comando '%@'.", command ?: @"(desconhecido)");
        #endif
        return;
    }

    NSString *escapedCommand = [command stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"http://%@:3689/ctrl-int/1/%@?session-id=%llu&prompt-id=0",
                           ip, escapedCommand, session.unsignedLongLongValue];

    NSURL *url = [NSURL URLWithString:urlString];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";

    [req addValue:guid forHTTPHeaderField:@"X-Apple-Device-GUID"];
    if (active && ![active isKindOfClass:[NSNull class]]) {
        [req addValue:active forHTTPHeaderField:@"Active-Remote"];
    }

    dispatch_semaphore_t sema = dispatch_semaphore_create(0);

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
        dataTaskWithRequest:req
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
              if (error) {
                  #ifdef DEBUG
                  NSLog(@"[Acordar ATV] Erro ao enviar comando '%@': %@", command, error);
                  #endif
              } else {
                  NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                  (void)http;
                  #ifdef DEBUG
                  NSLog(@"[Acordar ATV] Comando '%@' enviado. Código HTTP: %ld", command, (long)http.statusCode);
                  #endif
              }
              dispatch_semaphore_signal(sema);
          }];

    [task resume];
    dispatch_semaphore_wait(sema, DISPATCH_TIME_FOREVER);
}

@implementation ZPAirPlayStreamer

#pragma mark - Initialization

- (instancetype)initWithIPAddress:(NSString *)ipAddress port:(NSString *)port replayGainValue:(float)replayGainValue {
    self = [super init];
    if (self) {
        _ipAddress = ipAddress;
        //_latency = 132300; // 3 s of latency
        _latency = 44100; // Default latency
        _port = port;
        _audioEngine = [[AVAudioEngine alloc] init];
        _isStreaming = NO;
        _isRecording = NO;
        [self setGainInDecibels2:replayGainValue]; // replayGainValue is in dB, convert it here

        // Initialize the circular buffer with 10 seconds of stereo audio
        TPCircularBufferInit(&_circularBuffer, 44100 * 2 * 10); // Original value
        //TPCircularBufferInit(&_circularBuffer, 44100 * 4 * 10); // 1_764_000

        // Observe changes to the "SelectedAirPlayDevice" key
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(userDefaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    // Remove observer for user defaults changes
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSUserDefaultsDidChangeNotification
                                                  object:nil];
    TPCircularBufferCleanup(&_circularBuffer);
}

#pragma mark - Keep just one instance of raop_play

- (BOOL)isRaopPlayAlreadyRunning {
    // Get Application Support folder path
    NSArray<NSURL *> *appSupportURLs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *appSupportURL = [appSupportURLs firstObject];
    NSURL *appSpecificDirectory = [appSupportURL URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES];

    // Ensure the directory exists
    NSError *error = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:[appSpecificDirectory path]]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:appSpecificDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Streaming] Error creating directory: %@", error.localizedDescription);
            #endif
            return NO;
        }
    }

    // Define the lock file path
    NSString *lockFilePath = [[appSpecificDirectory URLByAppendingPathComponent:@"raop_play.lock"] path];

    // Try to open the lock file
    int lockFileDescriptor = open([lockFilePath UTF8String], O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (lockFileDescriptor < 0) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Failed to open lock file: %s", strerror(errno));
        #endif
        return NO;
    }

    // Use flock to check if the lock is already held
    if (flock(lockFileDescriptor, LOCK_EX | LOCK_NB) < 0) {
        if (errno == EWOULDBLOCK) {
            // Lock is already held, indicating raop_play might be running
            #ifdef DEBUG
            NSLog(@"[Streaming] Lock file is locked. Checking for active raop_play instances…");
            #endif

            // Use pgrep to count active instances of raop_play
            NSTask *pgrepTask = [[NSTask alloc] init];
            pgrepTask.launchPath = @"/usr/bin/pgrep";
            pgrepTask.arguments = @[@"-c", @"raop_play"]; // -c: Count the number of matching processes

            NSPipe *outputPipe = [NSPipe pipe];
            pgrepTask.standardOutput = outputPipe;

            @try {
                [pgrepTask launch];
                [pgrepTask waitUntilExit];
            } @catch (NSException *exception) {
                #ifdef DEBUG
                NSLog(@"[Streaming] Exception while checking process count: %@", exception.reason);
                #endif
                close(lockFileDescriptor);
                return YES; // Assume running if pgrep fails
            }

            // Parse the output of pgrep
            NSData *outputData = [[outputPipe fileHandleForReading] readDataToEndOfFile];
            NSString *processCountString = [[NSString alloc] initWithData:outputData encoding:NSUTF8StringEncoding];
            NSInteger processCount = [processCountString integerValue];

            if (processCount > 1) {
                // More than one instance detected; trigger cleanup
                #ifdef DEBUG
                NSLog(@"[Streaming] Detected %ld instances of raop_play. Cleaning up and restarting…", (long)processCount);
                #endif

                // Cleanup existing instances
                [self stopStreaming];

                // Return NO so that startStreaming can safely start a new instance
                close(lockFileDescriptor);
                return NO;
            } else if (processCount == 1) {
                #ifdef DEBUG
                NSLog(@"[Streaming] One active instance of raop_play found. No action needed.");
                #endif
                close(lockFileDescriptor);
                return YES; // One instance is running as expected
            } else {
                // No instances found; treat as stale lock file
                #ifdef DEBUG
                NSLog(@"[Streaming] No active raop_play instances found. Removing stale lock file.");
                #endif
                [[NSFileManager defaultManager] removeItemAtPath:lockFilePath error:nil];
                close(lockFileDescriptor);
                return NO;
            }
        }

        #ifdef DEBUG
        NSLog(@"[Streaming] Failed to acquire lock: %s", strerror(errno));
        #endif
        close(lockFileDescriptor);
        return NO;
    }

    // Lock acquired successfully
    #ifdef DEBUG
    NSLog(@"[Streaming] Lock acquired successfully. No existing raop_play instances detected.");
    #endif
    self.lockFileDescriptor = lockFileDescriptor; // Store descriptor to maintain lock
    return NO;
}

+ (void)cleanupRaopPlayLockFile {
    // Get Application Support folder path
    NSArray<NSURL *> *appSupportURLs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *appSupportURL = [appSupportURLs firstObject];
    NSURL *appSpecificDirectory = [appSupportURL URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES];

    // Define the lock file path
    NSURL *lockFileURL = [appSpecificDirectory URLByAppendingPathComponent:@"raop_play.lock"];
    NSString *lockFilePath = lockFileURL.path;

    // Remove the lock file
    if ([[NSFileManager defaultManager] fileExistsAtPath:lockFilePath]) {
        NSError *error = nil;
        [[NSFileManager defaultManager] removeItemAtPath:lockFilePath error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Lockfile] Failed to remove lock file: %@", error.localizedDescription);
            #endif
        } else {
            #ifdef DEBUG
            NSLog(@"[Lockfile] Lock file removed successfully.");
            #endif
        }
    } else {
        #ifdef DEBUG
        NSLog(@"[Lockfile] No lock file exists at %@", lockFilePath);
        #endif
    }
}

- (void)checkRaopPlayHealth {
    // 1. Check if streaming is active
    if (!self.isStreaming) {
        // If streaming is not active, no further checks are needed
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] Streaming is not active. Skipping health check.");
        #endif
        return;
    }

    // 2. Retrieve the selected AirPlay device from user defaults
    NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
    if (!selectedDevice) {
        // If no device is selected, user must have deselected or never selected one
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] No AirPlay device selected. Skipping health check.");
        #endif
        return;
    }

    // 3. Check for the existence of the lock file
    NSArray<NSURL *> *appSupportURLs = [[NSFileManager defaultManager]
                                        URLsForDirectory:NSApplicationSupportDirectory
                                               inDomains:NSUserDomainMask];
    if (appSupportURLs.count == 0) {
        // Could not locate the Application Support directory; bail out
        return;
    }

    NSURL *appSupportURL = [appSupportURLs firstObject];
    NSURL *appSpecificDirectory = [appSupportURL URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES];
    NSURL *lockFileURL = [appSpecificDirectory URLByAppendingPathComponent:@"raop_play.lock"];
    NSString *lockFilePath = lockFileURL.path;

    if (![[NSFileManager defaultManager] fileExistsAtPath:lockFilePath]) {
        // Lock file is missing, indicating raop_play may not be running
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] No lock file found, but user defaults say device is '%@'. Restarting raop_play…", selectedDevice);
        #endif

        // Restart streaming
        [self startStreaming];
        return;
    }

    // 4. Check if the raop_play process is running using pgrep
    NSTask *pgrepTask = [[NSTask alloc] init];
    pgrepTask.launchPath = @"/usr/bin/pgrep";
    pgrepTask.arguments = @[@"raop_play"];

    NSPipe *outputPipe = [NSPipe pipe];
    pgrepTask.standardOutput = outputPipe;

    @try {
        [pgrepTask launch];
        [pgrepTask waitUntilExit];
    } @catch (NSException *exception) {
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] Exception during pgrep: %@", exception.reason);
        #endif
        // If pgrep fails, we can't confirm anything. Exit the method.
        return;
    }

    int status = pgrepTask.terminationStatus;
    if (status != 0) {
        // pgrep didn't find the raop_play process
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] No raop_play process found (status=%d). Restarting streaming for device '%@'.", status, selectedDevice);
        #endif

        // Restart streaming
        [self startStreaming];
    } else {
        // Process is running, no action needed
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] raop_play process found via pgrep. All is well.");
        #endif
    }
}

- (void)setupHealthCheckTimer {
    // Create a dispatch queue for the timer
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);

    // Create the dispatch source timer
    self.healthCheckTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);

    if (self.healthCheckTimer) {
        // Set the timer to fire immediately, with a 15-second interval, and a leeway of 5 seconds
        dispatch_source_set_timer(self.healthCheckTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  60ull * NSEC_PER_SEC,
                                  5ull * NSEC_PER_SEC); // Leeway for flexibility

        // Define the event handler for the timer
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(self.healthCheckTimer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [strongSelf checkRaopPlayHealth];
            }
        });

        // Start the timer
        dispatch_resume(self.healthCheckTimer);

        #ifdef DEBUG
        NSLog(@"[Streaming] Health-check timer initialized.");
        #endif
    } else {
        // Handle failure to create the timer
        #ifdef DEBUG
        NSLog(@"[Streaming] Failed to initialize health-check timer.");
        #endif
    }
}

- (void)userDefaultsDidChange:(NSNotification *)notification {
    // Retrieve the selected AirPlay device from user defaults
    NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
    
    if (!selectedDevice) {
        // No device is selected; stop streaming
        #ifdef DEBUG
        NSLog(@"[Streaming] AirPlay device deselected. Stopping streaming.");
        #endif
        [self stopStreaming];
    }
}

#pragma mark - Wake-up call to AirPLay device


// Attempts to wake the target Apple TV by running `atvremote` and sending
// a DMAP play command using the discovered session information. The selected
// device's IP address is injected into the Python script.
- (void)sendWakeUpCallToDeviceWithIP:(NSString *)deviceIP
{
    if (deviceIP.length == 0) {
        #ifdef DEBUG
        NSLog(@"[Wake-up] Invalid IP address");
        #endif
        return;
    }

    NSDictionary *info = runPythonScriptAndParseJSON(deviceIP);
    if (!info) {
        #ifdef DEBUG
        NSLog(@"[Wake-up] Python helper failed to provide connection info");
        #endif
        return;
    }

    NSString *ip = [info[@"Host"] componentsSeparatedByString:@":"].firstObject;
    if (!ip) {
        #ifdef DEBUG
        NSLog(@"[Wake-up] Unable to extract IP from %@", info[@"Host"]);
        #endif
        return;
    }

    NSDictionary *mapped = @{
        @"ip": ip,
        @"session_id": @([info[@"Session-Id"] longLongValue]),
        @"guid": info[@"X-Apple-Device-Guid"],
        @"active_remote": info[@"Active-Remote"] ?: [NSNull null]
    };

    sendCommandWithInfo(mapped, @"play");
}

// Sends a DMAP "play" command similar to `atvremote --protocol dmap play`
- (void)sendPlayCommandToDeviceWithIP:(NSString *)deviceIP
                                  port:(NSInteger)port
                              sessionID:(NSInteger)sessionID
{
    if (deviceIP.length == 0) {
        #ifdef DEBUG
        NSLog(@"[DMAP] Invalid IP address");
        #endif
        return;
    }

    NSInteger playPort = 3689; // DMAP always listens on 3689
    if (port != playPort) {
#ifdef DEBUG
        NSLog(@"[DMAP] Ignoring provided play port %ld and using %ld",
              (long)port, (long)playPort);
#endif
    }
    port = playPort;

    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"http";
    components.host = deviceIP;
    components.port = @(port);
    components.path = @"/ctrl-int/1/play";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"session-id"
                                     value:[NSString stringWithFormat:@"%ld",
                                            (long)sessionID]]
    ];

    NSURL *url = components.URL;
    if (!url) {
        #ifdef DEBUG
        NSLog(@"[DMAP] Invalid URL for play command %@:%ld", deviceIP, (long)port);
        #endif
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    [request setValue:@"Remote/1.0" forHTTPHeaderField:@"User-Agent"];
    [request setValue:@"1" forHTTPHeaderField:@"Viewer-Only-Client"];
    [request setValue:@"3.13" forHTTPHeaderField:@"Client-DAAP-Version"];
    [request setValue:[NSString stringWithFormat:@"%ld", (long)sessionID]
           forHTTPHeaderField:@"Active-Remote"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 10.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                           completionHandler:^(NSData *data,
                                                               NSURLResponse *response,
                                                               NSError *error) {
        #ifdef DEBUG
        if (error) {
            NSLog(@"[DMAP] Play command failed: %@", error.localizedDescription);
        } else {
            NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
            NSLog(@"[DMAP] Play command HTTP Status: %ld", (long)httpResponse.statusCode);
        }
        #endif
    }];

    [task resume];
}

/// Convenience wrapper that uses the current IP and port values
- (void)sendPlayCommand
{
    // Use the default DMAP port (3689) regardless of the RAOP port
    [self sendPlayCommandToDeviceWithIP:self.ipAddress
                                      port:3689
                                  sessionID:1];
}

#pragma mark - Streaming Methods

- (void)startStreaming {
    // Clear any previous cancel flag
    self.cancelPendingStart = NO;
    // Ensure local playback and AirPlay streaming coexist
    [ZPAirPlayStreamer cleanupRaopPlayLockFile];

    // Check if a device is selected
    NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
    if (!selectedDevice) {
        #ifdef DEBUG
        NSLog(@"[Streaming] No AirPlay device selected. Aborting streaming.");
        #endif
        self.isStreaming = NO;
        return;
    }
    
    // Wake up the AirPlay device on a background queue to avoid blocking the UI
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self sendWakeUpCallToDeviceWithIP:self.ipAddress];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self startStreamingAfterWakeUp];
        });
    });
}

// Make sure that the fifo file for raop_play exists
static NSString * const kRaopClockPath = @"/var/tmp/raop_clock";

- (BOOL)ensureRaopClockAtPath:(NSString *)path
                 keepAliveFD:(int *)fdOut
                       error:(NSError **)error
{
    const char *p = path.fileSystemRepresentation;
    struct stat st;
    if (lstat(p, &st) == 0 && !S_ISFIFO(st.st_mode)) {
        unlink(p);
    }
    if (mkfifo(p, 0666) == -1 && errno != EEXIST) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:@{ NSFilePathErrorKey: path ?: @"" }];
        return NO;
    }
    chmod(p, 0666);

    // Mantém o FIFO aberto para evitar bloqueios de open()
    int fd = open(p, O_RDWR | O_NONBLOCK);
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:@{ NSFilePathErrorKey: path ?: @"" }];
        return NO;
    }
    if (fdOut) *fdOut = fd;
    return YES;
}

// Remaining setup performed after the wake-up call completes
- (void)startStreamingAfterWakeUp {

    // Abort if the pending start was cancelled or device was deselected
    NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
    if (self.cancelPendingStart || !selectedDevice) {
#ifdef DEBUG
        NSLog(@"[Streaming] Start cancelled before wake-up completed.");
#endif
        return;
    }
    
    // Check if streaming is already active
    if (self.isStreaming) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Already streaming. No further action needed.");
        #endif
        return;
    }

    // Check if raop_play is already running
    if ([self isRaopPlayAlreadyRunning]) {
        #ifdef DEBUG
        NSLog(@"[Streaming] raop_play is already running. Cannot start another instance.");
        #endif
        return;
    }

    // Stop any existing streaming before starting new streaming
    if (self.raopTask || self.inputPipe) {
        [self stopStreaming];
    }

    // Initialize the input pipe and RAOP task
    self.inputPipe = [NSPipe pipe];
    self.raopTask = [[NSTask alloc] init];

    if (!self.inputPipe || !self.raopTask) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Failed to initialize pipe or RAOP task.");
        #endif
        self.isStreaming = NO;
        return;
    }

    // Locate the raop_play executable
    NSString *raopPlayPath = [[NSBundle mainBundle] pathForResource:@"raop_play" ofType:nil];
    if (!raopPlayPath) {
        #ifdef DEBUG
        NSLog(@"[Streaming] raop_play executable not found.");
        #endif
        self.isStreaming = NO;
        return;
    }
    
    // Check the presence of the fifo file for raop_play
    NSError *fifoErr = nil;
    if (![self ensureRaopClockAtPath:kRaopClockPath keepAliveFD:&_raopClockFD error:&fifoErr]) {
        NSLog(@"[RAOP] Falha a garantir FIFO %@: %@", kRaopClockPath, fifoErr);
        return; // ou apresenta erro ao utilizador
    }

    // Configure the RAOP task
    // Define the values for all the flags
    self.raopTask.launchPath = raopPlayPath;
    self.raopTask.arguments = @[
        @"-a",
        @"-p", self.port,
        @"-l", [NSString stringWithFormat:@"%ld", (long)self.latency],
        @"-f", @"/var/tmp/raop_clock",
        self.ipAddress,
        @"-"
    ];
    self.raopTask.standardInput = self.inputPipe;

    // Configure task termination handler
    __weak typeof(self) weakSelf = self;
    self.raopTask.terminationHandler = ^(NSTask *task) {
        #ifdef DEBUG
        NSLog(@"[Streaming] RAOP task terminated. Reason: %ld, Status: %d",
              task.terminationReason, task.terminationStatus);
        #endif

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Cleanup lock file
        [ZPAirPlayStreamer cleanupRaopPlayLockFile];

        // Check if a device is still selected
        NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
        if (selectedDevice) {
            #ifdef DEBUG
            NSLog(@"[Streaming] RAOP task terminated, but device (%@) is still selected. Restarting streaming.", selectedDevice);
            #endif

            // Restart streaming
            [strongSelf startStreaming];
        } else {
            // Finalize stop
            #ifdef DEBUG
            NSLog(@"[Streaming] No AirPlay device selected. Stopping streaming completely.");
            #endif
            strongSelf.isStreaming = NO;
            strongSelf.inputPipe = nil;
            strongSelf.raopTask = nil;
        }
    };

    #ifdef DEBUG
    NSLog(@"[Streaming] Starting RAOP task…");
    #endif

    // Launch the RAOP task
    @try {
        [self.raopTask launch];
    } @catch (NSException *exception) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Failed to start RAOP task: %@", exception.reason);
        #endif
        self.isStreaming = NO;

        // Cleanup lock file on failure
        [ZPAirPlayStreamer cleanupRaopPlayLockFile];
        return;
    }

    // Update streaming state
    self.isStreaming = YES;

    // Initialize the GCD dispatch source timer for health checks
    [self setupHealthCheckTimer];

    // Prevent system sleep during streaming
    self.preventSleepActivity = [[NSProcessInfo processInfo] beginActivityWithOptions:NSActivityUserInitiated
                                reason:@"[Streaming] Prevent sleep during AirPlay"];

    // Start or update audio capture
    [self startOrUpdateAudioCapture];
}

- (void)stopStreaming {
    self.cancelPendingStart = YES;
    if (!self.isStreaming) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Streaming is not running.");
        #endif
        return;
    }
    self.isStreaming = NO;

    // 1) Timers
    if (self.healthCheckTimer) {
        dispatch_source_cancel(self.healthCheckTimer);
        self.healthCheckTimer = nil;
        #ifdef DEBUG
        NSLog(@"[Streaming] Health check timer canceled.");
        #endif
    }

    // 2) Fecha stdin do raop_play para sinalizar EOF
    if (self.inputPipe && self.inputPipe.fileHandleForWriting) {
        [self.inputPipe.fileHandleForWriting closeFile];
        self.inputPipe = nil;
        #ifdef DEBUG
        NSLog(@"[Streaming] Input pipe closed.");
        #endif
    }

    // 3) Give a chance of a clean exit
    if (self.raopTask) {
        // Short wait (without blocking too much the UI)
        for (int i = 0; i < 20 && self.raopTask.isRunning; i++) {
            [NSThread sleepForTimeInterval:0.05];
        }
        if (self.raopTask.isRunning) {
            [self.raopTask terminate]; // SIGTERM
            for (int i = 0; i < 20 && self.raopTask.isRunning; i++) {
                [NSThread sleepForTimeInterval:0.05];
            }
            if (self.raopTask.isRunning) {
                pid_t pid = self.raopTask.processIdentifier;
                if (pid > 0) kill(pid, SIGKILL); // last resource
            }
        }
        #ifdef DEBUG
        NSLog(@"[Streaming] RAOP task terminated.");
        #endif
        self.raopTask = nil;
    } else {
        #ifdef DEBUG
        NSLog(@"[Streaming] RAOP task was not running.");
        #endif
    }

    // 4) Always close the FIFO keep-alive
    int fd = self.raopClockFD;
    self.raopClockFD = -1;            // to avoid double-close in races

    if (fd >= 0) {
        while (close(fd) == -1 && errno == EINTR) { /* retry */ }
        #ifdef DEBUG
        NSLog(@"[Streaming] Closed the raop_play fifo (fd=%d).", fd);
        #endif
    }
    // 5) Always recreate the fifo for a fresh start
        unlink("/var/tmp/raop_clock");

    // 6) Lockfile
    if (self.lockFileDescriptor >= 0) { // use >=0, not >0
        close(self.lockFileDescriptor);
        self.lockFileDescriptor = -1;
        [ZPAirPlayStreamer cleanupRaopPlayLockFile];
        #ifdef DEBUG
        NSLog(@"[Streaming] Lock file removed successfully.");
        #endif
    }

    // 7) Stop audio capture if needed
    [self stopAudioCaptureIfNeeded];
    if (self.preventSleepActivity) {
        [[NSProcessInfo processInfo] endActivity:self.preventSleepActivity];
        self.preventSleepActivity = nil;
        #ifdef DEBUG
        NSLog(@"[Streaming] Sleep allowed.");
        #endif
    }

    #ifdef DEBUG
    NSLog(@"[Streaming] Streaming stopped and resources cleaned up.");
    #endif
}

#pragma mark - Recording Methods

- (void)startRecording {
    if (self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Already recording.");
        #endif
        return;
    }

    self.isRecording = YES;
    [self setGainInDecibels2:6.0];

    NSArray<NSURL *> *appSupportURLs = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask];
    NSURL *appSupportURL = [appSupportURLs firstObject];
    NSURL *tocaTintasDirectory = [appSupportURL URLByAppendingPathComponent:@"[Streaming] tocaTintas" isDirectory:YES];

    NSError *error = nil;
    if (![[NSFileManager defaultManager] fileExistsAtPath:[tocaTintasDirectory path]]) {
        [[NSFileManager defaultManager] createDirectoryAtURL:tocaTintasDirectory withIntermediateDirectories:YES attributes:nil error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Streaming] Error creating directory: %@", error.localizedDescription);
            #endif
        }
    }

    NSString *fileName = [NSString stringWithFormat:@"[Streaming] Recording_%@.pcm", [[NSUUID UUID] UUIDString]];
    NSURL *outputFileURL = [tocaTintasDirectory URLByAppendingPathComponent:fileName];

    self.fileOutputStream = [NSOutputStream outputStreamWithURL:outputFileURL append:NO];
    [self.fileOutputStream open];
    [self startOrUpdateAudioCapture];
    #ifdef DEBUG
    NSLog(@"[Streaming] Recording started. Saving to %@", [outputFileURL path]);
    #endif
}

- (void)stopRecording {
    if (!self.isRecording) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Recording is not running.");
        #endif
        return;
    }

    self.isRecording = NO;

    if (self.fileOutputStream) {
        [self.fileOutputStream close];
        self.fileOutputStream = nil;
        #ifdef DEBUG
        NSLog(@"[Streaming] Recording stopped and file output stream closed.");
        #endif
    }

    [self stopAudioCaptureIfNeeded];
}

#pragma mark - Audio Capture

- (void)startOrUpdateAudioCapture {
    if (self.audioEngine.isRunning) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Audio engine is already running.");
        #endif
        return;
    }

    [self installAudioTap];

    NSError *engineError = nil;
    if (![self.audioEngine startAndReturnError:&engineError]) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Error starting audio engine: %@", engineError.localizedDescription);
    } else {
        NSLog(@"[Streaming] Audio capturing started.");
        #endif
    }
}

- (void)stopAudioCaptureIfNeeded {
    if (!self.isRecording && !self.isStreaming) {
        if (self.audioEngine.isRunning) {
            [self.audioEngine.inputNode removeTapOnBus:0];
            [self.audioEngine stop];
            #ifdef DEBUG
            NSLog(@"[Streaming] Audio engine stopped.");
            #endif

        }
    } else {
        #ifdef DEBUG
        NSLog(@"[Streaming] Audio engine continues running (recording or streaming is active).");
        #endif
    }
}

#pragma mark - Original Audio Tap

- (void)installAudioTap {
    // Create a serial queue for streaming tasks
    dispatch_queue_t streamingQueue = dispatch_queue_create("com.zpairplay.streaming", DISPATCH_QUEUE_SERIAL);

    // Access the audio input node and its format
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;
    AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];

    // Validate input format
    if (!inputFormat || inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) {
        #ifdef DEBUG
        NSLog(@"[Error] Invalid input format: sample rate %f, channels %d",
              inputFormat.sampleRate, inputFormat.channelCount);
        #endif
        return;
    }

    // Target format for processing (16-bit PCM, 44.1 kHz, 2 channels)
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                   sampleRate:44100.0
                                                                     channels:2
                                                                  interleaved:YES];

    // Define a reusable streaming block
    void (^streamingBlock)(NSData *) = ^(NSData *data) {
        dispatch_async(streamingQueue, ^{
            if (!data || data.length == 0) return;

            @try {
                NSFileHandle *pipeWriteHandle = [self.inputPipe fileHandleForWriting];
                if (pipeWriteHandle) {
                    [pipeWriteHandle writeData:data];  // Potentially throws
                } else {
                    #ifdef DEBUG
                    NSLog(@"[Streaming] Pipe write handle is invalid (nil).");
                    #endif
                }
            } @catch (NSException *exception) {
                if ([exception.name isEqualToString:NSFileHandleOperationException]) {
                    // Check whether it's truly a broken/closed pipe
                    if ([exception.reason containsString:@"Broken pipe"] ||
                        [exception.reason containsString:@"closed file"]) {
                        
                        // Fatal: raop_play likely exited or pipe is irrecoverable
                        #ifdef DEBUG
                        NSLog(@"[Streaming] Broken or closed pipe, stopping streaming…");
                        #endif
                        [self stopStreaming];
                        
                    } else {
                        // Possibly a transient or less-critical error
                        #ifdef DEBUG
                        NSLog(@"[Streaming] NSFileHandleOperationException, but not broken pipe: %@", exception.reason);
                        #endif
                        // **Skip this chunk**: do not retry, do not kill streaming,
                        // just return so we effectively "lose" this chunk.
                        // The next chunk will be processed on the next callback.
                        #ifdef DEBUG
                        NSLog(@"[Streaming] Skipping the current chunk due to transient error…");
                        #endif
                        return;
                    }
                } else {
                    // Unknown exception: handle it as you see fit
                    #ifdef DEBUG
                    NSLog(@"[Streaming] Unknown exception writing to pipe: %@ (name=%@)",
                          exception.reason, exception.name);
                    #endif
                    // You might choose to skip, or you might decide
                    // to stopStreaming or rethrow. For example:
                    // [self stopStreaming];
                }
            }
        });
    };

    // Install audio tap
    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:inputFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        if (!buffer || buffer.frameLength == 0) return;

        dispatch_async(streamingQueue, ^{
            NSError *error = nil;

            // Convert audio buffer to the target format
            AVAudioPCMBuffer *convertedBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat frameCapacity:buffer.frameCapacity];
            AVAudioConverter *converter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:targetFormat];
            [converter convertToBuffer:convertedBuffer fromBuffer:buffer error:&error];

            if (error) {
                #ifdef DEBUG
                NSLog(@"[Streaming] Error converting audio buffer: %@", error.localizedDescription);
                #endif
                return;
            }

            // Apply gain to the audio data
            int16_t *pcmData = convertedBuffer.int16ChannelData[0];
            NSUInteger sampleCount = convertedBuffer.frameLength * targetFormat.channelCount;
            for (NSUInteger i = 0; i < sampleCount; i++) {
                int32_t scaledSample = (int32_t)(pcmData[i] * self.gainFactor2);
                pcmData[i] = MAX(INT16_MIN, MIN(INT16_MAX, scaledSample));
            }

            // Write data to circular buffer
            TPCircularBufferProduceBytes(&self->_circularBuffer, pcmData,
                                         convertedBuffer.frameLength * targetFormat.streamDescription->mBytesPerFrame);

            // Handle underflow by injecting silence
            uint32_t availableBytes = 0;
            TPCircularBufferTail(&self->_circularBuffer, &availableBytes);
            if (availableBytes == 0) {
                #ifdef DEBUG
                NSLog(@"[Streaming] Buffer underflow detected. Writing silence.");
                #endif
                int16_t silence[44100] = {0}; // 1 second of silence
                TPCircularBufferProduceBytes(&self->_circularBuffer, silence, sizeof(silence));
            }

            // Streaming logic
            if (self.isStreaming) {
                uint32_t availableBytes = 0;
                void *bufferPointer = TPCircularBufferTail(&self->_circularBuffer, &availableBytes);
                NSData *streamingData = [NSData dataWithBytes:bufferPointer length:availableBytes];
                streamingBlock(streamingData);
                TPCircularBufferConsume(&self->_circularBuffer, availableBytes);
            }

            // Recording logic
            if (self.isRecording) {
                NSData *recordingData = [NSData dataWithBytes:pcmData
                                                       length:(convertedBuffer.frameLength * targetFormat.streamDescription->mBytesPerFrame)];
                NSInteger bytesWritten = [self.fileOutputStream write:recordingData.bytes maxLength:recordingData.length];
                if (bytesWritten < 0) {
                    #ifdef DEBUG
                    NSLog(@"[Recording] Error writing to file: %@", self.fileOutputStream.streamError.localizedDescription);
                    #endif
                }
            }
        });
    }];
}

#pragma mark - Gain Adjustment

- (void)updateReplayGainValue:(float)dB {
    // Just call the existing method
    #ifdef DEBUG
    NSLog(@"[ReplayGain] All Formats, updateReplayGainValue received: %.2f", dB);
    #endif
    [self setGainInDecibels2:dB];
}

- (void)setGainInDecibels2:(float)gainInDb {
    self.gainFactor2 = powf(10.0, gainInDb / 20.0);
    #ifdef DEBUG
    NSLog(@"[ReplayGain] Final gain factor set to %.2f for %.2f dB gain.", self.gainFactor2, gainInDb);
    #endif
}

@end

