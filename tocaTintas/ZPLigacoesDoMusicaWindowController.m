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
//  ZPLigacoesDoMusicaWindowController.m
//  tocaTintas
//
//  Created by Zé Pedro do Amaral on 29/10/2026.
//

#import "ZPLigacoesDoMusicaWindowController.h"
#import <AVFoundation/AVFoundation.h>
#import "ZPCatalogoDaApple.h"
#include <sqlite3.h>

// O critério com que o sincronizar encontrou a candidata: só aqui, quando a
// única é de outra duração, a sugestão é «Nenhuma» — o mesmo título com mais de
// dois segundos de diferença é quase sempre outra gravação.
static NSString *const ZPCriterioOutraDuracao = @"título, outra duração";

// Quanto da candidata se ouve, e de onde: a 30 % da duração, que passa os
// silêncios do princípio e chega a um sítio onde as versões se distinguem.
static const NSTimeInterval ZPDuracaoDaAmostra = 10.0;

#pragma mark - Comparação

// O que o título diz da versão: o que vem entre parênteses ou depois de « - »,
// sem a remasterização (a mesma gravação noutra masterização) nem os
// convidados. «remaster» diz se havia remasterização, e qual.
static NSString *ZPLMMarcas(NSString *titulo, NSString **remaster) {
    static NSRegularExpression *rx;
    static dispatch_once_t uma;
    dispatch_once(&uma, ^{
        rx = [NSRegularExpression regularExpressionWithPattern:@"[\\(\\[]([^\\)\\]]*)[\\)\\]]|\\s-\\s+(.+)$" options:0 error:NULL];
    });
    NSMutableArray<NSString *> *marcas = [NSMutableArray array];
    NSString *r = @"";
    titulo = titulo ?: @"";
    for (NSTextCheckingResult *m in [rx matchesInString:titulo options:0 range:NSMakeRange(0, titulo.length)]) {
        NSRange onde = [m rangeAtIndex:1].location != NSNotFound ? [m rangeAtIndex:1] : [m rangeAtIndex:2];
        NSString *marca = [[titulo substringWithRange:onde] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        NSString *chave = [marca stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
        if ([chave containsString:@"remaster"]) { r = marca; continue; }
        if ([chave hasPrefix:@"feat"] || [chave hasPrefix:@"ft."] || [chave hasPrefix:@"with "] || marca.length == 0) continue;
        [marcas addObject:marca];
    }
    if (remaster) *remaster = r;
    return [marcas componentsJoinedByString:@", "];
}

static NSString *ZPLMChave(NSString *s) {
    NSString *c = [(s ?: @"") stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch locale:nil];
    return [c stringByReplacingOccurrencesOfString:@"[^\\p{L}\\p{N}]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, c.length)];
}

// O parecer sobre uma candidata, pela diferença de duração e pelo que os
// títulos dizem da versão. Mais de dez segundos é outra versão; até três, sem
// versões diferentes no título, é a mesma gravação; o resto só o ouvido decide.
typedef NS_ENUM(NSInteger, ZPLMParecer) { ZPLMMesma, ZPLMMesmaRemasterizada, ZPLMOutra, ZPLMPorOuvir };

static ZPLMParecer ZPLMParecerDe(NSDictionary *caso, NSDictionary *candidata) {
    double d = fabs([candidata[@"dif_duracao"] doubleValue]);
    if (d > 10.0) return ZPLMOutra;
    NSString *r1 = nil, *r2 = nil;
    NSString *m1 = ZPLMMarcas(caso[@"titulo"], &r1), *m2 = ZPLMMarcas(candidata[@"titulo"], &r2);
    if (d > 3.0 || ![ZPLMChave(m1) isEqualToString:ZPLMChave(m2)]) return ZPLMPorOuvir;
    return [ZPLMChave(r1) isEqualToString:ZPLMChave(r2)] ? ZPLMMesma : ZPLMMesmaRemasterizada;
}

#pragma mark - SQLite

// Os mesmos três passos que o ZPPrincipal usa com a base, aqui à parte: esta
// janela abre a sua ligação, só enquanto lê ou grava.
static BOOL ZPLMPreparar(sqlite3 *db, const char *sql, NSArray *args, sqlite3_stmt **st) {
    if (sqlite3_prepare_v2(db, sql, -1, st, NULL) != SQLITE_OK) {
        NSLog(@"[Ligações do Música] SQL: %s — %s", sqlite3_errmsg(db), sql);
        return NO;
    }
    for (NSUInteger i = 0; i < args.count; ++i) {
        id v = args[i];
        int k = (int)i + 1;
        if ([v isKindOfClass:[NSString class]]) sqlite3_bind_text(*st, k, [v UTF8String], -1, SQLITE_TRANSIENT);
        else if ([v isKindOfClass:[NSNumber class]]) sqlite3_bind_double(*st, k, [v doubleValue]);
        else sqlite3_bind_null(*st, k);
    }
    return YES;
}

static BOOL ZPLMExecutar(sqlite3 *db, const char *sql, NSArray *args) {
    sqlite3_stmt *st = NULL;
    BOOL ok = ZPLMPreparar(db, sql, args, &st) && sqlite3_step(st) == SQLITE_DONE;
    if (!ok) NSLog(@"[Ligações do Música] Falhou: %s — %s", sqlite3_errmsg(db), sql);
    sqlite3_finalize(st);
    return ok;
}

static id ZPLMColuna(sqlite3_stmt *st, int i) {
    switch (sqlite3_column_type(st, i)) {
        case SQLITE_INTEGER: return @(sqlite3_column_int64(st, i));
        case SQLITE_FLOAT:   return @(sqlite3_column_double(st, i));
        case SQLITE_TEXT:    return @((const char *)sqlite3_column_text(st, i));
        default:             return [NSNull null];
    }
}

// Uma linha como dicionário, com as colunas pelos nomes do SELECT; os NULL ficam
// de fora.
static NSDictionary *ZPLMLinha(sqlite3_stmt *st) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (int i = 0; i < sqlite3_column_count(st); ++i) {
        id v = ZPLMColuna(st, i);
        if (v != [NSNull null]) d[@(sqlite3_column_name(st, i))] = v;
    }
    return d;
}

static NSString *ZPLMTexto(id v) {
    return [v isKindOfClass:[NSString class]] ? v : [v isKindOfClass:[NSNumber class]] ? [v description] : @"";
}

static NSString *ZPLMDuracao(id segundos) {
    if (![segundos isKindOfClass:[NSNumber class]]) return @"";
    long s = lround([segundos doubleValue]);
    return [NSString stringWithFormat:@"%ld:%02ld", s / 60, s % 60];
}

#pragma mark -

@interface ZPLigacoesDoMusicaWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate>
@property (nonatomic, copy) NSString *caminhoDaBase;
@property (nonatomic, strong) dispatch_queue_t fila;

@property (nonatomic, strong) NSArray<NSDictionary *> *casos;          // todas as pendentes
@property (nonatomic, strong) NSArray<NSDictionary *> *casosVisiveis;  // as que passam o filtro
@property (nonatomic, strong) NSDictionary<NSString *, NSArray<NSDictionary *> *> *candidatas;   // pid → candidatas

@property (nonatomic, strong) NSSearchField *filtro;
@property (nonatomic, strong) NSTextField *contagem;
@property (nonatomic, strong) NSTableView *tabelaDosCasos;
@property (nonatomic, strong) NSTableView *tabelaDasCandidatas;
@property (nonatomic, strong) NSGridView *grelha;        // «Tocado no Música» e «Identificado com», campo a campo
@property (nonatomic, strong) NSArray<NSArray<NSTextField *> *> *celulas;   // [0] a faixa do Música, [1] a candidata
@property (nonatomic, strong) NSTextField *comparacao;   // o parecer e a consequência da escolha à vista
// pid → número da faixa no álbum, pedido ao catálogo da Apple quando o Música dá
// 0 (as faixas do catálogo); @"" enquanto se espera ou se a loja não o tem.
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSString *> *numerosDaLoja;
@property (nonatomic, strong) NSButton *botaoOuvirMusica;
@property (nonatomic, strong) NSButton *botaoOuvir;
@property (nonatomic, strong) NSButton *botaoAlbum;
@property (nonatomic, strong) NSButton *botaoSaltar;
@property (nonatomic, strong) NSButton *botaoLigar;

@property (nonatomic, strong, nullable) AVAudioPlayer *amostra;
@property (nonatomic, strong, nullable) NSTimer *fimDaAmostra;
@property (nonatomic) NSInteger ladoDaAmostra;        // 0 nada, 1 a faixa do Música, 2 a candidata
@property (nonatomic) NSUInteger pedidoDaAmostra;     // muda a cada pedido: uma resposta atrasada da loja não toca
@property (nonatomic, copy, nullable) NSString *aviso; // o que correu mal com a amostra, para a comparação
@property (nonatomic) BOOL aActualizar;               // a sincronizar: as escolhas esperam
@end

@implementation ZPLigacoesDoMusicaWindowController

- (instancetype)initComBase:(NSString *)caminhoDaBase {
    NSWindow *janela = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 640)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                             | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:YES];
    self = [super initWithWindow:janela];
    if (!self) return nil;
    _caminhoDaBase = [caminhoDaBase copy];
    _fila = dispatch_queue_create("tocaTintas.ligacoesDoMusica", DISPATCH_QUEUE_SERIAL);
    _casos = @[]; _casosVisiveis = @[]; _candidatas = @{};
    _numerosDaLoja = [NSMutableDictionary dictionary];
    janela.title = NSLocalizedString(@"music_links_title", @"Ligar faixas do Música");
    janela.minSize = NSMakeSize(900, 580);
    janela.delegate = self;
    janela.releasedWhenClosed = NO;
    [janela center];
    janela.frameAutosaveName = @"LigacoesDoMusica";
    [self montarJanela];
    [self recarregar];
    return self;
}

