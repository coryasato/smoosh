# Phase A baseline

Recorded 2026-08-27, before any Phase B code, on macOS 26.6 / Apple Silicon with
**libavif 1.4.2** (`aom [enc/dec]:3.14.1`, `dav1d [dec]:1.5.4`) and **libwebp 1.6.0**.

This file is the gate M13 and M14 are measured against: **Phase A's recorded sizes ±15%, no
visible regression, and matching chroma subsampling on both a photo and a graphics fixture**
(PLAN.md, "Key decisions carried forward"). It cannot be reconstructed after the encoders change,
so nothing here should be edited except to add later rounds beneath it.

Every number below comes from replaying Smoosh's *exact* pinned invocations — the ones
`src/main.zig`'s `beginEncode` and the HEIC staging spawn issue — not from a convenient
approximation:

```
/usr/bin/sips -s format png <src> --out <staged>     # HEIC/HEIF sources only
avifenc -q 58 --speed 6 <input> <output.avif>
cwebp  -q 80 <input> -o <output.webp>
```

## The fixture set

`test-images/` is gitignored, so this inventory is how the set is reproduced. Ten fixtures were
added in this round; the reason each exists is in the last column.

| Fixture | UTI | Pixels | Orient | Depth | Chroma | ICC | Proves |
|---|---|---|---|---|---|---|---|
| `large.jpg` | jpeg | 4000x3000 | — | 8 | **4:4:4** | sRGB | the atypical high-quality JPEG; that the chroma table reads the SOURCE rather than assuming 4:2:0 |
| `photo-420.jpg` | jpeg | 4000x3000 | — | 8 | **4:2:0** | sRGB | the common JPEG path (new) |
| `ui.png` | png | 1280x800 | — | 8 | n/a | none | the 4:4:4 graphics path — the fixture class that separates the encoders (new) |
| `ui.jpg` | jpeg | 1280x800 | — | 8 | **4:2:0** | sRGB | that a JPEG UI stays 4:2:0, matching Phase A rather than "improving" it (new) |
| `gray.jpg` | jpeg | 4000x3000 | — | 8 | 1 comp | Gray 2.2 | the 4:0:0 path (new) |
| `alpha16.png` | png | 512x512 | — | **16** | n/a | none | the depth + alpha edge case (new) |
| `small.png` | png | 64x64 | — | **16** | n/a | none | a 16-bit source that was in the set all along |
| `tiny.png` | png | 8x8 | — | **1** | n/a | sRGB | negative savings, and a 1-bit source |
| `photo.heic` | heic | 4000x3000 | 1 | 8 | n/a | sRGB | the HEIC staging path |
| `p3.heic` | heic | 4000x3000 | 1 | 8 | n/a | **Display P3** | wide-gamut conversion (new) |
| `rotated-p3.heic` | heic | 4000x3000 | **6** | 8 | n/a | **Display P3** | orientation + gamut together, on HEIC — synthetic (new) |
| `iphone-rotated-p3.heic` | heic | 4032x3024 | **6** | 8 | n/a | **Display P3** | the same, from a REAL iPhone 13 Pro capture, with real Apple EXIF/TIFF/MakerApple (new) |
| `multi-primary.heic` | heic | **640x200 @ index 1** | 1 | 8 | n/a | sRGB | primary-frame selection: two top-level images, `pitm` naming the SECOND (new) |
| `rotated-gps.jpg` | jpeg | 4000x3000 | **6** | 8 | 4:4:4 | sRGB | orientation baking + metadata stripping (EXIF Make/Model + GPS) (new) |
| `photo.webp` / `large.webp` | webp | 4000x3000 | — | 8 | n/a | none | the WebP-source path (`same_path` for WebP output) |
| `photo.avif` / `large.avif` | avif | 4000x3000 | 1 | 8 | n/a | sRGB | the AVIF-source path (`same_path` for AVIF output) |
| `oversized.jpg` | jpeg | 8000x6400 | — | 8 | 4:4:4 | sRGB | the 50 MP guard (51.2 MP) — no encode baseline |
| `not-an-image.jpg` | — | — | — | — | — | — | the undecodable-input guard (49 bytes of text) — no encode baseline |

