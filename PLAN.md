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

**One limitation is now open and drives the next two rounds:** Smoosh requires
`brew install libavif webp` to do anything. Phase B removes that by moving decoding to ImageIO
(M13) and vendoring the encoders (M14). See "Known limitations" and Phase B below.

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
1. **Metadata is stripped.** Measured: `avifenc` copies EXIF/GPS today, `cwebp` does not.
2. **Outputs are written atomically.** Phase A can leave a truncated file; this is a reliability
   fix that does not strictly belong to dependency removal, but it is one screenful and rides along.
3. **Display-P3 sources are converted to sRGB.** Already true for HEIC (which `sips` stages
   through PNG), but new for a P3 JPEG, which `avifenc` currently passes through its own ICC path.

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

**M13 (v0.2) — ImageIO decode, preview and probe.** No build-graph change and no encoder change:
the `avifenc`/`cwebp` spawns stay exactly as they are. This rests on ImageIO already being linked,
which is confirmed from the shipped binary's own load commands rather than inferred —
`otool -L zig-out/bin/smoosh` lists ImageIO, CoreGraphics and CoreFoundation directly. M14's eject
should still add an explicit `linkFramework("ImageIO")` rather than keep depending on that.

New C-ABI surface lives in `src/imageio.zig` as plain `extern fn` declarations (not `@cImport`,
which would need include paths; CoreFoundation types are opaque pointers and declare cleanly),
proven standalone by the spike in "Next up" before being wired into `HostBridge`. **Keep the
surface tiny** — `CGImageSourceCreateWithURL`, `GetPrimaryImageIndex`, `CopyPropertiesAtIndex`,
`CreateImageAtIndex`, `CreateThumbnailAtIndex`, plus only the CF/CG calls actually used. Do not
redeclare half of ImageIO. Three new host commands, each answering
off-thread. They are deliberately separate because they have different cost profiles — conflating
the preview and encode paths is how a 160px thumbnail ends up as the encoder's input:
- `image.probe` — properties only: primary-frame index, pixel dimensions, source UTI and
  orientation, via `CGImageSourceCopyPropertiesAtIndex`. Decodes NOTHING. Replaces the `sips -g`
  spawn and feeds the existing megapixel guard, which today runs only after a decode has already
  happened. The UTI it returns is what M14's chroma table keys on.
- `image.thumbnail` — preview only, <=160px, 8-bit sRGB RGBA with orientation baked, for
  `fx.registerImage`. Use `CGImageSourceCreateThumbnailAtIndex` with
  `kCGImageSourceThumbnailMaxPixelSize`, `kCGImageSourceCreateThumbnailFromImageAlways` and
  `kCGImageSourceCreateThumbnailWithTransform` (which applies orientation for us) — NOT a full
  `CGImageSourceCreateImageAtIndex`. Smoosh accepts up to 50 MP; decoding all of it to draw a
  160px card would be absurd. Replaces the `sips` thumbnail spawn AND `fx.loadImage` AND its temp
  file.
- `image.decode` — FULL-RESOLUTION primary frame, 8-bit sRGB RGBA, orientation baked, profile
  converted. This is the encoder's input, and the only one that needs
  `CGImageSourceCreateImageAtIndex` drawn into an 8-bit sRGB bitmap context. It has no consumer
  until M14, so it may land here or with the encoders — but it must exist and must never be
  confused with `image.thumbnail`.

Deletes: the two `sips` spawns, `parseDimensions`, `thumbnail_path` and its two buffers, and the
`fx.loadImage`/`thumbnail_result` hop. `Model` gains the source UTI alongside `source_width`/
`source_height`, since M14 needs it and `image.probe` is already returning it.

Deliberately KEPT until M14, because the encoder spawns still need them: the HEIC->PNG staging
step (`isHeicSource`, `heic_convert_key`, `convert_result`, `convert_failed`, `converted_path`) —
`avifenc`/`cwebp` still cannot read HEIC — plus `resolveSpawnEnviron`, the `which` probe and
`resolveAppTempPath`.

