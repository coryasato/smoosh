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
`brew install libavif webp` to do anything. See "Known limitations" and Phase B below.

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
- Metadata-preservation toggles (EXIF, GPS, ICC) — Phase B strips by default; revisit only on request
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

Phase B is a DEPENDENCY-REMOVAL round, not a feature round. Nothing user-facing changes. The
success criterion is one sentence: Smoosh works on a Mac where nothing is installed. That is also
the scope gate — anything that does not shrink the dependency surface or preserve current
behavior is out.

The shape is set by one platform fact: **macOS ImageIO encodes AVIF natively and cannot encode
WebP** (`CGImageDestinationCopyTypeIdentifiers()` lists `public.avif`, not `public.webp`).
Measured against our own `test-images/large.jpg`, ImageIO produced 633,154 B in 0.23s where
`avifenc -q 58 --speed 6` produced 717,003 B in 0.60s — smaller and 2.6x faster, hardware
accelerated on Apple Silicon. So AVIF needs no third-party code whatsoever, and only WebP needs a
vendored library. The two halves also have very different build risk, which is why they are two
milestones rather than one.

**M13 (v0.2) — ImageIO decode + native AVIF.** No build-graph change: `CGImageSource*`/
`CGImageDestination*` link via AppKit, which the SDK already links. New C-ABI surface lives in
`src/imageio.zig` as plain `extern fn` declarations (not `@cImport`, which would need include
paths; CoreFoundation types are opaque pointers and declare cleanly). Three new host commands on
`HostBridge`, each answering off-thread:
- `image.probe` — primary-frame index + dimensions from `CGImageSourceCopyPropertiesAtIndex`,
  WITHOUT decoding. Replaces the `sips -g` spawn and feeds the existing megapixel guard, which
  today runs only after a decode has already happened.
- `image.thumbnail` — decode, orient, convert to sRGB, downscale to 160px longest edge, hand back
  RGBA for `fx.registerImage`. Replaces the `sips` thumbnail spawn AND `fx.loadImage` AND the
  entire temp-file path.
- `image.encodeAvif` — decode primary frame, orient, convert to sRGB, encode via
  `CGImageDestinationCreateWithURL` with `public.avif`, write to a `.tmp` in the DESTINATION
  directory, then rename.

Deletes: `isHeicSource`, `heic_convert_key`, the `convert_result` arm and the `convert_failed`
outcome (ImageIO reads HEIC directly, so the staging hop is moot); the two `sips` spawns and
`parseDimensions`; `thumbnail_path`, `converted_path`, `resolveAppTempPath` and its four buffers;
the avifenc half of the launch probe. `resolveSpawnEnviron` and the `which` machinery must stay —
`cwebp` is still spawned.

**M14 (v0.3) — vendored libwebp, zero dependencies.** `native eject` to own `build.zig`, then
swap `addApp` for `addAppArtifacts` so `artifacts.exe.root_module` is reachable — `AppOptions`
has no link passthrough, so ejecting is the only route. Vendor libwebp under `third_party/` and
compile its encoder sources with `addCSourceFiles` (no libpng/libjpeg: those serve libwebp's
tools, not the library). `image.encodeWebp` reuses M13's decode/orient/sRGB pipeline, then
`WebPConfig`/`WebPPicture` at quality 80 and the same tmp-then-rename write.

Deletes: the `cwebp` spawn, `resolveSpawnEnviron` in full, the entire launch-time encoder probe
(`initFx`, `encoder_check_result`, `avifenc_present`/`cwebp_present`), the `missing_encoder`
outcome, and all three brew-install messages. The app then spawns no subprocesses at all.

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
  deliberate, irreversible trade, recorded in "Key decisions carried forward."
- **Strip metadata by default.** Building a destination from a decoded `CGImage` copies no
  metadata unless asked, so this is the do-nothing path — but it also drops the ICC tag, which is
  why sRGB must be tagged explicitly above. No GPS reaches an output. No toggle (see Non-goals).
- **Atomic write.** Encode to `<name>.<ext>.tmp` in the DESTINATION directory (a temp dir would
  cross filesystems and defeat the rename), then rename. Phase A does not do this either — a
  crash mid-encode currently can leave a truncated file beside the source.

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
- **Two fixtures are missing and block the correctness requirements.** Every current fixture is
  sRGB with `orientation: <nil>`, so nothing in the tree exercises orientation, color, or
  multi-frame handling. Add a rotated Display-P3 iPhone HEIC and a Live Photo HEIC. Both are
  gitignored, so they are tier-2 material only.

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

**Phase B moves the tier-1 seam.** Most encode and load coverage in `src/tests.zig` drives fake
SPAWNS; after M13/M14 those paths are host requests, so the assertions move to
`pendingHostCount`/`pendingHostAt` + `feedHostResult`. This is a real migration across a
2,519-line suite, not a mechanical rename, and it is part of each milestone rather than a
follow-up.

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
- **AVIF via ImageIO, not a vendored libavif.** "Statically link libavif" hides libaom: libavif is
  a wrapper and the real encoder is an AV1 encoder, a large CMake C project. macOS ImageIO
  encodes AVIF natively and, measured on `test-images/large.jpg`, produced 633,154 B in 0.23s
  against `avifenc -q 58 --speed 6`'s 717,003 B in 0.60s. AVIF therefore needs zero third-party
  code; only WebP needs a vendored library.
- **Phase B output is calibrated to a size band, not matched byte-for-byte.** ImageIO's knob is
  `kCGImageDestinationLossyCompressionQuality`, an opaque 0.0-1.0 float with no published mapping
  to `avifenc -q` and no speed knob at all. Bytes cannot be identical across two encoders. The
  gate is Phase A's recorded sizes +/-15% with no visible regression, not reproduction.
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
Phase B, in order. M13 and M14 are separately shippable; the spike gates both.
1. **Spike the threaded host command** (`docs/spikes/threaded-host-call-spike.zig`, following
   `dialog-open-file-spike.zig`'s precedent): a `request_fn` that spawns a `std.Thread`, returns
   immediately, and feeds `feedHostResult` from that thread. Prove the Msg lands and the window
   still paints. If this does not work, stop and re-plan — every long operation in M13/M14
   depends on it.
2. **Record the Phase A baseline** and add the two missing fixtures.
3. **M13 (v0.2)** — ImageIO decode + native AVIF.
4. **M14 (v0.3)** — vendored libwebp; zero dependencies.

UI polishing remains unplanned and now sits behind Phase B.
