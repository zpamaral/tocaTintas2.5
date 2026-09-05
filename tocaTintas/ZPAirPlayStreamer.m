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
#import "ZPAudioCapture.h"                      // ZPBindEngineInputToLoopback, ZPLoopbackAudioDevice
#import "PreferencesWindowController.h"          // chaves das preferências
#import <TPCircularBuffer/TPCircularBuffer.h>
#import <AVFoundation/AVFoundation.h>
#import <sys/stat.h>
#import <sys/file.h>      // flock
#import <fcntl.h>
#import <errno.h>
#import <signal.h>        // kill
#import <string.h>
#import <stdatomic.h>

@interface ZPAirPlayStreamer ()

// Existing properties
@property (nonatomic, strong) NSString *ipAddress;
@property (nonatomic, assign) NSInteger latency;
@property (nonatomic, strong) NSString *port;
@property (nonatomic, strong) NSTask *raopTask;
@property (nonatomic, strong) NSPipe *inputPipe;
@property (nonatomic, strong) AVAudioEngine *audioEngine;

// New properties
@property (nonatomic, assign) BOOL isStreaming;

// Reutilizados em cada callback do tap: alocar no thread de áudio é o que não
// se deve fazer, e era o que aqui se fazia duas vezes por bloco.
@property (nonatomic, strong) AVAudioConverter *toFloatConverter;
@property (nonatomic, strong) AVAudioPCMBuffer *floatBuffer;
@property (nonatomic, strong) AVAudioPCMBuffer *int16Buffer;

// Circular buffer
@property (nonatomic, assign) TPCircularBuffer circularBuffer;

// Opus Decoder
@property (nonatomic, strong) ZPOpusDecoder *opusDecoder;

@property (nonatomic, strong) dispatch_source_t healthCheckTimer;
@property (nonatomic, assign) int lockFileDescriptor; // File descriptor for the lock file

// Relógio do raop_play (ver «Relógio do raop_play», mais abaixo).
@property (nonatomic, strong) dispatch_source_t raopClockSource;
@property (nonatomic, assign) int raopClockWriterFD;
@property (nonatomic, strong) NSMutableData *raopClockPartial;
@property (nonatomic, assign) NSTimeInterval raopClockStartedAt;

// Observer da reconfiguração do engine (mudanças de dispositivos de áudio)
@property (nonatomic, strong) id engineConfigObserver;

// Private helper used to send a DMAP "play" command
- (void)sendPlayCommandToDeviceWithIP:(NSString *)deviceIP
                                  port:(NSInteger)port
                              sessionID:(NSInteger)sessionID;

// New helper that wakes up the device using `atvremote`
- (void)sendWakeUpCallToDeviceWithIP:(NSString *)deviceIP;

// Monta a transmissão: lança o raop_play, o consumidor do tampão, o leitor do
// relógio e a captura. Chama-se logo, sem esperar pelo acordar, que corre ao
// lado.
- (void)arrancarTransmissao;

// Tranco do raop_play e limpeza de instâncias deixadas por sessões anteriores.
// Ver o bloco «Uma só instância do raop_play».
- (BOOL)adquirirTrancoDoRaopPlay;
- (void)largarTrancoDoRaopPlay;
- (NSUInteger)matarRaopPlayOrfaos;

// Repõe o estado interno e relança o streaming depois de uma falha
// (morte do raop_play ou perda do tap). Sem isto, startStreaming aborta
// em "Already streaming" porque isStreaming nunca volta a NO.
- (void)restartStreamingAfterFailure;

// Relógio do raop_play
- (void)startRaopClockReader;
- (void)stopRaopClockReader;
- (void)relatarRelogio;

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

    // O interpretador deixou de estar escrito a martelo. Se o /usr/local/bin
    // desaparecer numa arrumação do Homebrew, o -launch do NSTask levanta uma
    // NSException que ninguém apanha e a aplicação vai abaixo — a acordar um
    // aparelho, que é a coisa mais dispensável que aqui se faz.
    NSString *python = nil;
    for (NSString *candidato in @[@"/usr/local/bin/python3",
                                  @"/opt/homebrew/bin/python3",
                                  @"/usr/bin/python3"]) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidato]) {
            python = candidato;
            break;
        }
    }
    if (!python) {
        NSLog(@"[Acordar ATV] Não encontrei um python3; o aparelho terá de acordar sozinho.");
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        return nil;
    }

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = python;
    task.arguments = @[tempPath];

    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;

    @try {
        [task launch];
    } @catch (NSException *excepcao) {
        NSLog(@"[Acordar ATV] Não consegui lançar o %@: %@", python, excepcao.reason);
        [[NSFileManager defaultManager] removeItemAtPath:tempPath error:nil];
        return nil;
    }

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

    // Sem semáforo: manda-se e segue-se. O que aqui estava esperava pela
    // resposta com DISPATCH_TIME_FOREVER, e como isto corria antes de a
    // transmissão sequer arrancar, um aparelho que aceitasse a ligação e não
    // respondesse segurava o arranque todo o tempo que quisesse.
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 10.0;

    NSURLSessionDataTask *task = [[NSURLSession sessionWithConfiguration:config]
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
          }];

    [task resume];
}

@implementation ZPAirPlayStreamer {
    // Ganho da normalização. O alvo é escrito pelo thread principal quando a
    // faixa muda e lido pelo thread de áudio, daí ser atómico; o «actual» só é
    // tocado dentro do tap, e é o que persegue o alvo bloco a bloco.
    _Atomic float _ganhoAlvo;
    float _ganhoActual;

    // Compensação da atenuação que o cursor de volume do macOS aplica ao
    // BlackHole. O que o tap multiplica é o produto dos dois.
    _Atomic float _ganhoCompensacao;

    // Contadores de áudio perdido. Incrementados no thread de áudio (só uma
    // soma atómica, sem registo nenhum lá dentro) e relatados pelo temporizador
    // de saúde. Ficam FORA do #ifdef DEBUG de propósito: perder amostras não é
    // acontecimento de rotina, e sem isto a compilação de lançamento perde-as
    // caladinha.
    _Atomic uint64_t _blocosDescartadosTapCheio;
    _Atomic uint64_t _bytesDescartadosTapCheio;
    _Atomic uint64_t _cortesDeDeriva;
    _Atomic uint64_t _bytesCortadosDeriva;

    // Relógio do raop_play. Escritas na fila do relógio (e, no caso dos bytes
    // entregues, no thread consumidor do tampão); leituras em qualquer lado,
    // incluindo pelas propriedades públicas.
    _Atomic uint64_t _bytesCapturados;        // o que o tap meteu no tampão
    _Atomic uint64_t _bytesCortadosTotal;     // o que a deriva deitou fora depois
    _Atomic uint64_t _bytesEntreguesAoRaop;   // quanto já enfiámos no tubo
    _Atomic uint64_t _relogioBlocos;          // contador de blocos da última linha
    _Atomic uint64_t _relogioHeadTs;          // head_ts da última linha
    _Atomic uint64_t _relogioLinhas;          // quantas linhas já chegaram
    _Atomic double   _relogioInstante;        // quando chegou a última
    _Atomic double   _relogioAtraso;          // Δ em segundos; 0 = desconhecido
}

#pragma mark - Initialization

