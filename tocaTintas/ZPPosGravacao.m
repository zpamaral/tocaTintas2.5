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
#import "ZPCatalogoDaApple.h"
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

static id ZPOuNada(id v) { return (v && v != [NSNull null]) ? v : nil; }

// Vazio dá 0. Nada de NaN neste ficheiro: compila-se com -Ofast, que liga o
// -ffast-math, e aí o compilador pode tirar os isnan().
static double ZPMediana(NSArray<NSNumber *> *v) {
    if (!v.count) return 0.0;
    NSArray *o = [v sortedArrayUsingSelector:@selector(compare:)];
    return o.count % 2 ? [o[o.count / 2] doubleValue]
                       : ([o[o.count / 2 - 1] doubleValue] + [o[o.count / 2] doubleValue]) / 2.0;
}

#pragma mark - A gravação, com as correcções por cima

typedef struct {
    const float *x;   // intercalado, dois canais
    long long n;      // tramas
    double taxa;
} ZPGravacao;

// Um pedaço de amostras corrigidas (uma rampa desfeita), lido por cima das do
// ficheiro. O ficheiro, mapeado, nunca se altera. Uma rampa que não se
// conseguiu desfazer também fica aqui, sem valores: lê-se como está, mas o
// veredicto da grelha não a conta (como o vigia da gravação).
typedef struct {
    long long inicio, n;
    float *valores;   // 2n, ou NULL se a rampa ficou como está
} ZPCorreccao;

