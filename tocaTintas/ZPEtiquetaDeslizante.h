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
//  ZPEtiquetaDeslizante.h
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 05/10/2026.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Uma etiqueta de uma linha que, quando o texto não cabe, o faz passar como um
/// ticker de bolsa: da direita para a esquerda, com o princípio a seguir ao
/// fim, uma passagem completa de cada vez. Parada, mostra-se cortada como um
/// NSTextField; quando o texto cabe, é um NSTextField como outro qualquer.
///
/// Num grupo (+agruparDeCimaParaBaixo:) só uma passa de cada vez, pela ordem
/// dada, com 8 s parado entre duas passagens; um texto novo em qualquer delas
/// recomeça o grupo, 2 s depois, pela de cima. Sozinha, é um grupo de uma.
///
/// Com «Reduzir movimento» ligado nas definições de Acessibilidade não desliza:
/// corta como o lineBreakMode da célula disser. Em qualquer dos casos, o texto
/// completo fica na dica.
///
/// Basta escrever-lhe stringValue, como a um NSTextField.
@interface ZPEtiquetaDeslizante : NSTextField

/// Junta estas etiquetas num grupo em que só uma desliza de cada vez, pela
/// ordem do vector.
+ (void)agruparDeCimaParaBaixo:(NSArray<ZPEtiquetaDeslizante *> *)etiquetas;

/// Os segundos que faltam para a faixa acabar, ou um valor negativo se não se
/// souber. Pergunta-se antes de cada passagem: se não chegar para a acabar, a
/// etiqueta fica cortada e a vez passa à seguinte. Sem bloco, passa sempre.
@property (nonatomic, copy, nullable) NSTimeInterval (^tempoRestante)(void);

@end

NS_ASSUME_NONNULL_END
