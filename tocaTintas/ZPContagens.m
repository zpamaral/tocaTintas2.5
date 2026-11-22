//
//  ZPContagens.m
//  tocaTintas
//
//  A janela das audições: a vista audicoes_locais da fonoteca, numa tabela que
//  se relê sozinha enquanto estiver à vista.
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

@interface ZPContagens () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property (nonatomic, copy) NSString *base;
@property (nonatomic, strong) dispatch_queue_t fila;
@property (nonatomic, strong) NSTimer *relogio;
@property (nonatomic, copy, nullable) NSString *assinatura;   // data e tamanho da base e do -wal, na última leitura
@property (nonatomic) BOOL aLer;
@property (nonatomic, strong) NSArray<NSDictionary *> *todas;
@property (nonatomic, strong) NSArray<NSDictionary *> *visiveis;
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
    _todas = @[]; _visiveis = @[];
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

    for (NSView *x in @[self.filtro, rol, self.legenda]) {
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
        [self.legenda.topAnchor constraintEqualToAnchor:rol.bottomAnchor constant:6],
        [self.legenda.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:14],
        [self.legenda.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-14],
        [self.legenda.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-10],
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
            if (sqlite3_prepare_v2(db, "SELECT quando, artista, album, titulo, vezes, formato FROM audicoes_locais",
                                   -1, &s, NULL) == SQLITE_OK) {
                int r;
                while ((r = sqlite3_step(s)) == SQLITE_ROW) {
                    [linhas addObject:@{
                        @"quando":  ZPTextoDaColuna(s, 0),
                        @"artista": ZPTextoDaColuna(s, 1),
                        @"album":   ZPTextoDaColuna(s, 2),
                        @"titulo":  ZPTextoDaColuna(s, 3),
                        @"vezes":   @(sqlite3_column_int64(s, 4)),
                        @"formato": ZPTextoDaColuna(s, 5),
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

// A chave de uma linha, para manter a selecção e o sítio entre leituras.
static NSString *ZPChaveDaLinha(NSDictionary *l) {
    return [NSString stringWithFormat:@"%@\t%@\t%@\t%@", l[@"quando"], l[@"artista"], l[@"album"], l[@"titulo"]];
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
    [self aplicarFiltro];

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

- (void)aplicarFiltro {
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
    self.visiveis = [l sortedArrayUsingDescriptors:self.tabela.sortDescriptors];
    [self.tabela reloadData];
    [self actualizarLegenda];
}

- (void)actualizarLegenda {
    if (self.erro) { self.legenda.stringValue = self.erro; return; }
    self.legenda.stringValue = self.visiveis.count == self.todas.count
        ? [NSString localizedStringWithFormat:NSLocalizedString(@"counts_total", @"%lu audições"),
           (unsigned long)self.todas.count]
        : [NSString localizedStringWithFormat:NSLocalizedString(@"counts_filtered", @"%lu de %lu audições"),
           (unsigned long)self.visiveis.count, (unsigned long)self.todas.count];
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
