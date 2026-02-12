//
//  ImportExtension.h
//  ZPSpotLightwv
//
//  Created by J. Pedro Sousa do Amaral on 09/08/2026.
//
#import <objc/runtime.h>
#import "ImportExtension.h"
#import <Foundation/Foundation.h>
#import <CoreSpotlight/CoreSpotlight.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <os/log.h>
#include <math.h> // llround

// Evitar colisão de nomes com outros headers
#define ChunkHeader WavPackChunkHeader
#import <wavpack/wavpack.h>
#undef ChunkHeader

@implementation ZPwvImportExtension

#pragma mark - Log

static os_log_t ZPLog(void) {
    static os_log_t l; static dispatch_once_t once;
    dispatch_once(&once, ^{ l = os_log_create("JPSdA.tocaTintas.ZPSpotLightwv", "import"); });
    return l;
}

#pragma mark - CSImportExtension

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130000
// 13+ (compilas com 13.1): expõe as variantes com UTType*.
// No 12.x nunca serão chamadas, mas é correcto tê-las disponíveis.
- (BOOL)updateAttributes:(CSSearchableItemAttributeSet *)attrs
            forFileAtURL:(NSURL *)url
             contentType:(UTType * _Nullable)contentType
                   error:(NSError **)error API_AVAILABLE(macos(13.0))
{
    os_log(ZPLog(), "🧪 contentType SYNC ct=%{public}@", contentType.identifier);
    return [self zp_handleUpdate:attrs url:url contentType:contentType error:error];
}

- (void)updateAttributes:(CSSearchableItemAttributeSet *)attrs
            forFileAtURL:(NSURL *)url
             contentType:(UTType *)contentType
       completionHandler:(void (^)(NSError * _Nullable))completion API_AVAILABLE(macos(13.0))
{
    os_log(ZPLog(), "🧪 contentType ASYNC ct=%{public}@", contentType.identifier);
    NSError *err = nil;
    (void)[self updateAttributes:attrs forFileAtURL:url contentType:contentType error:&err];
    if (completion) completion(err);
}
#else
// SDK < 13: só aqui existiria a variante com 'id' (NÃO é o teu caso).
- (void)updateAttributes:(CSSearchableItemAttributeSet *)attrs
            forFileAtURL:(NSURL *)url
             contentType:(id)contentType
       completionHandler:(void (^)(NSError * _Nullable))completion
{
    NSError *err = nil;
    NSString *tid = nil;
    if ([contentType isKindOfClass:[NSString class]]) tid = (NSString *)contentType;
    else if ([contentType respondsToSelector:@selector(identifier)]) tid = [contentType valueForKey:@"identifier"];
    (void)[self updateAttributes:attrs forFileAtURL:url typeIdentifier:tid error:&err];
    if (completion) completion(err);
}
#endif

// Síncrona: typeIdentifier → bridge para UTType e entra no funil
- (BOOL)updateAttributes:(CSSearchableItemAttributeSet *)attrs
            forFileAtURL:(NSURL *)url
          typeIdentifier:(NSString *)typeIdentifier
                   error:(NSError **)error
{
    os_log(ZPLog(), "🧪 typeId SYNC tid=%{public}@", typeIdentifier);
    UTType *ct = typeIdentifier.length ? [UTType typeWithIdentifier:typeIdentifier] : nil;
    return [self zp_handleUpdate:attrs url:url contentType:ct error:error];
}

// Assíncrona: typeIdentifier → embrulha a síncrona
- (void)updateAttributes:(CSSearchableItemAttributeSet *)attrs
            forFileAtURL:(NSURL *)url
          typeIdentifier:(NSString *)typeIdentifier
       completionHandler:(void (^)(NSError * _Nullable))completion
{
    NSError *err = nil;
    (void)[self updateAttributes:attrs forFileAtURL:url typeIdentifier:typeIdentifier error:&err];
    if (completion) completion(err);
}

// Opcional: sem tipo (fallback raro)
- (BOOL)updateAttributes:(CSSearchableItemAttributeSet *)attrs
            forFileAtURL:(NSURL *)url
                   error:(NSError **)error
{
    return [self zp_handleUpdate:attrs url:url contentType:nil error:error];
}

