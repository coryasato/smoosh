# Smoosh — PLAN.md

> Living plan. Update this file as decisions are made. Full v0.1 development history (every
> "settled/found here" decision, live-verification writeups, mutation-testing findings) lives in
> `docs/plan-v0.1-archive.md` — this file stays lean and current.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern web formats (AVIF and/or WebP) without leaving your desktop.

## Status
**v0.1 shipped** (M1-M12, archived). Pick or drop an image, choose AVIF/WebP/Both, Smoosh
auto-saves next to the source; each landed result row carries its own save icon to copy that one
file elsewhere, packaged as an ad-hoc-signed `.app`. `native test` 100/100, `native check` zero
warnings, `native build` clean.

**Phase B is UNDER WAY. M13 (v0.2) is DONE** (2026-08-28). The load chain runs on ImageIO: a new
`src/imageio.zig` holds the whole C-ABI seam, two new host commands (`image.probe`,
`image.thumbnail`) answer off the loop thread through `HostBridge`'s worker carrier, and both
`sips` spawns, `fx.loadImage`, `parseDimensions`, the preview temp file and the drawn-size clamp
are gone. `native test` 108/108, `native check` zero warnings, `native build` clean at 5.5 MB.
Steps 1-3 (the two prerequisite spikes and the Phase A baseline) were done 2026-08-27.
**Steps 5 and 6 (both M14 gates) are DONE** (2026-08-28). The link path is proven
(`docs/spikes/static-archive-link-spike.zig`; `addAppArtifacts` is real in CLI 0.10.1), and so are
the artifacts: encode-only `libwebp.a` + `libsharpyuv.a`, `libavif.a` and `libaom.a` are built for
arm64-macos and link into both a running ReleaseFast exe and the Debug test artifact, at a measured
cost of +5.20 MiB. Written up in `docs/phase-b-baseline.md` under "Phase B step 6". Nothing in
THIS tree is ejected or vendored yet — that is M14.

