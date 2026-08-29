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
//  PreferencesWindowController.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 12/09/2026.
//

#import "PreferencesWindowController.h"

NSString * const kBS2BProfileDefaultsKey        = @"bs2bProfile";
NSString * const kBS2BProfileChangedNotification = @"BS2BProfileChanged";

// Os nomes que o bs2b_bridge aceita em --perfil. A ordem é a do menu.
static NSString * const kPerfis[] = { @"default", @"cmoy", @"jmeier" };
static const NSUInteger kNumPerfis = sizeof(kPerfis) / sizeof(kPerfis[0]);

NSString * const kAirPlayNormalizationDefaultsKey        = @"airPlayNormalization";
NSString * const kAirPlayNormalizationChangedNotification = @"AirPlayNormalizationChanged";
NSString * const kAirPlayCompensateVolumeDefaultsKey        = @"airPlayCompensateSystemVolume";
NSString * const kAirPlayCompensateVolumeChangedNotification = @"AirPlayCompensateVolumeChanged";

// A ordem é a do menu. «trackfull» é o ganho de faixa aplicado por inteiro,
// sem o tecto do pico: pode ceifar, e é essa a diferença para «track».
static NSString * const kNormalizacoes[] = { @"none", @"trackfull", @"track", @"album" };
static const NSUInteger kNumNormalizacoes = sizeof(kNormalizacoes) / sizeof(kNormalizacoes[0]);

static NSString *ZPCurrentAirPlayNormalization(void) {
    NSString *guardado = [[NSUserDefaults standardUserDefaults] stringForKey:kAirPlayNormalizationDefaultsKey];
    for (NSUInteger i = 0; i < kNumNormalizacoes; ++i) {
        if ([kNormalizacoes[i] isEqualToString:guardado]) {
            return guardado;
        }
    }
    return @"track";   // o comportamento de sempre
}

void ZPResolveReplayGain(float trackGain, float trackPeak,
                         float albumGain, float albumPeak,
                         float *outGain, float *outPeak) {
    NSString *modo = ZPCurrentAirPlayNormalization();

    if ([modo isEqualToString:@"none"]) {
        // Nem ganho nem limitação: a faixa toca ao nível a que foi masterizada.
        if (outGain) *outGain = 0.0f;
        if (outPeak) *outPeak = 0.0f;
        return;
    }

    if ([modo isEqualToString:@"trackfull"]) {
        // Ganho de faixa integral. O pico vai a zero — «desconhecido» —, e o
        // streamer não limita nada: o que passar de 0 dBFS é ceifado pelo
        // limitador do tap. É o comportamento antigo, mantido de propósito para
        // se poder comparar com o outro.
        if (outGain) *outGain = trackGain;
        if (outPeak) *outPeak = 0.0f;
        return;
    }

    // Por álbum, com recurso à faixa quando o disco não traz as etiquetas de
    // álbum — que é o caso de muita coisa etiquetada à pressa.
    if ([modo isEqualToString:@"album"] && albumGain != 0.0f) {
        if (outGain) *outGain = albumGain;
        if (outPeak) *outPeak = (albumPeak > 0.0f) ? albumPeak : trackPeak;
        return;
    }

    if (outGain) *outGain = trackGain;
    if (outPeak) *outPeak = trackPeak;
}

NSString * const kBS2BEqDefaultsKey        = @"bs2bEq";
NSString * const kBS2BEqChangedNotification = @"BS2BEqChanged";

