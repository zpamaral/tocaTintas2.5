//
//  vectorizar.m
//
//  Um vector de 512 números por faixa, pelo codificador de áudio do CLAP
//  (laion/larger_clap_general) convertido para Core ML, a correr no Neural
//  Engine. Faz o mesmo que o analisar.py, sem Python nem PyTorch:
//
//    - três excertos de 10 s, aos 25, 50 e 75 % da faixa (um só, no início, se
//      a faixa tiver 30 s ou menos), mono a 48 kHz, lidos com o ExtAudioFile;
//    - o espectrograma mel de cada excerto, igual ao do ClapFeatureExtractor
//      do transformers (janela de Hann periódica de 1024, salto de 480, margens
//      reflectidas, banco «slaney» de 64 bandas, potência em dB);
//    - o modelo dá um vector por excerto; o da faixa é a média dos três,
//      normalizada.
//
//  As «assinaturas» ficam na base da fonoteca (CDs/.fonoteca.sqlite), tabela
//  assinaturas: uma por música e por modelo, com o md5 do áudio de que se
//  calculou. É daí que sai a estação.
//
//  Uso:
//    vectorizar actualizar BASE
//    vectorizar refinar BASE [--minutos N]
//    vectorizar associar BASE MAPA --artista A [--titulo T] [--semente S] [-n 24]
//    vectorizar descobertas MAPA [BASE [--semente S]] [-n 50]
//    vectorizar esquecer MAPA ID
//        Calcula as assinaturas que faltam: músicas novas, ou cujo ficheiro
//        preferido mudou de áudio.
//    vectorizar estacao BASE (caminho | uuid | musica:PID) [-n 50] [--por-artista 3] [--por-album 2] [--mapa MAPA]
//        Escreve os caminhos da estação, um por linha, com a semente à cabeça e
//        os vizinhos por ordem de semelhança. Se a semente ainda não tiver
//        assinatura, calcula-a (e guarda-a, se a música for da fonoteca).
//        Sai com 3 se a semente não servir e com 4 se a base não tiver assinaturas.
//    vectorizar mapear BASE MAPA
//    vectorizar importar BASE lista.tsv saída
//        Traz para a base os vectores de saída.f32/saída.ids (ver abaixo).
//    vectorizar [--modelo clap_audio.mlmodelc] [--cpu] [--loja] lista.tsv saída
//        lista.tsv: id <tab> duração <tab> caminho. Escreve saída.f32 (512
//        float32 por faixa) e saída.ids (um id por linha, pela mesma ordem).
//        Retoma de onde ficou.
//    vectorizar --excerto segundos ficheiro pcm.f32
//    vectorizar --mel pcm.f32 mel.f32
//    vectorizar [--modelo …] --vector-do-mel mel.f32 vector.f32
//        Ensaios: o excerto tal como o programa o lê, o mel de um excerto e o
//        vector de um mel, para comparar com o transformers.
//
//  O modelo procura-se ao lado do executável e, dentro de uma aplicação, em
//  Contents/Resources; --modelo manda em ambos.
//
//  Compilar à mão:
//    clang -fobjc-arc -O2 -o vectorizar vectorizar.m -framework Foundation \
//        -framework CoreML -framework AudioToolbox -framework Accelerate -lsqlite3
//

#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <AudioToolbox/AudioToolbox.h>
#import <Accelerate/Accelerate.h>
#import <mach/mach_time.h>
#include <sqlite3.h>
#include <sys/resource.h>
#include "mel_slaney.h"

// O nome com que as assinaturas ficam na base: o modelo e a maneira de tirar
// os excertos. Mudando um ou outra, muda o nome, e as antigas não se misturam.
static const char * const kModelo = "larger_clap_general/3x10s";
// A assinatura é um processo: primeiro o esboço, com três janelas, que serve
// logo; depois, sem pressa, a fina, com quinze (modo «refinar»). Medido em 346
// faixas: com 3 janelas só 6,4 das 10 vizinhas são as que 31 janelas dariam;
// com 7 são 8,1 e com 15 são 9,1. Acima de 15 já não compensa a leitura.
static const char * const kModeloFino = "larger_clap_general/15x10s";
static int gJanelas = 3;

enum {
    kFrequencia = 48000,
    kTramasDoExcerto = 480000,   // 10 s
    kJanela = 1024,
    kSalto = 480,
    kQuadros = 1001,             // 1 + 480000 / 480
    kBandas = 64,
    kBins = 513,
    kDimensao = 512,
};

static double ZPAgora(void) {
    static mach_timebase_info_data_t base;
    if (base.denom == 0) mach_timebase_info(&base);
    return (double)mach_absolute_time() * base.numer / base.denom / 1e9;
}

#pragma mark - Leitura do som

// Até 10 s a partir de «inicio» (segundos), em mono a 48 kHz. Devolve o número
// de tramas lidas; menos de 1 s não serve a ninguém e conta como falha.
static UInt32 ZPLerExcerto(ExtAudioFileRef ficheiro, const AudioStreamBasicDescription *doFicheiro,
                           double inicio, float *mono) {
    UInt32 canais = doFicheiro->mChannelsPerFrame;
    if (ExtAudioFileSeek(ficheiro, (SInt64)llround(inicio * doFicheiro->mSampleRate)) != noErr) return 0;
    static float *bloco = NULL;
    static UInt32 canaisDoBloco = 0;
    const UInt32 tramasPorBloco = 16384;
    if (canais > canaisDoBloco) {
        free(bloco);
        bloco = malloc((size_t)tramasPorBloco * canais * sizeof(float));
        canaisDoBloco = canais;
    }
    UInt32 lidas = 0;
    while (lidas < kTramasDoExcerto) {
        UInt32 pedido = MIN(tramasPorBloco, kTramasDoExcerto - lidas);
        AudioBufferList lista = { .mNumberBuffers = 1 };
        lista.mBuffers[0] = (AudioBuffer){ canais, pedido * canais * (UInt32)sizeof(float), bloco };
        UInt32 tramas = pedido;
        if (ExtAudioFileRead(ficheiro, &tramas, &lista) != noErr || tramas == 0) break;
        if (canais == 1) {
            memcpy(mono + lidas, bloco, tramas * sizeof(float));
        } else {
            // A média dos canais: para o estéreo é o que o ffmpeg faz com -ac 1.
            for (UInt32 i = 0; i < tramas; ++i) {
                float soma = 0.0f;
                for (UInt32 c = 0; c < canais; ++c) soma += bloco[i * canais + c];
                mono[lidas + i] = soma / (float)canais;
            }
        }
        lidas += tramas;
    }
    return lidas;
}

// O «repeatpad» do CLAP: um excerto curto repete-se por inteiro as vezes que
// couberem, e o resto fica a zeros.
static void ZPRepetirEEncher(float *mono, UInt32 lidas) {
    if (lidas >= kTramasDoExcerto) return;
    UInt32 vezes = kTramasDoExcerto / lidas;
    for (UInt32 v = 1; v < vezes; ++v) memcpy(mono + v * lidas, mono, lidas * sizeof(float));
    UInt32 cheio = vezes * lidas;
    memset(mono + cheio, 0, (kTramasDoExcerto - cheio) * sizeof(float));
}

#pragma mark - Espectrograma mel

typedef struct {
    vDSP_DFT_SetupD dft;
    double janela[kJanela];
    double *alargado;            // o excerto com as margens reflectidas
    double re[kJanela], im[kJanela], reS[kJanela], imS[kJanela], potencia[kBins];
} ZPMel;

static ZPMel *ZPMelCriar(void) {
    ZPMel *m = calloc(1, sizeof(ZPMel));
    m->dft = vDSP_DFT_zop_CreateSetupD(NULL, kJanela, vDSP_DFT_FORWARD);
    for (int n = 0; n < kJanela; ++n) m->janela[n] = 0.5 - 0.5 * cos(2.0 * M_PI * n / kJanela);   // Hann periódica
    m->alargado = malloc((kTramasDoExcerto + kJanela) * sizeof(double));
    return m;
}

// mono: 480000 amostras. mel: kQuadros × kBandas, por quadros (como o modelo quer).
static void ZPMelCalcular(ZPMel *m, const float *mono, float *mel) {
    const int margem = kJanela / 2;
    double *x = m->alargado;
    for (int i = 0; i < kTramasDoExcerto; ++i) x[margem + i] = mono[i];
    for (int i = 0; i < margem; ++i) {
        x[i] = mono[margem - i];                                               // reflexo, sem repetir a ponta
        x[margem + kTramasDoExcerto + i] = mono[kTramasDoExcerto - 2 - i];
    }
    memset(m->im, 0, sizeof(m->im));
    for (int q = 0; q < kQuadros; ++q) {
        const double *quadro = x + (size_t)q * kSalto;
        vDSP_vmulD(quadro, 1, m->janela, 1, m->re, 1, kJanela);
        vDSP_DFT_ExecuteD(m->dft, m->re, m->im, m->reS, m->imS);
        for (int k = 0; k < kBins; ++k) m->potencia[k] = m->reS[k] * m->reS[k] + m->imS[k] * m->imS[k];
        const double *pesos = kMelPesos;
        for (int b = 0; b < kBandas; ++b) {
            double soma = 0.0;
            vDSP_dotprD(m->potencia + kMelInicio[b], 1, pesos, 1, &soma, kMelLargura[b]);
            pesos += kMelLargura[b];
            mel[q * kBandas + b] = (float)(10.0 * log10(MAX(soma, 1e-10)));
        }
    }
}

#pragma mark - Modelo

static MLModel *ZPCarregarModelo(NSString *caminho, BOOL soCPU) {
    MLModelConfiguration *config = [MLModelConfiguration new];
    config.computeUnits = soCPU ? MLComputeUnitsCPUOnly : MLComputeUnitsCPUAndNeuralEngine;
    NSError *erro = nil;
    MLModel *modelo = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:caminho] configuration:config error:&erro];
    if (!modelo) fprintf(stderr, "Não consegui carregar o modelo «%s»: %s\n", caminho.UTF8String, erro.localizedDescription.UTF8String);
    return modelo;
}

// mel (kQuadros × kBandas) -> vector (kDimensao), já normalizado pelo modelo.
static BOOL ZPVectorDoMel(MLModel *modelo, const float *mel, float *vector) {
    NSError *erro = nil;
    MLMultiArray *entrada = [[MLMultiArray alloc] initWithShape:@[@1, @1, @(kQuadros), @(kBandas)]
                                                       dataType:MLMultiArrayDataTypeFloat16 error:&erro];
    if (!entrada) return NO;
    [entrada getMutableBytesWithHandler:^(void *bytes, NSInteger tamanho, NSArray<NSNumber *> *passos) {
        _Float16 *destino = bytes;
        for (int i = 0; i < kQuadros * kBandas; ++i) destino[i] = (_Float16)mel[i];
    }];
    MLDictionaryFeatureProvider *dados = [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{@"mel": entrada} error:&erro];
    id<MLFeatureProvider> saida = dados ? [modelo predictionFromFeatures:dados error:&erro] : nil;
    MLMultiArray *v = [saida featureValueForName:@"vector"].multiArrayValue;
    if (!v || v.count != kDimensao) {
        fprintf(stderr, "O modelo falhou: %s\n", erro.localizedDescription.UTF8String ?: "saída inesperada");
        return NO;
    }
    for (int i = 0; i < kDimensao; ++i) vector[i] = v[i].floatValue;
    return YES;
}

static void ZPNormalizar(float *v) {
    float norma = 0.0f;
    vDSP_svesq(v, 1, &norma, kDimensao);
    norma = sqrtf(norma);
    if (norma > 0.0f) vDSP_vsdiv(v, 1, &norma, v, 1, kDimensao);
}

#pragma mark - Uma faixa

typedef struct { double ler, mel, modelo; } ZPTempos;

// A semente de uma estação que a base não conhece (nunca uma assinatura que se
// vá guardar): pode ser o excerto de 30 s de uma loja.
static BOOL gSementeSolta = NO;

// O vector da faixa. «duracao» <= 0: usa a do ficheiro.
static BOOL ZPVectorDaFaixa(MLModel *modelo, ZPMel *melador, NSString *caminho, double duracao,
                            float *vector, ZPTempos *tempos) {
    static float *mono = NULL, *mel = NULL;
    if (!mono) {
        mono = malloc(kTramasDoExcerto * sizeof(float));
        mel = malloc(kQuadros * kBandas * sizeof(float));
    }
    ExtAudioFileRef ficheiro = NULL;
    if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:caminho], &ficheiro) != noErr) return NO;
    AudioStreamBasicDescription doFicheiro = {0};
    UInt32 tamanho = sizeof(doFicheiro);
    OSStatus s = ExtAudioFileGetProperty(ficheiro, kExtAudioFileProperty_FileDataFormat, &tamanho, &doFicheiro);
    UInt32 canais = MAX(doFicheiro.mChannelsPerFrame, 1u);
    AudioStreamBasicDescription cliente = {
        .mSampleRate = kFrequencia, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 4 * canais, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * canais,
        .mChannelsPerFrame = canais, .mBitsPerChannel = 32,
    };
    if (s == noErr) s = ExtAudioFileSetProperty(ficheiro, kExtAudioFileProperty_ClientDataFormat, sizeof(cliente), &cliente);
    if (s == noErr && duracao <= 0.0) {
        SInt64 tramas = 0;
        tamanho = sizeof(tramas);
        if (ExtAudioFileGetProperty(ficheiro, kExtAudioFileProperty_FileLengthFrames, &tamanho, &tramas) == noErr
            && doFicheiro.mSampleRate > 0) duracao = (double)tramas / doFicheiro.mSampleRate;
    }
    if (s != noErr) { ExtAudioFileDispose(ficheiro); return NO; }

    double inicios[15] = { 0.0 };
    int quantos = 1;
    if (gSementeSolta && duracao >= 20.0 && duracao <= 31.0) {
        // O excerto de 30 s de uma loja: três janelas que o cobrem todo. Com uma
        // só, no início, a «Casta diva» dava vizinhas orquestrais (a introdução).
        quantos = 3;
        inicios[1] = (duracao - 10.0) / 2.0;
        inicios[2] = duracao - 10.0;
    } else if (duracao > 30.0) {
        // Um plano que parte os intervalos ao meio: os quartos (25, 50, 75 %),
        // depois os oitavos ímpares, depois os dezasseis-avos ímpares. As três
        // primeiras janelas são as do esboço; as outras só as lê o «refinar».
        quantos = 0;
        for (int den = 4; den <= 16 && quantos < gJanelas; den *= 2)
            for (int num = 1; num < den && quantos < gJanelas; num += (den == 4 ? 1 : 2))
                inicios[quantos++] = MIN(MAX(duracao * num / den - 5.0, 0.0), duracao - 10.0);
    }

    float soma[kDimensao] = {0}, um[kDimensao];
    int validos = 0;
    for (int i = 0; i < quantos; ++i) {
        double t0 = ZPAgora();
        UInt32 lidas = ZPLerExcerto(ficheiro, &doFicheiro, inicios[i], mono);
        double t1 = ZPAgora();
        tempos->ler += t1 - t0;
        if (lidas < kFrequencia) continue;
        ZPRepetirEEncher(mono, lidas);
        ZPMelCalcular(melador, mono, mel);
        double t2 = ZPAgora();
        tempos->mel += t2 - t1;
        BOOL ok = ZPVectorDoMel(modelo, mel, um);
        tempos->modelo += ZPAgora() - t2;
        if (!ok) continue;
        ZPNormalizar(um);
        vDSP_vadd(soma, 1, um, 1, soma, 1, kDimensao);
        ++validos;
    }
    ExtAudioFileDispose(ficheiro);
    if (validos == 0) return NO;
    ZPNormalizar(soma);
    memcpy(vector, soma, sizeof(soma));
    return YES;
}

