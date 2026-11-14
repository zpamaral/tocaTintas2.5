//
//  ZPDescobertas.m
//  tocaTintas
//

#import "ZPDescobertas.h"

// As colunas da tabela, pela ordem dos campos que o vectorizar escreve.
typedef NS_ENUM(NSUInteger, ZPCampo) {
    ZPCampoId, ZPCampoLugar, ZPCampoSemelhanca, ZPCampoArtista, ZPCampoTitulo, ZPCampoAlbum,
    ZPCampoEndereco, ZPCampoSemente, ZPCampoVizinho, ZPCampoQuantos,
};

@interface ZPDescobertas () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, strong) NSURL *vectorizar;
@property (nonatomic, copy) NSString *base, *mapa;
@property (nonatomic, copy, nullable) NSString *semente, *nomeDaSemente;
@property (nonatomic, strong) NSArray<NSArray<NSString *> *> *linhas;
@property (nonatomic, strong) NSTableView *tabela;
@property (nonatomic, strong) NSSegmentedControl *modo;
@property (nonatomic, strong) NSTextField *legenda;
@property (nonatomic, strong) NSButton *abrir, *esquecer;
@property (nonatomic, assign) NSUInteger pedido;   // só a resposta ao último pedido conta
@end

@implementation ZPDescobertas

- (instancetype)initWithVectorizar:(NSURL *)vectorizar base:(NSString *)base mapa:(NSString *)mapa {
    NSWindow *janela = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 420)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered defer:YES];
    if (!(self = [super initWithWindow:janela])) return nil;
    _vectorizar = vectorizar;
    _base = [base copy];
    _mapa = [mapa copy];
    _linhas = @[];
    janela.title = NSLocalizedString(@"discoveries_title", @"Descobertas");
    janela.minSize = NSMakeSize(520, 240);
    janela.releasedWhenClosed = NO;
    [janela center];
    janela.frameAutosaveName = @"ZPDescobertas";
    [self montar];
    return self;
}

- (void)montar {
    NSView *fundo = self.window.contentView;

    self.modo = [NSSegmentedControl segmentedControlWithLabels:@[NSLocalizedString(@"discoveries_for_current", @"Para a faixa que toca"),
                                                                 NSLocalizedString(@"discoveries_all", @"Todas")]
                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                        target:self action:@selector(actualizar)];
    self.modo.selectedSegment = 0;

    self.legenda = [NSTextField labelWithString:@""];
    self.legenda.textColor = NSColor.secondaryLabelColor;
    self.legenda.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.legenda setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.tabela = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tabela.dataSource = self;
    self.tabela.delegate = self;
    self.tabela.usesAlternatingRowBackgroundColors = YES;
    self.tabela.allowsMultipleSelection = NO;
    self.tabela.target = self;
    self.tabela.doubleAction = @selector(abrirNoMusica:);
    self.tabela.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    NSArray<NSArray *> *colunas = @[
        @[@(ZPCampoLugar),   NSLocalizedString(@"discoveries_rank", @"Lugar"),          @60.0],
        @[@(ZPCampoArtista), NSLocalizedString(@"discoveries_artist", @"Artista"),      @150.0],
        @[@(ZPCampoTitulo),  NSLocalizedString(@"discoveries_song", @"Título"),         @190.0],
        @[@(ZPCampoAlbum),   NSLocalizedString(@"discoveries_album", @"Álbum"),         @150.0],
        @[@(ZPCampoSemente), NSLocalizedString(@"discoveries_brought_by", @"Trazida por"), @170.0],
    ];
    for (NSArray *c in colunas) {
        NSTableColumn *coluna = [[NSTableColumn alloc] initWithIdentifier:[c[0] stringValue]];
        coluna.title = c[1];
        coluna.width = [c[2] doubleValue];
        coluna.minWidth = 40;
        [self.tabela addTableColumn:coluna];
    }
    NSScrollView *rolo = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    rolo.documentView = self.tabela;
    rolo.hasVerticalScroller = YES;
    rolo.borderType = NSBezelBorder;

    self.abrir = [NSButton buttonWithTitle:NSLocalizedString(@"discoveries_open", @"Abrir no Música") target:self action:@selector(abrirNoMusica:)];
    self.abrir.keyEquivalent = @"\r";
    self.esquecer = [NSButton buttonWithTitle:NSLocalizedString(@"discoveries_forget", @"Esquecer") target:self action:@selector(esquecerEscolhida:)];

    for (NSView *v in @[self.modo, self.legenda, rolo, self.abrir, self.esquecer]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [fundo addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.modo.topAnchor constraintEqualToAnchor:fundo.topAnchor constant:14],
        [self.modo.leadingAnchor constraintEqualToAnchor:fundo.leadingAnchor constant:20],
        [self.legenda.centerYAnchor constraintEqualToAnchor:self.modo.centerYAnchor],
        [self.legenda.leadingAnchor constraintEqualToAnchor:self.modo.trailingAnchor constant:12],
        [self.legenda.trailingAnchor constraintLessThanOrEqualToAnchor:fundo.trailingAnchor constant:-20],
        [rolo.topAnchor constraintEqualToAnchor:self.modo.bottomAnchor constant:12],
        [rolo.leadingAnchor constraintEqualToAnchor:fundo.leadingAnchor constant:20],
        [rolo.trailingAnchor constraintEqualToAnchor:fundo.trailingAnchor constant:-20],
        [rolo.bottomAnchor constraintEqualToAnchor:self.abrir.topAnchor constant:-12],
        [self.abrir.trailingAnchor constraintEqualToAnchor:fundo.trailingAnchor constant:-20],
        [self.abrir.bottomAnchor constraintEqualToAnchor:fundo.bottomAnchor constant:-16],
        [self.esquecer.trailingAnchor constraintEqualToAnchor:self.abrir.leadingAnchor constant:-12],
        [self.esquecer.centerYAnchor constraintEqualToAnchor:self.abrir.centerYAnchor],
    ]];
    [self acertarBotoes];
}