// Repõe as correcções do AutoEQ a partir do arquivo que vem no pacote, se a
// pasta estiver vazia. É o que faz com que apagar a pasta não perca nada: as
// tuas contagens de reprodução não voltam, mas os 522 modelos voltam.
//
// Se o arquivo não estiver no pacote (não foi acrescentado ao projecto do
// Xcode), isto não faz nada e a lista fica só com as duas entradas especiais —
// não rebenta, apenas não semeia.
static void ZPSemearEqSeVazia(NSURL *pasta) {
    NSArray<NSURL *> *conteudo =
        [[NSFileManager defaultManager] contentsOfDirectoryAtURL:pasta
                                      includingPropertiesForKeys:nil
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:NULL];
    if (conteudo.count > 0) {
        return;
    }

    NSString *arquivo = [[NSBundle mainBundle] pathForResource:@"eq_autoeq" ofType:@"tgz"];
    if (!arquivo) {
        return;
    }

    NSTask *tar = [[NSTask alloc] init];
    tar.launchPath = @"/usr/bin/tar";
    tar.arguments = @[@"-xzf", arquivo, @"-C", pasta.path];
    tar.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    tar.standardError  = [NSFileHandle fileHandleWithNullDevice];

    @try {
        [tar launch];
        // Esperar sem bombear o run loop, pela mesma razão que em
        // -stopBs2bIfRunning: o -waitUntilExit do NSTask corre o run loop.
        for (int i = 0; i < 100 && tar.isRunning; ++i) {
            usleep(20 * 1000);
        }
        NSLog(@"[eq] Correcções do AutoEQ repostas em %@.", pasta.path);
    } @catch (NSException *e) {
        NSLog(@"[eq] Não consegui repor as correcções: %@", e.reason);
    }
}

NSURL *ZPHeadphoneEqFolder(void) {
    NSURL *suporte = [[[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                             inDomains:NSUserDomainMask] firstObject];
    NSURL *pasta = [[suporte URLByAppendingPathComponent:@"tocaTintas" isDirectory:YES]
                    URLByAppendingPathComponent:@"eq" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:pasta
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    ZPSemearEqSeVazia(pasta);
    return pasta;
}

NSString *ZPCurrentBS2BEq(void) {
    NSString *guardado = [[NSUserDefaults standardUserDefaults] stringForKey:kBS2BEqDefaultsKey];
    if (!guardado) {
        return @"builtin";           // como sempre foi, para quem nunca escolheu
    }
    if (guardado.length == 0 || [guardado isEqualToString:@"builtin"]) {
        return guardado;
    }
    // Um caminho que desapareceu não pode ficar a valer: a ponte recusaria
    // arrancar e ficavas sem som sem perceber porquê.
    if (![[NSFileManager defaultManager] fileExistsAtPath:guardado]) {
        return @"builtin";
    }
    return guardado;
}

NSString *ZPCurrentBS2BProfile(void) {
    NSString *guardado = [[NSUserDefaults standardUserDefaults] stringForKey:kBS2BProfileDefaultsKey];
    for (NSUInteger i = 0; i < kNumPerfis; ++i) {
        if ([kPerfis[i] isEqualToString:guardado]) {
            return guardado;
        }
    }
    return @"cmoy";   // o de sempre, para quem nunca abriu as preferências
}

@interface PreferencesWindowController ()
@property (strong, nonatomic) NSPopUpButton *dspPopUp;
@property (strong, nonatomic) NSPopUpButton *normPopUp;
@property (strong, nonatomic) NSButton *compensarVolume;
@property (strong, nonatomic) NSPopUpButton *eqMarcaPopUp;
@property (strong, nonatomic) NSPopUpButton *eqModeloPopUp;
@end

@implementation PreferencesWindowController

- (void)windowDidLoad {
    [super windowDidLoad];

    NSWindow *janela = self.window;

    // A vista que vem do storyboard — com o botão de escolher e o texto
    // explicativo — passa a ser o conteúdo do primeiro separador, tal como
    // está. Assim não é preciso mexer no storyboard nem nas suas traduções.
    NSView *vistaMusica = janela.contentView;

    // A etiqueta do caminho continua a ser criada aqui, como antes, mas entra
    // no separador e não na janela.
    self.testLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(26, 127, 437, 16)];
    [self.testLabel setBezeled:NO];
    [self.testLabel setDrawsBackground:NO];
    [self.testLabel setEditable:NO];
    [self.testLabel setSelectable:YES];
    [vistaMusica addSubview:self.testLabel];

    // O botão de escolher a pasta vive na vista do storyboard, com a etiqueta
    // 100. Ligar-lhe o alvo antes de a vista mudar de sítio.
    self.saveButton = [vistaMusica viewWithTag:100];
    [self.saveButton setTarget:self];
    [self.saveButton setAction:@selector(chooseDirectory:)];

    // A barra de separadores rouba altura ao conteúdo; a janela cresce o mesmo
    // para o primeiro separador não ficar mais apertado do que estava.
    // Alta que chegue para o texto mais comprido das três traduções. As
    // etiquetas medem-se a si próprias (ver -etiquetaEm:…), portanto o que
    // sobra é margem, não texto cortado.
    [janela setContentSize:NSMakeSize(480, 430)];
    janela.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 430)];

    NSTabView *separadores = [[NSTabView alloc] initWithFrame:janela.contentView.bounds];
    separadores.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    NSTabViewItem *itemMusica = [[NSTabViewItem alloc] initWithIdentifier:@"musica"];
    itemMusica.label = NSLocalizedString(@"prefs_tab_music", @"Título do separador da pasta de música");
    itemMusica.view = vistaMusica;
    [separadores addTabViewItem:itemMusica];

    NSTabViewItem *itemDSP = [[NSTabViewItem alloc] initWithIdentifier:@"dsp"];
    itemDSP.label = NSLocalizedString(@"prefs_tab_dsp", @"Título do separador do tratamento de áudio");
    itemDSP.view = [self criarVistaDSP];
    [separadores addTabViewItem:itemDSP];

    NSTabViewItem *itemEq = [[NSTabViewItem alloc] initWithIdentifier:@"eq"];
    itemEq.label = NSLocalizedString(@"prefs_tab_eq", @"Título do separador dos auscultadores");
    itemEq.view = [self criarVistaEq];
    [separadores addTabViewItem:itemEq];

    NSTabViewItem *itemAirPlay = [[NSTabViewItem alloc] initWithIdentifier:@"airplay"];
    itemAirPlay.label = NSLocalizedString(@"prefs_tab_airplay", @"Título do separador do AirPlay");
    itemAirPlay.view = [self criarVistaAirPlay];
    [separadores addTabViewItem:itemAirPlay];

    [janela.contentView addSubview:separadores];

    [self reloadDirectoryPath];
}

