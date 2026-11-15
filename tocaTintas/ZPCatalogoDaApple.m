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
//  ZPCatalogoDaApple.m
//  tocaTintas
//
//  Created by J. Pedro Sousa do Amaral on 01/11/2026.
//

#import "ZPCatalogoDaApple.h"

// Para comparar nomes: sem maiúsculas, acentos nem pontuação («C’mere» e
// «C'mere» são o mesmo).
static NSString *ZPChaveDoNome(NSString *s) {
    NSString *f = [s ?: @"" stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    NSMutableString *k = [NSMutableString stringWithCapacity:f.length];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < f.length; ++i) {
        unichar ch = [f characterAtIndex:i];
        if ([alnum characterIsMember:ch]) [k appendFormat:@"%C", ch];
    }
    return k;
}

// O nome sem os sufixos de edição, até três («Bloom (Deluxe Edition) - EP»).
static NSString *ZPSemSufixosDeEdicao(NSString *n) {
    static NSRegularExpression *sufixo;
    static dispatch_once_t umaVez;
    dispatch_once(&umaVez, ^{
        sufixo = [NSRegularExpression regularExpressionWithPattern:
                  @"\\s*(?:[\\(\\[][^\\(\\)\\[\\]]*[\\)\\]]|-\\s*(?:EP|Single))\\s*$"
                                                           options:NSRegularExpressionCaseInsensitive error:NULL];
    });
    for (NSUInteger i = 0; i < 3; i++) {
        NSString *m = [sufixo stringByReplacingMatchesInString:n options:0 range:NSMakeRange(0, n.length) withTemplate:@""];
        if ([m isEqualToString:n]) break;
        n = m;
    }
    return n;
}

// O artista do Música é muitas vezes uma lista («Sumi Jo, Suyoen Kim & …»):
// o primeiro nome basta para a pesquisa.
static NSString *ZPPrimeiroArtista(NSString *artista) {
    return [[artista ?: @"" componentsSeparatedByCharactersInSet:
             [NSCharacterSet characterSetWithCharactersInString:@",&"]].firstObject
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
}

static id ZPSeFor(id v, Class c) { return [v isKindOfClass:c] ? v : nil; }

@implementation ZPCatalogoDaApple

+ (dispatch_queue_t)fila {
    static dispatch_queue_t fila;
    static dispatch_once_t umaVez;
    dispatch_once(&umaVez, ^{
        fila = dispatch_queue_create("JPSdA.tocaTintas.catalogo",
                                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return fila;
}

// As respostas já dadas: NSNull é «não há».
+ (NSCache *)memoria {
    static NSCache *memoria;
    static dispatch_once_t umaVez;
    dispatch_once(&umaVez, ^{
        memoria = [[NSCache alloc] init];
        memoria.countLimit = 200;
    });
    return memoria;
}

+ (NSString *)lojaDoMac {
    return [[NSLocale.currentLocale objectForKey:NSLocaleCountryCode] ?: @"US" lowercaseString];
}

// Um pedido, até 15 s; o corpo se veio 200, senão nil.
+ (nullable NSData *)pedir:(NSURL *)url {
    if (!url) return nil;
    NSMutableURLRequest *pedido = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                      timeoutInterval:15.0];
    NSString *versao = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    [pedido setValue:[NSString stringWithFormat:@"tocaTintas/%@ ( https://github.com/zpamaral )", versao]
  forHTTPHeaderField:@"User-Agent"];
    __block NSData *corpo = nil;
    dispatch_semaphore_t feito = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:pedido
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e && [r isKindOfClass:[NSHTTPURLResponse class]] && ((NSHTTPURLResponse *)r).statusCode == 200) corpo = d;
        dispatch_semaphore_signal(feito);
    }] resume];
    dispatch_semaphore_wait(feito, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    return corpo;
}

// Os resultados de «search» ou «lookup» na loja, ou nil.
+ (nullable NSArray *)resultados:(NSString *)onde loja:(NSString *)loja campos:(NSDictionary<NSString *, NSString *> *)campos {
    NSURLComponents *c = [NSURLComponents componentsWithString:[@"https://itunes.apple.com/" stringByAppendingString:onde]];
    NSMutableArray *itens = [NSMutableArray arrayWithObject:[NSURLQueryItem queryItemWithName:@"country" value:loja]];
    [campos enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *parar) {
        [itens addObject:[NSURLQueryItem queryItemWithName:k value:v]];
    }];
    c.queryItems = itens;
    NSData *d = [self pedir:c.URL];
    NSDictionary *r = d ? ZPSeFor([NSJSONSerialization JSONObjectWithData:d options:0 error:NULL], [NSDictionary class]) : nil;
    return ZPSeFor(r[@"results"], [NSArray class]);
}

