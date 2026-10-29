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
//  ZPLigacoesDoMusicaWindowController.h
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 29/10/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// A janela onde se decidem as faixas do Música que o «fonoteca.py
/// sincronizar-musica» deixou pendentes: as que têm músicas parecidas na base
/// mas nenhuma certa. Para cada uma, as candidatas (a sugerida já escolhida) e
/// «Nenhuma», que lhe dá uma música própria — como o Música faz com um CD que
/// tem várias entradas.
///
/// Escreve só em faixas_musica, candidatas_musica e, para as próprias, em
/// musicas. As contagens que o Música já tinha passam a contar logo; o que ele
/// contar a seguir entra no sincronizar seguinte.
@interface ZPLigacoesDoMusicaWindowController : NSWindowController

- (instancetype)initComBase:(NSString *)caminhoDaBase;

/// Volta a ler as pendentes (depois de um sincronizar, por exemplo).
- (void)recarregar;

@end

NS_ASSUME_NONNULL_END