- (instancetype)initWithIPAddress:(NSString *)ipAddress port:(NSString *)port replayGainValue:(float)replayGainValue {
    self = [super init];
    if (self) {
        _ipAddress = ipAddress;
        //_latency = 132300; // 3 s of latency
        _latency = 44100; // Default latency
        // Descritores por atribuir. Zero é um descritor válido — a entrada
        // padrão —, e o -stopStreaming fecha o que aqui estiver. O do tranco
        // faltava nesta lista: ficava a zero, e os caminhos em que o tranco não
        // chegava a ser adquirido acabavam a fechar o stdin da aplicação.
        _raopClockFD = -1;
        _raopClockWriterFD = -1;
        _lockFileDescriptor = -1;
        _port = port;
        _audioEngine = [[AVAudioEngine alloc] init];
        _isStreaming = NO;
        // Sem pico conhecido à partida; quem souber chama depois o
        // -updateReplayGainValue:trackPeak:. No arranque o ganho actual já
        // parte do alvo, para a primeira faixa não entrar com rampa.
        atomic_store(&_ganhoCompensacao, 1.0f);
        [self refreshSystemVolumeCompensation];
        [self observeSystemVolume];
        [self updateReplayGainValue:replayGainValue trackPeak:0.0f];
        _ganhoActual = atomic_load(&_ganhoAlvo) * atomic_load(&_ganhoCompensacao);

        // Initialize the circular buffer with 10 seconds of stereo audio
        //TPCircularBufferInit(&_circularBuffer, 44100 * 2 * 10); // Original value
        TPCircularBufferInit(&_circularBuffer, 44100 * 4 * 10); // 1_764_000

        // Observe changes to the "SelectedAirPlayDevice" key
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(userDefaultsDidChange:)
                                                     name:NSUserDefaultsDidChangeNotification
                                                   object:nil];

        // Quando a topologia de áudio muda (auscultadores, AirPods, sleep do
        // monitor, mudança de frequência), o AVAudioEngine pára e o tap morre
        // em silêncio — o raop_play continua vivo mas sem dados. Reinstalar o
        // tap e reiniciar o engine recupera a captura sem intervenção manual.
        __weak typeof(self) weakSelf = self;
        _engineConfigObserver = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioEngineConfigurationChangeNotification
                        object:_audioEngine
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;

            #ifdef DEBUG
            NSLog(@"[Streaming] Reconfiguração do engine de áudio detectada (mudança de dispositivos).");
            #endif

            if (!strongSelf.isStreaming) return;

            [strongSelf installAudioTap];

            NSError *engineError = nil;
            if (![strongSelf.audioEngine startAndReturnError:&engineError]) {
                #ifdef DEBUG
                NSLog(@"[Streaming] Erro ao reiniciar engine após reconfiguração: %@", engineError.localizedDescription);
                #endif
            } else {
                #ifdef DEBUG
                NSLog(@"[Streaming] Engine reiniciado com sucesso após reconfiguração.");
                #endif
            }
        }];
    }
    return self;
}

- (void)dealloc {
    // Remove observer for user defaults changes
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:NSUserDefaultsDidChangeNotification
                                                  object:nil];
    if (_engineConfigObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_engineConfigObserver];
        _engineConfigObserver = nil;
    }

    // Rede de segurança: se algum caminho de erro deixou o tranco por largar, é
    // aqui que ele morre. Sem isto, um streamer que morresse com o tranco na mão
    // calava todos os seguintes — e cada selecção de aparelho cria um streamer
    // novo.
    if (_lockFileDescriptor >= 0) {
        flock(_lockFileDescriptor, LOCK_UN);
        close(_lockFileDescriptor);
        _lockFileDescriptor = -1;
    }

    TPCircularBufferCleanup(&_circularBuffer);
}

#pragma mark - Uma só instância do raop_play

// Um ficheiro de tranco só serve para alguma coisa se ninguém lhe mexer: o
// flock vive no inode, portanto apagar o ficheiro e voltar a criá-lo dá um
// inode novo e um tranco que ninguém disputa. Era exactamente o que aqui se
// fazia — o -startStreaming apagava-o mesmo antes de o testar —, e por isso
// este mecanismo nunca detectou instância nenhuma em toda a sua vida. Agora o
// ficheiro é criado uma vez e nunca mais é apagado; o tranco larga-se fechando
// o descritor, e morre sozinho com o processo se a app estoirar. Um ficheiro de
// tranco que fique para trás não é lixo nem sinal de nada: é assim que isto
// funciona.

+ (NSString *)caminhoDoTrancoDoRaopPlay {
    NSURL *appSupport = [[[NSFileManager defaultManager]
                          URLsForDirectory:NSApplicationSupportDirectory
                                 inDomains:NSUserDomainMask] firstObject];
    if (!appSupport) return nil;

    NSURL *pasta = [appSupport URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:pasta
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];

    return [pasta URLByAppendingPathComponent:@"raop_play.lock"].path;
}

/// Tenta ficar com o tranco. Devolve NO só quando outra coisa o tem de facto.
/// Não conseguir abrir o ficheiro não é motivo para não tocar — o tranco é uma
/// rede de segurança, não uma condição de arranque.
- (BOOL)adquirirTrancoDoRaopPlay {
    if (self.lockFileDescriptor >= 0) return YES;   // já é nosso

    NSString *caminho = [ZPAirPlayStreamer caminhoDoTrancoDoRaopPlay];
    if (!caminho) return YES;

    int fd = open(caminho.fileSystemRepresentation, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR);
    if (fd < 0) {
        NSLog(@"[Streaming] Não consegui abrir o ficheiro de tranco (%s); sigo sem ele.",
              strerror(errno));
        return YES;
    }

    if (flock(fd, LOCK_EX | LOCK_NB) < 0) {
        int erro = errno;
        close(fd);
        if (erro == EWOULDBLOCK) {
            NSLog(@"[Streaming] O tranco do raop_play está tomado; não abro outra instância.");
            return NO;
        }
        NSLog(@"[Streaming] O flock falhou (%s); sigo sem tranco.", strerror(erro));
        return YES;
    }

    self.lockFileDescriptor = fd;
    #ifdef DEBUG
    NSLog(@"[Streaming] Tranco do raop_play adquirido (fd=%d).", fd);
    #endif
    return YES;
}

- (void)largarTrancoDoRaopPlay {
    if (self.lockFileDescriptor < 0) return;

    flock(self.lockFileDescriptor, LOCK_UN);
    close(self.lockFileDescriptor);
    self.lockFileDescriptor = -1;

    #ifdef DEBUG
    NSLog(@"[Streaming] Tranco do raop_play largado.");
    #endif
}

