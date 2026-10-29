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
//  ZPBarraDeProgresso.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 29/10/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

// Barra de progresso determinada, com o aspecto da do sistema, para pôr no
// lugar de um NSProgressIndicator.
//
// No macOS 27 o NSProgressIndicator anima cada mudança de valor, e não há
// maneira de lho impedir. Actualizado de segundo a segundo, nunca chega a parar
// de animar: medido em 2026-10-29, custava 8 a 15 pontos de CPU ao WindowServer,
// contra menos de um com esta.
@interface ZPBarraDeProgresso : NSView

@property (nonatomic) double minValue;      // 0 por omissão
@property (nonatomic) double maxValue;      // 100 por omissão
@property (nonatomic) double doubleValue;

@end

NS_ASSUME_NONNULL_END
