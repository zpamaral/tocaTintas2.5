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

static NSString * const kNormalizacoes[] = { @"none", @"track", @"album" };
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
    [janela setContentSize:NSMakeSize(480, 310)];
    janela.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 310)];

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
    [vista addSubview:t];
    return t;
}

- (NSView *)criarVistaDSP {
    NSView *vista = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 285)];

    NSTextField *(^etiqueta)(NSRect, NSString *, BOOL) = ^NSTextField *(NSRect r, NSString *texto, BOOL pequena) {
        return [self etiquetaEm:vista moldura:r texto:texto pequena:pequena];
    };

    etiqueta(NSMakeRect(20, 195, 440, 70),
             NSLocalizedString(@"prefs_dsp_explanation", @"Explicação do que o crossfeed faz"), NO);

    etiqueta(NSMakeRect(20, 160, 200, 17),
             NSLocalizedString(@"prefs_dsp_profile_label", @"Etiqueta do menu de perfis"), NO);

    self.dspPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 128, 330, 26) pullsDown:NO];
    NSArray<NSString *> *chaves = @[@"prefs_dsp_profile_default", @"prefs_dsp_profile_cmoy", @"prefs_dsp_profile_jmeier"];
    for (NSUInteger i = 0; i < kNumPerfis; ++i) {
        [self.dspPopUp addItemWithTitle:NSLocalizedString(chaves[i], @"Nome de um perfil de crossfeed")];
        self.dspPopUp.lastItem.representedObject = kPerfis[i];
    }
    self.dspPopUp.target = self;
    self.dspPopUp.action = @selector(dspProfileChanged:);
    [vista addSubview:self.dspPopUp];

    NSString *actual = ZPCurrentBS2BProfile();
    for (NSMenuItem *item in self.dspPopUp.itemArray) {
        if ([item.representedObject isEqualToString:actual]) {
            [self.dspPopUp selectItem:item];
            break;
        }
    }

    etiqueta(NSMakeRect(20, 20, 440, 95),
             NSLocalizedString(@"prefs_dsp_note", @"Nota sobre o botão dos auscultadores"), YES);

    return vista;
}

- (NSView *)criarVistaAirPlay {
    NSView *vista = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 285)];

    [self etiquetaEm:vista moldura:NSMakeRect(20, 195, 440, 70)
               texto:NSLocalizedString(@"prefs_norm_explanation", @"Explicação da normalização de volume")
             pequena:NO];

    [self etiquetaEm:vista moldura:NSMakeRect(20, 160, 300, 17)
               texto:NSLocalizedString(@"prefs_norm_label", @"Etiqueta do menu de normalização")
             pequena:NO];

    self.normPopUp = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(20, 128, 330, 26) pullsDown:NO];
    NSArray<NSString *> *chaves = @[@"prefs_norm_none", @"prefs_norm_track", @"prefs_norm_album"];
    for (NSUInteger i = 0; i < kNumNormalizacoes; ++i) {
        [self.normPopUp addItemWithTitle:NSLocalizedString(chaves[i], @"Modo de normalização de volume")];
        self.normPopUp.lastItem.representedObject = kNormalizacoes[i];
    }
    self.normPopUp.target = self;
    self.normPopUp.action = @selector(airPlayNormalizationChanged:);
    [vista addSubview:self.normPopUp];

    NSString *actual = ZPCurrentAirPlayNormalization();
    for (NSMenuItem *item in self.normPopUp.itemArray) {
        if ([item.representedObject isEqualToString:actual]) {
            [self.normPopUp selectItem:item];
            break;
        }
    }

    [self etiquetaEm:vista moldura:NSMakeRect(20, 20, 440, 95)
               texto:NSLocalizedString(@"prefs_norm_note", @"Nota sobre a normalização")
             pequena:YES];

    return vista;
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
