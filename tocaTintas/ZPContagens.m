//
//  ZPContagens.m
//  tocaTintas
//
//  A janela das audições: a última audição de cada música, como na vista
//  audicoes_locais da fonoteca, numa tabela que se relê sozinha enquanto
//  estiver à vista. Nada fica de fora; mostra-se em páginas de mil, e os
//  botões do rodapé andam uma página (‹ ›) ou dez (« »). Abre na página do
//  topo — a das mais recentes, com a ordem de origem —, onde « e ‹ ficam
//  desligados; na do fundo, são › e ».
//
//  A base não fica presa. Uma ligação aberta no SQLite, mesmo só para leitura,
//  segura uma transacção enquanto houver uma leitura a decorrer, e com o WAL
//  isso impede o checkpoint: o que o tocaTintas e o fonoteca.py escrevem fica no
//  -wal, que cresce enquanto o leitor não largar. É o que acontece com o DB
//  Browser aberto. Aqui cada leitura abre, lê tudo de uma vez e fecha; entre
//  duas leituras não há ligação nenhuma.
//
//  Para saber quando reler sem abrir a base, olha-se de dois em dois segundos
//  para a data e o tamanho da .fonoteca.sqlite e do -wal: uma audição nova
//  escreve no -wal, um checkpoint escreve na base. Só um stat, numa fila à
//  parte, porque a base está no disco externo e um disco a acordar não pode
//  parar a janela.
//

#import "ZPContagens.h"
#include <sqlite3.h>
#include <sys/stat.h>

static const NSTimeInterval kZPIntervaloDasContagens = 2.0;
static const NSUInteger kZPLinhasPorPagina = 1000;
static const NSUInteger kZPPaginasPorSalto = 10;

// A última audição de cada música, com as colunas da audicoes_locais. As
// «vezes» da última audição são o total da música (contagens.n), tal como na
// vista. A primeira coluna, a música, só serve para manter a selecção.
static const char *kZPConsultaDasContagens =
    "SELECT a.musica, datetime(a.quando, 'localtime'), m.artista, m.album, m.titulo, c.n,"
    "       CASE a.origem WHEN 'cd' THEN 'cd' WHEN 'musica' THEN 'música' ELSE COALESCE(f.formato, '?') END"
    " FROM (SELECT id, musica, quando, origem, ficheiro,"
    "              ROW_NUMBER() OVER (PARTITION BY musica ORDER BY quando DESC, id DESC) AS r"
    "       FROM audicoes) a"
    " JOIN musicas m ON m.id = a.musica"
    " JOIN contagens c ON c.musica = a.musica"
    " LEFT JOIN ficheiros f ON f.id = a.ficheiro"
    " WHERE a.r = 1";

typedef NS_ENUM(NSInteger, ZPSalto) { ZPSaltoDezParaCima = 0, ZPSaltoUmParaCima, ZPSaltoUmParaBaixo, ZPSaltoDezParaBaixo };

// As colunas: identificador (o nome na vista), título, largura.
static NSArray<NSArray *> *ZPColunasDasContagens(void) {
    return @[
        @[@"quando",  NSLocalizedString(@"counts_col_when",   @"Quando"),  @140],
        @[@"artista", NSLocalizedString(@"counts_col_artist", @"Artista"), @200],
        @[@"album",   NSLocalizedString(@"counts_col_album",  @"Álbum"),   @220],
        @[@"titulo",  NSLocalizedString(@"counts_col_title",  @"Título"),  @240],
        @[@"vezes",   NSLocalizedString(@"counts_col_times",  @"Vezes"),   @50],
        @[@"formato", NSLocalizedString(@"counts_col_format", @"Formato"), @70],
    ];
}

@interface ZPContagens () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate, NSMenuItemValidation>
@property (nonatomic, copy) NSString *base;
@property (nonatomic, strong) dispatch_queue_t fila;
@property (nonatomic, strong) NSTimer *relogio;
@property (nonatomic, copy, nullable) NSString *assinatura;   // data e tamanho da base e do -wal, na última leitura
@property (nonatomic) BOOL aLer;
@property (nonatomic, strong) NSArray<NSDictionary *> *todas;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtradas;   // todas as que passam o filtro, ordenadas
@property (nonatomic, strong) NSArray<NSDictionary *> *visiveis;    // a página à vista
@property (nonatomic) NSUInteger pagina;                            // 0 = a do topo
@property (nonatomic, strong) NSSegmentedControl *saltos;
@property (nonatomic, strong) NSSearchField *filtro;
@property (nonatomic, strong) NSTableView *tabela;
@property (nonatomic, strong) NSTextField *legenda;
@property (nonatomic, copy, nullable) NSString *erro;
@end