// Separador do DSP, montado em código: assim as traduções ficam todas no
// Localizable.strings e não é preciso acrescentar objectos ao storyboard, que
// obrigaria a mexer nos Main.strings das três línguas.
// Etiqueta de texto para os separadores montados em código.
//
// A altura dada na moldura é ignorada: a etiqueta mede o texto à largura
// pedida e fica com a altura de que precisa, crescendo para baixo a partir do
// topo da moldura. Sem isto, uma tradução mais comprida do que a portuguesa
// era simplesmente cortada a meio da frase — e o russo é sempre mais comprido.
- (NSTextField *)etiquetaEm:(NSView *)vista moldura:(NSRect)r texto:(NSString *)texto pequena:(BOOL)pequena {
    NSTextField *t = [[NSTextField alloc] initWithFrame:r];
    t.stringValue = texto;
    t.bezeled = NO;
    t.drawsBackground = NO;
    t.editable = NO;
    t.selectable = NO;
    t.cell.wraps = YES;
    if (pequena) {
        t.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        t.textColor = [NSColor secondaryLabelColor];
    }

    NSSize cabe = [t.cell cellSizeForBounds:NSMakeRect(0, 0, NSWidth(r), CGFLOAT_MAX)];
    NSRect ajustada = r;
    ajustada.size.height = ceil(cabe.height);
    ajustada.origin.y    = NSMaxY(r) - ajustada.size.height;   // topo fixo
    t.frame = ajustada;

    [vista addSubview:t];
    return t;
}