**Nothing is missing any more**, but the way the last gap closed is worth recording, because the
obvious answer was wrong. A real iPhone still does NOT exercise primary-frame selection: the
supplied `iphone-rotated-p3.heic` is an HDR capture (`Headroom = 3.482202`) and therefore carries a
gain map, yet ImageIO reports `frames 1` — a gain map is an AUXILIARY image and
`CGImageSourceGetCount` does not count it. So no ordinary iPhone photo, Live Photo included, will
ever make `GetPrimaryImageIndex` return non-zero.

What does is a HEIC with two TOP-LEVEL images whose `pitm` box names the second. That is
`multi-primary.heic`, and it earns its place immediately — see finding 6.

How the new ones were made, so the set is reproducible:

```sh
magick -font '/System/Library/Fonts/Supplemental/Arial.ttf' -size 1280x800 xc:'#f6f7f9' \
  ... flat panels, 1px borders, colored text ... -colorspace sRGB -depth 8 -alpha off PNG24:ui.png
magick ui.png -quality 80 ui.jpg                                   # -> 4:2:0
magick large.jpg -sampling-factor 2x2 -quality 80 photo-420.jpg    # -> 4:2:0 (IM otherwise
                                                                   #    inherits the source's 4:4:4)
magick large.jpg -colorspace Gray -quality 85 gray.jpg
magick -size 512x512 gradient:'#ff0000-#0000ff' -alpha set -channel A \
  -evaluate set 60% +channel -depth 16 alpha16.png
magick large.jpg -profile '/System/Library/ColorSync/Profiles/Display P3.icc' -quality 60 p3.heic
magick large.jpg -profile '/System/Library/ColorSync/Profiles/Display P3.icc' \
  -orient RightTop -quality 60 rotated-p3.heic
python3 inject_exif.py large.jpg rotated-gps.jpg   # APP1 with Orientation=6, Make/Model, GPS lat/lon

# multi-primary.heic: two top-level images at DIFFERENT sizes (so which one was
# decoded is visible), then patch the `pitm` box to name item 2 as primary.
magick large.jpg -resize 400x300! a.png
magick ui.png    -resize 640x200! b.png
magick a.png b.png -quality 60 multi.heic
python3 -c "
import struct; d=bytearray(open('multi.heic','rb').read())
off=d.find(b'pitm')-4; assert d[off+8]==0            # version 0 -> 16-bit item_ID
struct.pack_into('>H', d, off+12, 2)                 # was 1
open('multi-primary.heic','wb').write(bytes(d))"
```

`iphone-rotated-p3.heic` is a real iPhone 13 Pro capture, supplied rather than generated. It is
not reproducible from this repo; any rotated Display-P3 iPhone HEIC substitutes for it.

Two traps worth knowing if these are ever regenerated. `magick -profile` on an image with no
existing profile *assigns* rather than converts — the stored bytes are unchanged and only the tag
is new, which is exactly what a wide-gamut test wants. And `identify` reports `rotated-p3.heic` as
"3000x4000, Orientation: TopLeft" because libheif applies the `irot` box on read, while ImageIO
reports the honest "4000x3000, Orientation 6"; ImageIO is what M13 uses, so ImageIO is the reading
that counts.

## The baseline numbers

PSNR is measured against **what the encoder actually read** (the staged PNG for HEIC sources, the
file itself otherwise), with both sides normalized the same way, so the number is encoder quality
and not a container mismatch. "AVIF WxH" is the *decoded* size — where it differs from the source's
stored pixels, a container-level rotation was applied.