static void ZPLer(const ZPGravacao *g, const ZPCorreccao *cs, int nc, long long inicio, long long n, float *destino) {
    memcpy(destino, g->x + 2 * inicio, (size_t)(2 * n) * sizeof(float));
    for (int k = 0; k < nc; ++k) {
        if (!cs[k].valores) continue;
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
//
// Se o polinómio falha, segue-se o ganho (ZPSeguirRampa): é o caso dos masters
// de 24 bits, que têm poucas amostras pequenas. `umNoFim`: o ganho chega a 1
// na última trama (rampa de entrada) e não na primeira (rampa de saída).
static float *ZPSeguirRampa(const float *r, long long n, BOOL umNoFim, double U, double *erroMax);

static float *ZPDesfazerRampa(const float *r, long long n, BOOL umNoFim, double *erroMax, int *bits) {
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
    if (!saida) {
        double erro = -1.0;
        saida = ZPSeguirRampa(r, n, umNoFim, 8388608.0, &erro);
        if (saida) *bits = 24;
        if (erro >= 0.0) *erroMax = *erroMax < 0.0 ? erro : MIN(*erroMax, erro);
    }
    return saida;
}

// Seguir o ganho, de onde a rampa chega a 1 para o outro lado, em janelas de
// 16 tramas. Em cada uma procura-se o ganho e a inclinação que põem as
// amostras da janela na grelha, perto do que as janelas anteriores fazem
// prever (uma parábola pelas últimas oito), com a curvatura dessa previsão. O
// polinómio de ZPDesfazerRampa mede o ganho só nas amostras de 1 a 4 degraus, e
// num master de 24 bits são poucas: 25 em 1022 tramas no «All for One» dos
// Stone Roses (2026-11-16), com amostras de até 1471 degraus, que pedem o
// ganho a uns 3e-5. Aí, seguido assim: de 0,834 a 1 em 1022 tramas, com erro
// máximo de 0,0044 LSB. As amostras de até 2 degraus não entram na procura
// (cabem em qualquer ganho), mas entram na verificação final, que é a mesma: todas
// abaixo de kZPErroMaximoDaRampa.
#define kZPJanelaDoSeguimento 16LL

static float *ZPSeguirRampa(const float *r, long long n, BOOL umNoFim, double U, double *erroMax) {
    const long long W = kZPJanelaDoSeguimento;
    long long janelas = (n + W - 1) / W;
    double *pk = malloc(sizeof(double) * (size_t)(janelas + 2));
    double *pg = malloc(sizeof(double) * (size_t)(janelas + 2));
    double *ganho = malloc(sizeof(double) * (size_t)n);
    double xs[2 * kZPJanelaDoSeguimento], us[2 * kZPJanelaDoSeguimento];
    // j = 0 é a trama junto à música, onde o ganho já é 1; para trás dela, 1.
    long np = 0;
    pk[np] = -12.0; pg[np++] = 1.0;
    pk[np] = -4.0;  pg[np++] = 1.0;
    BOOL valido = YES;
    for (long long w0 = 0; w0 < n && valido; w0 += W) {
        long long w1 = MIN(n, w0 + W);
        double meio = 0.5 * (double)(w0 + w1 - 1);

        long q0 = MAX(0, np - 8), m = np - q0;
        double t[8], y[8], coef[3] = { 0.0, 0.0, 0.0 };
        for (long i = 0; i < m; ++i) { t[i] = (pk[q0 + i] - meio) / (double)W; y[i] = pg[q0 + i]; }
        int grau = m >= 3 ? 2 : 1;
        if (!ZPAjustarPolinomio(t, y, m, grau, coef)) { valido = NO; break; }
        double pa = coef[0], pb = coef[1] / (double)W, pc = grau == 2 ? coef[2] / (double)(W * W) : 0.0;

        int ns = 0;
        for (long long j = w0; j < w1; ++j) {
            long long i = umNoFim ? n - 1 - j : j;
            for (int c = 0; c < 2; ++c) {
                double v = (double)r[2*i+c] * U;
                if (fabs(v) <= 2.0) continue;
                xs[ns] = v;
                us[ns] = (double)j - meio;
                ++ns;
            }
        }
        double ma = pa, mb = pb;
        if (ns > 0) {
            double alcance = MAX(2e-4, fabs(pb) * (double)W * 0.5);
            double largura = fabs(pb) + 2e-6;
            double melhor = 1e9;
            for (int ib = 0; ib <= 120; ++ib) {
                double b = pb - 0.5 * largura + ib * largura / 120.0;
                for (int ia = 0; ia <= 2000; ++ia) {
                    double a = pa - alcance + ia * alcance / 1000.0;
                    double pior = 0.0;
                    for (int s = 0; s < ns && pior < melhor; ++s) {
                        double q = xs[s] / (a + b * us[s] + pc * us[s] * us[s]);
                        pior = MAX(pior, fabs(q - rint(q)));
                    }
                    if (pior < melhor) { melhor = pior; ma = a; mb = b; }
                }
            }
        }
        for (long long j = w0; j < w1; ++j) {
            double u = (double)j - meio;
            ganho[j] = ma + mb * u + pc * u * u;
            if (ganho[j] < 0.05 || ganho[j] > 1.05) valido = NO;
        }
        pk[np] = meio; pg[np++] = ma;
    }

    float *saida = NULL;
    if (valido) {
        float *c = malloc(sizeof(float) * (size_t)(2 * n));
        double pior = 0.0;
        for (long long j = 0; j < n; ++j) {
            long long i = umNoFim ? n - 1 - j : j;
            for (int k = 0; k < 2; ++k) {
                double v = r[2*i+k];
                if (v == 0.0) { c[2*i+k] = 0.0f; continue; }
                double q = v * U / ganho[j];
                pior = MAX(pior, fabs(q - rint(q)));
                c[2*i+k] = (float)(rint(q) / U);
            }
        }
        *erroMax = pior;
        if (pior < kZPErroMaximoDaRampa) saida = c;
        else free(c);
    }
    free(pk);
    free(pg);
    free(ganho);
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
            float *c = ZPDesfazerRampa(g->x + 2 * r0, r1 - r0, lado == 0, &erro, &bits);
            NSString *qual = lado == 0 ? @"entrada" : @"saída";
            if (nc == capacidade) {
                capacidade *= 2;
                cs = realloc(cs, sizeof(ZPCorreccao) * (size_t)capacidade);
            }
            cs[nc++] = (ZPCorreccao){ r0, r1 - r0, c };   // sem valores, se ficou como está
            if (c) {
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

// O álbum no catálogo da Apple (ver ZPCatalogoDaApple), só com o mesmo nome:
// a loja americana primeiro, que dá os géneros em inglês, como os da fonoteca
// (a portuguesa deu «Alternativa» no Low); depois a portuguesa, para o que só
// lá houver. Devolve @{ @"album": …, @"faixas": @[…] } com os campos do iTunes
// Search API, ou nil.
//
// Os nomes, esses, vêm da loja do Mac, a do Música: a americana não é coerente
// consigo própria. No «ОМ» do Grünberg (2026-11-08) deu o álbum em cirílico e
// as faixas em inglês, e o Música mostra tudo em cirílico. O mesmo álbum tem o
// mesmo collectionId e os mesmos trackId em todas as lojas.
static NSDictionary *ZPAlbumNoCatalogo(NSString *artista, NSString *album, NSArray<NSDictionary *> *marcas) {
    NSDictionary *a = [ZPCatalogoDaApple albumDe:artista chamado:album marcas:marcas lojas:@[ @"us", @"pt" ] exacto:YES];
    NSArray *faixas = a ? [ZPCatalogoDaApple faixasDoAlbum:a] : nil;
    if (!faixas.count) return nil;
    NSString *loja = [ZPCatalogoDaApple lojaDoMac];
    if (![a[@"loja"] isEqual:loja]) {
        NSMutableDictionary *daqui = [a mutableCopy];
        daqui[@"loja"] = loja;
        NSMutableDictionary<id, NSDictionary *> *porId = [NSMutableDictionary dictionary];
        for (NSDictionary *t in [ZPCatalogoDaApple faixasDoAlbum:daqui]) if (t[@"trackId"]) porId[t[@"trackId"]] = t;
        NSMutableArray *renomeadas = [NSMutableArray arrayWithCapacity:faixas.count];
        for (NSDictionary *t in faixas) {
            NSDictionary *l = porId[t[@"trackId"]];
            NSMutableDictionary *n = [t mutableCopy];
            for (NSString *k in @[ @"trackName", @"collectionName", @"artistName" ]) if ([l[k] length]) n[k] = l[k];
            [renomeadas addObject:n];
        }
        NSString *nome = [porId.allValues.firstObject objectForKey:@"collectionName"];
        if ([nome isKindOfClass:[NSString class]] && nome.length) {
            NSMutableDictionary *m = [a mutableCopy];
            m[@"collectionName"] = nome;
            a = m;
        }
        faixas = renomeadas;
    }
    return @{ @"album": a, @"faixas": faixas };
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

// Um disco erudito é ópera? A Apple não o diz (o Verismo da Netrebko é
// «Clássica» no álbum e em cada faixa); o MusicBrainz diz, nas etiquetas e nos
// géneros do grupo da edição. Procura-se o grupo pelo título e pelo artista,
// mesmo quando nenhuma edição bateu nas durações: o género é do grupo.
static BOOL ZPEOperaNoMusicBrainz(NSString *artista, NSString *album, NSString *grupo) {
    BOOL ok = YES;
    NSArray *grupos = nil;
    [NSThread sleepForTimeInterval:1.1];
    if (grupo.length) {
        NSDictionary *g = ZPPedirJSON(ZPEndereco([NSString stringWithFormat:@"https://musicbrainz.org/ws/2/release-group/%@", grupo],
                                                 @{ @"inc": @"genres+tags", @"fmt": @"json" }), &ok);
        grupos = g ? @[g] : nil;
    } else if (artista.length && album.length) {
        NSString *q = [NSString stringWithFormat:@"releasegroup:\"%@\" AND artist:\"%@\"",
                       [album stringByReplacingOccurrencesOfString:@"\"" withString:@""],
                       [artista stringByReplacingOccurrencesOfString:@"\"" withString:@""]];
        NSDictionary *r = ZPPedirJSON(ZPEndereco(@"https://musicbrainz.org/ws/2/release-group/",
                                                 @{ @"query": q, @"fmt": @"json", @"limit": @"3" }), &ok);
        NSMutableArray *bons = [NSMutableArray array];
        for (NSDictionary *g in r[@"release-groups"]) if ([g[@"score"] integerValue] >= 90) [bons addObject:g];
        grupos = bons.count == 1 ? bons : nil;   // mais do que um: ambíguo, fica erudito
    }
    for (NSDictionary *g in grupos) {
        for (NSString *chave in @[@"genres", @"tags"]) {
            for (NSDictionary *t in g[chave]) {
                if ([[t[@"name"] lowercaseString] isEqualToString:@"opera"]) return YES;
            }
        }
    }
    return NO;
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

// O pico verdadeiro, como o do libebur128 (o do rsgain com o zp, TruePeak=true):
// sobreamostragem 4× abaixo de 96 kHz e 2× abaixo de 192 kHz, por um FIR de 49
// coeficientes (sinc com janela de Hann) em fases; acima, o pico das amostras.
// Cada fase guarda os seus coeficientes pelo atraso, em tramas.
enum { kZPCoeficientes = 49, kZPFatorMaximo = 4, kZPAtrasoMaximo = 25 };

typedef struct {
    int fator, atraso;
    int quantos[kZPFatorMaximo];
    int indice[kZPFatorMaximo][kZPAtrasoMaximo];
    double coef[kZPFatorMaximo][kZPAtrasoMaximo];
} ZPSobreamostragem;

static ZPSobreamostragem ZPSobreamostragemPara(double taxa) {
    ZPSobreamostragem s = { .fator = taxa < 96000 ? 4 : taxa < 192000 ? 2 : 1 };
    s.atraso = (kZPCoeficientes + s.fator - 1) / s.fator;
    if (s.fator == 1) return s;
    for (int j = 0; j < kZPCoeficientes; ++j) {
        double m = j - (kZPCoeficientes - 1) / 2.0, c = 1.0;
        if (fabs(m) > 1e-6) c = sin(m * M_PI / s.fator) / (m * M_PI / s.fator);
        c *= 0.5 * (1.0 - cos(2.0 * M_PI * j / (kZPCoeficientes - 1)));
        if (fabs(c) > 1e-6) {   // os zeros do sinc ficam de fora, como lá
            int f = j % s.fator;
            s.indice[f][s.quantos[f]] = j / s.fator;
            s.coef[f][s.quantos[f]++] = c;
        }
    }
    return s;
}

// Energia dos blocos de 400 ms, de 100 em 100 ms, de uma faixa; e o pico
// verdadeiro, nunca abaixo do das amostras.
static NSData *ZPBlocosDeEnergia(const ZPGravacao *g, const ZPCorreccao *cs, int nc,
                                 long long inicio, long long fim, double *pico) {
    ZPBiquad pre[2], alto[2];
    ZPFiltroK(g->taxa, &pre[0], &alto[0]);
    pre[1] = pre[0]; alto[1] = alto[0];
    ZPSobreamostragem so = ZPSobreamostragemPara(g->taxa);
    long long seg = llround(g->taxa * 0.1);
    NSMutableData *segmentos = [NSMutableData data];
    double soma = 0.0;
    long long noSegmento = 0;
    *pico = 0.0;
    const long long pedaco = 65536;
    float *buf = malloc(sizeof(float) * 2 * pedaco);
    // Por canal, as atraso − 1 tramas anteriores seguidas do pedaço; a faixa
    // começa sobre zeros, como um ficheiro no rsgain.
    const int antes = so.atraso - 1;
    float *hist[2] = { calloc(antes + pedaco, sizeof(float)), calloc(antes + pedaco, sizeof(float)) };
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
        if (so.fator == 1) continue;
        for (int c = 0; c < 2; ++c) {
            float *h = hist[c];
            for (long long i = 0; i < n; ++i) h[antes + i] = buf[2*i+c];
            for (long long i = 0; i < n; ++i) {
                const float *x = h + antes + i;   // x[-k] é a trama k atrás
                for (int f = 0; f < so.fator; ++f) {
                    double acc = 0.0;
                    for (int t = 0; t < so.quantos[f]; ++t) acc += x[-so.indice[f][t]] * so.coef[f][t];
                    float y = (float)acc;   // o libebur128 guarda a saída em float
                    if (fabsf(y) > *pico) *pico = fabsf(y);
                }
            }
            memmove(h, h + n, sizeof(float) * antes);
        }
    }
    free(hist[0]); free(hist[1]);
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

#pragma mark - AccurateRip

// A Apple serve muitos álbuns com o master do CD, e então a gravação coincide
// amostra a amostra com as cópias de CD na base do AccurateRip. No Geogaddi de
// 2026-11-20 coincidiram 22 de 23 faixas (a «Corsair» da Apple difere do CD;
// regravada, saiu igual à primeira), e as fronteiras certas ficaram 98 ms
// depois do fim do silêncio que as ancorava e 175 ms depois das posições do
// Música: nenhuma das duas âncoras é de fiar à amostra; esta é.
//
// O TOC do CD vem do MusicBrainz, dos lançamentos em CD do mesmo grupo (a
// edição que bate nas durações é quase sempre a digital, sem TOC). Uma faixa
// desliza ±0,5 s à volta do corte que já tinha, à procura da soma v1 de algum
// conjunto da base: a soma é linear, por isso desliza em O(1) por trama.
// Prensagens diferentes desviam o som do TOC (no Geogaddi, de 68 a 98 ms
// depois do silêncio): fica a que somar mais confiança no álbum.

static const long long kZPSectorAR = 588;              // tramas por sector de CD
static const double kZPProcuraAR = 0.5;                // s, para cada lado do corte que havia

// Uma trama de 16 bits como o AccurateRip a lê: o esquerdo em baixo.
static void ZPPalavrasAR(const ZPGravacao *g, const ZPCorreccao *cs, int nc, long long inicio, long long n, uint32_t *destino) {
    const long long pedaco = 65536;
    float *buf = malloc(sizeof(float) * 2 * pedaco);
    for (long long p = 0; p < n; p += pedaco) {
        long long m = MIN(pedaco, n - p);
        ZPLer(g, cs, nc, inicio + p, m, buf);
        for (long long i = 0; i < m; ++i) {
            long l = lrint((double)buf[2*i] * 32768.0), r = lrint((double)buf[2*i+1] * 32768.0);
            l = MIN(MAX(l, -32768L), 32767L);
            r = MIN(MAX(r, -32768L), 32767L);
            destino[p + i] = (uint32_t)(uint16_t)l | (uint32_t)(uint16_t)r << 16;
        }
    }
    free(buf);
}

// Σ_{j=1}^{L} j·x[a+s+j−1], módulo 2^32, para s = 0…n−1. C(s+1) = C(s) − S(s) + L·x[a+s+L],
// com S(s) a soma simples da janela. Lê a janela uma vez e as duas pontas.
static void ZPSomasAR(const ZPGravacao *g, const ZPCorreccao *cs, int nc, long long a, long long L, long long n, uint32_t *saida) {
    if (L <= 0) { memset(saida, 0, (size_t)n * sizeof(uint32_t)); return; }
    const long long pedaco = 65536;
    uint32_t *x = malloc(sizeof(uint32_t) * (size_t)MAX(pedaco, n));
    uint32_t C = 0, S = 0;
    for (long long p = 0; p < L; p += pedaco) {
        long long m = MIN(pedaco, L - p);
        ZPPalavrasAR(g, cs, nc, a + p, m, x);
        for (long long i = 0; i < m; ++i) { C += (uint32_t)(p + i + 1) * x[i]; S += x[i]; }
    }
    uint32_t *cabeca = malloc(sizeof(uint32_t) * (size_t)n), *cauda = x;
    ZPPalavrasAR(g, cs, nc, a, n, cabeca);
    ZPPalavrasAR(g, cs, nc, a + L, n, cauda);
    for (long long s = 0; s < n; ++s) {
        saida[s] = C;
        C = C - S + (uint32_t)L * cauda[s];
        S = S - cabeca[s] + cauda[s];
    }
    free(cabeca);
    free(x);
}

// A soma v1 da faixa a começar em a + s, s = 0…n−1: na primeira do disco não
// contam os multiplicadores abaixo de 5 × 588 − 1, na última os 5 sectores do
// fim (a regra do accuraterip-checksum e do whipper; no Geogaddi a primeira
// começa em silêncio e não a pôs à prova).
static void ZPSomasDaFaixaAR(const ZPGravacao *g, const ZPCorreccao *cs, int nc, long long a, long long W,
                             BOOL primeira, BOOL ultima, long long n, uint32_t *saida) {
    long long fim = ultima ? W - 5 * kZPSectorAR : W;
    ZPSomasAR(g, cs, nc, a, fim, n, saida);
    if (primeira) {
        uint32_t *menos = malloc(sizeof(uint32_t) * (size_t)n);
        ZPSomasAR(g, cs, nc, a, 5 * kZPSectorAR - 2, n, menos);
        for (long long s = 0; s < n; ++s) saida[s] -= menos[s];
        free(menos);
    }
}

// A soma v2 da faixa a começar em a: a mesma regra das pontas, mas cada
// produto de 64 bits entra com as duas metades. Não é linear, por isso não
// desliza: calcula-se só onde a v1 já encontrou a faixa. A base guarda as duas
// versões em conjuntos separados (no Geogaddi, a prensagem mais comum tinha
// 163 cópias na v1 e 189 na v2).
static uint32_t ZPSomaV2DaFaixaAR(const ZPGravacao *g, const ZPCorreccao *cs, int nc, long long a, long long W, BOOL primeira, BOOL ultima) {
    const long long pedaco = 65536;
    const long long de = primeira ? 5 * kZPSectorAR - 1 : 1, ate = ultima ? W - 5 * kZPSectorAR : W;
    uint32_t *x = malloc(sizeof(uint32_t) * pedaco);
    uint32_t soma = 0;
    for (long long p = 0; p < W; p += pedaco) {
        long long m = MIN(pedaco, W - p);
        ZPPalavrasAR(g, cs, nc, a + p, m, x);
        for (long long i = 0; i < m; ++i) {
            long long mult = p + i + 1;
            if (mult < de || mult > ate) continue;
            uint64_t produto = (uint64_t)x[i] * (uint64_t)mult;
            soma += (uint32_t)produto + (uint32_t)(produto >> 32);
        }
    }
    free(x);
    return soma;
}

static int ZPSomaDosDigitos(long v) { int s = 0; for (; v > 0; v /= 10) s += v % 10; return s; }

// Os TOC de CD do grupo, sem repetir: cada um com os deslocamentos (em
// sectores, com os 150 do princípio) e o fim, e o que o AccurateRip tem dele:
// por faixa, um dicionário soma v1 → confiança somada dos conjuntos.
static NSArray<NSDictionary *> *ZPDiscosNoAccurateRip(NSString *grupo, long disco, long faixasNoDisco, BOOL *respondeu) {
    *respondeu = YES;
    if (!grupo.length || faixasNoDisco <= 0) return @[];
    [NSThread sleepForTimeInterval:1.1];   // um pedido por segundo ao MusicBrainz
    BOOL ok = YES;
    NSDictionary *r = ZPPedirJSON(ZPEndereco(@"https://musicbrainz.org/ws/2/release",
                                             @{ @"release-group": grupo, @"inc": @"discids+media", @"limit": @"100", @"fmt": @"json" }), &ok);
    if (!ok) *respondeu = NO;
    NSMutableArray<NSDictionary *> *discos = [NSMutableArray array];
    NSMutableSet<NSString *> *vistos = [NSMutableSet set];
    for (NSDictionary *e in r[@"releases"]) {
        for (NSDictionary *m in e[@"media"]) {
            if (![[ZPOuNada(m[@"format"]) description] containsString:@"CD"]) continue;
            if ([ZPOuNada(m[@"position"]) longValue] != disco) continue;
            for (NSDictionary *dc in m[@"discs"]) {
                NSArray<NSNumber *> *o = ZPOuNada(dc[@"offsets"]);
                long fimDoDisco = [ZPOuNada(dc[@"sectors"]) longValue];
                if ((long)o.count != faixasNoDisco || fimDoDisco <= 0) continue;
                uint32_t id1 = 0, id2 = 0;
                int digitos = 0;
                for (NSUInteger i = 0; i < o.count; ++i) {
                    long lba = o[i].longValue - 150;
                    id1 += (uint32_t)lba;
                    id2 += (uint32_t)(MAX(lba, 1L) * (long)(i + 1));
                    digitos += ZPSomaDosDigitos(o[i].longValue / 75);
                }
                id1 += (uint32_t)(fimDoDisco - 150);
                id2 += (uint32_t)((fimDoDisco - 150) * (long)(o.count + 1));
                uint32_t cddb = (uint32_t)(digitos % 255) << 24 | (uint32_t)(fimDoDisco / 75 - o[0].longValue / 75) << 8 | (uint32_t)o.count;
                NSString *endereco = [NSString stringWithFormat:@"https://www.accuraterip.com/accuraterip/%x/%x/%x/dBAR-%03lu-%08x-%08x-%08x.bin",
                                      id1 & 0xF, id1 >> 4 & 0xF, id1 >> 8 & 0xF, (unsigned long)o.count, id1, id2, cddb];
                if ([vistos containsObject:endereco]) continue;
                [vistos addObject:endereco];
                BOOL veio = YES;
                NSData *d = ZPPedir([NSURL URLWithString:endereco], &veio);
                if (!veio) *respondeu = NO;
                if (!d.length) continue;
                NSMutableArray<NSMutableDictionary<NSNumber *, NSNumber *> *> *somas = [NSMutableArray array];
                for (NSUInteger i = 0; i < o.count; ++i) [somas addObject:[NSMutableDictionary dictionary]];
                const uint8_t *b = d.bytes;
                for (NSUInteger p = 0; p + 13 <= d.length; ) {
                    NSUInteger nt = b[p];
                    p += 13;
                    if (nt != o.count || p + 9 * nt > d.length) break;
                    for (NSUInteger t = 0; t < nt; ++t, p += 9) {
                        uint8_t conf = b[p];
                        uint32_t crc = (uint32_t)b[p+1] | (uint32_t)b[p+2] << 8 | (uint32_t)b[p+3] << 16 | (uint32_t)b[p+4] << 24;
                        if (!conf || !crc) continue;   // soma 0: faixa muda, nada a verificar
                        somas[t][@(crc)] = @([somas[t][@(crc)] longValue] + conf);
                    }
                }
                [discos addObject:@{ @"offsets": o, @"fim": @(fimDoDisco), @"somas": somas, @"id": dc[@"id"] ?: @"" }];
            }
        }
    }
    return discos;
}

// Acerta as fronteiras das faixas inteiras de um álbum pelo AccurateRip, se
// houver coincidência. `numeros` e `discos` são, por faixa, o número e o disco
// do catálogo; `totais`, as faixas desse disco. Devolve a linha do relatório.
// Muda «inicio», «fim» e «como» de cada faixa e põe «ar» (confiança, 0 se não
// coincide). As faixas mudas (só zeros) não se verificam: seguem as vizinhas.
static NSString *ZPAlinharPeloAccurateRip(const ZPGravacao *g, const ZPCorreccao *cs, int nc, NSArray<NSMutableDictionary *> *faixas,
                                          NSString *grupo, NSArray<NSNumber *> *numeros, NSArray<NSNumber *> *discos, NSArray<NSNumber *> *totais) {
    const long long M = llround(kZPProcuraAR * g->taxa);
    if (llround(g->taxa) != 44100) return nil;
    // Os TOC de cada disco do álbum.
    NSMutableDictionary<NSNumber *, NSArray<NSDictionary *> *> *tocs = [NSMutableDictionary dictionary];
    BOOL semResposta = NO;
    for (NSUInteger i = 0; i < faixas.count; ++i) {
        if (tocs[discos[i]]) continue;
        BOOL ok = YES;
        tocs[discos[i]] = ZPDiscosNoAccurateRip(grupo, discos[i].longValue, totais[i].longValue, &ok);
        if (!ok) semResposta = YES;
    }
    // Cada coincidência diz onde, na gravação, começaria o disco por aquele TOC:
    // a posição da faixa menos o seu deslocamento no TOC. É por aí que se
    // soma, e não pelo desvio ao corte de antes, que não é coerente ao
    // milissegundo de faixa para faixa (no Geogaddi, de +96 a +98 ms).
    // Chave: «índice do TOC:trama do princípio do disco».
    NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *achados = [NSMutableArray array];   // chave → confiança
    NSMutableDictionary<NSString *, NSNumber *> *peso = [NSMutableDictionary dictionary];               // chave → confiança no álbum
    NSMutableArray<NSDictionary *> *todosOsTOC = [NSMutableArray array];
    for (NSNumber *d in tocs) [todosOsTOC addObjectsFromArray:tocs[d]];
    long long (^posicaoNoTOC)(NSDictionary *, long, long long *) = ^long long (NSDictionary *t, long k, long long *W) {
        NSArray<NSNumber *> *o = t[@"offsets"];
        *W = ((k < (long)o.count ? o[k].longLongValue : [t[@"fim"] longLongValue]) - o[k-1].longLongValue) * kZPSectorAR;
        return (o[k-1].longLongValue - o[0].longLongValue) * kZPSectorAR;
    };
    uint32_t *somas = malloc(sizeof(uint32_t) * (size_t)(2 * M + 1));
    for (NSUInteger i = 0; i < faixas.count; ++i) {
        NSMutableDictionary<NSString *, NSNumber *> *daqui = [NSMutableDictionary dictionary];
        [achados addObject:daqui];
        long k = numeros[i].longValue;
        long long a = [faixas[i][@"inicio"] longLongValue] - M;
        for (NSDictionary *t in tocs[discos[i]]) {
            if (k < 1 || k > (long)[t[@"offsets"] count]) continue;
            long long W = 0, noTOC = posicaoNoTOC(t, k, &W);
            NSDictionary<NSNumber *, NSNumber *> *alvo = t[@"somas"][k-1];
            if (!alvo.count || a < 0 || a + W + 2 * M + 1 > g->n) continue;
            ZPSomasDaFaixaAR(g, cs, nc, a, W, k == 1, k == (long)[t[@"offsets"] count], 2 * M + 1, somas);
            for (long long s = 0; s <= 2 * M; ++s) {
                NSNumber *conf = alvo[@(somas[s])];
                if (!conf) continue;
                NSString *chave = [NSString stringWithFormat:@"%lu:%lld", (unsigned long)[todosOsTOC indexOfObjectIdenticalTo:t], a + s - noTOC];
                if (conf.longValue > [daqui[chave] longValue]) daqui[chave] = conf;
            }
        }
        for (NSString *c in daqui) peso[c] = @([peso[c] longValue] + daqui[c].longValue);
    }
    free(somas);
    NSString *melhor = nil;
    for (NSString *c in peso) if (!melhor || peso[c].longValue > peso[melhor].longValue) melhor = c;
    if (!melhor) {
        return semResposta && !todosOsTOC.count ? @"AccurateRip: o MusicBrainz ou o AccurateRip não responderam; cortes sem verificação."
             : !todosOsTOC.count ? @"AccurateRip: sem TOC de CD no MusicBrainz, ou sem o disco na base; cortes sem verificação."
             : @"AccurateRip: nenhuma faixa coincide com o CD (outro master, ou a gravação não é a do CD); cortes sem verificação.";
    }
    // As faixas: pelo princípio de disco do álbum; uma que só coincida noutro
    // (uma pausa entre faixas parte a cadeia) fica no seu. As que não coincidem
    // ficam onde o TOC do álbum as põe, encostadas às vizinhas, se isso estiver
    // a menos de ±0,5 s do corte de antes; senão ficam como estavam.
    NSArray<NSString *> *partes = [melhor componentsSeparatedByString:@":"];
    NSDictionary *tocDoAlbum = todosOsTOC[(NSUInteger)partes[0].integerValue];
    const long long discoDoAlbum = partes[1].longLongValue;
    NSUInteger verificadas = 0, mudas = 0, semVerificar = 0;
    long confianca = 0;
    NSMutableArray<NSNumber *> *desvios = [NSMutableArray array];
    for (NSUInteger i = 0; i < faixas.count; ++i) {
        NSMutableDictionary *f = faixas[i];
        NSDictionary<NSString *, NSNumber *> *daqui = achados[i];
        NSString *c = daqui[melhor] ? melhor : nil;
        if (!c) for (NSString *x in daqui) if (!c || daqui[x].longValue > daqui[c].longValue) c = x;
        long k = numeros[i].longValue;
        long long antes = [f[@"inicio"] longLongValue], W = 0, inicio = -1;
        NSDictionary *t = c ? todosOsTOC[(NSUInteger)[[c componentsSeparatedByString:@":"][0] integerValue]] : tocDoAlbum;
        long long disco = c ? [[c componentsSeparatedByString:@":"][1] longLongValue] : discoDoAlbum;
        if (k >= 1 && k <= (long)[t[@"offsets"] count]) inicio = disco + posicaoNoTOC(t, k, &W);
        BOOL muda = [f[@"silencio"] boolValue];
        if (c) {
            NSDictionary<NSNumber *, NSNumber *> *alvo = t[@"somas"][k-1];
            long v2 = [alvo[@(ZPSomaV2DaFaixaAR(g, cs, nc, inicio, W, k == 1, k == (long)[t[@"offsets"] count]))] longValue];
            f[@"ar"] = @(MAX(daqui[c].longValue, v2));
            confianca = MAX(confianca, MAX(daqui[c].longValue, v2));
            [desvios addObject:@((inicio - antes) * 1000.0 / g->taxa)];
            ++verificadas;
            f[@"como"] = [NSString stringWithFormat:@"AccurateRip, confiança %@ na v1%@ (%+.0f ms do corte de antes)", daqui[c],
                          v2 ? [NSString stringWithFormat:@" e %ld na v2", v2] : @"", (inicio - antes) * 1000.0 / g->taxa];
        } else {
            f[@"ar"] = @0;
            if (muda) ++mudas; else ++semVerificar;
            if (inicio < 0 || llabs(inicio - antes) > M) {
                f[@"como"] = [NSString stringWithFormat:@"%@; %@ (sem verificação)", muda ? @"silêncio digital" : @"NÃO coincide com o AccurateRip", f[@"como"]];
                continue;
            }
            f[@"como"] = [NSString stringWithFormat:@"%@; onde o TOC do CD a põe (%+.0f ms do corte de antes)",
                          muda ? @"silêncio digital, nada a verificar" : @"NÃO coincide com o AccurateRip", (inicio - antes) * 1000.0 / g->taxa];
        }
        f[@"inicio"] = @(MAX(inicio, 0LL));
        f[@"fim"] = @(MIN(inicio + W, g->n));
        if (i > 0 && [faixas[i-1][@"fim"] longLongValue] > inicio) faixas[i-1][@"fim"] = @(inicio);   // sem sobreposições
    }
    return [NSString stringWithFormat:@"AccurateRip: %lu de %lu faixas coincidem com o CD%@%@ (confiança até %ld, %+.0f ms em mediana do corte de antes).",
            (unsigned long)verificadas, (unsigned long)(verificadas + semVerificar),
            semVerificar ? @"; as outras ficam onde o TOC as põe" : @"",
            mudas ? [NSString stringWithFormat:@"; mais %lu de silêncio digital, sem nada a verificar", (unsigned long)mudas] : @"",
            confianca, ZPMediana(desvios)];
}

#pragma mark - O processamento

static NSString *ZPNomeDeFicheiro(NSString *s) {
    NSString *n = [[s ?: @"" stringByReplacingOccurrencesOfString:@"/" withString:@"-"]
                   stringByReplacingOccurrencesOfString:@":" withString:@""];
    n = [n stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    while ([n hasPrefix:@"."]) n = [n substringFromIndex:1];
    return n.length ? n : @"Sem nome";
}

// A faixa como o Música a mostrava, em JSON, para a etiqueta APPLE_MUSICA. Os
// nomes do ficheiro vêm do MusicBrainz ou do catálogo e podem ser outros (o
// «ОМ» do Grünberg, em 2026-11-08, saiu com os títulos em inglês da loja
// americana, e o Música mostra-os em cirílico). Por esta etiqueta a fonoteca
// liga as audições pelo Música ao ficheiro sem comparar nomes — com os mesmos
// campos que o tocaTintas lhe passa no «ouvir-musica». O persistent ID não
// serve: nas faixas do catálogo muda de cada vez que tocam.
static NSString *ZPDescricaoDoMusica(NSDictionary *m) {
    NSDictionary *d = @{ @"artista": ZPOuNada(m[@"artista"]) ?: @"",
                         @"album":   ZPOuNada(m[@"album"]) ?: @"",
                         @"disco":   ZPOuNada(m[@"disco"]) ?: @0,
                         @"faixa":   ZPOuNada(m[@"faixa"]) ?: @0,
                         @"titulo":  ZPOuNada(m[@"titulo"]) ?: @"",
                         @"duracao": ZPOuNada(m[@"duracao"]) ?: @0 };
    NSData *j = [NSJSONSerialization dataWithJSONObject:d
                                                options:NSJSONWritingSortedKeys | NSJSONWritingWithoutEscapingSlashes
                                                  error:NULL];
    return j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : nil;
}

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

#pragma mark - O corte pela TOC

// As marcas do Música erram dezenas de ms, mas são muitas: a primeira de cada
// faixa e, desde 2026-11, as posições que a gravação pergunta de cinco em cinco
// segundos («posicoes» na TOC). Cada uma diz onde a faixa começou no ficheiro
// (trama − posição × frequência), e as durações do catálogo dizem onde começa
// cada faixa em relação à primeira: a mediana das diferenças põe a cadeia
// inteira no sítio, a uns 20 ms, mesmo que a primeira faixa seja muda. O
// primeiro som deixou de ser a âncora (o «Next Exit» dos Interpol começa com
// 206 ms de zeros, o «Untitled» com 481, e uma faixa só de silêncio dá o
// primeiro som da seguinte); é só um dos silêncios que podem acertar a cadeia
// à amostra: o fim de um silêncio digital a encostar a uma das fronteiras,
// perto de onde as posições a põem.
//
// Uma posição que não anda enquanto as tramas andam é uma pausa ou um
// encravamento do Música (os Dead Kennedys de 2026-10-31): o início que dá
// salta, e a faixa tem um buraco — não sai, e diz-se onde. As faixas seguintes
// começam outra cadeia.
//
// Desde 2026-11-01 as posições trazem a trama pelo relógio do anfitrião, à
// hora a que se fez a pergunta («tramaDepois» na TOC diz que é dessas). Antes
// traziam a trama já escrita quando chegava a resposta, aos saltos de um
// bloco (100 ms) e com a demora da pergunta dentro: os limites largos ficam
// para as TOC antigas.
typedef struct {
    double desvioDaCadeia;     // s: acima disto, outra cadeia (e um salto destes é uma interrupção)
    double silencioAntes;      // s: o silêncio pode estar até isto antes das posições…
    double silencioDepois;     // s: …e até isto depois
    double atrasoDasPosicoes;  // s: o que as posições chegam tarde (< 0: adiantadas), em mediana, sem silêncio que acerte
} ZPLimitesDasPosicoes;
static const ZPLimitesDasPosicoes kZPPeloRelogio = { 0.10, 0.10, 0.10, -0.025 }; // El Pintor, 2026-11-01: −24 a −28 ms, ±5 ms por faixa
static const ZPLimitesDasPosicoes kZPPelaEscrita = { 0.30, 0.15, 0.08, 0.025 }; // Turn On the Bright Lights, 2026-11: 24 ms
static const double kZPSilencioMinimo = 0.01;      // s: os mais curtos são da própria música
static const double kZPDemoraMaxima = 0.25;        // s: perguntas ao Música mais lentas não contam

// Milésimas de trama para tramas, com o meio para longe do zero. As fronteiras
// somam-se em inteiros: com -ffast-math o compilador soma os double pela ordem
// que quer, e uma fronteira a meia trama (ms × 44,1 acaba em ,5 quando o ms
// acaba em 5) caía de um lado ou do outro conforme a compilação.
static long long ZPDeMilesimas(long long v) {
    return v >= 0 ? (v + 500) / 1000 : -((-v + 500) / 1000);
}

static void ZPCortarPelaTOC(const ZPGravacao *g, NSArray<NSMutableDictionary *> *faixas, NSDictionary *toc) {
    const double taxa = g->taxa;
    const long long taxaInteira = llround(taxa);
    NSArray<NSDictionary *> *posicoes = toc[@"posicoes"] ?: @[];
    const BOOL peloRelogio = posicoes.count && posicoes.firstObject[@"tramaDepois"] != nil;
    const ZPLimitesDasPosicoes L = peloRelogio ? kZPPeloRelogio : kZPPelaEscrita;
    // Os inícios que cada faixa dá, por ordem. No primeiro segundo da faixa a
    // posição é do arranque, com o Música ainda sem som (no «Untitled» dava
    // 0,72 s antes do certo; no «All the Rage Back Home», 0,28 s, e com os
    // limites pelo relógio passava por interrupção): as marcas não contam,
    // ficam só as perguntas de cinco em cinco segundos.
    NSMutableArray<NSMutableArray<NSNumber *> *> *inicios = [NSMutableArray array];
    NSMutableArray<NSMutableArray<NSNumber *> *> *tramasDosPontos = [NSMutableArray array];
    for (NSUInteger i = 0; i < faixas.count; ++i) {
        [inicios addObject:[NSMutableArray array]];
        [tramasDosPontos addObject:[NSMutableArray array]];
    }
    NSMutableArray<NSDictionary *> *pontos = [NSMutableArray array];
    for (NSMutableDictionary *f in faixas) [pontos addObject:f[@"marca"]];
    [pontos addObjectsFromArray:posicoes];
    [pontos sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"trama"] compare:b[@"trama"]];
    }];
    // Pelo relógio, a trama é da hora da pergunta, mas o Música lê a posição
    // perto do fim da ida e volta: uma resposta mais lenta do que o costume traz
    // a posição adiantada nessa diferença. No Geogaddi de 2026-11-20 três
    // perguntas levaram 0,24 s contra 0,12 s, a cinco segundos do princípio do
    // «Dandelion», do «I Saw Drones» e do «You Could Feel the Sky»; o início
    // dessas saltava 0,12–0,13 s (o excesso da demora, a 5 ms) e as três passavam
    // por interrompidas sem buraco nenhum no som. Acerta-se cada pergunta pelo
    // que demorou a mais ou a menos do que a mediana das vizinhas (três para cada
    // lado), não a da gravação toda: a partir dos 59:48 do mesmo Geogaddi o
    // Música passou a responder em 0,208 s certos, e aí as posições não vinham
    // adiantadas (pela mediana geral, o «You Could Feel the Sky» saltava 88 ms).
    // Com as vizinhas, o pior salto foi de 15 ms e nenhum início mexeu mais de 2 ms.
    NSMutableArray<NSDictionary *> *perguntas = [NSMutableArray array];
    if (peloRelogio) for (NSDictionary *p in posicoes) if (p[@"demora"]) [perguntas addObject:p];
    [perguntas sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"trama"] compare:b[@"trama"]];
    }];
    NSMapTable<NSDictionary *, NSNumber *> *acerto = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsObjectPointerPersonality
                                                                              valueOptions:NSPointerFunctionsStrongMemory];
    for (NSUInteger j = 0; j < perguntas.count; ++j) {
        NSUInteger de = j >= 3 ? j - 3 : 0, ate = MIN(j + 4, perguntas.count);
        NSArray<NSNumber *> *vizinhas = [[perguntas subarrayWithRange:NSMakeRange(de, ate - de)] valueForKey:@"demora"];
        [acerto setObject:@([perguntas[j][@"demora"] doubleValue] - ZPMediana(vizinhas)) forKey:perguntas[j]];
    }
    for (NSDictionary *p in pontos) {
        double posicao = [p[@"posicao"] doubleValue];
        if (![p[@"estado"] isEqualToString:@"playing"] || posicao < 1.0 || ![p[@"pid"] length]) continue;
        if (p[@"demora"] && [p[@"demora"] doubleValue] > kZPDemoraMaxima) continue;
        long long trama = [p[@"trama"] longLongValue] + llround([[acerto objectForKey:p] doubleValue] * taxa);
        // A faixa: a última com este pid que já tinha começado.
        for (NSInteger i = (NSInteger)faixas.count - 1; i >= 0; --i) {
            NSDictionary *m = faixas[i][@"marca"];
            if ([m[@"pid"] isEqualToString:p[@"pid"]] && [m[@"trama"] longLongValue] <= trama + llround(taxa)) {
                [inicios[i] addObject:@(trama - posicao * taxa)];
                [tramasDosPontos[i] addObject:@(trama)];
                break;
            }
        }
    }

    // As interrompidas: o início salta entre dois pontos seguidos.
    NSMutableArray *inicioDaFaixa = [NSMutableArray array];   // NSNumber, ou NSNull sem pontos
    for (NSUInteger i = 0; i < faixas.count; ++i) {
        NSArray<NSNumber *> *s = inicios[i];
        NSUInteger ate = s.count;
        for (NSUInteger k = 1; k < s.count; ++k) {
            double salto = s[k].doubleValue - s[k-1].doubleValue;
            if (fabs(salto) > L.desvioDaCadeia * taxa) {
                faixas[i][@"interrompida"] = [NSString stringWithFormat:
                    @"interrompida: o Música %@ %.2f s entre os %@ e os %@ do ficheiro (pausa ou encravamento), e a faixa tem um buraco",
                    salto > 0 ? @"parou" : @"saltou", fabs(salto) / taxa,
                    ZPTempo([tramasDosPontos[i][k-1] longLongValue], taxa), ZPTempo([tramasDosPontos[i][k] longLongValue], taxa)];
                ate = k;
                break;
            }
        }
        [inicioDaFaixa addObject:ate ? @(ZPMediana([s subarrayWithRange:NSMakeRange(0, ate)])) : [NSNull null]];
    }

    // As cadeias: faixas seguidas cujos inícios batem com a soma das durações.
    NSArray<NSArray<NSNumber *> *> *silencios = toc[@"silencios"] ?: @[];
    NSUInteger i = 0;
    while (i < faixas.count) {
        NSUInteger inicio = i;
        NSMutableArray<NSNumber *> *somas = [NSMutableArray arrayWithObject:@0.0];   // C_k, em tramas
        NSMutableArray<NSNumber *> *milesimas = [NSMutableArray arrayWithObject:@0LL];   // C_k, exacto, em milésimas de trama
        NSMutableArray<NSNumber *> *desvios = [NSMutableArray array];               // início − C_k, por ponto
        for (NSNumber *s in inicios[i]) [desvios addObject:@(s.doubleValue)];
        while (YES) {
            long long cm = milesimas.lastObject.longLongValue + llround([faixas[i][@"duracao"] doubleValue] * 1000.0) * taxaInteira;
            double c = cm / 1000.0;
            [milesimas addObject:@(cm)];
            [somas addObject:@(c)];
            if (faixas[i][@"interrompida"] || i + 1 >= faixas.count) break;
            NSNumber *s = ZPOuNada(inicioDaFaixa[i + 1]);
            if (s && desvios.count && fabs(s.doubleValue - c - ZPMediana(desvios)) > L.desvioDaCadeia * taxa) break;
            ++i;
            for (NSNumber *x in inicios[i]) [desvios addObject:@(x.doubleValue - c)];
        }
        NSUInteger fimDaCadeia = i;   // inclusive
        ++i;

        // O sítio da cadeia: pelas posições; sem nenhuma, pelo primeiro som.
        double o = ZPMediana(desvios);
        NSString *pelas = [NSString stringWithFormat:@"%lu posições do Música", (unsigned long)desvios.count];
        if (!desvios.count) {
            NSDictionary *m = faixas[inicio][@"marca"];
            long long est = [(m[@"inicioEstimado"] ?: m[@"trama"]) longLongValue];
            long long som = ZPPrimeiroSom(g, MAX(0LL, est - llround(0.5 * taxa)), g->n);
            o = som >= 0 ? (double)som : (double)MAX(0LL, est);
            pelas = @"o primeiro som (sem posições do Música)";
        }
        // À amostra, pelo silêncio que encoste a uma fronteira.
        BOOL achou = NO;
        double melhor = 0.0, melhorDesvio = DBL_MAX;
        long long fimDoMelhor = 0;
        NSUInteger fronteira = 0;
        for (NSArray<NSNumber *> *sil in silencios) {
            double e = sil[1].doubleValue;
            if (e >= g->n || e - sil[0].doubleValue < kZPSilencioMinimo * taxa) continue;
            for (NSUInteger k = 0; k < somas.count; ++k) {
                double d = o - (e - somas[k].doubleValue);   // > 0: as posições põem-na depois
                if (d <= L.silencioAntes * taxa && d >= -L.silencioDepois * taxa && fabs(d) < melhorDesvio) {
                    achou = YES;
                    melhorDesvio = fabs(d);
                    melhor = e - somas[k].doubleValue;
                    fimDoMelhor = sil[1].longLongValue;
                    fronteira = k;
                }
            }
        }
        NSString *ancora;
        long long om;   // o sítio da cadeia, em milésimas de trama
        if (achou) {
            ancora = [NSString stringWithFormat:@"no fim do silêncio aos %@, %@ (%@ a %+.0f ms)",
                      ZPTempo(fimDoMelhor, taxa),
                      fronteira == 0 ? @"o primeiro som" : fronteira + 1 == somas.count ? @"o fim do álbum a encostar ao som seguinte"
                                     : [NSString stringWithFormat:@"no início da %lu.ª faixa", (unsigned long)(inicio + fronteira + 1)],
                      pelas, (o - melhor) * 1000.0 / taxa];
            om = fimDoMelhor * 1000 - milesimas[fronteira].longLongValue;
        } else if (desvios.count) {
            om = llround((o - L.atrasoDasPosicoes * taxa) * 1000.0);
            ancora = peloRelogio
                ? [NSString stringWithFormat:@"pelas %@, mais %.0f ms de adiantamento típico (pelo relógio; nenhum silêncio bate)",
                   pelas, -L.atrasoDasPosicoes * 1000.0]
                : [NSString stringWithFormat:@"pelas %@, menos %.0f ms de atraso típico (±20 ms: nenhum silêncio bate)",
                   pelas, L.atrasoDasPosicoes * 1000.0];
        } else {
            om = llround(o) * 1000;
            ancora = [NSString stringWithFormat:@"pel%@", pelas];   // «pelo primeiro som»
        }

        for (NSUInteger k = inicio; k <= fimDaCadeia; ++k) {
            NSMutableDictionary *f = faixas[k];
            long long xm = om + milesimas[k - inicio].longLongValue;
            double x = xm / 1000.0;
            long long a = ZPDeMilesimas(xm), b = ZPDeMilesimas(om + milesimas[k - inicio + 1].longLongValue);
            [f removeObjectForKey:@"falta"];
            NSNumber *s = ZPOuNada(inicioDaFaixa[k]);
            NSString *daTOC = !s ? @"sem posições do Música"
                            : [NSString stringWithFormat:@"posições a %+.0f ms", (s.doubleValue - x) * 1000.0 / taxa];
            f[@"como"] = k == inicio ? [NSString stringWithFormat:@"cadeia ancorada %@; %@", ancora, daTOC]
                                     : [NSString stringWithFormat:@"soma das durações (%@)", daTOC];
            if (a < 0) { f[@"falta"] = @"o início: a gravação começou com a faixa já a tocar"; a = 0; }
            if (b > g->n) { f[@"falta"] = @"o fim: a gravação parou antes"; b = g->n; }
            if (f[@"interrompida"]) f[@"falta"] = f[@"interrompida"];
            f[@"inicio"] = @(a);
            f[@"exacto"] = @(x);
            f[@"fim"] = @(b);
        }
    }
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
        // As marcas gravadas desempatam álbuns com o mesmo nome (ver
        // +[ZPCatalogoDaApple albumDe:…]).
        NSMutableArray<NSDictionary *> *dasMarcas = [NSMutableArray array];
        for (NSDictionary *f in a[@"faixas"]) {
            [dasMarcas addObject:@{ @"titulo": f[@"marca"][@"titulo"] ?: @"", @"duracao": f[@"marca"][@"duracao"] ?: @0 }];
        }
        NSDictionary *cat = ZPAlbumNoCatalogo(a[@"artista"], a[@"nome"], dasMarcas);
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

    // 4. Onde começa e acaba cada faixa. Com todas as durações de confiança e
    // sem som perdido, manda o passo 4b, pela TOC; o que se segue fica para os
    // outros casos. A primeira no primeiro som depois da
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

    // 4b. Pela TOC (ver ZPCortarPelaTOC), quando todas as durações são de
    // confiança e não se perdeu som: as fronteiras de cima ficam só para os
    // outros casos.
    BOOL pelaTOC = faixas.count > 0 && perdas.count == 0;
    for (NSDictionary *f in faixas) pelaTOC = pelaTOC && [f[@"duracaoExacta"] boolValue];
    if (pelaTOC) ZPCortarPelaTOC(&g, faixas, toc);

    // 5. A grelha de cada faixa, já com as rampas desfeitas; a sonoridade.
    // Uma faixa em que nenhuma amostra chegue a meio LSB de 16 bits é silêncio
    // digital com ruído por cima: o Música, quando arranca uma faixa muda do
    // zero (a «Magic Window» do Geogaddi, 2026-11-20, com a rampa de entrada e
    // ruído abaixo de 1 LSB até ao fim), põe-lhe tramas fora de todas as
    // grelhas, e o álbum inteiro saía em 24 bits e «não bit-exacto». No CD é
    // zeros. Não conta para o veredicto e arredonda-se; num álbum de 24 bits
    // fica com o que tem. Uma faixa com som de verdade passa sempre de meio LSB.
    const long long pedaco = 65536;
    float *buf = malloc(sizeof(float) * 2 * pedaco);
    void (^medir)(NSMutableDictionary *) = ^(NSMutableDictionary *f) {
        long long a = [f[@"inicio"] longLongValue], b = [f[@"fim"] longLongValue];
        // As rampas que ficaram como estão não contam para o veredicto, como
        // no vigia da gravação: contam-se à parte, para o relatório.
        long long fora16 = 0, fora24 = 0, naRampa = 0;
        float maximo = 0.0f;
        int k = 0;
        for (long long p = a; p < b; p += pedaco) {
            long long n = MIN(pedaco, b - p);
            ZPLer(&g, cs, nc, p, n, buf);
            for (long long i = 0; i < 2 * n; ++i) maximo = MAX(maximo, fabsf(buf[i]));
            for (long long i = 0; i < n; ++i) {
                BOOL f16 = ZPForaDaGrelha(buf[2*i], 32768.0f) || ZPForaDaGrelha(buf[2*i+1], 32768.0f);
                BOOL f24 = ZPForaDaGrelha(buf[2*i], 8388608.0f) || ZPForaDaGrelha(buf[2*i+1], 8388608.0f);
                if (!f16 && !f24) continue;
                long long t = p + i;
                BOOL emRampa = NO;
                for (k = 0; k < nc && !emRampa; ++k) {
                    emRampa = !cs[k].valores && t >= cs[k].inicio && t < cs[k].inicio + cs[k].n;
                }
                if (emRampa) { if (f24) ++naRampa; continue; }
                if (f16) ++fora16;
                if (f24) ++fora24;
            }
        }
        BOOL silencio = maximo * 32768.0f < 0.5f;
        f[@"silencio"] = @(silencio);
        if (silencio) {
            f[@"ruido"] = @(fora24 + naRampa);
            fora16 = fora24 = naRampa = 0;
        }
        double pico = 0.0;
        NSData *blocos = ZPBlocosDeEnergia(&g, cs, nc, a, b, &pico);
        [f addEntriesFromDictionary:@{ @"fora16": @(fora16), @"fora24": @(fora24), @"naRampa": @(naRampa),
                                       @"pico": @(pico), @"blocos": blocos }];
    };
    for (NSMutableDictionary *f in faixas) if (!f[@"falta"]) medir(f);

    // 5b. AccurateRip, por álbum, quando o álbum cai na grelha de 16 bits (ver
    // ZPAlinharPeloAccurateRip). As faixas que mudaram de sítio medem-se outra vez.
    for (NSMutableDictionary *a in albuns) {
        NSMutableArray<NSMutableDictionary *> *inteiras = [NSMutableArray array];
        BOOL dezasseis = YES;
        for (NSMutableDictionary *f in a[@"faixas"]) {
            if (f[@"falta"]) continue;
            [inteiras addObject:f];
            if ([f[@"fora16"] longLongValue] > 0) dezasseis = NO;
        }
        NSString *grupo = ZPOuNada(ZPOuNada(a[@"mb"][@"release-group"])[@"id"]);
        if (!inteiras.count || !dezasseis || !grupo) continue;
        NSMutableArray<NSNumber *> *numeros = [NSMutableArray array], *discos = [NSMutableArray array], *totais = [NSMutableArray array];
        BOOL conhecidas = YES;
        for (NSMutableDictionary *f in inteiras) {
            NSDictionary *t = f[@"catalogo"], *mt = f[@"mb"];
            long numero = [(ZPOuNada(t[@"trackNumber"]) ?: ZPOuNada(mt[@"position"]) ?: @0) longValue];
            long disco = [(ZPOuNada(t[@"discNumber"]) ?: @1) longValue], total = 0;
            NSArray *suportes = a[@"mb"][@"media"];
            if (disco >= 1 && (NSUInteger)disco <= suportes.count) total = [suportes[disco - 1][@"track-count"] longValue];
            if (numero <= 0 || total <= 0) conhecidas = NO;
            [numeros addObject:@(numero)];
            [discos addObject:@(disco)];
            [totais addObject:@(total)];
        }
        if (!conhecidas) continue;
        NSMutableArray<NSArray<NSNumber *> *> *antes = [NSMutableArray array];
        for (NSMutableDictionary *f in inteiras) [antes addObject:@[ f[@"inicio"], f[@"fim"] ]];
        a[@"accuraterip"] = ZPAlinharPeloAccurateRip(&g, cs, nc, inteiras, grupo, numeros, discos, totais);
        for (NSUInteger i = 0; i < inteiras.count; ++i) {
            if (![antes[i][0] isEqual:inteiras[i][@"inicio"]] || ![antes[i][1] isEqual:inteiras[i][@"fim"]]) medir(inteiras[i]);
        }
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
                        cat ? [NSString stringWithFormat:@"%@ (loja %@)", cat[@"collectionId"], cat[@"loja"]] : @"não encontrado",
                        mb ? mb[@"id"] : a[@"mbSemResposta"] ? @"não respondeu (servidor ocupado); as etiquetas são só as da Apple"
                                              : @"sem edição que bata sem ambiguidade"]];
        if (!inteiras.count) {
            [rel addObject:@"Nenhuma faixa inteira: nada escrito."];
            for (NSMutableDictionary *f in todas) [rel addObject:[NSString stringWithFormat:@"  «%@»: falta %@.", f[@"marca"][@"titulo"], f[@"falta"]]];
            continue;
        }

        long long fora16 = 0, fora24 = 0, naRampa = 0;
        NSMutableData *blocosDoAlbum = [NSMutableData data];
        double picoDoAlbum = 0.0;
        for (NSMutableDictionary *f in inteiras) {
            fora16 += [f[@"fora16"] longLongValue];
            fora24 += [f[@"fora24"] longLongValue];
            naRampa += [f[@"naRampa"] longLongValue];
            [blocosDoAlbum appendData:f[@"blocos"]];
            picoDoAlbum = MAX(picoDoAlbum, [f[@"pico"] doubleValue]);
        }
        unsigned bits = fora16 == 0 ? 16 : 24;
        BOOL exacto = fora16 == 0 || fora24 == 0;
        double sonoridadeDoAlbum = ZPSonoridade(blocosDoAlbum);
        double ganhoDoAlbum = -18.0 - sonoridadeDoAlbum;

        NSString *genero = ZPOuNada(((NSDictionary *)inteiras[0][@"catalogo"])[@"primaryGenreName"]) ?: ZPOuNada(cat[@"primaryGenreName"]);
        BOOL erudita = [genero isEqualToString:@"Classical"] || [genero isEqualToString:@"Clássica"];
        if (erudita) {
            genero = @"Erudite";
            NSString *grupo = ZPOuNada(ZPOuNada(mb[@"release-group"])[@"id"]);
            if (ZPEOperaNoMusicBrainz(artistaDoAlbum, nomeDoAlbum, grupo)) {
                genero = @"Opera";
                [rel addObject:@"Género: Opera (etiqueta «opera» do grupo no MusicBrainz)."];
            }
        }
        NSString *ano = [ZPOuNada(mb[@"date"]) ?: ZPOuNada(cat[@"releaseDate"]) ?: @"" description];
        if (ano.length > 4) ano = [ano substringToIndex:4];
        NSArray *editoras = mb[@"label-info"];
        NSString *editora = editoras.count ? ZPOuNada(ZPOuNada(editoras[0][@"label"])[@"name"]) : nil;

        // A capa: a do catálogo a 600 px, como na fonoteca; senão a que o
        // Música tinha, guardada pela gravação.
        NSData *capa = nil;
        if (cat) capa = [ZPCatalogoDaApple capaDoAlbum:cat lado:600];
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
        // Uma pasta que já tem FLAC deste álbum (faixas regravadas, como a
        // «Corsair» de 2026-11-21): o ReplayGain de álbum daqui seria só das
        // faixas novas (deu −0,77 dB contra os −5,53 do Geogaddi), por isso não
        // se escreve; calcula-se com o rsgain depois de as juntar.
        BOOL jaTinha = NO;
        for (NSString *nome in [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:pasta.path error:NULL] ?: @[]) {
            if ([nome.pathExtension.lowercaseString isEqualToString:@"flac"] && nome.pathComponents.count <= 2) { jaTinha = YES; break; }
        }
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
        long long ruido = 0;
        NSUInteger comRuido = 0;
        for (NSMutableDictionary *f in inteiras) if ([f[@"ruido"] longLongValue] > 0) { ruido += [f[@"ruido"] longLongValue]; ++comRuido; }
        NSString *notaDoRuido = !ruido ? @""
            : [NSString stringWithFormat:@" (mais %lld tramas de ruído abaixo de meio LSB em %lu %@ de silêncio, arredondadas para zero)",
               ruido, (unsigned long)comRuido, comRuido == 1 ? @"faixa" : @"faixas"];
        NSString *notaDoGanho = jaTinha
            ? @"ReplayGain de álbum não escrito: a pasta já tinha faixas deste álbum; corre «rsgain easy -p zp» na pasta depois de as juntar"
            : [NSString stringWithFormat:@"ReplayGain do álbum %+.2f dB, pico verdadeiro %.6f", ganhoDoAlbum, picoDoAlbum];
        [rel addObject:[NSString stringWithFormat:@"%u bits, %@%@. %@.%@", bits,
                        !exacto ? [NSString stringWithFormat:@"NÃO bit-exacto (%lld tramas fora da grelha de 24 bits, arredondadas)", fora24]
                        : naRampa ? [NSString stringWithFormat:@"bit-exacto fora das rampas que ficaram como estão (%lld tramas, arredondadas)", naRampa]
                        : @"bit-exacto",
                        notaDoRuido, notaDoGanho, notaDaCapa]];
        if (a[@"accuraterip"]) [rel addObject:a[@"accuraterip"]];

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
            if ([m[@"titulo"] length]) por(@"APPLE_MUSICA", ZPDescricaoDoMusica(m));
            if (sonoridade > kZPSemSonoridade) {
                por(@"REPLAYGAIN_TRACK_GAIN", [NSString stringWithFormat:@"%+.2f dB", ganho]);
                por(@"REPLAYGAIN_TRACK_PEAK", [NSString stringWithFormat:@"%.8f", [f[@"pico"] doubleValue]]);
            }
            if (sonoridadeDoAlbum > kZPSemSonoridade && !jaTinha) {
                por(@"REPLAYGAIN_ALBUM_GAIN", [NSString stringWithFormat:@"%+.2f dB", ganhoDoAlbum]);
                por(@"REPLAYGAIN_ALBUM_PEAK", [NSString stringWithFormat:@"%.8f", picoDoAlbum]);
            }

            // Mais de um disco: cada um na sua pasta CD01, CD02…, como na
            // fonoteca, com um albumart_backup que aponta para o do álbum.
            NSString *base = [NSString stringWithFormat:@"%02ld %@", numero, ZPNomeDeFicheiro(titulo)];
            NSString *pastaDoDisco = pasta.path;
            if (discos > 1) {
                pastaDoDisco = [pasta.path stringByAppendingPathComponent:[NSString stringWithFormat:@"CD%02ld", disco]];
                [[NSFileManager defaultManager] createDirectoryAtPath:pastaDoDisco withIntermediateDirectories:YES attributes:nil error:NULL];
                NSString *atalho = [pastaDoDisco stringByAppendingPathComponent:@"albumart_backup"];
                if ([[NSFileManager defaultManager] fileExistsAtPath:[pasta.path stringByAppendingPathComponent:@"albumart_backup"]]
                    && ![[NSFileManager defaultManager] attributesOfItemAtPath:atalho error:NULL]) {
                    [[NSFileManager defaultManager] createSymbolicLinkAtPath:atalho withDestinationPath:@"../albumart_backup" error:NULL];
                }
            }
            NSString *caminho = [pastaDoDisco stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"flac"]];
            for (int k = 2; [[NSFileManager defaultManager] fileExistsAtPath:caminho]; ++k) {
                caminho = [pastaDoDisco stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ (%d).flac", base, k]];
            }
            long long ini = [f[@"inicio"] longLongValue], fim = [f[@"fim"] longLongValue];
            NSString *falha = nil;
            BOOL bem = ZPEscreverFLAC(caminho, &g, cs, nc, ini, fim, bits, et, capa, &falha);
            if (bem) ++escritas;
            NSString *grelha = [f[@"silencio"] boolValue]
                                 ? ([f[@"ruido"] longLongValue] > 0 ? [NSString stringWithFormat:@"silêncio digital (%@ tramas de ruído abaixo de meio LSB, arredondadas)", f[@"ruido"]]
                                                                    : @"silêncio digital")
                             : [f[@"fora16"] longLongValue] == 0 ? @"16 bits exactos"
                             : [f[@"fora24"] longLongValue] == 0 ? @"24 bits exactos"
                             : [NSString stringWithFormat:@"%@ tramas fora da grelha", f[@"fora24"]];
            if ([f[@"naRampa"] longLongValue] > 0) {
                grelha = [grelha stringByAppendingFormat:@" (mais %@ numa rampa que ficou como está)", f[@"naRampa"]];
            }
            NSString *ganhoDaFaixa = sonoridade > kZPSemSonoridade ? [NSString stringWithFormat:@"%+.2f dB", ganho] : @"sem ReplayGain de faixa";
            [rel addObject:[NSString stringWithFormat:@"  %@  %@ a %@ (%@)  %@; %@; %@%@",
                            [caminho substringFromIndex:pasta.path.length + 1], ZPTempo(ini, g.taxa), ZPTempo(fim, g.taxa), ZPTempo(fim - ini, g.taxa),
                            f[@"como"], grelha, ganhoDaFaixa, bem ? @"" : [NSString stringWithFormat:@"  — FALHOU: %@", falha]]];
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
    // O relatório não apaga o de outra gravação do mesmo álbum: «Processamento
    // (2).txt», como os FLAC.
    for (NSURL *pasta in [NSOrderedSet orderedSetWithArray:pastas]) {
        NSURL *destino = [pasta URLByAppendingPathComponent:@"Processamento.txt"];
        for (int k = 2; [[NSFileManager defaultManager] fileExistsAtPath:destino.path]; ++k) {
            destino = [pasta URLByAppendingPathComponent:[NSString stringWithFormat:@"Processamento (%d).txt", k]];
        }
        [relatorio writeToURL:destino atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
