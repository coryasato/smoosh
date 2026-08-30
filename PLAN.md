# Smoosh — PLAN.md

> Living plan. Update this file as decisions are made. Full v0.1 development history (every
> "settled/found here" decision, live-verification writeups, mutation-testing findings) lives in
> `docs/plan-v0.1-archive.md` — this file stays lean and current.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern web formats (AVIF and/or WebP) without leaving your desktop.

## Status
**v0.1 shipped** (M1-M12, archived). Pick or drop an image, choose AVIF/WebP/Both, Smoosh
auto-saves next to the source; each landed result row carries its own save icon to copy that one
file elsewhere, packaged as an ad-hoc-signed `.app`.

**Phase B is COMPLETE (v0.3).** M13 moved decode/preview/probe onto ImageIO; M14 (a/b/c) moved
encode onto vendored libavif/libaom/libwebp linked into the binary. **Smoosh now runs on a Mac
where nothing is installed** — no `brew`, no subprocess of any kind. `native test` 118/118,
`native check` zero warnings, `native build` clean at 10.94 MB. See the M14c entry below and
`docs/phase-b-baseline.md` "M14c" for the parity re-measurement.

**M13 (v0.2) was DONE** (2026-08-28). The load chain runs on ImageIO: a new
`src/imageio.zig` holds the whole C-ABI seam, two new host commands (`image.probe`,
`image.thumbnail`) answer off the loop thread through `HostBridge`'s worker carrier, and both
`sips` spawns, `fx.loadImage`, `parseDimensions`, the preview temp file and the drawn-size clamp
are gone. `native test` 108/108, `native check` zero warnings, `native build` clean at 5.5 MB.
Steps 1-3 (the two prerequisite spikes and the Phase A baseline) were done 2026-08-27.
**Steps 5 and 6 (both M14 gates) are DONE** (2026-08-28). The link path is proven
(see `build.zig`; `addAppArtifacts` is real in CLI 0.10.1), and so are
the artifacts: encode-only `libwebp.a` + `libsharpyuv.a`, `libavif.a` and `libaom.a` are built for
arm64-macos and link into both a running ReleaseFast exe and the Debug test artifact, at a measured
cost of +5.20 MiB. Written up in `docs/phase-b-baseline.md` under "Phase B step 6". Nothing in
THIS tree is ejected or vendored yet — that is M14.

**M14c is DONE** (2026-08-29) — **M14 is complete and Smoosh has zero dependencies.** The two
encode seams (`encoders.encodeAvif`/`encodeWebp`, a C shim in `src/encode.c` over the vendored
libavif/libaom/libwebp) run inside a new `image.encode` host command, answered off the loop thread
by `HostBridge`'s worker carrier: the worker `imageio.decode`s the source at full resolution,
encodes, and writes the output **atomically** (`createFileAtomic` -> `replace`). The whole
subprocess apparatus is gone — both encoder spawns, the `sips` HEIC staging step in full, the
launch-time `which` probe, `resolveSpawnEnviron`, `missing_encoder`/`convert_failed`, the three
brew messages. **The app spawns nothing.** Suite 114 (launch-probe / HEIC-staging / env tests
deleted, real-encode smoke tests added), `check` zero warnings, exe 5.52 MB -> 10.94 MB (+5.4 MB,
the referenced encoder members — matches the step-6 estimate). Parity re-encode of the whole
fixture set is under `docs/phase-b-baseline.md`, "M14c": every real photograph and both graphics
fixtures land within ±15% of the Phase A sizes with matching chroma; two rows fall outside and
neither is a regression (`multi-primary.heic` was the wrong-image bug, now fixed; `alpha16.png`
AVIF is a 1.5 KB delta on a synthetic gradient — flagged, not tuned).

**M14b is DONE** (2026-08-29): `src/imageio.zig` grew `decode` — full-resolution, primary frame,
EXIF orientation baked in BY HAND, sRGB, 8-bit, straight alpha, no metadata — and `src/chroma.zig`
holds the JPEG SOF parser and the source-container chroma table. Both pure; M14c's `image.encode`
worker is the consumer of each.

