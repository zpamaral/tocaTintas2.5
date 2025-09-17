//
//  PreviewProvider.m
//  ZPQLverwv
//
//  Created by J. Pedro Sousa do Amaral on 04/08/2025.
//

#import "PreviewProvider.h"
#import <QuickLook/QuickLook.h>
#import <QuickLookUI/QLPreviewReply.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/log.h>
#include <math.h>
#include <string.h>

#define ChunkHeader WavPackChunkHeader
#include <wavpack/wavpack.h>
#undef ChunkHeader

#define ZP_SMOKE_QL 1

// --------- Compatibilidade: declarações opcionais de QLPreviewReply ----------
@interface QLPreviewReply (ZPTCompatibility)
+ (instancetype)previewReplyWithAudioFileURL:(NSURL *)audioFileURL
                                       title:(NSString *)title
                                      artist:(NSString *)artist
                                       album:(NSString *)album
                                  artworkURL:(NSURL *)artworkURL;
+ (instancetype)previewReplyWithFileURL:(NSURL *)fileURL contentType:(NSString *)contentType;
+ (instancetype)previewReplyWithFileURL:(NSURL *)fileURL;
+ (instancetype)previewReplyWithData:(NSData *)data contentType:(UTType *)contentType;
@end
// ---------------------------------------------------------------------------

#pragma mark - Utilitários

static os_log_t ZPLog(void) {
    static os_log_t l; static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("JPSdA.tocaTintas.ZPQLverwv", "preview"); });
    return l;
}

static NSString *ZPHTMLEscape(NSString *s) {
    if (!s) return @"";
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\""withString:@"&quot;"options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"&#39;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

static BOOL ZPEnsureDir(NSString *path) {
    NSError *err = nil;
    BOOL ok = [[NSFileManager defaultManager] createDirectoryAtPath:path
                                     withIntermediateDirectories:YES
                                                      attributes:nil
                                                           error:&err];
    if (!ok) os_log_error(ZPLog(), "➡️ versão 3 — createDirectoryAtPath %{public}@ failed: %{public}@", path, err.localizedDescription);
    return ok;
}

static NSString *ZPFormatMinSec(double secs) {
    if (!(secs > 0)) return @"–:––";
    int t = (int)llround(secs);
    int m = t / 60, s = t % 60;
    return [NSString stringWithFormat:@"%d:%02d", m, s];
}

// Base64 (ainda aqui caso precises noutras vias)
//static NSString *ZPBase64(NSData *d) { return d ? [d base64EncodedStringWithOptions:0] : @""; }

#pragma mark - Metadados WavPack (inclui capa e duração)

static NSDictionary *ZPExtractWavPackMetadata(NSString *path) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];

    char error[80]={0};
    WavpackContext *ctx = WavpackOpenFileInput(path.UTF8String, error, OPEN_TAGS, 0);
    if (!ctx) return info;

    int size=0;
#define EXTRACT(tag,key) do{ size=WavpackGetTagItem(ctx,tag,NULL,0); if(size>0){\
char *buf=(char*)malloc(size+1); if(buf){ WavpackGetTagItem(ctx,tag,buf,size+1);\
info[@key]=[NSString stringWithUTF8String:buf]?:@""; free(buf);} } }while(0)
    EXTRACT("Title","title");
    EXTRACT("Artist","artist");
    EXTRACT("Album","album");
#undef EXTRACT

    // Capa (Cover Art (Front)) — dados binários depois do mime\0
    size = WavpackGetBinaryTagItem(ctx, "Cover Art (Front)", NULL, 0);
    if (size > 0) {
        void *bin = malloc(size);
        if (bin) {
            WavpackGetBinaryTagItem(ctx, "Cover Art (Front)", bin, size);
            unsigned char *p = bin; while (*p) p++; p++; // salta mime\0
            size_t dataSize = size - (size_t)(p - (unsigned char*)bin);
            if ((ptrdiff_t)dataSize > 0) info[@"cover"] = [NSData dataWithBytes:p length:dataSize];
            free(bin);
        }
    }

    // Técnicos
    uint32_t ns  = WavpackGetNumSamples(ctx);
    int sr       = WavpackGetSampleRate(ctx);
    int ch       = WavpackGetNumChannels(ctx);
    int bps      = WavpackGetBitsPerSample(ctx);
    if (sr > 0)      info[@"sampleRate"] = @(sr);
    if (ch > 0)      info[@"channels"]   = @(ch);
    if (bps > 0)     info[@"bits"]       = @(bps);
    if (ns != (uint32_t)-1 && sr > 0) {
        double dur = (double)ns / (double)sr;
        info[@"durationSec"] = @(dur);
        info[@"durationStr"] = ZPFormatMinSec(dur);
    }

    WavpackCloseFile(ctx);
    return info;
}