#pragma mark - Modos

static int ZPModoLista(MLModel *modelo, NSString *lista, NSString *saida) {
    NSString *texto = [NSString stringWithContentsOfFile:lista encoding:NSUTF8StringEncoding error:NULL];
    if (!texto) { fprintf(stderr, "Não consegui ler «%s».\n", lista.UTF8String); return 1; }
    NSString *caminhoIds = [saida stringByAppendingString:@".ids"];
    NSString *caminhoVectores = [saida stringByAppendingString:@".f32"];

    // O que já está feito. Se os dois ficheiros não baterem certo (o programa
    // foi abaixo a meio de uma escrita), corta-se pelo mais curto.
    NSMutableSet<NSString *> *feitos = [NSMutableSet set];
    NSString *idsAntigos = [NSString stringWithContentsOfFile:caminhoIds encoding:NSUTF8StringEncoding error:NULL];
    NSArray<NSString *> *linhasAntigas = idsAntigos.length ? [idsAntigos componentsSeparatedByString:@"\n"] : @[];
    NSUInteger completos = 0;
    for (NSString *l in linhasAntigas) if (l.length) ++completos;
    unsigned long long bytes = [[NSFileManager defaultManager] attributesOfItemAtPath:caminhoVectores error:NULL].fileSize;
    NSUInteger vectoresCompletos = (NSUInteger)(bytes / (kDimensao * sizeof(float)));
    NSUInteger validos = MIN(completos, vectoresCompletos);
    if (completos != vectoresCompletos || bytes % (kDimensao * sizeof(float)) != 0) {
        fprintf(stderr, "Saída desacertada (%lu ids, %lu vectores): fico com os primeiros %lu.\n",
                (unsigned long)completos, (unsigned long)vectoresCompletos, (unsigned long)validos);
        truncate(caminhoVectores.fileSystemRepresentation, (off_t)validos * kDimensao * sizeof(float));
        NSMutableString *novo = [NSMutableString string];
        NSUInteger n = 0;
        for (NSString *l in linhasAntigas) { if (!l.length) continue; if (n++ >= validos) break; [novo appendFormat:@"%@\n", l]; }
        [novo writeToFile:caminhoIds atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        linhasAntigas = [novo componentsSeparatedByString:@"\n"];
    }
    for (NSString *l in linhasAntigas) if (l.length) [feitos addObject:l];

    FILE *fIds = fopen(caminhoIds.fileSystemRepresentation, "a");
    FILE *fVec = fopen(caminhoVectores.fileSystemRepresentation, "ab");
    if (!fIds || !fVec) { fprintf(stderr, "Não consegui abrir a saída «%s».\n", saida.UTF8String); return 1; }

    ZPMel *melador = ZPMelCriar();
    NSArray<NSString *> *linhas = [texto componentsSeparatedByString:@"\n"];
    ZPTempos tempos = {0};
    double t0 = ZPAgora();
    NSUInteger novas = 0, falhas = 0, total = 0;
    for (NSString *linha in linhas) if (linha.length) ++total;
    NSUInteger n = 0;
    for (NSString *linha in linhas) {
        if (!linha.length) continue;
        ++n;
        @autoreleasepool {
            NSArray<NSString *> *campos = [linha componentsSeparatedByString:@"\t"];
            if (campos.count < 3) { fprintf(stderr, "Linha %lu sem três campos.\n", (unsigned long)n); ++falhas; continue; }
            NSString *mid = campos[0];
            if ([feitos containsObject:mid]) continue;
            float vector[kDimensao];
            if (!ZPVectorDaFaixa(modelo, melador, campos[2], campos[1].doubleValue, vector, &tempos)) {
                fprintf(stderr, "  sem som: %s\n", campos[2].UTF8String);
                ++falhas;
                continue;
            }
            fwrite(vector, sizeof(float), kDimensao, fVec);
            fflush(fVec);
            fprintf(fIds, "%s\n", mid.UTF8String);
            fflush(fIds);
            ++novas;
            if (novas % 500 == 0) {
                printf("%lu/%lu  %.0f s  (ler %.0f s, mel %.0f s, modelo %.0f s)\n", (unsigned long)n, (unsigned long)total,
                       ZPAgora() - t0, tempos.ler, tempos.mel, tempos.modelo);
                fflush(stdout);
            }
        }
    }
    fclose(fIds);
    fclose(fVec);
    printf("feito: %lu novas em %.0f s (ler %.0f s, mel %.0f s, modelo %.0f s); %lu falhas; total %lu\n",
           (unsigned long)novas, ZPAgora() - t0, tempos.ler, tempos.mel, tempos.modelo,
           (unsigned long)falhas, (unsigned long)(feitos.count + novas));
    return 0;
}

static NSData *ZPLerFloats(NSString *caminho, NSUInteger quantos) {
    NSData *d = [NSData dataWithContentsOfFile:caminho];
    if (d.length != quantos * sizeof(float)) {
        fprintf(stderr, "«%s» devia ter %lu float32 e tem %lu bytes.\n", caminho.UTF8String,
                (unsigned long)quantos, (unsigned long)d.length);
        return nil;
    }
    return d;
}

#pragma mark - Base da fonoteca

// O ficheiro de que se tira a assinatura de uma música (m): o FLAC, havendo-o.
// É a mesma escolha da vista «fonoteca».
#define kFicheiroPreferido "(SELECT f2.id FROM ficheiros f2 WHERE f2.musica = m.id AND f2.caminho IS NOT NULL" \
                           " ORDER BY f2.formato <> 'flac', f2.caminho LIMIT 1)"

static sqlite3 *ZPAbrirBase(NSString *caminho) {
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(caminho.fileSystemRepresentation, &db, SQLITE_OPEN_READWRITE, NULL) != SQLITE_OK) {
        fprintf(stderr, "Não consegui abrir a base «%s»: %s\n", caminho.UTF8String, db ? sqlite3_errmsg(db) : "sem memória");
        sqlite3_close(db);
        return NULL;
    }
    // O tocaTintas e o fonoteca.py têm a base aberta ao mesmo tempo (WAL).
    sqlite3_busy_timeout(db, 60000);
    char *erro = NULL;
    const char *esquema =
        "PRAGMA foreign_keys = ON;"
        "CREATE TABLE IF NOT EXISTS assinaturas ("
        "    musica       TEXT NOT NULL REFERENCES musicas(id) ON DELETE CASCADE,"
        "    modelo       TEXT NOT NULL,"              // modelo e maneira de tirar os excertos
        "    md5_audio    TEXT NOT NULL,"              // o áudio de que se calculou (ficheiros.md5_audio)
        "    vector       BLOB NOT NULL,"              // 512 float16, norma 1
        "    calculada_em TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ','now')),"
        "    PRIMARY KEY (musica, modelo)"
        ");";
    if (sqlite3_exec(db, esquema, NULL, NULL, &erro) != SQLITE_OK) {
        fprintf(stderr, "Não consegui preparar a tabela das assinaturas: %s\n", erro ?: "?");
        sqlite3_free(erro);
        sqlite3_close(db);
        return NULL;
    }
    return db;
}

static NSString *ZPTexto(sqlite3_stmt *s, int coluna) {
    const unsigned char *t = sqlite3_column_text(s, coluna);
    return t ? @((const char *)t) : @"";
}

// Na base os vectores vão em float16, que é a precisão com que o modelo os dá:
// 1024 bytes em vez de 2048. Com 2048 só cabia uma assinatura por página de
// 4096 (80 MB para 19 682 músicas); assim cabem três.
enum { kBytesDaAssinatura = kDimensao * sizeof(_Float16) };

static void ZPAssinaturaParaVector(const void *blob, float *vector) {
    const _Float16 *meio = blob;
    for (int i = 0; i < kDimensao; ++i) vector[i] = (float)meio[i];
}

static BOOL ZPGuardarAssinaturaCom(sqlite3 *db, NSString *musica, NSString *md5, const float *vector, const char *modelo);
static BOOL ZPGuardarAssinatura(sqlite3 *db, NSString *musica, NSString *md5, const float *vector) {
    return ZPGuardarAssinaturaCom(db, musica, md5, vector, kModelo);
}