#pragma mark - A janela

- (NSTableView *)tabelaComColunas:(NSArray<NSArray *> *)colunas {
    NSTableView *t = [[NSTableView alloc] init];
    for (NSArray *c in colunas) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
        col.title = c[1];
        col.width = [c[2] doubleValue];
        col.minWidth = 30;
        [t addTableColumn:col];
    }
    t.dataSource = self;
    t.delegate = self;
    t.usesAlternatingRowBackgroundColors = YES;
    t.allowsMultipleSelection = NO;
    t.allowsEmptySelection = NO;
    t.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    t.style = NSTableViewStyleFullWidth;
    return t;
}

- (NSScrollView *)rolar:(NSTableView *)t {
    NSScrollView *s = [[NSScrollView alloc] init];
    s.documentView = t;
    s.hasVerticalScroller = YES;
    s.autohidesScrollers = YES;
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

- (NSButton *)botao:(NSString *)chave comentario:(NSString *)comentario accao:(SEL)accao {
    NSButton *b = [NSButton buttonWithTitle:NSLocalizedString(chave, comentario) target:self action:accao];
    b.translatesAutoresizingMaskIntoConstraints = NO;
    return b;
}

- (void)montarJanela {
    NSView *v = self.window.contentView;

    self.filtro = [[NSSearchField alloc] init];
    self.filtro.placeholderString = NSLocalizedString(@"music_links_search", @"Filtrar por artista, álbum ou título");
    self.filtro.delegate = self;
    self.filtro.translatesAutoresizingMaskIntoConstraints = NO;

    self.contagem = [NSTextField labelWithString:@""];
    self.contagem.textColor = NSColor.secondaryLabelColor;
    self.contagem.translatesAutoresizingMaskIntoConstraints = NO;

    NSString *artista = NSLocalizedString(@"music_links_col_artist", @"Artista");
    NSString *album = NSLocalizedString(@"music_links_col_album", @"Álbum");
    NSString *numero = NSLocalizedString(@"music_links_col_number", @"N.º");
    NSString *titulo = NSLocalizedString(@"music_links_col_title", @"Título");
    NSString *duracao = NSLocalizedString(@"music_links_col_duration", @"Duração");
    self.tabelaDosCasos = [self tabelaComColunas:@[
        @[@"artista", artista, @240], @[@"album", album, @300], @[@"faixa", numero, @32],
        @[@"titulo", titulo, @260], @[@"duracao", duracao, @56],
        @[@"vezes", NSLocalizedString(@"music_links_col_plays", @"Vezes no Música"), @44] ]];
    self.tabelaDasCandidatas = [self tabelaComColunas:@[
        @[@"artista", artista, @200], @[@"album", album, @220], @[@"faixa", numero, @32],
        @[@"titulo", titulo, @220], @[@"duracao", duracao, @96],
        @[@"formato", NSLocalizedString(@"music_links_col_format", @"Onde"), @56],
        @[@"criterio", NSLocalizedString(@"music_links_col_criterion", @"Parecer"), @190] ]];
    self.tabelaDasCandidatas.doubleAction = @selector(ligar:);
    self.tabelaDasCandidatas.target = self;

    // As pendentes em cima, as candidatas da escolhida por baixo: cada tabela
    // com a largura toda, para se lerem os nomes, e nenhuma pode encolher até
    // desaparecer (lado a lado, a das candidatas chegou a ficar com largura 0).
    NSSplitView *divisao = [[NSSplitView alloc] init];
    divisao.vertical = NO;
    divisao.dividerStyle = NSSplitViewDividerStyleThin;
    divisao.translatesAutoresizingMaskIntoConstraints = NO;
    NSScrollView *deCima = [self rolar:self.tabelaDosCasos], *deBaixo = [self rolar:self.tabelaDasCandidatas];
    [divisao addArrangedSubview:deCima];
    [divisao addArrangedSubview:deBaixo];
    [deCima.heightAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    [deBaixo.heightAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    divisao.autosaveName = @"LigacoesDoMusicaDivisaoVertical";

    // As duas faixas, campo a campo, em colunas: o que tocou no Música e
    // aquilo com que está identificado (a candidata escolhida na tabela das candidatas).
    NSArray *cabecalhos = @[@"", artista, album, numero, titulo, duracao,
                            NSLocalizedString(@"music_links_col_format", @"Onde"),
                            NSLocalizedString(@"music_links_col_plays", @"Vezes")];
    NSMutableArray *linhas = [NSMutableArray array];
    NSMutableArray *cab = [NSMutableArray array];
    for (NSString *c in cabecalhos) {
        NSTextField *l = [NSTextField labelWithString:c];
        l.textColor = NSColor.secondaryLabelColor;
        [cab addObject:l];
    }
    [linhas addObject:cab];
    NSMutableArray *celulas = [NSMutableArray array];
    for (NSString *rotulo in @[NSLocalizedString(@"music_links_row_played", @"Tocado no Música"),
                               NSLocalizedString(@"music_links_row_identified", @"Identificado com")]) {
        NSTextField *r = [NSTextField labelWithString:rotulo];
        r.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        NSMutableArray *linha = [NSMutableArray arrayWithObject:r];
        NSMutableArray *campos = [NSMutableArray array];
        for (NSUInteger i = 1; i < cabecalhos.count; ++i) {
            NSTextField *l = [NSTextField labelWithString:@""];
            l.lineBreakMode = NSLineBreakByTruncatingTail;
            l.selectable = YES;
            // Artista, álbum e título ficam com a largura que sobra; só
            // encolhem (com «…», e o texto todo na dica) numa janela estreita.
            if (i == 1 || i == 2 || i == 4) {
                [l setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
                [l setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
            }
            [linha addObject:l];
            [campos addObject:l];
        }
        [linhas addObject:linha];
        [celulas addObject:campos];
    }
    self.celulas = celulas;
    self.grelha = [NSGridView gridViewWithViews:linhas];
    self.grelha.columnSpacing = 14;
    self.grelha.rowSpacing = 4;
    [self.grelha columnAtIndex:3].xPlacement = NSGridCellPlacementTrailing;   // n.º
    [self.grelha columnAtIndex:5].xPlacement = NSGridCellPlacementTrailing;   // duração
    [self.grelha columnAtIndex:7].xPlacement = NSGridCellPlacementTrailing;   // vezes
    self.grelha.translatesAutoresizingMaskIntoConstraints = NO;
    // A grelha fica com a altura das três linhas; a que sobra vai para as
    // tabelas. Sem isto as linhas espalhavam-se e o cabeçalho ficava longe.
    NSLayoutConstraint *justa = [self.grelha.heightAnchor constraintEqualToConstant:0];
    justa.priority = NSLayoutPriorityDefaultLow;
    justa.active = YES;

    self.comparacao = [NSTextField wrappingLabelWithString:@""];
    self.comparacao.selectable = YES;
    self.comparacao.translatesAutoresizingMaskIntoConstraints = NO;
    [self.comparacao setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.comparacao setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];

    self.botaoOuvirMusica = [self botao:@"music_links_listen_music" comentario:@"▶︎ Ouvir a do Música" accao:@selector(ouvir:)];
    self.botaoOuvir = [self botao:@"music_links_listen" comentario:@"▶︎ Ouvir a candidata" accao:@selector(ouvir:)];
    self.botaoAlbum = [self botao:@"music_links_accept_album" comentario:@"Aceitar o álbum" accao:@selector(aceitarOAlbum:)];
    self.botaoSaltar = [self botao:@"music_links_skip" comentario:@"Saltar" accao:@selector(saltar:)];
    self.botaoLigar = [self botao:@"music_links_link" comentario:@"Ligar" accao:@selector(ligar:)];
    self.botaoLigar.keyEquivalent = @"\r";
    self.botaoSaltar.toolTip = NSLocalizedString(@"music_links_skip_tip", @"Não grava nada: passa à faixa seguinte, e esta fica por ligar.");
    self.botaoAlbum.toolTip = NSLocalizedString(@"music_links_accept_album_tip", @"Aplica a sugestão a todas as faixas por ligar deste álbum; pergunta antes de gravar.");

    for (NSView *x in @[self.filtro, self.contagem, divisao, self.grelha, self.comparacao, self.botaoOuvirMusica, self.botaoOuvir,
                        self.botaoAlbum, self.botaoSaltar, self.botaoLigar]) {
        [v addSubview:x];
    }
    CGFloat m = 12;
    [NSLayoutConstraint activateConstraints:@[
        [self.filtro.topAnchor constraintEqualToAnchor:v.topAnchor constant:m],
        [self.filtro.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [self.filtro.widthAnchor constraintEqualToConstant:280],
        [self.contagem.centerYAnchor constraintEqualToAnchor:self.filtro.centerYAnchor],
        [self.contagem.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [divisao.topAnchor constraintEqualToAnchor:self.filtro.bottomAnchor constant:m],
        [divisao.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
        [divisao.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        [divisao.bottomAnchor constraintEqualToAnchor:self.grelha.topAnchor constant:-m],
        [self.grelha.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [self.grelha.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [self.grelha.bottomAnchor constraintEqualToAnchor:self.comparacao.topAnchor constant:-10],
        [divisao.heightAnchor constraintGreaterThanOrEqualToConstant:230],
        [self.comparacao.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [self.comparacao.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [self.comparacao.heightAnchor constraintGreaterThanOrEqualToConstant:64],
        [self.comparacao.bottomAnchor constraintEqualToAnchor:self.botaoLigar.topAnchor constant:-m],
        [self.botaoLigar.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [self.botaoLigar.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-m],
        [self.botaoSaltar.trailingAnchor constraintEqualToAnchor:self.botaoLigar.leadingAnchor constant:-8],
        [self.botaoSaltar.centerYAnchor constraintEqualToAnchor:self.botaoLigar.centerYAnchor],
        [self.botaoAlbum.trailingAnchor constraintEqualToAnchor:self.botaoSaltar.leadingAnchor constant:-8],
        [self.botaoAlbum.centerYAnchor constraintEqualToAnchor:self.botaoLigar.centerYAnchor],
        [self.botaoOuvirMusica.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
        [self.botaoOuvirMusica.centerYAnchor constraintEqualToAnchor:self.botaoLigar.centerYAnchor],
        [self.botaoOuvir.leadingAnchor constraintEqualToAnchor:self.botaoOuvirMusica.trailingAnchor constant:8],
        [self.botaoOuvir.centerYAnchor constraintEqualToAnchor:self.botaoLigar.centerYAnchor],
    ]];
}

- (void)windowWillClose:(NSNotification *)nota {
    [self pararAmostra];
}

#pragma mark - A base

- (nullable sqlite3 *)abrir {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(self.caminhoDaBase.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        NSLog(@"[Ligações do Música] Não abri %@: %s", self.caminhoDaBase, db ? sqlite3_errmsg(db) : "sem memória");
        sqlite3_close(db);
        return NULL;
    }
    // O sincronizar pode estar a meio da sua transacção, que leva uns segundos.
    sqlite3_busy_timeout(db, 30000);
    ZPLMExecutar(db, "PRAGMA foreign_keys = ON", nil);
    return db;
}

- (void)recarregar {
    dispatch_async(self.fila, ^{
        sqlite3 *db = [self abrir];
        if (!db) return;
        NSMutableArray *casos = [NSMutableArray array];
        NSMutableDictionary<NSString *, NSMutableArray *> *cands = [NSMutableDictionary dictionary];
        sqlite3_stmt *st = NULL;
        if (ZPLMPreparar(db, "SELECT pid, artista, album, disco, faixa, titulo, duracao, contagem_inicial AS vezes, tipo"
                             " FROM faixas_musica WHERE estado = 'pendente'"
                             " ORDER BY artista COLLATE NOCASE, album COLLATE NOCASE, disco, faixa", nil, &st)) {
            while (sqlite3_step(st) == SQLITE_ROW) [casos addObject:ZPLMLinha(st)];
        }
        sqlite3_finalize(st);
        // Onde está a candidata: o formato do ficheiro (o FLAC primeiro), «CD» se
        // só se conhece do disco, ou só no Música (a própria de outra faixa dele).
        if (ZPLMPreparar(db, "SELECT c.pid, c.musica, c.criterio, c.dif_duracao, m.artista, m.album, m.faixa, m.titulo, m.duracao,"
                             " (SELECT f.caminho FROM ficheiros f WHERE f.musica = m.id AND f.caminho IS NOT NULL"
                             "   ORDER BY f.formato <> 'flac', f.caminho LIMIT 1) AS caminho,"
                             " (SELECT f.formato FROM ficheiros f WHERE f.musica = m.id AND f.caminho IS NOT NULL"
                             "   ORDER BY f.formato <> 'flac', f.caminho LIMIT 1) AS formato,"
                             " EXISTS (SELECT 1 FROM faixas_cd fc WHERE fc.musica = m.id) AS do_cd,"
                             // O que a base já sabe dela: as audições (as registadas e as que o Música
                             // trazia das faixas já ligadas) e quantas faixas do Música tem ligadas.
                             " (SELECT COUNT(*) FROM audicoes a WHERE a.musica = m.id)"
                             "   + (SELECT COALESCE(SUM(y.contagem_inicial), 0) FROM faixas_musica y WHERE y.musica = m.id) AS audicoes,"
                             " (SELECT COUNT(*) FROM faixas_musica y WHERE y.musica = m.id) AS ligadas"
                             " FROM candidatas_musica c JOIN musicas m ON m.id = c.musica"
                             " JOIN faixas_musica fm ON fm.pid = c.pid AND fm.estado = 'pendente'"
                             " ORDER BY c.pid, c.ordem", nil, &st)) {
            while (sqlite3_step(st) == SQLITE_ROW) {
                NSDictionary *c = ZPLMLinha(st);
                NSMutableArray *lista = cands[c[@"pid"]];
                if (!lista) cands[c[@"pid"]] = lista = [NSMutableArray array];
                [lista addObject:c];
            }
        }
        sqlite3_finalize(st);
        sqlite3_close(db);
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *antes = [self casoSeleccionado][@"pid"];
            self.casos = casos;
            self.candidatas = cands;
            [self aplicarFiltro];
            [self seleccionarCaso:antes ou:0];
        });
    });
}

#pragma mark - Filtro e selecção

- (void)aplicarFiltro {
    NSString *f = self.filtro.stringValue;
    if (f.length == 0) {
        self.casosVisiveis = self.casos;
    } else {
        NSStringCompareOptions o = NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch;
        self.casosVisiveis = [self.casos filteredArrayUsingPredicate:
            [NSPredicate predicateWithBlock:^BOOL(NSDictionary *c, NSDictionary *b) {
                for (NSString *k in @[@"artista", @"album", @"titulo"]) {
                    if ([ZPLMTexto(c[k]) rangeOfString:f options:o].location != NSNotFound) return YES;
                }
                return NO;
            }]];
    }
    [self.tabelaDosCasos reloadData];
    [self escreverContagem];
    [self actualizarBotoes];
}

- (void)escreverContagem {
    self.contagem.stringValue = self.aActualizar
        ? NSLocalizedString(@"music_links_updating", @"A actualizar com o Música…")
        : self.casos.count == 0
        ? NSLocalizedString(@"music_links_empty", @"Nenhuma faixa por ligar.")
        : [NSString stringWithFormat:NSLocalizedString(@"music_links_count", @"%ld por ligar"), (long)self.casos.count];
}

- (void)mostrarActualizacao:(BOOL)aActualizar {
    if (aActualizar == self.aActualizar) return;
    self.aActualizar = aActualizar;
    // Uma passagem suave de um texto ao outro: some, muda, volta.
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
        c.duration = 0.15;
        self.contagem.animator.alphaValue = 0.0;
    } completionHandler:^{
        [self escreverContagem];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *c) {
            c.duration = 0.25;
            self.contagem.animator.alphaValue = 1.0;
        }];
    }];
    [self actualizarBotoes];
    if (!aActualizar) [self recarregar];
}

- (void)controlTextDidChange:(NSNotification *)nota {
    if (nota.object == self.filtro) {
        [self aplicarFiltro];
        [self seleccionarCaso:nil ou:0];
    }
}

- (nullable NSDictionary *)casoSeleccionado {
    NSInteger i = self.tabelaDosCasos.selectedRow;
    return (i >= 0 && i < (NSInteger)self.casosVisiveis.count) ? self.casosVisiveis[i] : nil;
}

- (NSArray<NSDictionary *> *)candidatasDe:(nullable NSDictionary *)caso {
    return caso ? (self.candidatas[caso[@"pid"]] ?: @[]) : @[];
}

// O caso com este pid, se ainda estiver à vista; senão o da posição i (ou o
// último, se i já passou do fim).
- (void)seleccionarCaso:(nullable NSString *)pid ou:(NSInteger)i {
    if (pid) {
        NSUInteger j = [self.casosVisiveis indexOfObjectPassingTest:^BOOL(NSDictionary *c, NSUInteger k, BOOL *p) {
            return [c[@"pid"] isEqualToString:pid];
        }];
        if (j != NSNotFound) i = (NSInteger)j;
    }
    if (self.casosVisiveis.count == 0) {
        [self.tabelaDasCandidatas reloadData];
        [self actualizarBotoes];
        return;
    }
    i = MAX(0, MIN(i, (NSInteger)self.casosVisiveis.count - 1));
    [self.tabelaDosCasos selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
    [self.tabelaDosCasos scrollRowToVisible:i];
    [self mostrarCandidatas];
}

// A sugestão: a primeira candidata que parece a mesma gravação; não havendo, a
// primeira de todas, menos quando é de outra duração.
- (NSInteger)sugestaoPara:(NSDictionary *)caso {
    NSArray *cs = [self candidatasDe:caso];
    for (NSUInteger i = 0; i < cs.count; ++i) if (ZPLMParecerDe(caso, cs[i]) <= ZPLMMesmaRemasterizada) return (NSInteger)i;
    if (cs.count == 0 || [cs[0][@"criterio"] isEqualToString:ZPCriterioOutraDuracao]) return (NSInteger)cs.count;   // «Nenhuma»
    return 0;
}

- (void)mostrarCandidatas {
    [self pararAmostra];
    [self.tabelaDasCandidatas reloadData];
    NSDictionary *caso = [self casoSeleccionado];
    if (caso) {
        NSInteger s = [self sugestaoPara:caso];
        [self.tabelaDasCandidatas selectRowIndexes:[NSIndexSet indexSetWithIndex:s] byExtendingSelection:NO];
        [self.tabelaDasCandidatas scrollRowToVisible:s];
    }
    [self actualizarBotoes];
}

- (nullable NSDictionary *)candidataSeleccionada {
    NSArray *cs = [self candidatasDe:[self casoSeleccionado]];
    NSInteger i = self.tabelaDasCandidatas.selectedRow;
    return (i >= 0 && i < (NSInteger)cs.count) ? cs[i] : nil;   // nil com «Nenhuma»
}

- (void)actualizarBotoes {
    BOOL ha = [self casoSeleccionado] != nil;
    // Ouvir pode-se sempre; escolher só com a base em dia.
    BOOL escolher = ha && !self.aActualizar;
    self.botaoLigar.enabled = escolher;
    // O botão diz o que faz com a linha escolhida nas candidatas: ligar à candidata
    // ou fazer dela uma entrada nova («Nenhuma»).
    self.botaoLigar.title = (ha && [self candidataSeleccionada] == nil)
        ? NSLocalizedString(@"music_links_new_entry", @"Entrada nova")
        : NSLocalizedString(@"music_links_link", @"Ligar à candidata");
    self.botaoSaltar.enabled = escolher;
    self.botaoAlbum.enabled = escolher && [ZPLMTexto([self casoSeleccionado][@"album"]) length] > 0;
    NSString *parar = NSLocalizedString(@"music_links_stop", @"■ Parar");
    self.botaoOuvirMusica.enabled = ha && self.ladoDaAmostra != 2;
    self.botaoOuvirMusica.title = self.ladoDaAmostra == 1 ? parar : NSLocalizedString(@"music_links_listen_music", @"▶︎ Ouvir a do Música");
    self.botaoOuvir.enabled = ha && [self candidataSeleccionada] != nil && self.ladoDaAmostra != 1;
    self.botaoOuvir.title = self.ladoDaAmostra == 2 ? parar : NSLocalizedString(@"music_links_listen", @"▶︎ Ouvir a candidata");
    [self mostrarComparacao];
}

#pragma mark - Comparação e consequência

static NSString *ZPLMNumero(double x) {
    return [NSString localizedStringWithFormat:@"%.1f", x];
}

// O número da faixa do Música no álbum. Nas do catálogo o Música dá 0, e vai-se
// buscar ao catálogo da Apple, como faz o título na janela do tocador; chega
// depois, e a comparação refaz-se se a faixa ainda for a escolhida.
- (NSString *)numeroDoTocado:(NSDictionary *)caso {
    NSInteger n = [caso[@"faixa"] integerValue];
    if (n > 0) return [NSString stringWithFormat:@"%ld", (long)n];
    NSString *pid = ZPLMTexto(caso[@"pid"]), *album = ZPLMTexto(caso[@"album"]);
    if (!pid.length || !album.length) return @"";
    NSString *sabido = self.numerosDaLoja[pid];
    if (sabido) return sabido;
    self.numerosDaLoja[pid] = @"";
    __weak typeof(self) fraco = self;
    [ZPCatalogoDaApple posicaoDe:ZPLMTexto(caso[@"artista"]) album:album titulo:ZPLMTexto(caso[@"titulo"])
                         duracao:[caso[@"duracao"] doubleValue]
                       concluido:^(NSInteger f, NSInteger total) {
        __strong typeof(fraco) forte = fraco;
        if (!forte || f <= 0) return;
        forte.numerosDaLoja[pid] = [NSString stringWithFormat:@"%ld", (long)f];
        NSUInteger linha = [forte.casosVisiveis indexOfObjectPassingTest:^BOOL(NSDictionary *x, NSUInteger i, BOOL *pare) {
            return [ZPLMTexto(x[@"pid"]) isEqualToString:pid];
        }];
        if (linha != NSNotFound) {
            [forte.tabelaDosCasos reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:linha]
                                            columnIndexes:[NSIndexSet indexSetWithIndex:[forte.tabelaDosCasos columnWithIdentifier:@"faixa"]]];
        }
        if ([ZPLMTexto([forte casoSeleccionado][@"pid"]) isEqualToString:pid]) [forte mostrarComparacao];
    }];
    return @"";
}

- (NSString *)ondeEsta:(NSDictionary *)c {
    if (c[@"caminho"]) {
        return [NSString stringWithFormat:NSLocalizedString(@"music_links_where_file", @"ficheiro %@"), [ZPLMTexto(c[@"formato"]) uppercaseString]];
    }
    return [c[@"do_cd"] boolValue] ? NSLocalizedString(@"music_links_where_cd", @"CD, sem ficheiro")
                                   : NSLocalizedString(@"music_links_only_music", @"só no Música");
}

// O que se lê antes de decidir: o parecer e porquê, as duas faixas lado a lado
// com o que a fonoteca sabe de cada uma, e o que acontece com a escolha que
// está seleccionada.
- (void)mostrarComparacao {
    NSDictionary *caso = [self casoSeleccionado];
    if (!caso) {
        self.comparacao.stringValue = @"";
        for (NSArray *l in self.celulas) for (NSTextField *x in l) x.stringValue = @"";
        return;
    }
    NSDictionary *c = [self candidataSeleccionada];
    NSArray *cs = [self candidatasDe:caso];
    NSInteger vezes = [caso[@"vezes"] integerValue];
    NSDictionary *normal = @{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize],
                              NSForegroundColorAttributeName: NSColor.labelColor };
    NSDictionary *forte = @{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold],
                             NSForegroundColorAttributeName: NSColor.labelColor };
    NSDictionary *fraco = @{ NSFontAttributeName: [NSFont systemFontOfSize:NSFont.systemFontSize],
                             NSForegroundColorAttributeName: NSColor.secondaryLabelColor };
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] init];
    void (^junta)(NSString *, NSDictionary *) = ^(NSString *s, NSDictionary *a) {
        [t appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:a]];
    };

    // 1. O parecer.
    if (c) {
        ZPLMParecer p = ZPLMParecerDe(caso, c);
        NSString *chave = p == ZPLMMesma ? @"music_links_verdict_same" : p == ZPLMMesmaRemasterizada ? @"music_links_verdict_same_remaster"
                        : p == ZPLMOutra ? @"music_links_verdict_other" : @"music_links_verdict_listen";
        junta(NSLocalizedString(chave, @"O parecer sobre a candidata"), forte);
        double d = fabs([c[@"dif_duracao"] doubleValue]);
        NSString *duracao = d < 0.05 ? NSLocalizedString(@"music_links_cmp_same_length", @"a mesma duração")
            : [NSString stringWithFormat:NSLocalizedString(@"music_links_cmp_length_diff", @"%@ s de diferença na duração"), ZPLMNumero(d)];
        NSString *m1 = ZPLMMarcas(caso[@"titulo"], NULL), *m2 = ZPLMMarcas(c[@"titulo"], NULL);
        NSString *nada = NSLocalizedString(@"music_links_cmp_no_mark", @"sem indicação");
        NSString *versoes = [ZPLMChave(m1) isEqualToString:ZPLMChave(m2)]
            ? NSLocalizedString(@"music_links_cmp_same_marks", @"os títulos não indicam versões diferentes")
            : [NSString stringWithFormat:NSLocalizedString(@"music_links_cmp_other_marks", @"os títulos indicam versões diferentes: «%@» no Música, «%@» na candidata"),
               m1.length ? m1 : nada, m2.length ? m2 : nada];
        junta([NSString stringWithFormat:@" — %@; %@.", duracao, versoes], normal);
        NSInteger ligadas = [c[@"ligadas"] integerValue];
        if (ligadas == 1) {
            junta(NSLocalizedString(@"music_links_cmp_linked_one", @" Já há uma faixa do Música ligada a esta candidata."), fraco);
        } else if (ligadas > 1) {
            junta([NSString stringWithFormat:NSLocalizedString(@"music_links_cmp_linked", @" Já há %ld faixas do Música ligadas a esta candidata."),
                   (long)ligadas], fraco);
        }
        junta(@"\n", normal);
    } else {
        junta(NSLocalizedString(@"music_links_verdict_none", @"Entrada nova"), forte);
        // Porquê: a candidata mais próxima e a diferença na duração.
        // Sem INFINITY nem isfinite: o alvo compila com matemática rápida.
        double d = 0;
        for (NSUInteger i = 0; i < cs.count; ++i) {
            double x = fabs([cs[i][@"dif_duracao"] doubleValue]);
            d = i == 0 ? x : MIN(d, x);
        }
        if (cs.count) {
            junta([NSString stringWithFormat:NSLocalizedString(@"music_links_verdict_none_why", @" — a candidata mais próxima tem %@ s de diferença na duração; escolhe-a na tabela das candidatas para a ligar."), ZPLMNumero(d)], normal);
        }
        junta(@"\n", normal);
    }

    // 2. As duas faixas, na grelha.
    NSString *(^numero)(NSDictionary *) = ^NSString *(NSDictionary *f) {
        NSInteger n = [f[@"faixa"] integerValue];
        return n > 0 ? [NSString stringWithFormat:@"%ld", (long)n] : @"";
    };
    NSArray *tocado = @[ZPLMTexto(caso[@"artista"]), ZPLMTexto(caso[@"album"]), [self numeroDoTocado:caso], ZPLMTexto(caso[@"titulo"]),
                        ZPLMDuracao(caso[@"duracao"]), NSLocalizedString(@"music_links_where_music", @"Música"),
                        [NSString stringWithFormat:@"%ld", (long)vezes]];
    NSArray *identificado = c
        ? @[ZPLMTexto(c[@"artista"]), ZPLMTexto(c[@"album"]), numero(c), ZPLMTexto(c[@"titulo"]),
            ZPLMDuracao(c[@"duracao"]), [self ondeEsta:c], [NSString stringWithFormat:@"%ld", (long)[c[@"audicoes"] integerValue]]]
        : @[NSLocalizedString(@"music_links_identified_none", @"nenhuma: entrada nova"), @"", @"", @"", @"", @"", @""];
    for (NSUInteger i = 0; i < 7; ++i) {
        self.celulas[0][i].stringValue = tocado[i];
        self.celulas[1][i].stringValue = identificado[i];
        self.celulas[0][i].toolTip = [tocado[i] length] ? tocado[i] : nil;
        self.celulas[1][i].toolTip = [identificado[i] length] ? identificado[i] : nil;
        self.celulas[1][i].textColor = c ? NSColor.labelColor : NSColor.secondaryLabelColor;
    }
    // O que difere da faixa do Música fica em destaque na candidata.
    if (c) {
        for (NSUInteger i = 0; i < 5; ++i) {
            BOOL igual = [ZPLMChave(tocado[i]) isEqualToString:ZPLMChave(identificado[i])];
            self.celulas[1][i].textColor = igual ? NSColor.labelColor : NSColor.systemOrangeColor;
        }
    }

    // 3. A consequência.
    NSString *consequencia;
    if (c) {
        NSInteger total = [c[@"audicoes"] integerValue] + vezes;
        consequencia = [NSString stringWithFormat:NSLocalizedString(c[@"caminho"] ? @"music_links_cons_link_file" : @"music_links_cons_link_no_file",
                                                                    @"O que acontece ao ligar"), (long)total];
    } else {
        consequencia = [NSString stringWithFormat:NSLocalizedString(@"music_links_cons_none", @"O que acontece com «Nenhuma»"), (long)vezes];
        if (cs.count) {
            consequencia = [consequencia stringByAppendingFormat:NSLocalizedString(@"music_links_cons_none_others",
                                                                                   @" Na fonoteca passa a haver %ld músicas com este título."),
                            (long)cs.count + 1];
        }
    }
    junta(consequencia, normal);
    if (self.aviso.length) { junta(@"\n", normal); junta(self.aviso, fraco); }
    self.comparacao.attributedStringValue = t;
}

#pragma mark - Tabelas

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t {
    if (t == self.tabelaDosCasos) return (NSInteger)self.casosVisiveis.count;
    NSDictionary *caso = [self casoSeleccionado];
    return caso ? (NSInteger)[self candidatasDe:caso].count + 1 : 0;   // + «Nenhuma»
}

static NSString *ZPLMNomeDoCriterio(NSString *c) {
    static NSDictionary *chaves;
    static dispatch_once_t uma;
    dispatch_once(&uma, ^{
        chaves = @{ @"estrito": @"music_links_crit_strict", @"artista+título": @"music_links_crit_artist_title",
                    @"sem remasterização": @"music_links_crit_remaster", @"sem sufixos": @"music_links_crit_suffixes",
                    @"álbum+faixa": @"music_links_crit_album_track", ZPCriterioOutraDuracao: @"music_links_crit_other_length" };
    });
    NSString *k = chaves[c];
    return k ? NSLocalizedString(k, @"Critério de uma candidata") : c;
}

- (NSString *)textoDe:(NSTableView *)t coluna:(NSString *)col linha:(NSInteger)i {
    if (t == self.tabelaDosCasos) {
        NSDictionary *c = self.casosVisiveis[i];
        if ([col isEqualToString:@"duracao"]) return ZPLMDuracao(c[@"duracao"]);
        if ([col isEqualToString:@"faixa"]) return [self numeroDoTocado:c];
        return ZPLMTexto(c[col]);
    }
    NSArray *cs = [self candidatasDe:[self casoSeleccionado]];
    if (i >= (NSInteger)cs.count) {
        return [col isEqualToString:@"artista"]
            ? NSLocalizedString(@"music_links_none", @"Nenhuma — fica como música própria") : @"";
    }
    NSDictionary *c = cs[i];
    if ([col isEqualToString:@"duracao"]) {
        double d = [c[@"dif_duracao"] doubleValue];
        return fabs(d) < 0.05 ? ZPLMDuracao(c[@"duracao"])
                              : [NSString stringWithFormat:@"%@ (%+.1f s)", ZPLMDuracao(c[@"duracao"]), d];
    }
    if ([col isEqualToString:@"formato"]) {
        if (c[@"caminho"]) return ZPLMTexto(c[@"formato"]);
        return [c[@"do_cd"] boolValue] ? @"CD" : NSLocalizedString(@"music_links_only_music", @"só no Música");
    }
    if ([col isEqualToString:@"criterio"]) {
        ZPLMParecer p = ZPLMParecerDe([self casoSeleccionado], c);
        NSString *curto = p <= ZPLMMesmaRemasterizada ? NSLocalizedString(@"music_links_short_same", @"mesma gravação")
                        : p == ZPLMOutra ? NSLocalizedString(@"music_links_short_other", @"outra versão")
                        : NSLocalizedString(@"music_links_short_listen", @"por ouvir");
        return [NSString stringWithFormat:@"%@ (%@)", curto, ZPLMNomeDoCriterio(c[@"criterio"])];
    }
    if ([col isEqualToString:@"faixa"]) return [c[@"faixa"] integerValue] > 0 ? ZPLMTexto(c[@"faixa"]) : @"";
    return ZPLMTexto(c[col]);
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)coluna row:(NSInteger)linha {
    NSTextField *campo = [t makeViewWithIdentifier:coluna.identifier owner:self];
    if (!campo) {
        campo = [NSTextField labelWithString:@""];
        campo.identifier = coluna.identifier;
        campo.lineBreakMode = NSLineBreakByTruncatingTail;
        campo.cell.truncatesLastVisibleLine = YES;
    }
    NSString *texto = [self textoDe:t coluna:coluna.identifier linha:linha];
    campo.stringValue = texto;
    campo.toolTip = texto.length > 20 ? texto : nil;
    BOOL nenhuma = t == self.tabelaDasCandidatas && linha >= (NSInteger)[self candidatasDe:[self casoSeleccionado]].count;
    campo.font = nenhuma ? [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightMedium]
                         : [NSFont systemFontOfSize:NSFont.systemFontSize];
    campo.alignment = [@[@"faixa", @"vezes", @"duracao"] containsObject:coluna.identifier] ? NSTextAlignmentRight
                                                                                         : NSTextAlignmentNatural;
    return campo;
}

- (void)tableViewSelectionDidChange:(NSNotification *)nota {
    self.aviso = nil;
    if (nota.object == self.tabelaDosCasos) [self mostrarCandidatas];
    else { [self pararAmostra]; [self actualizarBotoes]; }
}

#pragma mark - Escolhas

// Grava a escolha de um caso: a música (ligar) ou nil (própria). Só mexe em
// faixas que ainda estejam pendentes — se um sincronizar entretanto a resolveu,
// fica a dele.
- (BOOL)gravar:(NSArray<NSArray *> *)escolhas {
    sqlite3 *db = [self abrir];
    if (!db) return NO;
    BOOL ok = ZPLMExecutar(db, "BEGIN IMMEDIATE", nil);
    for (NSArray *e in escolhas) {
        if (!ok) break;
        NSString *pid = e[0];
        id musica = e[1];
        if (musica == [NSNull null]) {
            NSString *nova = [NSUUID UUID].UUIDString.lowercaseString;
            ok = ZPLMExecutar(db, "INSERT INTO musicas (id, titulo, artista, album, disco, faixa, duracao)"
                                  " SELECT ?2, titulo, artista, album, COALESCE(NULLIF(disco, 0), 1), NULLIF(faixa, 0), duracao"
                                  " FROM faixas_musica WHERE pid = ?1 AND estado = 'pendente'", @[pid, nova])
              && ZPLMExecutar(db, "UPDATE faixas_musica SET musica = ?2, estado = 'propria', criterio = 'escolha'"
                                  " WHERE pid = ?1 AND estado = 'pendente'", @[pid, nova]);
        } else {
            ok = ZPLMExecutar(db, "UPDATE faixas_musica SET musica = ?2, estado = 'escolhida', criterio = 'escolha'"
                                  " WHERE pid = ?1 AND estado = 'pendente'", @[pid, musica]);
        }
        ok = ok && ZPLMExecutar(db, "DELETE FROM candidatas_musica WHERE pid = ?1", @[pid]);
    }
    ok = ok && ZPLMExecutar(db, "COMMIT", nil);
    if (!ok) ZPLMExecutar(db, "ROLLBACK", nil);
    sqlite3_close(db);
    if (!ok) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = NSLocalizedString(@"music_links_failed", @"Não consegui gravar a escolha na base");
        a.alertStyle = NSAlertStyleWarning;
        [a beginSheetModalForWindow:self.window completionHandler:nil];
    }
    return ok;
}

// Tira estes casos das listas e passa ao seguinte, sem voltar a ler a base.
- (void)retirar:(NSSet<NSString *> *)pids {
    NSInteger i = self.tabelaDosCasos.selectedRow;
    NSPredicate *fica = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *c, NSDictionary *b) {
        return ![pids containsObject:c[@"pid"]];
    }];
    self.casos = [self.casos filteredArrayUsingPredicate:fica];
    NSMutableDictionary *cs = [self.candidatas mutableCopy];
    [cs removeObjectsForKeys:pids.allObjects];
    self.candidatas = cs;
    [self aplicarFiltro];
    [self seleccionarCaso:nil ou:i];
}

- (IBAction)ligar:(id)sender {
    NSDictionary *caso = [self casoSeleccionado];
    if (!caso || self.aActualizar) return;
    if (sender == self.tabelaDasCandidatas && self.tabelaDasCandidatas.clickedRow < 0) return;
    NSDictionary *c = [self candidataSeleccionada];
    if ([self gravar:@[@[caso[@"pid"], c[@"musica"] ?: [NSNull null]]]]) {
        [self retirar:[NSSet setWithObject:caso[@"pid"]]];
    }
}

- (IBAction)saltar:(id)sender {
    NSInteger i = self.tabelaDosCasos.selectedRow + 1;
    if (i < (NSInteger)self.casosVisiveis.count) [self seleccionarCaso:nil ou:i];
}

// Todas as pendentes do mesmo álbum (e artista) que a seleccionada, cada uma
// com a sua sugestão — a do álbum+faixa é quase sempre a certa, e há álbuns
// inteiros nesse caso (a música clássica, sobretudo).
- (IBAction)aceitarOAlbum:(id)sender {
    NSDictionary *caso = [self casoSeleccionado];
    if (!caso) return;
    NSString *album = ZPLMTexto(caso[@"album"]), *artista = ZPLMTexto(caso[@"artista"]);
    NSMutableArray *escolhas = [NSMutableArray array];
    NSMutableSet *pids = [NSMutableSet set];
    NSInteger ligadas = 0;
    for (NSDictionary *c in self.casos) {
        if (![ZPLMTexto(c[@"album"]) isEqualToString:album] || ![ZPLMTexto(c[@"artista"]) isEqualToString:artista]) continue;
        NSArray *cs = [self candidatasDe:c];
        NSInteger s = [self sugestaoPara:c];
        // A seleccionada vai com o que estiver escolhido à vista, que pode já não
        // ser a sugestão.
        if ([c[@"pid"] isEqualToString:caso[@"pid"]]) s = self.tabelaDasCandidatas.selectedRow;
        id musica = (s >= 0 && s < (NSInteger)cs.count) ? cs[s][@"musica"] : [NSNull null];
        if (musica != [NSNull null]) ligadas++;
        [escolhas addObject:@[c[@"pid"], musica]];
        [pids addObject:c[@"pid"]];
    }
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = [NSString stringWithFormat:NSLocalizedString(@"music_links_accept_album_title", @"Aceitar as sugestões de «%@»?"), album];
    a.informativeText = [NSString stringWithFormat:NSLocalizedString(@"music_links_accept_album_text",
                                                                     @"%ld faixas: %ld ligadas à candidata sugerida, %ld como músicas próprias."),
                         (long)escolhas.count, (long)ligadas, (long)(escolhas.count - ligadas)];
    [a addButtonWithTitle:NSLocalizedString(@"music_links_accept", @"Aceitar")];
    [a addButtonWithTitle:NSLocalizedString(@"music_links_cancel", @"Cancelar")];
    [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
        if (r == NSAlertFirstButtonReturn && [self gravar:escolhas]) [self retirar:pids];
    }];
}