// Dos resultados, os álbuns com esse nome, cada um com os seus pontos: 2 pelo
// nome igual (1 fora do modo exacto, sem os sufixos de edição), mais 2 se for
// do mesmo artista. Junta-os a `candidatos`, sem repetir o mesmo collectionId.
+ (void)juntar:(NSArray *)resultados album:(NSString *)album primeiro:(NSString *)primeiro
        exacto:(BOOL)exacto loja:(NSString *)loja a:(NSMutableArray<NSDictionary *> *)candidatos {
    NSString *chave = ZPChaveDoNome(album), *simples = ZPChaveDoNome(ZPSemSufixosDeEdicao(album));
    for (NSDictionary *a in resultados) {
        NSString *nome = ZPSeFor(ZPSeFor(a, [NSDictionary class])[@"collectionName"], [NSString class]);
        if (!nome || !a[@"collectionId"]) continue;
        if ([[candidatos valueForKey:@"collectionId"] containsObject:a[@"collectionId"]]) continue;
        NSInteger pontos = [ZPChaveDoNome(nome) isEqualToString:chave] ? 2
                         : !exacto && simples.length && [ZPChaveDoNome(ZPSemSufixosDeEdicao(nome)) isEqualToString:simples] ? 1 : 0;
        if (pontos == 0) continue;
        NSString *dele = ZPSeFor(a[@"artistName"], [NSString class]) ?: @"";
        if (primeiro.length && [dele rangeOfString:primeiro options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) pontos += 2;
        NSMutableDictionary *m = [a mutableCopy];
        m[@"loja"] = loja;   // de onde veio: as faixas e a capa pedem-se lá
        m[@"_pontos"] = @(pontos);
        [candidatos addObject:m];
    }
}

// Quantas das `marcas` ({titulo, duracao}) estão no álbum: o mesmo nome e, se
// a marca tiver duração, a menos de 1,5 s.
+ (NSUInteger)marcas:(NSArray<NSDictionary *> *)marcas noAlbum:(NSDictionary *)album {
    NSArray<NSDictionary *> *faixas = [self faixasDoAlbum:album];
    NSUInteger n = 0;
    for (NSDictionary *m in marcas) {
        NSString *chave = ZPChaveDoNome(m[@"titulo"]);
        double d = [m[@"duracao"] doubleValue];
        for (NSDictionary *t in faixas) {
            NSString *nome = ZPSeFor(t[@"trackName"], [NSString class]);
            if (!nome || ![ZPChaveDoNome(nome) isEqualToString:chave]) continue;
            if (d > 0 && fabs([ZPSeFor(t[@"trackTimeMillis"], [NSNumber class]) doubleValue] / 1000.0 - d) >= 1.5) continue;
            ++n;
            break;
        }
    }
    return n;
}

// Dos candidatos, o de mais pontos. Empatados — dois álbuns com o mesmo nome e
// do mesmo artista, como os dois «Alfredo Marceneiro» de 2006, um da World
// Music Records e outro da Valentim de Carvalho, com alinhamentos diferentes
// (visto em 2026-11-15: a gravação de um mostrava os números do outro) —
// decidem as marcas: o que tiver mais delas, se for um só. Se nem elas
// desempatarem, nil: um álbum adivinhado dá números e durações de outro disco.
+ (nullable NSDictionary *)escolher:(NSArray<NSDictionary *> *)candidatos marcas:(nullable NSArray<NSDictionary *> *)marcas {
    NSInteger topo = [[candidatos valueForKeyPath:@"@max._pontos"] integerValue];
    NSMutableArray<NSDictionary *> *empatados = [NSMutableArray array];
    for (NSDictionary *a in candidatos) if ([a[@"_pontos"] integerValue] == topo) [empatados addObject:a];
    NSDictionary *escolhido = nil;
    if (empatados.count == 1) {
        escolhido = empatados.firstObject;
    } else if (empatados.count > 1 && marcas.count) {
        NSUInteger melhor = 0, quantos = 0;
        for (NSDictionary *a in empatados) {
            NSUInteger n = [self marcas:marcas noAlbum:a];
            if (n > melhor) { melhor = n; quantos = 1; escolhido = a; }
            else if (n == melhor && n > 0) ++quantos;
        }
        if (quantos != 1) escolhido = nil;
    }
    if (!escolhido) return nil;
    NSMutableDictionary *m = [escolhido mutableCopy];
    [m removeObjectForKey:@"_pontos"];
    return m;
}

+ (nullable NSDictionary *)albumNaLoja:(NSString *)loja primeiro:(NSString *)primeiro album:(NSString *)album
                                marcas:(nullable NSArray<NSDictionary *> *)marcas exacto:(BOOL)exacto {
    NSMutableArray<NSDictionary *> *candidatos = [NSMutableArray array];
    // Pelo artista: os álbuns dele, todos. Há artistas com o mesmo nome (três
    // «Alex G», dois «Alfredo Marceneiro»): vêem-se os que tiverem exactamente
    // esse, até três, e juntam-se os álbuns de todos.
    if (primeiro.length) {
        NSUInteger vistos = 0;
        for (NSDictionary *a in [self resultados:@"search" loja:loja
                                          campos:@{ @"term": primeiro, @"entity": @"musicArtist", @"limit": @"5" }]) {
            NSString *nome = ZPSeFor(ZPSeFor(a, [NSDictionary class])[@"artistName"], [NSString class]);
            if (!nome || !a[@"artistId"] || ![ZPChaveDoNome(nome) isEqualToString:ZPChaveDoNome(primeiro)]) continue;
            [self juntar:[self resultados:@"lookup" loja:loja
                                   campos:@{ @"id": [a[@"artistId"] description], @"entity": @"album", @"limit": @"200" }]
                   album:album primeiro:primeiro exacto:exacto loja:loja a:candidatos];
            if (++vistos >= 3) break;
        }
        if (candidatos.count) return [self escolher:candidatos marcas:marcas];
    }
    [self juntar:[self resultados:@"search" loja:loja
                           campos:@{ @"term": [NSString stringWithFormat:@"%@ %@", primeiro, album],
                                     @"entity": @"album", @"limit": @"25" }]
           album:album primeiro:primeiro exacto:exacto loja:loja a:candidatos];
    NSString *titulo = marcas.firstObject[@"titulo"];
    if (!candidatos.count && [titulo length]) {
        [self juntar:[self resultados:@"search" loja:loja
                               campos:@{ @"term": [NSString stringWithFormat:@"%@ %@", primeiro, titulo],
                                         @"entity": @"song", @"limit": @"50" }]
               album:album primeiro:primeiro exacto:exacto loja:loja a:candidatos];
    }
    return candidatos.count ? [self escolher:candidatos marcas:marcas] : nil;
}

+ (nullable NSDictionary *)albumDe:(NSString *)artista chamado:(NSString *)album
                            marcas:(nullable NSArray<NSDictionary *> *)marcas
                             lojas:(NSArray<NSString *> *)lojas exacto:(BOOL)exacto {
    if (album.length == 0) return nil;
    NSString *primeiro = ZPPrimeiroArtista(artista);
    NSMutableString *dasMarcas = [NSMutableString string];
    for (NSDictionary *m in marcas) [dasMarcas appendFormat:@"%@/%.1f;", m[@"titulo"], [m[@"duracao"] doubleValue]];
    NSString *chave = [NSString stringWithFormat:@"album|%@|%d|%@|%@|%@", [lojas componentsJoinedByString:@","],
                       exacto, primeiro, album, dasMarcas];
    id visto = [[self memoria] objectForKey:chave];
    if (visto) return visto == [NSNull null] ? nil : visto;
    NSDictionary *achado = nil;
    for (NSString *loja in lojas) {
        achado = [self albumNaLoja:loja primeiro:primeiro album:album marcas:marcas exacto:exacto];
        if (achado) break;
    }
    [[self memoria] setObject:achado ?: [NSNull null] forKey:chave];
    return achado;
}

+ (NSArray<NSDictionary *> *)faixasDoAlbum:(NSDictionary *)album {
    if (!album[@"collectionId"]) return @[];
    NSString *loja = album[@"loja"] ?: [self lojaDoMac];
    NSString *chave = [NSString stringWithFormat:@"faixas|%@|%@", loja, album[@"collectionId"]];
    NSArray *visto = [[self memoria] objectForKey:chave];
    if (visto) return visto;
    NSMutableArray *faixas = [NSMutableArray array];
    for (NSDictionary *t in [self resultados:@"lookup" loja:loja
                                      campos:@{ @"id": [album[@"collectionId"] description], @"entity": @"song" }]) {
        if ([ZPSeFor(t, [NSDictionary class])[@"wrapperType"] isEqual:@"track"] && [t[@"kind"] isEqual:@"song"]) [faixas addObject:t];
    }
    if (faixas.count) [[self memoria] setObject:faixas forKey:chave];
    return faixas;
}

+ (nullable NSData *)capaDoAlbum:(NSDictionary *)album lado:(NSUInteger)lado {
    NSString *arte = ZPSeFor(album[@"artworkUrl100"], [NSString class]);
    if (!arte) return nil;
    NSString *tamanho = [NSString stringWithFormat:@"%lux%lubb", (unsigned long)lado, (unsigned long)lado];
    NSString *chave = [NSString stringWithFormat:@"capa|%@|%@", arte, tamanho];
    NSData *vista = [[self memoria] objectForKey:chave];
    if (vista) return vista;
    NSData *capa = [self pedir:[NSURL URLWithString:[arte stringByReplacingOccurrencesOfString:@"100x100bb" withString:tamanho]]];
    if (capa.length) [[self memoria] setObject:capa forKey:chave];
    return capa.length ? capa : nil;
}

+ (void)capaDe:(NSString *)artista album:(NSString *)album titulo:(nullable NSString *)titulo
     concluido:(void (^)(NSData *_Nullable))concluido {
    dispatch_async([self fila], ^{
        NSDictionary *a = [self albumDe:artista chamado:album marcas:titulo.length ? @[ @{ @"titulo": titulo } ] : nil
                                  lojas:@[ [self lojaDoMac] ] exacto:NO];
        NSData *capa = a ? [self capaDoAlbum:a lado:600] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ concluido(capa); });
    });
}