- (NSView *)criarVistaDSP {
    const CGFloat A = 390, margem = 20, largura = 440;
    NSView *vista = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, A)];
    CGFloat topo = A - margem;   // vai descendo à medida que se coloca

    NSTextField *t = [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 200, largura, 200)
                                texto:NSLocalizedString(@"prefs_dsp_explanation", @"Explicação do que o crossfeed faz")
                              pequena:NO];
    topo = NSMinY(t.frame) - 18;

    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 17, 220, 17)
               texto:NSLocalizedString(@"prefs_dsp_profile_label", @"Etiqueta do menu de perfis")
             pequena:NO];
    topo -= 17 + 6;

    self.dspPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(margem, topo - 26, 330, 26) pullsDown:NO];
    NSArray<NSString *> *chaves = @[@"prefs_dsp_profile_default", @"prefs_dsp_profile_cmoy", @"prefs_dsp_profile_jmeier"];
    for (NSUInteger i = 0; i < kNumPerfis; ++i) {
        [self.dspPopUp addItemWithTitle:NSLocalizedString(chaves[i], @"Nome de um perfil de crossfeed")];
        self.dspPopUp.lastItem.representedObject = kPerfis[i];
    }
    self.dspPopUp.target = self;
    self.dspPopUp.action = @selector(dspProfileChanged:);
    [vista addSubview:self.dspPopUp];
    topo -= 26 + 20;

    NSString *actual = ZPCurrentBS2BProfile();
    for (NSMenuItem *item in self.dspPopUp.itemArray) {
        if ([item.representedObject isEqualToString:actual]) {
            [self.dspPopUp selectItem:item];
            break;
        }
    }

    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 220, largura, 220)
               texto:NSLocalizedString(@"prefs_dsp_note", @"Nota sobre o botão dos auscultadores")
             pequena:YES];

    return vista;
}

- (NSView *)criarVistaEq {
    const CGFloat A = 390, margem = 20, largura = 440;
    NSView *vista = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, A)];
    CGFloat topo = A - margem;

    NSTextField *t = [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 200, largura, 200)
                                texto:NSLocalizedString(@"prefs_eq_explanation", @"O que a equalização faz")
                              pequena:NO];
    topo = NSMinY(t.frame) - 18;

    // Dois menus em vez de um: 522 modelos numa lista só não se navega. O
    // primeiro escolhe a marca (ou as duas entradas especiais), o segundo o
    // modelo dessa marca.
    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 17, 200, 17)
               texto:NSLocalizedString(@"prefs_eq_brand", @"Etiqueta do menu de marcas")
             pequena:NO];
    topo -= 17 + 6;

    self.eqMarcaPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(margem, topo - 26, largura, 26) pullsDown:NO];
    self.eqMarcaPopUp.target = self;
    self.eqMarcaPopUp.action = @selector(eqMarcaChanged:);
    [vista addSubview:self.eqMarcaPopUp];
    topo -= 26 + 14;

    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 17, 200, 17)
               texto:NSLocalizedString(@"prefs_eq_model", @"Etiqueta do menu de modelos")
             pequena:NO];
    topo -= 17 + 6;

    self.eqModeloPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(margem, topo - 26, largura, 26) pullsDown:NO];
    self.eqModeloPopUp.target = self;
    self.eqModeloPopUp.action = @selector(eqModeloChanged:);
    [vista addSubview:self.eqModeloPopUp];
    topo -= 26 + 14;

    NSButton *abrir = [[NSButton alloc] initWithFrame:NSMakeRect(margem, topo - 24, 260, 24)];
    abrir.bezelStyle = NSBezelStyleRounded;
    abrir.title = NSLocalizedString(@"prefs_eq_open_folder", @"Botão para abrir a pasta das correcções");
    abrir.target = self;
    abrir.action = @selector(abrirPastaEq:);
    [vista addSubview:abrir];
    topo -= 24 + 16;

    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 240, largura, 240)
               texto:NSLocalizedString(@"prefs_eq_note", @"Nota sobre os ficheiros do AutoEQ")
             pequena:YES];

    [self recarregarListaEq];
    return vista;
}