static BOOL ZPGuardarAssinaturaCom(sqlite3 *db, NSString *musica, NSString *md5, const float *vector, const char *modelo) {
    _Float16 meio[kDimensao];
    for (int i = 0; i < kDimensao; ++i) meio[i] = (_Float16)vector[i];
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO assinaturas (musica, modelo, md5_audio, vector) VALUES (?, ?, ?, ?)",
                           -1, &s, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_text(s, 1, musica.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 2, modelo, -1, SQLITE_STATIC);
    sqlite3_bind_text(s, 3, md5.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_blob(s, 4, meio, kBytesDaAssinatura, SQLITE_TRANSIENT);
    BOOL ok = sqlite3_step(s) == SQLITE_DONE;
    if (!ok) fprintf(stderr, "Não consegui guardar a assinatura de %s: %s\n", musica.UTF8String, sqlite3_errmsg(db));
    sqlite3_finalize(s);
    return ok;
}

// O modelo só se carrega quando faz falta: uma estação cuja semente já tem
// assinatura não precisa dele, e carregá-lo custa mais do que a estação.
static NSString *gModeloCaminho = nil;
static BOOL gSoCPU = NO;
static MLModel *ZPModeloQuandoPreciso(void) {
    static MLModel *modelo = nil;
    if (!modelo) modelo = ZPCarregarModelo(gModeloCaminho, gSoCPU);
    return modelo;
}

#pragma mark Actualizar

static int ZPModoActualizar(NSString *base) {
    sqlite3 *db = ZPAbrirBase(base);
    if (!db) return 1;
    // Primeiro a lista toda, para não ficar com uma leitura aberta durante os cálculos.
    NSMutableArray<NSArray *> *porFazer = [NSMutableArray array];
    sqlite3_stmt *s = NULL;
    const char *sql =
        "SELECT m.id, COALESCE(m.duracao, 0), f.caminho, f.md5_audio"
        "  FROM musicas m JOIN ficheiros f ON f.id = " kFicheiroPreferido
        "  LEFT JOIN assinaturas a ON a.musica = m.id AND a.modelo = ?"
        " WHERE a.musica IS NULL OR a.md5_audio <> f.md5_audio"
        " ORDER BY f.caminho";
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) {
        fprintf(stderr, "%s\n", sqlite3_errmsg(db)); sqlite3_close(db); return 1;
    }
    sqlite3_bind_text(s, 1, kModelo, -1, SQLITE_STATIC);
    while (sqlite3_step(s) == SQLITE_ROW) {
        [porFazer addObject:@[ZPTexto(s, 0), @(sqlite3_column_double(s, 1)), ZPTexto(s, 2), ZPTexto(s, 3)]];
    }
    sqlite3_finalize(s);
    if (porFazer.count == 0) { printf("nada por fazer\n"); sqlite3_close(db); return 0; }

    MLModel *modelo = ZPModeloQuandoPreciso();
    if (!modelo) { sqlite3_close(db); return 1; }
    ZPMel *melador = ZPMelCriar();
    ZPTempos tempos = {0};
    double t0 = ZPAgora();
    NSUInteger novas = 0, falhas = 0, n = 0;
    for (NSArray *faixa in porFazer) {
        ++n;
        @autoreleasepool {
            float vector[kDimensao];
            if (!ZPVectorDaFaixa(modelo, melador, faixa[2], [faixa[1] doubleValue], vector, &tempos)) {
                fprintf(stderr, "  sem som: %s\n", [faixa[2] UTF8String]);
                ++falhas;
                continue;
            }
            if (ZPGuardarAssinatura(db, faixa[0], faixa[3], vector)) ++novas; else ++falhas;
            // O ficheiro mudou: a assinatura fina que houvesse era do antigo.
            sqlite3_stmt *velha = NULL;
            if (sqlite3_prepare_v2(db, "DELETE FROM assinaturas WHERE musica = ? AND modelo = ? AND md5_audio <> ?", -1, &velha, NULL) == SQLITE_OK) {
                sqlite3_bind_text(velha, 1, [faixa[0] UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_bind_text(velha, 2, kModeloFino, -1, SQLITE_STATIC);
                sqlite3_bind_text(velha, 3, [faixa[3] UTF8String], -1, SQLITE_TRANSIENT);
                sqlite3_step(velha);
            }
            sqlite3_finalize(velha);
            if (novas % 500 == 0) {
                printf("%lu/%lu  %.0f s  (ler %.0f s, mel %.0f s, modelo %.0f s)\n", (unsigned long)n,
                       (unsigned long)porFazer.count, ZPAgora() - t0, tempos.ler, tempos.mel, tempos.modelo);
                fflush(stdout);
            }
        }
    }
    printf("feito: %lu novas em %.0f s (ler %.0f s, mel %.0f s, modelo %.0f s); %lu falhas\n",
           (unsigned long)novas, ZPAgora() - t0, tempos.ler, tempos.mel, tempos.modelo, (unsigned long)falhas);
    sqlite3_close(db);
    return falhas ? 1 : 0;
}

#pragma mark Refinar

// Passa esboços a assinaturas finas, durante «minutos» no máximo (0: até ao
// fim). É trabalho de fundo: o processo pede ao sistema a prioridade mínima de
// processador e de disco, e cede a quem estiver a tocar. Primeiro as músicas
// mais ouvidas. Cada assinatura é guardada mal fica pronta, por isso pode ser
// interrompido em qualquer altura.
static int ZPModoRefinar(NSString *base, double minutos) {
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
    sqlite3 *db = ZPAbrirBase(base);
    if (!db) return 1;
    NSMutableArray<NSArray *> *porFazer = [NSMutableArray array];
    sqlite3_stmt *s = NULL;
    const char *sql =
        "SELECT m.id, COALESCE(m.duracao, 0), f.caminho, f.md5_audio"
        "  FROM musicas m JOIN ficheiros f ON f.id = " kFicheiroPreferido
        "  LEFT JOIN assinaturas a ON a.musica = m.id AND a.modelo = ?"
        " WHERE a.musica IS NULL OR a.md5_audio <> f.md5_audio"
        " ORDER BY (SELECT COUNT(*) FROM audicoes o WHERE o.musica = m.id) DESC, f.caminho";
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) {
        fprintf(stderr, "%s\n", sqlite3_errmsg(db)); sqlite3_close(db); return 1;
    }
    sqlite3_bind_text(s, 1, kModeloFino, -1, SQLITE_STATIC);
    while (sqlite3_step(s) == SQLITE_ROW) {
        [porFazer addObject:@[ZPTexto(s, 0), @(sqlite3_column_double(s, 1)), ZPTexto(s, 2), ZPTexto(s, 3)]];
    }
    sqlite3_finalize(s);
    if (porFazer.count == 0) { printf("nada por refinar\n"); sqlite3_close(db); return 0; }

    MLModel *modelo = ZPModeloQuandoPreciso();
    if (!modelo) { sqlite3_close(db); return 1; }
    ZPMel *melador = ZPMelCriar();
    ZPTempos tempos = {0};
    gJanelas = 15;
    double t0 = ZPAgora();
    NSUInteger novas = 0, falhas = 0;
    for (NSArray *faixa in porFazer) {
        if (minutos > 0.0 && ZPAgora() - t0 > minutos * 60.0) break;
        @autoreleasepool {
            float vector[kDimensao];
            if (!ZPVectorDaFaixa(modelo, melador, faixa[2], [faixa[1] doubleValue], vector, &tempos)) { ++falhas; continue; }
            if (ZPGuardarAssinaturaCom(db, faixa[0], faixa[3], vector, kModeloFino)) ++novas; else ++falhas;
        }
    }
    printf("refinadas: %lu de %lu em %.0f s (ler %.0f s, mel %.0f s, modelo %.0f s); %lu falhas\n", (unsigned long)novas,
           (unsigned long)porFazer.count, ZPAgora() - t0, tempos.ler, tempos.mel, tempos.modelo, (unsigned long)falhas);
    sqlite3_close(db);
    return 0;
}

#pragma mark Importar

// Os vectores do ensaio (saída.f32 + saída.ids, feitos a partir de lista.tsv)
// passam para a base sem se voltar a ler o disco. O md5 é o do ficheiro que a
// lista dizia; uma faixa que a base já não conheça por esse caminho fica de fora
// e o «actualizar» trata dela.
static int ZPModoImportar(NSString *base, NSString *lista, NSString *saida) {
    NSString *texto = [NSString stringWithContentsOfFile:lista encoding:NSUTF8StringEncoding error:NULL];
    NSString *ids = [NSString stringWithContentsOfFile:[saida stringByAppendingString:@".ids"] encoding:NSUTF8StringEncoding error:NULL];
    NSData *vectores = [NSData dataWithContentsOfFile:[saida stringByAppendingString:@".f32"]];
    if (!texto || !ids || !vectores) { fprintf(stderr, "Não consegui ler a lista ou a saída.\n"); return 1; }
    NSMutableDictionary<NSString *, NSString *> *caminhos = [NSMutableDictionary dictionary];
    for (NSString *linha in [texto componentsSeparatedByString:@"\n"]) {
        NSArray<NSString *> *campos = [linha componentsSeparatedByString:@"\t"];
        if (campos.count >= 3) caminhos[campos[0]] = campos[2].precomposedStringWithCanonicalMapping;
    }
    NSMutableArray<NSString *> *ordem = [NSMutableArray array];
    for (NSString *l in [ids componentsSeparatedByString:@"\n"]) if (l.length) [ordem addObject:l];
    if (vectores.length != ordem.count * kDimensao * sizeof(float)) {
        fprintf(stderr, "A saída não bate certo: %lu ids e %lu bytes.\n", (unsigned long)ordem.count, (unsigned long)vectores.length);
        return 1;
    }
    sqlite3 *db = ZPAbrirBase(base);
    if (!db) return 1;
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "SELECT md5_audio FROM ficheiros WHERE musica = ? AND caminho = ?", -1, &s, NULL) != SQLITE_OK
        || sqlite3_exec(db, "BEGIN IMMEDIATE", NULL, NULL, NULL) != SQLITE_OK) {
        fprintf(stderr, "%s\n", sqlite3_errmsg(db)); sqlite3_close(db); return 1;
    }
    const float *v = vectores.bytes;
    NSUInteger postas = 0, fora = 0;
    BOOL ok = YES;
    for (NSUInteger i = 0; i < ordem.count && ok; ++i) {
        NSString *mid = ordem[i], *caminho = caminhos[mid];
        NSString *md5 = nil;
        if (caminho) {
            sqlite3_reset(s);
            sqlite3_bind_text(s, 1, mid.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 2, caminho.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(s) == SQLITE_ROW) md5 = ZPTexto(s, 0);
            sqlite3_reset(s);
        }
        if (!md5.length) { ++fora; continue; }
        ok = ZPGuardarAssinatura(db, mid, md5, v + i * kDimensao);
        if (ok) ++postas;
    }
    sqlite3_finalize(s);
    sqlite3_exec(db, ok ? "COMMIT" : "ROLLBACK", NULL, NULL, NULL);
    sqlite3_close(db);
    if (!ok) { fprintf(stderr, "Nada ficou na base.\n"); return 1; }
    printf("importadas: %lu; de fora (a base já não as conhece por esse caminho): %lu\n", (unsigned long)postas, (unsigned long)fora);
    return 0;
}

#pragma mark Estação

