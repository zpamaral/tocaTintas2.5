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
//  HistogramView.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 26/08/2026.
//

#import "HistogramView.h"
#import <QuartzCore/QuartzCore.h>

@interface HistogramView ()
@property (nonatomic, strong) NSMutableArray<CALayer *> *leftBarLayers;
@property (nonatomic, strong) NSMutableArray<CALayer *> *rightBarLayers;
@end

@implementation HistogramView

// Inicialização preguiçosa em vez de -initWithFrame:. Vindo de um nib é
// -initWithCoder: que corre, e com os arrays a nil o ciclo de criação de
// camadas em -updateBars nunca termina: [nil addObject:] é um no-op, a
// contagem fica sempre em zero e a condição nunca deixa de ser verdadeira.
- (NSMutableArray<CALayer *> *)leftBarLayers {
    if (!_leftBarLayers) _leftBarLayers = [NSMutableArray array];
    return _leftBarLayers;
}

- (NSMutableArray<CALayer *> *)rightBarLayers {
    if (!_rightBarLayers) _rightBarLayers = [NSMutableArray array];
    return _rightBarLayers;
}

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    // Sem camada própria, -addSublayer: cai no vazio e não aparece uma barra.
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawOnSetNeedsDisplay;
}

// Allows for Dark and Light Modes backgrounds
//
// Fundo sólido numa vista apoiada em camadas não precisa de -drawRect:. Com
// -wantsUpdateLayer basta atribuir a cor de fundo da camada, o que evita de
// raiz o problema documentado abaixo.
//
// O dirtyRect não é o rectângulo da vista: é a região que a AppKit quer
// redesenhada, e pode ser maior do que ela. Numa janela apoiada em camadas o
// macOS 26 passava aqui a região da janela inteira, e o NSRectFill pinta o que
// lhe derem — pelo que esta vista de 240x120 pintava de preto os 750x250
// todos, por baixo de tudo o resto. Nos macOS antigos, os rectângulos vinham
// justapostos e o erro nunca se via.
//
// Diagnosticado em 2026-09-05 por bissecção do -viewDidLoad e reproduzido
// fora da app em vinte linhas. O aspecto do histograma não muda: continua
// preto no escuro e cinzento claro no claro.
- (BOOL)wantsUpdateLayer {
    return YES;
}

- (void)updateLayer {
    self.layer.backgroundColor = [[self backgroundColorForCurrentAppearance] CGColor];
}

- (NSColor *)backgroundColorForCurrentAppearance {
    // Comparar directamente com NSAppearanceNameDarkAqua falha nas variantes
    // (contraste elevado, vibrante). bestMatch... resolve-as todas.
    NSAppearanceName match = [self.effectiveAppearance bestMatchFromAppearancesWithNames:
                              @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];

    if ([match isEqualToString:NSAppearanceNameDarkAqua]) {
        return [NSColor blackColor];  // Dark Mode background (black)
    }
    return [NSColor colorWithCalibratedWhite:0.8 alpha:1.0];  // Light Mode background (custom gray)
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    // Sem isto, mudar de modo com a app aberta deixa o fundo antigo até que
    // algo mais force a invalidação.
    [self setNeedsDisplay:YES];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    // As barras têm geometria em pontos absolutos; sem isto só reajustam à
    // largura nova na actualização seguinte do FIFO.
    [self updateBars];
}

- (void)updateHistogramWithLeftChannel:(NSArray<NSNumber *> *)leftChannel rightChannel:(NSArray<NSNumber *> *)rightChannel {
    // Chamado a partir da fila que lê o FIFO. As propriedades só são tocadas no
    // thread principal, para não competirem com o desenho.
    dispatch_async(dispatch_get_main_queue(), ^{
        self.leftChannelValues = leftChannel;
        self.rightChannelValues = rightChannel;
        [self updateBars];
    });
}