// Marcas = subpastas de eq/. Ficheiros soltos na raiz aparecem juntos numa
// entrada à parte, para quem larga lá um ficheiro à mão não ter de os arrumar.
- (NSArray<NSString *> *)marcasDisponiveis {
    NSURL *pasta = ZPHeadphoneEqFolder();
    NSArray<NSURL *> *conteudo =
        [[NSFileManager defaultManager] contentsOfDirectoryAtURL:pasta
                                      includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:NULL];
    NSMutableArray<NSString *> *marcas = [NSMutableArray array];
    BOOL soltos = NO;
    for (NSURL *u in conteudo) {
        NSNumber *ehPasta = nil;
        [u getResourceValue:&ehPasta forKey:NSURLIsDirectoryKey error:NULL];
        if (ehPasta.boolValue) {
            [marcas addObject:u.lastPathComponent];
        } else if ([u.pathExtension caseInsensitiveCompare:@"txt"] == NSOrderedSame) {
            soltos = YES;
        }
    }
    [marcas sortUsingSelector:@selector(localizedStandardCompare:)];
    if (soltos) {
        [marcas insertObject:@"" atIndex:0];   // a pseudo-marca dos ficheiros soltos
    }
    return marcas;
}

- (NSArray<NSURL *> *)ficheirosDaMarca:(NSString *)marca {
    NSURL *pasta = ZPHeadphoneEqFolder();
    if (marca.length) {
        pasta = [pasta URLByAppendingPathComponent:marca isDirectory:YES];
    }
    NSArray<NSURL *> *conteudo =
        [[NSFileManager defaultManager] contentsOfDirectoryAtURL:pasta
                                      includingPropertiesForKeys:nil
                                                         options:NSDirectoryEnumerationSkipsHiddenFiles
                                                           error:NULL];
    NSMutableArray<NSURL *> *txt = [NSMutableArray array];
    for (NSURL *u in conteudo) {
        if ([u.pathExtension caseInsensitiveCompare:@"txt"] == NSOrderedSame) {
            [txt addObject:u];
        }
    }
    [txt sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent localizedStandardCompare:b.lastPathComponent];
    }];
    return txt;
}

- (void)recarregarListaEq {
    if (!self.eqMarcaPopUp) {
        return;
    }

    NSString *actual = ZPCurrentBS2BEq();
    NSString *marcaActual = nil;
    if (actual.length && ![actual isEqualToString:@"builtin"]) {
        NSURL *u = [NSURL fileURLWithPath:actual];
        NSString *pai = u.URLByDeletingLastPathComponent.lastPathComponent;
        marcaActual = [pai isEqualToString:@"eq"] ? @"" : pai;
    }

    [self.eqMarcaPopUp removeAllItems];
    [self.eqMarcaPopUp addItemWithTitle:NSLocalizedString(@"prefs_eq_none", @"Sem equalização")];
    self.eqMarcaPopUp.lastItem.representedObject = @"@nenhuma";
    [self.eqMarcaPopUp addItemWithTitle:NSLocalizedString(@"prefs_eq_builtin", @"A correcção embutida")];
    self.eqMarcaPopUp.lastItem.representedObject = @"@builtin";

    NSArray<NSString *> *marcas = [self marcasDisponiveis];
    if (marcas.count) {
        [self.eqMarcaPopUp.menu addItem:[NSMenuItem separatorItem]];
    }
    for (NSString *m in marcas) {
        [self.eqMarcaPopUp addItemWithTitle:m.length ? m : NSLocalizedString(@"prefs_eq_mine", @"Ficheiros soltos")];
        self.eqMarcaPopUp.lastItem.representedObject = m;
    }

    NSString *aSeleccionar = @"@builtin";
    if (actual.length == 0)            aSeleccionar = @"@nenhuma";
    else if (marcaActual != nil)       aSeleccionar = marcaActual;

    for (NSMenuItem *item in self.eqMarcaPopUp.itemArray) {
        if ([item.representedObject isEqualToString:aSeleccionar]) {
            [self.eqMarcaPopUp selectItem:item];
            break;
        }
    }
    [self recarregarModelosSeleccionando:actual];
}

