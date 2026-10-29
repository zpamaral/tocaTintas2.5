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
//  ZPBarraDeProgresso.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 29/10/2026.
//

#import "ZPBarraDeProgresso.h"
#import <QuartzCore/QuartzCore.h>

// Medidas e cores tiradas de capturas do NSProgressIndicator do macOS 27, nos
// modos claro e escuro, com a janela activa e inactiva.
static const CGFloat kEspessura = 8.0;      // pt; centrada na altura da vista

// Pista: branco a ~8 % sobre o fundo escuro, preto a ~6 % sobre o claro, com
// um fio de contorno um pouco mais marcado.
static NSColor *ZPCorDaPista(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *aparencia) {
        BOOL escuro = [[aparencia bestMatchFromAppearancesWithNames:
                        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return escuro ? [NSColor colorWithWhite:1.0 alpha:0.08] : [NSColor colorWithWhite:0.0 alpha:0.06];
    }];
}

static NSColor *ZPCorDoContorno(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *aparencia) {
        BOOL escuro = [[aparencia bestMatchFromAppearancesWithNames:
                        @[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return escuro ? [NSColor colorWithWhite:1.0 alpha:0.04] : [NSColor colorWithWhite:0.0 alpha:0.07];
    }];
}

@interface ZPBarraDeProgresso ()
@property (nonatomic, strong) CALayer *pista;
@property (nonatomic, strong) CALayer *enchimento;
@end

@implementation ZPBarraDeProgresso

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _minValue = 0.0;
        _maxValue = 100.0;
        self.wantsLayer = YES;

        // Camadas nossas, sem animações implícitas: é precisamente a animação
        // de cada mudança de valor que se quer evitar.
        NSDictionary *semAnimacoes = @{@"bounds": [NSNull null], @"position": [NSNull null],
                                       @"frame": [NSNull null], @"backgroundColor": [NSNull null],
                                       @"borderColor": [NSNull null], @"cornerRadius": [NSNull null],
                                       @"hidden": [NSNull null]};
        _pista = [CALayer layer];
        _pista.actions = semAnimacoes;
        _pista.cornerRadius = kEspessura / 2.0;
        _pista.borderWidth = 1.0 / 2.0;     // um píxel no ecrã Retina
        [self.layer addSublayer:_pista];

        _enchimento = [CALayer layer];
        _enchimento.actions = semAnimacoes;
        _enchimento.anchorPoint = CGPointZero;
        [self.layer addSublayer:_enchimento];

        // Mudar a cor de destaque nos Ajustes chega por aqui.
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(pintar)
                                                     name:NSSystemColorsDidChangeNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (BOOL)isFlipped {
    return NO;
}

#pragma mark - Valor

- (void)setMinValue:(double)minValue {
    _minValue = minValue;
    [self encher];
}

- (void)setMaxValue:(double)maxValue {
    _maxValue = maxValue;
    [self encher];
}

- (void)setDoubleValue:(double)doubleValue {
    // Chamado de segundo a segundo: se o valor não mexe, não se toca nas camadas.
    if (doubleValue == _doubleValue) return;
    _doubleValue = doubleValue;
    [self encher];
}

#pragma mark - Geometria e cor

- (NSRect)rectanguloDaPista {
    NSRect b = self.bounds;
    return NSMakeRect(NSMinX(b), round(NSMidY(b) - kEspessura / 2.0), NSWidth(b), kEspessura);
}

- (void)encher {
    NSRect pista = [self rectanguloDaPista];
    double gama = self.maxValue - self.minValue;
    double fraccao = gama > 0 ? (self.doubleValue - self.minValue) / gama : 0.0;
    fraccao = MIN(MAX(fraccao, 0.0), 1.0);

    // Arredondado ao meio ponto, que é um píxel: entre dois segundos o
    // enchimento de uma faixa longa nem sempre avança um píxel, e assim não se
    // manda ao servidor de composição uma mudança que não se vê.
    CGFloat largura = round(NSWidth(pista) * fraccao * 2.0) / 2.0;
    if (self.enchimento.bounds.size.width == largura &&
        CGPointEqualToPoint(self.enchimento.position, pista.origin)) {
        return;
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.enchimento.hidden = (largura <= 0);
    self.enchimento.position = pista.origin;
    self.enchimento.bounds = CGRectMake(0, 0, largura, kEspessura);
    // Abaixo da espessura, um raio de metade da altura deformava o princípio.
    self.enchimento.cornerRadius = MIN(kEspessura, largura) / 2.0;
    [CATransaction commit];
}

- (void)pintar {
    // Com a janela activa, o enchimento leva a cor de destaque; inactiva,
    // cinzento, nos dois modos — como o NSProgressIndicator.
    BOOL activa = self.window.isKeyWindow;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        self.pista.backgroundColor = ZPCorDaPista().CGColor;
        self.pista.borderColor = ZPCorDoContorno().CGColor;
        self.enchimento.backgroundColor = activa ? NSColor.controlAccentColor.CGColor
                                                 : [NSColor colorWithWhite:170.0 / 255.0 alpha:1.0].CGColor;
    }];
    [CATransaction commit];
}

- (void)layout {
    [super layout];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.pista.frame = [self rectanguloDaPista];
    [CATransaction commit];
    [self encher];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    self.needsLayout = YES;
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self pintar];
}

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
    [super viewWillMoveToWindow:newWindow];
    NSNotificationCenter *centro = [NSNotificationCenter defaultCenter];
    [centro removeObserver:self name:NSWindowDidBecomeKeyNotification object:nil];
    [centro removeObserver:self name:NSWindowDidResignKeyNotification object:nil];
    if (newWindow) {
        [centro addObserver:self selector:@selector(pintar) name:NSWindowDidBecomeKeyNotification object:newWindow];
        [centro addObserver:self selector:@selector(pintar) name:NSWindowDidResignKeyNotification object:newWindow];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self pintar];
    self.needsLayout = YES;
}

#pragma mark - Acessibilidade

// O NSProgressIndicator anuncia-se ao VoiceOver; esta também.
- (BOOL)isAccessibilityElement {
    return YES;
}

- (NSAccessibilityRole)accessibilityRole {
    return NSAccessibilityProgressIndicatorRole;
}

- (id)accessibilityValue {
    return @(self.doubleValue);
}

- (id)accessibilityMinValue {
    return @(self.minValue);
}

- (id)accessibilityMaxValue {
    return @(self.maxValue);
}

@end
