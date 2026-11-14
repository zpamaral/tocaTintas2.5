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
//        Calcula as assinaturas que faltam: músicas novas, ou cujo ficheiro
//        preferido mudou de áudio.
//    vectorizar estacao BASE (caminho | uuid | musica:PID) [-n 50] [--por-artista 3] [--por-album 2] [--mapa MAPA]
//        Escreve os caminhos da estação, um por linha, com a semente à cabeça e
//        os vizinhos por ordem de semelhança. Se a semente ainda não tiver
//        assinatura, calcula-a (e guarda-a, se a música for da fonoteca).
//        Sai com 3 se a semente não servir e com 4 se a base não tiver assinaturas.
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
#include "mel_slaney.h"

// O nome com que as assinaturas ficam na base: o modelo e a maneira de tirar
// os excertos. Mudando um ou outra, muda o nome, e as antigas não se misturam.
static const char * const kModelo = "larger_clap_general/3x10s";

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

    double inicios[3] = { 0.0, 0.0, 0.0 };
    int quantos = 1;
    if (gSementeSolta && duracao >= 20.0 && duracao <= 31.0) {
        // O excerto de 30 s de uma loja: três janelas que o cobrem todo. Com uma
        // só, no início, a «Casta diva» dava vizinhas orquestrais (a introdução).
        quantos = 3;
        inicios[1] = (duracao - 10.0) / 2.0;
        inicios[2] = duracao - 10.0;
    } else if (duracao > 30.0) {
        quantos = 3;
        const double pontos[3] = { 0.25, 0.5, 0.75 };
        for (int i = 0; i < 3; ++i) inicios[i] = MAX(duracao * pontos[i] - 5.0, 0.0);
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

static BOOL ZPGuardarAssinatura(sqlite3 *db, NSString *musica, NSString *md5, const float *vector) {
    _Float16 meio[kDimensao];
    for (int i = 0; i < kDimensao; ++i) meio[i] = (_Float16)vector[i];
    sqlite3_stmt *s = NULL;
    if (sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO assinaturas (musica, modelo, md5_audio, vector) VALUES (?, ?, ?, ?)",
                           -1, &s, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_text(s, 1, musica.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(s, 2, kModelo, -1, SQLITE_STATIC);
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
        if (sqlite3_prepare_v2(db, "SELECT vector FROM assinaturas WHERE musica = ? AND modelo = ?", -1, &s, NULL) == SQLITE_OK) {
            sqlite3_bind_text(s, 1, musica.UTF8String, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(s, 2, kModelo, -1, SQLITE_STATIC);
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
                      " WHERE a.modelo = ?";
    if (sqlite3_prepare_v2(db, sql, -1, &s, NULL) != SQLITE_OK) { fprintf(stderr, "%s\n", sqlite3_errmsg(db)); sqlite3_close(db); return 1; }
    sqlite3_bind_text(s, 1, kModelo, -1, SQLITE_STATIC);
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
            NSString *pid = [@"musica:" stringByAppendingString:ZPTexto(s, 0)];
            [faixas addObject:@[pid, ZPTexto(s, 2), ZPTexto(s, 3), ZPTexto(s, 4), pid]];
        }
        sqlite3_finalize(s);
    }
    sqlite3_close(mapa);
    NSUInteger n = faixas.count;
    if (n < 2) { fprintf(stderr, "A base não tem assinaturas: falta correr «vectorizar actualizar».\n"); return 4; }

    // Semelhança (co-seno: os vectores têm norma 1) e ordem decrescente.
    float *semelhanca = malloc(n * sizeof(float));
    vDSP_Length *ordem = malloc(n * sizeof(vDSP_Length));
    vDSP_mmul(vectores.bytes, 1, alvo, 1, semelhanca, 1, n, 1, kDimensao);
    for (NSUInteger i = 0; i < n; ++i) ordem[i] = i;
    vDSP_vsorti(semelhanca, ordem, NULL, n, -1);

    // A semente vai à cabeça e conta para as regras. Se for da fonoteca, sabe-se
    // quem é; se não, só se evita repeti-la pelo caminho.
    NSMutableSet<NSString *> *titulos = [NSMutableSet set];
    NSCountedSet<NSString *> *artistas = [NSCountedSet set], *albuns = [NSCountedSet set];
    for (NSArray<NSString *> *f in faixas) {
        if ((musica && [f[0] isEqualToString:musica]) || [f[4] isEqualToString:caminhoDaSemente]) {
            NSString *chave = ZPChaveDoTitulo(f[3]);
            if (chave.length) [titulos addObject:chave];
            [artistas addObject:ZPChaveDoArtista(f[1], f[2])];
            [albuns addObject:[NSString stringWithFormat:@"%@|%@", f[1], f[2]]];
            break;
        }
    }
    printf("%s\n", caminhoDaSemente.UTF8String);
    NSUInteger escolhidas = 1;
    for (NSUInteger k = 0; k < n && escolhidas < quantas; ++k) {
        NSArray<NSString *> *f = faixas[ordem[k]];
        if (musica && [f[0] isEqualToString:musica]) continue;
        if ([f[4] isEqualToString:caminhoDaSemente]) continue;
        NSString *chave = ZPChaveDoTitulo(f[3]);
        if (chave.length && [titulos containsObject:chave]) continue;          // outra versão da mesma canção
        NSString *artista = ZPChaveDoArtista(f[1], f[2]);
        NSString *album = [NSString stringWithFormat:@"%@|%@", f[1], f[2]];
        if ([artistas countForObject:artista] >= porArtista) continue;
        if ([albuns countForObject:album] >= porAlbum) continue;
        if (chave.length) [titulos addObject:chave];
        [artistas addObject:artista];
        [albuns addObject:album];
        printf("%s\n", f[4].UTF8String);
        ++escolhidas;
    }
    free(semelhanca);
    free(ordem);
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
        for (NSUInteger i = 0; i < args.count; ) {
            NSString *a = args[i];
            if ([a isEqualToString:@"--modelo"] && i + 1 < args.count) {
                modeloCaminho = args[i + 1];
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--cpu"]) {
                soCPU = YES;
                [args removeObjectAtIndex:i];
            } else if ([a isEqualToString:@"--mapa"] && i + 1 < args.count) {
                gMapa = args[i + 1];
                [args removeObjectsInRange:NSMakeRange(i, 2)];
            } else if ([a isEqualToString:@"--loja"]) {
                // A lista é de excertos de 30 s de uma loja: três janelas a
                // cobrir cada um, como na semente solta de uma estação.
                gSementeSolta = YES;
                [args removeObjectAtIndex:i];
            } else if ([@[@"-n", @"--por-artista", @"--por-album"] containsObject:a] && i + 1 < args.count) {
                NSUInteger v = (NSUInteger)MAX(args[i + 1].integerValue, 1);
                if ([a isEqualToString:@"-n"]) quantas = v; else if ([a isEqualToString:@"--por-artista"]) porArtista = v; else porAlbum = v;
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
        if (args.count == 3 && [args[0] isEqualToString:@"estacao"]) return ZPModoEstacao(args[1], args[2], quantas, porArtista, porAlbum);
        if (args.count == 4 && [args[0] isEqualToString:@"importar"]) return ZPModoImportar(args[1], args[2], args[3]);
        if (args.count != 2) {
            fprintf(stderr, "uso: vectorizar actualizar BASE\n"
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
