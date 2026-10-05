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
//  ZPEtiquetaDeslizante.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 05/10/2026.
//

#import "ZPEtiquetaDeslizante.h"
#import <QuartzCore/QuartzCore.h>

static const CFTimeInterval kPausaInicial = 2.0;   // s parado, cortado, quando o texto aparece
static const CFTimeInterval kPausaEntrePassagens = 8.0;   // s parado, cortado, entre duas passagens
static const CGFloat kVelocidade = 50.0;            // pt/s; com letra de 22 pt, uns 4,5 caracteres por segundo
static const CGFloat kIntervaloEmEms = 2.5;         // espaço entre o fim e o princípio, em tamanhos de letra
static const CGFloat kEsbatimento = 16.0;           // pt de esbatimento em cada borda

// O movimento é todo do Core Animation: no começo de cada passagem o texto (com
// a cópia que vem atrás) é desenhado uma vez numa camada, e a deslocação e os
// esbatimentos são animações dessa camada, feitas pelo servidor de composição.
// A app só acorda nas mudanças de fase — duas vezes por passagem —, em vez de
// redesenhar o texto 60 vezes por segundo.

@class ZPGrupoDeEtiquetas;

@interface ZPEtiquetaDeslizante ()
@property (nonatomic) BOOL desliza;                 // o texto não cabe e o movimento é permitido
@property (nonatomic) CGFloat larguraDoTexto;
@property (nonatomic) CGFloat periodo;              // pt de uma passagem: o texto e o intervalo
@property (nonatomic) BOOL emPassagem;              // a fita está à vista e a etiqueta não desenha o texto
@property (nonatomic, strong, nullable) ZPGrupoDeEtiquetas *grupo;
@property (nonatomic, strong) NSView *fita;         // vista com camadas próprias, por cima da área do texto
@property (nonatomic, strong) CALayer *camadaDoTexto;
@property (nonatomic, strong) CAGradientLayer *mascara;
@property (nonatomic) BOOL imagemValida;            // a imagem da camada corresponde ao texto, ao aspecto e à escala
- (void)comecarPassagem;
- (void)terminarPassagem;
@end

#pragma mark - Grupo

// Quem dá a vez às etiquetas: uma passagem de cada vez, pela ordem do grupo
// (de cima para baixo), com uma pausa entre cada duas. Cada etiqueta sozinha é
// um grupo de uma, e +agruparDeCimaParaBaixo: junta várias. Vive de um único
// temporizador, armado para a próxima mudança de fase.
@interface ZPGrupoDeEtiquetas : NSObject
@property (nonatomic, strong) NSPointerArray *etiquetas;   // fracas: as etiquetas é que seguram o grupo
@property (nonatomic, strong, nullable) NSTimer *temporizador;
@property (nonatomic) NSInteger indice;             // a que está a passar, ou a última que passou; -1 antes da primeira
@property (nonatomic) BOOL emPassagem;
@end

@implementation ZPGrupoDeEtiquetas

- (instancetype)init {
    self = [super init];
    if (self) {
        _etiquetas = [NSPointerArray weakObjectsPointerArray];
        _indice = -1;
    }
    return self;
}

- (void)largar {
    [self.temporizador invalidate];
    self.temporizador = nil;
}

- (void)armarPara:(NSTimeInterval)segundos accao:(SEL)accao {
    [self.temporizador invalidate];
    __weak typeof(self) fraco = self;
    self.temporizador = [NSTimer timerWithTimeInterval:segundos repeats:NO block:^(NSTimer *t) {
        ZPGrupoDeEtiquetas *forte = fraco;
        if (!forte) return;
        forte.temporizador = nil;
        ((void (*)(id, SEL))[forte methodForSelector:accao])(forte, accao);
    }];
    // Folga para o sistema juntar este acordar a outros; o fim da animação não
    // depende dele (a camada fica parada na posição final, igual à inicial).
    self.temporizador.tolerance = 0.1;
    [[NSRunLoop mainRunLoop] addTimer:self.temporizador forMode:NSRunLoopCommonModes];
}

- (nullable ZPEtiquetaDeslizante *)etiquetaEm:(NSInteger)i {
    return (i >= 0 && (NSUInteger)i < self.etiquetas.count) ? (__bridge ZPEtiquetaDeslizante *)[self.etiquetas pointerAtIndex:(NSUInteger)i] : nil;
}

- (BOOL)alguemPrecisa {
    for (ZPEtiquetaDeslizante *e in self.etiquetas) {
        if (e.desliza && e.window) return YES;
    }
    return NO;
}