#pragma mark - Ouvir

// Uma amostra de dez segundos de cada lado, à parte do leitor do tocaTintas:
// não conta como audição (pela regra dos 5 s, dez segundos contariam) e não
// mexe na lista nem no Música. A candidata que tem ficheiro ouve-se dele, a
// 30 % da duração; a faixa do Música, e a candidata que só lá existe, ouvem-se
// pelo excerto de 30 s da loja da Apple — o desta versão, pela duração, ou
// nenhum. Para a loja vão só o artista e o título.
- (IBAction)ouvir:(id)sender {
    if (self.ladoDaAmostra) { [self pararAmostra]; return; }
    NSDictionary *caso = [self casoSeleccionado];
    NSDictionary *c = [self candidataSeleccionada];
    BOOL doMusica = sender == self.botaoOuvirMusica;
    NSDictionary *faixa = doMusica ? caso : c;
    if (!faixa) return;
    self.aviso = nil;
    self.pedidoDaAmostra++;
    self.ladoDaAmostra = doMusica ? 1 : 2;
    NSString *caminho = doMusica ? nil : c[@"caminho"];
    if (caminho) {
        NSError *erro = nil;
        AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:caminho] error:&erro];
        if (!p) {
            NSLog(@"[Ligações do Música] Não consigo tocar %@: %@", caminho, erro.localizedDescription);
            self.aviso = NSLocalizedString(@"music_links_sample_unreadable", @"O macOS não lê este ficheiro: não há amostra.");
            [self pararAmostra];
            return;
        }
        p.currentTime = MAX(0.0, MIN(p.duration * 0.3, p.duration - ZPDuracaoDaAmostra));
        [self tocarAmostra:p];
        return;
    }
    [self actualizarBotoes];
    NSUInteger pedido = self.pedidoDaAmostra;
    __weak typeof(self) fraco = self;
    [self excertoDaLojaDe:faixa depois:^(NSData *som) {
        __strong typeof(fraco) eu = fraco;
        if (!eu || eu.pedidoDaAmostra != pedido || eu.ladoDaAmostra == 0) return;   // entretanto parou ou mudou
        AVAudioPlayer *p = som ? [[AVAudioPlayer alloc] initWithData:som fileTypeHint:AVFileTypeAppleM4A error:NULL] : nil;
        if (!p) {
            eu.aviso = NSLocalizedString(@"music_links_sample_missing", @"A loja não tem excerto desta versão: não há amostra.");
            [eu pararAmostra];
            return;
        }
        [eu tocarAmostra:p];
    }];
}