- (void)mostrar {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self actualizar];
}

- (void)faixaEmCurso:(NSString *)semente nome:(NSString *)nome {
    BOOL mudou = !(semente == self.semente || [semente isEqualToString:self.semente]);
    self.semente = semente;
    self.nomeDaSemente = nome;
    if (mudou && self.window.visible && self.modo.selectedSegment == 0) [self actualizar];
}

- (void)refazerSeAVista {
    if (self.window.visible) [self actualizar];
}

// Pede a lista ao vectorizar, fora do thread principal (a base está no disco
// externo, que pode estar a dormir).
- (void)actualizar {
    BOOL pelaFaixa = self.modo.selectedSegment == 0 && self.semente.length > 0;
    if (self.modo.selectedSegment == 0) {
        self.legenda.stringValue = self.semente.length ? (self.nomeDaSemente ?: @"")
                                                       : NSLocalizedString(@"discoveries_nothing_playing", @"Não está nada a tocar: mostram-se todas.");
    } else {
        self.legenda.stringValue = @"";
    }
    NSMutableArray<NSString *> *args = [@[@"descobertas", self.mapa, self.base, @"-n", @"200"] mutableCopy];
    if (pelaFaixa) [args addObjectsFromArray:@[@"--semente", self.semente]];
    NSUInteger pedido = ++self.pedido;
    NSURL *vectorizar = self.vectorizar;
    __weak typeof(self) fraco = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NSArray<NSString *> *> *linhas = [NSMutableArray array];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = vectorizar;
        task.arguments = args;
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSPipe *saida = [NSPipe pipe];
        task.standardOutput = saida;
        if ([task launchAndReturnError:NULL]) {
            NSData *dados = [saida.fileHandleForReading readDataToEndOfFile];
            [task waitUntilExit];
            NSString *texto = [[NSString alloc] initWithData:dados encoding:NSUTF8StringEncoding] ?: @"";
            for (NSString *linha in [texto componentsSeparatedByString:@"\n"]) {
                NSArray<NSString *> *campos = [linha componentsSeparatedByString:@"\t"];
                if (campos.count >= ZPCampoQuantos) [linhas addObject:campos];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(fraco) forte = fraco;
            if (!forte || forte.pedido != pedido) return;
            forte.linhas = linhas;
            [forte.tabela reloadData];
            if (linhas.count == 0) forte.legenda.stringValue = NSLocalizedString(@"discoveries_empty", @"Ainda não há descobertas.");
            [forte acertarBotoes];
        });
    });
}

