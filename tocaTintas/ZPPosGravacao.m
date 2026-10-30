//
//  ZPPosGravacao.m
//  tocaTintas
//
//  O processamento automático de uma gravação, depois de fechada: rampas,
//  cortes, FLAC, etiquetas, capa e ReplayGain. Ver ZPPosGravacao.h.
//
//  Feito à mão antes, em Python, nas gravações de 2026-10 (DIIV, Respighi,
//  Low): cada passo aqui é o que lá deu certo, com os números de lá.
//

#import "ZPPosGravacao.h"
#import <AppKit/AppKit.h>
#include <FLAC/metadata.h>
#include <FLAC/stream_encoder.h>
#include <math.h>

// A marca do Música e a soma das durações do catálogo discordam até uns 55 ms
// (medido no Low: a latência do Apple Event e o tamanho dos blocos). Acima
// disto, alguma coisa aconteceu entre as duas faixas — pausa, salto, faixa
// tirada a meio — e manda a marca.
static const double kZPToleranciaDaMarca = 0.25;   // s

// As rampas do Música duram uns 25 ms e encostam sempre a silêncio digital;
// procuram-se até esta distância dele (o mesmo número do vigia da grelha).
static const long long kZPTramasDeRampa = 2400;

// O critério para desfazer uma rampa: todas as amostras de volta à grelha com
// erro abaixo disto. No Low, com o grau 5, o erro foi de 0,00003 LSB.
static const double kZPErroMaximoDaRampa = 0.01;   // LSB

static const NSUInteger kZPTamanhoDoCabecalhoWav = 56;

#pragma mark - A gravação, com as correcções por cima

typedef struct {
    const float *x;   // intercalado, dois canais
    long long n;      // tramas
    double taxa;
} ZPGravacao;

// Um pedaço de amostras corrigidas (uma rampa desfeita), lido por cima das do
// ficheiro. O ficheiro, mapeado, nunca se altera.
typedef struct {
    long long inicio, n;
    float *valores;   // 2n
} ZPCorreccao;

static void ZPLer(const ZPGravacao *g, const ZPCorreccao *cs, int nc, long long inicio, long long n, float *destino) {
    memcpy(destino, g->x + 2 * inicio, (size_t)(2 * n) * sizeof(float));
    for (int k = 0; k < nc; ++k) {
        long long a = MAX(inicio, cs[k].inicio), b = MIN(inicio + n, cs[k].inicio + cs[k].n);
        if (a < b) {
            memcpy(destino + 2 * (a - inicio), cs[k].valores + 2 * (a - cs[k].inicio),
                   (size_t)(2 * (b - a)) * sizeof(float));
        }
    }
}

// Multiplicar por potências de 2 é exacto em float.
static inline BOOL ZPForaDaGrelha(float v, float unidade) {
    float q = v * unidade;
    return q != rintf(q);
}

static long long ZPPrimeiroSom(const ZPGravacao *g, long long desde, long long ate) {
    for (long long i = MAX(desde, 0); i < MIN(ate, g->n); ++i) {
        if (g->x[2*i] != 0.0f || g->x[2*i+1] != 0.0f) return i;
    }
    return -1;
}

static NSString *ZPTempo(long long trama, double taxa) {
    double s = trama / taxa;
    int m = (int)(s / 60.0);
    return [NSString stringWithFormat:@"%d:%06.3f", m, s - 60.0 * m];
}

#pragma mark - Rampas

// Mínimos quadrados de um polinómio de grau `grau` em t ∈ [0, 1], pelas
// equações normais. Bem condicionado até ao grau 5 neste intervalo.
static BOOL ZPAjustarPolinomio(const double *t, const double *y, long m, int grau, double *coef) {
    int k = grau + 1;
    double A[8][9];
    memset(A, 0, sizeof(A));
    for (long i = 0; i < m; ++i) {
        double p[16];
        p[0] = 1.0;
        for (int j = 1; j < 2 * k; ++j) p[j] = p[j-1] * t[i];
        for (int r = 0; r < k; ++r) {
            for (int c = 0; c < k; ++c) A[r][c] += p[r + c];
            A[r][k] += p[r] * y[i];
        }
    }
    for (int c = 0; c < k; ++c) {
        int piv = c;
        for (int r = c + 1; r < k; ++r) if (fabs(A[r][c]) > fabs(A[piv][c])) piv = r;
        if (fabs(A[piv][c]) < 1e-300) return NO;
        if (piv != c) for (int j = 0; j <= k; ++j) { double tmp = A[c][j]; A[c][j] = A[piv][j]; A[piv][j] = tmp; }
        for (int r = 0; r < k; ++r) {
            if (r == c) continue;
            double f = A[r][c] / A[c][c];
            for (int j = c; j <= k; ++j) A[r][j] -= f * A[c][j];
        }
    }
    for (int c = 0; c < k; ++c) coef[c] = A[c][k] / A[c][c];
    return YES;
}

static inline double ZPPolinomio(const double *coef, int grau, double t) {
    double v = 0.0;
    for (int j = grau; j >= 0; --j) v = v * t + coef[j];
    return v;
}

// Desfaz o ganho de uma rampa. O ganho lê-se nas amostras pequenas: um inteiro
// n de 1 a 4 multiplicado por um ganho entre 0,8 e 1 cai em (0,8n, n], e esses
// intervalos não se tocam — o n é ceil(|x|), e o ganho |x|/n. Um polinómio
// liga esses pontos; dividir por ele tem de devolver inteiros a TODAS as
// amostras, senão a rampa fica como está. Tenta-se a grelha de 16 bits e
// depois a de 24. Devolve as amostras corrigidas (para libertar com free) ou
// NULL; em `erroMax` o erro da melhor tentativa, ou −1 se nenhuma chegou a
// medir. Sem infinitos: o projecto compila com matemática rápida, e com ela o
// compilador supõe que não os há.
static float *ZPDesfazerRampa(const float *r, long long n, double *erroMax, int *bits) {
    static const double unidades[2] = { 32768.0, 8388608.0 };
    static const int bitsDe[2] = { 16, 24 };
    double *ts = malloc(sizeof(double) * (size_t)(2 * n));
    double *gs = malloc(sizeof(double) * (size_t)(2 * n));
    float *saida = NULL;
    *erroMax = -1.0;
    for (int u = 0; u < 2 && !saida; ++u) {
        double U = unidades[u];
        long m = 0;
        double tMin = 1.0, tMax = 0.0;
        for (long long i = 0; i < n; ++i) {
            double t = n > 1 ? (double)i / (double)(n - 1) : 0.0;
            for (int c = 0; c < 2; ++c) {
                double v = fabs((double)r[2*i+c]) * U;
                if (v <= 0.0 || v > 4.0) continue;
                double nn = ceil(v);
                if (v <= 0.8 * nn) continue;
                ts[m] = t; gs[m] = v / nn; ++m;
                tMin = MIN(tMin, t); tMax = MAX(tMax, t);
            }
        }
        if (m < 12 || tMin > 0.34 || tMax < 0.66) continue;
        int grau = m >= 40 ? 5 : 3;
        double coef[8];
        if (!ZPAjustarPolinomio(ts, gs, m, grau, coef)) continue;

        float *c = malloc(sizeof(float) * (size_t)(2 * n));
        double pior = 0.0;
        BOOL valido = YES;
        for (long long i = 0; i < n && valido; ++i) {
            double t = n > 1 ? (double)i / (double)(n - 1) : 0.0;
            double ganho = ZPPolinomio(coef, grau, t);
            if (ganho < 0.05 || ganho > 1.05) { valido = NO; break; }
            for (int k = 0; k < 2; ++k) {
                double v = r[2*i+k];
                if (v == 0.0) { c[2*i+k] = 0.0f; continue; }
                double q = v * U / ganho;
                pior = MAX(pior, fabs(q - rint(q)));
                c[2*i+k] = (float)(rint(q) / U);
            }
        }
        if (valido) *erroMax = *erroMax < 0.0 ? pior : MIN(*erroMax, pior);
        if (valido && pior < kZPErroMaximoDaRampa) {
            saida = c;
            *bits = bitsDe[u];
        } else {
            free(c);
        }
    }
    free(ts);
    free(gs);
    return saida;
}