- (void)tocarAmostra:(AVAudioPlayer *)p {
    [p play];
    self.amostra = p;
    __weak typeof(self) fraco = self;
    self.fimDaAmostra = [NSTimer scheduledTimerWithTimeInterval:ZPDuracaoDaAmostra repeats:NO block:^(NSTimer *t) {
        [fraco pararAmostra];
    }];
    [self actualizarBotoes];
}

// O excerto da loja para esta faixa: o resultado com o mesmo título de base e
// artista, e a duração a menos de três segundos. Chama no thread principal, com
// nil se não houver.
- (void)excertoDaLojaDe:(NSDictionary *)faixa depois:(void (^)(NSData * _Nullable som))depois {
    NSString *artista = [[ZPLMTexto(faixa[@"artista"]) componentsSeparatedByString:@";"].firstObject
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString *titulo = ZPLMTexto(faixa[@"titulo"]);
    double duracao = [faixa[@"duracao"] doubleValue];
    NSString *(^base)(NSString *) = ^NSString *(NSString *t) {
        NSString *semMarcas = [t stringByReplacingOccurrencesOfString:@"[\\(\\[][^\\)\\]]*[\\)\\]]|\\s-\\s+.+$" withString:@""
                                                              options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
        return ZPLMChave(semMarcas);
    };
    NSString *kt = base(titulo), *ka = ZPLMChave(artista);
    NSURLComponents *u = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    u.queryItems = @[ [NSURLQueryItem queryItemWithName:@"term" value:[NSString stringWithFormat:@"%@ %@", artista, titulo]],
                      [NSURLQueryItem queryItemWithName:@"country" value:@"pt"], [NSURLQueryItem queryItemWithName:@"media" value:@"music"],
                      [NSURLQueryItem queryItemWithName:@"entity" value:@"song"], [NSURLQueryItem queryItemWithName:@"limit" value:@"50"] ];
    void (^acabar)(NSData *) = ^(NSData *som) { dispatch_async(dispatch_get_main_queue(), ^{ depois(som); }); };
    NSURLSession *sessao = [NSURLSession sharedSession];
    [[sessao dataTaskWithURL:u.URL completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
        NSArray *resultados = [j isKindOfClass:[NSDictionary class]] && [j[@"results"] isKindOfClass:[NSArray class]] ? j[@"results"] : @[];
        NSString *melhor = nil;
        double melhorD = 3.0;
        for (NSDictionary *x in resultados) {
            if (![x isKindOfClass:[NSDictionary class]] || ![x[@"previewUrl"] isKindOfClass:[NSString class]]
                || ![x[@"trackName"] isKindOfClass:[NSString class]] || ![x[@"trackTimeMillis"] isKindOfClass:[NSNumber class]]) continue;
            if (![base(x[@"trackName"]) isEqualToString:kt]) continue;
            NSString *xa = ZPLMChave([x[@"artistName"] isKindOfClass:[NSString class]] ? x[@"artistName"] : @"");
            if (ka.length && xa.length && ![xa containsString:ka] && ![ka containsString:xa]) continue;
            double dd = fabs([x[@"trackTimeMillis"] doubleValue] / 1000.0 - duracao);
            if (dd <= melhorD) { melhorD = dd; melhor = x[@"previewUrl"]; }
        }
        NSURL *excerto = melhor ? [NSURL URLWithString:melhor] : nil;
        if (!excerto) { acabar(nil); return; }
        [[sessao dataTaskWithURL:excerto completionHandler:^(NSData *som, NSURLResponse *r2, NSError *e2) {
            acabar(som.length >= 10000 ? som : nil);
        }] resume];
    }] resume];
}

- (void)pararAmostra {
    [self.fimDaAmostra invalidate];
    self.fimDaAmostra = nil;
    [self.amostra stop];
    self.amostra = nil;
    self.ladoDaAmostra = 0;
    if (self.botaoOuvir) [self actualizarBotoes];
}

@end