@implementation ZPContagens

- (instancetype)initComBase:(NSString *)base {
    NSWindow *janela = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 960, 560)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                             | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered defer:YES];
    self = [super initWithWindow:janela];
    if (!self) return nil;
    _base = [base copy];
    _fila = dispatch_queue_create("eu.zpsou.tocaTintas.contagens", DISPATCH_QUEUE_SERIAL);
    _todas = @[]; _filtradas = @[]; _visiveis = @[];
    janela.title = NSLocalizedString(@"counts_title", @"Contagens");
    janela.minSize = NSMakeSize(600, 300);
    janela.releasedWhenClosed = NO;
    janela.delegate = self;
    [janela center];
    janela.frameAutosaveName = @"ZPContagens";
    [self montar];
    return self;
}

#pragma mark - A janela

- (void)montar {
    NSView *v = self.window.contentView;

    self.filtro = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.filtro.placeholderString = NSLocalizedString(@"counts_filter", @"Filtrar");
    self.filtro.delegate = self;
    self.filtro.sendsSearchStringImmediately = YES;
    self.filtro.target = self;
    self.filtro.action = @selector(filtrar:);

    NSTableView *t = [[NSTableView alloc] initWithFrame:NSZeroRect];
    for (NSArray *c in ZPColunasDasContagens()) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1];
        col.width = [c[2] doubleValue];
        col.minWidth = 40;
        BOOL numero = [c[0] isEqualToString:@"vezes"];
        if (numero) col.headerCell.alignment = NSTextAlignmentRight;
        // A data vem como «AAAA-MM-DD HH:MM:SS», que ordena bem como texto.
        col.sortDescriptorPrototype = numero
            ? [NSSortDescriptor sortDescriptorWithKey:c[0] ascending:NO]
            : [NSSortDescriptor sortDescriptorWithKey:c[0] ascending:[c[0] isEqualToString:@"quando"] ? NO : YES
                                             selector:@selector(localizedStandardCompare:)];
        [t addTableColumn:col];
    }
    t.dataSource = self;
    t.delegate = self;
    t.usesAlternatingRowBackgroundColors = YES;
    t.allowsMultipleSelection = YES;
    t.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    t.autosaveName = @"ZPContagensColunas";
    t.autosaveTableColumns = YES;
    if (t.sortDescriptors.count == 0) {
        t.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"quando" ascending:NO
                                                             selector:@selector(localizedStandardCompare:)]];
    }
    self.tabela = t;

    NSScrollView *rol = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    rol.documentView = t;
    rol.hasVerticalScroller = YES;
    rol.hasHorizontalScroller = YES;
    rol.borderType = NSBezelBorder;

    self.legenda = [NSTextField labelWithString:@""];
    self.legenda.textColor = NSColor.secondaryLabelColor;
    self.legenda.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    self.legenda.lineBreakMode = NSLineBreakByTruncatingMiddle;

    NSArray<NSString *> *simbolos = @[@"chevron.left.2", @"chevron.left", @"chevron.right", @"chevron.right.2"];
    NSMutableArray<NSImage *> *imagens = [NSMutableArray array];
    for (NSString *n in simbolos) [imagens addObject:[NSImage imageWithSystemSymbolName:n accessibilityDescription:nil]];
    self.saltos = [NSSegmentedControl segmentedControlWithImages:imagens trackingMode:NSSegmentSwitchTrackingMomentary
                                                          target:self action:@selector(saltar:)];
    [self.saltos setToolTip:NSLocalizedString(@"counts_back_ten", @"Dez páginas para cima") forSegment:ZPSaltoDezParaCima];
    [self.saltos setToolTip:NSLocalizedString(@"counts_back_one", @"Uma página para cima") forSegment:ZPSaltoUmParaCima];
    [self.saltos setToolTip:NSLocalizedString(@"counts_forward_one", @"Uma página para baixo") forSegment:ZPSaltoUmParaBaixo];
    [self.saltos setToolTip:NSLocalizedString(@"counts_forward_ten", @"Dez páginas para baixo") forSegment:ZPSaltoDezParaBaixo];

    for (NSView *x in @[self.filtro, rol, self.legenda, self.saltos]) {
        x.translatesAutoresizingMaskIntoConstraints = NO;
        [v addSubview:x];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.filtro.topAnchor constraintEqualToAnchor:v.topAnchor constant:12],
        [self.filtro.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [self.filtro.widthAnchor constraintEqualToConstant:240],
        [rol.topAnchor constraintEqualToAnchor:self.filtro.bottomAnchor constant:10],
        [rol.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [rol.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [self.saltos.topAnchor constraintEqualToAnchor:rol.bottomAnchor constant:8],
        [self.saltos.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [self.saltos.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-10],
        [self.legenda.centerYAnchor constraintEqualToAnchor:self.saltos.centerYAnchor],
        [self.legenda.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [self.legenda.trailingAnchor constraintLessThanOrEqualToAnchor:self.saltos.leadingAnchor constant:-10],
    ]];
}

- (void)mostrar {
    [self.window makeKeyAndOrderFront:nil];
    self.assinatura = nil;   // relê sempre ao abrir
    [self verSeMudou];
    if (!self.relogio) {
        __weak typeof(self) fraco = self;
        self.relogio = [NSTimer scheduledTimerWithTimeInterval:kZPIntervaloDasContagens repeats:YES block:^(NSTimer *r) {
            [fraco verSeMudou];
        }];
        self.relogio.tolerance = 0.5;
    }
}

- (void)windowWillClose:(NSNotification *)nota {
    [self.relogio invalidate];
    self.relogio = nil;
}

#pragma mark - Ler

// Data de modificação e tamanho da base e do -wal. Sem a base, nil.
static NSString * _Nullable ZPAssinaturaDaBase(NSString *base) {
    struct stat b, w;
    if (stat(base.fileSystemRepresentation, &b) != 0) return nil;
    NSString *wal = [base stringByAppendingString:@"-wal"];
    BOOL temWal = stat(wal.fileSystemRepresentation, &w) == 0;
    return [NSString stringWithFormat:@"%ld.%ld:%lld|%ld.%ld:%lld",
            (long)b.st_mtimespec.tv_sec, b.st_mtimespec.tv_nsec, (long long)b.st_size,
            temWal ? (long)w.st_mtimespec.tv_sec : 0L, temWal ? w.st_mtimespec.tv_nsec : 0L,
            temWal ? (long long)w.st_size : 0LL];
}

static NSString *ZPTextoDaColuna(sqlite3_stmt *s, int i) {
    const unsigned char *t = sqlite3_column_text(s, i);
    return t ? @((const char *)t) : @"";
}

- (void)verSeMudou {
    if (self.aLer || !self.window.isVisible) return;
    self.aLer = YES;
    NSString *base = self.base, *anterior = self.assinatura;
    __weak typeof(self) fraco = self;
    dispatch_async(self.fila, ^{
        NSString *assinatura = ZPAssinaturaDaBase(base);
        if (assinatura && [assinatura isEqualToString:anterior]) {
            dispatch_async(dispatch_get_main_queue(), ^{ fraco.aLer = NO; });
            return;
        }
        NSMutableArray<NSDictionary *> *linhas = [NSMutableArray array];
        NSString *erro = nil;
        sqlite3 *db = NULL;
        if (!assinatura) {
            erro = NSLocalizedString(@"counts_no_database", @"A base da fonoteca não está acessível.");
        } else if (sqlite3_open_v2(base.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
            erro = @(sqlite3_errmsg(db));
        } else {
            sqlite3_busy_timeout(db, 2000);
            sqlite3_stmt *s = NULL;
            if (sqlite3_prepare_v2(db, kZPConsultaDasContagens, -1, &s, NULL) == SQLITE_OK) {
                int r;
                while ((r = sqlite3_step(s)) == SQLITE_ROW) {
                    [linhas addObject:@{
                        @"musica":  ZPTextoDaColuna(s, 0),
                        @"quando":  ZPTextoDaColuna(s, 1),
                        @"artista": ZPTextoDaColuna(s, 2),
                        @"album":   ZPTextoDaColuna(s, 3),
                        @"titulo":  ZPTextoDaColuna(s, 4),
                        @"vezes":   @(sqlite3_column_int64(s, 5)),
                        @"formato": ZPTextoDaColuna(s, 6),
                    }];
                }
                if (r != SQLITE_DONE) erro = @(sqlite3_errmsg(db));
            } else {
                erro = @(sqlite3_errmsg(db));
            }
            sqlite3_finalize(s);
        }
        sqlite3_close(db);   // fecha sempre: entre leituras, a base não tem ligação nossa
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(fraco) forte = fraco;
            if (!forte) return;
            forte.aLer = NO;
            forte.erro = erro;
            if (erro) {
                // Lê outra vez no próximo tique (uma escrita a meio, o disco a montar).
                forte.assinatura = nil;
                [forte actualizarLegenda];
                return;
            }
            forte.assinatura = assinatura;
            [forte adoptar:linhas];
        });
    });
}

#pragma mark - Mostrar

// A chave de uma linha, para manter a selecção e o sítio entre leituras: a
// música, que é uma linha só, mesmo quando volta a tocar e muda de sítio.
static NSString *ZPChaveDaLinha(NSDictionary *l) {
    return l[@"musica"];
}

- (void)adoptar:(NSArray<NSDictionary *> *)linhas {
    // O que estava seleccionado e a linha do topo, antes de mudar.
    NSMutableSet<NSString *> *seleccionadas = [NSMutableSet set];
    [self.tabela.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *parar) {
        if (i < self.visiveis.count) [seleccionadas addObject:ZPChaveDaLinha(self.visiveis[i])];
    }];
    NSRect vista = self.tabela.enclosingScrollView.contentView.bounds;
    NSInteger topo = [self.tabela rowAtPoint:NSMakePoint(0, NSMinY(vista) + self.tabela.headerView.frame.size.height + 1)];
    NSString *chaveDoTopo = (topo > 0 && topo < (NSInteger)self.visiveis.count) ? ZPChaveDaLinha(self.visiveis[topo]) : nil;

    self.todas = linhas;
    [self aplicarFiltroNaPagina:self.pagina];

    NSMutableIndexSet *indices = [NSMutableIndexSet indexSet];
    NSInteger novoTopo = -1;
    for (NSUInteger i = 0; i < self.visiveis.count; i++) {
        NSString *k = ZPChaveDaLinha(self.visiveis[i]);
        if ([seleccionadas containsObject:k]) [indices addIndex:i];
        if (chaveDoTopo && novoTopo < 0 && [k isEqualToString:chaveDoTopo]) novoTopo = (NSInteger)i;
    }
    [self.tabela selectRowIndexes:indices byExtendingSelection:NO];
    // No topo, fica no topo e as audições novas aparecem; mais abaixo, fica onde estava.
    if (novoTopo > 0) {
        NSRect linha = [self.tabela rectOfRow:novoTopo];
        [self.tabela scrollPoint:NSMakePoint(NSMinX(vista), NSMinY(linha) - self.tabela.headerView.frame.size.height)];
    } else if (!chaveDoTopo) {
        [self.tabela scrollRowToVisible:0];
    }
}