// A faixa do catálogo que corresponde a uma do Música: pelo nome; senão pela
// duração, a menos de 1,5 s, se só uma cair aí. Síncrono.
+ (nullable NSDictionary *)faixaDe:(NSString *)artista album:(NSString *)album titulo:(NSString *)titulo
                           duracao:(double)duracao todas:(NSArray<NSDictionary *> *_Nullable *_Nullable)todas {
    NSDictionary *a = [self albumDe:artista chamado:album marcas:@[ @{ @"titulo": titulo ?: @"", @"duracao": @(duracao) } ]
                              lojas:@[ [self lojaDoMac] ] exacto:NO];
    NSArray<NSDictionary *> *faixas = a ? [self faixasDoAlbum:a] : @[];
    NSString *chave = ZPChaveDoNome(titulo);
    NSDictionary *achada = nil;
    for (NSDictionary *t in faixas) {
        NSString *nome = ZPSeFor(t[@"trackName"], [NSString class]);
        if (nome && [ZPChaveDoNome(nome) isEqualToString:chave]) { achada = t; break; }
    }
    if (!achada && duracao > 0) {
        NSUInteger perto = 0;
        for (NSDictionary *t in faixas) {
            if (fabs([ZPSeFor(t[@"trackTimeMillis"], [NSNumber class]) doubleValue] / 1000.0 - duracao) < 1.5) {
                achada = t;
                ++perto;
            }
        }
        if (perto != 1) achada = nil;
    }
    if (todas) *todas = faixas;
    return achada;
}