| Fixture | Staged | Source B | AVIF B | AVIF Δ | AVIF PSNR | AVIF yuv | AVIF WxH | AVIF EXIF | WebP B | WebP Δ | WebP PSNR | WebP WxH |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `large.jpg` | — | 5846465 | 717003 | -88% | 35.73 | YUV444 | 4000x3000 | Absent | 671054 | -89% | 35.07 | 4000x3000 |
| `photo-420.jpg` | — | 1223075 | 634631 | -48% | 40.76 | YUV420 | 4000x3000 | Absent | 599368 | -51% | 39.03 | 4000x3000 |
| `ui.png` | — | 42477 | 9495 | -78% | 49.63 | YUV444 | 1280x800 | Absent | 16144 | -62% | 42.43 | 1280x800 |
| `ui.jpg` | — | 40330 | 12577 | -69% | 47.15 | YUV420 | 1280x800 | Absent | 17796 | -56% | 46.01 | 1280x800 |
| `gray.jpg` | — | 1319879 | 520291 | -61% | 42.01 | YUV400 | 4000x3000 | Absent | 499288 | -62% | 41.05 | 4000x3000 |
| `alpha16.png` | — | 3878 | 695 | -82% | 64.33 | YUV444 | 512x512 | Absent | 1760 | -55% | 53.08 | 512x512 |
| `small.png` | — | 573 | 342 | -40% | 53.29 | YUV444 | 64x64 | Absent | 160 | -72% | 43.69 | 64x64 |
| `tiny.png` | — | 312 | 315 | **+1%** | 45.91 | YUV444 | 8x8 | Absent | 68 | -78% | 52.90 | 8x8 |
| `photo.heic` | sips→png | 2308948 | 655145 | -72% | 38.16 | YUV444 | 4000x3000 | **Present (104 B)** | 604060 | -74% | 37.31 | 4000x3000 |
| `p3.heic` | sips→png | 3064647 | 667716 | -78% | 37.83 | YUV444 | 4000x3000 | **Present (92 B)** | 613948 | -80% | 36.96 | 4000x3000 |
| `rotated-p3.heic` | sips→png | 3064657 | 667716 | -78% | see below | YUV444 | 4000x3000 | **Present (92 B)** | 613948 | -80% | see below | 4000x3000 |
| `rotated-gps.jpg` | — | 5846685 | 717292 | -88% | 35.73 | YUV444 | **3000x4000** | **Present (210 B)** | 671054 | -89% | see below | 4000x3000 |
| `iphone-rotated-p3.heic` | sips→png | 2025792 | 578634 | -71% | see below | YUV444 | 4032x3024 | **Present (2664 B)** | 731748 | -64% | see below | 4032x3024 |
| `multi-primary.heic` | sips→png | 34574 | 10223 | -70% | 37.68 | YUV444 | **400x300** | Present (104 B) | 9314 | -73% | 36.44 | **400x300** |
| `photo.webp` | — | 604060 | **fail** | — | — | — | — | — | 462808 | -23% | 43.40 | 4000x3000 |
| `large.webp` | — | 671054 | **fail** | — | — | — | — | — | 489728 | -27% | 42.71 | 4000x3000 |
| `photo.avif` | — | 655145 | **fail** | — | — | — | — | — | **fail** | — | — | — |
| `large.avif` | — | 717003 | **fail** | — | — | — | — | — | **fail** | — | — | — |

The chroma column is the one that must match exactly after M14, and it confirms PLAN.md's table
empirically: the *same* UI image is **YUV444 as a PNG** (`ui.png`) and **YUV420 as a JPEG**
(`ui.jpg`); a 4:4:4 photographic JPEG stays **YUV444** (`large.jpg`) while the same photo at 4:2:0
becomes **YUV420** (`photo-420.jpg`); grayscale is **YUV400**; every staged HEIC is **YUV444**
because it reaches the encoder as a PNG. `avifenc --yuv auto` never looks at the pixels.

## What the baseline exposed that PLAN.md had wrong or did not know

These are behaviors of the SHIPPING app, found while measuring it. Each one changes something
about Phase B.

### 1. `sips` does NOT convert HEIC to sRGB — PLAN.md says it does