#pragma mark - Decodificação para WAV 16-bit (snippet com limite)

static BOOL ZPDecodeWavPackToWaveAtPathWithLimit(NSString *srcPath, NSString *dstPath, double maxSeconds) {
    char error[80] = {0};
    WavpackContext *ctx = WavpackOpenFileInput(srcPath.UTF8String, error, 0, 0);
    if (!ctx) return NO;

    const int numChannels = WavpackGetNumChannels(ctx);
    const int sampleRate  = WavpackGetSampleRate(ctx);
    const int bps_src     = WavpackGetBitsPerSample(ctx);  // <= AQUI
    if (numChannels <= 0 || sampleRate <= 0 || bps_src <= 0) { WavpackCloseFile(ctx); return NO; }

    const int bytesPerSample = 2; // saída 16-bit PCM
    uint64_t maxFrames = (maxSeconds > 0) ? (uint64_t)llround(maxSeconds * (double)sampleRate) : UINT64_MAX;

    FILE *f = fopen(dstPath.UTF8String, "wb");
    if (!f) { WavpackCloseFile(ctx); return NO; }

    // Cabeçalho WAV (placeholders)
    fwrite("RIFF",1,4,f); uint32_t riffSize=0; fwrite(&riffSize,4,1,f);
    fwrite("WAVEfmt ",1,8,f);
    uint32_t fmtSize=16; fwrite(&fmtSize,4,1,f);
    uint16_t audioFormat=1, nch=(uint16_t)numChannels, bps=16;
    uint32_t sr=(uint32_t)sampleRate, byteRate=sr*(uint32_t)nch*(uint32_t)bytesPerSample;
    uint16_t blockAlign=(uint16_t)(nch*bytesPerSample);
    fwrite(&audioFormat,2,1,f); fwrite(&nch,2,1,f); fwrite(&sr,4,1,f);
    fwrite(&byteRate,4,1,f);    fwrite(&blockAlign,2,1,f); fwrite(&bps,2,1,f);
    fwrite("data",1,4,f); long dataSizePos=ftell(f); uint32_t dataBytes=0; fwrite(&dataBytes,4,1,f);

    enum { FRAMES = 4096 };
    int32_t *ibuf = (int32_t *)malloc(sizeof(int32_t) * FRAMES * (size_t)numChannels);
    int16_t *obuf = (int16_t *)malloc(sizeof(int16_t) * FRAMES * (size_t)numChannels);
    if (!ibuf || !obuf) { if (ibuf) free(ibuf); if (obuf) free(obuf); fclose(f); WavpackCloseFile(ctx); return NO; }

    // Calcular deslocamento correcto (LSB-aligned)
    // Se bps_src > 16, desloca-se à direita com arredondamento; se <16, à esquerda.
    const int shift = bps_src - 16;

    uint64_t totalFrames = 0;
    while (totalFrames < maxFrames) {
        int32_t want = (int32_t)MIN((uint64_t)FRAMES, maxFrames - totalFrames);
        int32_t got  = WavpackUnpackSamples(ctx, ibuf, want); // frames por canal
        if (got <= 0) break;

        const uint32_t N = (uint32_t)got * (uint32_t)numChannels;

        if (shift > 0) {
            const int add = 1 << (shift - 1); // arredondar
            for (uint32_t i = 0; i < N; ++i) {
                int32_t y = (ibuf[i] + (ibuf[i] >= 0 ? add : -add)) >> shift;
                if (y >  32767) y =  32767;
                if (y < -32768) y = -32768;
                obuf[i] = (int16_t)y;
            }
        } else if (shift < 0) {
            const int l = -shift;
            for (uint32_t i = 0; i < N; ++i) {
                int32_t y = ibuf[i] << l;
                if (y >  32767) y =  32767;
                if (y < -32768) y = -32768;
                obuf[i] = (int16_t)y;
            }
        } else {
            // bps_src == 16 → cast directo
            for (uint32_t i = 0; i < N; ++i) {
                int32_t y = ibuf[i];
                if (y >  32767) y =  32767;
                if (y < -32768) y = -32768;
                obuf[i] = (int16_t)y;
            }
        }

        fwrite(obuf, sizeof(int16_t), N, f);
        totalFrames += (uint64_t)got;
    }

    free(ibuf); free(obuf);

    uint64_t finalDataBytes64 = totalFrames * (uint64_t)numChannels * (uint64_t)bytesPerSample;
    uint32_t finalDataBytes   = (finalDataBytes64 > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)finalDataBytes64;
    uint32_t finalRiffSize    = 36 + finalDataBytes;

    fflush(f);
    fseek(f, 4, SEEK_SET);           fwrite(&finalRiffSize, 4, 1, f);
    fseek(f, dataSizePos, SEEK_SET); fwrite(&finalDataBytes, 4, 1, f);
    fflush(f); fclose(f);
    WavpackCloseFile(ctx);
    return YES;
}

