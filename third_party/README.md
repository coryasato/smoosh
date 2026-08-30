# third_party — vendored encode-only static archives

These four `.a` files are what let Smoosh encode AVIF and WebP without
`brew install libavif webp`. They are committed deliberately: they are the
build's inputs, they are ~8.8 MB, and reproducing them requires CMake,
Ninja and ~2 GB of throwaway build tree that does not belong in this repo.

**Nothing here is modified upstream source.** Each archive is the
unmodified output of an upstream release tarball built with the exact
invocation recorded in `docs/phase-b-baseline.md` under "Phase B step 6".
That document is the authority; this file is the summary you need to
decide whether you are looking at the right bytes.

## What is here

| Path | Version | Why |
|---|---|---|
| `libavif/lib/libavif.a` | 1.4.2 | AVIF mux/encode API. **Must be linked BEFORE libaom.a** — it leaves all 15 `aom_codec_*` symbols undefined. |
| `libaom/lib/libaom.a` | 3.14.1 | The AV1 encoder behind libavif, built `CONFIG_AV1_DECODER=0`. What `avifenc` itself uses, so it is what reproduces the Phase A output. |
| `libwebp/lib/libwebp.a` | 1.6.0 | WebP encoder. |
| `libwebp/lib/libsharpyuv.a` | 1.6.0 | **Mandatory, not optional.** `picture_csp_enc.c.o` calls `SharpYuvConvert`/`SharpYuvInit`/`SharpYuvGetConversionMatrix`. Omitting it links a ReleaseFast exe clean and fails only the Debug test artifact. |

Source tarball sha256s are in `docs/phase-b-baseline.md`. libavif's is
byte-identical to the hash Homebrew's formula pins, so the source tree is
provably the one the Phase A baseline's `avifenc` was built from.

Targets **arm64-macos, deployment target 11.0**, non-fat, matching what
`native build` targets (`native-macos.11.0`). There is no x86_64 or
universal build; producing one is unexplored.

## Headers

`*/include` carries only the headers for the two APIs Smoosh actually
calls — `avif/avif.h` and `webp/encode.h` (plus `webp/types.h`, which it
includes). They are the ABI reference `src/encoders.zig` writes its
`extern fn` declarations against; nothing `@cImport`s them and no include
path is set.

Deliberately NOT vendored: libaom's headers (Smoosh never calls libaom
directly — libavif does), libwebp's `decode.h`/`demux.h`/`mux_types.h`,
libavif's C++ wrapper, and the `libwebpdecoder.a`/`libwebpdemux.a`
archives. Decoding is ImageIO's job (`src/imageio.zig`) and animation is
a stated non-goal, so an encode-only header surface keeps the vendored
tree honest about what it is.

## Why "encode-only" is verified, not assumed

Against Homebrew's `libaom.a`, ours is missing exactly 13 objects and no
others — the AV1 decoder, VMAF tuning and their bulk. Note
`_aom_codec_decode` is still exported: it is the generic dispatch entry in
`aom_decoder.c` and is always compiled. Its presence is NOT evidence the
decoder is linked in; the absence of `_aom_codec_av1_dx` is evidence it is
not. The object-level diff is in `docs/phase-b-baseline.md`.

## Two traps recorded here because the build cannot state them

1. **`AVIF_LIBYUV=OFF` and `AVIF_LIBSHARPYUV=OFF` are output-parity
   requirements, not size tuning.** `AVIF_LIBYUV` defaults to `SYSTEM` and
   would silently swap in different RGB→YUV math than the baseline's
   `avifenc` used. Nothing in the build reports this.
2. **These are `-O3` (upstream Release) where Homebrew's are `-Os`.** That
   is why ours is 8.1 MB against Homebrew's 5.4 MB despite 13 fewer
   objects. libaom's rate control carries floating-point math and
   optimization level can change FP contraction, so **output parity with
   the Phase A baseline is NOT proven** and must be re-measured when the
   encoders are actually called (M14c), not reasoned about.

## Updating

Rebuild per `docs/phase-b-baseline.md` and copy the archives over. Then
expect `src/tests.zig` to go red: it pins all three versions through
`src/encoders.zig`'s `pinned`. That is the point — an encoder change must
be a decision re-measured against the baseline, not something that
arrives silently with a re-copied file.
