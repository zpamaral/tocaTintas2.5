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

// Dos resultados, o álbum com esse nome; o do mesmo artista à frente.
+ (nullable NSDictionary *)melhor:(NSArray *)resultados album:(NSString *)album
                         primeiro:(NSString *)primeiro exacto:(BOOL)exacto {
    NSString *chave = ZPChaveDoNome(album), *simples = ZPChaveDoNome(ZPSemSufixosDeEdicao(album));
    NSDictionary *melhor = nil;
    NSInteger melhorPontos = 0;
    for (NSDictionary *a in resultados) {
        NSString *nome = ZPSeFor(ZPSeFor(a, [NSDictionary class])[@"collectionName"], [NSString class]);
        if (!nome || !a[@"collectionId"]) continue;
        NSInteger pontos = [ZPChaveDoNome(nome) isEqualToString:chave] ? 2
                         : !exacto && simples.length && [ZPChaveDoNome(ZPSemSufixosDeEdicao(nome)) isEqualToString:simples] ? 1 : 0;
        if (pontos == 0) continue;
        NSString *dele = ZPSeFor(a[@"artistName"], [NSString class]) ?: @"";
        if (primeiro.length && [dele rangeOfString:primeiro options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) pontos += 2;
        if (pontos > melhorPontos) { melhor = a; melhorPontos = pontos; }
    }
    return melhor;
}

+ (nullable NSDictionary *)albumNaLoja:(NSString *)loja primeiro:(NSString *)primeiro album:(NSString *)album
                                titulo:(nullable NSString *)titulo exacto:(BOOL)exacto {
    // Pelo artista: os álbuns dele, todos. Há artistas com o mesmo nome (três
    // «Alex G»): vêem-se os que tiverem exactamente esse, até três.
    if (primeiro.length) {
        NSUInteger vistos = 0;
        for (NSDictionary *a in [self resultados:@"search" loja:loja
                                          campos:@{ @"term": primeiro, @"entity": @"musicArtist", @"limit": @"5" }]) {
            NSString *nome = ZPSeFor(ZPSeFor(a, [NSDictionary class])[@"artistName"], [NSString class]);
            if (!nome || !a[@"artistId"] || ![ZPChaveDoNome(nome) isEqualToString:ZPChaveDoNome(primeiro)]) continue;
            NSDictionary *achado = [self melhor:[self resultados:@"lookup" loja:loja
                                                          campos:@{ @"id": [a[@"artistId"] description], @"entity": @"album",
                                                                    @"limit": @"200" }]
                                          album:album primeiro:primeiro exacto:exacto];
            if (achado) return achado;
            if (++vistos >= 3) break;
        }
    }
    NSDictionary *achado = [self melhor:[self resultados:@"search" loja:loja
                                                  campos:@{ @"term": [NSString stringWithFormat:@"%@ %@", primeiro, album],
                                                            @"entity": @"album", @"limit": @"25" }]
                                  album:album primeiro:primeiro exacto:exacto];
    if (!achado && titulo.length) {
        achado = [self melhor:[self resultados:@"search" loja:loja
                                        campos:@{ @"term": [NSString stringWithFormat:@"%@ %@", primeiro, titulo],
                                                  @"entity": @"song", @"limit": @"50" }]
                        album:album primeiro:primeiro exacto:exacto];
    }
    return achado;
}

+ (nullable NSDictionary *)albumDe:(NSString *)artista chamado:(NSString *)album titulo:(nullable NSString *)titulo
                             lojas:(NSArray<NSString *> *)lojas exacto:(BOOL)exacto {
    if (album.length == 0) return nil;
    NSString *primeiro = ZPPrimeiroArtista(artista);
    NSString *chave = [NSString stringWithFormat:@"album|%@|%d|%@|%@|%@", [lojas componentsJoinedByString:@","],
                       exacto, primeiro, album, titulo ?: @""];
    id visto = [[self memoria] objectForKey:chave];
    if (visto) return visto == [NSNull null] ? nil : visto;
    NSDictionary *achado = nil;
    for (NSString *loja in lojas) {
        NSDictionary *a = [self albumNaLoja:loja primeiro:primeiro album:album titulo:titulo exacto:exacto];
        if (a) {
            NSMutableDictionary *m = [a mutableCopy];
            m[@"loja"] = loja;   // de onde veio: as faixas e a capa pedem-se lá
            achado = m;
            break;
        }
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
        NSDictionary *a = [self albumDe:artista chamado:album titulo:titulo lojas:@[ [self lojaDoMac] ] exacto:NO];
        NSData *capa = a ? [self capaDoAlbum:a lado:600] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ concluido(capa); });
    });
}

@end