// O título sem o que distingue versões da mesma canção: maiúsculas, acentos, o
// que vem entre parênteses e o « - Remastered 2009» do fim.
static NSString *ZPChaveDoTitulo(NSString *titulo) {
    NSMutableString *t = [[titulo stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                                      locale:nil] mutableCopy];
    [t replaceOccurrencesOfString:@"[\\(\\[].*?[\\)\\]]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    [t replaceOccurrencesOfString:@"\\s+-\\s+.*$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    [t replaceOccurrencesOfString:@"[^\\p{L}\\p{N}]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    return t;
}

// Nas eruditas o artista é «Compositor; Intérpretes»: conta o compositor. Numa
// colectânea («Vários») o artista não diz nada, e conta o álbum.
static NSString *ZPChaveDoArtista(NSString *artista, NSString *album) {
    NSString *a = [[artista componentsSeparatedByString:@";"].firstObject
                   stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    a = [a stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
    if (a.length == 0 || [@[@"varios", @"various", @"various artists", @"varios artistas"] containsObject:a]) {
        return [@"álbum:" stringByAppendingString:album.lowercaseString];
    }
    return a;
}

static BOOL ZPPareceUUID(NSString *s) {
    return s.length == 36 && [[NSUUID alloc] initWithUUIDString:s] != nil;
}

// O mapa do catálogo (--mapa): um SQLite à parte da fonoteca, com as faixas da
// biblioteca do Música que não têm ficheiro local, assinadas pelo excerto de
// 30 s da loja. Entram na estação como «musica:<persistent ID>», que é o que o
// Música sabe tocar. A semente também pode ser uma delas.
static NSString *gMapa = nil;
static const char * const kModeloDoExcerto = "larger_clap_general/excerto-3x10s";

static sqlite3 *ZPAbrirMapa(void) {
    sqlite3 *mapa = NULL;
    if (!gMapa.length) return NULL;
    if (sqlite3_open_v2(gMapa.fileSystemRepresentation, &mapa, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
        fprintf(stderr, "Não consegui abrir o mapa «%s»; sigo sem ele.\n", gMapa.UTF8String);
        sqlite3_close(mapa);
        return NULL;
    }
    sqlite3_busy_timeout(mapa, 5000);
    return mapa;
}

static float gAncora = 0.08f;   // --ancora: quanto sobe, na semelhança, uma faixa do artista mais vizinho da semente (0 = só o som)
static NSMutableArray<NSString *> *gRumos;   // --rumo: faixas que quem ouve puxou para cima; a estação aproxima-se delas
static NSMutableArray<NSString *> *gLonges;  // --longe: faixas que desmarcou; a estação afasta-se delas
static NSString *gSem;                       // --sem: ficheiro com as faixas que já tocaram, uma por linha, para não voltarem
static NSString *gInfo;                      // --info: onde escrever, para cada linha da estação, artista, título, álbum e semelhança
static NSUInteger gOndas = 5;   // --ondas: em quantas voltas à semente se reparte a estação (1 = por ordem de semelhança)

static int ZPModoEstacao(NSString *base, NSString *semente, NSUInteger quantas, NSUInteger porArtista, NSUInteger porAlbum) {
    sqlite3 *db = ZPAbrirBase(base);
    if (!db) return 1;
    BOOL sementeDoMusica = [semente hasPrefix:@"musica:"];

    // Quem é a semente: uma música da fonoteca (pelo UUID ou pelo caminho de um
    // dos seus ficheiros) ou um ficheiro qualquer, que a base não conhece.
    NSString *musica = nil, *caminhoDaSemente = nil, *md5 = nil;
    double duracao = 0.0;
    sqlite3_stmt *s = NULL;
    if (ZPPareceUUID(semente)) {
        if (sqlite3_prepare_v2(db, "SELECT m.id, f.caminho, f.md5_audio, COALESCE(m.duracao, 0) FROM musicas m"
                                   " JOIN ficheiros f ON f.id = " kFicheiroPreferido " WHERE m.id = ?", -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s, 1, semente.lowercaseString.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(s) == SQLITE_ROW) {
                musica = ZPTexto(s, 0); caminhoDaSemente = ZPTexto(s, 1); md5 = ZPTexto(s, 2); duracao = sqlite3_column_double(s, 3);
            }
        }
        sqlite3_finalize(s);
        if (!musica) { fprintf(stderr, "A fonoteca não tem ficheiro para a música %s.\n", semente.UTF8String); sqlite3_close(db); return 3; }
    } else if (sementeDoMusica) {
        caminhoDaSemente = semente;
    } else {
        caminhoDaSemente = semente.stringByStandardizingPath;
        if (sqlite3_prepare_v2(db, "SELECT f.musica, f.md5_audio, COALESCE(m.duracao, 0) FROM ficheiros f"
                                   " JOIN musicas m ON m.id = f.musica WHERE f.caminho = ?", -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s, 1, caminhoDaSemente.precomposedStringWithCanonicalMapping.UTF8String, -1, SQLITE_TRANSIENT);
            if (sqlite3_step(s) == SQLITE_ROW) { musica = ZPTexto(s, 0); md5 = ZPTexto(s, 1); duracao = sqlite3_column_double(s, 2); }
        }
        sqlite3_finalize(s);
    }

    // A assinatura da semente: a da base, ou calculada agora.
    float alvo[kDimensao];
    BOOL temAlvo = NO;
    if (musica) {
        if (sqlite3_prepare_v2(db, "SELECT vector FROM assinaturas WHERE musica = ?1 AND modelo IN (?2, ?3)"
                                   " ORDER BY modelo = ?3 DESC LIMIT 1", -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s, 1, musica.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 2, kModelo, -1, SQLITE_STATIC);
            sqlite3_bind_text(s, 3, kModeloFino, -1, SQLITE_STATIC);
            if (sqlite3_step(s) == SQLITE_ROW && sqlite3_column_bytes(s, 0) == kBytesDaAssinatura) {
                ZPAssinaturaParaVector(sqlite3_column_blob(s, 0), alvo);
                temAlvo = YES;
            }
        }
        sqlite3_finalize(s);
    }
    if (sementeDoMusica) {
        sqlite3 *mapa = ZPAbrirMapa();
        if (mapa && sqlite3_prepare_v2(mapa, "SELECT a.vector FROM assinaturas a JOIN faixas f ON f.id = a.faixa"
                                             " WHERE f.pid = ? AND a.modelo = ?", -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s, 1, [semente substringFromIndex:7].UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 2, kModeloDoExcerto, -1, SQLITE_STATIC);
            if (sqlite3_step(s) == SQLITE_ROW && sqlite3_column_bytes(s, 0) == kBytesDaAssinatura) {
                ZPAssinaturaParaVector(sqlite3_column_blob(s, 0), alvo);
                temAlvo = YES;
            }
            sqlite3_finalize(s);
        }
        sqlite3_close(mapa);
        if (!temAlvo) { fprintf(stderr, "O mapa não tem assinatura para «%s».\n", semente.UTF8String); sqlite3_close(db); return 3; }
    }
    if (!temAlvo) {
        gSementeSolta = (musica == nil);
        if (gSementeSolta) duracao = 0.0;   // a do ficheiro
        MLModel *modelo = ZPModeloQuandoPreciso();
        ZPTempos tempos = {0};
        if (!modelo || !ZPVectorDaFaixa(modelo, ZPMelCriar(), caminhoDaSemente, duracao, alvo, &tempos)) {
            fprintf(stderr, "Não consegui tirar a assinatura de «%s».\n", caminhoDaSemente.UTF8String);
            sqlite3_close(db);
            return 3;
        }
        if (musica && md5.length) ZPGuardarAssinatura(db, musica, md5, alvo);
    }

    // Todas as assinaturas, com o que as regras precisam de saber de cada música.
    NSMutableData *vectores = [NSMutableData data];
    NSMutableArray<NSArray<NSString *> *> *faixas = [NSMutableArray array];   // id, artista, álbum, título, caminho
    const char *sql = "SELECT a.musica, a.vector, m.artista, m.album, m.titulo, f.caminho"
                      "  FROM assinaturas a JOIN musicas m ON m.id = a.musica JOIN ficheiros f ON f.id = " kFicheiroPreferido
                      // De cada música a assinatura fina, se já a tiver; senão o esboço.
                      " WHERE a.modelo = ?2 OR (a.modelo = ?1 AND NOT EXISTS"
                      "       (SELECT 1 FROM assinaturas b WHERE b.musica = a.musica AND b.modelo = ?2))";
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { fprintf(stderr, "%s\n", sqlite3_errmsg(db)); sqlite3_close(db); return 1; }
    sqlite3_bind_text(s, 1, kModelo, -1, SQLITE_STATIC);
    sqlite3_bind_text(s, 2, kModeloFino, -1, SQLITE_STATIC);
    while (sqlite3_step(s) == SQLITE_ROW) {
        if (sqlite3_column_bytes(s, 1) != kBytesDaAssinatura) continue;
        float um[kDimensao];
        ZPAssinaturaParaVector(sqlite3_column_blob(s, 1), um);
        [vectores appendBytes:um length:sizeof(um)];
        [faixas addObject:@[ZPTexto(s, 0), ZPTexto(s, 2), ZPTexto(s, 3), ZPTexto(s, 4), ZPTexto(s, 5)]];
    }
    sqlite3_finalize(s);
    sqlite3_close(db);

    // As do mapa, na mesma lista: o «caminho» delas é «musica:<pid>».
    sqlite3 *mapa = ZPAbrirMapa();
    if (mapa && sqlite3_prepare_v2(mapa, "SELECT f.pid, a.vector, f.artista, f.album, f.titulo FROM assinaturas a"
                                         " JOIN faixas f ON f.id = a.faixa WHERE f.pid IS NOT NULL AND a.modelo = ?", -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_text(s, 1, kModeloDoExcerto, -1, SQLITE_STATIC);
        while (sqlite3_step(s) == SQLITE_ROW) {
            if (sqlite3_column_bytes(s, 1) != kBytesDaAssinatura) continue;
            float um[kDimensao];
            ZPAssinaturaParaVector(sqlite3_column_blob(s, 1), um);
            [vectores appendBytes:um length:sizeof(um)];
            // «musica:<pid>», e depois de uma tabulação o nome a mostrar.
            NSString *pid = [@"musica:" stringByAppendingString:ZPTexto(s, 0)];
            NSString *linha = [NSString stringWithFormat:@"%@\t%@ — %@", pid, ZPTexto(s, 2), ZPTexto(s, 4)];
            [faixas addObject:@[pid, ZPTexto(s, 2), ZPTexto(s, 3), ZPTexto(s, 4), linha]];
        }
        sqlite3_finalize(s);
    }
    NSUInteger n = faixas.count;
    if (n < 2) { sqlite3_close(mapa); fprintf(stderr, "A base não tem assinaturas: falta correr «vectorizar actualizar».\n"); return 4; }

    // A âncora: os artistas que a ListenBrainz dá como vizinhos do artista da
    // semente (quem ouve um ouve os outros), guardados no mapa pela consulta
    // externa. A assinatura só conhece o som; a vizinhança de ouvintes traz a
    // época e o país. Cada vizinho fica com um peso entre 0 e 1.
    NSMutableDictionary<NSString *, NSNumber *> *vizinhos = [NSMutableDictionary dictionary];
    if (mapa && gAncora > 0) {
        NSString *artistaDaSemente = nil;
        for (NSArray<NSString *> *f in faixas) {
            if ((musica && [f[0] isEqualToString:musica]) || [f[4] isEqualToString:caminhoDaSemente] || [f[0] isEqualToString:caminhoDaSemente]) {
                artistaDaSemente = ZPChaveDoArtista(f[1], f[2]);
                break;
            }
        }
        if (artistaDaSemente.length && sqlite3_prepare_v2(mapa, "SELECT v.nome, v.peso FROM vizinhos v JOIN artistas a ON a.mbid = v.artista"
                                                                " WHERE a.chave = ? AND v.peso > 0 ORDER BY v.peso DESC", -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s, 1, artistaDaSemente.UTF8String, -1, SQLITE_TRANSIENT);
            double maximo = 0;
            while (sqlite3_step(s) == SQLITE_ROW) {
                double peso = sqlite3_column_double(s, 1);
                if (maximo == 0) maximo = peso;
                NSString *chave = ZPChaveDoArtista(ZPTexto(s, 0), @"");
                if (chave.length && !vizinhos[chave]) vizinhos[chave] = @(sqrt(peso / maximo));
            }
            sqlite3_finalize(s);
        }
    }
    sqlite3_close(mapa);

    // O rumo: o que quem ouve fez na janela «A seguir». As faixas que puxou
    // para cima (--rumo) aproximam o alvo de si, as que desmarcou (--longe)
    // afastam-no, estas com metade do peso: afastar do som de uma faixa leva
    // consigo outras que soam parecido e de que se pode gostar. Conta a média
    // de cada grupo, para a semente mandar sempre mais do que os gestos. As
    // desmarcadas não voltam a sair, tal como as do --sem (as que a estação já
    // tem); as promovidas saem se não estiverem no --sem, e saem cedo.
    NSMutableSet<NSString *> *fora = [NSMutableSet set];
    if (gSem.length) {
        NSString *texto = [NSString stringWithContentsOfFile:gSem encoding:NSUTF8StringEncoding error:NULL] ?: @"";
        for (NSString *linha in [texto componentsSeparatedByString:@"\n"]) if (linha.length) [fora addObject:linha.precomposedStringWithCanonicalMapping];
    }
    if (gRumos.count || gLonges.count) {
        const float *todos = vectores.bytes;
        float soma[kDimensao];
        memcpy(soma, alvo, sizeof(soma));
        NSArray<NSArray *> *grupos = @[@[gRumos ?: @[], @0.6f], @[gLonges ?: @[], @-0.3f]];
        for (NSArray *grupo in grupos) {
            float media[kDimensao] = {0};
            NSUInteger quantas = 0;
            for (NSString *faixa in (NSArray<NSString *> *)grupo[0]) {
                NSString *chave = faixa.precomposedStringWithCanonicalMapping;
                if ([grupo[1] floatValue] < 0) [fora addObject:chave];   // as desmarcadas não voltam; as promovidas podem
                for (NSUInteger i = 0; i < n; ++i) {
                    // Um ficheiro pelo caminho, uma faixa do Música pelo «musica:PID».
                    if ([faixas[i][0] isEqualToString:chave] || [faixas[i][4] isEqualToString:chave]
                        || [[faixas[i][4] componentsSeparatedByString:@"\t"].firstObject isEqualToString:chave]) {
                        vDSP_vadd(media, 1, todos + i * kDimensao, 1, media, 1, kDimensao);
                        ++quantas;
                        break;
                    }
                }
            }
            if (quantas == 0) continue;
            float peso = [grupo[1] floatValue] / (float)quantas;
            vDSP_vsma(media, 1, &peso, soma, 1, soma, 1, kDimensao);
        }
        float norma = 0;
        vDSP_svesq(soma, 1, &norma, kDimensao);
        norma = sqrtf(norma);
        if (norma > 0) vDSP_vsdiv(soma, 1, &norma, alvo, 1, kDimensao);
    }

    // Semelhança (co-seno: os vectores têm norma 1) e ordem decrescente.
    float *semelhanca = malloc(n * sizeof(float));
    vDSP_Length *ordem = malloc(n * sizeof(vDSP_Length));
    vDSP_mmul(vectores.bytes, 1, alvo, 1, semelhanca, 1, n, 1, kDimensao);
    for (NSUInteger i = 0; i < n; ++i) {
        ordem[i] = i;
        // Uma faixa de um artista vizinho sobe na ordem, tanto mais quanto mais vizinho.
        if (vizinhos.count) semelhanca[i] += gAncora * [vizinhos[ZPChaveDoArtista(faixas[i][1], faixas[i][2])] floatValue];
    }
    vDSP_vsorti(semelhanca, ordem, NULL, n, -1);

    // A semente vai à cabeça e conta para as regras. Se for da fonoteca, sabe-se
    // quem é; se não, só se evita repeti-la pelo caminho.
    NSMutableSet<NSString *> *titulos = [NSMutableSet set];
    NSCountedSet<NSString *> *artistas = [NSCountedSet set], *albuns = [NSCountedSet set];
    for (NSArray<NSString *> *f in faixas) {
        if ((musica && [f[0] isEqualToString:musica]) || [f[4] isEqualToString:caminhoDaSemente] || [f[0] isEqualToString:caminhoDaSemente]) {
            if (sementeDoMusica) caminhoDaSemente = f[4];   // com o nome, para quem lê a lista
            NSString *chave = ZPChaveDoTitulo(f[3]);
            if (chave.length) [titulos addObject:chave];
            [artistas addObject:ZPChaveDoArtista(f[1], f[2])];
            [albuns addObject:[NSString stringWithFormat:@"%@|%@", f[1], f[2]]];
            break;
        }
    }
    printf("%s\n", caminhoDaSemente.UTF8String);
    NSMutableArray<NSString *> *porOrdem = [NSMutableArray array];   // as escolhidas, da mais parecida à menos
    NSMutableString *info = [NSMutableString string];
    NSUInteger escolhidas = 1;
    for (NSUInteger k = 0; k < n && escolhidas < quantas; ++k) {
        NSArray<NSString *> *f = faixas[ordem[k]];
        if (musica && [f[0] isEqualToString:musica]) continue;
        if ([f[4] isEqualToString:caminhoDaSemente] || [f[0] isEqualToString:semente]) continue;
        if (fora.count && ([fora containsObject:f[0]] || [fora containsObject:f[4]])) continue;   // f[0] das do Música é «musica:PID»
        NSString *chave = ZPChaveDoTitulo(f[3]);
        if (chave.length && [titulos containsObject:chave]) continue;          // outra versão da mesma canção
        NSString *artista = ZPChaveDoArtista(f[1], f[2]);
        NSString *album = [NSString stringWithFormat:@"%@|%@", f[1], f[2]];
        if ([artistas countForObject:artista] >= porArtista) continue;
        if ([albuns countForObject:album] >= porAlbum) continue;
        if (chave.length) [titulos addObject:chave];
        [artistas addObject:artista];
        [albuns addObject:album];
        [porOrdem addObject:f[4]];
        // A chave é o que a linha tem antes da tabulação: o caminho ou «musica:PID».
        [info appendFormat:@"%@\t%@\t%@\t%@\t%.3f\n", [f[4] componentsSeparatedByString:@"\t"].firstObject, f[1], f[3], f[2], semelhanca[ordem[k]]];
        ++escolhidas;
    }
    // Tocadas por ordem de semelhança, as faixas iam-se afastando da semente e
    // nunca mais voltavam: a estação derivava. Por isso saem em ondas: cada
    // onda começa perto da semente e afasta-se, e a seguinte volta ao pé dela.
    // Com cinco ondas, a primeira leva a 1.ª, a 6.ª, a 11.ª… mais parecidas, a
    // segunda a 2.ª, a 7.ª, a 12.ª…
    NSUInteger ondas = MAX(MIN(gOndas, porOrdem.count), (NSUInteger)1);
    for (NSUInteger onda = 0; onda < ondas; ++onda) {
        for (NSUInteger k = onda; k < porOrdem.count; k += ondas) printf("%s\n", porOrdem[k].UTF8String);
    }
    if (gInfo.length) [info writeToFile:gInfo atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    free(semelhanca);
    free(ordem);
    return 0;
}

#pragma mark - Associar

// A consulta externa. A partir do artista da faixa que toca, pergunta-se à
// ListenBrainz (dados abertos, sem chave) que artistas ouve quem o ouve, e
// quais as gravações mais ouvidas desses; cada candidata procura-se na loja da
// Apple (iTunes Search API), que dá o excerto de 30 s; do excerto tira-se a
// assinatura, e a assinatura diz em que lugar a candidata ficaria entre as
// vizinhas da semente na fonoteca. Tudo o que se apura fica no mapa do
// catálogo, aprovado ou não: uma candidata fraca para esta semente pode servir
// a outra.
//
// Para fora vão só nomes de artistas e títulos. A loja aceita uns 20 pedidos por
// minuto, e é esse o passo estreito: uma passagem leva minuto e meio.

static NSString * const kAgente = @"tocaTintas-vectorizar/1.0";

// O «User token» da ListenBrainz, se o utilizador o guardou no Porta-chaves:
//     security add-generic-password -s tocaTintas-ListenBrainz -a token -w
// Lê-se pelo próprio «security», que é quem o lá pôs: o Porta-chaves não
// pergunta nada, e não volta a perguntar de cada vez que o vectorizar se
// recompila. nil se não houver. Nunca se escreve em registo nenhum.
static NSString *ZPTokenDaListenBrainz(void) {
    static NSString *token = nil;
    static dispatch_once_t uma;
    dispatch_once(&uma, ^{
        NSTask *t = [[NSTask alloc] init];
        t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/security"];
        t.arguments = @[@"find-generic-password", @"-s", @"tocaTintas-ListenBrainz", @"-a", @"token", @"-w"];
        NSPipe *saida = [NSPipe pipe];
        t.standardOutput = saida;
        t.standardError = [NSFileHandle fileHandleWithNullDevice];
        t.standardInput = [NSFileHandle fileHandleWithNullDevice];
        if (![t launchAndReturnError:NULL]) return;
        NSData *d = [saida.fileHandleForReading readDataToEndOfFile];
        [t waitUntilExit];
        NSString *lido = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (t.terminationStatus == 0 && lido.length >= 16) token = lido;
    });
    return token;
}

static NSData *ZPPedir(NSString *endereco, NSDictionary<NSString *, NSString *> *parametros) {
    NSURLComponents *c = [NSURLComponents componentsWithString:endereco];
    if (parametros.count) {
        NSMutableArray<NSURLQueryItem *> *itens = [NSMutableArray array];
        for (NSString *k in parametros) [itens addObject:[NSURLQueryItem queryItemWithName:k value:parametros[k]]];
        c.queryItems = itens;
    }
    if (!c.URL) return nil;
    NSMutableURLRequest *pedido = [NSMutableURLRequest requestWithURL:c.URL];
    pedido.timeoutInterval = 30;
    [pedido setValue:kAgente forHTTPHeaderField:@"User-Agent"];
    // O token só vai para a ListenBrainz, e só por HTTPS.
    if ([c.scheme isEqualToString:@"https"] && [c.host hasSuffix:@"listenbrainz.org"] && ZPTokenDaListenBrainz()) {
        [pedido setValue:[@"Token " stringByAppendingString:ZPTokenDaListenBrainz()] forHTTPHeaderField:@"Authorization"];
    }
    __block NSData *dados = nil;
    dispatch_semaphore_t feito = dispatch_semaphore_create(0);
    [[[NSURLSession sharedSession] dataTaskWithRequest:pedido completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (!e && [(NSHTTPURLResponse *)r statusCode] == 200) dados = d;
        dispatch_semaphore_signal(feito);
    }] resume];
    dispatch_semaphore_wait(feito, dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC));
    return dados;
}

static id ZPPedirJSON(NSString *endereco, NSDictionary<NSString *, NSString *> *parametros) {
    NSData *dados = ZPPedir(endereco, parametros);
    return dados ? [NSJSONSerialization JSONObjectWithData:dados options:0 error:NULL] : nil;
}

static BOOL ZPMapaTemColuna(sqlite3 *db, const char *tabela, const char *coluna) {
    sqlite3_stmt *s = NULL;
    BOOL tem = NO;
    if (sqlite3_prepare_v2(db, [NSString stringWithFormat:@"PRAGMA table_info(%s)", tabela].UTF8String, -1, &s, NULL) == SQLITE_OK) {
        while (sqlite3_step(s) == SQLITE_ROW) if ([ZPTexto(s, 1) isEqualToString:@(coluna)]) tem = YES;
    }
    sqlite3_finalize(s);
    return tem;
}

static sqlite3 *ZPAbrirMapaParaEscrever(NSString *caminho) {
    sqlite3 *mapa = NULL;
    if (sqlite3_open_v2(caminho.fileSystemRepresentation, &mapa, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL) != SQLITE_OK) {
        fprintf(stderr, "Não consegui abrir o mapa «%s».\n", caminho.UTF8String);
        sqlite3_close(mapa);
        return NULL;
    }
    sqlite3_busy_timeout(mapa, 20000);
    sqlite3_exec(mapa, "PRAGMA foreign_keys = ON", NULL, NULL, NULL);   // apagar uma faixa leva a assinatura e os juízos
    const char *esquema =
        "CREATE TABLE IF NOT EXISTS faixas ("
        "    id INTEGER PRIMARY KEY, loja INTEGER, pid TEXT UNIQUE, musica TEXT,"
        "    artista TEXT, album TEXT, titulo TEXT, duracao REAL, endereco TEXT,"
        "    origem TEXT NOT NULL, semente TEXT, associacao TEXT, vista_em TEXT NOT NULL);"
        "CREATE INDEX IF NOT EXISTS faixas_loja ON faixas(loja);"
        "CREATE TABLE IF NOT EXISTS assinaturas ("
        "    faixa INTEGER PRIMARY KEY REFERENCES faixas(id) ON DELETE CASCADE,"
        "    modelo TEXT NOT NULL, vector BLOB NOT NULL, calculada_em TEXT NOT NULL);"
        "CREATE TABLE IF NOT EXISTS tentativas (pid TEXT PRIMARY KEY, motivo TEXT, quando TEXT NOT NULL);"
        // Quem é cada artista no MusicBrainz, e quando se lhe pediram os vizinhos.
        "CREATE TABLE IF NOT EXISTS artistas (chave TEXT PRIMARY KEY, nome TEXT, mbid TEXT, vizinhos_em TEXT);"
        // Os vizinhos que a ListenBrainz deu, e quando se foram ver as faixas de cada um.
        "CREATE TABLE IF NOT EXISTS vizinhos (artista TEXT NOT NULL, vizinho TEXT NOT NULL, nome TEXT, peso REAL,"
        "    explorado_em TEXT, PRIMARY KEY (artista, vizinho));"
        // O que se procurou na loja e não havia, para não voltar a perguntar.
        "CREATE TABLE IF NOT EXISTS procuradas (chave TEXT PRIMARY KEY, quando TEXT NOT NULL);"
        // O juízo pelo som: em que lugar a faixa ficaria entre as vizinhas da semente.
        "CREATE TABLE IF NOT EXISTS juizos (faixa INTEGER NOT NULL REFERENCES faixas(id) ON DELETE CASCADE,"
        "    semente TEXT NOT NULL, semelhanca REAL NOT NULL, lugar INTEGER NOT NULL, quando TEXT NOT NULL,"
        "    PRIMARY KEY (faixa, semente));";
    char *erro = NULL;
    if (sqlite3_exec(mapa, esquema, NULL, NULL, &erro) != SQLITE_OK) {
        fprintf(stderr, "Não consegui preparar o mapa: %s\n", erro ?: "?");
        sqlite3_free(erro);
        sqlite3_close(mapa);
        return NULL;
    }
    // Coluna que veio depois: quando o utilizador mandou esquecer a descoberta.
    if (!ZPMapaTemColuna(mapa, "faixas", "esquecida_em")) sqlite3_exec(mapa, "ALTER TABLE faixas ADD COLUMN esquecida_em TEXT", NULL, NULL, NULL);
    return mapa;
}

// Executa com parâmetros (NSString, NSNumber, NSData ou NSNull).
static BOOL ZPMapaExecutar(sqlite3 *db, const char *sql, NSArray *valores) {
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { fprintf(stderr, "%s\n", sqlite3_errmsg(db)); return NO; }
    int i = 1;
    for (id v in valores) {
        if ([v isKindOfClass:[NSString class]]) sqlite3_bind_text(s, i, [v UTF8String], -1, SQLITE_TRANSIENT);
        else if ([v isKindOfClass:[NSNumber class]]) sqlite3_bind_double(s, i, [v doubleValue]);
        else if ([v isKindOfClass:[NSData class]]) sqlite3_bind_blob(s, i, [v bytes], (int)[v length], SQLITE_TRANSIENT);
        else sqlite3_bind_null(s, i);
        ++i;
    }
    BOOL ok = sqlite3_step(s) == SQLITE_DONE;
    sqlite3_finalize(s);
    return ok;
}

static NSString *ZPMapaTexto(sqlite3 *db, const char *sql, NSArray<NSString *> *valores) {
    sqlite3_stmt *s = NULL;
    NSString *r = nil;
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) return nil;
    int i = 1;
    for (NSString *v in valores) sqlite3_bind_text(s, i++, v.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(s) == SQLITE_ROW && sqlite3_column_type(s, 0) != SQLITE_NULL) r = ZPTexto(s, 0);
    sqlite3_finalize(s);
    return r;
}

static NSString *ZPChaveDaFaixa(NSString *artista, NSString *titulo) {
    return [NSString stringWithFormat:@"%@|%@", ZPChaveDoArtista(artista, @""), ZPChaveDoTitulo(titulo)];
}

// As assinaturas da fonoteca (a fina de cada música, se houver) numa matriz, e
// as chaves artista|título das músicas que têm ficheiro.
static NSUInteger ZPCarregarFonoteca(sqlite3 *db, NSMutableData *vectores, NSMutableSet<NSString *> *chaves) {
    sqlite3_stmt *s = NULL;
    NSUInteger n = 0;
    const char *sql = "SELECT a.vector, m.artista, m.titulo FROM assinaturas a JOIN musicas m ON m.id = a.musica"
                      " WHERE a.modelo = ?2 OR (a.modelo = ?1 AND NOT EXISTS"
                      "       (SELECT 1 FROM assinaturas b WHERE b.musica = a.musica AND b.modelo = ?2))";
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) return 0;
    sqlite3_bind_text(s, 1, kModelo, -1, SQLITE_STATIC);
    sqlite3_bind_text(s, 2, kModeloFino, -1, SQLITE_STATIC);
    while (sqlite3_step(s) == SQLITE_ROW) {
        if (sqlite3_column_bytes(s, 0) != kBytesDaAssinatura) continue;
        float um[kDimensao];
        ZPAssinaturaParaVector(sqlite3_column_blob(s, 0), um);
        [vectores appendBytes:um length:sizeof(um)];
        [chaves addObject:ZPChaveDaFaixa(ZPTexto(s, 1), ZPTexto(s, 2))];
        ++n;
    }
    sqlite3_finalize(s);
    return n;
}

// A assinatura da semente, se já existir: na fonoteca (UUID ou caminho) ou no
// mapa («musica:PID»). Aqui não se calcula nada.
static BOOL ZPAlvoDaSemente(sqlite3 *db, sqlite3 *mapa, NSString *semente, float *alvo) {
    sqlite3_stmt *s = NULL;
    BOOL tem = NO;
    if ([semente hasPrefix:@"musica:"]) {
        if (sqlite3_prepare_v2(mapa, "SELECT a.vector FROM assinaturas a JOIN faixas f ON f.id = a.faixa WHERE f.pid = ?", -1, &s, NULL) != SQLITE_OK) return NO;
        sqlite3_bind_text(s, 1, [semente substringFromIndex:7].UTF8String, -1, SQLITE_TRANSIENT);
    } else {
        const char *sql = ZPPareceUUID(semente)
            ? "SELECT vector FROM assinaturas WHERE musica = ?1 AND modelo IN (?2, ?3) ORDER BY modelo = ?3 DESC LIMIT 1"
            : "SELECT a.vector FROM assinaturas a JOIN ficheiros f ON f.musica = a.musica WHERE f.caminho = ?1"
              " AND a.modelo IN (?2, ?3) ORDER BY a.modelo = ?3 DESC LIMIT 1";
        if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) return NO;
        NSString *valor = ZPPareceUUID(semente) ? semente.lowercaseString
                                                : semente.stringByStandardizingPath.precomposedStringWithCanonicalMapping;
        sqlite3_bind_text(s, 1, valor.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(s, 2, kModelo, -1, SQLITE_STATIC);
        sqlite3_bind_text(s, 3, kModeloFino, -1, SQLITE_STATIC);
    }
    if (sqlite3_step(s) == SQLITE_ROW && sqlite3_column_bytes(s, 0) == kBytesDaAssinatura) {
        ZPAssinaturaParaVector(sqlite3_column_blob(s, 0), alvo);
        tem = YES;
    }
    sqlite3_finalize(s);
    return tem;
}

static NSString *ZPAgoraISO(void) {
    return [NSISO8601DateFormatter stringFromDate:[NSDate date] timeZone:[NSTimeZone timeZoneWithAbbreviation:@"UTC"]
                                    formatOptions:NSISO8601DateFormatWithInternetDateTime];
}

static int ZPModoAssociar(NSString *base, NSString *caminhoDoMapa, NSString *artista, NSString *titulo, NSString *semente,
                          NSUInteger quantas) {
    setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG);
    // «Compositor; Intérpretes»: conta o compositor. Colectâneas não dizem nada.
    NSString *chaveDoArtista = ZPChaveDoArtista(artista, @"");
    if (chaveDoArtista.length == 0 || [chaveDoArtista hasPrefix:@"álbum:"]) { printf("sem artista que se possa associar\n"); return 0; }
    NSString *nomeDoArtista = [[artista componentsSeparatedByString:@";"].firstObject
                               stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    sqlite3 *db = ZPAbrirBase(base);
    sqlite3 *mapa = ZPAbrirMapaParaEscrever(caminhoDoMapa);
    if (!db || !mapa) { sqlite3_close(db); sqlite3_close(mapa); return 1; }

    // 1. Quem é o artista (MusicBrainz), uma vez por artista.
    NSString *mbid = ZPMapaTexto(mapa, "SELECT mbid FROM artistas WHERE chave = ?", @[chaveDoArtista]);
    if (!mbid) {
        // O MusicBrainz responde «ocupado» (503) com frequência a quem não se
        // identifica com contacto: tenta-se duas vezes, e sem resposta fica
        // para a próxima faixa deste artista.
        NSDictionary *r = nil;
        for (int tentativa = 0; tentativa < 2 && ![r[@"artists"] isKindOfClass:[NSArray class]]; ++tentativa) {
            if (tentativa) [NSThread sleepForTimeInterval:2.5];
            id resposta = ZPPedirJSON(@"https://musicbrainz.org/ws/2/artist",
                                      @{ @"fmt": @"json", @"limit": @"1", @"query": [NSString stringWithFormat:@"artist:\"%@\"", nomeDoArtista] });
            r = [resposta isKindOfClass:[NSDictionary class]] ? resposta : nil;
        }
        if (![r[@"artists"] isKindOfClass:[NSArray class]]) {
            printf("o MusicBrainz não respondeu por «%s»; fica para outra vez\n", nomeDoArtista.UTF8String);
            sqlite3_close(db); sqlite3_close(mapa);
            return 0;
        }
        NSDictionary *primeiro = [r[@"artists"] firstObject];
        if (![primeiro[@"id"] isKindOfClass:[NSString class]] || [primeiro[@"score"] integerValue] < 90) {
            printf("o MusicBrainz não conhece «%s»\n", nomeDoArtista.UTF8String);
            ZPMapaExecutar(mapa, "INSERT OR REPLACE INTO artistas (chave, nome, mbid) VALUES (?, ?, '')", @[chaveDoArtista, nomeDoArtista]);
            sqlite3_close(db); sqlite3_close(mapa);
            return 0;
        }
        mbid = primeiro[@"id"];
        ZPMapaExecutar(mapa, "INSERT OR REPLACE INTO artistas (chave, nome, mbid) VALUES (?, ?, ?)", @[chaveDoArtista, nomeDoArtista, mbid]);
    }
    if (mbid.length == 0) { printf("artista sem identificador\n"); sqlite3_close(db); sqlite3_close(mapa); return 0; }

    // 2. Os vizinhos dele (ListenBrainz), renovados de 30 em 30 dias.
    NSString *fresco = ZPMapaTexto(mapa, "SELECT 1 FROM artistas WHERE chave = ? AND vizinhos_em > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-30 days')", @[chaveDoArtista]);
    if (!fresco) {
        NSArray *r = ZPPedirJSON(@"https://labs.api.listenbrainz.org/similar-artists/json",
                                 @{ @"artist_mbids": mbid,
                                    @"algorithm": @"session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30" });
        if ([r isKindOfClass:[NSArray class]]) {
            for (NSDictionary *v in r) {
                if (![v isKindOfClass:[NSDictionary class]] || ![v[@"artist_mbid"] isKindOfClass:[NSString class]]) continue;
                ZPMapaExecutar(mapa, "INSERT INTO vizinhos (artista, vizinho, nome, peso) VALUES (?1, ?2, ?3, ?4)"
                                     " ON CONFLICT (artista, vizinho) DO UPDATE SET nome = ?3, peso = ?4",
                               @[mbid, v[@"artist_mbid"], v[@"name"] ?: @"", @([v[@"score"] doubleValue])]);
            }
            ZPMapaExecutar(mapa, "UPDATE artistas SET vizinhos_em = ? WHERE chave = ?", @[ZPAgoraISO(), chaveDoArtista]);
        } else {
            printf("a ListenBrainz não deu vizinhos de «%s»\n", nomeDoArtista.UTF8String);
        }
    }

    // 3. Os vizinhos de maior peso que ainda não se foram ver, e as gravações
    //    mais ouvidas de cada um: três por vizinho.
    NSMutableArray<NSArray<NSString *> *> *vizinhos = [NSMutableArray array];
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(mapa, "SELECT vizinho, nome FROM vizinhos WHERE artista = ? AND explorado_em IS NULL ORDER BY peso DESC LIMIT ?",
                           -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_text(s, 1, mbid.UTF8String, -1, SQLITE_TRANSIENT);
        // Mais vizinhos do que os precisos: de muitos o utilizador já tem tudo,
        // e esses não dão candidatas. Pára-se quando houver as pedidas.
        sqlite3_bind_int(s, 2, (int)MAX(quantas, 12));
        while (sqlite3_step(s) == SQLITE_ROW) [vizinhos addObject:@[ZPTexto(s, 0), ZPTexto(s, 1)]];
    }
    sqlite3_finalize(s);
    if (vizinhos.count == 0) { printf("os vizinhos de «%s» já foram todos vistos\n", nomeDoArtista.UTF8String); sqlite3_close(db); sqlite3_close(mapa); return 0; }

    NSMutableData *vectores = [NSMutableData data];
    NSMutableSet<NSString *> *locais = [NSMutableSet set];
    NSUInteger n = ZPCarregarFonoteca(db, vectores, locais);
    float alvo[kDimensao];
    BOOL temAlvo = semente.length && n > 0 && ZPAlvoDaSemente(db, mapa, semente, alvo);
    float semelhancaDaCandidata = 0;
    float *semelhancas = temAlvo ? malloc(n * sizeof(float)) : NULL;
    if (temAlvo) vDSP_mmul(vectores.bytes, 1, alvo, 1, semelhancas, 1, n, 1, kDimensao);
    NSString *nomeDaSemente = [NSString stringWithFormat:@"%@ — %@", artista, titulo];

    MLModel *modelo = nil;
    ZPMel *melador = NULL;
    ZPTempos tempos = {0};
    NSUInteger novas = 0, aprovadas = 0, vistas = 0;

    // Uma semente sem assinatura (faixa do Música que o mapa ainda não tem, ou
    // ficheiro por registar): o alvo tira-se do excerto dela na loja, para as
    // candidatas não ficarem sem juízo. Não se guarda; é só para medir.
    if (!temAlvo && n > 0 && titulo.length) {
        [NSThread sleepForTimeInterval:3.1];
        NSDictionary *r = ZPPedirJSON(@"https://itunes.apple.com/search",
                                      @{ @"term": [NSString stringWithFormat:@"%@ %@", artista, titulo], @"country": @"pt",
                                         @"media": @"music", @"entity": @"song", @"limit": @"15" });
        NSString *kt = ZPChaveDoTitulo(titulo), *ka = ZPChaveDoArtista(artista, @"");
        for (NSDictionary *x in ([r isKindOfClass:[NSDictionary class]] && [r[@"results"] isKindOfClass:[NSArray class]] ? r[@"results"] : @[])) {
            if (![x isKindOfClass:[NSDictionary class]] || ![x[@"trackName"] isKindOfClass:[NSString class]]
                || ![x[@"artistName"] isKindOfClass:[NSString class]] || ![x[@"previewUrl"] isKindOfClass:[NSString class]]) continue;
            NSString *kx = ZPChaveDoArtista(x[@"artistName"], @"");
            if (kt.length == 0 || ![ZPChaveDoTitulo(x[@"trackName"]) isEqualToString:kt]
                || !([kx containsString:ka] || [ka containsString:kx])) continue;
            NSData *som = ZPPedir(x[@"previewUrl"], nil);
            if (som.length < 10000) break;
            NSString *temporario = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"vectorizar-excerto-%@.m4a", NSUUID.UUID.UUIDString]];
            [som writeToFile:temporario atomically:NO];
            modelo = ZPModeloQuandoPreciso(); melador = ZPMelCriar();
            gSementeSolta = YES;
            temAlvo = modelo && ZPVectorDaFaixa(modelo, melador, temporario, 0.0, alvo, &tempos);
            [[NSFileManager defaultManager] removeItemAtPath:temporario error:NULL];
            break;
        }
        if (temAlvo) {
            semelhancas = malloc(n * sizeof(float));
            vDSP_mmul(vectores.bytes, 1, alvo, 1, semelhancas, 1, n, 1, kDimensao);
            printf("semente sem assinatura: mede-se pelo excerto da loja\n");
        } else {
            printf("semente sem assinatura nem excerto: as candidatas ficam sem lugar\n");
        }
    }
    for (NSArray<NSString *> *vizinho in vizinhos) {
        // 4. As canções do vizinho que a loja põe à frente, num só pedido (um de
        //    três em três segundos). As «mais ouvidas» da ListenBrainz passaram
        //    a exigir conta; a loja dá-as por ordem de procura, já com o excerto.
        //
        //    Com o token da ListenBrainz no Porta-chaves, as canções são as mais
        //    ouvidas do vizinho, e a loja só serve para as encontrar: um pedido
        //    por canção, cinco no máximo por vizinho. Se isso falhar, ou sem
        //    token, fica a ordem da loja.
        NSDictionary *loja = nil;
        NSArray *ouvidas = ZPTokenDaListenBrainz()
            ? ZPPedirJSON([@"https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/" stringByAppendingString:vizinho[0]], nil) : nil;
        if ([ouvidas isKindOfClass:[NSArray class]] && ouvidas.count) {
            NSMutableArray *achadas = [NSMutableArray array];
            NSMutableSet<NSString *> *jaVistas = [NSMutableSet set];
            NSUInteger pedidos = 0;
            for (NSDictionary *g in ouvidas) {
                if (achadas.count >= 3 || pedidos >= 5) break;
                NSString *t = [g isKindOfClass:[NSDictionary class]] ? g[@"recording_name"] : nil;
                if (![t isKindOfClass:[NSString class]] || t.length == 0) continue;
                NSString *a = [g[@"artist_name"] isKindOfClass:[NSString class]] ? g[@"artist_name"] : vizinho[1];
                NSString *kt = ZPChaveDoTitulo(t);
                if (kt.length == 0 || [jaVistas containsObject:kt] || [locais containsObject:ZPChaveDaFaixa(a, t)]) continue;
                [jaVistas addObject:kt];
                ++pedidos;
                [NSThread sleepForTimeInterval:3.1];
                NSDictionary *r = ZPPedirJSON(@"https://itunes.apple.com/search",
                                              @{ @"term": [NSString stringWithFormat:@"%@ %@", a, t], @"country": @"pt",
                                                 @"media": @"music", @"entity": @"song", @"limit": @"15" });
                for (NSDictionary *x in ([r isKindOfClass:[NSDictionary class]] && [r[@"results"] isKindOfClass:[NSArray class]] ? r[@"results"] : @[])) {
                    if ([x isKindOfClass:[NSDictionary class]] && [x[@"trackName"] isKindOfClass:[NSString class]]
                        && [ZPChaveDoTitulo(x[@"trackName"]) isEqualToString:kt]) { [achadas addObject:x]; break; }
                }
            }
            loja = @{ @"results": achadas };
        } else {
            [NSThread sleepForTimeInterval:3.1];
            loja = ZPPedirJSON(@"https://itunes.apple.com/search",
                               @{ @"term": vizinho[1], @"country": @"pt", @"media": @"music", @"entity": @"song",
                                  @"attribute": @"artistTerm", @"limit": @"25" });
        }
        if (![loja isKindOfClass:[NSDictionary class]]) continue;   // falha passageira: fica para outra vez
        ZPMapaExecutar(mapa, "UPDATE vizinhos SET explorado_em = ? WHERE artista = ? AND vizinho = ?", @[ZPAgoraISO(), mbid, vizinho[0]]);
        NSUInteger deste = 0;
        NSMutableSet<NSString *> *titulosDeste = [NSMutableSet set];
        NSString *chaveDoVizinho = ZPChaveDoArtista(vizinho[1], @"");
        for (NSDictionary *escolhida in ([loja[@"results"] isKindOfClass:[NSArray class]] ? loja[@"results"] : @[])) {
            if (deste >= 3 || vistas >= quantas) break;
            if (![escolhida isKindOfClass:[NSDictionary class]] || ![escolhida[@"previewUrl"] isKindOfClass:[NSString class]]
                || ![escolhida[@"trackName"] isKindOfClass:[NSString class]] || ![escolhida[@"trackId"] isKindOfClass:[NSNumber class]]) continue;
            NSString *a = [escolhida[@"artistName"] isKindOfClass:[NSString class]] ? escolhida[@"artistName"] : vizinho[1];
            NSString *t = escolhida[@"trackName"];
            // Só o próprio artista (não quem o cita no título), uma versão de
            // cada canção, e nada que já haja em ficheiro ou no mapa.
            NSString *ka = ZPChaveDoArtista(a, @"");
            if (![ka containsString:chaveDoVizinho] && ![chaveDoVizinho containsString:ka]) continue;
            NSString *kt = ZPChaveDoTitulo(t);
            if (kt.length == 0 || [titulosDeste containsObject:kt]) continue;
            if ([locais containsObject:ZPChaveDaFaixa(a, t)]) continue;
            [titulosDeste addObject:kt];
            ++deste; ++vistas;
            NSNumber *idDaLoja = escolhida[@"trackId"];
            if (ZPMapaTexto(mapa, "SELECT 1 FROM faixas WHERE loja = ?", @[[idDaLoja stringValue] ?: @""])) continue;

            // 5. O excerto e a assinatura dele.
            NSData *som = ZPPedir(escolhida[@"previewUrl"], nil);
            if (som.length < 10000) continue;
            NSString *temporario = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"vectorizar-excerto-%@.m4a", NSUUID.UUID.UUIDString]];
            [som writeToFile:temporario atomically:NO];
            if (!modelo) { modelo = ZPModeloQuandoPreciso(); melador = ZPMelCriar(); }
            float vector[kDimensao];
            gSementeSolta = YES;
            BOOL ok = modelo && ZPVectorDaFaixa(modelo, melador, temporario, 0.0, vector, &tempos);
            [[NSFileManager defaultManager] removeItemAtPath:temporario error:NULL];
            if (!ok) continue;

            _Float16 meio[kDimensao];
            for (int i = 0; i < kDimensao; ++i) meio[i] = (_Float16)vector[i];
            NSString *endereco = [[escolhida[@"trackViewUrl"] ?: @"" componentsSeparatedByString:@"&uo="] firstObject];
            if (!ZPMapaExecutar(mapa, "INSERT INTO faixas (loja, artista, album, titulo, duracao, endereco, origem, semente, associacao, vista_em)"
                                      " VALUES (?, ?, ?, ?, ?, ?, 'associacao', ?, ?, ?)",
                                @[idDaLoja, escolhida[@"artistName"] ?: a, escolhida[@"collectionName"] ?: @"", escolhida[@"trackName"],
                                  @([escolhida[@"trackTimeMillis"] doubleValue] / 1000.0), endereco, nomeDaSemente,
                                  [@"listenbrainz:" stringByAppendingString:vizinho[1]], ZPAgoraISO()])) continue;
            sqlite3_int64 faixa = sqlite3_last_insert_rowid(mapa);
            ZPMapaExecutar(mapa, "INSERT OR REPLACE INTO assinaturas VALUES (?, ?, ?, ?)",
                           @[@(faixa), @(kModeloDoExcerto), [NSData dataWithBytes:meio length:sizeof(meio)], ZPAgoraISO()]);
            ++novas;

            // 6. O juízo: o lugar que teria entre as vizinhas da semente.
            if (temAlvo) {
                vDSP_dotpr(vector, 1, alvo, 1, &semelhancaDaCandidata, kDimensao);
                NSUInteger lugar = 1;
                for (NSUInteger i = 0; i < n; ++i) if (semelhancas[i] > semelhancaDaCandidata) ++lugar;
                ZPMapaExecutar(mapa, "INSERT OR REPLACE INTO juizos VALUES (?, ?, ?, ?, ?)",
                               @[@(faixa), nomeDaSemente, @(semelhancaDaCandidata), @(lugar), ZPAgoraISO()]);
                if (lugar <= 200) ++aprovadas;
                printf("  %5lu.º  %.3f  %s — %s\n", (unsigned long)lugar, semelhancaDaCandidata,
                       [escolhida[@"artistName"] UTF8String] ?: "", [escolhida[@"trackName"] UTF8String] ?: "");
            } else {
                printf("  %s — %s\n", [escolhida[@"artistName"] UTF8String] ?: "", [escolhida[@"trackName"] UTF8String] ?: "");
            }
            fflush(stdout);
        }
        if (vistas >= quantas) break;
    }
    printf("associar «%s»: %lu candidatas vistas, %lu novas no mapa, %lu nas 200 vizinhas da semente\n", nomeDoArtista.UTF8String,
           (unsigned long)vistas, (unsigned long)novas, (unsigned long)aprovadas);
    free(semelhancas);
    sqlite3_close(db);
    sqlite3_close(mapa);
    return 0;
}