**M14b is DONE** (2026-08-29): `src/imageio.zig` grew `decode` — full-resolution, primary frame,
EXIF orientation baked in BY HAND, sRGB, 8-bit, straight alpha, no metadata — and `src/chroma.zig`
is new, holding the JPEG SOF parser and the source-container chroma table. Both are pure over a
path or over bytes; **neither has a caller yet**, which is what M14b is (PLAN.md's b/c split).
Suite 116 -> 125, `check` zero warnings, exe 5,522,376 -> 5,522,488 bytes. Verified against the
whole fixture set outside the suite as well: the chroma table reproduces
`docs/phase-b-baseline.md`'s `AVIF yuv` column exactly, and the orientation bake is an exact
permutation. Written up under the baseline doc's "M14b" heading. **M14c is next and is the last
step of M14** — the two encode seams, atomic write, the deletions, and the parity investigation.

**M14a is DONE** (2026-08-28): `native eject` ran, `build.zig` is ours and links the four vendored
encode-only archives under `third_party/` into both the exe and the test artifact, `src/encoders.zig`
exists holding version probes only, and `src/imageio_tests.zig` runs under `native test` at last
(108 -> 116 tests). The app calls no vendored encoder yet and still needs Homebrew; M14b and M14c
are what change that. Exe grew 128 bytes.

**The encoders are untouched, exactly as M13 promised and as M14a preserved** — `avifenc`/`cwebp`
still read the source file with the pinned argv, so no output byte moved. What changed is everything upstream of them:
the preview and the megapixel guard now read the file's PRIMARY frame, with EXIF orientation baked
and the profile converted to sRGB.

The limitation driving the round is unchanged — Smoosh requires `brew install libavif webp` to do
anything — and M14 is what removes it. See "Known limitations" for what M13 fixed, what it fixed
only halfway, and what is still waiting on the encoders.

## Success criteria for v0.1 (MVP) — all shipped
- [x] App launches to a clean drop-zone UI that becomes a file card once a file lands
- [x] User can pick an image via "Choose Image…" (native open dialog, wired through a custom
  `HostCallBinding` — see CLAUDE.md's "File acquisition, honestly") or drag-and-drop onto the window
  (`UiApp.Options.on_drop`, SDK 0.8.2+)
- [x] Image appears as preview with original size
- [x] User can choose output: AVIF, WebP, or Both (default)
- [x] "Smoosh" produces the selected format(s) via system tools and auto-saves next to the source file
- [x] Before/after file size + savings % are shown
- [x] User can optionally re-save any landed output to a different location, via a save icon on
  that format's own result row
- [x] Works on macOS only
- [x] Reasonable input size limits (100 MB / 50 MP) with clear feedback
- [x] Ships as a packaged `.app` (ad-hoc signed) that launches on a machine that never ran `native build`

## Non-goals (for now)
- Linux or Windows support
- Batch processing of many files
- Advanced quality controls / comparison view / side-by-side
- Cloud upload / accounts / history
- Animated image support
- Vector / SVG handling
- In-app image editing (crop, resize, etc.)
- Shipping a Node or ImageMagick dependency
- Metadata-preservation toggles (EXIF, GPS, ICC) — Phase B strips unconditionally, a deliberate
  change from today's AVIF output; revisit only on request
- Wide-gamut output (P3 and beyond) — Phase B converts to sRGB deliberately
- Quality/speed sliders — the pinned settings are the product

## Technical approach

### Encoding strategy (phased)

**Phase A — current (system tools)**
- `fx.spawn` against system tools already available via Homebrew or bundled with macOS.
  - `avifenc` (from libavif) for AVIF
  - `cwebp` (from libwebp) for WebP
- Presence of `avifenc`/`cwebp` is detected at launch. If missing, the status line names which tool
  is absent and the exact `brew install` command — the user runs it themselves in Terminal.
- HEIC/HEIF sources are staged as a PNG via `sips` first (`avifenc`/`cwebp` reject HEIC as an input
  format outright); both encoders then read the staged PNG.
- No ImageMagick. No Sharp. No sidecars.

Pinned invocations, confirmed against real fixtures (libavif 1.4.2, libwebp 1.6.0):
```
avifenc -q 58 --speed 6 <input> <output.avif>
cwebp  -q 80 <input> -o <output.webp>
```
A negative-savings result (output larger than a tiny source) is real, not an error — it displays as
`+1% larger`, not a failure.

**Phase B — native (v0.2 + v0.3)**

Phase B is a DEPENDENCY-REMOVAL round, not a feature round, and NOTHING about output quality may
regress. The success criterion is one sentence: Smoosh works on a Mac where nothing is installed.
That is also the scope gate — anything that does not shrink the dependency surface or preserve
current behavior is out.

Three deliberate EXCEPTIONS to "nothing changes", each a product decision rather than a
side effect, all detailed in "Correctness requirements":
1. **Metadata is stripped.** Measured: `avifenc` copies EXIF/GPS **and XMP** today, `cwebp` does
   not.
2. **Outputs are written atomically.** Phase A can leave a truncated file; this is a reliability
   fix that does not strictly belong to dependency removal, but it is one screenful and rides along.
3. **Display-P3 sources are converted to sRGB.** New for EVERY wide-gamut source, HEIC included —
   an earlier draft of this plan said `sips` already converted HEIC to sRGB and it does not (see
   `docs/phase-b-baseline.md`, finding 1).

Phase B also FIXES four things measured while recording the baseline, at no extra cost — they
fall out of decoding through ImageIO and encoding from pixels, so they are not scope creep:
a Display-P3 source stops producing a desaturated WebP; an orientation-tagged source stops
producing one upright file and one sideways one; a multi-image HEIC stops compressing the wrong
image; and a WebP or AVIF source stops producing nothing at all. All four are in "Known
limitations" with their measurements.

The split is DECODE vs ENCODE, because the two have opposite answers:

- **Decode belongs to ImageIO.** It reads HEIC, JPEG, PNG, WebP and TIFF directly, needs no
  third-party code, and requires no build-graph change (`CGImageSource*` links via AppKit, which
  the SDK already links). This is an unambiguous win and lands first.
- **Encode belongs to vendored libraries.** macOS ImageIO *can* encode AVIF, and on photographs it
  is quality-indistinguishable from `avifenc` and 2.6x faster — but it is hard-locked to YUV420
  chroma subsampling with no control exposed, which makes it decisively worse on the
  screenshot/UI/graphics content this tool exists to compress. See "Key decisions carried
  forward" for the measurements that settled this. Matching today's output on ALL content
  requires the same encoders Phase A shells out to.

**M13 (v0.2) — ImageIO decode, preview and probe. DONE (2026-08-28).** No build-graph change and
no encoder change: the `avifenc`/`cwebp` spawns are exactly as they were. This rested on ImageIO
already being linked, confirmed from the shipped binary's own load commands rather than inferred —
`otool -L zig-out/bin/smoosh` lists ImageIO, CoreGraphics and CoreFoundation directly. M14's eject
should still add an explicit `linkFramework("ImageIO")` rather than keep depending on that.

The C-ABI surface is `src/imageio.zig`: plain `extern fn` declarations (not `@cImport`, which would
need include paths), transplanted from `docs/spikes/imageio-decode-spike.zig`. 100 lines of
declarations cover both commands; CoreFoundation types are opaque pointers and declare cleanly.

TWO host commands landed, not three, and both answer off the loop thread:
- `image.probe` — properties only, via `CGImageSourceCopyPropertiesAtIndex`. Decodes NOTHING.
  Replaced the `sips -g` spawn and now feeds the megapixel guard BEFORE any decode has happened,
  which the old ordering could not offer. Returns `"<w> <h> <orientation> <uti>"`; the dimensions
  are DISPLAY dimensions (orientation already applied) and the UTI is what M14's chroma table will
  key on.
- `image.thumbnail` — preview only, <=160px, 8-bit sRGB, straight alpha, orientation baked by
  `kCGImageSourceCreateThumbnailWithTransform`. Replaced the `sips` thumbnail spawn AND
  `fx.loadImage` AND its temp file; `update` now calls `fx.registerImage` directly.
- `image.decode` — DEFERRED TO M14, deliberately. It has no consumer until the vendored encoders
  exist, and wiring a host command with no Msg arm would have meant shipping an unreachable code
  path. The seam it would use and the module it lands in are both proven by the two above; what it
  still needs of its own is the EXIF transform applied BY HAND, since the full-decode path does not
  rotate (measured: the same 4000x3000 Orientation 6 source comes back 120x160 as a thumbnail and
  4000x3000 unrotated as a full decode).

**THE PIXELS RIDE THE HOST RESULT, and PLAN.md's earlier "prefer the descriptor shape for BOTH
commands" was the wrong call for the thumbnail.** `max_effect_host_result_bytes` is 256 KiB and an
over-cap answer is silently rewritten to the err route; 160x160 RGBA is 100 KiB and fits with room.
The descriptor's advantage was said to be removing a silent cliff at 256x256 — but a
`comptime` assert removes that cliff outright, as a COMPILE error rather than a runtime one, and
riding the result costs nothing extra: `hostRequest` heap-allocates `payload.len + 256 KiB` per
request whether or not the answer uses it. It also deletes a whole class of bug the descriptor
shape would have introduced, since bytes fed for a key are copied into that key's own effect slot
and a cancelled key drops them, while a `pub var` pixel buffer is shared by every in-flight worker.
A full-resolution decode still cannot ride the result and M14 must use a descriptor there.

The header is FIXED WIDTH (`"{d:0>5} {d:0>5}\n"`) so ImageIO decodes straight into the reply buffer
past it, rather than the bridge moving 100 KiB of pixels to make room for a shorter number.

**Long work goes off the loop thread through `HostBridge`'s worker carrier** — the seam
`docs/spikes/threaded-host-call-spike.zig` proved, now shipping: `poll_fn`/`pending_fn`/
`bind_services_fn`/`shutdown_fn`, three slots, each owning its own reply buffer. The dialogs,
`file.stat` and `file.copy` still answer SYNCHRONOUSLY from `request_fn`, which is legal and right
— a panel has to run on the main thread anyway. Slots carry an `abandoned` flag, which the spike
did not need and the real app does: a reset or a second drop mid-load leaves the old worker
running, and `feedHostResult` matches on key alone, so without it a superseded worker's pixels
would be delivered as the NEW file's preview.

Deleted, as planned: both `sips` spawns, `parseDimensions`, `thumbnail_path` and its two buffers,
and the `fx.loadImage`/`image_loaded` hop. Deleted beyond the plan: `Model.previewWidth`/
`previewHeight`. Those clamped the drawn size to the source because `sips -Z 160` UPSCALED anything
smaller (an 8x8 icon rendered as a 160x160 blur); ImageIO CAPS instead, measured across the fixture
set, so the registered size is already honest and the markup binds `preview_width`/`preview_height`
directly.

`Model` gained the source UTI beside `source_width`/`source_height`, as planned. Nothing in v0.2
reads it — it is there because M14 needs it and `image.probe` already returns it.

**One deliberate behavior change beyond the fixes: a probe that cannot be parsed now FAILS the
load.** Phase A tolerated an unparseable `sips -g` answer and let the thumbnail spawn be the format
gate. There is no second gate any more — the thumbnail is the same ImageIO read — so a probe that
cannot name the image's size is a file the preview could not have drawn either.

Deliberately KEPT until M14, because the encoder spawns still need them: the HEIC->PNG staging step
(`isHeicSource`, `heic_convert_key`, `convert_result`, `convert_failed`, `converted_path`) —
`avifenc`/`cwebp` still cannot read HEIC — plus `resolveSpawnEnviron`, the `which` probe and
`resolveAppTempPath`. `isHeicSource` still sniffs the EXTENSION rather than the UTI now sitting in
`Model`; switching it would be a behavior change (a mis-named HEIC would start staging) for a step
M14 deletes outright.

**M14 (v0.3) — vendored encoders, zero dependencies.** Split into M14a/b/c; see "Next up".
`native eject` to own `build.zig`, then swap `addApp` for `addAppArtifacts` so
`artifacts.exe.root_module` is reachable — `AppOptions` has no link passthrough, so owning the
build is the only route. **ALL OF THIS IS DONE — it was M14a** (2026-08-28); what follows is kept
as the record of why the build looks the way it does, and `build.zig`'s own comments are the live
version. The gate was passed earlier still (step 5, 2026-08-28): `addAppArtifacts` is
public in CLI 0.10.1 and returns `AppArtifacts{ exe, tests, install, run }`, `eject`'s output
builds, and a prebuilt `libwebp.a` links into the executable and runs. The hand-written-`build.zig`
fallback is not needed. Four things the spike settled that M14 must carry
(`docs/spikes/static-archive-link-spike.zig` has the evidence):
- **Wire BOTH `exe.root_module` and `tests.root_module`.** The exe's module is shared with the
  hidden `-analysis` object and `-model-contract` exe; the test artifact's is a separate Debug
  module that inherits nothing. Miss it and a test touching the archive dies on
  `undefined symbol: _WebPGetEncoderVersion` — CLAUDE.md's `_CFRelease` failure in a new coat.
- **`linkFramework` needs `addFrameworkPath`** on those same modules
  (`b.sysroot ++ "/System/Library/Frameworks"`; `addAppArtifacts` has already resolved
  `b.sysroot`), or the link fails with `searched paths:  none`.
- **Therefore M14 can fold `src/imageio_tests.zig` back into `native test`** — proven with a test
  calling `CGImageSourceGetTypeID()`. **DONE in M14a**, along with the rewrites it forced:
  CLAUDE.md's "`native test` links no frameworks" note, the run-by-hand instruction in
  `src/imageio_tests.zig`, and the matching claim in `src/imageio.zig`'s header.
- **`native eject` is one-shot and refuses if `build.zig`/`build.zig.zon` already exist.**
  `build`, `test` and `check` all keep working afterwards (`check` still validates markup against
  the model contract).

Vendor under `third_party/`, encode-only in every case (**DONE in M14a**; `third_party/README.md`
is the live record):
- **libwebp** + libsharpyuv — the second is MANDATORY, not a nicety: `picture_csp_enc.c.o` calls
  `SharpYuvConvert`/`SharpYuvInit`/`SharpYuvGetConversionMatrix` (measured in step 5, where the
  ReleaseFast exe linked clean without it and only the Debug test artifact failed — a missing
  companion archive can hide until the other artifact is built). No libwebpmux (animation is a
  non-goal), no libpng/libjpeg (those serve libwebp's tools, not the library).
- **libavif** (mux/encode API only) + **libaom** built `CONFIG_AV1_DECODER=0` (and
  `CONFIG_TUNE_VMAF=0` — Homebrew treats libvmaf as required, and we do not need it). libaom
  rather than SVT-AV1 (faster but much larger) or rav1e (pulls a Rust toolchain into a Zig
  build), because libaom is what `avifenc` itself uses and so is what reproduces today's output.
  No dav1d — decoding AVIF is ImageIO's job.

**The prebuild path is settled and the artifacts exist** (step 6, 2026-08-28). PLAN.md budgeted
libaom as the hard vendor because its `rtcd` dispatch headers (`aom_config.h`, `aom_dsp_rtcd.h`,
...) are GENERATED at configure time. That worry was correct about the mechanism and wrong about
the cost: CMake generates them itself using macOS's own `/usr/bin/perl`, so with cmake + ninja
installed the whole encode-only build is 22s. No meson (that is dav1d's build system and we vendor
no decoder) and no nasm (arm64 libaom is NEON intrinsics in plain C). Reproducing CMake's configure
step inside `build.zig` remains the thing NOT to attempt — M14 links the prebuilt archives.
Exact invocations, encode-only verification and the size numbers: `docs/phase-b-baseline.md`,
"Phase B step 6".

Both encoders consume `image.decode`'s FULL-RESOLUTION 8-bit RGBA (never `image.thumbnail`'s
160px buffer), so the HEIC staging hop disappears rather than being ported. Each encode also
needs `image.probe`'s source UTI to pick `yuvFormat` per the chroma table in "Correctness
requirements". The encoder stack, not the Zig, dominates binary size, and it is now MEASURED
rather than estimated: **+5.20 MiB** for a build referencing the real encoder entry points, landing
Smoosh around 10.7 MB. Linking pulls only referenced archive members, which is why the same
archives cost +1,424 bytes when only the version symbols are called — the 8.1 MB libaom.a is not
the price. All BSD-licensed and compatible with a local tool.

Deletes: both encoder spawns, the HEIC staging step in full (`isHeicSource`, `heic_convert_key`,
`convert_result`, `convert_failed`, `converted_path`, `resolveAppTempPath`), `resolveSpawnEnviron`,
the entire launch-time encoder probe (`initFx`, `encoder_check_result`, `avifenc_present`/
`cwebp_present`), the `missing_encoder` outcome, and all three brew-install messages. The app then
spawns no subprocesses at all.

### Correctness requirements for Phase B
`sips` does LESS implicitly than an earlier draft of this plan assumed (it preserves the source's
orientation tag and its ICC profile rather than resolving either), and a raw
`CGImageSourceCreateImageAtIndex` does none of it. Each item below is therefore behavior to
IMPLEMENT — some preserving what Phase A does, some fixing what it does wrong. Measurements are in
`docs/phase-b-baseline.md`.
- **Primary frame, not index 0. LANDED IN M13 for the probe and the preview; the ENCODER INPUT is
  still index 0 until M14** (a HEIC still reaches the encoders through the `sips` staging step,
  which takes index 0). Use `CGImageSourceGetPrimaryImageIndex`. **This is a live bug,
  not a precaution:** on `multi-primary.heic` (two top-level images, `pitm` naming the second) all
  three of today's `sips` calls take index 0, so the megapixel guard measures the wrong image, the
  card previews the wrong image, and the user gets a compressed copy of an image that was never
  the primary — silently. Note a real iPhone still does NOT reach this path: an HDR capture's gain
  map is an AUXILIARY image and `CGImageSourceGetCount` reports `frames 1`, so the fixture had to
  be synthesized.
- **Bake in EXIF orientation. LANDED IN M13 for the preview only** — `image.thumbnail` comes back
  upright, so the card no longer shows a sideways photo. The OUTPUT files are unchanged and still
  disagree with each other; that is M14's, because the encoders still read the source file.
  Read `kCGImagePropertyOrientation` and transform before encoding.
  `CGImageSourceCreateThumbnailAtIndex` with `kCGImageSourceCreateThumbnailWithTransform` does
  this FOR the preview (verified: a 4000x3000 source with Orientation 6 yields a 120x160
  thumbnail), so only `image.decode` needs the transform by hand. This also fixes today's
  inconsistency, where the same rotated source produces an upright AVIF and a sideways WebP —
  and where `avifenc` itself only writes `irot` for a JPEG input, not for a staged PNG.
- **Convert to sRGB and tag sRGB. LANDED IN M13 for the preview and in M14b for
  `imageio.decode`**, where the bitmap context does it for free; the outputs still carry whatever
  the encoders make of the source, until M14c feeds them decoded pixels.
  ImageIO passes the source profile through by default, so a
  Display P3 iPhone photo would emit P3. Web output is this tool's whole purpose, so convert:
  predictable rendering everywhere beats preserving a gamut most consumers mishandle. This is a
  deliberate, irreversible trade, recorded in "Key decisions carried forward." It is new for EVERY
  wide-gamut source — `sips` does NOT convert HEIC to sRGB — and it repairs a real bug on the WebP
  side, where `cwebp` strips the ICC profile and ships P3 numbers in an untagged (therefore sRGB)
  file that displays desaturated. Mechanically it is free: drawing into a
  `CGBitmapContextCreate(..., kCGColorSpaceSRGB)` performs the conversion, verified pixel-wise.
- **Strip metadata — an intentional CHANGE, not a do-nothing path.** Measured on a JPEG carrying
  TIFF+GPS tags: `avifenc` copies it through by default ("Exif Metadata: Present (210 bytes)",
  Make/Model/GPS all readable in the output AVIF) **and copies XMP too** (417-419 bytes on every
  staged-HEIC output, so HEIC sources leak as well), while `cwebp` carries none. So today Smoosh
  leaks GPS into AVIF but not WebP. Phase B strips both, which is the right web default AND makes
  the two formats consistent — but it will differ from current AVIF output and must be recorded
  as deliberate. Implementation-wise it is the do-nothing path (encoding from decoded pixels
  copies nothing unless asked); product-wise it is a change. It also drops the ICC tag, which is
  why sRGB must be tagged explicitly above. No toggle (see Non-goals).
- **Atomic write.** Encode to `<name>.<ext>.tmp` in the DESTINATION directory (a temp dir would
  cross filesystems and defeat the rename), then rename. Phase A does not do this either — a
  crash mid-encode currently can leave a truncated file beside the source.
- **Reproduce avifenc's chroma subsampling from the SOURCE CONTAINER. LANDED IN M14b** as
  `src/chroma.zig`, checked against every fixture; M14c is what feeds it to libavif. The single most
  consequential encoder knob, and invisible on photos while catastrophic on graphics (7.7 dB on a
  UI fixture). `avifenc --yuv auto` is **not** a content detector — it never inspects the image.
  It reads the source, and after M14 decodes everything to RGBA the container is gone, so the
  table must be carried explicitly:

  | Source | yuvFormat |
  |---|---|
  | JPEG | whatever the JPEG's own chroma sampling is |
  | PNG / HEIC / TIFF / GIF / WebP (color) | 4:4:4 |
  | grayscale | 4:0:0 (4:4:4 is harmless if simpler) |

  Verified empirically: the SAME UI image is 4:4:4 as a PNG and 4:2:0 as a JPEG, and
  `test-images/large.jpg` — a photograph — is 4:4:4 because the JPEG itself is 4:4:4
  (`1x1,1x1,1x1`). A HEIC is 4:4:4 today only because `sips` stages it to PNG first.

  **Do NOT simplify this to "JPEG -> 4:2:0".** It is wrong on our own primary fixture, and wrong
  in the case that motivated vendoring libaom: measured, a JPEG written at quality >=90 is
  `1x1,1x1,1x1` (4:4:4) and `avifenc` gives it YUV444, while the same image at q80 is 4:2:0 ->
  YUV420. Hardcoding 420 would silently soften every high-quality JPEG, screenshots included.
  **Do NOT invent an "is this photographic?" heuristic.** That is new behavior and would disagree
  with v0.1 on exactly the files used to justify vendoring libaom.
- **A JPEG source needs its chroma sampling parsed by hand. LANDED IN M14b**
  (`chroma.parseJpegSampling`, matching ImageMagick on all six real JPEG fixtures).
  ImageIO does not expose it —
  re-checked in this round by dumping the FULL property dictionary for a 4:2:0 JPEG (`ui.jpg`) and
  a 4:4:4 one (`large.jpg`): the two are identical apart from dimensions (ColorModel, Depth,
  PixelWidth/Height, ProfileName, {JFIF}), with no sampling key of any kind. So "keep the JPEG's own chroma" requires scanning the source for its SOF marker
  and reading the first component's sampling factors: `1x1` -> 4:4:4, `2x1` -> 4:2:2, `2x2` ->
  4:2:0, one component -> grayscale. About 20 lines; a prototype reproduces ImageMagick's reading
  of all three JPEG fixtures exactly. Do not assume JPEG means 4:2:0 — our own primary fixture is
  the exception.
- **Decode to 8-bit RGBA — in `image.decode` and `image.thumbnail` only. LANDED IN M13** for
  `image.thumbnail` (`drawToRgba8` pins 8 bits per channel); `image.probe` allocates no bitmap at
  all, as required. Pin those two bitmap
  contexts to 8 bits per channel rather than inheriting the source's depth. `image.probe`
  allocates no bitmap at all and must stay that way. A 16-bit source is otherwise carried into the encoder at higher
  depth for no benefit, and it is what triggers the ImageIO alpha bug recorded in "Key decisions
  carried forward." This is load-bearing on the CURRENT fixture set, not a hypothetical:
  `small.png` reports Depth 16 and `tiny.png` reports Depth 1.
- **The decoded buffer is PREMULTIPLIED and TOP-DOWN.** `CGBitmapContextCreate`'s only 8-bit RGBA
  layout is `kCGImageAlphaPremultipliedLast`, and row 0 of the backing store is the image's TOP row
  (both verified in the spike). No vertical flip is needed feeding an encoder that wants top-down
  rows, but an encoder wanting STRAIGHT alpha must un-premultiply — which matters for exactly one
  fixture, `alpha16.png`. **M13 un-premultiplies in `drawToRgba8`, so `src/imageio.zig` returns
  STRAIGHT alpha to every caller** — not an optimisation but a contract: `fx.registerImage`
  documents its input as straight-alpha RGBA8, and libwebp/libavif want the same, so having one
  convention leave the module beats two callers each remembering to convert.
- **An undecodable file is detected by frame COUNT, not by a null source. LANDED IN M13** —
  `imageio.probe` returns `error.NotAnImage` off the count, and that failure is the format gate the
  thumbnail spawn used to be.
  `CGImageSourceCreateWithURL` SUCCEEDS on `not-an-image.jpg` (49 bytes of text) and returns a
  non-null source; `CGImageSourceGetCount() == 0` (and a null `GetType()`) is what says "not an
  image". Test the count, or the undecodable-input error arrives later and as the wrong message.

### Format selection
- User choice in the UI:
  - **AVIF** — best compression for modern browsers
  - **WebP** — broader compatibility
  - **Both** (default) — produce both files so the source can serve AVIF with WebP fallback for older browsers
- When "Both" is selected, two files are written (e.g. `photo.avif` + `photo.webp`) and each shows
  its own savings line — never a summed "combined savings," since no client ever downloads both.

### File acquisition
- Primary: native open dialog via `runtime.showOpenDialog`, called from a `HostCallBinding.request_fn`
  bound by hand in `src/main.zig` — see CLAUDE.md's "File acquisition, honestly" for the full pattern
  and why it requires a hand-authored root.
- Secondary: real window-wide drag-and-drop via `UiApp.Options.on_drop` (SDK 0.8.2+), which re-enters
  the exact same load chain a picked file does.
- Accepts common raster formats that macOS ImageIO / platform codecs can decode (JPEG, PNG, WebP,
  HEIC/HEIF, TIFF, GIF, BMP).

### Output handling
- Auto-save next to the source file (e.g. `photo.jpg` → `photo.avif` / `photo.webp`) as soon as "Smoosh" completes — no save dialog in the default path.
- If an output file already exists, overwrite it silently. Re-running "Smoosh" on the same source is treated as "redo this."
- Each landed result row carries its own save icon, an optional secondary action to copy that one
  file to a different location; it does not replace auto-save.

### Error states
Each maps to a user-facing message and the `.failed` Model state:
- Encoder binary missing (`avifenc` and/or `cwebp` not found) → name the missing tool + `brew install` command.
- Unsupported/undecodable input format → name the file and expected formats.
- Input exceeds size/megapixel limit → show the limit and the file's actual size.
- Encode failed (non-zero exit from `fx.spawn`) → surface a short, non-technical message; encoder stderr is not surfaced.
- Write to output path failed (permissions, disk full, read-only volume) → name the reason if known.
- HEIC/HEIF staging step failed → one shared message, not a per-format one (see "Encoding strategy").

`.failed` is always paired with a populated `error_message_buffer`; the list above enumerates every
message that can land there, and no other path may set `.failed`.

### Input size limits
- **100 MB** or **50 megapixels**, whichever comes first (both checks inclusive: exactly 100 MB or
  exactly 50.0 MP passes).
- Rationale: a local tool should be more permissive than a typical web upload limit, but still needs
  to protect against pathological files that would exhaust memory when decoded to RGBA.
- Clear, friendly error when exceeded, naming both the file's actual size and the limit.

### Verification strategy
Every change should end with a check against the *running* app, not just a compile check.
- `native build` + `native check` are necessary but never sufficient.
- `native automate widget-click` drives the real UI for anything reachable without a native dialog
  or a real file drop.
- **Never automate a native file dialog** (open or save panel) — the app runs as a bare executable
  under `native dev`/`native build`, and System Events cannot bring it frontmost, so global keystrokes
  land on whatever IS frontmost instead. Have the user drive every dialog by hand.
- **File drops cannot be automated at all** (a different constraint, same practical answer): have the
  user drag a real file onto the window by hand.
- Test fixtures live under `test-images/` (gitignored): a small PNG, a large JPEG, a HEIC, a WebP, an
  already-tiny PNG (negative-savings case), a non-image file renamed `.jpg`, and one file over the
  size limit.
- **M13 was verified live, by hand, over six drops** (2026-08-28, `native dev`), since neither a
  drop nor a dialog can be automated. `multi-primary.heic` previews 160x50 — the 640x200 primary,
  where the shipping app draws the 400x300 image at index 0; `rotated-gps.jpg` previews 120x160
  upright; `tiny.png` draws 8x8, not a 160x160 blur; `not-an-image.jpg` fails at the PROBE with the
  supported-formats message and no preview widget in the tree; `oversized.jpg` fails at 51 MP
  before anything is decoded. The regression check is the one that matters most: `large.jpg`
  smooshed to **717,003 B AVIF and 671,054 B WebP — byte-identical to the recorded baseline**, not
  merely inside the +/-15% gate. That is what "the encoders are untouched" has to mean.
- **The Phase A baseline is RECORDED** — `docs/phase-b-baseline.md`, taken before any Phase B code,
  with size, PSNR, AVIF `yuvFormat`, decoded dimensions and metadata presence for every fixture.
  It is the +/-15% gate for M13/M14 and cannot be reconstructed afterwards, so treat it as
  append-only. It also carries five measured findings about the SHIPPING app; the ones that change
  Phase B are folded into "Correctness requirements" and "Known limitations" above.
- **The fixture set has GROWN, and one gap remains.** Every fixture used to be a photograph, sRGB,
  with `orientation: <nil>`, and `test-images/large.jpg` is an atypical 4:4:4 JPEG — generalizing
  from that set already produced a wrong encoder recommendation once. Seven fixtures were added:

  | Fixture | Proves | Status |
  |---|---|---|
  | `photo-420.jpg` | the common JPEG path; `large.jpg` (4:4:4) is the exception, not the rule | added |
  | `ui.jpg` | that a JPEG UI stays 4:2:0 — matching Phase A, not "improving" it | added |
  | `ui.png` | the 4:4:4 path; the fixture class that separates the encoders (7.7 dB) | added |
  | `rotated-p3.heic` | orientation + color conversion, and HEIC's 4:4:4 path (synthetic) | added |
  | `iphone-rotated-p3.heic` | the same from a REAL iPhone 13 Pro capture, with real Apple metadata | added |
  | `rotated-gps.jpg` | orientation baking + the EXIF/GPS/XMP strip, on a JPEG | added |
  | `p3.heic` | wide-gamut conversion without the rotation variable | added |
  | `multi-primary.heic` | primary-frame selection (`pitm` names index 1) | added |
  | `alpha16.png` | the depth/alpha edge case | added |
  | `gray.jpg` | the 4:0:0 path | added |

  The set now covers every requirement. Closing the primary-frame gap corrected an assumption in
  the process: a real Live Photo would NOT have closed it. An iPhone HDR capture's gain map is an
  auxiliary image, so ImageIO still reports `frames 1`; only a HEIC with two TOP-LEVEL images and a
  `pitm` naming the second makes `GetPrimaryImageIndex` return non-zero. That fixture immediately
  found a live bug — see "Known limitations".

  `test-images/large.jpg` (4:4:4 JPEG) stays and is now load-bearing: it is the fixture that
  proves the chroma table reads the source rather than assuming 4:2:0. Two fixtures nobody had
  characterized turned out to matter: `small.png` is 16-bit and `tiny.png` is 1-bit, so the
  8-bit-pinning requirement is exercised by the set as it stands.

  All are gitignored, so they are tier-2 material only; `docs/phase-b-baseline.md` carries the
  recipe for regenerating each one.
- **Chroma subsampling is a verification output, not just an encode setting.** Every AVIF the
  M14 gate produces gets its `yuvFormat` read back (`avifdec --info`) and compared against the
  Phase A baseline for the same fixture. A size-and-PSNR match with the wrong subsampling is a
  failure.

### Testing strategy
Two tiers, in this order. Reaching for the GUI to answer a question a unit test answers faster is
the failure mode to avoid.

**Tier 1 — `native test` (`src/tests.zig`).** Deterministic, no GUI, no processes, no network. This
is where logic gets proven.

**`native test` LINKS FRAMEWORKS AS OF M14a, so ImageIO is now reachable from tier 1.** The
constraint it replaces, found in M13 from the SDK source, is worth keeping because its SHAPE still
applies: `build/app.zig` derives `test_app_mod` as a fresh Debug module whenever
`app_optimize != optimize` (and `app_optimize` defaults to ReleaseFast), so `linkPlatform` — which
adds `linkFramework("AppKit")` and everything ImageIO rides in on — never runs on it. Any test
reaching `imageio.probe`/`thumbnail` died at LINK time on `undefined symbol: _CFRelease`, in ANY
file reachable from `main.zig`. M14a's ejected `build.zig` states the frameworks on
`artifacts.tests.root_module` itself, and `src/imageio_tests.zig` is now imported by `main.zig`'s
`test` block and runs under `native test` (suite went 108 -> 116: 5 ImageIO tests plus 3 encoder
link probes). Its tests embed their own PNGs rather than reading `test-images/`, so they still run
on a fresh clone.

**The trap generalizes to anything you link next.** `exe.root_module` and `tests.root_module` are
separate modules; wire only the exe and the failure shows up solely in the test artifact. The seam is the same dispatch path the runtime uses: build the markup
against the real `Model`, find a widget, ask the tree for the `Msg`, feed it to `update`.
- Effects-bearing paths drive `Effects` in fake-executor mode (`fx.executor = .fake`, via the
  `Harness` in `src/tests.zig`) — assert the *request* an arm made, then feed the answer and drain.
- What tier 1 does *not* cover: whether the host actually shows an `NSOpenPanel`, whether an encoder
  binary really exists, whether anything renders. Those are tier 2 by definition.

**Tier 2 — `native automate` against `native dev`.** Proves the real seam end to end. `native build`
is ReleaseFast and has neither automation nor hot reload — verification runs against `native dev`.

**Fixtures are gitignored**, so tier-1 tests must never read `test-images/`. Anything image-shaped
in a unit test uses in-repo bytes: `canvas.png.writeRgba8` to encode a raw RGBA fixture plus
`harness.null_platform.image_decode = true` for the decode→register→draw path.

**Phase B moves the tier-1 seam, in two steps. M13 did the first.** The LOAD chain (probe,
thumbnail) now drives `pendingHostAt`/`pendingHostCount` + `feedHostResult` instead of
`pendingSpawnAt`/`feedExit`; the ENCODE chain still drives spawns and moves with M14. The
migration also let three tests get SHARPER rather than merely ported: the reset-staleness tests now
assert `error.EffectNotFound` from a post-reset `feedHostResult`, which proves the cancel really
silences the answer rather than that a status guard happens to drop it — and that proof is why the
load chain's status guards could go. Suite is 108 tests.

## Key decisions carried forward
Quick reference; full rationale for each is in `docs/plan-v0.1-archive.md`.
- **Partial failure in "Both" mode is partial SUCCESS.** The two encodes are independent; one landing
  while the other fails is `.done` with the failure named in the status bar. Only an all-failed run
  is `.failed` — the encoders write their own output files, so anything else would contradict a file
  already on disk.
- **A shared prerequisite failure (the HEIC staging step) is NOT independent** — if it fails, neither
  requested format could have started, so it fails the whole run directly with one message rather than
  going through the per-format partial-failure join.
- **Signed ad-hoc, not notarized, not unsigned**, for a single-machine local tool with no paid Apple
  Developer identity. Revisit only if this ever needs sharing with someone else.
- **Save As is per-format, not a single "Both" action.** Each result row has its own save icon
  (`save_avif_as`/`save_webp_as`), each running its own one-shot save-dialog-then-copy round — no
  queue, since `showSaveDialog` only ever needs to answer one path at a time this way. Pressing
  either icon while a round is already in flight is a no-op.
- **AVIF encoding stays on libaom; ImageIO does decoding only.** ImageIO encodes AVIF natively
  and on PHOTOGRAPHS is indistinguishable from `avifenc -q 58 --speed 6`: at matched size on
  `test-images/large.jpg`, 714,717 B at 35.65 dB PSNR against 717,003 B at 35.73 dB — 0.08 dB,
  far under the ~0.5 dB just-noticeable threshold — while running 2.6x faster. Generalizing from
  photographs alone is the trap. On a UI/screenshot fixture (flat color, colored text, sharp
  edges) `avifenc` produced 7,515 B at 47.77 dB in YUV444 where ImageIO's best was 9,911 B at
  40.04 dB in YUV420: 32% LARGER and 7.7 dB worse. Raising quality does not help — ImageIO
  plateaus near 40 dB (14,904 B at 40.35 dB) because it is hard-locked to YUV420 chroma
  subsampling. ImageIO exposes no subsampling control (the headers offer
  `kCGImageDestinationLossyCompressionQuality` and nothing for chroma) and q=1.0 fails to produce
  a file at all. Screenshots and UI exports are core input for a web-asset tool, so this would be
  a real regression against what v0.1 already ships. The ImageIO speed win is not a regression to
  give up — 0.60s IS today's speed — and the eject/static-link work is paid once for libwebp
  regardless, so libaom's true marginal cost is binary size alone (~5 MB on 5.8 MB).
- **ImageIO's AVIF encoder has an alpha interop bug, which reinforces the above.** A 16-bit source
  with alpha makes it emit a 10-bit AVIF whose alpha plane libavif/dav1d cannot decode
  ("Decoding of alpha plane failed") — that is Chrome and Firefox. Reproducible; 8-bit sources are
  unaffected. Moot once libaom does the encoding, and defended against anyway by pinning the
  decode to 8-bit RGBA (see "Correctness requirements").
- **Phase B targets Phase A's output closely, because it uses the same encoders.** Vendoring
  libaom and libwebp means the pinned settings (AVIF q58/speed6, WebP q80) carry over literally
  rather than being re-derived against an opaque knob. Bytes need not be identical — `avifenc`
  and `cwebp` are CLI front-ends whose defaults (subsampling selection, alpha quality, tiling)
  must be replicated deliberately through the C APIs — but the gate is tight: Phase A's recorded
  sizes +/-15%, no visible regression, and matching chroma subsampling on both a photo and a
  graphics fixture.
- **Long work runs off the loop thread through the WORKER-CARRIER seam, not `feedHostResult`.**
  `Effects` offers spawn/fetch/file/db/pty/channel and nothing that runs arbitrary Zig off-loop, so
  the seam is a `HostCallBinding.request_fn` that returns WITHOUT answering. An earlier draft had
  the worker call `effects.feedHostResult` directly; that is WRONG, and the spike
  (`docs/spikes/threaded-host-call-spike.zig`) corrected it. `HostCallBinding`'s own doc comment is
  explicit that a host answers "on the loop thread — synchronously from `request_fn`, or later from
  an event the host marshals back", and the marshal seam already exists: the optional carrier trio
  `poll_fn` / `pending_fn` / `bind_services_fn`, plus `shutdown_fn`. The worker parks its answer in
  a bridge-owned mailbox and calls `services.wake()`; `hasPending` consults `pending_fn` and
  `adoptHostCompletions` drains `poll_fn` on the loop thread, calling `feedHostResult` itself.
  Measured live: two concurrent workers (1.36s and 2.21s of saturated CPU) delivered correctly
  while a 100ms timer kept firing (14 and 22 ticks) and `gpu_frame` advanced throughout — the loop
  never blocked. `shutdown_fn` is not optional: it is the one window in which a still-running
  worker can be joined while `PlatformServices` is still live. Note this is a hitch Phase B
  INTRODUCES — today's subprocess encode never blocks the loop.

## Known limitations
All five of the new entries below were measured while recording the Phase A baseline; the numbers
are in `docs/phase-b-baseline.md`. Every one of them is fixed by Phase B, and M13 has now fixed the
INPUT side of three of them — what the app measures and shows. The OUTPUT side of all three is
still Phase A's, because the encoders still read the source file themselves; M14 is what closes
them. Each entry says which half it is in.
- **Smoosh requires `brew install libavif webp`.** The app detects the missing tools and names the
  install command, but a zero-friction local tool should not need either. This is what Phase B
  exists to remove.
- **A WebP or AVIF source produces nothing at all.** `avifenc` cannot read either container
  ("Unrecognized file format" / "Unsupported file format AVIF") and `cwebp` cannot read AVIF, so a
  `.webp` source fails AVIF while WebP is skipped as `same_path` — and an `.avif` source fails WebP
  while AVIF is skipped — leaving the whole run `.failed`. Both formats are in the open panel's
  filter list and both are accepted on drop, so this is reachable from the UI. The archive records
  the `same_path` decision but not that the OTHER format cannot be produced.
- **An orientation-tagged source produces one upright file and one sideways one.** OUTPUT SIDE,
  still live. The PREVIEW is fixed as of M13 — the card shows the photo upright. `avifenc`
  translates EXIF Orientation into an AVIF `irot` transform; `cwebp` ignores orientation entirely.
  Worse, `avifenc` only does this for a JPEG input — the same tag arriving via the `sips`-staged
  PNG (any rotated HEIC) yields `Transformations: None` and a sideways AVIF too.
- **A Display-P3 source produces a desaturated WebP.** OUTPUT SIDE, still live. The PREVIEW is
  fixed as of M13 — it is converted to sRGB before it is registered. `cwebp` strips the ICC
  profile, so P3 pixel
  numbers ship in an untagged (therefore sRGB) file. `avifenc` preserves the gamut correctly, via
  CICP primaries from a PNG input or an embedded ICC profile from a JPEG one — so the two outputs
  of one "Both" run do not match.
- **A multi-image HEIC compresses the WRONG image, silently.** OUTPUT SIDE, still live — and this
  one M13 fixed TWO of three ways. `sips` takes index 0 where the file's `pitm` box names another
  item as primary; the megapixel guard and the preview card now go through
  `CGImageSourceGetPrimaryImageIndex` and get the real one, but the ENCODER still reads the source
  through the `sips` staging step and still gets index 0. So the card now shows a different image
  than the file it writes, which is worse-looking but more honest: the discrepancy is visible
  instead of silent. M14 deletes the staging step and closes it.
- **A crash mid-encode can leave a truncated output** beside the source; the encoders write their
  destination directly. Fixed by Phase B's atomic write.

## Next up
Phase B, in order. M13 and M14 are separately shippable. **Steps 1-8 are DONE** (2026-08-27/29) —
every spike is behind us, both M14 gates are passed, M14a landed the build ownership and the
vendored archives, and M14b landed the decode path and the chroma table. **M14c is next, is
unblocked, and is all that is left of M14.**

M14 was split into three because it does not fit one sitting: M14a (build + vendor) was the fully
de-risked half and moved no output byte; M14b was pure logic and moved none either; M14c is the
encoder swap plus an open-ended parity investigation, and is the step where output bytes finally
change.

1. ~~**Spike the threaded host command.**~~ **DONE** — `docs/spikes/threaded-host-call-spike.zig`.
   Verdict: works, but NOT the way this plan assumed. `feedHostResult` is loop-thread-only; the
   supported seam is `HostCallBinding`'s worker-carrier trio (`poll_fn`/`pending_fn`/
   `bind_services_fn`) plus `shutdown_fn`. Two concurrent saturated-CPU workers delivered while the
   loop kept ticking and painting. Also settled the 256 KiB host-result cap that shapes M13. Full
   findings and caveats in the spike's header; the corrected decision is in "Key decisions carried
   forward".
2. ~~**Spike ImageIO from Zig, standalone.**~~ **DONE** — `docs/spikes/imageio-decode-spike.zig`,
   run over the whole fixture set. Verdict: works, ~90 lines of `extern fn` cover all three
   commands. Proved orientation baking in the thumbnail path (and its absence in the full-decode
   path), P3->sRGB conversion by the bitmap context alone, top-down premultiplied output, that
   ImageIO still exposes no JPEG chroma key, and that an undecodable file is detected by frame
   COUNT rather than a null source. Primary-frame selection remains unproven — see step 3's gap.
3. ~~**Record the Phase A baseline** and grow the fixture set.~~ **DONE** —
   `docs/phase-b-baseline.md`: size, PSNR, `yuvFormat`, decoded dimensions and metadata presence
   for 18 fixtures, ten of them new. It confirmed PLAN.md's chroma table empirically and surfaced
   five shipping bugs now recorded in "Known limitations". The fixture set has no gaps left; every
   requirement in "Correctness requirements" has a file that exercises it.
4. ~~**M13 (v0.2)** — ImageIO decode, preview and probe. Encoders untouched.~~ **DONE**
   (2026-08-28). Two host commands, not three (`image.decode` deferred to M14, which is its only
   consumer); the preview pixels ride the host result rather than a descriptor, behind a comptime
   assert; the worker carrier ships with an `abandoned` flag the spike did not need. Full account
   in the M13 entry above; live verification in "Verification strategy".
5. ~~**Spike the link path** — the M14 gate.~~ **DONE** (2026-08-28) —
   `docs/spikes/static-archive-link-spike.zig`, run against a throwaway `zig-core` app on CLI
   0.10.1 / Zig 0.16.0. Verdict: works, and the SDK fights it less than expected.
   `addAppArtifacts` is public and `native eject`'s output builds; Homebrew's `libwebp.a` links
   into the exe and `WebPGetEncoderVersion` returns 1.6.0 from the running app. Two things beyond
   the plan: `tests.root_module` is a SEPARATE module that must be wired too, and `linkFramework`
   needs an explicit `addFrameworkPath` — which together mean M14 can bring `imageio_tests.zig`
   back into `native test`. Also measured: libsharpyuv is mandatory. Full findings and the
   untested edges (vendoring, `native dev`/`package`, x86_64) in the spike's header.
6. ~~**Spike the encoder artifacts.**~~ **DONE** (2026-08-28) — all three archives built
   encode-only for arm64-macos under `~/Code/zig/smoosh-vendor`, verified in the linkspike, and
   fully written up in `docs/phase-b-baseline.md` under "Phase B step 6". Verdict: works, and
   **libaom was not the hard vendor PLAN.md budgeted for** — CMake generates the `rtcd` headers
   itself using macOS's own `/usr/bin/perl`, no nasm and no meson, and the whole build is 22s.
   `brew install cmake ninja` was the only prerequisite. Four things beyond the plan:
   - **The +5 MB estimate is confirmed at +5.20 MiB**, measured three ways (no archives / version
     symbols only / real encoder entry points referenced). Smoosh lands around 10.7 MB. The
     version-only row is +1,424 bytes — the 8.1 MB archive is not the cost, the referenced members
     are.
   - **`AVIF_LIBYUV=OFF` and `AVIF_LIBSHARPYUV=OFF` are output-parity requirements.** `AVIF_LIBYUV`
     defaults to `SYSTEM` and would silently swap in different RGB->YUV math than the baseline's
     `avifenc` used. Getting these wrong moves output bytes and nothing in the build says so.
   - **libavif.a must precede libaom.a in the link order** — it leaves all 15 `aom_codec_*`
     symbols undefined.
   - **Output parity is NOT yet proven.** Our libaom is `-O3` (upstream Release) where Homebrew's
     is `-Os`, and libaom's rate control carries floating-point math, so M14 must re-encode the
     fixture set against the Phase A table rather than assume the bitstream is unchanged.
7. ~~**M14a — own the build, vendor the archives.**~~ **DONE** (2026-08-28). `native eject` ran;
   `build.zig` and `build.zig.zon` are ours and the CLI drives `zig build`. `build.zig` swaps
   `addApp` for `addAppArtifacts` and links the four encode-only archives plus the three ImageIO
   frameworks into BOTH `exe.root_module` and `tests.root_module`, transplanted from the step-5
   spike. Archives and the two headers we call are vendored under `third_party/` (8.8 MB, tracked)
   with `third_party/README.md` recording provenance. `src/encoders.zig` is created holding ONLY
   version probes; `src/imageio_tests.zig` is folded into `native test`. Suite 108 -> 116, `check`
   zero warnings, exe 5,522,248 -> 5,522,376 bytes (+128) and `otool -L` shows no new dylibs.
   Four things worth carrying:
   - **The exe does not reference the archives yet, only the test artifact does.** `encoders.zig`
     is reachable from `tests.zig`, not from `main`, so the ReleaseFast exe emits none of the
     extern symbols and the +128 bytes is framework wiring, not encoder code. The exe-side link is
     proven by the step-5 spike (which called into the archive from a running GUI app), not by
     this tree. It stops being a question the moment M14c calls an encoder.
   - **`native dev` and `native package` both work on an ejected tree** — two of the three edges
     the spike left open. Verified live: `native dev` built Debug, launched, rendered the full
     20-widget tree with `markup_watch=armed`, and `native automate snapshot` drove it. The third
     edge (x86_64/universal) is untouched and out of scope.
   - **The version pins are a real gate, not decoration.** `encoders.pinned` holds libwebp 1.6.0 /
     libavif 1.4.2 / libaom v3.14.1 and three tests assert them, so a re-copied archive cannot
     change the encoder out from under `docs/phase-b-baseline.md` silently.
   - **`native eject` is one-shot and refuses if the files exist.** There is no re-ejecting to
     pick up CLI changes; `build.zig` is now a file we maintain.
8. ~~**M14b (v0.3)** — the decode path and the chroma table.~~ **DONE** (2026-08-29).
   `imageio.decode` (full-res 8-bit sRGB RGBA, primary frame, EXIF transform by hand) and
   `src/chroma.zig` (the JPEG SOF parser plus the source-container table). Neither has a caller;
   M14c's encode seams are the only consumers. Four things worth carrying:
   - **`decode` is NOT a host command, deliberately.** PLAN.md said "pure logic plus one host
     command"; the host command is the wrong shape. A full-resolution buffer cannot ride a 256 KiB
     host result (M13 already recorded this), and `decode`'s only caller will be M14c's encode
     worker — which is already off the loop thread and can call it directly. Wiring a command with
     no Msg arm would have shipped an unreachable path, which is exactly what M13 refused to do
     for the same function.
   - **The orientation bake goes through three SCALAR CTM calls, not `CGContextConcatCTM`.**
     `CGAffineTransform` is six doubles: neither an HFA nor register-sized on arm64, so passing it
     by value puts a C-ABI question between us and the one Phase B requirement whose failure mode
     is a WRONG IMAGE rather than an error. Every EXIF orientation is `translate . (quarter turn?)
     . scale`, so `imageio.orientationTransform` returns that decomposition and three scalar calls
     apply it. Proven three independent ways: the table re-derived algebraically in
     `src/tests.zig`, all eight orientations decoded from synthesized tagged PNGs in
     `src/imageio_tests.zig`, and `rotated-gps.jpg`/`rotated-p3.heic` checked corner-by-corner
     against their untagged twins. **CoreGraphics' quarter turns are EXACT permutations** — no
     resampling, so the pixel assertions are equality rather than tolerance.
   - **ImageIO reads PNG `eXIf` chunks**, which is what lets the eight-orientation test stay a
     synthesized PNG built in-process instead of dragging a JPEG or TIFF fixture into a file that
     has to work on a fresh clone (`test-images/` is gitignored).
   - **The fixture inventory had `oversized.jpg` recorded as 4:4:4; it is 4:2:0.** Corrected in
     `docs/phase-b-baseline.md` with a note. Nothing depended on it (the 50 MP guard blocks the
     fixture, so it has no encode row) and it is a source property rather than an encoder
     measurement, so it does not touch the gate. The chroma table matches ImageMagick on all six
     real JPEGs and matches the baseline's `AVIF yuv` column on all fourteen fixtures that have
     one.
9. **M14c (v0.3)** — the two encode seams in `src/encoders.zig` (libwebp and libavif, written
   together so they share a shape), atomic write, then the deletions: both encoder spawns, the HEIC
   staging step in full, `resolveSpawnEnviron`, the launch probe, `missing_encoder`, the brew
   messages. Then the tier-1 encode tests migrate off `pendingSpawnAt`/`feedExit` (23 call sites)
   onto the new seam, and the fixture set is re-encoded against the Phase A table.
   **Budget the parity investigation as real work, not a checkbox** — our libaom is `-O3` where
   Homebrew's is `-Os` and rate control carries FP math, so the bitstream may legitimately differ.
   Keep M14c in ONE session: the two seams should rhyme, and breaking mid-parity-investigation
   loses the per-fixture state that makes it tractable.

UI polishing remains unplanned and now sits behind Phase B.