+ (void)posicaoDe:(NSString *)artista album:(NSString *)album titulo:(NSString *)titulo duracao:(double)duracao
        concluido:(void (^)(NSInteger, NSInteger))concluido {
    dispatch_async([self fila], ^{
        NSArray<NSDictionary *> *faixas = nil;
        NSDictionary *achada = [self faixaDe:artista album:album titulo:titulo duracao:duracao todas:&faixas];
        // O «trackCount» da Apple não é de fiar (ver o ZPPosGravacao): contam-se
        // as faixas do mesmo disco.
        NSInteger faixa = [ZPSeFor(achada[@"trackNumber"], [NSNumber class]) integerValue], total = 0;
        if (faixa > 0) {
            for (NSDictionary *t in faixas) if ([t[@"discNumber"] isEqual:achada[@"discNumber"]]) ++total;
        }
        if (total < faixa) faixa = total = 0;
        dispatch_async(dispatch_get_main_queue(), ^{ concluido(faixa, total); });
    });
}

+ (void)excertoDe:(NSString *)artista album:(NSString *)album titulo:(NSString *)titulo duracao:(double)duracao
        concluido:(void (^)(NSURL *_Nullable))concluido {
    dispatch_async([self fila], ^{
        NSDictionary *faixa = [self faixaDe:artista album:album titulo:titulo duracao:duracao todas:NULL];
        NSString *endereco = ZPSeFor(faixa[@"previewUrl"], [NSString class]);
        NSData *som = endereco ? [self pedir:[NSURL URLWithString:endereco]] : nil;
        NSURL *ficheiro = nil;
        if (som.length) {
            ficheiro = [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:
                        [NSString stringWithFormat:@"tocaTintas-excerto-%@.m4a", NSUUID.UUID.UUIDString]];
            if (![som writeToURL:ficheiro atomically:YES]) ficheiro = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ concluido(ficheiro); });
    });
}

@end