/// Mata os raop_play deixados por sessões anteriores — um estoiro, um «forçar a
/// saída», um relançamento que não esperou pelo anterior. Isto importa porque o
/// Apple TV só aceita uma sessão RAOP de cada vez: com um órfão vivo, a ligação
/// nova falha, o terminationHandler relança, e ficava um ciclo de tentativas que
/// só saía quando o aparelho largasse a sessão velha por si.
///
/// Só mata o executável que vem dentro deste pacote — nunca um raop_play de
/// outra proveniência — e nunca o nosso próprio filho.
- (NSUInteger)matarRaopPlayOrfaos {
    NSString *executavel = [[NSBundle mainBundle] pathForResource:@"raop_play" ofType:nil];
    if (!executavel) return 0;

    pid_t oNosso = self.raopTask.isRunning ? self.raopTask.processIdentifier : 0;
    NSMutableArray<NSNumber *> *orfaos = [NSMutableArray array];

    NSTask *pgrep = [[NSTask alloc] init];
    pgrep.launchPath = @"/usr/bin/pgrep";
    pgrep.arguments = @[@"-f", executavel];

    NSPipe *tubo = [NSPipe pipe];
    pgrep.standardOutput = tubo;
    pgrep.standardError = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [pgrep launch];
        NSData *saida = [tubo.fileHandleForReading readDataToEndOfFile];
        [pgrep waitUntilExit];

        NSString *texto = [[NSString alloc] initWithData:saida encoding:NSUTF8StringEncoding];
        for (NSString *linha in [texto componentsSeparatedByString:@"\n"]) {
            pid_t pid = (pid_t)linha.integerValue;
            if (pid > 0 && pid != oNosso && pid != getpid()) {
                [orfaos addObject:@(pid)];
            }
        }
    } @catch (NSException *excepcao) {
        NSLog(@"[Streaming] Não consegui procurar raop_play órfãos: %@", excepcao.reason);
        return 0;
    }

    if (orfaos.count == 0) return 0;

    NSLog(@"[Streaming] %lu raop_play de sessões anteriores ainda vivo(s); a terminá-lo(s) "
           "antes de abrir sessão nova.", (unsigned long)orfaos.count);

    for (NSNumber *pid in orfaos) kill(pid.intValue, SIGTERM);

    // Meio segundo para saírem em condições: o raop_play fecha a sessão RTSP ao
    // sair, e é isso que liberta o aparelho do outro lado. Quem não sair leva
    // SIGKILL, que deixa a sessão pendurada mas pelo menos larga a rede.
    for (int i = 0; i < 10; i++) {
        BOOL algumVivo = NO;
        for (NSNumber *pid in orfaos) {
            if (kill(pid.intValue, 0) == 0) { algumVivo = YES; break; }
        }
        if (!algumVivo) break;
        [NSThread sleepForTimeInterval:0.05];
    }

    for (NSNumber *pid in orfaos) {
        if (kill(pid.intValue, 0) == 0) kill(pid.intValue, SIGKILL);
    }

    return orfaos.count;
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

    // 3. O sinal de saúde é o nosso próprio processo, e mais nada.
    //
    // Havia aqui duas verificações e ambas mentiam. A existência do ficheiro de
    // tranco não diz nada — agora existe sempre, é essa a ideia, e antes o
    // -startStreaming apagava-o no arranque, portanto uma verificação que
    // calhasse nesse instante mandava relançar uma transmissão que estava
    // precisamente a começar. E o `pgrep raop_play` encontrava qualquer
    // raop_play, incluindo um órfão de outra sessão: com a nossa transmissão
    // morta e um órfão vivo, isto dava «está tudo bem» e ninguém relançava
    // coisa nenhuma.
    if (self.raopTask && self.raopTask.isRunning) {
        #ifdef DEBUG
        NSLog(@"[checkRaopPlayHealth] O raop_play desta transmissão está vivo.");
        #endif
        return;
    }

    NSLog(@"[checkRaopPlayHealth] O raop_play desta transmissão já não está vivo; "
           "a relançar para «%@».", selectedDevice);
    [self restartStreamingAfterFailure];
}

- (void)restartStreamingAfterFailure {
    #ifdef DEBUG
    NSLog(@"[Streaming] A repor o estado interno antes de relançar o streaming.");
    #endif

    // Sem este reset, arrancarTransmissao vê isStreaming == YES e
    // aborta com "Already streaming" — era por isto que o auto-restart
    // nunca funcionava e era preciso re-seleccionar o alvo à mão.
    self.isStreaming = NO;

    // Fecha o fd do FIFO antigo para não vazar quando o restart criar outro.
    // O leitor primeiro, pela mesma razão do -stopStreaming: com a fonte de
    // leitura viva, o descritor é dela.
    [self stopRaopClockReader];

    int fd = self.raopClockFD;
    self.raopClockFD = -1;
    if (fd >= 0) {
        while (close(fd) == -1 && errno == EINTR) { /* retry */ }
    }

    self.inputPipe = nil;
    self.raopTask = nil;

    // Pequena pausa para não entrar em ciclo apertado se o alvo estiver
    // mesmo inacessível (cada tentativa também passa pelo wake-up)
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf startStreaming];
    });
}

// Relata, uma vez por minuto e só se houver o que relatar, quanto áudio se
// perdeu e onde. Fora do #ifdef DEBUG: é isto que permite diagnosticar
// estalidos numa compilação de lançamento.
- (void)relatarAudioPerdido {
    uint64_t blocos = atomic_exchange(&_blocosDescartadosTapCheio, 0);
    uint64_t bytes  = atomic_exchange(&_bytesDescartadosTapCheio, 0);
    uint64_t cortes = atomic_exchange(&_cortesDeDeriva, 0);
    uint64_t bytesCorte = atomic_exchange(&_bytesCortadosDeriva, 0);

    const double bytesPorSegundo = 44100.0 * 4.0;

    if (blocos > 0) {
        NSLog(@"[Streaming] No último minuto o tampão circular esteve cheio %llu vezes; "
               "perderam-se %.3f s de áudio no produtor.", blocos, bytes / bytesPorSegundo);
    }
    if (cortes > 0) {
        NSLog(@"[Streaming] No último minuto houve %llu corte(s) de deriva, num total de %.2f s descartados.",
              cortes, bytesCorte / bytesPorSegundo);
    }
}

- (void)setupHealthCheckTimer {
    // Cancela um timer anterior para não acumular timers em cada restart
    if (self.healthCheckTimer) {
        dispatch_source_cancel(self.healthCheckTimer);
        self.healthCheckTimer = nil;
    }

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
                [strongSelf relatarAudioPerdido];
                [strongSelf relatarRelogio];
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

    // Check if a device is selected
    NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
    if (!selectedDevice) {
        #ifdef DEBUG
        NSLog(@"[Streaming] No AirPlay device selected. Aborting streaming.");
        #endif
        self.isStreaming = NO;
        return;
    }

    // O acordar corre ao lado do arranque, e não à frente dele.
    //
    // Antes a transmissão ficava à espera: o ajudante em Python tem oito
    // segundos de tolerância, e o pedido HTTP que se lhe seguia esperava sem
    // limite nenhum, portanto entre carregar na caixa e o raop_play sequer
    // arrancar podia ir mais de um minuto. Pior: o ajudante está feito para um
    // Apple TV em concreto, com o identificador escrito no próprio script, de
    // modo que para qualquer outro aparelho esse tempo todo era gasto só para
    // falhar. E é dispensável na maioria dos casos — o raop_play acorda o
    // aparelho sozinho quando abre a sessão RTSP.
    __weak typeof(self) fraco = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(fraco) forte = fraco;
        if (!forte || forte.cancelPendingStart) return;
        [forte sendWakeUpCallToDeviceWithIP:forte.ipAddress];
    });

    [self arrancarTransmissao];
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
    int fd = open(p, O_RDONLY | O_NONBLOCK);
    if (fd < 0 && errno != ENXIO) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                code:errno
                                            userInfo:@{NSFilePathErrorKey: path ?: @""}];
        return NO;
    }
    if (fdOut) *fdOut = fd;
    return YES;
}