**M14 (v0.3) — vendored encoders, zero dependencies.** One build round for both formats.
`native eject` to own `build.zig`, then swap `addApp` for `addAppArtifacts` so
`artifacts.exe.root_module` is reachable — `AppOptions` has no link passthrough, so owning the
build is the only route. Treat `eject`/`addAppArtifacts` as a SPIKE GATE, not a given: both are
CLI-version-specific (the tree pins no SDK version, so `native build` links whatever the global
CLI carries). If `eject`'s output is unusable, the fallback is to hand-write a `build.zig` calling
the same public `addAppArtifacts` — NOT "pass linker flags", since without an owned build there is
nowhere to pass them; Zig has no source-level link pragma. Vendor under `third_party/`, encode-only in every case:
- **libwebp** + libsharpyuv. No libwebpmux (animation is a non-goal), no libpng/libjpeg (those
  serve libwebp's tools, not the library).
- **libavif** (mux/encode API only) + **libaom** built `CONFIG_AV1_DECODER=0` (and
  `CONFIG_TUNE_VMAF=0` — Homebrew treats libvmaf as required, and we do not need it). libaom
  rather than SVT-AV1 (faster but much larger) or rav1e (pulls a Rust toolchain into a Zig
  build), because libaom is what `avifenc` itself uses and so is what reproduces today's output.
  No dav1d — decoding AVIF is ImageIO's job.

**libaom is the hard vendor, not libwebp — budget for it separately.** libwebp is plain C and
will compile through `addCSourceFiles` with some pain. libaom will not: its build deps are
cmake + ninja + meson + python, and its per-architecture `rtcd` dispatch headers
(`aom_config.h`, `aom_dsp_rtcd.h`, ...) are GENERATED at configure time. That generation, not
assembly, is the real obstacle — on arm64-macOS libaom uses NEON intrinsics in C and needs no
external assembler (nasm is x86-only), so this is a configure problem, not a toolchain one. The
pragmatic path is to PREBUILD `libaom.a`, `libavif.a` and `libwebp.a` for arm64-macos once and
link the artifacts, rather than reproducing CMake's configure step inside `build.zig`. Prove
that before writing any encoder Zig.

Both encoders consume `image.decode`'s FULL-RESOLUTION 8-bit RGBA (never `image.thumbnail`'s
160px buffer), so the HEIC staging hop disappears rather than being ported. Each encode also
needs `image.probe`'s source UTI to pick `yuvFormat` per the chroma table in "Correctness
requirements". Expect the encoder stack, not the Zig, to dominate binary size: roughly +5 MB
against today's 5.8 MB. All BSD-licensed and compatible with a local tool.

Deletes: both encoder spawns, the HEIC staging step in full (`isHeicSource`, `heic_convert_key`,
`convert_result`, `convert_failed`, `converted_path`, `resolveAppTempPath`), `resolveSpawnEnviron`,
the entire launch-time encoder probe (`initFx`, `encoder_check_result`, `avifenc_present`/
`cwebp_present`), the `missing_encoder` outcome, and all three brew-install messages. The app then
spawns no subprocesses at all.

### Correctness requirements for Phase B
Today `sips` applies orientation and color conversion implicitly. A raw
`CGImageSourceCreateImageAtIndex` does not, so each of these is behavior to PRESERVE, not add:
- **Primary frame, not index 0.** Live Photos and portrait HEICs carry extra images. Use
  `CGImageSourceGetPrimaryImageIndex`.
- **Bake in EXIF orientation.** Read `kCGImagePropertyOrientation` and transform before encoding,
  or a sideways iPhone photo stays sideways.
- **Convert to sRGB and tag sRGB.** ImageIO passes the source profile through by default, so a
  Display P3 iPhone photo would emit P3. Web output is this tool's whole purpose, so convert:
  predictable rendering everywhere beats preserving a gamut most consumers mishandle. This is a
  deliberate, irreversible trade, recorded in "Key decisions carried forward." Note it is already
  today's behavior for HEIC (`sips` stages through PNG) but NOT for a Display-P3 JPEG, which
  `avifenc` currently reads through its own ICC path — that one file type will retint slightly.
