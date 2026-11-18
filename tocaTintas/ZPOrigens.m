//
//  ZPOrigens.m
//  tocaTintas
//
//  A janela das regras de origem das estações. O ficheiro é o mesmo que se
//  pode editar à mão (origens.json, na pasta de dados da aplicação):
//      { "_leia": "…",
//        "origens":  { "Fado": ["Fado", "Fado de Coimbra"], … },
//        "artistas": { "Sérgio Godinho": ["Portuguesa", "Brasileira", …], … } }
//  Uma semente com regra só leva faixas das etiquetas marcadas; sem regra, a
//  estação não tem limite de origem.
//

#import "ZPOrigens.h"
#include <sqlite3.h>

typedef NS_ENUM(NSInteger, ZPLado) { ZPLadoOrigens = 0, ZPLadoArtistas = 1, ZPLadoArtistasDoMusica = 2, ZPLadoGenerosDoMusica = 3 };

static NSString *const ZPLeia =
    @"Regras de origem das estações. «origens»: o que uma semente com essa etiqueta GENRE admite. "
     "«artistas»: excepções, que mandam sobre a origem. «generosDoMusica»: a origem das faixas do Música pelo género "
     "que ele lhes dá, quando o artista não tem ficheiros. «artistasDoMusica»: a origem dada à mão a um artista do Música "
     "(vazio: nenhuma). Edita-se também em Reprodução ▸ Origens…";

// A chave de um artista, como a do vectorizar (ZPChaveDoArtista): o primeiro,
// sem maiúsculas nem acentos.
static NSString *ZPChaveDoArtistaDasOrigens(NSString *a) {
    NSString *p = [[a ?: @"" componentsSeparatedByString:@";"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return [p stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
}

@interface ZPOrigens () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSSearchFieldDelegate>
@property (nonatomic, copy) NSString *base;
@property (nonatomic, copy) NSString *caminhoDasRegras;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *origens;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *artistas;
@property (nonatomic, copy) NSString *leia;
@property (nonatomic, copy) NSString *mapa;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *generosDoMusica;    // género do Música → origem
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *artistasDoMusica;   // artista do Música → origem («» = nenhuma)
@property (nonatomic, strong) NSArray<NSArray *> *artistasSoNoMusica;   // (artista, género mais frequente, faixas)
@property (nonatomic, strong) NSArray<NSArray *> *generosNoMusica;      // (género, faixas)
@property (nonatomic, strong) NSArray<NSArray *> *linhasDoMusica;       // as do separador à vista
@property (nonatomic, strong) NSArray<NSArray *> *linhasVisiveis;       // as que passam o filtro
@property (nonatomic, strong) NSTableView *lista;                       // a tabela dos dois separadores do Música
@property (nonatomic, strong) NSScrollView *rolLista;
@property (nonatomic, strong) NSScrollView *rolSementes;
@property (nonatomic, strong) NSScrollView *rolEtiquetas;
@property (nonatomic, strong) NSArray<NSArray *> *generos;          // (etiqueta, faixas), da mais frequente para a menos
@property (nonatomic, strong) NSArray<NSArray *> *generosVisiveis;  // os que passam o filtro
@property (nonatomic, strong) NSArray<NSString *> *nomesDosArtistas; // os da fonoteca, para escolher uma excepção
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *origemDoArtista;   // a etiqueta mais frequente de cada um

@property (nonatomic, strong) NSSegmentedControl *lado;
@property (nonatomic, strong) NSTableView *sementes;
@property (nonatomic, strong) NSSegmentedControl *maisMenos;
@property (nonatomic, strong) NSSearchField *filtro;
@property (nonatomic, strong) NSTableView *etiquetas;
@property (nonatomic, strong) NSTextField *legenda;
@end

// A ordem escolhida na tabela das etiquetas: (coluna, ascendente).
static NSString * const kZPOrdemDasEtiquetas = @"ZPOrigensOrdemDasEtiquetas";

@implementation ZPOrigens

- (instancetype)initComBase:(NSString *)base mapa:(NSString *)mapa regras:(NSString *)regras {
    NSWindow *janela = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 520)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                             | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered defer:YES];
    self = [super initWithWindow:janela];
    if (!self) return nil;
    _base = [base copy];
    _caminhoDasRegras = [regras copy];
    _mapa = [mapa copy];
    _generosDoMusica = [NSMutableDictionary dictionary];
    _artistasDoMusica = [NSMutableDictionary dictionary];
    _linhasDoMusica = @[]; _linhasVisiveis = @[];
    _origens = [NSMutableDictionary dictionary];
    _artistas = [NSMutableDictionary dictionary];
    _generos = @[]; _generosVisiveis = @[]; _nomesDosArtistas = @[]; _origemDoArtista = @{};
    janela.title = NSLocalizedString(@"origins_title", @"Origens das estações");
    janela.minSize = NSMakeSize(720, 360);
    janela.releasedWhenClosed = NO;
    janela.delegate = self;
    [janela center];
    janela.frameAutosaveName = @"ZPOrigens";
    [self montar];
    return self;
}

#pragma mark - A janela

- (NSTableView *)tabelaComColunas:(NSArray<NSArray *> *)colunas {
    NSTableView *t = [[NSTableView alloc] initWithFrame:NSZeroRect];
    for (NSArray *c in colunas) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1];
        col.width = [c[2] doubleValue];
        if ([c[0] isEqualToString:@"marca"]) { col.minWidth = col.maxWidth = 24; } else col.minWidth = 40;
        [t addTableColumn:col];
    }
    t.dataSource = self;
    t.delegate = self;
    t.usesAlternatingRowBackgroundColors = YES;
    t.allowsMultipleSelection = NO;
    t.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    return t;
}