// As rampas encostam a silêncio digital: a de entrada logo depois dele, a de
// saída logo antes. Cada uma é a sequência de tramas fora da grelha de 24 bits
// (que contém a de 16) nesse sítio; numa gravação bit-exacta, fora das rampas
// não há nenhuma.
static int ZPProcurarRampas(const ZPGravacao *g, NSArray<NSArray<NSNumber *> *> *silencios,
                            ZPCorreccao **saida, NSMutableArray<NSString *> *notas) {
    int nc = 0, capacidade = 8;
    ZPCorreccao *cs = malloc(sizeof(ZPCorreccao) * (size_t)capacidade);
    for (NSArray<NSNumber *> *s in silencios) {
        if (s.count < 2) continue;
        long long a = s[0].longLongValue, b = s[1].longLongValue;
        for (int lado = 0; lado < 2; ++lado) {
            long long r0 = -1, r1 = -1;
            if (lado == 0 && b < g->n) {               // entrada: depois do silêncio
                for (long long i = b; i < MIN(b + kZPTramasDeRampa, g->n); ++i) {
                    if (ZPForaDaGrelha(g->x[2*i], 8388608.0f) || ZPForaDaGrelha(g->x[2*i+1], 8388608.0f)) r1 = i + 1;
                }
                if (r1 > 0) r0 = b;
            } else if (lado == 1 && a > 0) {           // saída: antes do silêncio
                for (long long i = a - 1; i >= MAX(a - kZPTramasDeRampa, 0); --i) {
                    if (ZPForaDaGrelha(g->x[2*i], 8388608.0f) || ZPForaDaGrelha(g->x[2*i+1], 8388608.0f)) r0 = i;
                }
                if (r0 >= 0) r1 = a;
            }
            if (r0 < 0 || r1 <= r0) continue;

            double erro = -1.0;
            int bits = 0;
            float *c = ZPDesfazerRampa(g->x + 2 * r0, r1 - r0, &erro, &bits);
            NSString *qual = lado == 0 ? @"entrada" : @"saída";
            if (c) {
                if (nc == capacidade) {
                    capacidade *= 2;
                    cs = realloc(cs, sizeof(ZPCorreccao) * (size_t)capacidade);
                }
                cs[nc++] = (ZPCorreccao){ r0, r1 - r0, c };
                [notas addObject:[NSString stringWithFormat:@"Rampa de %@ aos %@ (%lld tramas): desfeita na grelha de %d bits, erro máximo %.5f LSB.",
                                  qual, ZPTempo(r0, g->taxa), r1 - r0, bits, erro]];
            } else {
                [notas addObject:[NSString stringWithFormat:@"Rampa de %@ aos %@ (%lld tramas): fica como está (%@).",
                                  qual, ZPTempo(r0, g->taxa), r1 - r0,
                                  erro >= 0.0 ? [NSString stringWithFormat:@"erro máximo %.4f LSB", erro]
                                                 : @"poucos pontos para medir o ganho"]];
            }
        }
    }
    *saida = cs;
    return nc;
}

#pragma mark - Rede: catálogo da Apple e MusicBrainz

// Um GET síncrono. O MusicBrainz responde 503 («server is currently busy»)
// quando está carregado — visto em 2026-10-30, numa em cada duas corridas do
// Low, e às vezes durante mais de 12 s —, e então tenta-se mais cinco vezes,
// com esperas de 2, 4, 8, 16 e 30 s: corre em segundo plano, pode esperar. Em
// `respondeu`, se chegou alguma resposta definitiva (200 ou 404).
static NSData *ZPPedirUmaVez(NSURL *url, NSInteger *codigo);

static NSData *ZPPedir(NSURL *url, BOOL *respondeu) {
    if (respondeu) *respondeu = NO;
    if (!url) return nil;
    static const double esperas[] = { 0.0, 2.0, 4.0, 8.0, 16.0, 30.0 };
    for (int tentativa = 0; tentativa < 6; ++tentativa) {
        if (esperas[tentativa] > 0.0) [NSThread sleepForTimeInterval:esperas[tentativa]];
        NSInteger codigo = 0;
        NSData *corpo = ZPPedirUmaVez(url, &codigo);
        if (codigo == 200 || codigo == 404) {
            if (respondeu) *respondeu = YES;
            return corpo;
        }
        if (codigo != 503 && codigo != 0) return nil;   // outro erro: não vale a pena insistir
    }
    return nil;
}

static NSData *ZPPedirUmaVez(NSURL *url, NSInteger *codigoDevolvido) {
    NSMutableURLRequest *pedido = [NSMutableURLRequest requestWithURL:url
                                                          cachePolicy:NSURLRequestUseProtocolCachePolicy
                                                      timeoutInterval:15.0];
    NSString *versao = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
    [pedido setValue:[NSString stringWithFormat:@"tocaTintas/%@ ( https://github.com/zpamaral )", versao]
  forHTTPHeaderField:@"User-Agent"];
    __block NSData *corpo = nil;
    __block NSInteger codigo = 0;
    dispatch_semaphore_t feito = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:pedido
                                     completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        codigo = [r isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        if (!e && codigo == 200) corpo = d;
        dispatch_semaphore_signal(feito);
    }] resume];
    dispatch_semaphore_wait(feito, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)));
    *codigoDevolvido = codigo;
    return corpo;
}

static id ZPPedirJSON(NSURL *url, BOOL *respondeu) {
    NSData *d = ZPPedir(url, respondeu);
    return d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL] : nil;
}

static NSURL *ZPEndereco(NSString *base, NSDictionary<NSString *, NSString *> *pergunta) {
    NSURLComponents *c = [NSURLComponents componentsWithString:base];
    NSMutableArray *itens = [NSMutableArray array];
    for (NSString *k in pergunta) [itens addObject:[NSURLQueryItem queryItemWithName:k value:pergunta[k]]];
    c.queryItems = itens;
    return c.URL;
}

// Para comparar nomes: sem maiúsculas, acentos nem pontuação.
static NSString *ZPChave(NSString *s) {
    NSString *f = [s ?: @"" stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    NSMutableString *k = [NSMutableString string];
    NSCharacterSet *alnum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < f.length; ++i) {
        unichar ch = [f characterAtIndex:i];
        if ([alnum characterIsMember:ch]) [k appendFormat:@"%C", ch];
    }
    return k;
}

// A Apple acrescenta « - EP» e « - Single» ao nome dos álbuns, no catálogo e
// no Música; o MusicBrainz e a fonoteca não («Belly Up - EP» dos Moin, em
// 2026-10-30, não deu com a edição «Belly Up» do MusicBrainz).
static NSString *ZPSemSufixoDaApple(NSString *album) {
    for (NSString *sufixo in @[ @" - EP", @" - Single" ]) {
        if ([album hasSuffix:sufixo]) return [album substringToIndex:album.length - sufixo.length];
    }
    return album;
}