#pragma mark - Relógio do raop_play

// O raop_play lançado com `-f CAMINHO` escreve no FIFO uma linha por segundo,
// do seu controlador de sincronismo, com dois números decimais separados por um
// espaço:
//
//     <blocos enviados> <head_ts>\n
//
// O primeiro é o contador de blocos que ele já pôs na rede, a começar em zero
// com o fluxo; o segundo é a marca temporal RTP do próximo bloco a enviar, cuja
// origem é o relógio NTP no arranque e portanto não nos diz nada em absoluto.
// Cada bloco são 352 tramas — é o máximo que o protocolo permite e o raop_play
// usa sempre esse valor. Daí o que interessa:
//
//     tramas já enviadas = blocos * 352
//
// Do nosso lado sabemos quantas tramas o tap capturou (`_bytesCapturados`, a
// 4 bytes por trama) e quantas a correcção de deriva deitou fora depois de
// capturadas (`_bytesCortadosTotal`) — essas foram capturadas mas nunca chegam a
// ser enviadas, portanto saem da conta. A diferença para as que o raop_play já
// pôs na rede é tudo o que está em trânsito, e cobre a cadeia inteira: o tampão
// circular cá dentro, o tubo do sistema, e o que o raop_play tem na mão.
// Somando a latência que lhe pedimos (`-l`, que é quanto o aparelho segura antes
// de tocar) fica o atraso total entre o que o tap está a capturar neste instante
// e o que se ouve do outro lado:
//
//     Δ = (capturadas - cortadas - enviadas + latência) / 44100
//
// Contar a partir do que foi entregue ao tubo, e não do que foi capturado,
// deixava de fora o tampão circular — que em regime é quase nada, mas que a
// deriva entre relógios pode encher até seis segundos, e é exactamente aí que
// saber o atraso interessa.
//
// É este Δ que permitirá atrasar a reprodução local até ela coincidir com a
// remota. Sem ele só havia a latência nominal, que ignora tudo o que está em
// trânsito.
//
// Nota sobre o contador de blocos. Esteve aqui escrita ao contrário; isto foi
// verificado na fonte do rust-raop-player em 2026-09-05.
//
// O `frame_counter` conta blocos de áudio **novo**. Quando o raop_play retoma
// depois de uma pausa e reenche o aparelho com pedaços do backlog
// (`raop_client.rs:353-378`), não o incrementa — e faz bem, que esse áudio não é
// novo. Logo `blocos * 352` é mesmo o número de tramas únicas que foram para a
// rede, que é exactamente o que aqui se quer comparar com as capturadas. O
// contador está certo e é esta a fonte a usar.
//
// Tentador seria usar antes o head_ts, que avança em tudo, inclusive nos
// reenvios. Não serve: o head_ts é re-baseado a partir do relógio NTP a cada
// arranque de fluxo — nos dois ramos do `flush()` (`raop_client.rs:324-338`),
// `head_ts = now_ts` sem pausa e `head_ts = now_ts - latência - chunk` com
// pausa. Uma diferença de head_ts que atravesse uma retoma mede **tempo de
// parede**, não tramas. Trocar uma coisa pela outra faz o `emTransito` saltar
// para zero e o Δ colapsar na latência nominal, de vez.
//
// O que fica mesmo por cobrir é outra coisa: o «+ latência» assume que o
// receptor segura exactamente as tramas que lhe pedimos no `-l`. Um aparelho que
// segure menos faz o Δ sair grande de mais — e um Δ inflado atrasa o histograma
// a mais, que se ouve como o som chegar antes das barras. É um desvio fixo por
// aparelho, e distingue-se de um problema de contagem pelo feitio no registo:
// este é plano, um erro de contagem varia com o que se passou no fluxo.

static const uint64_t kRaopFramesPerChunk = 352;   // MAX_SAMPLES_PER_CHUNK
static const double   kRaopSampleRate     = 44100.0;
static const double   kRaopClockSilencioMaximo = 5.0;  // segundos sem linha = parado

- (void)startRaopClockReader {
    [self stopRaopClockReader];

    if (self.raopClockFD < 0) {
        NSLog(@"[RAOP relógio] Sem descritor do FIFO; o relógio não vai ser lido.");
        return;
    }

    // Um escritor nosso, aberto e deixado quieto. Sem ele, sempre que o
    // raop_play não tivesse o FIFO aberto — antes de arrancar, ou depois de
    // morrer — o tubo ficava em fim-de-ficheiro, e uma fonte de leitura sobre um
    // fim-de-ficheiro acorda em ciclo fechado a ler zero bytes: um núcleo a
    // 100 % sem nada para ler. Com um escritor sempre presente o FIFO nunca
    // chega ao fim, e a fonte só acorda quando há mesmo linha.
    int escritor = open(kRaopClockPath.fileSystemRepresentation, O_WRONLY | O_NONBLOCK);
    if (escritor < 0) {
        NSLog(@"[RAOP relógio] Não consegui abrir o lado escritor do FIFO (%s); "
               "o leitor arranca à mesma, mas gasta CPU se o raop_play fechar.", strerror(errno));
    }
    self.raopClockWriterFD = escritor;

    self.raopClockPartial   = [NSMutableData data];
    self.raopClockStartedAt = [NSDate timeIntervalSinceReferenceDate];
    atomic_store(&_relogioLinhas, 0);
    atomic_store(&_relogioInstante, 0.0);
    atomic_store(&_relogioAtraso, 0.0);

    int fd = self.raopClockFD;
    dispatch_queue_t fila = dispatch_queue_create("JPSdA.tocaTintas.raopclock", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t fonte = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, fila);
    if (!fonte) {
        NSLog(@"[RAOP relógio] Não consegui criar a fonte de leitura.");
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(fonte, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf drenarRelogio:fd];
        }
    });

    // O descritor passa a ser desta fonte, e é fechado aqui e só aqui: fechá-lo
    // com a fonte ainda viva é dos poucos erros que o GCD castiga com um estoiro.
    dispatch_source_set_cancel_handler(fonte, ^{
        while (close(fd) == -1 && errno == EINTR) { /* repetir */ }
    });

    self.raopClockSource = fonte;
    dispatch_resume(fonte);

    // O raop_play escreve de segundo a segundo; se ao fim de cinco não veio
    // nada, não é lentidão, é ausência. Vale a pena dizê-lo alto: o `-f` está a
    // ser passado (ver -arrancarTransmissao), portanto o que falta é do
    // outro lado — um raop_play compilado sem o subcomando, ou com ele desligado.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isStreaming) return;
        if (atomic_load(&strongSelf->_relogioLinhas) == 0) {
            NSLog(@"[RAOP relógio] Cinco segundos de transmissão e nem uma linha em %@. "
                   "O raop_play foi lançado com -f, portanto ou a compilação instalada não "
                   "tem o subcomando dos tempos, ou ele está desligado. Sem isto não há "
                   "medição do atraso remoto: fica só a latência nominal de %ld tramas.",
                  kRaopClockPath, (long)strongSelf.latency);
        }
    });

    #ifdef DEBUG
    NSLog(@"[RAOP relógio] Leitor do FIFO iniciado (fd=%d, escritor=%d).", fd, escritor);
    #endif
}