- (NSScrollView *)rolar:(NSTableView *)t {
    NSScrollView *s = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    s.documentView = t;
    s.hasVerticalScroller = YES;
    s.borderType = NSBezelBorder;
    return s;
}

- (void)montar {
    NSView *v = self.window.contentView;

    self.lado = [NSSegmentedControl segmentedControlWithLabels:@[NSLocalizedString(@"origins_tab_origins", @"Origens"),
                                                                 NSLocalizedString(@"origins_tab_artists", @"Artistas"),
                                                                 NSLocalizedString(@"origins_tab_music_artists", @"Artistas do Música"),
                                                                 NSLocalizedString(@"origins_tab_music_genres", @"Géneros do Música")]
                                                  trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(mudarDeLado:)];
    self.lado.selectedSegment = ZPLadoOrigens;

    self.sementes = [self tabelaComColunas:@[@[@"semente", NSLocalizedString(@"origins_col_seed", @"Semente"), @180]]];
    self.sementes.allowsEmptySelection = NO;
    NSScrollView *rolSementes = [self rolar:self.sementes];
    self.rolSementes = rolSementes;

    self.maisMenos = [NSSegmentedControl segmentedControlWithImages:@[[NSImage imageNamed:NSImageNameAddTemplate],
                                                                      [NSImage imageNamed:NSImageNameRemoveTemplate]]
                                                       trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(maisOuMenos:)];
    self.maisMenos.segmentStyle = NSSegmentStyleSmallSquare;

    self.filtro = [[NSSearchField alloc] init];
    self.filtro.placeholderString = NSLocalizedString(@"origins_filter", @"Filtrar etiquetas");
    self.filtro.delegate = self;

    self.etiquetas = [self tabelaComColunas:@[@[@"marca", @"", @24],
                                              @[@"genero", NSLocalizedString(@"origins_col_genre", @"Etiqueta GENRE"), @200],
                                              @[@"faixas", NSLocalizedString(@"origins_col_tracks", @"Faixas"), @60]]];
    // Carregar no cabeçalho ordena: a etiqueta por nome, as faixas da mais
    // frequente para a menos (o primeiro clique); outro clique inverte. A
    // escolha fica lembrada.
    [self.etiquetas tableColumnWithIdentifier:@"genero"].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"genero" ascending:YES];
    [self.etiquetas tableColumnWithIdentifier:@"faixas"].sortDescriptorPrototype =
        [NSSortDescriptor sortDescriptorWithKey:@"faixas" ascending:NO];
    NSArray *lembrada = [[NSUserDefaults standardUserDefaults] arrayForKey:kZPOrdemDasEtiquetas];
    if (lembrada.count == 2 && [@[@"genero", @"faixas"] containsObject:lembrada[0]]) {
        self.etiquetas.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:lembrada[0] ascending:[lembrada[1] boolValue]]];
    } else {
        self.etiquetas.sortDescriptors = @[[NSSortDescriptor sortDescriptorWithKey:@"faixas" ascending:NO]];
    }
    NSScrollView *rolEtiquetas = [self rolar:self.etiquetas];
    self.rolEtiquetas = rolEtiquetas;
    self.lista = [self tabelaComColunas:@[@[@"nome", NSLocalizedString(@"origins_col_name", @"Artista"), @200],
                                          @[@"generoMusica", NSLocalizedString(@"origins_col_music_genre", @"Género no Música"), @140],
                                          @[@"faixas", NSLocalizedString(@"origins_col_tracks", @"Faixas"), @50],
                                          @[@"origem", NSLocalizedString(@"origins_col_origin", @"Origem"), @200]]];
    self.lista.rowHeight = 24;
    self.rolLista = [self rolar:self.lista];
    self.rolLista.hidden = YES;

    self.legenda = [NSTextField wrappingLabelWithString:@""];
    self.legenda.textColor = NSColor.secondaryLabelColor;
    [self.legenda setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    for (NSView *x in @[self.lado, rolSementes, self.maisMenos, self.filtro, rolEtiquetas, self.rolLista, self.legenda]) {
        x.translatesAutoresizingMaskIntoConstraints = NO;
        [v addSubview:x];
    }
    CGFloat m = 16;
    [NSLayoutConstraint activateConstraints:@[
        [self.lado.topAnchor constraintEqualToAnchor:v.topAnchor constant:m],
        [self.lado.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [rolSementes.topAnchor constraintEqualToAnchor:self.lado.bottomAnchor constant:8],
        [rolSementes.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [rolSementes.widthAnchor constraintEqualToConstant:200],
        [rolSementes.bottomAnchor constraintEqualToAnchor:self.maisMenos.topAnchor constant:-1],
        [self.maisMenos.leadingAnchor constraintEqualToAnchor:rolSementes.leadingAnchor],
        [self.maisMenos.bottomAnchor constraintEqualToAnchor:self.legenda.topAnchor constant:-12],
        [self.filtro.centerYAnchor constraintEqualToAnchor:self.lado.centerYAnchor],
        [self.filtro.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.lado.trailingAnchor constant:m],
        [self.filtro.widthAnchor constraintGreaterThanOrEqualToConstant:160],
        [self.filtro.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [rolEtiquetas.topAnchor constraintEqualToAnchor:rolSementes.topAnchor],
        [rolEtiquetas.leadingAnchor constraintEqualToAnchor:rolSementes.trailingAnchor constant:m],
        [rolEtiquetas.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [rolEtiquetas.bottomAnchor constraintEqualToAnchor:self.maisMenos.bottomAnchor],
        [self.rolLista.topAnchor constraintEqualToAnchor:rolSementes.topAnchor],
        [self.rolLista.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [self.rolLista.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [self.rolLista.bottomAnchor constraintEqualToAnchor:self.maisMenos.bottomAnchor],
        [self.legenda.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [self.legenda.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [self.legenda.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-m],
    ]];
}

- (void)mostrar {
    [self ler];
    [self.window makeKeyAndOrderFront:nil];
}

#pragma mark - Ler e gravar

static NSString *ZPPrimeiroArtista(NSString *a) {
    NSString *p = [[a ?: @"" componentsSeparatedByString:@";"].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    // «Sérgio Godinho com Caetano Veloso» é do Sérgio Godinho.
    NSRange com = [p rangeOfString:@" com "];
    return com.location != NSNotFound ? [p substringToIndex:com.location] : p;
}

- (void)ler {
    // As regras.
    [self.origens removeAllObjects];
    [self.artistas removeAllObjects];
    [self.generosDoMusica removeAllObjects];
    [self.artistasDoMusica removeAllObjects];
    self.leia = ZPLeia;
    NSData *dados = [NSData dataWithContentsOfFile:self.caminhoDasRegras];
    NSDictionary *j = dados ? [NSJSONSerialization JSONObjectWithData:dados options:0 error:NULL] : nil;
    if ([j isKindOfClass:[NSDictionary class]]) {
        for (NSString *grupo in @[@"generosDoMusica", @"artistasDoMusica"]) {
            NSDictionary *d = [j[grupo] isKindOfClass:[NSDictionary class]] ? j[grupo] : @{};
            for (NSString *k in d) if ([d[k] isKindOfClass:[NSString class]])
                ([grupo isEqualToString:@"generosDoMusica"] ? self.generosDoMusica : self.artistasDoMusica)[k] = d[k];
        }
        for (NSString *grupo in @[@"origens", @"artistas"]) {
            NSDictionary *d = [j[grupo] isKindOfClass:[NSDictionary class]] ? j[grupo] : @{};
            for (NSString *k in d) {
                if (![d[k] isKindOfClass:[NSArray class]]) continue;
                NSMutableArray *l = [NSMutableArray array];
                for (id x in d[k]) if ([x isKindOfClass:[NSString class]]) [l addObject:x];
                ([grupo isEqualToString:@"origens"] ? self.origens : self.artistas)[k] = l;
            }
        }
    } else if (dados) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = NSLocalizedString(@"origins_bad_file", @"O ficheiro das regras não se deixa ler.");
        a.informativeText = self.caminhoDasRegras.stringByAbbreviatingWithTildeInPath;
        a.alertStyle = NSAlertStyleWarning;
        [a runModal];
    }
    // As etiquetas e os artistas da fonoteca.
    NSMutableArray *generos = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSCountedSet *> *porArtista = [NSMutableDictionary dictionary];
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.base.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(db, 5000);
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, "SELECT genero, COUNT(*) FROM generos WHERE genero <> '' GROUP BY genero ORDER BY 2 DESC, 1",
                               -1, &s, NULL) == SQLITE_OK) {
            while (sqlite3_step(s) == SQLITE_ROW) {
                [generos addObject:@[@((const char *)sqlite3_column_text(s, 0)), @(sqlite3_column_int(s, 1))]];
            }
        }
        sqlite3_finalize(s);
        if (sqlite3_prepare_v2(db, "SELECT m.artista, g.genero, COUNT(*) FROM ficheiros f JOIN musicas m ON m.id = f.musica"
                                   " LEFT JOIN generos g ON g.caminho = f.caminho WHERE f.caminho IS NOT NULL GROUP BY 1, 2",
                               -1, &s, NULL) == SQLITE_OK) {
            while (sqlite3_step(s) == SQLITE_ROW) {
                if (sqlite3_column_type(s, 0) == SQLITE_NULL) continue;
                NSString *a = ZPPrimeiroArtista(@((const char *)sqlite3_column_text(s, 0)));
                if (a.length == 0 || [@[@"Vários", @"Various", @"Various Artists"] containsObject:a]) continue;
                if (!porArtista[a]) porArtista[a] = [NSCountedSet set];
                if (sqlite3_column_type(s, 1) != SQLITE_NULL && sqlite3_column_bytes(s, 1) > 0) {
                    NSString *g = @((const char *)sqlite3_column_text(s, 1));
                    for (int i = 0; i < sqlite3_column_int(s, 2); ++i) [porArtista[a] addObject:g];
                }
            }
        }
        sqlite3_finalize(s);
    }
    sqlite3_close(db);
    self.generos = generos;
    NSMutableDictionary *origemDoArtista = [NSMutableDictionary dictionary];
    for (NSString *a in porArtista) {
        NSString *melhor = nil;
        for (NSString *g in porArtista[a]) if (!melhor || [porArtista[a] countForObject:g] > [porArtista[a] countForObject:melhor]) melhor = g;
        if (melhor) origemDoArtista[a] = melhor;
    }
    self.origemDoArtista = origemDoArtista;
    self.nomesDosArtistas = [porArtista.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSMutableSet<NSString *> *comFicheiros = [NSMutableSet set];
    for (NSString *a in porArtista) [comFicheiros addObject:ZPChaveDoArtistaDasOrigens(a)];
    [self lerOMapa:comFicheiros];
    [self aplicarFiltro];
    [self refazerAsSementes:nil];
}

// As faixas do Música no mapa do catálogo: os artistas que não têm ficheiros
// (com o género mais frequente e quantas faixas), e os géneros que o Música dá.
- (void)lerOMapa:(NSSet<NSString *> *)comFicheiros {
    NSMutableDictionary<NSString *, NSMutableArray *> *artistas = [NSMutableDictionary dictionary];   // nome → (contagens de género, faixas)
    NSMutableDictionary<NSString *, NSNumber *> *generos = [NSMutableDictionary dictionary];
    sqlite3 *db = NULL;
    if (self.mapa && sqlite3_open_v2(self.mapa.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(db, 5000);
        sqlite3_stmt *s = NULL;
        if (sqlite3_prepare_v2(db, "SELECT artista, COALESCE(genero, ''), COUNT(*) FROM faixas WHERE pid IS NOT NULL"
                                   " AND indisponivel_em IS NULL GROUP BY 1, 2", -1, &s, NULL) == SQLITE_OK) {
            while (sqlite3_step(s) == SQLITE_ROW) {
                if (sqlite3_column_type(s, 0) == SQLITE_NULL) continue;
                NSString *a = ZPPrimeiroArtista(@((const char *)sqlite3_column_text(s, 0)));
                NSString *g = @((const char *)sqlite3_column_text(s, 1));
                int n = sqlite3_column_int(s, 2);
                if (g.length) generos[g] = @(generos[g].integerValue + n);
                if (a.length == 0 || [comFicheiros containsObject:ZPChaveDoArtistaDasOrigens(a)]) continue;
                if (!artistas[a]) artistas[a] = [@[[NSCountedSet set], @0] mutableCopy];
                for (int i = 0; i < n && g.length; ++i) [artistas[a][0] addObject:g];
                artistas[a][1] = @([artistas[a][1] integerValue] + n);
            }
        }
        sqlite3_finalize(s);
    }
    sqlite3_close(db);
    NSMutableArray *la = [NSMutableArray array];
    for (NSString *a in artistas) {
        NSCountedSet *c = artistas[a][0];
        NSString *melhor = @"";
        for (NSString *g in c) if (!melhor.length || [c countForObject:g] > [c countForObject:melhor]) melhor = g;
        [la addObject:@[a, melhor, artistas[a][1]]];
    }
    [la sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [x[0] localizedCaseInsensitiveCompare:y[0]]; }];
    self.artistasSoNoMusica = la;
    NSMutableArray *lg = [NSMutableArray array];
    for (NSString *g in generos) [lg addObject:@[g, @"", generos[g]]];
    [lg sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [y[2] compare:x[2]]; }];
    self.generosNoMusica = lg;
}

- (void)gravar {
    NSDictionary *tudo = @{ @"_leia": self.leia ?: ZPLeia, @"origens": self.origens, @"artistas": self.artistas,
                            @"generosDoMusica": self.generosDoMusica, @"artistasDoMusica": self.artistasDoMusica };
    NSData *dados = [NSJSONSerialization dataWithJSONObject:tudo
                                                    options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                      error:NULL];
    [[NSFileManager defaultManager] createDirectoryAtPath:self.caminhoDasRegras.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:NULL];
    if (![dados writeToFile:self.caminhoDasRegras atomically:YES]) NSBeep();
}

#pragma mark - As sementes (à esquerda)

- (NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *)regrasDoLado {
    return self.lado.selectedSegment == ZPLadoArtistas ? self.artistas : self.origens;
}

- (NSArray<NSString *> *)chavesDoLado {
    return [[self regrasDoLado].allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

- (nullable NSString *)sementeSeleccionada {
    if ([self ladoDoMusica]) return nil;
    NSArray *k = [self chavesDoLado];
    NSInteger i = self.sementes.selectedRow;
    return (i >= 0 && i < (NSInteger)k.count) ? k[i] : nil;
}

- (void)refazerAsSementes:(nullable NSString *)escolher {
    NSString *antes = escolher ?: [self sementeSeleccionada];
    [self.sementes reloadData];
    NSUInteger i = antes ? [[self chavesDoLado] indexOfObject:antes] : NSNotFound;
    if (i == NSNotFound) i = 0;
    if ([self chavesDoLado].count) {
        [self.sementes selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
        [self.sementes scrollRowToVisible:(NSInteger)i];
    }
    [self.etiquetas reloadData];
    [self actualizarLegenda];
}

- (BOOL)ladoDoMusica {
    return self.lado.selectedSegment >= ZPLadoArtistasDoMusica;
}

- (IBAction)mudarDeLado:(id)sender {
    BOOL doMusica = [self ladoDoMusica];
    self.rolLista.hidden = !doMusica;
    self.rolSementes.hidden = self.rolEtiquetas.hidden = self.maisMenos.hidden = doMusica;
    self.filtro.placeholderString = doMusica
        ? NSLocalizedString(self.lado.selectedSegment == ZPLadoArtistasDoMusica ? @"origins_filter_artists" : @"origins_filter", @"Filtrar")
        : NSLocalizedString(@"origins_filter", @"Filtrar etiquetas");
    self.lista.tableColumns[0].title = self.lado.selectedSegment == ZPLadoArtistasDoMusica
        ? NSLocalizedString(@"origins_col_name", @"Artista") : NSLocalizedString(@"origins_col_music_genre", @"Género no Música");
    self.lista.tableColumns[1].hidden = self.lado.selectedSegment != ZPLadoArtistasDoMusica;
    [self aplicarFiltro];
    [self refazerAsSementes:nil];
}

- (IBAction)maisOuMenos:(NSSegmentedControl *)sender {
    if (sender.selectedSegment == 1) { [self tirar]; return; }
    if (self.lado.selectedSegment == ZPLadoOrigens) [self acrescentarOrigem]; else [self acrescentarArtista];
}

// Uma origem nova: das etiquetas da fonoteca que ainda não têm regra. Começa
// por admitir só ela própria.
- (void)acrescentarOrigem {
    NSMenu *menu = [[NSMenu alloc] init];
    for (NSArray *g in self.generos) {
        if (self.origens[g[0]]) continue;
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"%@  (%@)", g[0], g[1]]
                                                      action:@selector(acrescentarOrigemDoMenu:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = g[0];
        [menu addItem:item];
    }
    if (menu.numberOfItems == 0) { NSBeep(); return; }
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(self.maisMenos.bounds) + 2) inView:self.maisMenos];
}

- (void)acrescentarOrigemDoMenu:(NSMenuItem *)item {
    NSString *g = item.representedObject;
    self.origens[g] = [NSMutableArray arrayWithObject:g];
    [self gravar];
    [self refazerAsSementes:g];
}

// Um artista que seja excepção: escolhe-se dos da fonoteca. Começa por admitir
// o mesmo que a origem dele (a etiqueta mais frequente nos ficheiros dele).
- (void)acrescentarArtista {
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = NSLocalizedString(@"origins_add_artist", @"Que artista?");
    a.informativeText = NSLocalizedString(@"origins_add_artist_text", @"A regra dele passa à frente da da origem.");
    NSComboBox *caixa = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 280, 26)];
    caixa.completes = YES;
    caixa.numberOfVisibleItems = 15;
    [caixa addItemsWithObjectValues:self.nomesDosArtistas];
    a.accessoryView = caixa;
    [a addButtonWithTitle:NSLocalizedString(@"origins_add", @"Acrescentar")];
    [a addButtonWithTitle:NSLocalizedString(@"origins_cancel", @"Cancelar")];
    a.window.initialFirstResponder = caixa;
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        NSString *nome = [caixa.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (r != NSAlertFirstButtonReturn || nome.length == 0) return;
        if (!self.artistas[nome]) {
            NSString *origem = self.origemDoArtista[nome];
            NSArray *daOrigem = origem ? self.origens[origem] : nil;
            self.artistas[nome] = [NSMutableArray arrayWithArray:daOrigem ?: (origem ? @[origem] : @[])];
            [self gravar];
        }
        [self refazerAsSementes:nome];
    }];
}

- (void)tirar {
    NSString *k = [self sementeSeleccionada];
    if (!k) { NSBeep(); return; }
    [[self regrasDoLado] removeObjectForKey:k];
    [self gravar];
    [self refazerAsSementes:nil];
}

#pragma mark - As etiquetas (à direita)

- (void)aplicarFiltro {
    NSString *f = self.filtro.stringValue;
    self.linhasDoMusica = self.lado.selectedSegment == ZPLadoArtistasDoMusica ? self.artistasSoNoMusica
                        : self.lado.selectedSegment == ZPLadoGenerosDoMusica ? self.generosNoMusica : @[];
    if (f.length == 0) self.linhasVisiveis = self.linhasDoMusica;
    else {
        NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        self.linhasVisiveis = [self.linhasDoMusica filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *l, NSDictionary *b) {
            return [l[0] rangeOfString:f options:o].location != NSNotFound || [l[1] rangeOfString:f options:o].location != NSNotFound;
        }]];
    }
    [self.lista reloadData];
    NSArray<NSArray *> *generos = self.generos;
    if (f.length) {
        NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch;
        generos = [generos filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSArray *g, NSDictionary *b) {
            return [g[0] rangeOfString:f options:o].location != NSNotFound;
        }]];
    }
    self.generosVisiveis = [self ordenarEtiquetas:generos];
    [self.etiquetas reloadData];
}

