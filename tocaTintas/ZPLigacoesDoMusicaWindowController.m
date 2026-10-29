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
#include <sqlite3.h>

// O critério com que o sincronizar encontrou a candidata: só aqui, quando a
// única é de outra duração, a sugestão é «Nenhuma» — o mesmo título com mais de
// dois segundos de diferença é quase sempre outra gravação.
static NSString *const ZPCriterioOutraDuracao = @"título, outra duração";

// Quanto da candidata se ouve, e de onde: a 30 % da duração, que passa os
// silêncios do princípio e chega a um sítio onde as versões se distinguem.
static const NSTimeInterval ZPDuracaoDaAmostra = 10.0;

#pragma mark - SQLite

// Os mesmos três passos que o ViewController usa com a base, aqui à parte: esta
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
@property (nonatomic, strong) NSButton *botaoOuvir;
@property (nonatomic, strong) NSButton *botaoAlbum;
@property (nonatomic, strong) NSButton *botaoSaltar;
@property (nonatomic, strong) NSButton *botaoLigar;

@property (nonatomic, strong, nullable) AVAudioPlayer *amostra;
@property (nonatomic, strong, nullable) NSTimer *fimDaAmostra;
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
    janela.title = NSLocalizedString(@"music_links_title", @"Ligar faixas do Música");
    janela.minSize = NSMakeSize(820, 420);
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
        @[@"artista", artista, @130], @[@"album", album, @130], @[@"faixa", numero, @32],
        @[@"titulo", titulo, @170], @[@"duracao", duracao, @48],
        @[@"vezes", NSLocalizedString(@"music_links_col_plays", @"Vezes no Música"), @44] ]];
    self.tabelaDasCandidatas = [self tabelaComColunas:@[
        @[@"artista", artista, @120], @[@"album", album, @120], @[@"faixa", numero, @32],
        @[@"titulo", titulo, @170], @[@"duracao", duracao, @80],
        @[@"formato", NSLocalizedString(@"music_links_col_format", @"Onde"), @56],
        @[@"criterio", NSLocalizedString(@"music_links_col_criterion", @"Porquê"), @110] ]];
    self.tabelaDasCandidatas.doubleAction = @selector(ligar:);
    self.tabelaDasCandidatas.target = self;

    NSSplitView *divisao = [[NSSplitView alloc] init];
    divisao.vertical = YES;
    divisao.dividerStyle = NSSplitViewDividerStyleThin;
    divisao.translatesAutoresizingMaskIntoConstraints = NO;
    [divisao addArrangedSubview:[self rolar:self.tabelaDosCasos]];
    [divisao addArrangedSubview:[self rolar:self.tabelaDasCandidatas]];
    divisao.autosaveName = @"LigacoesDoMusicaDivisao";

    self.botaoOuvir = [self botao:@"music_links_listen" comentario:@"▶︎ Ouvir 10 s" accao:@selector(ouvir:)];
    self.botaoAlbum = [self botao:@"music_links_accept_album" comentario:@"Aceitar o álbum" accao:@selector(aceitarOAlbum:)];
    self.botaoSaltar = [self botao:@"music_links_skip" comentario:@"Saltar" accao:@selector(saltar:)];
    self.botaoLigar = [self botao:@"music_links_link" comentario:@"Ligar" accao:@selector(ligar:)];
    self.botaoLigar.keyEquivalent = @"\r";

    for (NSView *x in @[self.filtro, self.contagem, divisao, self.botaoOuvir, self.botaoAlbum, self.botaoSaltar, self.botaoLigar]) {
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
        [divisao.bottomAnchor constraintEqualToAnchor:self.botaoLigar.topAnchor constant:-m],
        [self.botaoLigar.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-m],
        [self.botaoLigar.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-m],
        [self.botaoSaltar.trailingAnchor constraintEqualToAnchor:self.botaoLigar.leadingAnchor constant:-8],
        [self.botaoSaltar.centerYAnchor constraintEqualToAnchor:self.botaoLigar.centerYAnchor],
        [self.botaoAlbum.trailingAnchor constraintEqualToAnchor:self.botaoSaltar.leadingAnchor constant:-8],
        [self.botaoAlbum.centerYAnchor constraintEqualToAnchor:self.botaoLigar.centerYAnchor],
        [self.botaoOuvir.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:m],
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
                             " EXISTS (SELECT 1 FROM faixas_cd fc WHERE fc.musica = m.id) AS do_cd"
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
    self.contagem.stringValue = self.casos.count == 0
        ? NSLocalizedString(@"music_links_empty", @"Nenhuma faixa por ligar.")
        : [NSString stringWithFormat:NSLocalizedString(@"music_links_count", @"%ld por ligar"), (long)self.casos.count];
    [self actualizarBotoes];
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

// A sugestão: a primeira candidata, menos quando é de outra duração.
- (NSInteger)sugestaoPara:(NSDictionary *)caso {
    NSArray *cs = [self candidatasDe:caso];
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
    self.botaoLigar.enabled = ha;
    self.botaoSaltar.enabled = ha;
    self.botaoAlbum.enabled = ha && [ZPLMTexto([self casoSeleccionado][@"album"]) length] > 0;
    self.botaoOuvir.enabled = ha && [self candidataSeleccionada][@"caminho"] != nil;
    self.botaoOuvir.title = self.amostra
        ? NSLocalizedString(@"music_links_stop", @"■ Parar")
        : NSLocalizedString(@"music_links_listen", @"▶︎ Ouvir 10 s");
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
        if ([col isEqualToString:@"faixa"]) return [c[@"faixa"] integerValue] > 0 ? ZPLMTexto(c[@"faixa"]) : @"";
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
    if ([col isEqualToString:@"criterio"]) return ZPLMNomeDoCriterio(c[@"criterio"]);
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
    if (!caso) return;
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

// Uma amostra da candidata local, à parte do leitor do tocaTintas: não conta
// como audição (pela regra dos 5 s, dez segundos contariam) e não mexe na lista.
- (IBAction)ouvir:(id)sender {
    if (self.amostra) { [self pararAmostra]; return; }
    NSString *caminho = [self candidataSeleccionada][@"caminho"];
    if (!caminho) return;
    NSError *erro = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:[NSURL fileURLWithPath:caminho] error:&erro];
    if (!p) {
        NSLog(@"[Ligações do Música] Não consigo tocar %@: %@", caminho, erro.localizedDescription);
        NSBeep();
        return;
    }
    p.currentTime = MAX(0.0, MIN(p.duration * 0.3, p.duration - ZPDuracaoDaAmostra));
    [p play];
    self.amostra = p;
    __weak typeof(self) fraco = self;
    self.fimDaAmostra = [NSTimer scheduledTimerWithTimeInterval:ZPDuracaoDaAmostra repeats:NO block:^(NSTimer *t) {
        [fraco pararAmostra];
    }];
    [self actualizarBotoes];
}

- (void)pararAmostra {
    [self.fimDaAmostra invalidate];
    self.fimDaAmostra = nil;
    [self.amostra stop];
    self.amostra = nil;
    if (self.botaoOuvir) [self actualizarBotoes];
}

@end