- **Strip metadata — an intentional CHANGE, not a do-nothing path.** Measured on a JPEG carrying
  TIFF+GPS tags: `avifenc` copies it through by default ("Exif Metadata: Present (214 bytes)",
  Make/Model/GPS all readable in the output AVIF), while `cwebp` carries none. So today Smoosh
  leaks GPS into AVIF but not WebP. Phase B strips both, which is the right web default AND makes
  the two formats consistent — but it will differ from current AVIF output and must be recorded
  as deliberate. Implementation-wise it is the do-nothing path (encoding from decoded pixels
  copies nothing unless asked); product-wise it is a change. It also drops the ICC tag, which is
  why sRGB must be tagged explicitly above. No toggle (see Non-goals).
- **Atomic write.** Encode to `<name>.<ext>.tmp` in the DESTINATION directory (a temp dir would
  cross filesystems and defeat the rename), then rename. Phase A does not do this either — a
  crash mid-encode currently can leave a truncated file beside the source.
- **Reproduce avifenc's chroma subsampling from the SOURCE CONTAINER (M14).** The single most
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
- **A JPEG source needs its chroma sampling parsed by hand (M14).** ImageIO does not expose it —
  `CGImageSourceCopyPropertiesAtIndex` has no sampling/chroma key for either a 4:2:0 or a 4:4:4
  JPEG (checked). So "keep the JPEG's own chroma" requires scanning the source for its SOF marker
  and reading the first component's sampling factors: `1x1` -> 4:4:4, `2x1` -> 4:2:2, `2x2` ->
  4:2:0, one component -> grayscale. About 20 lines; a prototype reproduces ImageMagick's reading
  of all three JPEG fixtures exactly. Do not assume JPEG means 4:2:0 — our own primary fixture is
  the exception.
- **Decode to 8-bit RGBA — in `image.decode` and `image.thumbnail` only.** Pin those two bitmap
  contexts to 8 bits per channel rather than inheriting the source's depth. `image.probe`
  allocates no bitmap at all and must stay that way. A 16-bit source is otherwise carried into the encoder at higher
  depth for no benefit, and it is what triggers the ImageIO alpha bug recorded in "Key decisions
  carried forward."

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
- **Record the Phase A baseline before touching code.** Every fixture's current output size goes
  into `docs/phase-b-baseline.md`; it is the +/-15% gate for M13/M14 and cannot be reconstructed
  afterwards.
- **The fixture set cannot verify Phase B and must grow.** Every current fixture is a photograph,
  sRGB, with `orientation: <nil>`. Worse, `test-images/large.jpg` is an atypical 4:4:4 JPEG, so
  the one JPEG we test on does not represent the common case. Generalizing from this set already
  produced a wrong encoder recommendation once. Add:

  | Fixture | Proves |
  |---|---|
  | 4:2:0 JPEG photo | the common JPEG path; `large.jpg` (4:4:4) is the exception, not the rule |
  | JPEG screenshot (4:2:0) | that a JPEG UI stays 4:2:0 — matching Phase A, not "improving" it |
  | PNG screenshot / UI export | the 4:4:4 path; the fixture that separates the encoders (7.7 dB) |
  | rotated Display-P3 iPhone HEIC | orientation + color conversion, and HEIC's 4:4:4 path |
  | Live Photo HEIC | primary-frame selection |
  | 16-bit PNG with alpha | the depth/alpha edge case |
  | grayscale JPEG or PNG | the 4:0:0 path |

  `test-images/large.jpg` (4:4:4 JPEG) stays and is now load-bearing: it is the fixture that
  proves the chroma table reads the source rather than assuming 4:2:0.

  All are gitignored, so they are tier-2 material only.
- **Chroma subsampling is a verification output, not just an encode setting.** Every AVIF the
  M14 gate produces gets its `yuvFormat` read back (`avifdec --info`) and compared against the
  Phase A baseline for the same fixture. A size-and-PSNR match with the wrong subsampling is a
  failure.

