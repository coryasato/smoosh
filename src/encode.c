// The C side of Smoosh's encoder seam — the one file in the tree that
// speaks the struct-heavy libavif / libwebp encode APIs directly.
//
// `src/encoders.zig` is the mirror of `src/imageio.zig` and follows the
// same "declare the C ABI by hand" rule — but that rule fits an
// opaque-pointer API (ImageIO) and fights a struct-heavy one. `avifEncoder`
// has ~30 caller-mutable fields, `avifRGBImage` is a stack struct filled by
// `avifRGBImageSetDefaults`, and `WebPConfig`/`WebPPicture` are larger
// still; transcribing their layouts into Zig `extern struct`s by hand is a
// silent-miscompile risk with no upside. Instead this shim does the struct
// work in C, against the vendored headers (`third_party/*/include`, wired
// on both modules by `build.zig`), and exposes a flat scalar ABI that
// `encoders.zig` declares in three lines.
//
// Contract for both encode fns: return 0 on success, non-zero on failure.
// On success `*out` is a `malloc`'d buffer of `*out_len` bytes that the
// caller releases with `smoosh_encode_free`. Input is always tightly
// packed 8-bit RGBA, straight (non-premultiplied) alpha, top-down — i.e.
// exactly what `imageio.decode` returns.

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <avif/avif.h>
#include <webp/encode.h>

// Hand back a libc-`free`-able copy so the caller has one release path for
// both encoders (libavif wants `avifRWDataFree`, libwebp wants `WebPFree`).
static int copy_out(const uint8_t *src, size_t len, uint8_t **out, size_t *out_len) {
    if (len == 0) return 1;
    uint8_t *buf = (uint8_t *)malloc(len);
    if (!buf) return 1;
    memcpy(buf, src, len);
    *out = buf;
    *out_len = len;
    return 0;
}

void smoosh_encode_free(uint8_t *p) {
    free(p);
}

// `yuv_format` is `chroma.Subsampling` as an int: 0=444 1=422 2=420 3=400,
// which maps onto avifPixelFormat by a fixed +1 offset (NONE is 0 there).
// `quality`/`speed` are avifenc's own scale — `-q 58 --speed 6` becomes
// `encoder->quality = 58` / `encoder->speed = 6` literally, since we vendor
// the same libaom avifenc links.
int smoosh_encode_avif(const uint8_t *rgba, int w, int h,
                       int yuv_format, int quality, int speed,
                       uint8_t **out, size_t *out_len) {
    if (w <= 0 || h <= 0) return 1;

    avifPixelFormat fmt = (avifPixelFormat)(AVIF_PIXEL_FORMAT_YUV444 + yuv_format);
    avifImage *image = avifImageCreate((uint32_t)w, (uint32_t)h, 8, fmt);
    if (!image) return 1;

    // Tag sRGB explicitly. The decode has already converted to sRGB and
    // dropped the ICC profile (Phase B strips metadata unconditionally), so
    // without this the output would carry no color signalling at all.
    // matrixCoefficients BT601 matches avifenc's default for a non-identity
    // matrix.
    image->colorPrimaries = AVIF_COLOR_PRIMARIES_BT709; // == _SRGB
    image->transferCharacteristics = AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;
    image->yuvRange = AVIF_RANGE_FULL;

    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image); // format defaults to RGBA, depth 8
    rgb.pixels = (uint8_t *)rgba;
    rgb.rowBytes = (uint32_t)w * 4;
    rgb.alphaPremultiplied = AVIF_FALSE;

    int rc = 1;
    avifEncoder *encoder = NULL;
    avifRWData output = AVIF_DATA_EMPTY;

    if (avifImageRGBToYUV(image, &rgb) != AVIF_RESULT_OK) goto done;

    encoder = avifEncoderCreate();
    if (!encoder) goto done;
    encoder->quality = quality;
    encoder->qualityAlpha = quality;
    encoder->speed = speed;
    // Single-threaded on purpose: libaom's rate control carries FP math and
    // the parity gate compares byte sizes against the Phase A baseline.
    // Determinism beats the few ms a second thread would save here.
    encoder->maxThreads = 1;

    if (avifEncoderWrite(encoder, image, &output) != AVIF_RESULT_OK) goto done;
    rc = copy_out(output.data, output.size, out, out_len);

done:
    avifRWDataFree(&output);
    if (encoder) avifEncoderDestroy(encoder);
    avifImageDestroy(image);
    return rc;
}

// `WebPEncodeRGBA` is `cwebp -q <q>` with nothing else set: it runs
// `WebPConfigInit` (method 4, the cwebp default), applies the quality, then
// `WebPPictureImportRGBA` + `WebPEncode`. No metadata is attached, matching
// Phase B's unconditional strip.
int smoosh_encode_webp(const uint8_t *rgba, int w, int h, int quality,
                       uint8_t **out, size_t *out_len) {
    if (w <= 0 || h <= 0) return 1;

    uint8_t *webp = NULL;
    size_t len = WebPEncodeRGBA(rgba, w, h, w * 4, (float)quality, &webp);
    if (len == 0 || !webp) {
        WebPFree(webp);
        return 1;
    }
    int rc = copy_out(webp, len, out, out_len);
    WebPFree(webp);
    return rc;
}