// Volta à página do topo: um filtro ou uma ordem nova são outra lista.
- (void)aplicarFiltro {
    [self aplicarFiltroNaPagina:0];
}

- (void)aplicarFiltroNaPagina:(NSUInteger)pagina {
    NSString *f = [self.filtro.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray<NSDictionary *> *l = self.todas;
    if (f.length) {
        NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        l = [l filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *x, NSDictionary *b) {
            for (NSString *k in @[@"artista", @"album", @"titulo", @"formato", @"quando"]) {
                if ([x[k] rangeOfString:f options:o].location != NSNotFound) return YES;
            }
            return NO;
        }]];
    }
    self.filtradas = [l sortedArrayUsingDescriptors:self.tabela.sortDescriptors];
    [self mostrarPagina:pagina];
}

- (NSUInteger)paginas {
    return MAX((NSUInteger)1, (self.filtradas.count + kZPLinhasPorPagina - 1) / kZPLinhasPorPagina);
}

- (void)mostrarPagina:(NSUInteger)pagina {
    self.pagina = MIN(pagina, self.paginas - 1);
    NSUInteger inicio = self.pagina * kZPLinhasPorPagina;
    NSUInteger quantas = MIN(kZPLinhasPorPagina, self.filtradas.count - MIN(inicio, self.filtradas.count));
    self.visiveis = [self.filtradas subarrayWithRange:NSMakeRange(MIN(inicio, self.filtradas.count), quantas)];
    [self.tabela reloadData];
    BOOL noTopo = self.pagina == 0, noFundo = self.pagina + 1 >= self.paginas;
    [self.saltos setEnabled:!noTopo forSegment:ZPSaltoDezParaCima];
    [self.saltos setEnabled:!noTopo forSegment:ZPSaltoUmParaCima];
    [self.saltos setEnabled:!noFundo forSegment:ZPSaltoUmParaBaixo];
    [self.saltos setEnabled:!noFundo forSegment:ZPSaltoDezParaBaixo];
    [self actualizarLegenda];
}