PLAN.md states the sRGB conversion "is already today's behavior for HEIC (`sips` stages through
PNG) but NOT for a Display-P3 JPEG". Measured, that is backwards in an important way: the staged
PNG from `p3.heic` still reports **`profile Display P3`**. `sips` preserves the source profile; it
converts nothing.

So Phase B's sRGB conversion is a deliberate change for **every** wide-gamut source, HEIC included
— not just for P3 JPEGs. The "Non-goals" entry and the "Correctness requirements" bullet both need
that correction.

### 2. Today, a Display-P3 source produces a correct AVIF and a DESATURATED WebP

Both halves measured on `p3.heic`:

- `avifenc` preserves the gamut, by two different mechanisms depending on the input container.
  From the staged **PNG** it reads the `iCCP` chunk and writes **CICP Color Primaries 12**
  (P3-D65), ICC absent. From a **JPEG** carrying a P3 ICC it embeds the **ICC profile itself**
  (536 bytes) with Color Primaries 2 (unspecified). Either way the AVIF displays correctly.
- `cwebp` **strips the ICC profile entirely** (`webpinfo` shows a lone `VP8` chunk, no `ICCP`).
  The P3 pixel numbers are written into an untagged — therefore sRGB — WebP, so the file displays
  desaturated. Sampling one mid-tone: source `#818181` comes back `#7E8381`.

This is a real, shipping color bug in the WebP half, and it is the strongest concrete argument for
PLAN.md's "convert to sRGB" requirement: after Phase B both formats carry the same, correct,
sRGB-tagged pixels. Record it as a bug Phase B FIXES, not only as a trade it makes.

### 3. Orientation handling is inconsistent between the two formats — and between input containers

On `rotated-gps.jpg` (4000x3000 pixels, EXIF Orientation 6) — and reproduced on the real
`iphone-rotated-p3.heic`, where both outputs come back 4032x3024 against an upright 3024x4032
reference:

- `avifenc` translates the EXIF orientation into an AVIF **`irot (Rotation): 3`** transform, so the
  AVIF decodes to **3000x4000** and displays upright.
- `cwebp` ignores orientation completely; the WebP is **4000x3000** and displays **sideways**.

So "Both" on any orientation-tagged photo ships one correct file and one rotated one. The PSNR
cells marked "see below" are that mismatch showing up as a dimension mismatch — 5.66 dB for
`rotated-gps.jpg`, ~9.6 dB for the two rotated HEICs — not a quality measurement.

It is worse than a simple per-format split, because `avifenc`'s own behavior depends on the input
container: the same orientation tag arriving via the **staged PNG** (`rotated-p3.heic`) produces
`Transformations: None` and a 4000x3000 AVIF — sideways, like the WebP. So a rotated JPEG and a
rotated HEIC behave differently in the same format.

Phase B baking orientation into the pixels resolves every case at once. Add this to "Known
limitations" — it is user-visible today and nobody had written it down.

### 4. Neither encoder can read a WebP or AVIF source, so those sources produce NOTHING today

| Source | `avifenc` | `cwebp` | What Smoosh does today |
|---|---|---|---|
| `.webp` | `Unrecognized file format` | ok | AVIF fails; WebP is `same_path` → **whole run `.failed`** |
| `.avif` | `Unsupported file format AVIF` | `Unrecognized file format` | AVIF is `same_path`; WebP fails → **whole run `.failed`** |

Both formats are in the open panel's filter list and both are accepted on drop, so this is
reachable from the UI. The archive records the `same_path` decision for WebP→WebP but nobody
recorded that the *other* format cannot be produced at all.

M13 fixes half of this for free (ImageIO decodes both), and M14 finishes it: after Phase B, a WebP
source produces a real AVIF and an AVIF source produces a real WebP. That is a genuine capability
Phase B adds while removing the dependency — worth stating, since Phase B is otherwise a strict
"nothing changes" round.

### 5. Metadata leakage is wider than "EXIF into AVIF"