// Uma descoberta que o utilizador juntou à biblioteca do Música passa a ser uma
// faixa como as outras do mapa: ganha o persistent ID e a música da fonoteca, e
// daí em diante entra nas estações. A assinatura já lá está; não se pede nada
// a ninguém.
static void ZPReconciliarMapa(sqlite3 *db, sqlite3 *mapa) {
    NSMutableDictionary<NSString *, NSNumber *> *descobertas = [NSMutableDictionary dictionary];
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(mapa, "SELECT id, artista, titulo FROM faixas WHERE origem = 'associacao' AND pid IS NULL", -1, &s, NULL) == SQLITE_OK) {
        while (sqlite3_step(s) == SQLITE_ROW) descobertas[ZPChaveDaFaixa(ZPTexto(s, 1), ZPTexto(s, 2))] = @(sqlite3_column_int64(s, 0));
    }
    sqlite3_finalize(s);
    if (descobertas.count == 0) return;
    if (sqlite3_prepare_v2(db, "SELECT x.pid, x.musica, x.artista, x.titulo FROM faixas_musica x"
                               " WHERE x.tipo = 'streaming' AND x.musica IS NOT NULL", -1, &s, NULL) != SQLITE_OK) return;
    while (sqlite3_step(s) == SQLITE_ROW) {
        NSNumber *faixa = descobertas[ZPChaveDaFaixa(ZPTexto(s, 2), ZPTexto(s, 3))];
        if (!faixa) continue;
        if (ZPMapaTexto(mapa, "SELECT 1 FROM faixas WHERE pid = ?", @[ZPTexto(s, 0)])) continue;
        ZPMapaExecutar(mapa, "UPDATE faixas SET pid = ?, musica = ?, origem = 'biblioteca' WHERE id = ?", @[ZPTexto(s, 0), ZPTexto(s, 1), faixa]);
    }
    sqlite3_finalize(s);
}

