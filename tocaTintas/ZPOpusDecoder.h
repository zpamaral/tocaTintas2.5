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
//  ZPOpusDecoder.h
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 14/09/2026.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>  // Use AppKit for macOS images


// Forward declaration to avoid circular dependency

@interface ZPOpusDecoder : NSObject  // Ensure it inherits from NSObject

@property (nonatomic, strong) NSString *artist;
@property (nonatomic, strong) NSString *album;
@property (nonatomic, strong) NSString *title;
@property (nonatomic, strong) NSString *track;   // Add track property
@property (nonatomic, strong) NSImage *albumArt;
/// O ReplayGain lido das etiquetas, sem política aplicada.
///
/// Aqui esteve um `airPlayStreamer` próprio, criado com `[[ZPAirPlayStreamer
/// alloc] init]` e alimentado com o ganho desta faixa. Não servia para nada, por
/// duas razões de uma vez: não era o streamer que estava a transmitir — esse é o
/// do ViewController —, e como a classe não tem `-init`, só
/// `-initWithIPAddress:port:replayGainValue:`, o objecto saía meio construído,
/// sem tampão nem engine. O resultado é que uma faixa Opus tocava do princípio
/// ao fim com o ganho que a faixa anterior tinha deixado.
///
/// Agora quem empurra é o ViewController, pelo -primeReplayGainForTrack:, e
/// antes de a faixa começar. Isto fica só como leitura, para quem a quiser.
///
/// Um pico a zero significa «desconhecido», e os valores de álbum a zero contam
/// como ausentes — é a convenção do ZPResolveReplayGain, que é quem resolve o
/// par a aplicar a partir destes quatro.
@property (atomic, assign) float replayGainValue;
@property (atomic, assign) float replayGainPeak;
@property (atomic, assign) float replayGainAlbumValue;
@property (atomic, assign) float replayGainAlbumPeak;

// Method to initialize decoder with an Opus file
- (instancetype)initWithFilePath:(NSString *)filePath;

// Alternative initializer that accepts already loaded Opus data
- (instancetype)initWithData:(NSData *)data;

// Method to decode Opus file and extract metadata
- (BOOL)decodeFile;

// Helper method to retrieve file duration
- (NSTimeInterval)getDuration;

@end
/* OpusDecoder_h */