**M14a is DONE** (2026-08-28): `native eject` ran, `build.zig` is ours and links the four vendored
encode-only archives under `third_party/` into both the exe and the test artifact, and
`src/imageio_tests.zig` runs under `native test`.

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
fallback is not needed. Four things the spike settled that M14 must carry (the spike is gone —
`build.zig` is its live version and carries all four as comments):
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
- **"Overwrite silently" is about a previous OUTPUT, never the source.** A format whose destination
  would BE the source is skipped (`EncodeOutcome.same_path`), and the comparison is
  CASE-INSENSITIVE because macOS volumes are: on the default case-insensitive APFS, `Photo.AVIF`
  and the `Photo.avif` this derives are one file, so a byte-exact compare let the atomic write
  replace the user's original with a lossy re-encode of itself. Found in the Phase B review and
  fixed there; pinned by three tests in `src/tests.zig`. Symlinked and hardlinked destinations are
  still not covered — that needs an `Io` to stat with, which `update` can never hold.
- Each landed result row carries its own save icon, an optional secondary action to copy that one
  file to a different location; it does not replace auto-save.

### Error states
Each maps to a user-facing message and the `.failed` Model state:
- Source unreadable (`file.stat` failed) → "Can't read that file."
- Unsupported/undecodable input → name the expected formats. `image.probe` is the gate, and it
  reports off the frame COUNT, not a null source (`CGImageSourceCreateWithURL` succeeds on 49
  bytes of text named `.jpg`).
- Input exceeds the size or megapixel limit → show the limit and the file's actual size.
- Preview could not be built (`image.thumbnail` failed, or its reply would not parse) → one
  message; the load fails rather than showing a card with no image.
- Encode failed (the worker could not decode the source, or libavif/libwebp rejected the frame) →
  a short, non-technical message. There is no encoder stderr to surface any more.
- Write to output path failed (permissions, disk full, read-only volume) → points at the folder.
- Destination would be the source → skipped, and named as such ("already an AVIF file").

**Three v0.1 error states no longer exist**, and their absence is the point of Phase B: "encoder
binary missing" (nothing to install), "non-zero exit from `fx.spawn`" (no subprocess), and
"HEIC/HEIF staging step failed" (ImageIO decodes HEIC directly). Messages naming `brew`, `avifenc`
or `cwebp` are gone from the app entirely.

In "Both" mode a per-format failure is a WARNING on a `.done` run, not a `.failed` one — only a run
where no requested format landed sets `.failed` (see "the partial-failure decision" in `main.zig`).

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

### Closed by Phase B
All six entries below were measured while recording the Phase A baseline (`docs/phase-b-baseline.md`)
and **all six are now closed by Phase B**. Kept here as the record of what the round fixed.
- **~~Smoosh requires `brew install libavif webp`.~~ CLOSED by M14.** The encoders are vendored
  static archives linked into the binary; the app spawns no subprocess and needs nothing installed.
- **~~A WebP or AVIF source produces nothing at all.~~ CLOSED.** M13 gave ImageIO the decode (it
  reads both containers); M14c encodes from those pixels, so a `.webp` source now produces a real
  AVIF and an `.avif` source a real WebP. `same_path` still skips WebP->WebP / AVIF->AVIF, as
  intended.
- **~~An orientation-tagged source produces one upright file and one sideways one.~~ CLOSED.**
  `imageio.decode` bakes the EXIF orientation into the pixels by hand (M14b), so both outputs are
  upright and identical in geometry. Measured on `rotated-gps.jpg` / `rotated-p3.heic`.
- **~~A Display-P3 source produces a desaturated WebP.~~ CLOSED.** The decode converts to sRGB in
  the bitmap context and drops the ICC profile; the AVIF encoder re-tags sRGB via CICP. Both
  outputs now carry the same, correct color.
- **~~A multi-image HEIC compresses the WRONG image, silently.~~ CLOSED.** The encode worker
  decodes through `CGImageSourceGetPrimaryImageIndex`, same as the guard and the preview since M13.
  `multi-primary.heic` now compresses its 640x200 primary (the Phase A row shows the 400x300
  index-0 image the `sips` staging step took — see `docs/phase-b-baseline.md` "M14c").
- **~~A crash mid-encode can leave a truncated output.~~ CLOSED.** The worker writes
  `<name>.<ext>` via `createFileAtomic` + `replace` — a temp sibling in the destination directory,
  renamed into place. A crash leaves the temp, never a half-written output.

### Open, introduced by Phase B
- **"Both" decodes the source twice.** The two formats are two independent `image.encode` workers
  (that independence is the partial-failure decision, and it is what the design wants), and each
  calls `imageio.decode` on the same file. The cost is **peak memory, not latency**: two
  full-resolution RGBA buffers are live at once, up to ~400 MB at the 50 MP guard. Wall-clock is
  not the concern — the two decodes run concurrently on separate threads, where Phase A staged a
  HEIC once but then wrote an intermediate to disk and had `avifenc` and `cwebp` each decode THAT
  across three process spawns, largely serially. Whether Phase B is actually slower for a large
  HEIC has **not been measured**; `avifenc`/`cwebp` are still installed, so it can be, against
  master. Sharing one decode between the two workers would mean a refcounted buffer outliving both
  slots — real complexity for a memory win only, so it is a deliberate trade, not an oversight.