// As descobertas: o que a associação trouxe e ainda não está na biblioteca do
// Música nem foi esquecido. Uma linha por canção, com tabulações:
//     id, lugar, semelhança, artista, título, álbum, endereço, semente que a trouxe, vizinho
// Com semente, a ordem é a da semelhança com ela (e o lugar é o que a canção
// teria entre as vizinhas dela na fonoteca): o mapa todo, e não só o que essa
// semente trouxe. Sem semente, o melhor lugar que cada uma já teve.
static int ZPModoDescobertas(NSString *caminhoDoMapa, NSString *base, NSString *semente, NSUInteger quantas) {
    sqlite3 *mapa = ZPAbrirMapaParaEscrever(caminhoDoMapa);
    if (!mapa) return 1;
    sqlite3 *db = base.length ? ZPAbrirBase(base) : NULL;
    if (db) ZPReconciliarMapa(db, mapa);
    sqlite3_stmt *s = NULL;
    float alvo[kDimensao];
    if (db && semente.length && ZPAlvoDaSemente(db, mapa, semente, alvo)) {
        NSMutableData *vectores = [NSMutableData data];
        NSUInteger n = ZPCarregarFonoteca(db, vectores, [NSMutableSet set]);
        float *daFonoteca = malloc(MAX(n, (NSUInteger)1) * sizeof(float));
        if (n) {
            vDSP_mmul(vectores.bytes, 1, alvo, 1, daFonoteca, 1, n, 1, kDimensao);
            vDSP_vsort(daFonoteca, n, 1);   // crescente
        }
        NSMutableArray<NSArray *> *linhas = [NSMutableArray array];
        if (sqlite3_prepare_v2(mapa, "SELECT f.id, a.vector, f.artista, f.titulo, f.album, f.endereco, f.semente, f.associacao"
                                     "  FROM faixas f JOIN assinaturas a ON a.faixa = f.id"
                                     " WHERE f.origem = 'associacao' AND f.esquecida_em IS NULL", -1, &s, NULL) == SQLITE_OK) {
            while (sqlite3_step(s) == SQLITE_ROW) {
                if (sqlite3_column_bytes(s, 1) != kBytesDaAssinatura) continue;
                float um[kDimensao], semelhanca = 0;
                ZPAssinaturaParaVector(sqlite3_column_blob(s, 1), um);
                vDSP_dotpr(um, 1, alvo, 1, &semelhanca, kDimensao);
                // Quantas da fonoteca ficam acima: procura binária na lista ordenada.
                NSUInteger baixo = 0, cima = n;
                while (baixo < cima) { NSUInteger meio = (baixo + cima) / 2; if (daFonoteca[meio] > semelhanca) cima = meio; else baixo = meio + 1; }
                [linhas addObject:@[@(semelhanca), [NSString stringWithFormat:@"%lld\t%lu\t%.3f\t%@\t%@\t%@\t%@\t%@\t%@",
                                    sqlite3_column_int64(s, 0), (unsigned long)(n - baixo + 1), semelhanca, ZPTexto(s, 2), ZPTexto(s, 3),
                                    ZPTexto(s, 4), ZPTexto(s, 5), ZPTexto(s, 6), ZPTexto(s, 7)]]];
            }
        }
        sqlite3_finalize(s);
        free(daFonoteca);
        [linhas sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [y[0] compare:x[0]]; }];
        for (NSUInteger i = 0; i < MIN(quantas, linhas.count); ++i) printf("%s\n", [linhas[i][1] UTF8String]);
    } else if (sqlite3_prepare_v2(mapa, "SELECT f.id, IFNULL(MIN(j.lugar), 0), IFNULL(MAX(j.semelhanca), 0), f.artista, f.titulo, f.album, f.endereco, f.semente, f.associacao"
                                        "  FROM faixas f LEFT JOIN juizos j ON j.faixa = f.id"   // as sem juízo (lugar 0) vão no fim
                                        " WHERE f.origem = 'associacao' AND f.esquecida_em IS NULL"
                                        " GROUP BY f.id ORDER BY MIN(j.lugar) IS NULL, 2, f.id LIMIT ?", -1, &s, NULL) == SQLITE_OK) {
        sqlite3_bind_int(s, 1, (int)quantas);
        while (sqlite3_step(s) == SQLITE_ROW) {
            printf("%lld\t%d\t%.3f\t%s\t%s\t%s\t%s\t%s\t%s\n", sqlite3_column_int64(s, 0), sqlite3_column_int(s, 1), sqlite3_column_double(s, 2),
                   ZPTexto(s, 3).UTF8String, ZPTexto(s, 4).UTF8String, ZPTexto(s, 5).UTF8String, ZPTexto(s, 6).UTF8String,
                   ZPTexto(s, 7).UTF8String, ZPTexto(s, 8).UTF8String);
        }
        sqlite3_finalize(s);
    }
    sqlite3_close(db);
    sqlite3_close(mapa);
    return 0;
}