#pragma mark - ZPwvPreviewProvider

@implementation ZPwvPreviewProvider

static inline NSString *ZPQLTempRoot(void) {
    return NSTemporaryDirectory();
}

#pragma mark - Ciclo de vida

+ (void)load {
    os_log_error(ZPLog(), "➡️ versão 3 — +load ZPwvPreviewProvider");
}
- (instancetype)init {
    self = [super init];
    os_log_error(ZPLog(), "➡️ versão 3 — init %@", self);
    return self;
}
/// (extra: se o QL te chamar no modo view-based por engano)
- (void)preparePreviewOfFileAtURL:(NSURL *)url completionHandler:(void (^)(NSError * _Nullable))handler {
    os_log_error(ZPLog(), "➡️ versão 3 — ENTER preparePreviewOfFileAtURL path=%@", url.path);
    handler(nil);
}

- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                   completionHandler:(void (^)(QLPreviewReply * _Nullable reply, NSError * _Nullable error))handler
{
    os_log_error(ZPLog(), "➡️ versão 3 — ENTER providePreviewForFileRequest path=%@", request.fileURL.path);

    NSURL *url = request.fileURL;

    // Em QL no macOS 12, a URL normalmente não é security-scoped. Nunca falhar por isto.
    BOOL didScope = NO;
    if ([url respondsToSelector:@selector(startAccessingSecurityScopedResource)]) {
        didScope = [url startAccessingSecurityScopedResource];
        os_log(ZPLog(), "securityScoped=%{public}d", didScope);
    }

    void (^Finish)(QLPreviewReply * _Nullable, NSError * _Nullable) =
    ^(QLPreviewReply * _Nullable r, NSError * _Nullable e){
        os_log(ZPLog(), "➡️ versão 3 — LEAVE providePreviewForFileRequest (reply=%{public}@, err=%{public}@)",
               r ? @"YES" : @"NO", e.localizedDescription ?: @"nil");
        if (didScope) [url stopAccessingSecurityScopedResource];
        handler(r, e);
    };

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            @try {
                // --- Metadados e directórios temporários ---
                NSDictionary *meta = ZPExtractWavPackMetadata(url.path);

                NSString *baseDir = ZPQLTempRoot();
                NSString *sessionDir = [baseDir stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
                if (!ZPEnsureDir(sessionDir)) {
                    Finish(nil, [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteUnknownError userInfo:nil]);
                    return;
                }

                // --- Decodificar snippet WAV temporário ---
                NSString *wavAbs = [sessionDir stringByAppendingPathComponent:@"track.wav"];
                const double kMaxPreviewSeconds = 20.0;
                if (!ZPDecodeWavPackToWaveAtPathWithLimit(url.path, wavAbs, kMaxPreviewSeconds)) {
                    // Fallback: HTML curtinho (sem áudio)
                    NSString *html = @"<!doctype html><meta charset='utf-8'><title>WV</title>"
                                     "<body style='font:16px -apple-system;padding:24px'>"
                                     "<p>WV preview indisponível (decode falhou).</p></body>";
                    QLPreviewReply *r = nil;
                    if ([QLPreviewReply respondsToSelector:@selector(previewReplyWithData:contentType:)]) {
                        NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
                        r = [QLPreviewReply previewReplyWithData:htmlData
                                                     contentType:[UTType typeWithIdentifier:@"public.html"]];
                    } else {
                        NSString *htmlAbs = [sessionDir stringByAppendingPathComponent:@"index.html"];
                        [html writeToFile:htmlAbs atomically:YES encoding:NSUTF8StringEncoding error:nil];
                        if ([QLPreviewReply respondsToSelector:@selector(previewReplyWithFileURL:contentType:)]) {
                            r = [QLPreviewReply previewReplyWithFileURL:[NSURL fileURLWithPath:htmlAbs]
                                                            contentType:@"public.html"];
                        } else if ([QLPreviewReply respondsToSelector:@selector(previewReplyWithFileURL:)]) {
                            r = [QLPreviewReply previewReplyWithFileURL:[NSURL fileURLWithPath:htmlAbs]];
                        }
                    }
                    Finish(r, nil);
                    return;
                }

                // --- Metadados apresentados ---
                NSString *title  = meta[@"title"]  ?: url.lastPathComponent;
                NSString *artist = meta[@"artist"] ?: @"";
                NSString *album  = meta[@"album"]  ?: @"";
                NSString *durStr = meta[@"durationStr"] ?: @"–:––";
                BOOL hasCover    = (meta[@"cover"] != nil);

                if (@available(macOS 13, *)) {
                    // ---------- 13+: HTML com attachments (capa + controlos personalizados) ----------
                    NSMutableString *html = [NSMutableString string];
                    [html appendString:
                     @"<!doctype html><html lang=\"pt\"><head><meta charset=\"utf-8\">"
                     "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
                     "<title>Pré-visualização</title>"
                     "<style>"
                     ":root{--bg:#1f1f1f;--fg:#e6e6e6;--muted:#a0a0a0;--card:#2a2a2a;--shadow:rgba(0,0,0,.3)}"
                     "@media (prefers-color-scheme: light){:root{--bg:#fff;--fg:#111;--muted:#666;--card:#f4f4f4;--shadow:rgba(0,0,0,.12)}}"
                     "html,body{height:100%} body{margin:0;background:var(--bg);color:var(--fg);font:15px -apple-system,system-ui}"
                     ".wrap{max-width:920px;margin:0 auto;padding:24px}"
                     ".pane{display:grid;grid-template-columns: 320px 1fr;gap:24px;align-items:start}"
                     ".art img{width:100%;height:auto;border-radius:12px;box-shadow:0 10px 30px var(--shadow);background:#000}"
                     ".title{font-size:28px;font-weight:700;line-height:1.2;margin:4px 0 8px}"
                     ".kv{margin:6px 0 14px} .kv dt{color:var(--muted);float:left;min-width:106px} .kv dd{margin:0 0 4px 110px;font-weight:600}"
                     ".meta{color:var(--muted);font-size:13px}"
                     ".bar{position:sticky;bottom:0;margin-top:18px}"
                     ".controls{display:flex;align-items:center;gap:10px;background:var(--card);border-radius:14px;padding:10px 12px;box-shadow:0 8px 24px var(--shadow)}"
                     ".btn{appearance:none;border:0;background:transparent;font:inherit;color:var(--fg);cursor:pointer;padding:6px 10px;border-radius:8px}"
                     ".btn:active{transform:translateY(1px)}"
                     ".time{min-width:90px;text-align:center;font-variant-numeric:tabular-nums;color:var(--muted)}"
                     ".range{flex:1} input[type=range]{width:100%}"
                     "</style></head><body><div class=\"wrap\"><div class=\"pane\">"];

                    if (hasCover) {
                        [html appendString:@"<div class='art'><img src='cid:cover' alt='capa'></div>"];
                    } else {
                        [html appendString:@"<div class='art'><div style='width:100%;aspect-ratio:1/1;border-radius:12px;background:#000'></div></div>"];
                    }

                    [html appendFormat:
                     @"<div class='info'>"
                     @"<div class='title'>%@</div>"
                     @"<dl class='kv'>"
                     @"<dt>Intérprete:</dt><dd>%@</dd>"
                     @"<dt>Álbum:</dt><dd>%@</dd>"
                     @"<dt>Duração:</dt><dd>%@</dd>"
                     @"</dl>"
                     @"<div class='meta'>%@ • %@-bit • %@ canais</div>"
                     @"</div>",
                     ZPHTMLEscape(title),
                     ZPHTMLEscape(artist.length?artist:@"—"),
                     ZPHTMLEscape(album.length?album:@"—"),
                     ZPHTMLEscape(durStr),
                     meta[@"sampleRate"]? [NSString stringWithFormat:@"%@ Hz", meta[@"sampleRate"]]:@"",
                     meta[@"bits"]?:@"",
                     meta[@"channels"]?:@""
                    ];

                    [html appendString:
                     @"</div>"
                     @"<div class='bar'><div class='controls'>"
                     @"<button class='btn' id='back' title='Recuar 15s'>⟲15</button>"
                     @"<button class='btn' id='play' title='Reproduzir/Pausar'>▶︎</button>"
                     @"<button class='btn' id='fwd'  title='Avançar 15s'>15⟳</button>"
                     @"<span class='time' id='tcur'>00:00</span>"
                     @"<input class='range' id='seek' type='range' min='0' max='1000' value='0' step='1'>"
                     @"<span class='time' id='tmax'>"];
                    [html appendString: ZPHTMLEscape(durStr)];
                    [html appendString:
                     @"</span>"
                     @"<input class='range' id='vol' type='range' min='0' max='1' value='1' step='0.01' style='max-width:120px'>"
                     @"</div></div>"
                     @"<audio id='player' preload='metadata' src='cid:track'></audio>"
                     @"</div>"
                     @"<script>"
                     @"const a=document.getElementById('player'), play=document.getElementById('play'), b=document.getElementById('back'), f=document.getElementById('fwd');"
                     @"const cur=document.getElementById('tcur'), max=document.getElementById('tmax'), seek=document.getElementById('seek'), vol=document.getElementById('vol');"
                     @"function mmss(x){if(!(x>0))return'00:00';x|=0;const m=(x/60)|0,s=x%60;return m+':'+String(s).padStart(2,'0')}"
                     @"a.addEventListener('loadedmetadata',()=>{ if(isFinite(a.duration)){ max.textContent=mmss(a.duration); } });"
                     @"a.addEventListener('timeupdate',()=>{cur.textContent=mmss(a.currentTime); if(isFinite(a.duration)){ seek.value = (a.currentTime/a.duration*1000)|0; }});"
                     @"seek.addEventListener('input',()=>{ if(isFinite(a.duration)){ a.currentTime = seek.value/1000*a.duration; }});"
                     @"vol.addEventListener('input',()=>{ a.volume = vol.value; });"
                     @"play.addEventListener('click',async()=>{ if(a.paused){ try{ await a.play(); play.textContent='❚❚'; }catch(e){} } else { a.pause(); play.textContent='▶︎'; }});"
                     @"b.addEventListener('click',()=>{ a.currentTime=Math.max(0,a.currentTime-15); });"
                     @"f.addEventListener('click',()=>{ if(isFinite(a.duration)) a.currentTime=Math.min(a.duration,a.currentTime+15); });"
                     @"</script></body></html>"];

                    QLPreviewReply *reply = nil;
                    if ([QLPreviewReply respondsToSelector:@selector(previewReplyWithData:contentType:)]) {
                        NSData *htmlData = [html dataUsingEncoding:NSUTF8StringEncoding];
                        reply = [QLPreviewReply previewReplyWithData:htmlData
                                                         contentType:[UTType typeWithIdentifier:@"public.html"]];
                    }

                    if (reply) {
                        NSMutableDictionary<NSString *, QLPreviewReplyAttachment *> *atts = [NSMutableDictionary dictionary];

                        // WAV
                        NSData *wavData = [NSData dataWithContentsOfFile:wavAbs options:NSDataReadingMappedIfSafe error:nil];
                        if (!wavData) wavData = [NSData dataWithContentsOfFile:wavAbs];
                        if (wavData) {
                            QLPreviewReplyAttachment *aw = [(QLPreviewReplyAttachment *)[QLPreviewReplyAttachment alloc]
                                                            initWithData:wavData
                                                            contentType:[UTType typeWithIdentifier:@"com.microsoft.waveform-audio"]];
                            if (aw) atts[@"track"] = aw;
                        }

                        // Capa
                        if (hasCover) {
                            NSData *cov = (NSData *)meta[@"cover"];
                            const unsigned char *b = cov.bytes;
                            UTType *typeCover = [UTType typeWithIdentifier:@"public.jpeg"];
                            if (cov.length >= 8 && b[0]==0x89 && b[1]==0x50 && b[2]==0x4E && b[3]==0x47) {
                                typeCover = [UTType typeWithIdentifier:@"public.png"];
                            } else if (cov.length >= 6 && !memcmp(b, "GIF89a", 6)) {
                                typeCover = [UTType typeWithIdentifier:@"com.compuserve.gif"];
                            }
                            QLPreviewReplyAttachment *ac = [(QLPreviewReplyAttachment *)[QLPreviewReplyAttachment alloc]
                                                            initWithData:cov contentType:typeCover];
                            if (ac) atts[@"cover"] = ac;
                        }

                        reply.attachments = atts;
                        Finish(reply, nil);
                        return;
                    }
                    // Se não conseguires o modo "data", cai no caminho 12 abaixo
                }

                // ---------- macOS 12: tentar UI nativo (se existir esse selector no runtime) ----------
                QLPreviewReply *reply12 = nil;

                BOOL hasNativeAudioUI =
                [QLPreviewReply respondsToSelector:@selector(previewReplyWithAudioFileURL:title:artist:album:artworkURL:)];
                os_log(ZPLog(), "hasNativeAudioUI=%{public}d", hasNativeAudioUI);

                if (hasNativeAudioUI) {
                    NSURL *artURL = nil;
                    if (hasCover) {
                        // escrever capa para ficheiro (jpg/png/gif) para o UI nativo
                        NSData *cov = (NSData *)meta[@"cover"];
                        const unsigned char *b = cov.bytes;
                        NSString *ext = @"jpg";
                        if (cov.length >= 8 && b[0]==0x89 && b[1]==0x50 && b[2]==0x4E && b[3]==0x47) ext = @"png";
                        else if (cov.length >= 6 && !memcmp(b, "GIF89a", 6)) ext = @"gif";
                        NSString *coverAbs = [sessionDir stringByAppendingPathComponent:[@"cover." stringByAppendingString:ext]];
                        [cov writeToFile:coverAbs atomically:YES];
                        artURL = [NSURL fileURLWithPath:coverAbs];
                    }
                    reply12 = [QLPreviewReply previewReplyWithAudioFileURL:[NSURL fileURLWithPath:wavAbs]
                                                                     title:title ?: @""
                                                                    artist:artist ?: @""
                                                                     album:album ?: @""
                                                                artworkURL:artURL];
                }

                if (!reply12 && [QLPreviewReply respondsToSelector:@selector(previewReplyWithFileURL:contentType:)]) {
                    reply12 = [QLPreviewReply previewReplyWithFileURL:[NSURL fileURLWithPath:wavAbs]
                                                          contentType:@"com.microsoft.waveform-audio"];
                }
                if (!reply12 && [QLPreviewReply respondsToSelector:@selector(previewReplyWithFileURL:)]) {
                    reply12 = [QLPreviewReply previewReplyWithFileURL:[NSURL fileURLWithPath:wavAbs]];
                }

                if (reply12) {
                    Finish(reply12, nil);
                    return;
                }

                // ---------- macOS 12: fallback leve — HTML a referenciar ficheiros locais ----------
                // Escrever capa para ficheiro ao lado do HTML (se existir)
                NSString *coverRel = nil;
                if (hasCover) {
                    NSData *cov = (NSData *)meta[@"cover"];
                    const unsigned char *b = cov.bytes;
                    NSString *ext = @"jpg";
                    if (cov.length >= 8 && b[0]==0x89 && b[1]==0x50 && b[2]==0x4E && b[3]==0x47) ext = @"png";
                    else if (cov.length >= 6 && !memcmp(b, "GIF89a", 6)) ext = @"gif";
                    coverRel = [@"cover." stringByAppendingString:ext];
                    NSString *coverAbs = [sessionDir stringByAppendingPathComponent:coverRel];
                    [cov writeToFile:coverAbs atomically:YES];
                }

                // HTML pequeno, com caminhos relativos (track.wav e cover.xxx)
                NSMutableString *html = [NSMutableString string];
                [html appendFormat:
                 @"<!doctype html><meta charset='utf-8'><title>%@</title>"
                 @"<body style='margin:0;background:#111;color:#eee;font:15px -apple-system,system-ui'>"
                 @"<div style='max-width:920px;margin:0 auto;padding:24px'>"
                 @"<div style='display:grid;grid-template-columns:320px 1fr;gap:24px;align-items:start'>",
                 ZPHTMLEscape(title)];

                if (coverRel) {
                    [html appendFormat:
                     @"<div><img alt='capa' style='width:100%%;height:auto;border-radius:12px;box-shadow:0 10px 30px rgba(0,0,0,.35)' src='%@'></div>",
                     ZPHTMLEscape(coverRel)];
                } else {
                    [html appendString:
                     @"<div><div style='width:100%;aspect-ratio:1/1;border-radius:12px;background:#000'></div></div>"];
                }

                [html appendFormat:
                 @"<div>"
                 @"<div style='font-size:28px;font-weight:700;line-height:1.2;margin:4px 0 8px'>%@</div>"
                 @"<div style='color:#aaa;margin-bottom:8px'>%@ — %@ · %@</div>"
                 @"<audio controls preload='metadata' style='width:100%%;display:block;margin-top:12px' src='track.wav'></audio>"
                 @"<div style='color:#888;font-size:13px;margin-top:8px'>A pré-visualização é um excerto.</div>"
                 @"</div></div></div></body>",
                 ZPHTMLEscape(title),
                 ZPHTMLEscape(artist.length?artist:@"—"),
                 ZPHTMLEscape(album.length?album:@"—"),
                 ZPHTMLEscape(durStr)];

                NSString *htmlAbs = [sessionDir stringByAppendingPathComponent:@"index.html"];
                [html writeToFile:htmlAbs atomically:YES encoding:NSUTF8StringEncoding error:nil];

                QLPreviewReply *r = nil;
                if ([QLPreviewReply respondsToSelector:@selector(previewReplyWithFileURL:contentType:)]) {
                    r = [QLPreviewReply previewReplyWithFileURL:[NSURL fileURLWithPath:htmlAbs] contentType:@"public.html"];
                } else if ([QLPreviewReply respondsToSelector:@selector(previewReplyWithFileURL:)]) {
                    r = [QLPreviewReply previewReplyWithFileURL:[NSURL fileURLWithPath:htmlAbs]];
                }
                Finish(r, nil);
                return;

            } @catch (NSException *ex) {
                os_log_error(ZPLog(), "➡️ versão 3 — EXCEPTION: %{public}@", ex.reason);
                NSError *err = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:NSFileReadUnknownError
                                               userInfo:@{ NSLocalizedDescriptionKey : ex.reason ?: @"Exception" }];
                Finish(nil, err);
                return;
            }
        }
    });
}

@end
