//
//  ZPDescobertas.m
//  tocaTintas
//

#import "ZPDescobertas.h"

// Os campos de cada linha, como a fonte os dá.
typedef NS_ENUM(NSUInteger, ZPCampo) { ZPCampoChave, ZPCampoArtista, ZPCampoTitulo, ZPCampoAlbum, ZPCampoMarcada, ZPCampoQuantos };

static NSPasteboardType const ZPTipoDaLinha = @"JPSdA.tocaTintas.linha-da-fila";

@interface ZPDescobertas () <NSTableViewDataSource, NSTableViewDelegate>
@property (nonatomic, weak) id<ZPFonteDaEstacao> fonte;
@property (nonatomic, strong) NSMutableArray<NSMutableArray<NSString *> *> *linhas;
@property (nonatomic, strong) NSTableView *tabela;
@property (nonatomic, strong) NSTextField *legenda;
@end

@implementation ZPDescobertas

- (instancetype)initComFonte:(id<ZPFonteDaEstacao>)fonte {
    NSWindow *janela = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, 440)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered defer:YES];
    if (!(self = [super initWithWindow:janela])) return nil;
    _fonte = fonte;
    _linhas = [NSMutableArray array];
    janela.title = NSLocalizedString(@"up_next_title", @"A seguir");
    janela.minSize = NSMakeSize(420, 200);
    janela.releasedWhenClosed = NO;
    [janela center];
    janela.frameAutosaveName = @"ZPASeguir";
    [self montar];
    return self;
}

- (void)montar {
    NSView *fundo = self.window.contentView;

    self.legenda = [NSTextField labelWithString:@""];
    self.legenda.textColor = NSColor.secondaryLabelColor;
    self.legenda.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.legenda setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.tabela = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tabela.dataSource = self;
    self.tabela.delegate = self;
    self.tabela.usesAlternatingRowBackgroundColors = YES;
    self.tabela.allowsMultipleSelection = NO;
    self.tabela.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    [self.tabela registerForDraggedTypes:@[ZPTipoDaLinha]];
    [self.tabela setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    NSArray<NSArray *> *colunas = @[
        @[@(ZPCampoMarcada), @"",                                              @24.0],
        @[@(ZPCampoArtista), NSLocalizedString(@"up_next_artist", @"Artista"), @170.0],
        @[@(ZPCampoTitulo),  NSLocalizedString(@"up_next_song", @"Título"),    @220.0],
        @[@(ZPCampoAlbum),   NSLocalizedString(@"up_next_album", @"Álbum"),    @170.0],
    ];
    for (NSArray *c in colunas) {
        NSTableColumn *coluna = [[NSTableColumn alloc] initWithIdentifier:[c[0] stringValue]];
        coluna.title = c[1];
        coluna.width = [c[2] doubleValue];
        if ([c[0] unsignedIntegerValue] == ZPCampoMarcada) { coluna.minWidth = coluna.maxWidth = 24; }
        else coluna.minWidth = 60;
        [self.tabela addTableColumn:coluna];
    }
    NSScrollView *rolo = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    rolo.documentView = self.tabela;
    rolo.hasVerticalScroller = YES;
    rolo.borderType = NSBezelBorder;

    for (NSView *v in @[self.legenda, rolo]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [fundo addSubview:v];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.legenda.topAnchor constraintEqualToAnchor:fundo.topAnchor constant:12],
        [self.legenda.leadingAnchor constraintEqualToAnchor:fundo.leadingAnchor constant:20],
        [self.legenda.trailingAnchor constraintLessThanOrEqualToAnchor:fundo.trailingAnchor constant:-20],
        [rolo.topAnchor constraintEqualToAnchor:self.legenda.bottomAnchor constant:8],
        [rolo.leadingAnchor constraintEqualToAnchor:fundo.leadingAnchor constant:20],
        [rolo.trailingAnchor constraintEqualToAnchor:fundo.trailingAnchor constant:-20],
        [rolo.bottomAnchor constraintEqualToAnchor:fundo.bottomAnchor constant:-20],
    ]];
}

- (void)mostrar {
    [self showWindow:nil];
    [self.window makeKeyAndOrderFront:nil];
    [self actualizar];
}

- (void)refazerSeAVista {
    if (self.window.visible) [self actualizar];
}