// O álbum no catálogo da Apple: a loja americana primeiro, que dá os géneros
// em inglês, como os da fonoteca (a portuguesa deu «Alternativa» no Low);
// depois a portuguesa, para o que só lá houver. Devolve @{ @"album": …,
// @"faixas": @[…] } com os campos do iTunes Search API, ou nil.
static NSDictionary *ZPCatalogoDaApple(NSString *artista, NSString *album) {
    NSString *chaveAlbum = ZPChave(album), *chaveArtista = ZPChave(artista);
    for (NSString *pais in @[ @"us", @"pt" ]) {
        NSDictionary *r = ZPPedirJSON(ZPEndereco(@"https://itunes.apple.com/search",
            @{ @"term": [NSString stringWithFormat:@"%@ %@", artista, album], @"entity": @"album",
               @"country": pais, @"limit": @"25" }), NULL);
        NSDictionary *escolhido = nil;
        for (NSDictionary *a in r[@"results"]) {
            if (![ZPChave(a[@"collectionName"]) isEqualToString:chaveAlbum]) continue;
            NSString *ca = ZPChave(a[@"artistName"]);
            if (chaveArtista.length && ![ca containsString:chaveArtista] && ![chaveArtista containsString:ca]) continue;
            escolhido = a;
            break;
        }
        if (!escolhido) continue;
        NSDictionary *l = ZPPedirJSON(ZPEndereco(@"https://itunes.apple.com/lookup",
            @{ @"id": [escolhido[@"collectionId"] description], @"entity": @"song", @"country": pais }), NULL);
        NSMutableArray *faixas = [NSMutableArray array];
        for (NSDictionary *t in l[@"results"]) {
            if ([t[@"wrapperType"] isEqualToString:@"track"] && [t[@"kind"] isEqualToString:@"song"]) [faixas addObject:t];
        }
        if (faixas.count) return @{ @"album": escolhido, @"faixas": faixas, @"pais": pais };
    }
    return nil;
}

// A edição no MusicBrainz, só se bater sem ambiguidade: o mesmo número de
// faixas e todas as durações a menos de 1,5 s das que se conhecem. Entre as
// que batem, a digital primeiro (é o que o streaming é). Devolve a edição com
// gravações, ISRC, editoras e grupo, ou nil. O MusicBrainz pede no máximo um
// pedido por segundo. Em `respondeu`, NO se algum pedido ficou sem resposta:
// então «nenhuma bate» pode não ser verdade.
static NSDictionary *ZPEdicaoNoMusicBrainz(NSString *artista, NSString *album, NSArray<NSNumber *> *duracoesMs, BOOL *respondeu) {
    BOOL ok = YES;
    *respondeu = YES;
    NSString *q = [NSString stringWithFormat:@"release:\"%@\" AND artist:\"%@\" AND tracks:%lu",
                   [album stringByReplacingOccurrencesOfString:@"\"" withString:@""],
                   [artista stringByReplacingOccurrencesOfString:@"\"" withString:@""],
                   (unsigned long)duracoesMs.count];
    NSDictionary *r = ZPPedirJSON(ZPEndereco(@"https://musicbrainz.org/ws/2/release/",
                                             @{ @"query": q, @"fmt": @"json", @"limit": @"10" }), &ok);
    if (!ok) *respondeu = NO;
    NSMutableArray<NSDictionary *> *candidatas = [NSMutableArray array];
    for (NSDictionary *e in r[@"releases"]) {
        if ([e[@"score"] integerValue] < 90) continue;
        BOOL digital = NO;
        for (NSDictionary *m in e[@"media"]) if ([m[@"format"] isEqual:@"Digital Media"]) digital = YES;
        if (digital) [candidatas insertObject:e atIndex:0]; else [candidatas addObject:e];
    }
    NSUInteger pedidos = 0;
    for (NSDictionary *e in candidatas) {
        if (++pedidos > 4) break;
        [NSThread sleepForTimeInterval:1.1];
        NSDictionary *d = ZPPedirJSON(ZPEndereco([NSString stringWithFormat:@"https://musicbrainz.org/ws/2/release/%@", e[@"id"]],
                                                 @{ @"inc": @"recordings+isrcs+labels+release-groups+artist-credits", @"fmt": @"json" }), &ok);
        if (!ok) *respondeu = NO;
        NSMutableArray *faixas = [NSMutableArray array];
        for (NSDictionary *m in d[@"media"]) [faixas addObjectsFromArray:m[@"tracks"] ?: @[]];
        if (faixas.count != duracoesMs.count) continue;
        BOOL bate = YES;
        for (NSUInteger i = 0; i < faixas.count && bate; ++i) {
            id l = faixas[i][@"length"];
            if (![l isKindOfClass:[NSNumber class]] || fabs([l doubleValue] - duracoesMs[i].doubleValue) > 1500.0) bate = NO;
        }
        if (bate) return d;
    }
    return nil;
}

#pragma mark - ReplayGain (BS.1770)

// O filtro K da BS.1770 a qualquer frequência: as fórmulas do libebur128, que
// dão os coeficientes da norma (escritos para 48 kHz) a partir dos pólos.
typedef struct { double b0, b1, b2, a1, a2, z1, z2; } ZPBiquad;

static inline double ZPPassar(ZPBiquad *f, double x) {
    double y = f->b0 * x + f->z1;
    f->z1 = f->b1 * x - f->a1 * y + f->z2;
    f->z2 = f->b2 * x - f->a2 * y;
    return y;
}

static void ZPFiltroK(double taxa, ZPBiquad *prefiltro, ZPBiquad *passaAlto) {
    double f0 = 1681.974450955533, G = 3.999843853973347, Q = 0.7071752369554196;
    double K = tan(M_PI * f0 / taxa);
    double Vh = pow(10.0, G / 20.0), Vb = pow(Vh, 0.4996667741545416);
    double a0 = 1.0 + K / Q + K * K;
    *prefiltro = (ZPBiquad){ (Vh + Vb * K / Q + K * K) / a0, 2.0 * (K * K - Vh) / a0, (Vh - Vb * K / Q + K * K) / a0,
                             2.0 * (K * K - 1.0) / a0, (1.0 - K / Q + K * K) / a0, 0, 0 };
    f0 = 38.13547087602444; Q = 0.5003270373238773;
    K = tan(M_PI * f0 / taxa);
    a0 = 1.0 + K / Q + K * K;
    *passaAlto = (ZPBiquad){ 1.0, -2.0, 1.0, 2.0 * (K * K - 1.0) / a0, (1.0 - K / Q + K * K) / a0, 0, 0 };
}

// Energia dos blocos de 400 ms, de 100 em 100 ms, de uma faixa; e o pico.
static NSData *ZPBlocosDeEnergia(const ZPGravacao *g, const ZPCorreccao *cs, int nc,
                                 long long inicio, long long fim, double *pico) {
    ZPBiquad pre[2], alto[2];
    ZPFiltroK(g->taxa, &pre[0], &alto[0]);
    pre[1] = pre[0]; alto[1] = alto[0];
    long long seg = llround(g->taxa * 0.1);
    NSMutableData *segmentos = [NSMutableData data];
    double soma = 0.0;
    long long noSegmento = 0;
    *pico = 0.0;
    const long long pedaco = 65536;
    float *buf = malloc(sizeof(float) * 2 * pedaco);
    for (long long p = inicio; p < fim; p += pedaco) {
        long long n = MIN(pedaco, fim - p);
        ZPLer(g, cs, nc, p, n, buf);
        for (long long i = 0; i < n; ++i) {
            for (int c = 0; c < 2; ++c) {
                double v = buf[2*i+c];
                if (fabs(v) > *pico) *pico = fabs(v);
                double y = ZPPassar(&alto[c], ZPPassar(&pre[c], v));
                soma += y * y;
            }
            if (++noSegmento == seg) {
                [segmentos appendBytes:&soma length:sizeof(double)];
                soma = 0.0; noSegmento = 0;
            }
        }
    }
    free(buf);
    const double *s = segmentos.bytes;
    long ns = (long)(segmentos.length / sizeof(double));
    NSMutableData *blocos = [NSMutableData data];
    for (long k = 3; k < ns; ++k) {
        double z = (s[k-3] + s[k-2] + s[k-1] + s[k]) / (4.0 * seg);
        [blocos appendBytes:&z length:sizeof(double)];
    }
    return blocos;
}