// Pela ordem do cabeçalho: nome (à maneira do Finder) ou número de faixas,
// com o nome a desempatar.
- (NSArray<NSArray *> *)ordenarEtiquetas:(NSArray<NSArray *> *)generos {
    NSSortDescriptor *d = self.etiquetas.sortDescriptors.firstObject;
    if (!d) return generos;
    BOOL porFaixas = [d.key isEqualToString:@"faixas"], sobe = d.ascending;
    return [generos sortedArrayUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        NSComparisonResult r = porFaixas ? [a[1] compare:b[1]] : NSOrderedSame;
        if (r == NSOrderedSame) {
            r = [a[0] localizedStandardCompare:b[0]];
            if (porFaixas) return r;   // o desempate é sempre de A a Z
        }
        return sobe ? r : -r;
    }];
}

- (void)tableView:(NSTableView *)t sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)antigos {
    if (t != self.etiquetas) return;
    NSSortDescriptor *d = t.sortDescriptors.firstObject;
    if (d) [[NSUserDefaults standardUserDefaults] setObject:@[d.key, @(d.ascending)] forKey:kZPOrdemDasEtiquetas];
    [self aplicarFiltro];
}

- (void)controlTextDidChange:(NSNotification *)nota {
    if (nota.object == self.filtro) [self aplicarFiltro];
}