// Um texto novo: todas cortadas, e a primeira passagem, a da etiqueta de cima
// que precise, depois da pausa inicial.
- (void)recomecar {
    if (self.emPassagem) [[self etiquetaEm:self.indice] terminarPassagem];
    self.emPassagem = NO;
    self.indice = -1;
    if ([self alguemPrecisa]) {
        [self armarPara:kPausaInicial accao:@selector(proximaPassagem)];
    } else {
        [self largar];
    }
}

- (void)etiqueta:(ZPEtiquetaDeslizante *)etiqueta mudou:(BOOL)textoNovo {
    if (textoNovo) {
        [self recomecar];
    } else if (self.emPassagem && [self etiquetaEm:self.indice] == etiqueta && !etiqueta.desliza) {
        // A que estava a passar deixou de precisar (passou a caber, ligou-se o
        // «Reduzir movimento», saiu da janela).
        [self fimDaPassagem];
    } else if (!self.temporizador && !self.emPassagem && [self alguemPrecisa]) {
        // Uma passou a precisar sem texto novo (entrou na janela, por exemplo).
        [self armarPara:kPausaInicial accao:@selector(proximaPassagem)];
    }
}

// Acabou a pausa: a seguinte, de cima para baixo e dando a volta, que não
// caiba e cuja passagem a faixa deixe acabar. Uma passagem que a música não
// deixaria acabar ficava com o texto cortado ao meio quando a faixa seguinte o
// trocasse.
- (void)proximaPassagem {
    NSInteger n = (NSInteger)self.etiquetas.count;
    BOOL alguem = NO;
    for (NSInteger k = 1; k <= n; k++) {
        NSInteger i = ((self.indice + k) % n + n) % n;
        ZPEtiquetaDeslizante *e = [self etiquetaEm:i];
        if (!e.desliza || !e.window) continue;
        alguem = YES;
        NSTimeInterval passagem = e.periodo / kVelocidade;
        NSTimeInterval restante = e.tempoRestante ? e.tempoRestante() : -1;
        if (restante >= 0 && restante < passagem) continue;
        self.indice = i;
        self.emPassagem = YES;
        [e comecarPassagem];
        [self armarPara:passagem accao:@selector(fimDaPassagem)];
        return;
    }
    // Ninguém pode passar agora: volta-se a ver ao fim de outra pausa, se
    // houver alguém à espera; senão, fica-se quieto até um texto novo.
    if (alguem) {
        [self armarPara:kPausaEntrePassagens accao:@selector(proximaPassagem)];
    }
}

- (void)fimDaPassagem {
    [[self etiquetaEm:self.indice] terminarPassagem];
    self.emPassagem = NO;
    if ([self alguemPrecisa]) {
        [self armarPara:kPausaEntrePassagens accao:@selector(proximaPassagem)];
    } else {
        [self largar];
    }
}

@end

#pragma mark - Etiqueta

@implementation ZPEtiquetaDeslizante

+ (void)agruparDeCimaParaBaixo:(NSArray<ZPEtiquetaDeslizante *> *)etiquetas {
    ZPGrupoDeEtiquetas *grupo = [[ZPGrupoDeEtiquetas alloc] init];
    for (ZPEtiquetaDeslizante *e in etiquetas) {
        [e.grupo largar];
        [e terminarPassagem];
        e.grupo = grupo;
        [grupo.etiquetas addPointer:(__bridge void *)e];
    }
    [grupo recomecar];
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // A fita: uma vista que hospeda camadas nossas (layer-hosting), por cima
        // da área do texto e escondida fora das passagens.
        CALayer *raiz = [CALayer layer];
        raiz.masksToBounds = YES;
        _camadaDoTexto = [CALayer layer];
        _camadaDoTexto.anchorPoint = CGPointZero;
        [raiz addSublayer:_camadaDoTexto];
        _mascara = [CAGradientLayer layer];
        _mascara.startPoint = CGPointMake(0, 0.5);
        _mascara.endPoint = CGPointMake(1, 0.5);
        _mascara.colors = @[(id)NSColor.clearColor.CGColor, (id)NSColor.blackColor.CGColor,
                            (id)NSColor.blackColor.CGColor, (id)NSColor.clearColor.CGColor];
        raiz.mask = _mascara;
        _fita = [[NSView alloc] initWithFrame:NSZeroRect];
        _fita.layer = raiz;
        _fita.wantsLayer = YES;
        _fita.hidden = YES;
        [self addSubview:_fita];

        _grupo = [[ZPGrupoDeEtiquetas alloc] init];
        [_grupo.etiquetas addPointer:(__bridge void *)self];
        [[[NSWorkspace sharedWorkspace] notificationCenter] addObserver:self selector:@selector(movimentoMudou:)
                                                                   name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                                                                 object:nil];
        [self reavaliar:NO];
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver:self];
}