+ (void)load {
    os_log(ZPLog(), "☑️ +load (bundle carregado)");
}

static NSString *ZPClamp(NSString *s, NSUInteger cap) {
    if (!s) return nil;
    if (s.length <= cap) return s;
    return [[s substringToIndex:cap] stringByAppendingString:@"…"];
}

static void ZPLogAttrs(CSSearchableItemAttributeSet *a, NSURL *u) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];

    if (u) d[@"_file"] = u.lastPathComponent ?: u.path;

    // contentType pode ser NSString (UTI) ou UTType, dependendo do SDK
    id ct = a.contentType;
    if (ct) {
        if ([ct isKindOfClass:[UTType class]]) {
            d[@"contentType"] = ((UTType *)ct).identifier;
        } else if ([ct isKindOfClass:[NSString class]]) {
            d[@"contentType"] = (NSString *)ct; // já é o UTI
        }
    }

    // Strings “clamped”
    if (a.title)        d[@"title"]        = ZPClamp(a.title,        200);
    if (a.artist)       d[@"artist"]       = ZPClamp(a.artist,       200);
    if (a.album)        d[@"album"]        = ZPClamp(a.album,        200);
    if (a.composer)     d[@"composer"]     = ZPClamp(a.composer,     200);
    if (a.musicalGenre) d[@"musicalGenre"] = ZPClamp(a.musicalGenre, 120);

    // Numéricos (apenas se presentes)
    if (a.audioTrackNumber)   d[@"audioTrackNumber"]   = a.audioTrackNumber;
    if (a.duration)           d[@"duration"]           = a.duration;
    if (a.audioSampleRate)    d[@"audioSampleRate"]    = a.audioSampleRate;
    if (a.audioChannelCount)  d[@"audioChannelCount"]  = a.audioChannelCount;
    if (a.audioBitRate)       d[@"audioBitRate"]       = a.audioBitRate;

    if (a.keywords.count)     d[@"keywords"]           = a.keywords;
    if (a.thumbnailData)      d[@"thumbnailData.bytes"]= @(a.thumbnailData.length);

    NSError *e = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:d options:0 error:&e];
    if (json) {
        os_log(ZPLog(), "📦 ATTRS %{public}@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    } else {
        os_log(ZPLog(), "📦 ATTRS (fallback) %{public}@", d);
    }
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)ctx
{
    [super beginRequestWithExtensionContext:ctx];
    os_log(ZPLog(), "➡️ versão 4 — beginRequestWithExtensionContext: %{public}@", ctx);

    // Selectors that exist in some SDKs but not others:
    SEL selNoCT   = @selector(updateAttributes:forFileAtURL:error:);
    SEL selWithCT = NSSelectorFromString(@"updateAttributes:forFileAtURL:contentType:error:");
    SEL selTypeId = @selector(updateAttributes:forFileAtURL:typeIdentifier:error:);
    SEL selAsync  = NSSelectorFromString(@"updateAttributes:forFileAtURL:typeIdentifier:completionHandler:");

    os_log(ZPLog(), "➡️ versão 4 — respondsTo noCT=%d withCT=%d typeId=%d typeIdAsync=%d",
          (int)[self respondsToSelector:selNoCT],
          (int)[self respondsToSelector:selWithCT],
          (int)[self respondsToSelector:selTypeId],
          (int)[self respondsToSelector:selAsync]);

    SEL s1 = @selector(updateAttributes:forFileAtURL:error:);
    SEL s2 = @selector(updateAttributes:forFileAtURL:typeIdentifier:error:);

    Method m1 = class_getInstanceMethod([ZPwvImportExtension class], s1);
    Method m2 = class_getInstanceMethod([ZPwvImportExtension class], s2);

    // Confirma se ESTÁS a fazer override (compara IMP com a superclasse):
    IMP i1      = class_getMethodImplementation([ZPwvImportExtension class], s1);
    IMP i1super = class_getMethodImplementation([CSImportExtension class],     s1);

    os_log(ZPLog(), "➡️ versão 4 — reflect m1=%p m2=%p imp=%p super=%p overridden=%{public}s",
          m1, m2, i1, i1super, (i1 && i1 != i1super) ? "YES" : "NO");
    
    NSBundle *b = [NSBundle bundleForClass:self.class];
    os_log(ZPLog(), "➡️ versão 4 — CSSupportedContentTypes=%{public}@",
          [b.infoDictionary valueForKeyPath:@"NSExtension.NSExtensionAttributes.CSSupportedContentTypes"]);
}