- (IBAction)marcar:(NSButton *)caixa {
    NSString *k = [self sementeSeleccionada];
    NSInteger linha = [self.etiquetas rowForView:caixa];
    if (!k || linha < 0 || linha >= (NSInteger)self.generosVisiveis.count) return;
    NSString *g = self.generosVisiveis[linha][0];
    NSMutableArray *admitidas = [self regrasDoLado][k];
    if (caixa.state == NSControlStateValueOn) { if (![admitidas containsObject:g]) [admitidas addObject:g]; }
    else [admitidas removeObject:g];
    [self gravar];
    [self actualizarLegenda];
}

- (void)actualizarLegenda {
    if ([self ladoDoMusica]) {
        self.legenda.stringValue = NSLocalizedString(self.lado.selectedSegment == ZPLadoArtistasDoMusica ? @"origins_hint_music_artists"
                                                                                                         : @"origins_hint_music_genres", @"");
        return;
    }
    NSString *k = [self sementeSeleccionada];
    if (!k) {
        self.legenda.stringValue = self.lado.selectedSegment == ZPLadoOrigens
            ? NSLocalizedString(@"origins_hint_empty_origins", @"Sem regras: as estações não têm limite de origem. Acrescente uma origem com +.")
            : NSLocalizedString(@"origins_hint_empty_artists", @"Sem excepções. Acrescente um artista com +.");
        return;
    }
    NSArray *admitidas = [[self regrasDoLado][k] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
    NSString *lista = admitidas.count ? [admitidas componentsJoinedByString:@", "] : NSLocalizedString(@"origins_nothing", @"nada");
    self.legenda.stringValue = [NSString stringWithFormat:
        NSLocalizedString(self.lado.selectedSegment == ZPLadoOrigens ? @"origins_hint_origin" : @"origins_hint_artist",
                          @"Uma estação a partir de «%@» só leva faixas de: %@."), k, lista];
}

#pragma mark - Tabelas

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    if (t == self.lista) return (NSInteger)self.linhasVisiveis.count;
    if (t == self.sementes) return (NSInteger)[self chavesDoLado].count;
    return [self sementeSeleccionada] ? (NSInteger)self.generosVisiveis.count : 0;
}