PLAN.md records that `avifenc` copies EXIF/GPS. Measured, it also copies **XMP** — 417-419 bytes on
every staged-HEIC output — and the leak survives the `sips` PNG staging step, so HEIC sources leak
too, not just JPEGs. `cwebp` carries none of it, as recorded. Phase B's unconditional strip removes
all of it; the "Correctness requirements" bullet should say EXIF *and XMP*.

The synthetic fixtures understate the size of the leak. On the real capture
(`iphone-rotated-p3.heic`) the AVIF carries **2664 bytes of EXIF** — the whole Apple block, which
ImageIO reports as capture timestamps, `LensModel`, `HostComputer = "iPhone 13 Pro"`,
`Software = "26.6.1"`, a `SubjectArea`, and a large opaque `{MakerApple}` dictionary. This
particular photo happens to carry no GPS, but everything else identifying the device and the
moment is there and ships to the web today.

### 6. `sips` compresses the WRONG IMAGE in a multi-image HEIC

This is the bug `CGImageSourceGetPrimaryImageIndex` exists to prevent, and it is live today.
`multi-primary.heic` holds two top-level images — 400x300 at index 0, 640x200 at index 1 — with the
`pitm` box naming **index 1** as primary. ImageIO agrees (`primary 1`, properties report 640x200).
All three of Smoosh's `sips` calls take index 0 instead:

| Smoosh's call | Reports / produces | Should be |
|---|---|---|
| `sips -g pixelWidth -g pixelHeight` (megapixel guard) | `pixelWidth: 400 \| pixelHeight: 300` | 640x200 |
| `sips -Z 160` (the preview) | 160x120 | 160x50 |
| `sips -s format png` (encoder staging) | 400x300 | 640x200 |

So the guard measures the wrong image, the card previews the wrong image, and the user gets a
compressed copy of an image that was never the primary — silently, with no error anywhere. M13
fixes all three at once by routing every one of them through `GetPrimaryImageIndex`, which is
exactly the requirement PLAN.md already carried; this is the measurement that shows it is not
hypothetical.

Note the fixture had to be synthesized. A real iPhone still, even an HDR one with a gain map, is
`frames 1` to ImageIO — see the fixture-set note above.

## Reproducing this

The two scripts that produced the table (`baseline.sh` replaying the pinned invocations, and
`inject_exif.py` building the orientation+GPS APP1 segment) are throwaway measurement tooling, not
part of the app. The invocations they run are quoted at the top of this file; that, plus the
fixture recipes above, is everything needed to rebuild the numbers from scratch.

---

# Phase B step 6 — the vendored encoder artifacts

Recorded 2026-08-28, appended beneath the Phase A baseline rather than editing it. Everything
above is the Phase A measurement and stays frozen; this section records how M14's three static
archives are produced, so the build can be reproduced without re-deriving the flags.

Built on macOS 26.6 / Apple Silicon with **CMake 4.4.3** and **Ninja 1.13.2** (neither was
installed; `brew install cmake ninja`), AppleClang 21.0.0, against the Xcode SDK at
`xcrun --show-sdk-path`. Meson and nasm were NOT needed — meson is dav1d's build system and we
vendor no decoder, and nasm is x86-only while libaom's arm64 SIMD is NEON intrinsics in plain C.

## Sources

Release tarballs, at the exact versions the Phase A baseline was measured against, extracted under
`~/Code/zig/smoosh-vendor/src` (outside this repo — the build trees are ~2 GB and are throwaway):

| library | version | sha256 |
|---|---|---|
| libwebp | 1.6.0 | `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564` |
| libavif | 1.4.2 | `2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d` |
| libaom | 3.14.1 | `44bf90dbd23e734d50e70a8c41c285193922938bd0d3bc2ee56764d181d55ef5` |

libavif's hash is byte-identical to the one Homebrew's `libavif` formula pins, so the source tree
is provably the same one the baseline's `avifenc` was built from.

## The configure invocations

Common to all three: `-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0
-DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF`, with `-DCMAKE_INSTALL_PREFIX` pointing
at `out/<lib>`. The deployment target matches what `native build` targets
(`native-macos.11.0`, visible in the build summary).