- (void)stopRaopClockReader {
    dispatch_source_t fonte = self.raopClockSource;
    if (fonte) {
        self.raopClockSource = nil;
        // A partir daqui o descritor é do manipulador de cancelamento; quem vier
        // a seguir não o pode fechar outra vez.
        self.raopClockFD = -1;
        dispatch_source_cancel(fonte);
    }

    int escritor = self.raopClockWriterFD;
    self.raopClockWriterFD = -1;
    if (escritor >= 0) {
        while (close(escritor) == -1 && errno == EINTR) { /* repetir */ }
    }

    self.raopClockPartial = nil;
}

// Corre na fila do relógio. Esvazia o que houver no FIFO e parte-o em linhas.
- (void)drenarRelogio:(int)fd {
    char bloco[512];

    for (;;) {
        ssize_t lidos = read(fd, bloco, sizeof(bloco));

        if (lidos > 0) {
            [self.raopClockPartial appendBytes:bloco length:(NSUInteger)lidos];
            [self consumirLinhasDoRelogio];
            continue;
        }
        if (lidos == 0) {
            return;  // sem escritor do outro lado; o nosso keep-alive evita isto
        }
        if (errno == EINTR) {
            continue;
        }
        return;      // EAGAIN/EWOULDBLOCK: acabou por agora
    }
}

- (void)consumirLinhasDoRelogio {
    NSMutableData *acumulado = self.raopClockPartial;
    if (!acumulado) return;

    const char *bytes = (const char *)acumulado.bytes;
    NSUInteger total = acumulado.length;
    NSUInteger inicio = 0;

    for (NSUInteger i = 0; i < total; i++) {
        if (bytes[i] != '\n') continue;

        NSUInteger comprimento = i - inicio;
        if (comprimento > 0 && comprimento < 128) {
            char linha[128];
            memcpy(linha, bytes + inicio, comprimento);
            linha[comprimento] = '\0';
            [self processarLinhaDoRelogio:linha];
        }
        inicio = i + 1;
    }

    if (inicio > 0) {
        [acumulado replaceBytesInRange:NSMakeRange(0, inicio) withBytes:NULL length:0];
    }

    // Se alguém encher isto sem nunca mandar uma mudança de linha, mais vale
    // perder o que lá está do que crescer sem fim.
    if (acumulado.length > 4096) {
        acumulado.length = 0;
    }
}

- (void)processarLinhaDoRelogio:(const char *)linha {
    unsigned long long blocos = 0, headTs = 0;
    if (sscanf(linha, "%llu %llu", &blocos, &headTs) != 2) {
        #ifdef DEBUG
        NSLog(@"[RAOP relógio] Linha que não percebi: «%s»", linha);
        #endif
        return;
    }

    // Tudo em tramas; o áudio é int16 estéreo, 4 bytes por trama.
    const uint64_t capturadas = atomic_load(&_bytesCapturados) / 4;
    const uint64_t cortadas   = atomic_load(&_bytesCortadosTotal) / 4;
    const uint64_t enviadas   = (uint64_t)blocos * kRaopFramesPerChunk;
    const uint64_t uteis      = (capturadas > cortadas) ? (capturadas - cortadas) : 0;

    // Em trânsito: o que já foi capturado e ainda não foi para a rede. Negativo
    // não faz sentido — seria ele ter enviado mais do que lhe demos —, e aparece
    // nos primeiros instantes e depois de uma retoma com reenvios.
    double emTransito = (uteis > enviadas) ? (double)(uteis - enviadas) : 0.0;
    double atraso = (emTransito + (double)self.latency) / kRaopSampleRate;

    atomic_store(&_relogioBlocos, blocos);
    atomic_store(&_relogioHeadTs, headTs);
    atomic_store(&_relogioAtraso, atraso);
    atomic_store(&_relogioInstante, [NSDate timeIntervalSinceReferenceDate]);

    uint64_t linhas = atomic_fetch_add(&_relogioLinhas, 1) + 1;
    if (linhas == 1) {
        NSLog(@"[RAOP relógio] Tempos a chegar de %@: primeira linha «%s». "
               "Atraso remoto estimado: %.3f s.", kRaopClockPath, linha, atraso);
    }
    #ifdef DEBUG
    else if (linhas % 30 == 0) {
        // Onde é que o áudio em trânsito está parado: deste lado do tubo ou já
        // lá dentro. Distingue «o tampão encheu» de «a rede está lenta».
        const uint64_t entregues = atomic_load(&_bytesEntreguesAoRaop) / 4;
        double caDentro = (uteis > entregues) ? (double)(uteis - entregues) : 0.0;
        if (caDentro > emTransito) caDentro = emTransito;
        double noTubo = emTransito - caDentro;

        NSLog(@"[RAOP relógio] %llu linhas. Blocos: %llu (%.1f s enviados). "
               "Em trânsito: %.3f s (%.3f no tampão, %.3f no tubo). "
               "Latência pedida: %.3f s. Atraso remoto: %.3f s.",
              linhas, blocos, enviadas / kRaopSampleRate,
              emTransito / kRaopSampleRate, caDentro / kRaopSampleRate,
              noTubo / kRaopSampleRate, self.latency / kRaopSampleRate, atraso);
    }
    #endif
}

// Relatório periódico, pendurado no temporizador de saúde que já existia.
- (void)relatarRelogio {
    if (!self.isStreaming) return;

    uint64_t linhas = atomic_load(&_relogioLinhas);
    if (linhas == 0) {
        NSLog(@"[RAOP relógio] Sem tempos do raop_play desde que a transmissão começou "
               "(há %.0f s). Atraso remoto por medir.",
              [NSDate timeIntervalSinceReferenceDate] - self.raopClockStartedAt);
        return;
    }

    double silencio = [NSDate timeIntervalSinceReferenceDate] - atomic_load(&_relogioInstante);
    if (silencio > kRaopClockSilencioMaximo) {
        NSLog(@"[RAOP relógio] Os tempos pararam há %.0f s (recebidas %llu linhas). "
               "O raop_play ainda está vivo?", silencio, linhas);
        return;
    }

    #ifdef DEBUG
    NSLog(@"[RAOP relógio] Vivo: %llu linhas, última há %.1f s, atraso remoto %.3f s.",
          linhas, silencio, atomic_load(&_relogioAtraso));
    #endif
}

#pragma mark - Estado do relógio, para fora

- (BOOL)raopClockIsRunning {
    double ultima = atomic_load(&_relogioInstante);
    if (ultima <= 0.0) return NO;
    return ([NSDate timeIntervalSinceReferenceDate] - ultima) < kRaopClockSilencioMaximo;
}

- (NSTimeInterval)remoteAudioLag {
    // Sem relógio a bater não se devolve o último valor conhecido: um atraso
    // velho é pior do que nenhum, porque quem o usar para alinhar o som local
    // alinha-o com uma coisa que já não é verdade.
    return self.raopClockIsRunning ? atomic_load(&_relogioAtraso) : 0.0;
}