- (void)recarregarModelosSeleccionando:(NSString *)caminho {
    NSString *marca = self.eqMarcaPopUp.selectedItem.representedObject;
    BOOL especial = [marca hasPrefix:@"@"];

    [self.eqModeloPopUp removeAllItems];
    self.eqModeloPopUp.enabled = !especial;
    if (especial) {
        [self.eqModeloPopUp addItemWithTitle:@"—"];
        return;
    }

    for (NSURL *u in [self ficheirosDaMarca:marca]) {
        [self.eqModeloPopUp addItemWithTitle:[u.lastPathComponent stringByDeletingPathExtension]];
        self.eqModeloPopUp.lastItem.representedObject = u.path;
    }
    for (NSMenuItem *item in self.eqModeloPopUp.itemArray) {
        if ([item.representedObject isEqualToString:caminho]) {
            [self.eqModeloPopUp selectItem:item];
            return;
        }
    }
    if (self.eqModeloPopUp.numberOfItems > 0) {
        [self.eqModeloPopUp selectItemAtIndex:0];
    }
}

- (void)windowDidBecomeKey:(NSNotification *)nota {
    [self recarregarListaEq];
}

- (void)eqMarcaChanged:(id)sender {
    NSString *marca = self.eqMarcaPopUp.selectedItem.representedObject;
    if ([marca isEqualToString:@"@nenhuma"]) {
        [self guardarEq:@""];
    } else if ([marca isEqualToString:@"@builtin"]) {
        [self guardarEq:@"builtin"];
    } else {
        [self recarregarModelosSeleccionando:nil];
        [self eqModeloChanged:nil];
        return;
    }
    [self recarregarModelosSeleccionando:nil];
}

- (void)eqModeloChanged:(id)sender {
    NSString *caminho = self.eqModeloPopUp.selectedItem.representedObject;
    if (caminho.length) {
        [self guardarEq:caminho];
    }
}

- (void)guardarEq:(NSString *)valor {
    [[NSUserDefaults standardUserDefaults] setObject:valor forKey:kBS2BEqDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:kBS2BEqChangedNotification object:nil];
}

- (void)abrirPastaEq:(id)sender {
    [[NSWorkspace sharedWorkspace] openURL:ZPHeadphoneEqFolder()];
}