// «Esquecer» uma descoberta: fica no mapa, marcada, para a consulta externa
// não a voltar a trazer; só deixa de aparecer.
static int ZPModoEsquecer(NSString *caminhoDoMapa, NSString *faixa) {
    sqlite3 *mapa = ZPAbrirMapaParaEscrever(caminhoDoMapa);
    if (!mapa) return 1;
    BOOL ok = ZPMapaExecutar(mapa, "UPDATE faixas SET esquecida_em = ? WHERE id = ? AND origem = 'associacao'", @[ZPAgoraISO(), @(faixa.longLongValue)]);
    sqlite3_close(mapa);
    return ok ? 0 : 1;
}

#pragma mark - Mapear

// As faixas da biblioteca do Música que ainda não estão no mapa do catálogo:
// as que a fonoteca conhece («sincronizar-musica»), já ligadas a uma música e
// sem ficheiro local. Procura-se cada álbum na loja da Apple (um pedido; os que
// sobrarem, um por faixa), tira-se a assinatura do excerto de 30 s e guarda-se.
// O que a loja não tem fica nas tentativas e não se volta a pedir. As
// pendentes ficam de fora enquanto não forem ligadas: não têm música.
//
// O tocaTintas corre isto depois de cada sincronização com o Música. Para fora
// vão só nomes de artistas, álbuns e títulos; um pedido de três em três
// segundos, que é o que a loja aceita.