## Next up
**Phase B is COMPLETE — steps 1-9 are all DONE** (2026-08-27/29). Every spike, both M14 gates,
M13, and M14a/b/c. Smoosh has zero dependencies. What remains is unplanned UI polishing
(see the end of this section).

M14 was split into three: M14a (build + vendor) moved no output byte; M14b (decode + chroma table)
moved none either; M14c swapped the encoders in, wrote outputs atomically, deleted the subprocess
apparatus, and re-measured parity — two rows outside ±15%, neither a regression
(`docs/phase-b-baseline.md` "M14c").

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
5. ~~**Spike the link path** — the M14 gate.~~ **DONE** (2026-08-28) — run against a throwaway
   `zig-core` app on CLI 0.10.1 / Zig 0.16.0; the spike file was deleted post-Phase-B, its
   findings now living in `build.zig`. Verdict: works, and the SDK fights it less than expected.
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
9. ~~**M14c (v0.3)** — the two encode seams, atomic write, the deletions, the test migration, and
   the parity re-encode.~~ **DONE** (2026-08-29). Things worth carrying:
   - **The encoder ABI is a C shim (`src/encode.c`), not hand-rolled `extern struct`s.** libavif's
     `avifEncoder` (~30 caller-mutable fields) and `avifRGBImage` and libwebp's
     `WebPConfig`/`WebPPicture` are struct-heavy and ABI-fragile to transcribe; the shim
     `#include`s the vendored headers, does the struct work in C, and exposes three flat scalar
     functions `encoders.zig` declares. `build.zig` compiles it with `link_libc` on the module.
   - **`build.zig`'s module list must be de-duplicated.** For `native build` (ReleaseFast) the SDK
     hands back the SAME `*Build.Module` for `exe` and `tests` (`app_optimize == optimize`), so
     adding a compiled `.c` to both is a fatal `duplicate symbol`. Linking an `.a` twice was only
     wasteful, which is why M14a's loop got away with it. `build.zig` now compares the pointers.
   - **`image.encode` is a host command on the existing worker carrier**, one request per format.
     The worker decodes + encodes + writes atomically (`createFileAtomic` -> `replace`) and replies
     with just the output size. No `image.decode` host command was ever needed — the worker calls
     `imageio.decode` directly, off the loop thread.
   - **Parity: two rows outside ±15%, neither a regression.** `multi-primary.heic` (baseline
     encoded the wrong index-0 image; M13's primary-frame fix changed which picture is compressed)
     and `alpha16.png` AVIF (+1.5 KB on a synthetic gradient — flagged, not tuned). Every real
     photograph and both graphics fixtures within ±15%, most within ±5%. Full table in
     `docs/phase-b-baseline.md` "M14c".
   - The decode is NOT shared between the two formats in Both mode — each `image.encode` worker
     decodes independently. Simpler; a shared-decode optimization is possible later.
   - **A `reset` cannot cancel a running encode worker** (`avifEncoderWrite` has no cancellation
     token), so the worker runs to completion holding its slot; its stale answer is dropped three
     ways (the `abandoned` flag, the cancel's generation bump, `.encode_result`'s status guard).
     `worker_slot_count` is 8 so a person cannot pile up abandoned encodes faster than they drain
     (reset -> drop -> smoosh is three actions, and neither the drop nor a dialog can be
     automated); a full pool degrades to one `.encode_failed`, still better than v0.1's unbounded
     `avifenc` spawn.
   - The `image.encode` payload is **NUL-delimited**, not newline — a macOS path may contain `\n`.

UI polishing remains unplanned and now sits after a complete Phase B.

## Roadmap — post-Phase-B sessions

Five tracks, written down at the end of the Phase B review session (2026-08-30) so the next
session can start from a decision rather than re-derive one. **Ordering matters for the first
two; the rest are independent.** Each carries a model/effort suggestion — these are judgment
calls about how much of the work is taste versus mechanism, not benchmarks.

### 1 + 4. Condense the markdown, and cut the comments — ONE pass, not two
**Do this first. It unblocks everything else by making the tree navigable.**

These are the same job. A large fraction of the comment bulk is *history* ("this used to be X
before M14a", "the `sips -g` hop this replaces"), and that is exactly what a CHANGELOG absorbs —
so splitting them into two passes means touching every file twice.

Scope: a `CHANGELOG.md` taking the M1-M14 narrative out of PLAN.md and
`docs/plan-v0.1-archive.md`; PLAN.md shrinking to decisions, requirements and open work; CLAUDE.md
losing its "Current status" duplication (it already tells itself not to restate PLAN.md, and does).

**The comment rule — use this, not a volume target.** The comments are the most valuable thing in
this repo and a size-driven cleanup would take out the load-bearing ones first, because they are
the longest.
- **Cut:** historical narration, anything a CHANGELOG entry now covers, anything restating what
  the code plainly says.
- **Keep:** traps that cost a day to rediscover (`build.zig`'s two modules, the framework search
  path, the archive link order, the mandatory libsharpyuv), non-obvious WHY (the scalar CTM calls
  over `CGAffineTransform`, the fixed-width preview header, NUL-delimited payloads), and
  invariants (`.failed` is always paired with a message; "do not simplify JPEG to 4:2:0").

**Also fold in: delete the two remaining spikes.** `docs/spikes/dialog-open-file-spike.zig` and
`threaded-host-call-spike.zig` are frozen snapshots whose every conclusion now ships in tested
code, and a drifted reference is worse than none. ~48 inbound references across 8 files, which is
why it belongs in this pass rather than on its own. **Salvage first:** the threaded spike's
measured evidence (a 100 ms timer fired 14 times across a 1.36 s worker and `gpu_frame` advanced
105 -> 353, proving the loop never blocked) is a measurement, not restatable from the shipping
code — move it into the CHANGELOG. `imageio-decode-spike.zig` is the only real keep-case (it
builds standalone, so it can isolate an ImageIO regression from the SDK), but
`src/imageio_tests.zig` covers the same surface and actually runs. The link-path spike was already
deleted this way (2026-08-30); `build.zig` is its live version.

*Suggested: **Opus 5, high effort.** Deciding what is load-bearing requires understanding why each
comment exists, across the whole tree at once — the case where the strongest model earns its cost.*

### 2. Performance
**Measure before touching anything.** The app is already effectively instant on normal photos, and
optimizing without a number is how the parity gate gets perturbed for nothing. Every change here
must be re-checked against `docs/phase-b-baseline.md`.

Ranked by payoff-to-risk:
- **`drawToRgba8`'s `@memset(pixels, 0)`** — a full-buffer write, up to 200 MB, redundant because
  our transforms always cover the whole destination. Cheapest real win, no parity risk.
- **`encoder->maxThreads = 1`** — the single biggest wall-clock lever on large photos. Set for
  determinism while parity was being established; parity is banked now, so this is re-measurable
  as a decision rather than a constraint.
- **libaom rebuilt `-Os` instead of `-O3`** — Homebrew's is 5.4 MB against our 8.1 MB, so this
  meaningfully cuts the 10.94 MB binary. Needs a full parity re-measure: libaom's rate control
  carries FP math and optimization level can change contraction.
- **`copy_out`'s extra malloc+memcpy** of the whole encoded buffer in `src/encode.c` — tidy, low
  payoff, zero risk.
- **The Both-mode double decode** — see "Known limitations". Memory, not latency.

*Suggested: **Opus 5, medium** for the measuring and the first two items; **high** if touching
encoder settings or rebuilding an archive, where the parity judgment is the whole task.*

### 3. UI and style polish
Independent of everything else — run it whenever. The `design` skill and Claude Design flows fit
here. Constraint to respect: the app is meant to live in a corner of the desktop, so it must stay
correct at `window_min_width` (420) and the layout floor recorded in `main.zig`.

*Suggested: **Opus 5, medium.** Iterative and visual; the work is in the looking, not the
reasoning.*

### 5. The standalone-app review
This is the umbrella, not a task, and the Phase B review (2026-08-30) already covered its
correctness half — one real bug found and fixed (the case-insensitive `same_path` collision).
What it did NOT touch, and what this track should:
- **arm64-only.** `third_party/README.md` calls x86_64 "unexplored". This is a genuine gap the
  moment the `.app` is handed to anyone else.
- **Notarization.** Currently ad-hoc signed; fine for one machine, not for distribution.
- **The app icon**, still a placeholder (README says so).
- **Launch time**, never measured.

*Suggested: **Opus 5, high**, or run `/code-review ultra` for the correctness sweep — it is
user-triggered and billed, so it cannot be launched from inside a session.*
