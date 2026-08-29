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
//  PreferencesWindowController.h
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 12/09/2026.
//

#import <Cocoa/Cocoa.h>

/// Chave em NSUserDefaults com o perfil de crossfeed escolhido nas preferências.
/// Os valores são os nomes que o bs2b_bridge conhece: "default", "cmoy" e
/// "jmeier". Ausente ou desconhecido vale como "cmoy".
extern NSString * const kBS2BProfileDefaultsKey;

/// Publicada quando o perfil muda, para quem estiver a correr a ponte a poder
/// relançar com o perfil novo.
extern NSString * const kBS2BProfileChangedNotification;

/// Perfil válido guardado nas preferências, já com o valor por omissão aplicado.
NSString *ZPCurrentBS2BProfile(void);

/// Chave em NSUserDefaults com a normalização de volume do AirPlay:
/// "none", "track" ou "album". Ausente ou desconhecida vale como "track".
extern NSString * const kAirPlayNormalizationDefaultsKey;

/// Publicada quando essa escolha muda.
extern NSString * const kAirPlayNormalizationChangedNotification;

/// Compensar no AirPlay a atenuação que o cursor de volume do macOS aplica ao
/// BlackHole. Ausente vale como ligada.
extern NSString * const kAirPlayCompensateVolumeDefaultsKey;
extern NSString * const kAirPlayCompensateVolumeChangedNotification;

/// Aplica a política escolhida aos valores lidos das etiquetas e devolve o par
/// (ganho, pico) a entregar ao streamer. Um pico de 0 significa «desconhecido»,
/// e nesse caso o streamer não limita nada. Os valores de álbum a zero contam
/// como ausentes, e a normalização por álbum recai então na de faixa.
void ZPResolveReplayGain(float trackGain, float trackPeak,
                         float albumGain, float albumPeak,
                         float *outGain, float *outPeak);

@interface PreferencesWindowController : NSWindowController

@property (weak) IBOutlet NSButton *saveButton; // Button for saving

@property (strong, nonatomic) NSTextField *testLabel;  // Programmatic label

- (IBAction)chooseDirectory:(id)sender; // Action for opening the directory chooser
- (void)reloadDirectoryPath; // Method to reload the directory path from user defaults

@end

