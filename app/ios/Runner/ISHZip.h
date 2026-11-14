//  ISHZip.h
//  dsh-go — Stage 2 native bridge layer (design §3, step 2.1/2.2).
//
//  Raw-deflate helper for the rootfs installer (ZIP entries use
//  method 8 = raw deflate). Thin wrapper over libz (libz.tbd).
//  Ported from the Stage 1 prototype (ISHCoexist/ISHZip.h) unchanged
//  except for this header comment.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Inflate raw deflate data (no zlib header) into `dst`.
/// Returns 0 on success and writes the inflated length to `outLen`;
/// -1 if the destination is too small, -2 on a zlib error.
int ish_zip_inflate_raw(const uint8_t *src, size_t srcLen,
                        uint8_t *dst, size_t dstCapacity,
                        size_t *outLen);

NS_ASSUME_NONNULL_END