### libwebp

```sh
cmake -S src/libwebp-1.6.0 -B build/libwebp -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX=$PWD/out/libwebp \
  -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_LIBWEBPMUX=OFF -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF -DWEBP_BUILD_FUZZTEST=OFF
```

Every `WEBP_BUILD_*` switch is a **tool**, not a library feature: there is no encode-only switch
for `libwebp.a` itself, which carries both the encoder and the decoder in one archive. That costs
nothing, because the link pulls only referenced members. `libwebpdecoder.a` and `libwebpdemux.a`
are still produced as separate artifacts and are simply not linked.

`libsharpyuv.a` falls out of the same build and is **mandatory**, as step 5 measured:
`picture_csp_enc.c.o` calls `SharpYuvConvert`/`SharpYuvInit`/`SharpYuvGetConversionMatrix`.

Build: 179 targets, a few seconds.

### libaom — encode-only

```sh
cmake -S src/libaom-3.14.1 -B build/libaom -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX=$PWD/out/libaom \
  -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTDATA=OFF \
  -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF \
  -DCONFIG_AV1_DECODER=0 -DCONFIG_TUNE_VMAF=0 -DCONFIG_TUNE_BUTTERAUGLI=0 \
  -DCONFIG_WEBM_IO=0
```

**PLAN.md budgeted libaom as the hard vendor and it was not.** The `rtcd` dispatch headers
(`aom_config.h`, `aom_dsp_rtcd.h`, ...) are generated by CMake itself using **perl**, which ships
with macOS at `/usr/bin/perl` — CMake found it and generated them with no intervention. Configure
took 12s; the full build was **22s wall** across 310 targets. The obstacle PLAN.md anticipated is
real only if you try to reproduce the configure step inside `build.zig`, which is exactly why the
plan chose to prebuild instead.

Encode-only is verified by archive membership, not by trusting the flag. Against Homebrew's
libaom.a, ours is missing exactly 13 objects and no others:

```
av1_dx_iface.c.o  binary_codes_reader.c.o  bitreader.c.o  decodeframe.c.o
decodemv.c.o      decoder.c.o              decodetxb.c.o  detokenize.c.o
entdec.c.o        grain_synthesis.c.o      obu.c.o        tune_vmaf.c.o  vmaf.c.o
```

`_aom_codec_decode` is still exported — it is the generic dispatch entry in `aom_decoder.c` and is
always compiled — but `_aom_codec_av1_dx`, the AV1 decoder interface and all the bulk behind it,
is gone. Presence of the former is not evidence the decoder is linked in; absence of the latter is
evidence it is not.

`CONFIG_TUNE_VMAF=0` drops the libvmaf dependency Homebrew treats as required. Our pinned
invocation is `avifenc -q 58 --speed 6` with no `--tune`, so the VMAF tuning path was never
reachable in Phase A either.

**Our libaom.a is 8.1 MB against Homebrew's 5.4 MB, despite having 13 fewer objects.** The cause
is optimization level, confirmed in Homebrew's own source: `extend/ENV/super.rb:89` sets
`HOMEBREW_OPTIMIZATION_LEVEL` to `Os` for clang, and the `aom` formula does not opt into `O3`. Our
build uses upstream's Release flags, which are `-O3`. Per-object the difference is all `__TEXT`
(`encodeframe.c.o`: 28,756 vs 21,792 bytes of `__text`, identical `__cstring` and `__const`).
`-O3` is the right default for an encoder in a tool that promises to feel instantaneous, and the
size cost is measured below. **Do not assume this is bit-identical output**: libaom's rate control
carries floating-point math, and optimization level can change FP contraction. M14 must re-encode
the fixture set and compare against the Phase A table rather than reason about it.

### libavif — encode-only, against our libaom