// Dez páginas de uma vez param na primeira ou na última, se não houver tantas.
- (void)saltar:(NSSegmentedControl *)sender {
    NSInteger p = (NSInteger)self.pagina;
    switch (sender.selectedSegment) {
        case ZPSaltoDezParaCima:  p -= (NSInteger)kZPPaginasPorSalto; break;
        case ZPSaltoUmParaCima:   p -= 1; break;
        case ZPSaltoUmParaBaixo:  p += 1; break;
        case ZPSaltoDezParaBaixo: p += (NSInteger)kZPPaginasPorSalto; break;
        default: return;
    }
    [self.tabela deselectAll:nil];
    [self mostrarPagina:(NSUInteger)MAX(0, MIN(p, (NSInteger)self.paginas - 1))];
    [self.tabela scrollRowToVisible:0];
}

- (void)actualizarLegenda {
    if (self.erro) { self.legenda.stringValue = self.erro; return; }
    unsigned long n = self.filtradas.count, de = self.pagina * kZPLinhasPorPagina + 1;
    unsigned long ate = de + self.visiveis.count - 1;
    if (n == 0) {
        self.legenda.stringValue = NSLocalizedString(@"counts_none", @"Nenhuma música");
    } else if (n == self.todas.count) {
        self.legenda.stringValue = [NSString localizedStringWithFormat:
            NSLocalizedString(@"counts_range", @"%1$lu–%2$lu de %3$lu músicas"), de, ate, n];
    } else {
        self.legenda.stringValue = [NSString localizedStringWithFormat:
            NSLocalizedString(@"counts_range_filtered", @"%1$lu–%2$lu de %3$lu músicas (filtradas de %4$lu)"),
            de, ate, n, (unsigned long)self.todas.count];
    }
}