#pragma mark Quando reavaliar

- (void)setStringValue:(NSString *)valor {
    // O mesmo texto outra vez (a identificação de um CD que se refaz, a mesma
    // faixa que recomeça) não volta ao princípio.
    if ([valor isEqualToString:self.stringValue]) return;
    [super setStringValue:valor];
    [self reavaliar:YES];
}

- (void)setAttributedStringValue:(NSAttributedString *)valor {
    [super setAttributedStringValue:valor];
    [self reavaliar:YES];
}

- (void)setFont:(NSFont *)font {
    [super setFont:font];
    [self reavaliar:NO];
}

- (void)setTextColor:(NSColor *)cor {
    [super setTextColor:cor];
    self.imagemValida = NO;
}

- (void)setFrameSize:(NSSize)tamanho {
    [super setFrameSize:tamanho];
    [self reavaliar:NO];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self reavaliar:NO];
}

// Claro/escuro e a densidade do ecrã mudam a imagem do texto, não a geometria.
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self imagemMudou];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self imagemMudou];
}

- (void)imagemMudou {
    self.imagemValida = NO;
    if (self.emPassagem) [self prepararImagem];   // a meio da passagem: troca-se a imagem, a animação continua
}

- (void)movimentoMudou:(NSNotification *)nota {
    [self reavaliar:NO];
}

// Mede o texto, decide se tem de deslizar e avisa o grupo. `textoNovo` faz o
// grupo todo recomeçar, com a pausa inicial.
- (void)reavaliar:(BOOL)textoNovo {
    if (!self.fita) return;   // ainda dentro do -initWithFrame: do NSTextField
    NSAttributedString *texto = [self textoParaDesenhar];
    self.larguraDoTexto = ceil(texto.size.width);
    self.periodo = self.larguraDoTexto + round(self.font.pointSize * kIntervaloEmEms);
    self.imagemValida = NO;

    NSRect area = [self areaDoTexto];
    self.fita.frame = NSMakeRect(NSMinX(area), 0, NSWidth(area), NSHeight(self.bounds));
    BOOL naoCabe = self.larguraDoTexto > NSWidth(area) + 0.5;
    BOOL reduzir = [NSWorkspace sharedWorkspace].accessibilityDisplayShouldReduceMotion;

    self.toolTip = naoCabe ? self.stringValue : nil;
    self.desliza = naoCabe && !reduzir && self.window != nil;
    [self.grupo etiqueta:self mudou:textoNovo];
    self.needsDisplay = YES;
}

#pragma mark Passagem

// Desenha o texto e a cópia que vem atrás numa imagem do tamanho da fita na
// altura e de uma passagem e uma largura de fita no comprimento, à escala e com
// as cores do aspecto em vigor. Feito uma vez por texto, não por quadro.
- (void)prepararImagem {
    if (self.imagemValida) return;
    CGFloat escala = self.window.backingScaleFactor ?: 2.0;
    NSRect area = [self areaDoTexto];
    CGFloat alto = NSHeight(self.bounds);
    CGFloat largo = ceil(self.periodo + NSWidth(area));
    // Onde a célula põe o texto, medido a partir do topo da etiqueta.
    CGFloat topo = self.isFlipped ? NSMinY(area) : alto - NSMaxY(area);

    size_t w = (size_t)ceil(largo * escala), h = (size_t)ceil(alto * escala);
    CGColorSpaceRef espaco = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef cg = CGBitmapContextCreate(NULL, w, h, 8, 0, espaco, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(espaco);
    if (!cg) return;
    CGContextScaleCTM(cg, escala, escala);
    CGContextTranslateCTM(cg, 0, alto);
    CGContextScaleCTM(cg, 1, -1);   // origem em cima, como numa vista invertida

    NSGraphicsContext *anterior = [NSGraphicsContext currentContext];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
        NSAttributedString *texto = [self textoParaDesenhar];
        for (CGFloat x = 0; x < largo; x += self.periodo) {
            [texto drawWithRect:NSMakeRect(x, topo, self.larguraDoTexto + 1, NSHeight(area))
                        options:NSStringDrawingUsesLineFragmentOrigin context:nil];
        }
    }];
    [NSGraphicsContext setCurrentContext:anterior];

    CGImageRef imagem = CGBitmapContextCreateImage(cg);
    CGContextRelease(cg);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.camadaDoTexto.contents = (__bridge id)imagem;
    self.camadaDoTexto.contentsScale = escala;
    self.camadaDoTexto.bounds = CGRectMake(0, 0, largo, alto);
    [CATransaction commit];
    CGImageRelease(imagem);
    self.imagemValida = YES;
}