- (void)actualizar {
    NSArray<NSArray<NSString *> *> *fila = [self.fonte proximasDaEstacao];
    NSMutableArray *linhas = [NSMutableArray array];
    for (NSArray<NSString *> *f in fila) if (f.count >= ZPCampoQuantos) [linhas addObject:[f mutableCopy]];
    self.linhas = linhas;
    [self.tabela reloadData];
    self.legenda.stringValue = !fila ? NSLocalizedString(@"up_next_no_station", @"Não há estação a tocar.")
                             : linhas.count ? NSLocalizedString(@"up_next_hint", @"Desmarque as que não quer ouvir; arraste para mudar a ordem.")
                                            : NSLocalizedString(@"up_next_ended", @"A estação não tem mais faixas.");
}

// A fila, como está na tabela, vai para a fonte.
- (void)entregar { [self entregarComASubir:nil aDescer:nil]; }

- (void)entregarComASubir:(NSString *)subiu aDescer:(NSString *)desceu {
    NSMutableArray<NSString *> *chaves = [NSMutableArray array];
    NSMutableSet<NSString *> *desmarcadas = [NSMutableSet set];
    for (NSArray<NSString *> *l in self.linhas) {
        [chaves addObject:l[ZPCampoChave]];
        if (![l[ZPCampoMarcada] isEqualToString:@"1"]) [desmarcadas addObject:l[ZPCampoChave]];
    }
    [self.fonte filaDaEstacaoPassaASer:chaves desmarcadas:desmarcadas subiu:subiu desceu:desceu];
}

#pragma mark Tabela

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return (NSInteger)self.linhas.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)coluna row:(NSInteger)linha {
    NSArray<NSString *> *campos = self.linhas[linha];
    NSUInteger campo = (NSUInteger)coluna.identifier.integerValue;
    BOOL marcada = [campos[ZPCampoMarcada] isEqualToString:@"1"];
    if (campo == ZPCampoMarcada) {
        NSButton *caixa = [tableView makeViewWithIdentifier:@"caixa" owner:self];
        if (!caixa) {
            caixa = [NSButton checkboxWithTitle:@"" target:self action:@selector(marcar:)];
            caixa.identifier = @"caixa";
        }
        caixa.state = marcada ? NSControlStateValueOn : NSControlStateValueOff;
        return caixa;
    }
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
    celula.textField.stringValue = campos[campo] ?: @"";
    // Uma faixa desmarcada fica à vista, apagada.
    celula.textField.textColor = marcada ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    celula.toolTip = campos[campo];
    return celula;
}

- (void)marcar:(NSButton *)caixa {
    NSInteger linha = [self.tabela rowForView:caixa];
    if (linha < 0 || linha >= (NSInteger)self.linhas.count) return;
    self.linhas[linha][ZPCampoMarcada] = caixa.state == NSControlStateValueOn ? @"1" : @"0";
    [self.tabela reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)linha]
                           columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)self.tabela.numberOfColumns)]];
    [self entregar];
}

#pragma mark Arrastar

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)linha {
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    [item setString:[NSString stringWithFormat:@"%ld", (long)linha] forType:ZPTipoDaLinha];
    return item;
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)linha
       proposedDropOperation:(NSTableViewDropOperation)operacao {
    if (info.draggingSource != tableView) return NSDragOperationNone;
    // Só entre linhas, nunca para cima de uma.
    if (operacao == NSTableViewDropOn) [tableView setDropRow:linha dropOperation:NSTableViewDropAbove];
    return NSDragOperationMove;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)destino
    dropOperation:(NSTableViewDropOperation)operacao {
    NSString *texto = [info.draggingPasteboard stringForType:ZPTipoDaLinha];
    if (!texto) return NO;
    NSInteger origem = texto.integerValue;
    if (origem < 0 || origem >= (NSInteger)self.linhas.count || destino < 0 || destino > (NSInteger)self.linhas.count) return NO;
    if (destino == origem || destino == origem + 1) return NO;   // ficava onde estava
    NSMutableArray<NSString *> *movida = self.linhas[origem];
    [self.linhas removeObjectAtIndex:(NSUInteger)origem];
    NSInteger onde = destino > origem ? destino - 1 : destino;
    [self.linhas insertObject:movida atIndex:(NSUInteger)onde];
    [tableView reloadData];
    [tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)onde] byExtendingSelection:NO];
    NSString *chave = movida[ZPCampoChave];
    [self entregarComASubir:(onde < origem ? chave : nil) aDescer:(onde > origem ? chave : nil)];
    return YES;
}

@end