// Remaining setup performed after the wake-up call completes
- (void)arrancarTransmissao {

    // Abort if the pending start was cancelled or device was deselected
    NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
    if (self.cancelPendingStart || !selectedDevice) {
        #ifdef DEBUG
        NSLog(@"[Streaming] Arranque cancelado antes de começar.");
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

    // Stop any existing streaming before starting new streaming
    if (self.raopTask || self.inputPipe) {
        // O -stopStreaming levanta a bandeira de cancelamento, que é o que faz
        // uma paragem pedida de fora abortar um arranque a meio. Só que esta
        // paragem fomos nós que a pedimos, para limpar o que sobrou do fluxo
        // anterior — se a bandeira ficasse levantada, este arranque
        // cancelava-se a si próprio mais à frente.
        [self stopStreaming];
        self.cancelPendingStart = NO;
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

    // Apagar FIFO antigo para começar de raiz
    unlink(kRaopClockPath.fileSystemRepresentation);

    // Criar o FIFO novo e abrir o lado leitor
    NSError *fifoErr = nil;
    if (![self ensureRaopClockAtPath:kRaopClockPath keepAliveFD:&_raopClockFD error:&fifoErr]) {
        NSLog(@"[RAOP] Falha a garantir FIFO %@: %@", kRaopClockPath, fifoErr);
        self.isStreaming = NO;
        return;
    }

    // Configure the RAOP task.
    //
    // Atenção ao «-a»: não é o endereço, é «Send ALAC compressed audio», uma
    // opção sem argumento (ver USAGE em src/main.rs do rust-raop-player-mod). O
    // endereço é posicional, e só calha ficar certo porque vem logo a seguir —
    // o docopt lê «-a» como bandeira e «self.ipAddress» como <server-ip>. O «-»
    // final é o <filename>, e quer dizer «lê da entrada padrão», que é o tubo.
    // Escrito por extenso para ninguém «corrigir» isto para «-a» com argumento.
    //
    // O «-f» é o que faz o raop_play escrever os tempos no FIFO. Sem ele não há
    // relógio nenhum para ler — ver «Relógio do raop_play».
    self.raopTask.launchPath = raopPlayPath;
    self.raopTask.arguments = @[
        @"-a", self.ipAddress,
        @"-p", self.port,
        @"-l", [NSString stringWithFormat:@"%ld", (long)self.latency],
        @"-f", kRaopClockPath,
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

        // O raop_play morreu, portanto o tranco que o guardava deixa de fazer
        // sentido. Largar é fechar o descritor, nunca apagar o ficheiro.
        [strongSelf largarTrancoDoRaopPlay];

        NSString *selectedDevice = [[NSUserDefaults standardUserDefaults] objectForKey:@"SelectedAirPlayDevice"];
        if (selectedDevice) {
            #ifdef DEBUG
            NSLog(@"[Streaming] RAOP task terminated, but device (%@) is still selected. Restarting streaming.", selectedDevice);
            #endif
            [strongSelf restartStreamingAfterFailure];
        } else {
            #ifdef DEBUG
            NSLog(@"[Streaming] No AirPlay device selected. Stopping streaming completely.");
            #endif
            strongSelf.isStreaming = NO;
            strongSelf.inputPipe = nil;
            strongSelf.raopTask = nil;
        }
    };

    // Órfãos de sessões anteriores: enquanto um deles estiver vivo, o aparelho
    // não aceita a sessão nova e o relançamento anda em círculos. Isto e o
    // tranco ficam aqui, coladinhos ao -launch, para não haver caminho de erro
    // entre tomar o tranco e usá-lo — cada selecção cria um streamer novo, e um
    // tranco esquecido por um deles calava o seguinte.
    [self matarRaopPlayOrfaos];

    if (![self adquirirTrancoDoRaopPlay]) {
        // Outra transmissão desta app ainda não o largou. Não se desiste —
        // desistir em silêncio era o que obrigava a desmarcar e voltar a marcar
        // o aparelho à mão —, tenta-se outra vez daqui a um segundo.
        self.isStreaming = NO;
        self.inputPipe = nil;
        self.raopTask = nil;
        __weak typeof(self) fraco = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            __strong typeof(fraco) forte = fraco;
            if (forte && !forte.cancelPendingStart) [forte arrancarTransmissao];
        });
        return;
    }

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
        [self largarTrancoDoRaopPlay];
        return;
    }

    // Update streaming state
    self.isStreaming = YES;

    // Fluxo novo, contas do zero: o contador de blocos do raop_play recomeça com
    // ele, e o nosso das tramas entregues tem de recomeçar ao mesmo tempo, senão
    // a diferença entre os dois — que é o áudio em trânsito — vem do fluxo
    // anterior.
    atomic_store(&_bytesCapturados, 0);
    atomic_store(&_bytesCortadosTotal, 0);
    atomic_store(&_bytesEntreguesAoRaop, 0);
    [self startRaopClockReader];

    // Iniciar thread consumidor do tampão circular
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // int16 estéreo a 44,1 kHz
        const uint32_t bytesPerSecond = 44100 * 4;
        // Os relógios da captura e do receptor AirPlay derivam um do outro.
        // Sem limite, o tampão enche durante minutos/horas até transbordar e
        // descartar um bloco inteiro (soluço audível) — e a latência cresce
        // até 10 s. Acima da marca de água alta fazemos um corte controlado
        // para o nível alvo: um único salto, registado, em vez de descartes
        // aleatórios no produtor.
        const uint32_t highWatermark = bytesPerSecond * 6; // 6 s
        const uint32_t targetLevel   = bytesPerSecond * 2; // 2 s

        NSTimeInterval lastLevelLog = [NSDate timeIntervalSinceReferenceDate];
        NSTimeInterval starvedSince = 0;

        while (self.isStreaming) {
            uint32_t availableBytes = 0;
            void *bufferPointer = TPCircularBufferTail(&self->_circularBuffer, &availableBytes);

            NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
            #ifdef DEBUG
            if (now - lastLevelLog >= 10.0) {
                NSLog(@"[Streaming] Nível do tampão circular: %u bytes (%.2f s).",
                      availableBytes, availableBytes / (double)bytesPerSecond);
                lastLevelLog = now;
            }
            #endif

            if (availableBytes > highWatermark) {
                uint32_t excess = availableBytes - targetLevel;
                TPCircularBufferConsume(&self->_circularBuffer, excess);
                atomic_fetch_add(&self->_cortesDeDeriva, 1);
                atomic_fetch_add(&self->_bytesCortadosDeriva, excess);
                // O de cima é zerado pelo relatório de minuto a minuto; este é
                // acumulado e serve a conta do atraso, que precisa de saber que
                // este áudio foi capturado mas nunca chegou a ser enviado.
                atomic_fetch_add(&self->_bytesCortadosTotal, excess);
                NSLog(@"[Streaming] Deriva: tampão acima de %.0f s — descartados %.2f s de áudio para repor a latência. "
                       "Isto ouve-se como um salto.",
                      highWatermark / (double)bytesPerSecond, excess / (double)bytesPerSecond);
                continue;
            }

            if (availableBytes > 0) {
                starvedSince = 0;
                NSData *data = [NSData dataWithBytes:bufferPointer length:availableBytes];
                @try {
                    [self->_inputPipe.fileHandleForWriting writeData:data];
                    // Só depois de a escrita passar: o que ficou por escrever não
                    // está em trânsito, está perdido.
                    atomic_fetch_add(&self->_bytesEntreguesAoRaop, availableBytes);
                } @catch (NSException *exception) {
                    #ifdef DEBUG
                    NSLog(@"[Streaming] Pipe fechado, a terminar consumidor: %@", exception.reason);
                    #endif
                    return;
                }
                TPCircularBufferConsume(&self->_circularBuffer, availableBytes);
            } else {
                // Tampão vazio: normal por instantes, mas prolongado indica
                // que o tap/engine deixou de produzir (captura morta)
                if (starvedSince == 0) {
                    starvedSince = now;
                } else if (now - starvedSince >= 5.0) {
                    NSLog(@"[Streaming] Tampão circular vazio há %.0f s — a captura parou de produzir dados?",
                          now - starvedSince);
                    starvedSince = now;
                }
                [NSThread sleepForTimeInterval:0.005];
            }
        }
    });

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
    // O leitor primeiro: enquanto a fonte de leitura viver, o descritor é dela e
    // fechá-lo por baixo dela é um estoiro. O -stopRaopClockReader devolve o
    // raopClockFD a -1 quando o entrega ao cancelamento, e o que se segue
    // encarrega-se do caso em que não chegou a haver leitor nenhum.
    [self stopRaopClockReader];

    int fd = self.raopClockFD;
    self.raopClockFD = -1;            // to avoid double-close in races

    if (fd >= 0) {
        while (close(fd) == -1 && errno == EINTR) { /* retry */ }
        #ifdef DEBUG
        NSLog(@"[Streaming] Closed the raop_play fifo (fd=%d).", fd);
        #endif
    }
    // 5) Always recreate the fifo for a fresh start
        unlink(kRaopClockPath.fileSystemRepresentation);

    // 6) Lockfile
    [self largarTrancoDoRaopPlay];

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
        #endif
    } else {
        #ifdef DEBUG
        NSLog(@"[Streaming] Audio capturing started.");
        #endif
    }
}