- (void)comecarPassagem {
    [self prepararImagem];
    NSRect area = [self areaDoTexto];
    CGFloat largura = NSWidth(area);
    CFTimeInterval duracao = self.periodo / kVelocidade;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.fita.layer.bounds = CGRectMake(0, 0, largura, NSHeight(self.bounds));
    self.mascara.frame = self.fita.layer.bounds;

    // A deslocação: uma passagem inteira, a velocidade constante. O valor do
    // modelo fica no fim, que tem o princípio da cópia no sítio do original —
    // o mesmo aspecto do começo, se o temporizador do fim se atrasar um pouco.
    self.camadaDoTexto.position = CGPointMake(-self.periodo, 0);
    CABasicAnimation *andar = [CABasicAnimation animationWithKeyPath:@"position.x"];
    andar.fromValue = @0;
    andar.toValue = @(-self.periodo);
    andar.duration = duracao;
    andar.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [self.camadaDoTexto addAnimation:andar forKey:@"andar"];

    // Os esbatimentos: o da direita fixo; o da esquerda cresce enquanto o texto
    // arranca e encolhe quando o princípio volta ao sítio, para não haver salto
    // de e para a etiqueta cortada.
    CGFloat d = MIN(kEsbatimento / largura, 0.5);
    NSArray *fechado = @[@0, @0, @(1 - d), @1];
    NSArray *aberto  = @[@0, @(d), @(1 - d), @1];
    self.mascara.locations = fechado;
    CAKeyframeAnimation *esbater = [CAKeyframeAnimation animationWithKeyPath:@"locations"];
    double a = MIN(kEsbatimento / self.periodo, 0.5);
    esbater.values = @[fechado, aberto, aberto, fechado];
    esbater.keyTimes = @[@0, @(a), @(1 - a), @1];
    esbater.duration = duracao;
    [self.mascara addAnimation:esbater forKey:@"esbater"];

    // A fita aparece e o texto da etiqueta sai no mesmo quadro.
    self.fita.hidden = NO;
    self.emPassagem = YES;
    self.needsDisplay = YES;
    [self displayIfNeeded];
    [CATransaction commit];
}

- (void)terminarPassagem {
    if (!self.emPassagem) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [self.camadaDoTexto removeAllAnimations];
    [self.mascara removeAllAnimations];
    self.fita.hidden = YES;
    self.emPassagem = NO;
    self.needsDisplay = YES;
    [self displayIfNeeded];
    [CATransaction commit];
}

#pragma mark Desenho

// Onde o NSTextField põe o texto: a área de desenho da célula menos os 2 pt de
// margem de cada lado (o lineFragmentPadding). Sem isto, o texto que desliza
// ficava 2 pt à esquerda do das etiquetas que não deslizam.
- (NSRect)areaDoTexto {
    return NSInsetRect([self.cell drawingRectForBounds:self.bounds], 2, 0);
}

- (NSAttributedString *)textoParaDesenhar {
    NSMutableParagraphStyle *paragrafo = [[NSMutableParagraphStyle alloc] init];
    paragrafo.lineBreakMode = NSLineBreakByClipping;
    return [[NSAttributedString alloc] initWithString:self.stringValue ?: @""
                                           attributes:@{ NSFontAttributeName: self.font ?: [NSFont systemFontOfSize:0],
                                                         NSForegroundColorAttributeName: self.textColor ?: NSColor.labelColor,
                                                         NSParagraphStyleAttributeName: paragrafo }];
}

// Em passagem o texto está na fita; a etiqueta só desenha o fundo, se o tiver.
- (void)drawRect:(NSRect)sujo {
    if (!self.emPassagem) {
        [super drawRect:sujo];
    } else if (self.drawsBackground && self.backgroundColor) {
        [self.backgroundColor setFill];
        NSRectFill(sujo);
    }
}

@end