```sh
PKG_CONFIG_PATH=$PWD/out/libaom/lib/pkgconfig \
cmake -S src/libavif-1.4.2 -B build/libavif -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF \
  -DCMAKE_INSTALL_PREFIX=$PWD/out/libavif \
  -DCMAKE_PREFIX_PATH=$PWD/out/libaom \
  -DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_ENCODE=ON -DAVIF_CODEC_AOM_DECODE=OFF \
  -DAVIF_CODEC_DAV1D=OFF -DAVIF_CODEC_LIBGAV1=OFF -DAVIF_CODEC_RAV1E=OFF -DAVIF_CODEC_SVT=OFF \
  -DAVIF_LIBYUV=OFF -DAVIF_LIBSHARPYUV=OFF \
  -DAVIF_BUILD_APPS=OFF -DAVIF_BUILD_TESTS=OFF -DAVIF_BUILD_EXAMPLES=OFF -DAVIF_BUILD_MAN_PAGES=OFF
```

Configure prints `libavif: Codec enabled: aom (encode only)`. It resolves aom through pkg-config,
so `PKG_CONFIG_PATH` must point at OUR `aom.pc` — both ours and Homebrew's report version 3.14.1,
so a mistake here is invisible in the log. Verified by the paths CMake cached
(`out/libaom/include`, `out/libaom/lib/libaom.a`), not by the version string.

**`-DAVIF_LIBYUV=OFF` and `-DAVIF_LIBSHARPYUV=OFF` are output-parity requirements, not size
trims.** `AVIF_LIBYUV` defaults to `SYSTEM` and would silently enable libyuv's RGB-to-YUV fast
paths if libyuv happened to be installed; Homebrew's formula passes `AVIF_LIBYUV=OFF` and leaves
`AVIF_LIBSHARPYUV` at its `OFF` default, so the baseline's `avifenc` used libavif's own conversion.
Matching that is how M14's output stays on the Phase A numbers.

`libavif.a` is 302 KB and does **not** bundle libaom: every `aom_codec_*` symbol it calls is left
undefined (`nm -u` lists 15 of them plus `avifCodecCreateAOM`). **libavif.a must therefore precede
libaom.a in the link order.**

## Verification in the linkspike harness

Per `~/Code/zig/smoosh-linkspike/README.md`: the three archive paths were pointed at
`~/Code/zig/smoosh-vendor/out`, wrapper `pub fn`s added in `src/main.zig` for `avifVersion` and
`aom_codec_version_str` beside the existing `WebPGetEncoderVersion`, and tests asserting the exact
version strings added in `src/tests.zig`. Both artifacts, every archive:

- `native build . --yes` — clean, and the running ReleaseFast exe prints
  `libwebp encoder version: 1.6.0`, `libavif version: 1.4.2`, `libaom version: v3.14.1`.
- `native test . --yes` — **9/9 pass**, including the three version assertions, so all three
  archives reach the separate Debug test module too.

`otool -L` on the exe lists no new dylibs — the same system frameworks as before and nothing from
`/opt/homebrew`. The archives really are static.

## Size cost — the measurement PLAN.md's "+5 MB" estimate was waiting on

Three ReleaseFast builds of the same linkspike app, differing only in what the exe references:

| what the exe references | exe size | delta |
|---|---|---|
| no archives linked at all | 6,466,232 | — |
| the three version symbols only | 6,467,656 | **+1,424** |
| the real encoder entry points | 11,917,704 | **+5,451,472 (+5.20 MiB)** |

The third row references `WebPEncodeRGB`, `avifEncoderCreate`, `avifEncoderAddImage`,
`avifEncoderFinish`, `avifImageCreate`, `avifImageRGBToYUV` and `avifRGBImageSetDefaults` — the
calls M14's encoder actually makes — without calling them; a reference is enough to force emission
and pull the same archive members. **PLAN.md's ~+5 MB estimate holds: +5.20 MiB.** Against
Smoosh's current 5.5 MB binary that lands around **10.7 MB**, and the +1,424-byte row is the
reminder of why: the link pulls only what is referenced, so the 8.1 MB archive is not the cost.
If that number ever needs to come down, Homebrew's `-Os` libaom is the knob — at an encode-speed
cost, and only after re-verifying output against the Phase A table.