- (void)stopAudioCaptureIfNeeded {
    if (!self.isStreaming) {
        if (self.audioEngine.isRunning) {
            [self.audioEngine.inputNode removeTapOnBus:0];
            [self.audioEngine stop];
            #ifdef DEBUG
            NSLog(@"[Streaming] Audio engine stopped.");
            #endif

        }
    } else {
        #ifdef DEBUG
        NSLog(@"[Streaming] Audio engine continues running (streaming is active).");
        #endif
    }
}

#pragma mark - Original Audio Tap

- (void)installAudioTap {
    AVAudioInputNode *inputNode = self.audioEngine.inputNode;

    // A captura é do BlackHole, e não do dispositivo de entrada por omissão do
    // sistema: assim a entrada do Mac fica livre para o microfone sem que a
    // transmissão passe a mandar a sala para a aparelhagem. Antes de se ler o
    // formato, que é o do dispositivo.
    ZPBindEngineInputToLoopback(self.audioEngine);

    // Remover um tap anterior antes de instalar — instalar sobre um tap
    // existente lança excepção (relevante na reinstalação após reconfiguração)
    [inputNode removeTapOnBus:0];

    AVAudioFormat *inputFormat = [inputNode inputFormatForBus:0];

    if (!inputFormat || inputFormat.channelCount == 0 || inputFormat.sampleRate == 0) {
        #ifdef DEBUG
        NSLog(@"[Error] Invalid input format: sample rate %f, channels %d",
              inputFormat.sampleRate, inputFormat.channelCount);
        #endif
        return;
    }

    // Formato intermédio em float 32 bits para processamento de ganho sem perda
    AVAudioFormat *floatFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                                  sampleRate:44100.0
                                                                    channels:2
                                                                 interleaved:NO];

    // Formato final int16 para envio ao raop_play
    AVAudioFormat *targetFormat = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatInt16
                                                                   sampleRate:44100.0
                                                                     channels:2
                                                                  interleaved:YES];

    // Conversor e tampões criados uma vez e reutilizados em cada callback: no
    // thread de áudio não se aloca memória. A capacidade é quatro vezes o que
    // se pede ao tap — o código antigo dimensionava-os pelo tampão que chegava,
    // e um tampão maior do que estes não teria onde caber. Se ainda assim vier
    // um maior, o bloco é descartado com aviso em vez de sair calado.
    const AVAudioFrameCount capacidadeTap = 4096 * 4;
    self.toFloatConverter = [[AVAudioConverter alloc] initFromFormat:inputFormat toFormat:floatFormat];
    self.floatBuffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:floatFormat frameCapacity:capacidadeTap];
    self.int16Buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:targetFormat frameCapacity:capacidadeTap];

    __weak typeof(self) weakSelf = self;

    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:inputFormat
                         block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !buffer || buffer.frameLength == 0) return;

        AVAudioPCMBuffer *floatBuffer = strongSelf.floatBuffer;
        AVAudioPCMBuffer *convertedBuffer = strongSelf.int16Buffer;
        if (!floatBuffer || !convertedBuffer) return;

        if (buffer.frameLength > floatBuffer.frameCapacity) {
            #ifdef DEBUG
            NSLog(@"[Streaming] Tampão do tap com %u tramas, acima da capacidade de %u — bloco descartado.",
                  buffer.frameLength, floatBuffer.frameCapacity);
            #endif
            return;
        }

        // Passo 1: converter para float 32 bits
        NSError *error = nil;
        [strongSelf.toFloatConverter convertToBuffer:floatBuffer fromBuffer:buffer error:&error];
        if (error) {
            #ifdef DEBUG
            NSLog(@"[Streaming] Error converting to float: %@", error.localizedDescription);
            #endif
            return;
        }

        // Passos 2 e 3 num só varrimento: ganho, limitação e conversão para
        // int16 com a intercalação L/R sob controlo nosso.
        //
        // O ganho não salta: quando a faixa muda, o alvo é novo mas o ganho
        // percorre a distância ao longo deste bloco (uns 90 ms a 44,1 kHz).
        // Um degrau entre duas amostras — de ×0,5 para ×1,4, por exemplo —
        // ouve-se como um estalo. O alvo é lido uma vez por bloco, e de forma
        // atómica, porque quem o escreve é o thread principal.
        const AVAudioFrameCount frames = floatBuffer.frameLength;
        const float ganhoAlvo = atomic_load(&strongSelf->_ganhoAlvo)
                              * atomic_load(&strongSelf->_ganhoCompensacao);
        float ganho = strongSelf->_ganhoActual;
        const float passo = (frames > 0) ? (ganhoAlvo - ganho) / (float)frames : 0.0f;

        convertedBuffer.frameLength = frames;

        const float *leftChannel  = floatBuffer.floatChannelData[0];
        const float *rightChannel = floatBuffer.floatChannelData[1];
        int16_t *pcmData = convertedBuffer.int16ChannelData[0];

        for (AVAudioFrameCount i = 0; i < frames; i++, ganho += passo) {
            float esquerdo = fmaxf(-1.0f, fminf(1.0f, leftChannel[i]  * ganho));
            float direito  = fmaxf(-1.0f, fminf(1.0f, rightChannel[i] * ganho));
            // lrintf arredonda; o molde para int truncava em direcção a zero,
            // o que é meio bit de distorção de graça em cada amostra.
            pcmData[i * 2]     = (int16_t)lrintf(esquerdo * INT16_MAX);
            pcmData[i * 2 + 1] = (int16_t)lrintf(direito  * INT16_MAX);
        }

        strongSelf->_ganhoActual = ganhoAlvo;

        NSUInteger byteCount = frames * convertedBuffer.format.streamDescription->mBytesPerFrame;

        // Passo 4: escrever no tampão circular. Se estiver cheio, o bloco é
        // descartado — regista-se para correlacionar com soluços audíveis.
        if (!TPCircularBufferProduceBytes(&strongSelf->_circularBuffer, pcmData, (uint32_t)byteCount)) {
            atomic_fetch_add(&strongSelf->_blocosDescartadosTapCheio, 1);
            atomic_fetch_add(&strongSelf->_bytesDescartadosTapCheio, byteCount);
        } else {
            // Só o que entrou mesmo. É a ponta de cima da contabilidade do
            // atraso remoto — ver «Relógio do raop_play».
            atomic_fetch_add(&strongSelf->_bytesCapturados, (uint64_t)byteCount);
        }
    }];
}