#pragma mark - Limites

static const size_t kMaxTagBytes   = 16 * 1024;        // por item de texto
static const size_t kMaxCoverBytes = 20 * 1024 * 1024; // capa embutida
static const int    kMaxKeywords   = 12;

#pragma mark - Helpers

static NSString *WVTagStringCapped(WavpackContext *wpc, const char *name) {
    int size = WavpackGetTagItem(wpc, name, NULL, 0);
    if (size <= 0) return nil;
    if ((size_t)size > kMaxTagBytes) size = (int)kMaxTagBytes;
    char *buf = (char *)malloc((size_t)size + 1);
    if (!buf) return nil;
    if (WavpackGetTagItem(wpc, name, buf, size + 1) <= 0) { free(buf); return nil; }
    buf[size] = '\0';
    NSString *s = [[NSString alloc] initWithUTF8String:buf];
    free(buf);
    return s.length ? s : nil;
}

static NSData *WVFrontCoverDataCapped(WavpackContext *wpc) {
    int tagSize = WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", NULL, 0);
    if (tagSize <= 0) return nil;
    if ((size_t)tagSize > kMaxCoverBytes) {
        os_log(ZPLog(), "⚠️ capa embutida >%zu bytes; ignorada", kMaxCoverBytes);
        return nil;
    }
    void *binary = malloc((size_t)tagSize);
    if (!binary) return nil;
    NSData *result = nil;
    if (WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", binary, tagSize) > 0) {
        unsigned char *p = (unsigned char *)binary, *base = (unsigned char *)binary;
        while ((size_t)(p - base) < (size_t)tagSize && *p) p++;
        if ((size_t)(p - base) < (size_t)tagSize) p++; // saltar NUL
        size_t used = (size_t)(p - base);
        if (used < (size_t)tagSize) result = [NSData dataWithBytes:p length:(size_t)tagSize - used];
    }
    free(binary);
    return result;
}

static NSNumber *ParseTrackNumberCapped(NSString *raw) {
    if (raw.length == 0) return nil;
    NSScanner *sc = [NSScanner scannerWithString:raw];
    NSInteger n = 0;
    if ([sc scanInteger:&n] && n >= 0 && n < 10000) return @(n);
    return nil;
}

#pragma mark - Core