// As barras são CALayers simples, com a altura nos bounds. Antes eram
// CAShapeLayers com um CGPath novo por barra e por trama, e o servidor de
// composição tinha de rasterizar cada path de novo, 25 vezes por segundo; um
// rectângulo com cor de fundo não se rasteriza. Uma barra que não mudou não se
// toca, para não entrar na transacção.
- (void)acertarBarras:(NSMutableArray<CALayer *> *)camadas
              valores:(NSArray<NSNumber *> *)valores
             primeira:(NSUInteger)primeira
                  cor:(NSColor *)cor
          columnWidth:(CGFloat)columnWidth
             barWidth:(CGFloat)barWidth
            maxHeight:(CGFloat)maxHeight {
    while (camadas.count < valores.count) {
        CALayer *barLayer = [CALayer layer];
        barLayer.anchorPoint = CGPointZero;
        barLayer.actions = @{@"bounds": [NSNull null], @"position": [NSNull null]};   // nunca animar as barras
        barLayer.backgroundColor = cor.CGColor;
        [self.layer addSublayer:barLayer];
        [camadas addObject:barLayer];
    }

    for (NSUInteger i = 0; i < valores.count; i++) {
        CGFloat height = round(valores[i].floatValue / 1000.0 * maxHeight * 2.0) / 2.0;   // ao píxel
        CALayer *barLayer = camadas[i];
        CGPoint posicao = CGPointMake((i + primeira) * columnWidth, 0);
        CGRect limites = CGRectMake(0, 0, barWidth, height);
        if (!CGPointEqualToPoint(barLayer.position, posicao)) barLayer.position = posicao;
        if (!CGRectEqualToRect(barLayer.bounds, limites)) barLayer.bounds = limites;
    }
}

- (void)updateBars {
    CGFloat totalBars = self.leftChannelValues.count + self.rightChannelValues.count;
    if (totalBars < 1.0) return;   // evita columnWidth infinito

    // Sem isto, cada mudança de tamanho dispara a animação implícita de 0,25 s do
    // CoreAnimation. Com 30 barras a mudar 20 vezes por segundo ficam sempre 30
    // animações a interpolar em simultâneo — é a maior fatia do CPU e é o que dá
    // às barras aquele arrastamento elástico.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CGFloat columnWidth = self.bounds.size.width / totalBars;
    CGFloat maxHeight = self.bounds.size.height;
    // Com muitas barras numa vista estreita, columnWidth - 2 fica negativo e a
    // barra sai sem largura: as barras desapareciam sem aviso.
    CGFloat barWidth = MAX(columnWidth - 2.0, 1.0);

    [self acertarBarras:self.leftBarLayers
                 valores:self.leftChannelValues
                primeira:0
                     cor:[NSColor colorWithCalibratedRed:0.2 green:0.2 blue:0.2 alpha:1.0]
             columnWidth:columnWidth barWidth:barWidth maxHeight:maxHeight];
    [self acertarBarras:self.rightBarLayers
                 valores:self.rightChannelValues
                primeira:self.leftChannelValues.count
                     cor:[NSColor colorWithCalibratedRed:0.5 green:0.5 blue:0.5 alpha:1.0]
             columnWidth:columnWidth barWidth:barWidth maxHeight:maxHeight];

    // Remove extra layers if counts have decreased
    if (self.leftBarLayers.count > self.leftChannelValues.count) {
        for (NSUInteger i = self.leftChannelValues.count; i < self.leftBarLayers.count; i++) {
            CALayer *barLayer = self.leftBarLayers[i];
            [barLayer removeFromSuperlayer];
        }
        [self.leftBarLayers removeObjectsInRange:NSMakeRange(self.leftChannelValues.count, self.leftBarLayers.count - self.leftChannelValues.count)];
    }

    if (self.rightBarLayers.count > self.rightChannelValues.count) {
        for (NSUInteger i = self.rightChannelValues.count; i < self.rightBarLayers.count; i++) {
            CALayer *barLayer = self.rightBarLayers[i];
            [barLayer removeFromSuperlayer];
        }
        [self.rightBarLayers removeObjectsInRange:NSMakeRange(self.rightChannelValues.count, self.rightBarLayers.count - self.rightChannelValues.count)];
    }

    [CATransaction commit];
}

@end