static NSString *ZPChaveDoAlbum(NSString *album) {
    NSMutableString *t = [[album ?: @"" stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                                                            locale:nil] mutableCopy];
    [t replaceOccurrencesOfString:@"[\\(\\[].*?[\\)\\]]" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    [t replaceOccurrencesOfString:@"\\s+-\\s+(ep|single)\\s*$" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    [t replaceOccurrencesOfString:@"[^\\p{L}\\p{N}]+" withString:@"" options:NSRegularExpressionSearch range:NSMakeRange(0, t.length)];
    return t;
}

// O melhor resultado da loja para a faixa, e por que critério (do mais certo
// para o menos): os do «remapear.py», que são os das contagens da fonoteca.
static NSDictionary *ZPCasarComALoja(NSDictionary *f, NSArray *resultados, NSString **criterio) {
    static NSArray<NSString *> *nomes;
    if (!nomes) nomes = @[@"artista+título", @"álbum+faixa", @"mesmo álbum", @"título, outra duração"];
    NSString *ka = ZPChaveDoArtista(f[@"artista"], @""), *kt = ZPChaveDoTitulo(f[@"titulo"]), *kb = ZPChaveDoAlbum(f[@"album"]);
    BOOL varios = [ka hasPrefix:@"álbum:"];
    double duracao = [f[@"duracao"] doubleValue];
    NSDictionary *melhor = nil;
    NSInteger melhorC = 99;
    double melhorD = 0.0;
    for (NSDictionary *r in resultados) {
        if (![r isKindOfClass:[NSDictionary class]] || ![r[@"previewUrl"] isKindOfClass:[NSString class]]
            || ![r[@"trackName"] isKindOfClass:[NSString class]] || ![r[@"trackTimeMillis"] isKindOfClass:[NSNumber class]]
            || ![r[@"trackId"] isKindOfClass:[NSNumber class]]) continue;
        double d = fabs([r[@"trackTimeMillis"] doubleValue] / 1000.0 - duracao);
        NSString *rt = ZPChaveDoTitulo(r[@"trackName"]);
        NSString *ra = ZPChaveDoArtista([r[@"artistName"] isKindOfClass:[NSString class]] ? r[@"artistName"] : @"", @"");
        NSString *rb = ZPChaveDoAlbum([r[@"collectionName"] isKindOfClass:[NSString class]] ? r[@"collectionName"] : @"");
        BOOL titulo = kt.length && [kt isEqualToString:rt];
        BOOL album = kb.length && [kb isEqualToString:rb];
        // Numa colectânea o artista da biblioteca não diz nada: vale o álbum.
        BOOL artista = varios ? album : (ka.length && ra.length && ([ka containsString:ra] || [ra containsString:ka]));
        BOOL parecidos = kt.length && rt.length && ([kt containsString:rt] || [rt containsString:kt]);
        NSInteger c;
        if (artista && titulo && d <= 2.0) c = 0;
        else if (album && d <= 2.0 && parecidos && [f[@"faixa"] integerValue] > 0
                 && [r[@"trackNumber"] integerValue] == [f[@"faixa"] integerValue]
                 && MAX([r[@"discNumber"] integerValue], 1) == MAX([f[@"disco"] integerValue], 1)) c = 1;
        else if (artista && album && titulo && d <= 5.0) c = 2;
        else if (artista && titulo && d <= 30.0) c = 3;
        else continue;
        if (c == 0 && !album) d += 1.0;   // prefere o mesmo álbum
        if (c < melhorC || (c == melhorC && d < melhorD)) { melhor = r; melhorC = c; melhorD = d; }
    }
    if (melhor && criterio) *criterio = nomes[melhorC];
    return melhor;
}

// Um pedido à loja, nunca a menos de 3,1 s do anterior. nil se ela não responder.
static NSArray *ZPProcurarNaLoja(NSString *termo, NSUInteger limite) {
    static double ultimo = 0.0;
    for (int tentativa = 0; tentativa < 3; ++tentativa) {
        double espera = 3.1 - (ZPAgora() - ultimo);
        if (espera > 0.0) [NSThread sleepForTimeInterval:espera];
        ultimo = ZPAgora();
        NSDictionary *r = ZPPedirJSON(@"https://itunes.apple.com/search",
                                      @{ @"term": termo, @"country": @"pt", @"media": @"music", @"entity": @"song",
                                         @"limit": [NSString stringWithFormat:@"%lu", (unsigned long)limite] });
        if ([r isKindOfClass:[NSDictionary class]] && [r[@"results"] isKindOfClass:[NSArray class]]) return r[@"results"];
        [NSThread sleepForTimeInterval:20.0 * (tentativa + 1)];
    }
    return nil;
}

static int ZPModoMapear(NSString *base, NSString *caminhoDoMapa) {
    sqlite3 *db = ZPAbrirBase(base);
    if (!db) return 1;
    sqlite3 *mapa = ZPAbrirMapaParaEscrever(caminhoDoMapa);
    if (!mapa) { sqlite3_close(db); return 1; }
    ZPReconciliarMapa(db, mapa);   // as descobertas que entretanto foram para a biblioteca já têm assinatura
    ZPMapaExecutar(mapa, "DELETE FROM tentativas WHERE pid IN (SELECT pid FROM faixas WHERE pid IS NOT NULL)", @[]);

    NSMutableSet<NSString *> *feitas = [NSMutableSet set];
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(mapa, "SELECT pid FROM faixas WHERE pid IS NOT NULL UNION SELECT pid FROM tentativas", -1, &s, NULL) == SQLITE_OK) {
        while (sqlite3_step(s) == SQLITE_ROW) [feitas addObject:ZPTexto(s, 0)];
    }
    sqlite3_finalize(s);
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *albuns = [NSMutableDictionary dictionary];
    NSUInteger porFazer = 0;
    if (sqlite3_prepare_v2(db, "SELECT x.pid, x.musica, x.artista, x.album, x.disco, x.faixa, x.titulo, x.duracao FROM faixas_musica x"
                               " WHERE x.tipo = 'streaming' AND x.musica IS NOT NULL"
                               " AND NOT EXISTS (SELECT 1 FROM ficheiros f WHERE f.musica = x.musica)", -1, &s, NULL) == SQLITE_OK) {
        while (sqlite3_step(s) == SQLITE_ROW) {
            NSString *pid = ZPTexto(s, 0), *titulo = ZPTexto(s, 6);
            if (pid.length == 0 || titulo.length == 0 || [feitas containsObject:pid]) continue;
            NSDictionary *f = @{ @"pid": pid, @"musica": ZPTexto(s, 1), @"artista": ZPTexto(s, 2), @"album": ZPTexto(s, 3),
                                 @"disco": @(sqlite3_column_int(s, 4)), @"faixa": @(sqlite3_column_int(s, 5)),
                                 @"titulo": titulo, @"duracao": @(sqlite3_column_double(s, 7)) };
            NSString *k = [NSString stringWithFormat:@"%@\t%@", f[@"artista"], f[@"album"]];
            if (!albuns[k]) albuns[k] = [NSMutableArray array];
            [albuns[k] addObject:f];
            ++porFazer;
        }
    }
    sqlite3_finalize(s);
    sqlite3_close(db);
    if (porFazer == 0) { printf("mapear: nada de novo\n"); sqlite3_close(mapa); return 0; }
    printf("mapear: %lu faixas por fazer em %lu álbuns\n", (unsigned long)porFazer, (unsigned long)albuns.count);
    fflush(stdout);

    MLModel *modelo = nil;
    ZPMel *melador = NULL;
    ZPTempos tempos = {0};
    NSUInteger novas = 0, semLoja = 0, semExcerto = 0;
    double t0 = ZPAgora();
    BOOL calada = NO;
    for (NSString *k in [albuns.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<NSDictionary *> *faixas = albuns[k];
        NSString *artista = [faixas[0][@"artista"] componentsSeparatedByString:@";"].firstObject;
        NSString *album = faixas[0][@"album"];
        if ([ZPChaveDoArtista(artista, @"") hasPrefix:@"álbum:"]) artista = @"";
        NSArray *doAlbum = @[];
        if (faixas.count > 1 && album.length) {
            doAlbum = ZPProcurarNaLoja([[NSString stringWithFormat:@"%@ %@", artista, album]
                                        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], 200);
            if (!doAlbum) { calada = YES; break; }
        }
        for (NSDictionary *f in faixas) {
            @autoreleasepool {
                NSString *criterio = nil;
                NSDictionary *r = ZPCasarComALoja(f, doAlbum, &criterio);
                if (!r) {
                    NSArray *daFaixa = ZPProcurarNaLoja([[NSString stringWithFormat:@"%@ %@", artista, f[@"titulo"]]
                                                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], 50);
                    if (!daFaixa) { calada = YES; break; }
                    r = ZPCasarComALoja(f, daFaixa, &criterio);
                }
                if (!r) {
                    ZPMapaExecutar(mapa, "INSERT OR REPLACE INTO tentativas VALUES (?, 'sem correspondência (2)', ?)", @[f[@"pid"], ZPAgoraISO()]);
                    ++semLoja;
                    continue;
                }
                // O excerto e a assinatura dele. Se falhar, fica para a próxima vez.
                NSData *som = ZPPedir(r[@"previewUrl"], nil);
                BOOL ok = NO;
                float vector[kDimensao];
                if (som.length >= 10000) {
                    NSString *temporario = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                            [NSString stringWithFormat:@"vectorizar-excerto-%@.m4a", NSUUID.UUID.UUIDString]];
                    [som writeToFile:temporario atomically:NO];
                    if (!modelo) { modelo = ZPModeloQuandoPreciso(); melador = ZPMelCriar(); }
                    gSementeSolta = YES;
                    ok = modelo && ZPVectorDaFaixa(modelo, melador, temporario, 0.0, vector, &tempos);
                    [[NSFileManager defaultManager] removeItemAtPath:temporario error:NULL];
                }
                if (!ok) { ++semExcerto; continue; }
                _Float16 meio[kDimensao];
                for (int i = 0; i < kDimensao; ++i) meio[i] = (_Float16)vector[i];
                NSString *endereco = [[([r[@"trackViewUrl"] isKindOfClass:[NSString class]] ? r[@"trackViewUrl"] : @"")
                                       componentsSeparatedByString:@"&uo="] firstObject];
                if (!ZPMapaExecutar(mapa, "INSERT INTO faixas (loja, pid, musica, artista, album, titulo, duracao, endereco, origem, associacao, vista_em)"
                                          " VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'biblioteca', ?, ?)",
                                    @[r[@"trackId"], f[@"pid"], f[@"musica"], f[@"artista"], f[@"album"], f[@"titulo"], f[@"duracao"],
                                      endereco, criterio, ZPAgoraISO()])) continue;
                ZPMapaExecutar(mapa, "INSERT OR REPLACE INTO assinaturas VALUES (?, ?, ?, ?)",
                               @[@(sqlite3_last_insert_rowid(mapa)), @(kModeloDoExcerto), [NSData dataWithBytes:meio length:sizeof(meio)], ZPAgoraISO()]);
                ++novas;
            }
        }
        if (calada) break;
    }
    if (calada) printf("mapear: a loja não responde; o resto fica para a próxima vez\n");
    printf("mapear: %lu assinadas, %lu sem correspondência na loja, %lu sem excerto, %.0f s\n",
           (unsigned long)novas, (unsigned long)semLoja, (unsigned long)semExcerto, ZPAgora() - t0);
    sqlite3_close(mapa);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        for (int i = 1; i < argc; ++i) [args addObject:@(argv[i])];
        // O modelo: ao lado do executável ou, dentro de uma aplicação, nos Resources.
        NSString *pasta = [(NSBundle.mainBundle.executablePath ?: @(argv[0])) stringByDeletingLastPathComponent];
        NSString *modeloCaminho = [pasta stringByAppendingPathComponent:@"clap_audio.mlmodelc"];
        if (![[NSFileManager defaultManager] fileExistsAtPath:modeloCaminho]) {
            NSString *nosRecursos = [[[pasta stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"Resources"]
                                     stringByAppendingPathComponent:@"clap_audio.mlmodelc"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:nosRecursos]) modeloCaminho = nosRecursos;
        }
        BOOL soCPU = NO;
        NSString *modo = @"lista";
        double inicioDoExcerto = 0.0;
        NSUInteger quantas = 50, porArtista = 3, porAlbum = 2;
        double minutos = 0.0;
        NSString *artista = nil, *titulo = nil, *semente = nil;
        for (NSUInteger i = 0; i < args.count; ) {
            NSString *a = args[i];
            if ([a isEqualToString:@"--modelo"] && i + 1 < args.count) {
                modeloCaminho = args[i + 1];
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--cpu"]) {
                soCPU = YES;
                [args removeObjectAtIndex:i];
            } else if ([@[@"--artista", @"--titulo", @"--semente"] containsObject:a] && i + 1 < args.count) {
                if ([a isEqualToString:@"--artista"]) artista = args[i + 1];
                else if ([a isEqualToString:@"--titulo"]) titulo = args[i + 1];
                else semente = args[i + 1];
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--minutos"] && i + 1 < args.count) {
                minutos = args[i + 1].doubleValue;
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--mapa"] && i + 1 < args.count) {
                gMapa = args[i + 1];
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--loja"]) {
                // A lista é de excertos de 30 s de uma loja: três janelas a
                // cobrir cada um, como na semente solta de uma estação.
                gSementeSolta = YES;
                [args removeObjectAtIndex:i];
            } else if ([@[@"--rumo", @"--longe", @"--sem", @"--info"] containsObject:a] && i + 1 < args.count) {
                if ([a isEqualToString:@"--rumo"]) { if (!gRumos) gRumos = [NSMutableArray array]; [gRumos addObject:args[i + 1]]; }
                else if ([a isEqualToString:@"--longe"]) { if (!gLonges) gLonges = [NSMutableArray array]; [gLonges addObject:args[i + 1]]; }
                else if ([a isEqualToString:@"--sem"]) gSem = args[i + 1]; else gInfo = args[i + 1];
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--ancora"] && i + 1 < args.count) {
                gAncora = MAX(args[i + 1].floatValue, 0.0f);
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([@[@"-n", @"--por-artista", @"--por-album", @"--ondas"] containsObject:a] && i + 1 < args.count) {
                NSUInteger v = (NSUInteger)MAX(args[i + 1].integerValue, 1);
                if ([a isEqualToString:@"-n"]) quantas = v; else if ([a isEqualToString:@"--por-artista"]) porArtista = v;
                else if ([a isEqualToString:@"--ondas"]) gOndas = v; else porAlbum = v;
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--excerto"] && i + 1 < args.count) {
                modo = a;
                inicioDoExcerto = args[i + 1].doubleValue;
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--mel"] || [a isEqualToString:@"--vector-do-mel"]) {
                modo = a;
                [args removeObjectAtIndex:i];
            } else {
                ++i;
            }
        }
        gModeloCaminho = modeloCaminho;
        gSoCPU = soCPU;
        if (args.count == 2 && [args[0] isEqualToString:@"actualizar"]) return ZPModoActualizar(args[1]);
        if (args.count == 2 && [args[0] isEqualToString:@"refinar"]) return ZPModoRefinar(args[1], minutos);
        if (args.count == 3 && [args[0] isEqualToString:@"associar"] && artista.length) {
            return ZPModoAssociar(args[1], args[2], artista, titulo ?: @"", semente, quantas == 50 ? 24 : quantas);
        }
        if ((args.count == 2 || args.count == 3) && [args[0] isEqualToString:@"descobertas"]) {
            return ZPModoDescobertas(args[1], args.count == 3 ? args[2] : nil, semente, quantas);
        }
        if (args.count == 3 && [args[0] isEqualToString:@"mapear"]) return ZPModoMapear(args[1], args[2]);
        if (args.count == 3 && [args[0] isEqualToString:@"esquecer"]) return ZPModoEsquecer(args[1], args[2]);
        if (args.count == 3 && [args[0] isEqualToString:@"estacao"]) return ZPModoEstacao(args[1], args[2], quantas, porArtista, porAlbum);
        if (args.count == 4 && [args[0] isEqualToString:@"importar"]) return ZPModoImportar(args[1], args[2], args[3]);
        if (args.count != 2) {
            fprintf(stderr, "uso: vectorizar actualizar BASE\n"
                            "     vectorizar refinar BASE [--minutos N]\n"
                            "     vectorizar associar BASE MAPA --artista A [--titulo T] [--semente (caminho | uuid | musica:PID)] [-n 24]\n"
                            "     vectorizar descobertas MAPA [BASE [--semente S]] [-n 50]\n"
                            "     vectorizar esquecer MAPA ID\n"
                            "     vectorizar mapear BASE MAPA\n"
                            "     vectorizar estacao BASE (caminho | uuid | musica:PID) [-n 50] [--por-artista 3] [--por-album 2] [--mapa MAPA]\n"
                            "     vectorizar importar BASE lista.tsv saída\n"
                            "     vectorizar [--modelo M.mlmodelc] [--cpu] [--loja] lista.tsv saída\n"
                            "     vectorizar --excerto segundos ficheiro pcm.f32\n"
                            "     vectorizar --mel pcm.f32 mel.f32\n"
                            "     vectorizar [--modelo M.mlmodelc] [--cpu] --vector-do-mel mel.f32 vector.f32\n");
            return 2;
        }

        if ([modo isEqualToString:@"--excerto"]) {
            // Ensaio: o excerto tal como o programa o lê (mono, 48 kHz, float32).
            ExtAudioFileRef f = NULL;
            if (ExtAudioFileOpenURL((__bridge CFURLRef)[NSURL fileURLWithPath:args[0]], &f) != noErr) return 1;
            AudioStreamBasicDescription fmt = {0};
            UInt32 t = sizeof(fmt);
            ExtAudioFileGetProperty(f, kExtAudioFileProperty_FileDataFormat, &t, &fmt);
            UInt32 canais = MAX(fmt.mChannelsPerFrame, 1u);
            AudioStreamBasicDescription cliente = {
                .mSampleRate = kFrequencia, .mFormatID = kAudioFormatLinearPCM,
                .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                .mBytesPerPacket = 4 * canais, .mFramesPerPacket = 1, .mBytesPerFrame = 4 * canais,
                .mChannelsPerFrame = canais, .mBitsPerChannel = 32,
            };
            if (ExtAudioFileSetProperty(f, kExtAudioFileProperty_ClientDataFormat, sizeof(cliente), &cliente) != noErr) return 1;
            float *mono = malloc(kTramasDoExcerto * sizeof(float));
            UInt32 lidas = ZPLerExcerto(f, &fmt, inicioDoExcerto, mono);
            ExtAudioFileDispose(f);
            return [[NSData dataWithBytesNoCopy:mono length:lidas * sizeof(float)] writeToFile:args[1] atomically:YES] ? 0 : 1;
        }

        if ([modo isEqualToString:@"--mel"]) {
            NSData *pcm = ZPLerFloats(args[0], kTramasDoExcerto);
            if (!pcm) return 1;
            float *mel = malloc(kQuadros * kBandas * sizeof(float));
            ZPMelCalcular(ZPMelCriar(), pcm.bytes, mel);
            BOOL ok = [[NSData dataWithBytesNoCopy:mel length:kQuadros * kBandas * sizeof(float)] writeToFile:args[1] atomically:YES];
            return ok ? 0 : 1;
        }

        MLModel *modelo = ZPCarregarModelo(modeloCaminho, soCPU);
        if (!modelo) return 1;

        if ([modo isEqualToString:@"--vector-do-mel"]) {
            NSData *mel = ZPLerFloats(args[0], kQuadros * kBandas);
            if (!mel) return 1;
            float vector[kDimensao];
            if (!ZPVectorDoMel(modelo, mel.bytes, vector)) return 1;
            return [[NSData dataWithBytes:vector length:sizeof(vector)] writeToFile:args[1] atomically:YES] ? 0 : 1;
        }

        return ZPModoLista(modelo, args[0], args[1]);
    }
}