- (BOOL)zp_handleUpdate:(CSSearchableItemAttributeSet *)attributes
                    url:(NSURL *)contentURL
            contentType:(UTType * _Nullable)contentType
                  error:(NSError **)error
{
    @autoreleasepool {
        // Deduz o tipo se vier nil (passagem interna totalmente dentro da classe)
        if (!contentType) {
            NSString *ext = contentURL.pathExtension.lowercaseString;
            if (ext.length) contentType = [UTType typeWithFilenameExtension:ext];
        }

        NSString *ctid = nil;
        if (contentType && [contentType isKindOfClass:[UTType class]]) {
            ctid = [(UTType *)contentType identifier];
        }
        os_log(ZPLog(), "⭐️ updateAttributes UTType=%{public}@ url=%{public}s",
              ctid ?: @"(nil)", contentURL.fileSystemRepresentation);

        // Passagem permissiva
        if (![[contentURL.pathExtension lowercaseString] isEqualToString:@"wv"]) {
            os_log(ZPLog(), "⏭️ ignorado: não é .wv (ct=%{public}@, ext=%{public}@)",
                      contentType.identifier, contentURL.pathExtension);
            return YES; // só processa .wv
        }

        BOOL scoped = [contentURL startAccessingSecurityScopedResource];
        if (!scoped) {
            os_log(ZPLog(), "⚠️ startAccessingSecurityScopedResource devolveu NO");
        }

        @try {
            NSNumber *fileSizeNum = nil;
            (void)[contentURL getResourceValue:&fileSizeNum forKey:NSURLFileSizeKey error:NULL];

            char errbuf[96] = {0};
            WavpackContext *wpc = WavpackOpenFileInput(contentURL.fileSystemRepresentation, errbuf, OPEN_TAGS, 0);
            if (!wpc) {
                os_log(ZPLog(), "❌ WavpackOpen falhou: %s", errbuf);
                if (error) {
                    *error = [NSError errorWithDomain:@"ZPwvImportExtension"
                                                 code:1
                                             userInfo:@{NSLocalizedDescriptionKey:
                                                            [NSString stringWithFormat:@"WavPack open failed: %s", errbuf]}];
                }
                return NO;
            }

            NSString *artist   = WVTagStringCapped(wpc, "Artist");
            NSString *album    = WVTagStringCapped(wpc, "Album");
            NSString *title    = WVTagStringCapped(wpc, "Title");
            NSString *genre    = WVTagStringCapped(wpc, "Genre");
            NSString *composer = WVTagStringCapped(wpc, "Composer");
            NSString *trackStr = WVTagStringCapped(wpc, "Track");

            if (title.length == 0)  title  = contentURL.lastPathComponent.stringByDeletingPathExtension;
            if (artist.length == 0) artist = @"Unknown Artist";
            if (album.length  == 0) album  = @"Unknown Album";

            uint32_t sr      = WavpackGetSampleRate(wpc);
            uint32_t ch      = WavpackGetNumChannels(wpc);
            uint32_t samples = WavpackGetNumSamples(wpc);
            double duration  = (samples != (uint32_t)-1 && sr > 0) ? ((double)samples/(double)sr) : 0.0;

            NSNumber *bitrateNum = nil;
            if (duration > 0.0 && fileSizeNum.unsignedLongLongValue > 0ULL) {
                double bits = (double)fileSizeNum.unsignedLongLongValue * 8.0;
                long long br = (long long)llround(bits / duration);
                if (br > 0 && br < (20LL*1000*1000)) bitrateNum = @(br);
            }

            NSData *thumb = WVFrontCoverDataCapped(wpc);
            NSString *rg  = WVTagStringCapped(wpc, "replaygain_track_gain");

            WavpackCloseFile(wpc);

            // Atributos
            attributes.title  = title;
            attributes.album  = album;
            attributes.artist = artist;
            if (genre) attributes.musicalGenre = genre;
            if (composer) attributes.composer = composer;
            if (contentType) {
                if (@available(macOS 13.0, *)) {
                    // Em 13+, o setter aceita UTType* — KVC evita o erro de tipo em compile-time
                    [attributes setValue:contentType forKey:@"contentType"];
                } else {
                    // Em 12.x, o setter espera NSString (UTI)
                    [attributes setValue:contentType.identifier forKey:@"contentType"];
                }
            }

            NSNumber *tn = ParseTrackNumberCapped(trackStr);
            if (tn)             attributes.audioTrackNumber  = tn;
            if (duration > 0.0) attributes.duration          = @(duration);
            if (sr)             attributes.audioSampleRate   = @(sr);
            if (ch)             attributes.audioChannelCount = @(ch);
            if (bitrateNum)     attributes.audioBitRate      = bitrateNum;
            if (thumb.length > 0 && thumb.length <= kMaxCoverBytes) attributes.thumbnailData = thumb;

            NSMutableArray<NSString *> *keys = [NSMutableArray array];
            if (artist) [keys addObject:artist];
            if (album)  [keys addObject:album];
            if (genre)  [keys addObject:genre];
            if (rg)     [keys addObject:rg];
            if (keys.count > kMaxKeywords)
                [keys removeObjectsInRange:NSMakeRange(kMaxKeywords, keys.count - kMaxKeywords)];
            attributes.keywords = keys.count ? keys : nil;

            os_log(ZPLog(), "✅ preenchido: title=%{public}@ artist=%{public}@ album=%{public}@ sr=%u ch=%u dur=%.3f",
                  attributes.title, attributes.artist, attributes.album, sr, ch, duration);
            ZPLogAttrs(attributes, contentURL);
            return YES;
        }
        @finally {
            if (scoped) [contentURL stopAccessingSecurityScopedResource];
        }
    }
}

@end