- (void)acertarBotoes {
    BOOL ha = self.tabela.selectedRow >= 0 && self.tabela.selectedRow < (NSInteger)self.linhas.count;
    self.abrir.enabled = ha;
    self.esquecer.enabled = ha;
}

#pragma mark Tabela

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.linhas.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)coluna row:(NSInteger)linha {
    NSTableCellView *celula = [tableView makeViewWithIdentifier:@"celula" owner:self];
    if (!celula) {
        celula = [[NSTableCellView alloc] initWithFrame:NSZeroRect];
        celula.identifier = @"celula";
        NSTextField *texto = [NSTextField labelWithString:@""];
        texto.lineBreakMode = NSLineBreakByTruncatingTail;
        texto.translatesAutoresizingMaskIntoConstraints = NO;
        [celula addSubview:texto];
        celula.textField = texto;
        [NSLayoutConstraint activateConstraints:@[
            [texto.leadingAnchor constraintEqualToAnchor:celula.leadingAnchor constant:2],
            [texto.trailingAnchor constraintEqualToAnchor:celula.trailingAnchor constant:-2],
            [texto.centerYAnchor constraintEqualToAnchor:celula.centerYAnchor],
        ]];
    }
    NSArray<NSString *> *campos = self.linhas[linha];
    NSUInteger campo = (NSUInteger)coluna.identifier.integerValue;
    NSString *valor = campos[campo];
    if (campo == ZPCampoLugar) {
        // Lugar 0: trazida por uma faixa sem assinatura, ainda por medir.
        valor = valor.integerValue > 0 ? [NSString stringWithFormat:NSLocalizedString(@"discoveries_rank_format", @"%ld.º"), (long)valor.integerValue] : @"—";
        celula.textField.alignment = NSTextAlignmentRight;
    } else {
        celula.textField.alignment = NSTextAlignmentNatural;
        if (campo == ZPCampoSemente) {
            // «Ana Moura — Desfado, via Carminho»: a faixa que a trouxe e o vizinho.
            NSString *vizinho = campos[ZPCampoVizinho];
            NSRange doisPontos = [vizinho rangeOfString:@":"];
            if (doisPontos.location != NSNotFound) vizinho = [vizinho substringFromIndex:NSMaxRange(doisPontos)];
            if (vizinho.length) valor = [NSString stringWithFormat:NSLocalizedString(@"discoveries_via_format", @"%@, via %@"), valor, vizinho];
        }
    }
    celula.textField.stringValue = valor ?: @"";
    celula.toolTip = valor;
    return celula;
}

- (void)tableViewSelectionDidChange:(NSNotification *)nota {
    [self acertarBotoes];
}

#pragma mark Acções

// O endereço da loja com «music:» em vez de «https:» abre a página da canção
// no Música, e não no navegador. Ele não a toca sozinho: ouve-se e junta-se à
// biblioteca lá.
- (void)abrirNoMusica:(id)sender {
    NSInteger linha = self.tabela.clickedRow >= 0 && sender == self.tabela ? self.tabela.clickedRow : self.tabela.selectedRow;
    if (linha < 0 || linha >= (NSInteger)self.linhas.count) return;
    NSURLComponents *c = [NSURLComponents componentsWithString:self.linhas[linha][ZPCampoEndereco]];
    if (![c.host isEqualToString:@"music.apple.com"]) return;
    c.scheme = @"music";
    if (c.URL) [[NSWorkspace sharedWorkspace] openURL:c.URL];
}

- (void)esquecerEscolhida:(id)sender {
    NSInteger linha = self.tabela.selectedRow;
    if (linha < 0 || linha >= (NSInteger)self.linhas.count) return;
    NSString *faixa = self.linhas[linha][ZPCampoId];
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = self.vectorizar;
    task.arguments = @[@"esquecer", self.mapa, faixa];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    __weak typeof(self) fraco = self;
    task.terminationHandler = ^(NSTask *acabou) {
        dispatch_async(dispatch_get_main_queue(), ^{ [fraco actualizar]; });
    };
    if (![task launchAndReturnError:NULL]) return;
    // Sai já da tabela; a lista refaz-se quando o vectorizar acabar.
    NSMutableArray *restantes = [self.linhas mutableCopy];
    [restantes removeObjectAtIndex:(NSUInteger)linha];
    self.linhas = restantes;
    [self.tabela reloadData];
    [self acertarBotoes];
}

@end
