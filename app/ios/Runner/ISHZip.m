//  ISHZip.m
//  dsh-go — Stage 2 native bridge layer. See ISHZip.h.
//  Ported from the Stage 1 prototype (ISHCoexist/ISHZip.m) unchanged
//  except for this header comment.
#import "ISHZip.h"
#include <zlib.h>
#include <string.h>

int ish_zip_inflate_raw(const uint8_t *src, size_t srcLen,
                        uint8_t *dst, size_t dstCapacity,
                        size_t *outLen) {
    if (!src || !dst || !outLen) return -2;
    z_stream strm;
    memset(&strm, 0, sizeof(strm));
    strm.next_in = (Bytef *)src;
    strm.avail_in = (uInt)srcLen;
    strm.next_out = dst;
    strm.avail_out = (uInt)dstCapacity;
    // -MAX_WBITS: raw deflate stream, no zlib header (ZIP method 8).
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK) return -2;
    int rc = inflate(&strm, Z_FINISH);
    *outLen = strm.total_out;
    inflateEnd(&strm);
    if (rc == Z_STREAM_END) return 0;
    if (rc == Z_BUF_ERROR) return -1; // destination too small
    return -2;
}