### Testing strategy
Two tiers, in this order. Reaching for the GUI to answer a question a unit test answers faster is
the failure mode to avoid.

**Tier 1 — `native test` (`src/tests.zig`).** Deterministic, no GUI, no processes, no network. This
is where logic gets proven. The seam is the same dispatch path the runtime uses: build the markup
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

**Phase B moves the tier-1 seam, in two steps.** Coverage in `src/tests.zig` drives fake SPAWNS
today. M13 moves the LOAD chain (probe, thumbnail) to host requests; M14 moves the ENCODE chain.
Both land on `pendingHostCount`/`pendingHostAt` + `feedHostResult` instead of the spawn
assertions. This is a real migration across a 2,519-line suite, not a mechanical rename, and each
half belongs to its own milestone rather than a follow-up.

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
- **Long work runs off the loop thread via a host command, because there is no worker effect.**
  `Effects` offers spawn/fetch/file/db/pty/channel and nothing that runs arbitrary Zig off-loop.
  The seam is a `HostCallBinding.request_fn` that returns WITHOUT answering, with a worker thread
  calling `effects.feedHostResult` when it finishes (`feedHostResult` uses atomic slot state and
  calls `wakeHost()`, so it is built for this). Every `request_fn` in `HostBridge` today answers
  synchronously, so this is a new pattern and gets its own spike. Note this is a hitch Phase B
  INTRODUCES — today's subprocess encode never blocks the loop.

## Known limitations
- **Smoosh requires `brew install libavif webp`.** The app detects the missing tools and names the
  install command, but a zero-friction local tool should not need either. This is what Phase B
  exists to remove.
- **A crash mid-encode can leave a truncated output** beside the source; the encoders write their
  destination directly. Fixed by Phase B's atomic write.

## Next up
Phase B, in order. M13 and M14 are separately shippable. Step 1 is a hard gate for both; steps 5 and 6
are hard gates for M14 specifically.
1. **Spike the threaded host command** (`docs/spikes/threaded-host-call-spike.zig`, following
   `dialog-open-file-spike.zig`'s precedent): a `request_fn` that spawns a `std.Thread`, returns
   immediately, and feeds `feedHostResult` from that thread. Prove the Msg lands and the window
   still paints. If this does not work, stop and re-plan — every long operation in M13/M14
   depends on it.
2. **Spike ImageIO from Zig, standalone** (`docs/spikes/imageio-decode-spike.zig`): open
   `photo.heic`, print the primary-frame index, dimensions and UTI, and dump decoded 8-bit RGBA to
   a PPM. Proves the Zig-to-C-ABI seam — `extern fn` declarations, CoreFoundation lifetime rules,
   `CFRelease` discipline — before any of it is entangled with `HostBridge`.
3. **Record the Phase A baseline** and grow the fixture set (see "Verification strategy"). For
   every fixture record size, PSNR AND `yuvFormat` — subsampling is half of what M14 must match,
   and it cannot be recovered later.
4. **M13 (v0.2)** — ImageIO decode, preview and probe. Encoders untouched.
5. **Spike the link path** — the M14 gate, and the one the SDK actively fights. `native eject`,
   swap `addApp` for `addAppArtifacts`, and link ONE prebuilt `.a` (libwebp is the smaller
   target) into `artifacts.exe.root_module`; call `WebPGetEncoderVersion` from Zig and print it.
   Only once that links and runs is vendoring anything else worth starting.
6. **Spike the encoder artifacts** — produce `libwebp.a`, `libavif.a` and `libaom.a` for
   arm64-macos, encode-only, and record the exact configure invocations in
   `docs/phase-b-baseline.md`. Separate from step 5 because it is a build-system problem, not a
   linking one, and libaom's generated `rtcd` headers are where it will bite.
7. **M14 (v0.3)** — vendored libwebp + libavif/libaom; zero dependencies.

UI polishing remains unplanned and now sits behind Phase B.