#pragma mark - Compensação do volume do sistema

// Quanto é que o cursor de volume do macOS está a atenuar, em dB (<= 0).
//
// Isto existe porque a saída do sistema é o BlackHole, e o BlackHole — ao
// contrário dos dispositivos agregados que aqui estiveram antes — TEM controlo
// de volume. O cursor atenua antes do loopback, e por isso a atenuação vai
// parar tanto aos auscultadores (onde a queremos) como à transmissão para o
// AirPlay (onde não a queremos: quem manda no volume da aparelhagem é a
// aparelhagem). Compensando-a aqui, a transmissão sai sempre ao nível do
// ficheiro, seja qual for a posição do cursor.
//
// Repõe-se em vírgula flutuante e antes da conversão para int16, onde o sinal
// ainda tem toda a precisão que o CoreAudio lhe deu: não se recupera ruído de
// quantização nenhum, porque ainda não houve nenhum.
static float ZPSystemVolumeAttenuationDB(void) {
    AudioDeviceID dispositivo = ZPLoopbackAudioDevice();
    if (dispositivo == kAudioObjectUnknown) {
        return 0.0f;
    }

    // O «decibels» é o ganho que o dispositivo diz aplicar; o «scalar» é só a
    // posição do cursor, e a curva entre os dois não é logarítmica simples.
    // Prefere-se o primeiro, e o segundo fica de reserva.
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyVolumeDecibels,
        .mScope    = kAudioDevicePropertyScopeOutput,
        .mElement  = kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(dispositivo, &addr)) {
        addr.mElement = 1;
    }
    Float32 dB = 0.0f;
    UInt32 tamanho = sizeof(dB);
    if (AudioObjectHasProperty(dispositivo, &addr)
        && AudioObjectGetPropertyData(dispositivo, &addr, 0, NULL, &tamanho, &dB) == noErr) {
        return dB < 0.0f ? (float)dB : 0.0f;
    }

    addr.mSelector = kAudioDevicePropertyVolumeScalar;
    addr.mElement  = kAudioObjectPropertyElementMain;
    if (!AudioObjectHasProperty(dispositivo, &addr)) {
        addr.mElement = 1;
    }
    Float32 escalar = 1.0f;
    tamanho = sizeof(escalar);
    if (AudioObjectHasProperty(dispositivo, &addr)
        && AudioObjectGetPropertyData(dispositivo, &addr, 0, NULL, &tamanho, &escalar) == noErr
        && escalar > 0.0f && escalar < 1.0f) {
        return 20.0f * log10f(escalar);
    }

    return 0.0f;
}

- (void)refreshSystemVolumeCompensation {
    BOOL ligada = YES;
    NSNumber *guardado = [[NSUserDefaults standardUserDefaults] objectForKey:kAirPlayCompensateVolumeDefaultsKey];
    if (guardado) {
        ligada = guardado.boolValue;
    }

    float dB = ligada ? ZPSystemVolumeAttenuationDB() : 0.0f;
    float factor = powf(10.0f, -dB / 20.0f);   // dB é negativo: o factor sobe
    atomic_store(&_ganhoCompensacao, factor);

    #ifdef DEBUG
    NSLog(@"[ReplayGain] Compensação do volume do sistema: %@ (%.2f dB → ×%.3f).",
          ligada ? @"ligada" : @"desligada", dB, factor);
    #endif
}

// O cursor de volume mexe a qualquer momento; a compensação segue-o, e a rampa
// do tap encarrega-se de a mudança não se ouvir como um degrau.
- (void)observeSystemVolume {
    AudioDeviceID dispositivo = ZPLoopbackAudioDevice();
    if (dispositivo == kAudioObjectUnknown) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    AudioObjectPropertyAddress addr = {
        .mSelector = kAudioDevicePropertyVolumeScalar,
        .mScope    = kAudioDevicePropertyScopeOutput,
        .mElement  = kAudioObjectPropertyElementWildcard
    };
    AudioObjectAddPropertyListenerBlock(dispositivo, &addr, dispatch_get_main_queue(),
                                        ^(UInt32 n, const AudioObjectPropertyAddress *a) {
        [weakSelf refreshSystemVolumeCompensation];
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:kAirPlayCompensateVolumeChangedNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *nota) {
        [weakSelf refreshSystemVolumeCompensation];
    }];
}

#pragma mark - Gain Adjustment

// Sem pico: mantém-se o comportamento antigo (aplica o ganho todo e limita-se
// à bruta se transbordar).
- (void)updateReplayGainValue:(float)dB {
    [self updateReplayGainValue:dB trackPeak:0.0f];
}

// O pico é o `replaygain_track_peak` das etiquetas: a amplitude da amostra mais
// alta da faixa, em escala 0…1 (pode passar de 1 em material já ceifado).
//
// Sem ele, uma faixa baixinha leva um ganho positivo que atira os picos acima
// de 0 dBFS, e o limitador do tap corta-os a direito — distorção audível
// precisamente nas passagens mais fortes. Com ele, limita-se o ganho a 1/pico,
// que é o máximo que a faixa comporta sem ceifar. É a regra «prevent clipping»
// da norma ReplayGain.
- (void)updateReplayGainValue:(float)dB trackPeak:(float)peak {
    float factor = powf(10.0f, dB / 20.0f);

    if (peak > 0.0f) {
        float tecto = 1.0f / peak;
        if (factor > tecto) {
            #ifdef DEBUG
            NSLog(@"[ReplayGain] Ganho de %.2f dB (×%.3f) reduzido para ×%.3f: o pico da faixa é %.3f.",
                  dB, factor, tecto, peak);
            #endif
            factor = tecto;
        }
    }

    atomic_store(&_ganhoAlvo, factor);

    #ifdef DEBUG
    NSLog(@"[ReplayGain] Ganho alvo ×%.3f para %.2f dB (pico %@).",
          factor, dB, peak > 0.0f ? [NSString stringWithFormat:@"%.3f", peak] : @"desconhecido");
    #endif
}

@end