- (NSView *)criarVistaAirPlay {
    const CGFloat A = 390, margem = 20, largura = 440;
    NSView *vista = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, A)];
    CGFloat topo = A - margem;

    NSTextField *t = [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 200, largura, 200)
                                texto:NSLocalizedString(@"prefs_norm_explanation", @"Explicação da normalização de volume")
                              pequena:NO];
    topo = NSMinY(t.frame) - 18;

    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 17, 300, 17)
               texto:NSLocalizedString(@"prefs_norm_label", @"Etiqueta do menu de normalização")
             pequena:NO];
    topo -= 17 + 6;

    self.normPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(margem, topo - 26, 380, 26) pullsDown:NO];
    NSArray<NSString *> *chaves = @[@"prefs_norm_none", @"prefs_norm_track_full",
                                    @"prefs_norm_track", @"prefs_norm_album"];
    for (NSUInteger i = 0; i < kNumNormalizacoes; ++i) {
        [self.normPopUp addItemWithTitle:NSLocalizedString(chaves[i], @"Modo de normalização de volume")];
        self.normPopUp.lastItem.representedObject = kNormalizacoes[i];
    }
    self.normPopUp.target = self;
    self.normPopUp.action = @selector(airPlayNormalizationChanged:);
    [vista addSubview:self.normPopUp];
    topo -= 26 + 16;

    NSString *actual = ZPCurrentAirPlayNormalization();
    for (NSMenuItem *item in self.normPopUp.itemArray) {
        if ([item.representedObject isEqualToString:actual]) {
            [self.normPopUp selectItem:item];
            break;
        }
    }

    self.compensarVolume = [[NSButton alloc] initWithFrame:NSMakeRect(margem, topo - 20, largura, 20)];
    [self.compensarVolume setButtonType:NSButtonTypeSwitch];
    self.compensarVolume.title = NSLocalizedString(@"prefs_norm_compensate", @"Compensar o volume do sistema");
    NSNumber *guardado = [[NSUserDefaults standardUserDefaults] objectForKey:kAirPlayCompensateVolumeDefaultsKey];
    self.compensarVolume.state = (!guardado || guardado.boolValue) ? NSControlStateValueOn : NSControlStateValueOff;
    self.compensarVolume.toolTip = NSLocalizedString(@"prefs_norm_note2", @"Porquê compensar o volume do sistema");
    self.compensarVolume.target = self;
    self.compensarVolume.action = @selector(compensateVolumeChanged:);
    [vista addSubview:self.compensarVolume];
    topo -= 20 + 14;

    [self etiquetaEm:vista moldura:NSMakeRect(margem, topo - 240, largura, 240)
               texto:NSLocalizedString(@"prefs_norm_note", @"Nota sobre a normalização")
             pequena:YES];

    return vista;
}

- (void)compensateVolumeChanged:(id)sender {
    [[NSUserDefaults standardUserDefaults] setBool:(self.compensarVolume.state == NSControlStateValueOn)
                                            forKey:kAirPlayCompensateVolumeDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAirPlayCompensateVolumeChangedNotification object:nil];
}

- (void)airPlayNormalizationChanged:(id)sender {
    NSString *modo = self.normPopUp.selectedItem.representedObject;
    if (!modo) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:modo forKey:kAirPlayNormalizationDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:kAirPlayNormalizationChangedNotification object:nil];
}

- (void)dspProfileChanged:(id)sender {
    NSString *perfil = self.dspPopUp.selectedItem.representedObject;
    if (!perfil) {
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:perfil forKey:kBS2BProfileDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [[NSNotificationCenter defaultCenter] postNotificationName:kBS2BProfileChangedNotification object:nil];
}

// Method to reload the directory path from user defaults
- (void)reloadDirectoryPath {
    NSString *currentPath = [[NSUserDefaults standardUserDefaults] stringForKey:@"songsDirectoryPath"];

    if (currentPath && currentPath.length > 0) {
        self.testLabel.stringValue = currentPath;
    } else {
        self.testLabel.stringValue = NSLocalizedString(@"prefs_no_path", @"Mostrado quando ainda não foi escolhida uma pasta");
    }
}

// IBAction for the "Choose Directory" button
- (IBAction)chooseDirectory:(id)sender {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    [panel setCanChooseDirectories:YES];
    [panel setCanChooseFiles:NO];
    [panel setAllowsMultipleSelection:NO];
    [panel setTitle:NSLocalizedString(@"prefs_choose_directory_title", @"Título do painel de escolha da pasta")];

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK) {
            NSURL *selectedDirectory = panel.URL;
            if (selectedDirectory) {
                self.testLabel.stringValue = selectedDirectory.path;

                [[NSUserDefaults standardUserDefaults] setObject:selectedDirectory.path forKey:@"songsDirectoryPath"];
                [[NSUserDefaults standardUserDefaults] synchronize];

                NSDictionary *userInfo = @{@"newPath": selectedDirectory.path};
                [[NSNotificationCenter defaultCenter] postNotificationName:@"SongsDirectoryPathChanged" object:nil userInfo:userInfo];
            }
        }
    }];
}

@end