// A origem que uma linha teria sem escolha à mão: a do género do Música,
// pela tradução dos géneros (só nos artistas).
- (NSString *)origemAutomaticaDe:(NSArray *)l {
    return self.lado.selectedSegment == ZPLadoArtistasDoMusica ? (self.generosDoMusica[l[1]] ?: @"") : @"";
}

- (NSView *)vistaDaListaNaColuna:(NSString *)col linha:(NSInteger)linha {
    NSArray *l = self.linhasVisiveis[linha];
    BOOL artistas = self.lado.selectedSegment == ZPLadoArtistasDoMusica;
    if ([col isEqualToString:@"origem"]) {
        NSPopUpButton *b = [self.lista makeViewWithIdentifier:@"escolha" owner:self];
        if (!b) {
            b = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            b.identifier = @"escolha";
            b.controlSize = NSControlSizeSmall;
            b.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
            b.bordered = NO;
            b.target = self;
            b.action = @selector(escolherOrigem:);
        }
        [b removeAllItems];
        NSString *automatica = [self origemAutomaticaDe:l];
        NSString *primeira = artistas
            ? [NSString stringWithFormat:NSLocalizedString(@"origins_auto", @"Pelo género (%@)"),
               automatica.length ? automatica : NSLocalizedString(@"origins_nothing", @"nada")]
            : NSLocalizedString(@"origins_none_dash", @"—");
        [b addItemWithTitle:primeira];
        b.lastItem.representedObject = [NSNull null];
        [b.menu addItem:[NSMenuItem separatorItem]];
        for (NSString *o in [self.origens.allKeys sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]) {
            [b addItemWithTitle:o];
            b.lastItem.representedObject = o;
        }
        if (artistas) {
            [b.menu addItem:[NSMenuItem separatorItem]];
            [b addItemWithTitle:NSLocalizedString(@"origins_none", @"Nenhuma")];
            b.lastItem.representedObject = @"";
        }
        NSString *escolhida = artistas ? self.artistasDoMusica[l[0]] : self.generosDoMusica[l[0]];
        if (!escolhida) [b selectItemAtIndex:0];
        else {
            NSInteger i = [b indexOfItemWithRepresentedObject:escolhida];
            if (i < 0) { [b addItemWithTitle:escolhida]; b.lastItem.representedObject = escolhida; i = b.numberOfItems - 1; }
            [b selectItemAtIndex:i];
        }
        return b;
    }
    NSTextField *campo = [self.lista makeViewWithIdentifier:col owner:self];
    if (!campo) {
        campo = [NSTextField labelWithString:@""];
        campo.identifier = col;
        campo.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    campo.stringValue = [col isEqualToString:@"nome"] ? l[0] : [col isEqualToString:@"faixas"] ? [l[2] description] : l[1];
    campo.alignment = [col isEqualToString:@"faixas"] ? NSTextAlignmentRight : NSTextAlignmentNatural;
    campo.textColor = [col isEqualToString:@"nome"] ? NSColor.labelColor : NSColor.secondaryLabelColor;
    return campo;
}

- (IBAction)escolherOrigem:(NSPopUpButton *)b {
    NSInteger linha = [self.lista rowForView:b];
    if (linha < 0 || linha >= (NSInteger)self.linhasVisiveis.count) return;
    NSString *k = self.linhasVisiveis[linha][0];
    id o = b.selectedItem.representedObject;
    NSMutableDictionary *d = self.lado.selectedSegment == ZPLadoArtistasDoMusica ? self.artistasDoMusica : self.generosDoMusica;
    if (o == [NSNull null] || !o) [d removeObjectForKey:k]; else d[k] = o;
    [self gravar];
    // Mudar a tradução de um género muda a origem automática dos artistas.
    if (self.lado.selectedSegment == ZPLadoGenerosDoMusica) [self.lista reloadData];
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)coluna row:(NSInteger)linha {
    if (t == self.lista) return [self vistaDaListaNaColuna:coluna.identifier linha:linha];
    if ([coluna.identifier isEqualToString:@"marca"]) {
        NSButton *caixa = [t makeViewWithIdentifier:@"caixa" owner:self];
        if (!caixa) {
            caixa = [NSButton checkboxWithTitle:@"" target:self action:@selector(marcar:)];
            caixa.identifier = @"caixa";
        }
        NSString *g = self.generosVisiveis[linha][0];
        caixa.state = [[self regrasDoLado][[self sementeSeleccionada]] containsObject:g] ? NSControlStateValueOn : NSControlStateValueOff;
        return caixa;
    }
    NSTextField *campo = [t makeViewWithIdentifier:coluna.identifier owner:self];
    if (!campo) {
        campo = [NSTextField labelWithString:@""];
        campo.identifier = coluna.identifier;
        campo.lineBreakMode = NSLineBreakByTruncatingTail;
    }
    if (t == self.sementes) {
        NSString *k = [self chavesDoLado][linha];
        campo.stringValue = k;
        // Uma origem que já não existe nas etiquetas fica à vista, apagada.
        BOOL existe = self.lado.selectedSegment == ZPLadoArtistas
            || [self.generos indexOfObjectPassingTest:^BOOL(NSArray *g, NSUInteger i, BOOL *p) { return [g[0] isEqualToString:k]; }] != NSNotFound;
        campo.textColor = existe ? NSColor.labelColor : NSColor.secondaryLabelColor;
        campo.alignment = NSTextAlignmentNatural;
        campo.font = [NSFont systemFontOfSize:NSFont.systemFontSize];
    } else if ([coluna.identifier isEqualToString:@"faixas"]) {
        campo.stringValue = [self.generosVisiveis[linha][1] description];
        campo.textColor = NSColor.secondaryLabelColor;
        campo.alignment = NSTextAlignmentRight;
    } else {
        NSString *g = self.generosVisiveis[linha][0];
        campo.stringValue = g;
        // As que já são origens (têm regra) em negrito: são as que importam.
        campo.font = self.origens[g] ? [NSFont boldSystemFontOfSize:NSFont.systemFontSize] : [NSFont systemFontOfSize:NSFont.systemFontSize];
        campo.textColor = NSColor.labelColor;
        campo.alignment = NSTextAlignmentNatural;
    }
    return campo;
}

- (void)tableViewSelectionDidChange:(NSNotification *)nota {
    if (nota.object != self.sementes) return;
    [self.etiquetas reloadData];
    [self actualizarLegenda];
}

@end
