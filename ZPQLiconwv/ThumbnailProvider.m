//  ThumbnailProvider.m
//  ZPQLiconwv

#import <os/log.h>
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <AVFoundation/AVUtilities.h>
#import "ThumbnailProvider.h"
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

#define ChunkHeader WavPackChunkHeader
#include <wavpack/wavpack.h>
#undef ChunkHeader

@implementation ZPwvThumbnailProvider

#pragma mark - QLThumbnailProvider

- (BOOL)canProvideThumbnailForFileRequest:(QLFileThumbnailRequest *)request {
    NSString *ext = request.fileURL.pathExtension.lowercaseString;
    os_log(OS_LOG_DEFAULT, "[ZPQLiconwv] canProvideThumbnailForFileRequest: ext='%{public}s'",
           ext.UTF8String ?: "nil");
    return [ext isEqualToString:@"wv"];
}

- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                    completionHandler:(void (^)(QLThumbnailReply * _Nullable reply,
                                                NSError * _Nullable error))handler
{
#ifdef DEBUG
    os_log(OS_LOG_DEFAULT,
           "[ZPQLiconwv] provideThumbnailForFileRequest: %{public}s",
           request.fileURL.path.fileSystemRepresentation);
#endif

    // Obter caminho C directamente — Quick Look já concede permissões de leitura
    const char *cpath = request.fileURL.fileSystemRepresentation;

    CGImageRef cgImage = [self newCoverImageFromWavPackAtPath:cpath];
    if (!cgImage) {
        handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadNoSuchFileError
                                     userInfo:nil]);
        return;
    }

    const size_t imageWidth  = CGImageGetWidth(cgImage);
    const size_t imageHeight = CGImageGetHeight(cgImage);
    if (imageWidth == 0 || imageHeight == 0) {
        CGImageRelease(cgImage);
        handler(nil, [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileReadCorruptFileError
                                     userInfo:nil]);
        return;
    }

    CGSize sz = (request.maximumSize.width > 0 && request.maximumSize.height > 0)
              ? request.maximumSize
              : CGSizeMake(256, 256);

    QLThumbnailReply *reply =
    [QLThumbnailReply replyWithContextSize:sz drawingBlock:^BOOL(CGContextRef ctx) {
        // 1) escala retina: 2x em cada eixo (ou o que o sistema pedir)
        CGFloat scale = (request.scale >= 1.0) ? request.scale : 2.0;
        CGContextSaveGState(ctx);
        CGContextScaleCTM(ctx, scale, scale);

        // 2) tudo continua em PONTOS
        CGRect bounds   = CGRectMake(0, 0, sz.width, sz.height);
        CGRect imageBox = AVMakeRectWithAspectRatioInsideRect(
            CGSizeMake(imageWidth, imageHeight), bounds
        );

        // 3) desenha normalmente
        CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
        CGContextFillRect(ctx, bounds);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, imageBox, cgImage);

        CGContextRestoreGState(ctx);
        CGImageRelease(cgImage);
        return YES;
    }];

#ifdef DEBUG
    os_log(OS_LOG_DEFAULT, "[ZPQLiconwv] reply pronto %dx%d",
           (int)sz.width, (int)sz.height);
#endif

    handler(reply, nil);
}

#pragma mark - Helper: extrair capa como CGImage

/// Cria um CGImage da capa "Cover Art (Front)" de um ficheiro WavPack (.wv).
/// Retorna um CGImage **retido** (o chamador deve fazer CGImageRelease), ou NULL.
- (CGImageRef)newCoverImageFromWavPackAtPath:(const char *)cpath {
    char error[80] = {0};
    WavpackContext *wpc = WavpackOpenFileInput(cpath, error, OPEN_TAGS, 0);
    if (!wpc) return NULL;

    uint32_t totalSize = WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", NULL, 0);
    if (totalSize == 0) {
        WavpackCloseFile(wpc);
        return NULL;
    }

    void *raw = malloc(totalSize);
    if (!raw) {
        WavpackCloseFile(wpc);
        return NULL;
    }

    CGImageRef outImage = NULL;

    if (WavpackGetBinaryTagItem(wpc, "Cover Art (Front)", raw, totalSize) > 0) {
        // layout: "mime\0<bytes_da_imagem>"
        unsigned char *p = (unsigned char *)raw;
        // salta o MIME
        while ((p - (unsigned char *)raw) < (ptrdiff_t)totalSize && *p) p++;
        p++; // '\0'

        size_t dataSize = (size_t)((unsigned char *)raw + totalSize - p);
        if (dataSize > 0) {
            CFDataRef data = CFDataCreate(kCFAllocatorDefault, p, dataSize);
            if (data) {
                CGImageSourceRef src = CGImageSourceCreateWithData(data, NULL);
                if (src) {
                    outImage = CGImageSourceCreateImageAtIndex(src, 0, NULL); // retained
                    CFRelease(src);
                }
                CFRelease(data);
            }
        }
    }

    free(raw);
    WavpackCloseFile(wpc);
    return outImage; // pode ser NULL
}

@end