// A sonoridade integrada (LUFS), com as duas portas da norma: a absoluta de
// −70 LUFS e a relativa de 10 LU abaixo da média das que passaram a primeira.
// Sem blocos que passem (silêncio, ou menos de 400 ms), kZPSemSonoridade.
static const double kZPSemSonoridade = -1000.0;

static double ZPSonoridade(NSData *blocos) {
    const double *z = blocos.bytes;
    long n = (long)(blocos.length / sizeof(double));
    double soma = 0.0;
    long c = 0;
    for (long i = 0; i < n; ++i) if (z[i] > 0 && -0.691 + 10.0 * log10(z[i]) > -70.0) { soma += z[i]; ++c; }
    if (c == 0) return kZPSemSonoridade;
    double relativa = -0.691 + 10.0 * log10(soma / c) - 10.0;
    soma = 0.0; c = 0;
    for (long i = 0; i < n; ++i) {
        if (z[i] <= 0) continue;
        double l = -0.691 + 10.0 * log10(z[i]);
        if (l > -70.0 && l > relativa) { soma += z[i]; ++c; }
    }
    return c ? -0.691 + 10.0 * log10(soma / c) : kZPSemSonoridade;
}

#pragma mark - FLAC

// O formato de uma imagem pelos primeiros bytes: @"jpg", @"png", @"gif",
// @"webp", ou nil se for outro.
static NSString *ZPFormatoDaImagem(NSData *d) {
    const uint8_t *b = d.bytes;
    if (d.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return @"jpg";
    if (d.length >= 8 && !memcmp(b, "\x89PNG\r\n\x1a\n", 8)) return @"png";
    if (d.length >= 6 && (!memcmp(b, "GIF87a", 6) || !memcmp(b, "GIF89a", 6))) return @"gif";
    if (d.length >= 12 && !memcmp(b, "RIFF", 4) && !memcmp(b + 8, "WEBP", 4)) return @"webp";
    return nil;
}

static const char *ZPTipoMIME(NSString *formato) {
    if ([formato isEqualToString:@"png"]) return "image/png";
    if ([formato isEqualToString:@"gif"]) return "image/gif";
    if ([formato isEqualToString:@"webp"]) return "image/webp";
    return "image/jpeg";
}

static BOOL ZPEscreverFLAC(NSString *caminho, const ZPGravacao *g, const ZPCorreccao *cs, int nc,
                           long long inicio, long long fim, unsigned bits,
                           NSArray<NSArray<NSString *> *> *etiquetas, NSData *capa, NSString **erro) {
    FLAC__StreamEncoder *e = FLAC__stream_encoder_new();
    if (!e) { *erro = @"sem codificador"; return NO; }
    FLAC__stream_encoder_set_verify(e, true);   // descodifica o que escreve e compara
    FLAC__stream_encoder_set_compression_level(e, 8);
    FLAC__stream_encoder_set_channels(e, 2);
    FLAC__stream_encoder_set_bits_per_sample(e, bits);
    FLAC__stream_encoder_set_sample_rate(e, (unsigned)llround(g->taxa));
    FLAC__stream_encoder_set_total_samples_estimate(e, (FLAC__uint64)(fim - inicio));

    FLAC__StreamMetadata *meta[3];
    unsigned nm = 0;
    FLAC__StreamMetadata *vc = FLAC__metadata_object_new(FLAC__METADATA_TYPE_VORBIS_COMMENT);
    for (NSArray<NSString *> *par in etiquetas) {
        FLAC__StreamMetadata_VorbisComment_Entry entrada;
        if (FLAC__metadata_object_vorbiscomment_entry_from_name_value_pair(&entrada, par[0].UTF8String, par[1].UTF8String)) {
            FLAC__metadata_object_vorbiscomment_append_comment(vc, entrada, false);
        }
    }
    meta[nm++] = vc;
    if (capa.length) {
        NSBitmapImageRep *imagem = [NSBitmapImageRep imageRepWithData:capa];
        FLAC__StreamMetadata *p = FLAC__metadata_object_new(FLAC__METADATA_TYPE_PICTURE);
        p->data.picture.type = FLAC__STREAM_METADATA_PICTURE_TYPE_FRONT_COVER;
        FLAC__metadata_object_picture_set_mime_type(p, (char *)ZPTipoMIME(ZPFormatoDaImagem(capa)), true);
        FLAC__metadata_object_picture_set_description(p, (FLAC__byte *)"", true);
        p->data.picture.width = (FLAC__uint32)imagem.pixelsWide;
        p->data.picture.height = (FLAC__uint32)imagem.pixelsHigh;
        p->data.picture.depth = 24;
        FLAC__metadata_object_picture_set_data(p, (FLAC__byte *)capa.bytes, (FLAC__uint32)capa.length, true);
        meta[nm++] = p;
    }
    FLAC__StreamMetadata *enchimento = FLAC__metadata_object_new(FLAC__METADATA_TYPE_PADDING);
    enchimento->length = 4096;
    meta[nm++] = enchimento;
    FLAC__stream_encoder_set_metadata(e, meta, nm);

    BOOL bem = FLAC__stream_encoder_init_file(e, caminho.fileSystemRepresentation, NULL, NULL) == FLAC__STREAM_ENCODER_INIT_STATUS_OK;
    if (!bem) *erro = @"não abriu o ficheiro";
    const double escala = bits == 16 ? 32768.0 : 8388608.0;
    const long long maximo = bits == 16 ? 32767 : 8388607, minimo = -maximo - 1;
    const long long pedaco = 65536;
    float *f = malloc(sizeof(float) * 2 * pedaco);
    FLAC__int32 *q = malloc(sizeof(FLAC__int32) * 2 * pedaco);
    for (long long p = inicio; bem && p < fim; p += pedaco) {
        long long n = MIN(pedaco, fim - p);
        ZPLer(g, cs, nc, p, n, f);
        for (long long i = 0; i < 2 * n; ++i) {
            long long v = llrint((double)f[i] * escala);
            q[i] = (FLAC__int32)MIN(MAX(v, minimo), maximo);
        }
        if (!FLAC__stream_encoder_process_interleaved(e, q, (unsigned)n)) {
            bem = NO;
            *erro = [NSString stringWithUTF8String:FLAC__stream_encoder_get_resolved_state_string(e)];
        }
    }
    if (!FLAC__stream_encoder_finish(e) && bem) {
        bem = NO;
        *erro = [NSString stringWithUTF8String:FLAC__stream_encoder_get_resolved_state_string(e)];
    }
    FLAC__stream_encoder_delete(e);
    for (unsigned i = 0; i < nm; ++i) FLAC__metadata_object_delete(meta[i]);
    free(f);
    free(q);
    if (!bem) [[NSFileManager defaultManager] removeItemAtPath:caminho error:NULL];
    return bem;
}

#pragma mark - O processamento

static NSString *ZPNomeDeFicheiro(NSString *s) {
    NSString *n = [[s ?: @"" stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
                   stringByReplacingOccurrencesOfString:@":" withString:@""];
    n = [n stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    while ([n hasPrefix:@"."]) n = [n substringFromIndex:1];
    return n.length ? n : @"Sem nome";
}

static id ZPOuNada(id v) { return (v && v != [NSNull null]) ? v : nil; }

// O artista como o MusicBrainz o credita: «Moin feat. Sophia Al-Maria & Ben
// Vince». Os convidados vão aqui e não no título, ao contrário da Apple.
static NSString *ZPCreditoDoMusicBrainz(NSArray<NSDictionary *> *credito) {
    NSMutableString *s = [NSMutableString string];
    for (NSDictionary *c in credito) {
        [s appendString:ZPOuNada(c[@"name"]) ?: @""];
        [s appendString:ZPOuNada(c[@"joinphrase"]) ?: @""];
    }
    return s.length ? s : nil;
}

NSString *ZPProcessarGravacaoAgora(NSURL *wav, NSURL *raiz, NSArray<NSURL *> **pastasEscritas) {
    if (pastasEscritas) *pastasEscritas = @[];
    NSMutableArray<NSString *> *rel = [NSMutableArray array];
    NSURL *urlDaTOC = [[wav URLByDeletingPathExtension] URLByAppendingPathExtension:@"toc.json"];
    NSDictionary *toc = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:urlDaTOC] ?: [NSData data]
                                                        options:0 error:NULL];
    NSArray<NSDictionary *> *marcas = toc[@"faixas"];
    if (!marcas.count) return @"Sem faixas na TOC: nada a processar.";

    NSError *erro = nil;
    NSData *dados = [NSData dataWithContentsOfURL:wav options:NSDataReadingMappedAlways error:&erro];
    const uint8_t *h = dados.bytes;
    if (dados.length < kZPTamanhoDoCabecalhoWav || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)
        || h[20] != 3 || h[22] != 2) {
        return [NSString stringWithFormat:@"%@ não é um WAV float de dois canais%@.", wav.lastPathComponent,
                erro ? [@": " stringByAppendingString:erro.localizedDescription] : @""];
    }
    ZPGravacao g = { (const float *)(h + kZPTamanhoDoCabecalhoWav),
                     (long long)((dados.length - kZPTamanhoDoCabecalhoWav) / 8),
                     (double)(h[24] | h[25] << 8 | h[26] << 16 | (uint32_t)h[27] << 24) };
    [rel addObject:[NSString stringWithFormat:@"Gravação: %@, %.1f kHz, %@.", wav.lastPathComponent, g.taxa / 1000.0, ZPTempo(g.n, g.taxa)]];

    // 1. Rampas.
    NSMutableArray<NSString *> *notasDasRampas = [NSMutableArray array];
    ZPCorreccao *cs = NULL;
    int nc = ZPProcurarRampas(&g, toc[@"silencios"] ?: @[], &cs, notasDasRampas);

    // 2. As faixas: uma por marca, sem repetir a mesma seguida.
    NSMutableArray<NSMutableDictionary *> *faixas = [NSMutableArray array];
    for (NSDictionary *m in marcas) {
        if (![m[@"titulo"] length]) continue;
        if (faixas.count && [faixas.lastObject[@"marca"][@"pid"] isEqual:m[@"pid"]] && [m[@"pid"] length]) continue;
        [faixas addObject:[@{ @"marca": m } mutableCopy]];
    }

    // 3. Catálogo e MusicBrainz, por álbum (marcas seguidas do mesmo álbum).
    NSMutableArray<NSMutableDictionary *> *albuns = [NSMutableArray array];
    for (NSMutableDictionary *f in faixas) {
        NSString *album = f[@"marca"][@"album"] ?: @"";
        NSMutableDictionary *a = albuns.lastObject;
        if (!a || ![a[@"nome"] isEqualToString:album]) {
            a = [@{ @"nome": album, @"artista": f[@"marca"][@"artista"] ?: @"", @"faixas": [NSMutableArray array] } mutableCopy];
            [albuns addObject:a];
        }
        [a[@"faixas"] addObject:f];
    }
    for (NSMutableDictionary *a in albuns) {
        NSDictionary *cat = ZPCatalogoDaApple(a[@"artista"], a[@"nome"]);
        NSArray<NSDictionary *> *doCatalogo = cat[@"faixas"];
        if (cat) {
            a[@"catalogo"] = cat[@"album"];
            a[@"faixasDoCatalogo"] = doCatalogo;
        }
        // Cada marca à sua faixa do catálogo: pelo nome; senão pela duração,
        // a menos de 1,5 s da que o Música disse.
        NSMutableSet *usadas = [NSMutableSet set];
        for (NSMutableDictionary *f in a[@"faixas"]) {
            NSString *chave = ZPChave(f[@"marca"][@"titulo"]);
            double d = [f[@"marca"][@"duracao"] doubleValue];
            NSDictionary *melhor = nil;
            for (NSDictionary *t in doCatalogo) {
                if (![usadas containsObject:t[@"trackId"]] && [ZPChave(t[@"trackName"]) isEqualToString:chave]) { melhor = t; break; }
            }
            if (!melhor) {
                double menor = 1.5;
                for (NSDictionary *t in doCatalogo) {
                    double dt = fabs([t[@"trackTimeMillis"] doubleValue] / 1000.0 - d);
                    if (![usadas containsObject:t[@"trackId"]] && dt < menor) { menor = dt; melhor = t; }
                }
            }
            if (melhor) {
                [usadas addObject:melhor[@"trackId"]];
                f[@"catalogo"] = melhor;
            }
        }
        if (!doCatalogo.count) continue;
        NSArray<NSDictionary *> *ordenadas = [doCatalogo sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
            NSComparisonResult r = [x[@"discNumber"] compare:y[@"discNumber"]];
            return r != NSOrderedSame ? r : [x[@"trackNumber"] compare:y[@"trackNumber"]];
        }];
        NSArray *ms = [ordenadas valueForKey:@"trackTimeMillis"];
        BOOL respondeu = YES;
        NSDictionary *mb = ZPEdicaoNoMusicBrainz(a[@"catalogo"][@"artistName"] ?: a[@"artista"],
                                                 ZPSemSufixoDaApple(a[@"catalogo"][@"collectionName"] ?: a[@"nome"]), ms, &respondeu);
        if (!respondeu) a[@"mbSemResposta"] = @YES;
        if (!mb) continue;
        a[@"mb"] = mb;
        NSMutableArray *dasEdicao = [NSMutableArray array];
        for (NSDictionary *m in mb[@"media"]) [dasEdicao addObjectsFromArray:m[@"tracks"] ?: @[]];
        for (NSMutableDictionary *f in a[@"faixas"]) {
            NSUInteger k = f[@"catalogo"] ? [ordenadas indexOfObject:f[@"catalogo"]] : NSNotFound;
            if (k != NSNotFound && k < dasEdicao.count) f[@"mb"] = dasEdicao[k];
        }
    }

    // 4. Onde começa e acaba cada faixa. A primeira no primeiro som depois da
    // marca; cada uma das seguintes onde a soma das durações a põe, se a marca
    // concordar (num álbum sem pausas, são as fronteiras verdadeiras, ao
    // milissegundo); senão no primeiro som depois da marca. O som perdido pelo
    // caminho desconta-se: as amostras de um lado e do outro estão encostadas.
    for (NSMutableDictionary *f in faixas) {
        NSNumber *ms = ZPOuNada(f[@"catalogo"][@"trackTimeMillis"]) ?: ZPOuNada(f[@"mb"][@"length"]);
        if (ms) {
            f[@"duracao"] = @(ms.doubleValue / 1000.0);
            f[@"origemDaDuracao"] = f[@"catalogo"] ? @"catálogo da Apple" : @"MusicBrainz";
            f[@"duracaoExacta"] = @YES;
        } else {
            f[@"duracao"] = f[@"marca"][@"duracao"] ?: @0;
            f[@"origemDaDuracao"] = @"o Música (pode desviar dezenas de ms)";
        }
    }
    NSArray<NSDictionary *> *perdas = toc[@"perdas"] ?: @[];
    long long (^perdidasEntre)(long long, long long) = ^long long (long long a, long long b) {
        long long soma = 0;
        for (NSDictionary *p in perdas) {
            long long t = [p[@"trama"] longLongValue], q = [p[@"perdidas"] longLongValue];
            if (q > 0 && t >= a && t < b) soma += q;
        }
        return soma;
    };
    const long long meioSegundo = llround(0.5 * g.taxa), tolerancia = llround(kZPToleranciaDaMarca * g.taxa);
    // Um corte perto de `t`: no fim do silêncio digital que acabe a menos de
    // `raio` (o som da faixa seguinte começa aí, exacto); senão em `t`. Nunca
    // antes de `minimo`. O «primeiro som depois de t − 0,5 s» não serve: num
    // álbum sem pausas, é logo t − 0,5 s (visto em 2026-10-30, num teste sem
    // catálogo com o EP dos Moin).
    NSArray<NSArray<NSNumber *> *> *silencios = toc[@"silencios"] ?: @[];
    long long (^ancorar)(long long, long long, long long) = ^long long (long long t, long long raio, long long minimo) {
        long long melhor = -1;
        for (NSArray<NSNumber *> *sil in silencios) {
            long long fimDoSilencio = sil[1].longLongValue;
            if (fimDoSilencio < minimo || fimDoSilencio >= g.n || llabs(fimDoSilencio - t) > raio) continue;
            if (melhor < 0 || llabs(fimDoSilencio - t) < llabs(melhor - t)) melhor = fimDoSilencio;
        }
        return melhor >= 0 ? melhor : MAX(t, minimo);
    };
    for (NSUInteger i = 0; i < faixas.count; ++i) {
        NSMutableDictionary *f = faixas[i];
        NSDictionary *m = f[@"marca"];
        long long est = [(m[@"inicioEstimado"] ?: m[@"trama"]) longLongValue];
        long long inicio;
        double exacto = -1.0;   // a posição sem arredondar, quando vem da soma das durações
        if (i == 0) {
            if (est < -meioSegundo) {
                f[@"falta"] = @"o início: a gravação começou com a faixa já a tocar";
                inicio = 0;
            } else {
                inicio = ZPPrimeiroSom(&g, est - meioSegundo, g.n);
            }
            f[@"como"] = @"primeiro som";
        } else {
            NSMutableDictionary *ant = faixas[i-1];
            // A soma faz-se sem arredondar, e só a fronteira se arredonda: uma
            // duração que dê meia trama (o Dancing and Fire dos Low, 257,305 s
            // a 44,1 kHz) não empurra as faixas seguintes.
            long long a0 = [ant[@"inicio"] longLongValue];
            double x = [ant[@"exacto"] doubleValue] + [ant[@"duracao"] doubleValue] * g.taxa;
            long long p = llround(x);
            long long perdidas = perdidasEntre(a0, p);
            p -= perdidas;
            x -= perdidas;
            if (![ant[@"duracaoExacta"] boolValue]) {
                // Sem duração de confiança (fora do catálogo, o Música
                // arredonda ao segundo: 218,0 s por 218,719), a marca manda.
                inicio = ancorar(est, meioSegundo, a0 + 1);
                ant[@"fim"] = @(inicio);
                f[@"como"] = inicio == est ? @"marca do Música (±0,1 s)" : @"silêncio junto à marca do Música";
            } else if (llabs(p - est) <= tolerancia) {
                inicio = p;
                exacto = x;
                ant[@"fim"] = @(p);
                f[@"como"] = [NSString stringWithFormat:@"soma das durações (marca a %+.0f ms)", (est - p) * 1000.0 / g.taxa];
            } else {
                inicio = ancorar(est, meioSegundo, a0 + 1);
                f[@"como"] = [NSString stringWithFormat:@"%@ (a soma das durações dava %+.3f s)",
                              inicio == est ? @"marca do Música" : @"silêncio junto à marca", (p - est) / g.taxa];
                if (inicio >= 0 && p > inicio) {
                    ant[@"fim"] = @(inicio);
                    if (!ant[@"falta"]) ant[@"falta"] = @"o fim: a faixa seguinte começou antes";
                } else {
                    ant[@"fim"] = @(p);   // pausa: o silêncio que se segue não é da faixa
                }
            }
        }
        if (inicio < 0) {
            f[@"falta"] = @"o som: não há som depois da marca";
            inicio = g.n;
        }
        f[@"inicio"] = @(inicio);
        f[@"exacto"] = @(exacto >= 0.0 ? exacto : (double)inicio);
        if (i + 1 == faixas.count) {
            long long dur = llround([f[@"duracao"] doubleValue] * g.taxa);
            long long fim = inicio + dur - perdidasEntre(inicio, inicio + dur);
            if (![f[@"duracaoExacta"] boolValue]) {
                // Duração ao segundo: o fim no silêncio que houver por perto
                // (o do fim do álbum, antes da folga que traz o seguinte), e
                // só falta o fim se a gravação parar bem antes.
                long long perto = ancorar(fim, llround(1.5 * g.taxa), inicio + 1);
                if (perto != fim) fim = perto;
                else if (fim > g.n && fim - g.n <= llround(1.5 * g.taxa)) fim = g.n;
            }
            if (fim > g.n) {
                if (!f[@"falta"]) f[@"falta"] = @"o fim: a gravação parou antes";
                fim = g.n;
            }
            f[@"fim"] = @(fim);
        }
    }

    // 5. A grelha de cada faixa, já com as rampas desfeitas; a sonoridade.
    const long long pedaco = 65536;
    float *buf = malloc(sizeof(float) * 2 * pedaco);
    for (NSMutableDictionary *f in faixas) {
        if (f[@"falta"]) continue;
        long long a = [f[@"inicio"] longLongValue], b = [f[@"fim"] longLongValue];
        long long fora16 = 0, fora24 = 0;
        for (long long p = a; p < b; p += pedaco) {
            long long n = MIN(pedaco, b - p);
            ZPLer(&g, cs, nc, p, n, buf);
            for (long long i = 0; i < n; ++i) {
                if (ZPForaDaGrelha(buf[2*i], 32768.0f) || ZPForaDaGrelha(buf[2*i+1], 32768.0f)) ++fora16;
                if (ZPForaDaGrelha(buf[2*i], 8388608.0f) || ZPForaDaGrelha(buf[2*i+1], 8388608.0f)) ++fora24;
            }
        }
        double pico = 0.0;
        NSData *blocos = ZPBlocosDeEnergia(&g, cs, nc, a, b, &pico);
        [f addEntriesFromDictionary:@{ @"fora16": @(fora16), @"fora24": @(fora24), @"pico": @(pico), @"blocos": blocos }];
    }
    free(buf);

    // 6. Por álbum: profundidade, ReplayGain, capa, etiquetas, FLAC.
    NSMutableArray<NSURL *> *pastas = [NSMutableArray array];
    NSMutableArray<NSString *> *resumos = [NSMutableArray array];
    NSArray *capas = toc[@"capas"];
    for (NSMutableDictionary *a in albuns) {
        NSDictionary *cat = a[@"catalogo"], *mb = a[@"mb"];
        NSArray<NSMutableDictionary *> *todas = a[@"faixas"];
        NSMutableArray<NSMutableDictionary *> *inteiras = [NSMutableArray array];
        for (NSMutableDictionary *f in todas) if (!f[@"falta"]) [inteiras addObject:f];

        NSString *nomeDoAlbum = ZPOuNada(mb[@"title"]) ?: ZPSemSufixoDaApple(ZPOuNada(cat[@"collectionName"]) ?: a[@"nome"]);
        NSString *artistaDoAlbum = ZPOuNada(cat[@"artistName"]) ?: a[@"artista"];
        [rel addObject:@""];
        [rel addObject:[NSString stringWithFormat:@"%@ — %@", artistaDoAlbum, nomeDoAlbum]];
        [rel addObject:[NSString stringWithFormat:@"Catálogo da Apple: %@. MusicBrainz: %@.",
                        cat ? [NSString stringWithFormat:@"%@ (loja %@)", cat[@"collectionId"], [cat[@"collectionViewUrl"] containsString:@"/pt/"] ? @"pt" : @"us"] : @"não encontrado",
                        mb ? mb[@"id"] : a[@"mbSemResposta"] ? @"não respondeu (servidor ocupado); as etiquetas são só as da Apple"
                                              : @"sem edição que bata sem ambiguidade"]];
        if (!inteiras.count) {
            [rel addObject:@"Nenhuma faixa inteira: nada escrito."];
            for (NSMutableDictionary *f in todas) [rel addObject:[NSString stringWithFormat:@"  «%@»: falta %@.", f[@"marca"][@"titulo"], f[@"falta"]]];
            continue;
        }

        long long fora16 = 0, fora24 = 0;
        NSMutableData *blocosDoAlbum = [NSMutableData data];
        double picoDoAlbum = 0.0;
        for (NSMutableDictionary *f in inteiras) {
            fora16 += [f[@"fora16"] longLongValue];
            fora24 += [f[@"fora24"] longLongValue];
            [blocosDoAlbum appendData:f[@"blocos"]];
            picoDoAlbum = MAX(picoDoAlbum, [f[@"pico"] doubleValue]);
        }
        unsigned bits = fora16 == 0 ? 16 : 24;
        BOOL exacto = fora16 == 0 || fora24 == 0;
        double sonoridadeDoAlbum = ZPSonoridade(blocosDoAlbum);
        double ganhoDoAlbum = -18.0 - sonoridadeDoAlbum;

        NSString *genero = ZPOuNada(((NSDictionary *)inteiras[0][@"catalogo"])[@"primaryGenreName"]) ?: ZPOuNada(cat[@"primaryGenreName"]);
        BOOL erudita = [genero isEqualToString:@"Classical"] || [genero isEqualToString:@"Clássica"];
        if (erudita) genero = @"Erudite";
        NSString *ano = [ZPOuNada(mb[@"date"]) ?: ZPOuNada(cat[@"releaseDate"]) ?: @"" description];
        if (ano.length > 4) ano = [ano substringToIndex:4];
        NSArray *editoras = mb[@"label-info"];
        NSString *editora = editoras.count ? ZPOuNada(ZPOuNada(editoras[0][@"label"])[@"name"]) : nil;

        // A capa: a do catálogo a 600 px, como na fonoteca; senão a que o
        // Música tinha, guardada pela gravação.
        NSData *capa = nil;
        NSString *arte = ZPOuNada(cat[@"artworkUrl100"]);
        if (arte) capa = ZPPedir([NSURL URLWithString:[arte stringByReplacingOccurrencesOfString:@"100x100bb" withString:@"600x600bb"]], NULL);
        if (!capa) {
            for (NSDictionary *c in capas) {
                if ([c[@"album"] isEqual:a[@"nome"]]) {
                    capa = [NSData dataWithContentsOfURL:[[wav URLByDeletingLastPathComponent] URLByAppendingPathComponent:c[@"ficheiro"]]];
                    break;
                }
            }
        }

        NSURL *pasta = [[raiz URLByAppendingPathComponent:ZPNomeDeFicheiro(artistaDoAlbum) isDirectory:YES]
                        URLByAppendingPathComponent:ZPNomeDeFicheiro(nomeDoAlbum) isDirectory:YES];
        if (![[NSFileManager defaultManager] createDirectoryAtURL:pasta withIntermediateDirectories:YES attributes:nil error:&erro]) {
            [rel addObject:[NSString stringWithFormat:@"Não consegui criar %@: %@", pasta.path, erro.localizedDescription]];
            continue;
        }
        [pastas addObject:pasta];

        // A capa também solta, em albumart_backup/, como nas pastas da
        // fonoteca: os mesmos bytes que vão embutidos, em cover.jpg ou
        // cover.png, que é onde o tocaTintas a procura. Só um formato que ele
        // aí não lê (GIF, WebP, HEIC…) passa a PNG, que não perde nada. Uma
        // que lá esteja (uma faixa regravada para um álbum já feito) fica.
        NSString *notaDaCapa = @" Sem capa.";
        if (capa) {
            NSURL *copias = [pasta URLByAppendingPathComponent:@"albumart_backup" isDirectory:YES];
            NSString *formato = ZPFormatoDaImagem(capa);
            NSData *solta = capa;
            if (![formato isEqualToString:@"jpg"] && ![formato isEqualToString:@"png"]) {
                formato = @"png";
                solta = [[NSBitmapImageRep imageRepWithData:capa] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            }
            NSString *nome = [@"cover" stringByAppendingPathExtension:formato];
            NSURL *destino = [copias URLByAppendingPathComponent:nome];
            BOOL jaHa = NO;
            for (NSString *outro in @[ @"cover.jpg", @"cover.png" ]) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:[copias URLByAppendingPathComponent:outro].path]) jaHa = YES;
            }
            if (jaHa) {
                notaDaCapa = @" A capa que já estava em albumart_backup ficou.";
            } else if (solta && [[NSFileManager defaultManager] createDirectoryAtURL:copias withIntermediateDirectories:YES attributes:nil error:NULL]
                       && [solta writeToURL:destino atomically:YES]) {
                notaDaCapa = [NSString stringWithFormat:@" Capa em albumart_backup/%@.", nome];
            } else {
                notaDaCapa = [NSString stringWithFormat:@" Não consegui escrever albumart_backup/%@.", nome];
            }
        }
        [rel addObject:[NSString stringWithFormat:@"%u bits, %@. ReplayGain do álbum %+.2f dB, pico %.6f.%@", bits,
                        exacto ? @"bit-exacto" : [NSString stringWithFormat:@"NÃO bit-exacto (%lld tramas fora da grelha de 24 bits, arredondadas)", fora24],
                        ganhoDoAlbum, picoDoAlbum, notaDaCapa]];

        NSUInteger escritas = 0;
        for (NSUInteger i = 0; i < todas.count; ++i) {
            NSMutableDictionary *f = todas[i];
            NSDictionary *m = f[@"marca"], *t = f[@"catalogo"], *mt = f[@"mb"];
            if (f[@"falta"]) {
                [rel addObject:[NSString stringWithFormat:@"  -- «%@»: não sai, falta %@.", m[@"titulo"], f[@"falta"]]];
                continue;
            }
            NSString *titulo = ZPOuNada(mt[@"title"]) ?: ZPOuNada(t[@"trackName"]) ?: m[@"titulo"];
            long numero = [(ZPOuNada(t[@"trackNumber"]) ?: ZPOuNada(mt[@"position"]) ?: @0) longValue];
            if (numero <= 0) numero = [m[@"faixa"] longValue];
            if (numero <= 0) numero = (long)i + 1;
            long disco = [(ZPOuNada(t[@"discNumber"]) ?: @1) longValue], discos = [(ZPOuNada(t[@"discCount"]) ?: @1) longValue];
            // O «trackCount» da Apple não é de fiar (10 no Double Negative, que
            // tem 11): conta-se no MusicBrainz, ou nas faixas do catálogo.
            long total = 0;
            NSArray *suportes = mb[@"media"];
            if (disco >= 1 && (NSUInteger)disco <= suportes.count) total = [suportes[disco - 1][@"track-count"] longValue];
            if (total <= 0) {
                for (NSDictionary *c in a[@"faixasDoCatalogo"]) if ([c[@"discNumber"] longValue] == disco) ++total;
            }
            double sonoridade = ZPSonoridade(f[@"blocos"]);
            double ganho = -18.0 - sonoridade;

            NSMutableArray<NSArray<NSString *> *> *et = [NSMutableArray array];
            void (^por)(NSString *, id) = ^(NSString *k, id v) {
                NSString *s = [ZPOuNada(v) description];
                if (s.length) [et addObject:@[ k, s ]];
            };
            // Com o título do MusicBrainz, o artista também: senão os
            // convidados, que a Apple põe no título, perdiam-se.
            NSString *creditado = mt ? ZPCreditoDoMusicBrainz(ZPOuNada(mt[@"artist-credit"]) ?: ZPOuNada(mt[@"recording"][@"artist-credit"])) : nil;
            por(@"ARTIST", creditado ?: ZPOuNada(t[@"artistName"]) ?: m[@"artista"]);
            por(@"ALBUMARTIST", artistaDoAlbum);
            por(@"ALBUM", nomeDoAlbum);
            por(@"DATE", ano);
            por(@"GENRE", genero);
            por(@"TITLE", titulo);
            por(@"TRACKNUMBER", [NSString stringWithFormat:@"%02ld", numero]);
            if (total > 0) por(@"TRACKTOTAL", [NSString stringWithFormat:@"%02ld", total]);
            por(@"DISCNUMBER", @(disco));
            por(@"DISCTOTAL", @(discos));
            por(@"LABEL", editora);
            NSArray *isrcs = mt[@"recording"][@"isrcs"];
            por(@"ISRC", isrcs.count ? isrcs[0] : nil);
            por(@"BARCODE", mb[@"barcode"]);
            por(@"MUSICBRAINZ_ALBUMID", mb[@"id"]);
            por(@"MUSICBRAINZ_RELEASEGROUPID", mb[@"release-group"][@"id"]);
            por(@"MUSICBRAINZ_TRACKID", mt[@"recording"][@"id"]);
            por(@"MUSICBRAINZ_RELEASETRACKID", mt[@"id"]);
            if (sonoridade > kZPSemSonoridade) {
                por(@"REPLAYGAIN_TRACK_GAIN", [NSString stringWithFormat:@"%+.2f dB", ganho]);
                por(@"REPLAYGAIN_TRACK_PEAK", [NSString stringWithFormat:@"%.8f", [f[@"pico"] doubleValue]]);
            }
            if (sonoridadeDoAlbum > kZPSemSonoridade) {
                por(@"REPLAYGAIN_ALBUM_GAIN", [NSString stringWithFormat:@"%+.2f dB", ganhoDoAlbum]);
                por(@"REPLAYGAIN_ALBUM_PEAK", [NSString stringWithFormat:@"%.8f", picoDoAlbum]);
            }

            NSString *base = discos > 1 ? [NSString stringWithFormat:@"%ld-%02ld %@", disco, numero, ZPNomeDeFicheiro(titulo)]
                                        : [NSString stringWithFormat:@"%02ld %@", numero, ZPNomeDeFicheiro(titulo)];
            NSString *caminho = [pasta.path stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"flac"]];
            for (int k = 2; [[NSFileManager defaultManager] fileExistsAtPath:caminho]; ++k) {
                caminho = [pasta.path stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d).flac", base, k]];
            }
            long long ini = [f[@"inicio"] longLongValue], fim = [f[@"fim"] longLongValue];
            NSString *falha = nil;
            BOOL bem = ZPEscreverFLAC(caminho, &g, cs, nc, ini, fim, bits, et, capa, &falha);
            if (bem) ++escritas;
            NSString *grelha = [f[@"fora16"] longLongValue] == 0 ? @"16 bits exactos"
                             : [f[@"fora24"] longLongValue] == 0 ? @"24 bits exactos"
                             : [NSString stringWithFormat:@"%@ tramas fora da grelha", f[@"fora24"]];
            [rel addObject:[NSString stringWithFormat:@"  %@  %@ a %@ (%@)  %@; %@; %+.2f dB%@",
                            caminho.lastPathComponent, ZPTempo(ini, g.taxa), ZPTempo(fim, g.taxa), ZPTempo(fim - ini, g.taxa),
                            f[@"como"], grelha, ganho, bem ? @"" : [NSString stringWithFormat:@"  — FALHOU: %@", falha]]];
        }
        if (erudita) [rel addObject:@"Erudita: os compositores, os intérpretes e os títulos vêm da Apple e têm de ser revistos (convenção da fonoteca)."];
        BOOL duracoesDoMusica = NO;
        for (NSMutableDictionary *f in inteiras) if (!f[@"catalogo"] && !f[@"mb"]) duracoesDoMusica = YES;
        if (duracoesDoMusica) [rel addObject:@"Há faixas sem catálogo nem MusicBrainz: cortadas nas marcas do Música (±0,1 s), ou nos silêncios junto a elas. Convém rever essas fronteiras."];
        [resumos addObject:[NSString stringWithFormat:@"%@ — %@: %lu de %lu faixas, %u bits%@", artistaDoAlbum, nomeDoAlbum,
                            (unsigned long)escritas, (unsigned long)todas.count, bits, exacto ? @", bit-exacto" : @", não bit-exacto"]];
    }

    if (notasDasRampas.count) {
        [rel addObject:@""];
        [rel addObjectsFromArray:notasDasRampas];
    }
    if (perdas.count) {
        [rel addObject:@""];
        for (NSDictionary *p in perdas) {
            [rel addObject:[NSString stringWithFormat:@"Som perdido aos %@ do ficheiro: %@ tramas (%.3f s), medido pel%@ %@.",
                            ZPTempo([p[@"trama"] longLongValue], g.taxa), p[@"perdidas"], [p[@"segundos"] doubleValue],
                            [p[@"pelo"] isEqual:@"relógio"] ? @"o" : @"as", p[@"pelo"]]];
        }
    }
    for (int k = 0; k < nc; ++k) free(cs[k].valores);
    free(cs);

    if (!resumos.count) [resumos addObject:@"Nenhum álbum processado."];
    [rel insertObject:[resumos componentsJoinedByString:@"; "] atIndex:0];
    NSString *relatorio = [[rel componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
    for (NSURL *pasta in pastas) {
        [relatorio writeToURL:[pasta URLByAppendingPathComponent:@"Processamento.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    if (pastasEscritas) *pastasEscritas = pastas;
    return relatorio;
}

void ZPProcessarGravacao(NSURL *wav, void (^concluido)(NSArray<NSURL *> *pastas, NSString *relatorio)) {
    static dispatch_queue_t fila;
    static dispatch_once_t umaVez;
    dispatch_once(&umaVez, ^{
        // Abaixo da gravação: uma nova pode começar enquanto esta se processa.
        fila = dispatch_queue_create("com.tocaTintas.posGravacao",
                                     dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    dispatch_async(fila, ^{
        @autoreleasepool {
            NSArray<NSURL *> *pastas = nil;
            NSString *relatorio = ZPProcessarGravacaoAgora(wav, [NSURL fileURLWithPath:@"/var/tmp" isDirectory:YES], &pastas);
            NSLog(@"[Pós-gravação] %@", relatorio);
            if (concluido) {
                dispatch_async(dispatch_get_main_queue(), ^{ concluido(pastas, relatorio); });
            }
        }
    });
}