- (void)filtrar:(id)sender {
    [self aplicarFiltro];
}

- (void)controlTextDidChange:(NSNotification *)nota {
    [self aplicarFiltro];
}

#pragma mark - Tabela

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    return (NSInteger)self.visiveis.count;
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)coluna row:(NSInteger)linha {
    NSTextField *c = [t makeViewWithIdentifier:coluna.identifier owner:self];
    BOOL numero = [coluna.identifier isEqualToString:@"vezes"];
    if (!c) {
        c = [NSTextField labelWithString:@""];
        c.identifier = coluna.identifier;
        c.lineBreakMode = NSLineBreakByTruncatingTail;
        if (numero) {
            c.alignment = NSTextAlignmentRight;
            c.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        }
    }
    id valor = self.visiveis[(NSUInteger)linha][coluna.identifier];
    c.stringValue = numero ? [valor stringValue] : (valor ?: @"");
    c.toolTip = numero ? nil : c.stringValue;
    return c;
}

- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)antigos {
    [self aplicarFiltro];
}

// ⌘C: as linhas seleccionadas, separadas por tabulações, pela ordem das colunas.
- (void)copy:(id)sender {
    NSIndexSet *sel = self.tabela.selectedRowIndexes;
    if (sel.count == 0) return;
    NSArray<NSTableColumn *> *colunas = self.tabela.tableColumns;
    NSMutableString *texto = [NSMutableString string];
    [sel enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *parar) {
        if (i >= self.visiveis.count) return;
        NSMutableArray *campos = [NSMutableArray array];
        for (NSTableColumn *c in colunas) [campos addObject:[self.visiveis[i][c.identifier] description] ?: @""];
        [texto appendFormat:@"%@\n", [campos componentsJoinedByString:@"\t"]];
    }];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:texto forType:NSPasteboardTypeString];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(copy:)) return self.tabela.selectedRowIndexes.count > 0;
    return YES;
}

@end
