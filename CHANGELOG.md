# Changelog

How Smoosh got here. This file holds the narrative — what landed when, what was decided along the
way, and the measurements behind those decisions. `PLAN.md` holds the current state: decisions
still in force, requirements, and open work. If a fact matters to changing the code *today*, it
belongs in PLAN.md or in a source comment; if it explains a road already travelled, it is here.

Versions are the app's own. Milestone numbers (M1-M14) are the development shorthand used
throughout the sessions that built it, kept because the commit log and `docs/phase-b-baseline.md`
both refer to them.

---

## v0.3 — zero dependencies (2026-08-29)

**Smoosh runs on a Mac where nothing is installed.** No `brew`, no `avifenc`, no `cwebp`, no
subprocess of any kind. Encode moved onto vendored static libavif / libaom / libwebp linked into
the binary, fed by ImageIO's own decode.

`native test` 118/118, `native check` zero warnings, `native build` 10.94 MB (from 5.52 MB — the
+5.4 MB is the referenced encoder members).

**Six limitations closed**, all of them measured on the shipping v0.1 app while recording the Phase
A baseline:

- **Smoosh required `brew install libavif webp`.** The encoders are vendored static archives now.
- **A WebP or AVIF source produced nothing at all.** ImageIO reads both containers, so a `.webp`
  source now produces a real AVIF and an `.avif` source a real WebP. (`same_path` still skips
  WebP→WebP and AVIF→AVIF, as intended.)
- **An orientation-tagged source produced one upright file and one sideways one.** `avifenc` only
  wrote `irot` for a JPEG input, not for a staged PNG. The decode bakes the orientation into the
  pixels, so both outputs are upright and identical in geometry.
- **A Display-P3 source produced a desaturated WebP.** `cwebp` stripped the ICC profile and shipped
  P3 numbers in an untagged — therefore sRGB — file. The decode converts, and the AVIF encoder
  re-tags sRGB via CICP.
- **A multi-image HEIC compressed the WRONG image, silently.** All three `sips` calls took index 0,
  so the megapixel guard measured, the card previewed, and the encoder compressed an image the file
  never called primary. Everything now reads `CGImageSourceGetPrimaryImageIndex`.
- **A crash mid-encode could leave a truncated output.** The worker writes a temp sibling in the
  destination directory and renames it into place.

### M14c — the encode seams, atomic write, and the deletions

`image.encode` became a host command on the existing worker carrier, one request per output
format. The worker decodes the source at full resolution through ImageIO, runs libavif/libwebp,
writes the output atomically (`createFileAtomic` → `replace`), and replies with just the output
size.

Deleted outright: both encoder spawns, the HEIC→PNG staging step in full (`isHeicSource`,
`heic_convert_key`, `convert_result`, `convert_failed`, `converted_path`, `resolveAppTempPath`),
`resolveSpawnEnviron`, the launch-time `which` probe (`initFx`, `encoder_check_result`,
`avifenc_present`/`cwebp_present`), the `missing_encoder` outcome, and all three brew-install
messages. Three v0.1 error states ceased to exist along with them: "encoder binary missing",
"non-zero exit from `fx.spawn`", and "HEIC staging failed".

Decisions worth keeping:

- **The encoder ABI is a C shim (`src/encode.c`), not hand-rolled `extern struct`s.** libavif's
  `avifEncoder` has ~30 caller-mutable fields, `avifRGBImage` is a stack struct filled by
  `avifRGBImageSetDefaults`, and `WebPConfig`/`WebPPicture` are larger still. Transcribing those
  layouts into Zig is a silent-miscompile risk with no upside — so the shim does the struct work in
  C against the vendored headers and exposes a flat scalar ABI. This is the deliberate exception to
  `imageio.zig`'s "declare the C ABI by hand" rule, which fits an opaque-pointer API and fights a
  struct-heavy one.
- **No `image.decode` host command was ever needed.** A full-resolution buffer cannot ride a
  256 KiB host result, and `decode`'s only caller — the encode worker — is already off the loop
  thread and can call it directly. Wiring a command with no `Msg` arm would have shipped an
  unreachable path.
- **`build.zig`'s module list must be de-duplicated.** For the ReleaseFast `native build` the SDK
  hands back the SAME `*Build.Module` for the exe and the tests, so adding a compiled `.c` to both
  is a fatal `duplicate symbol`. Linking an `.a` twice was merely wasteful, which is why M14a's
  loop got away with it.
- **Parity re-encode: two rows outside ±15%, neither a regression.** `multi-primary.heic` (the
  baseline encoded the wrong index-0 image; the primary-frame fix changed which picture is
  compressed) and `alpha16.png` AVIF (+1.5 KB on a synthetic gradient — flagged, not tuned). Every
  real photograph and both graphics fixtures landed within ±15%, most within ±5%, with matching
  chroma. Full table in `docs/phase-b-baseline.md` under "M14c".
- **Case-insensitive `same_path`, found in review.** On the default case-insensitive APFS,
  `Photo.AVIF` and the derived `Photo.avif` are one file, so a byte-exact compare let the atomic
  write replace the user's original with a lossy re-encode of itself. Fixed and pinned by three
  tests.

### M14b — the decode path and the chroma table

`imageio.decode` (full resolution, primary frame, EXIF orientation baked in by hand, sRGB, 8-bit,
straight alpha, no metadata) and `src/chroma.zig` (the JPEG SOF parser plus the source-container
table). Both pure; neither had a caller until M14c.

- **The orientation bake goes through three SCALAR CTM calls, not `CGContextConcatCTM`.**
  `CGAffineTransform` is six doubles — neither an HFA nor register-sized on arm64 — so passing it
  by value would put a C-ABI question between us and the one requirement whose failure mode is a
  WRONG IMAGE rather than an error. Every EXIF orientation is `translate . (quarter turn?) .
  scale`, so the transform is returned as that decomposition. Proven three independent ways: the
  table re-derived algebraically in `src/tests.zig`, all eight orientations decoded from
  synthesized tagged PNGs in `src/imageio_tests.zig`, and `rotated-gps.jpg`/`rotated-p3.heic`
  checked corner-by-corner against their untagged twins. CoreGraphics' quarter turns are EXACT
  permutations, so those assertions are equality, not tolerance.
- **ImageIO reads PNG `eXIf` chunks**, which is what lets the eight-orientation test synthesize its
  own tagged PNGs in-process rather than dragging a JPEG or TIFF fixture into a file that has to
  work on a fresh clone (`test-images/` is gitignored).
- **A fixture correction:** `oversized.jpg` was recorded as 4:4:4 in the baseline inventory; it is
  4:2:0. Corrected in `docs/phase-b-baseline.md`. Nothing depended on it — the 50 MP guard blocks
  the fixture, so it has no encode row. The chroma table matches ImageMagick on all six real JPEGs
  and matches the baseline's `AVIF yuv` column on all fourteen fixtures that have one.

### M14a — own the build, vendor the archives

`native eject` ran; `build.zig` and `build.zig.zon` became ours and the CLI now drives `zig build`.
`build.zig` swapped `addApp` for `addAppArtifacts` so the archives and frameworks could be stated
on the artifacts. Suite 108 → 116; exe 5,522,248 → 5,522,376 bytes (+128) and `otool -L` showed no
new dylibs.

- **The exe did not reference the archives yet — only the test artifact did.** `encoders.zig` was
  reachable from `tests.zig` and not from `main`, so the ReleaseFast exe emitted none of the extern
  symbols and the +128 bytes was framework wiring, not encoder code.
- **`native test` started linking frameworks here**, which is what folded `src/imageio_tests.zig`
  back into the suite. See "The framework-linking trap", below.
- **The version pins are a real gate, not decoration.** `encoders.pinned` holds libwebp 1.6.0 /
  libavif 1.4.2 / libaom v3.14.1 and three tests assert them, so a re-copied archive cannot change
  the encoder out from under `docs/phase-b-baseline.md` silently.
- **`native eject` is one-shot** and refuses if `build.zig`/`build.zig.zon` exist. There is no
  re-ejecting to pick up CLI changes; `build.zig` is now a file we maintain.
- **`native dev` and `native package` both work on an ejected tree** — verified live, including a
  full 20-widget automation snapshot. x86_64/universal remains untouched.

### The framework-linking trap (found in M13, closed in M14a)

`build/app.zig` derives its test artifact from a fresh Debug module whenever
`app_optimize != optimize` (and `app_optimize` defaults to ReleaseFast), so the SDK's private
`linkPlatform` — which adds `linkFramework("AppKit")` and everything ImageIO rides in on — never
ran over it. Any test reaching ImageIO from any file reachable from `main.zig` died at LINK time on
`undefined symbol: _CFRelease`. That is why `src/imageio_tests.zig` spent M13 as a file nothing
imported, run by hand.

The ejected `build.zig` states the frameworks on `artifacts.tests.root_module` directly, which
closed it. **The shape of the trap still applies to anything new you link** — see `build.zig`'s
comments, which are its live version.

### Phase B step 6 — the encoder artifacts

All three archives built encode-only for arm64-macos and verified before any of M14 was written.

- **libaom was not the hard vendor the plan budgeted for.** Its `rtcd` dispatch headers
  (`aom_config.h`, `aom_dsp_rtcd.h`, …) are generated at configure time, but CMake generates them
  itself using macOS's own `/usr/bin/perl` — no nasm (arm64 libaom is NEON intrinsics in plain C)
  and no meson (that is dav1d's build system, and we vendor no decoder). `brew install cmake ninja`
  was the only prerequisite and the whole build is 22s. Reproducing CMake's configure step inside
  `build.zig` remains the thing not to attempt.
- **The +5 MB size estimate confirmed at +5.20 MiB**, measured three ways: no archives, version
  symbols only, and real encoder entry points referenced. The version-only row is +1,424 bytes —
  linking pulls only referenced members, so the 8.1 MB `libaom.a` is not the price.
- **`AVIF_LIBYUV=OFF` and `AVIF_LIBSHARPYUV=OFF` are output-parity requirements**, not size tuning.
  `AVIF_LIBYUV` defaults to `SYSTEM` and would silently swap in different RGB→YUV math than the
  baseline's `avifenc` used.
- **libsharpyuv is mandatory beside libwebp**, and **libavif.a must precede libaom.a** in the link
  order. Both now live as `build.zig` comments; both have a failure mode that hides until the other
  artifact is built.

### Phase B step 5 — the link path

Run against a throwaway `zig-core` app on CLI 0.10.1 / Zig 0.16.0. `addAppArtifacts` is public and
returns `AppArtifacts{ exe, tests, install, run }`; `native eject`'s output builds; Homebrew's
`libwebp.a` linked into a running GUI app and `WebPGetEncoderVersion` returned 1.6.0 from it. Two
findings beyond the plan: `tests.root_module` is a separate module that must be wired too, and
`linkFramework` needs an explicit `addFrameworkPath` or the link fails with `searched paths:
none`. The hand-written-`build.zig` fallback was never needed.

---

## v0.2 — ImageIO decode, preview and probe (2026-08-28)

### M13

The load chain moved onto ImageIO with the encoders left exactly as they were. `src/imageio.zig`
holds the whole C-ABI seam; two new host commands (`image.probe`, `image.thumbnail`) answer off the
loop thread through `HostBridge`'s worker carrier. Both `sips` spawns, `fx.loadImage`,
`parseDimensions`, the preview temp file and the drawn-size clamp are gone. `native test` 108/108,
`native build` 5.5 MB.

- **TWO host commands landed, not three.** `image.decode` was deferred to M14 deliberately: it had
  no consumer until the vendored encoders existed, and wiring a host command with no `Msg` arm
  would have shipped an unreachable code path.
- **The preview pixels RIDE THE HOST RESULT**, reversing the plan's "prefer the descriptor shape
  for both commands". `max_effect_host_result_bytes` is 256 KiB and 160×160 RGBA is 100 KiB, so it
  fits with room; the silent cliff the descriptor was meant to remove is removed better by a
  `comptime` assert, as a compile error rather than a runtime one. Riding the result also costs
  nothing extra (`hostRequest` heap-allocates `payload.len + 256 KiB` per request either way) and
  deletes a whole class of bug: bytes fed for a key are copied into that key's own effect slot and
  a cancelled key drops them, where a `pub var` pixel buffer is shared by every in-flight worker.
- **The reply header is FIXED WIDTH** (`"{d:0>5} {d:0>5}\n"`) so ImageIO decodes straight into the
  reply buffer past it, rather than the bridge moving 100 KiB of pixels to make room for a shorter
  number.
- **Worker slots carry an `abandoned` flag**, which the spike this seam came from did not need and
  the real app does: a reset or a second drop mid-load leaves the old worker running, and
  `feedHostResult` matches on key alone — without it, a superseded worker's pixels would be
  delivered as the NEW file's preview.
- **A probe that cannot be parsed now FAILS the load**, a deliberate behavior change. v0.1
  tolerated an unparseable `sips -g` answer and let the thumbnail spawn be the format gate. There
  is no second gate any more — the thumbnail is the same ImageIO read.
- **`Model.previewWidth`/`previewHeight` were deleted beyond the plan.** They clamped the drawn
  size because `sips -Z 160` UPSCALED anything smaller (an 8×8 icon rendered as a 160×160 blur);
  ImageIO CAPS instead, measured across the fixture set, so the registered size is already honest.
- **Live verification, six drops by hand** (neither a drop nor a dialog can be automated).
  `multi-primary.heic` previewed 160×50 — the 640×200 primary, where the shipping app drew the
  400×300 image at index 0. `rotated-gps.jpg` previewed 120×160 upright. `tiny.png` drew 8×8, not a
  blur. `not-an-image.jpg` failed at the probe with no preview widget in the tree. `oversized.jpg`
  failed at 51 MP before anything was decoded. And the regression check that mattered most:
  `large.jpg` smooshed to **717,003 B AVIF and 671,054 B WebP — byte-identical to the recorded
  baseline**, not merely inside the ±15% gate.

### Phase B step 3 — the Phase A baseline and the fixture set

`docs/phase-b-baseline.md` records size, PSNR, AVIF `yuvFormat`, decoded dimensions and metadata
presence for 18 fixtures, taken before any Phase B code. It is append-only: the gate M13/M14 are
judged against, and it cannot be reconstructed afterwards.

Ten fixtures were added, because every original fixture was a photograph, sRGB, with
`orientation: <nil>` — generalizing from that set had already produced a wrong encoder
recommendation once. The additions cover the common 4:2:0 JPEG path (`photo-420.jpg`), the
graphics class that separates the encoders (`ui.jpg`, `ui.png`), orientation and wide gamut
(`rotated-gps.jpg`, `rotated-p3.heic`, `iphone-rotated-p3.heic`, `p3.heic`), primary-frame
selection (`multi-primary.heic`), the depth/alpha edge case (`alpha16.png`) and grayscale
(`gray.jpg`).

- **A real Live Photo would NOT have closed the primary-frame gap.** An iPhone HDR capture's gain
  map is an AUXILIARY image and `CGImageSourceGetCount` still reports `frames 1`; only a HEIC with
  two TOP-LEVEL images and a `pitm` naming the second makes `GetPrimaryImageIndex` return non-zero.
  That synthesized fixture immediately found a live bug.
- **Two uncharacterized fixtures turned out to matter:** `small.png` is 16-bit and `tiny.png` is
  1-bit, so the 8-bit-pinning requirement is exercised by the set as it stands.
- **`test-images/large.jpg` is an atypical 4:4:4 JPEG and is now load-bearing** — it is the fixture
  that proves the chroma table reads the source rather than assuming 4:2:0.

### Phase B step 2 — ImageIO from Zig, standalone

A throwaway spike proved the C-ABI seam over the whole fixture set before any of it was entangled
with `HostBridge`. About 90 lines of `extern fn` covered all three reads. Findings, each now a
comment in `src/imageio.zig` or a test in `src/imageio_tests.zig`:

- `extern fn` over `@cImport` is right — every type is an opaque pointer or a plain scalar, and
  `CGRect` is the only by-value struct.
- **`kCGImageSourceCreateThumbnailWithTransform` really bakes orientation, and the full decode
  really does not.** Same file (`rotated-gps.jpg`, 4000×3000, EXIF Orientation 6): the thumbnail
  comes back 120×160 rotated, `CGImageSourceCreateImageAtIndex` comes back 4000×3000 unrotated.
- **Drawing into an sRGB bitmap context really converts.** Two PNGs with identical stored bytes,
  one tagged Display P3: the untagged one returns its authored values unchanged, the P3-tagged one
  is remapped — #D93025 → (237,5,14), #0A66FF → (0,104,255), #00A35C → (0,166,84), white unmoved,
  with 2.78% of pixels moving by more than 6/255 total. No ColorSync call of our own.
- **ImageIO exposes no JPEG chroma sampling key.** The full property dictionary for a 4:2:0 JPEG
  (`ui.jpg`) and a 4:4:4 one (`large.jpg`) is identical apart from dimensions — ColorModel, Depth,
  PixelWidth/Height, ProfileName, {JFIF}. The hand-rolled SOF parse is not optional.
- **An undecodable file does not fail where you expect.** `CGImageSourceCreateWithURL` SUCCEEDS on
  49 bytes of text named `.jpg` and returns a non-null source; `CGImageSourceGetCount() == 0` is
  what says "not an image".
- **The decoded buffer is TOP-DOWN and PREMULTIPLIED.** Row 0 of the backing store is the image's
  top row, so no vertical flip is needed feeding an encoder; `kCGImageAlphaPremultipliedLast` is
  the only 8-bit RGBA layout `CGBitmapContextCreate` accepts, so straight alpha has to be restored
  by hand.

### Phase B step 1 — the threaded host command

The other throwaway spike, and it corrected the plan rather than confirming it.

- **`feedHostResult` is loop-thread-only.** The plan had assumed the worker could call it
  ("uses atomic slot state and calls `wakeHost()`, so it is built for this"); `HostCallBinding`'s
  own doc comment is explicit the other way, and the atomics inside it guard the SDK's own worker
  families, which hand-roll the slot write + enqueue + wake sequence themselves.
- **The supported seam is the carrier trio** `poll_fn`/`pending_fn`/`bind_services_fn`, plus
  `shutdown_fn`. The worker parks its answer in a bridge-owned mailbox and calls `services.wake()`;
  `hasPending` consults `pending_fn` and `adoptHostCompletions` drains `poll_fn` on the loop thread
  and calls `feedHostResult` itself.
- **Measured live, and this measurement does not exist anywhere else.** Two concurrent
  saturated-CPU workers (sha256, 1.36 s and 2.21 s) delivered correctly while a 100 ms repeating
  timer kept firing — **14 ticks across the 1.36 s worker and 22 across the 2.21 s one** — and the
  snapshot's `gpu_frame` advanced monotonically throughout (**105 → 353**). The loop thread never
  blocked and the window really was painting, not merely dispatching.
- **`shutdown_fn` is not optional.** `Effects.deinit` calls it while `PlatformServices` is still
  live, before severing the services binding — the one window in which joining a worker that might
  still call `wake()` is safe.
- **The `services.wake()` nudge was never proven load-bearing.** The spike's view was a
  `gpu_present_mode = .timer` surface, so the loop already woke ~60×/s and would have polled the
  mailbox on its own. It is contract-correct and free — treat it as required — but this is not
  evidence that delivery fails without it.

### Phase B's shape, and why encode was NOT ImageIO's job

The round was scoped as dependency removal, not a feature round, with one success criterion:
Smoosh works on a Mac where nothing is installed. Decode and encode got opposite answers.

**Decode belongs to ImageIO** — it reads HEIC, JPEG, PNG, WebP and TIFF directly, needs no
third-party code, and required no build-graph change (`CGImageSource*` links via AppKit, confirmed
from the shipped binary's own load commands with `otool -L`, not inferred).

**Encode belongs to vendored libraries**, and the measurement that settled it is worth keeping:
macOS ImageIO *can* encode AVIF, and on PHOTOGRAPHS it is indistinguishable from
`avifenc -q 58 --speed 6` — at matched size on `large.jpg`, 714,717 B at 35.65 dB PSNR against
717,003 B at 35.73 dB, i.e. 0.08 dB, far under the ~0.5 dB just-noticeable threshold — while
running 2.6× faster. Generalizing from photographs alone is the trap. On a UI/screenshot fixture
`avifenc` produced 7,515 B at 47.77 dB in YUV444 where ImageIO's best was 9,911 B at 40.04 dB in
YUV420: **32% larger and 7.7 dB worse.** Raising quality does not help — ImageIO plateaus near
40 dB (14,904 B at 40.35 dB) because it is hard-locked to YUV420 with no subsampling control
exposed (the headers offer `kCGImageDestinationLossyCompressionQuality` and nothing for chroma),
and q=1.0 fails to produce a file at all.

**ImageIO's AVIF encoder also has an alpha interop bug**, which reinforced the same conclusion: a
16-bit source with alpha makes it emit a 10-bit AVIF whose alpha plane libavif/dav1d cannot decode
("Decoding of alpha plane failed") — that is Chrome and Firefox. Reproducible; 8-bit sources are
unaffected. Moot once libaom does the encoding, and defended against anyway by pinning the decode
to 8-bit RGBA.

Three deliberate exceptions to "nothing about output changes" were taken as product decisions:
metadata is stripped (measured: `avifenc` copied EXIF/GPS **and XMP** through, `cwebp` copied
none — so v0.1 leaked GPS into AVIF but not WebP), outputs are written atomically, and wide-gamut
sources are converted to sRGB. The last is new for EVERY wide-gamut source, HEIC included: an
earlier draft of the plan claimed `sips` already converted HEIC to sRGB, and it does not.

---

## v0.1 — feature-complete and packaged (2026-08-13)

Pick or drop an image, choose AVIF/WebP/Both, Smoosh auto-saves next to the source, optionally save
any output elsewhere, packaged as an ad-hoc-signed `.app`. Encoding shelled out to system tools
(`avifenc`, `cwebp`, and `sips` for thumbnails and HEIC staging) through `fx.spawn`.

Milestones ran Opus for real design surface or dense unfamiliar API wiring, Sonnet for work
following a pattern already in the tree.

### M12 — HEIC encode gap

`avifenc`/`cwebp` reject HEIC as an INPUT format outright, so a HEIC source produced nothing.
Fixed in Phase A rather than by narrowing the promise: `smoosh` staged the source as a PNG via
`sips` first and both encoders read that. (M14c deleted the whole step — ImageIO reads HEIC
directly.)

- **ONE shared staging spawn per run, not one per format** — "Both" would otherwise pay for the
  same conversion twice.
- **The destination path still derived from the ORIGINAL source name**, never the staging file, so
  `photo.heic` became `photo.avif` and not something named after `converted.png`.
- **A conversion failure was ONE direct `.fail`, not a run through the per-format join.** Unlike
  the two genuinely independent encoders, staging is a single shared prerequisite: if it fails
  neither format could have started, so there is no partial success to preserve — and routing it
  through the join would have printed the identical sentence twice in "Both" mode.
- **`resolveThumbnailPath` became `resolveAppTempPath`**, parameterized on filename and
  caller-owned buffers. The original used function-local `var` statics sized for exactly one call;
  calling it twice for two simultaneously-live paths would have aliased them onto the same backing
  memory. Caught by reasoning about where the static storage lived, not by a live failure.
- **A live mutation-testing gap, found and closed:** the first version of "a conversion result that
  lands after reset is ignored" only checked model state right after `.reset`, which zeroes
  `status` regardless of whether the new `fx.cancel` line existed at all. Rewritten to dispatch a
  synthetic stale result directly, bypassing `fx`. The same latent weakness was confirmed to exist
  in the older equivalent encode test.

### M11 — file drops

Real window-wide drag-and-drop via `UiApp.Options.on_drop`, a `fn(platform.FileDropEvent) ?Msg`
field beside `update_fx`/`init_fx`. **The seam arrived in the toolchain mid-project**: `@native-sdk/cli`
0.8.2 added it (verified by unpacking the 0.8.0-0.8.3 tarballs and counting `on_drop` occurrences
in `ui_app.zig`: 0, 0, 2, 2). The platform already emitted `files_dropped` in 0.8.0 and `flow.zig`
already routed it; what 0.8.2 added is the app-facing hook. The TypeScript `dropMsg` the release
notes advertise is literally this field — Zig sits one layer below it.

Four constraints, all read out of the CLI's source:

1. **The drop is WINDOW-wide, not drop-zone-shaped.** On a real drag the macOS host builds the
   event from `window_id` + paths only — no `view_label`, no `point`. Anywhere in the window
   accepts, so the copy must not promise a targeted zone.
2. **The widget-level channel is a double dead end.** `canvas_widget_file_drop` and
   `routeCanvasWidgetFileDrop` exist, but `UiApp.handleRuntimeEvent` has no case for it and drops
   it into `else => {}`, and the router bails when `view_label.len == 0` or `point == null` — which
   per (1) is every physical drag. There is no `on-file-drop`/`accepts-drop` markup attribute
   either.
3. **A drag-over highlight is impossible.** The AppKit host's event enum has exactly one drag kind;
   `draggingEntered:` returns `NSDragOperationCopy` unconditionally and emits nothing. There is no
   hover state to design.
4. **Nothing needs enabling.** The NSWindow registers `NSPasteboardTypeFileURL` unconditionally at
   creation. No `RunOptions.bridge` gate, no permission, no runtime capability check.

Built as a dedicated `dropped_file: []const u8` arm rather than a synthesized `.dialog_result` — a
transcript that reads "`dropped_file`" says what happened, where a fake `EffectHostResult` would
read as a dialog answer that never happened. Both entry points share `beginLoad(model, fx, path)`,
which is what makes "a drop re-enters the already-validated chain with zero new pipeline" true by
construction: mutation-testing `clearResults`/`clearPreview` out of it fails both the drop test and
the pre-existing pick test.

**Drops cannot be automated at all.** `native automate` has no bare drop verb;
`widget-action … drop-files` exists but requires `semantics.actions.drop_files`, which markup
cannot express, and it drives the widget channel constraint (2) says a real drag never reaches — so
it would prove the wrong thing. The user drags a real file by hand. This is a *different*
constraint from the standing dialog rule (dialogs are dangerous to automate; drops are simply not
automatable), with the same practical answer.

`app.zon` gained `"file_drops"` in `.capabilities`. It is a real
`app_manifest.CapabilityKind` — an earlier CLAUDE.md claim that no such string existed was wrong —
but nothing in the runtime reads it, so it is honest metadata, not a switch.

The drop zone's copy became "Drop an image here — or click to choose" and the idle status line
regained the word "drop". M9 had removed it deliberately because drops did not work yet; M11 is
what made the word true again.

### M10 — packaging and the v0.1 release

- **Ad-hoc signed, not notarized, not unsigned.** `security find-identity -v -p codesigning` found
  zero identities — no Apple Developer Program membership, so real Developer ID signing plus
  notarization was not available. Of the two free options, ad-hoc gives the bundle a valid local
  code signature (`codesign -dv` confirms `flags=0x2(adhoc)`). Its real limitation — it does
  nothing for Gatekeeper's "unidentified developer" prompt on a QUARANTINED copy — does not bite
  for one person on one Mac, dragging locally into `/Applications`.
- **A real bug found only by actually launching from `/Applications`:** the packaged app opened to
  the "install avifenc/cwebp" error with both genuinely installed. Every `fx.spawn` child inherited
  `Runtime.Options.environ`, wired straight to the raw process environment — and a GUI-launched
  process inherits launchd's minimal PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), where Homebrew's
  `/opt/homebrew/bin` only lands via `brew shellenv` in an interactive login shell. That is exactly
  what `native dev`/`native build` always was and a packaged app never is. Fixed at the source with
  `resolveSpawnEnviron`, which widened the bound environ's PATH before `Runtime.initAt` so every
  spawn downstream inherited the fix. (Deleted in M14c along with the last subprocess.)
- **`native package` does not clean its output directory.** A stray `assets/icon.png.bak` rode
  along into `Contents/Resources/assets/` and was still there on the second run after the source
  file was deleted — it only overwrites files it knows about. `rm -rf zig-out/package` before any
  packaging run that matters.
- **The icon is a placeholder, and how it was made is a warning.** Hand-written SVG rasterized with
  `magick` — the only rasterizer on the machine. ImageMagick's built-in SVG delegate (MSVG) is
  primitive: `<linearGradient>` fills render solid black and `<line>`/`<path>` with `stroke` do not
  render at all, so the arrow had to be built as two filled `<polygon>`s with hand-computed
  corners. A future pass should use a real vector tool and treat `assets/icon.png` as a placeholder
  to replace, not a baseline to iterate on.

### M9 — UI/UX pass

Replaced the scaffold view with the real one: a header, one middle band swapping between a
pressable drop zone and a file card (preview left, name/size/results right), the format chips, the
actions row, and the status line. The chrome around the middle band never moves, so every control
keeps its widget id across the swap.

- **The drop zone said "click", not "drop"** — file drops did not work yet, and a drop zone that
  lies about accepting drops is the one thing a drop zone must not do. M11 made it true.
- **The window grew to 540×400 with `min_width`/`min_height` declared** (420/400, in all three
  places). 480×320 was a guess made before any content existed and the ready state overflowed it —
  the `zero_canvas_layout` diagnostic. `min_height` equals the default on purpose: every row is
  fixed-height and the preview frame is a fixed box, so vertical shrink buys nothing and costs the
  layout its only slack.
- **Error messages stopped naming the file.** `<status-bar>` is one honest line — it takes no
  `wrap` (a validation error: "put wrap on the text leaf itself") and `size="sm"` does not shrink
  its text — so it elides at roughly 65 characters. A quoted filename cost ~18 of those, and the
  live failed state read `"not-an-image.jpg" isn't an image Smoosh can read. Try JPEG,…` — the
  truncated half being the half that says what to do. The file card names the file instead.
- **The alert icon rides BESIDE the status bar rather than recolouring it** — two `<status-bar>`s
  behind an if/else would give the status line two different widget ids, and automation addresses
  it as one.
- **The chip iterable became `[]FormatChip{ value, label }`** so the chips read "AVIF"/"WebP"/"Both"
  instead of lowercase Zig tag names. A `pub fn label` on `Format` was tried first and rejected by
  the checker: bindings resolve FIELDS on a loop item, and an enum has none.
- **A bug the new card exposed:** a new pick never cleared the previous file's preview. Invisible
  under the scaffold, obvious the moment name and thumbnail sat side by side. Fixed with
  `clearPreview()` at the PICK, not at the failure.
- **A note that cost a screenshot to find:** the result lines were first coloured `success_text`,
  which is the on-success-fill foreground and rendered nearly invisible on the dark background.
  `success` is the token for tinted TEXT. The snapshot reports names, not contrast.

### M8 — Save As

- **"Both" needed a real design decision the sketch did not cover:** `showSaveDialog` returns ONE
  path but Smoosh can produce two files. Settled on sequential rounds — one dialog-then-copy per
  landed format — over a folder picker or disabling Save As for "Both" (rejected: Both is the
  headline feature, and silently disabling its own Save As reads as a regression). Later replaced
  by a per-format save icon on each result row, which removed the queue entirely.
- **Copy goes through a host command we bind, `file.copy`**, not `fx.writeFile`: the file effects
  cap at `max_effect_file_bytes` (1 MiB) and a real encoder output exceeds that.
  `std.Io.Dir.copyFileAbsolute` has no such cap.
- **A save note lives in its own buffer**, not the encode-warning one: they are different facts
  about different actions, and folding them would mean one silently overwriting the other.
- **Host requests need no staleness guard**, confirmed rather than assumed: dialogs block the loop,
  so a save round can never be mid-flight when another Msg is dispatched. The defensive guards on
  both result arms are provably unreachable through the effects channel — mutation-tested by
  dispatching the result Msg directly, the only way to reach them at all.
- **Mutation testing caught two test gaps, not just code bugs.** A same-key `fx.hostRequest`
  re-issue REPLACES the pending one, which made a naive "second press → still exactly one pending
  request" test pass whether or not the double-press guard existed; rebuilding it around an
  already-advanced round exposed the difference. And no test asserted the exact `file.copy` payload
  text, so swapping source and destination in the format string — which would copy the chosen
  destination OVER the real output, backwards — passed everything.

### M7 — the encode pipeline

`smoosh` → one spawn per requested format → a `file.stat` per output → `.done`/`.failed`.

- **PARTIAL FAILURE IS PARTIAL SUCCESS.** The deciding fact is that the encoders write their own
  output files: by the time WebP's nonzero exit arrives, `photo.avif` is already on disk next to
  the source, so failing the whole run would mean either claiming failure with a good file sitting
  right there, or deleting a file the user can see. The all-failed floor keeps the error-mapping
  invariant intact and is the ordinary failure path in single-format mode — no special case.
- **The join must never re-read `Model.format`.** Completion is "neither format is `.pending`",
  tracked per format. The chips stay live while encoding, so a join that re-read the current
  selection would end the run early when the user narrows Both → AVIF mid-flight, silently
  orphaning the WebP file still being written. Caught by mutation testing, not by the first version
  of the test.
- **`.done` needed its own warning buffer**, separate from the error message. The two coexist in
  exactly the case this milestone exists to handle, and keeping them apart is what preserves
  "`.failed` is always paired with an error message, and no other path sets `.failed`".
- **A zero exit is not a result.** The output's size comes from a `file.stat` on the destination,
  which doubles as the only available signal for "write to output path failed" — the encoder writes
  its own destination, so there is no separate write step to fail.
- **`savings_percent` was deleted from the model sketch rather than implemented**: it is pure
  arithmetic over sizes, so it is derived per rebuild.
- **"Combined savings" resolved as per-format lines, not a sum.** A summed total describes a
  download that never happens — no client fetches both files.
- **Widget ids were NOT stable across conditional rows, and now are.** Every `<if>` child of the
  root column that starts rendering re-disambiguates its unkeyed same-kind siblings, so ids after
  it all move — the Smoosh button took three different ids across idle → ready → done, which broke
  an automation script mid-run. Fixed by giving every root child a `key`. The id-stability test
  could not catch it because it only changed `status`, which alters no structure.
- **`Model.view_unbound` landed**, taking `native check` from 17 warnings to zero. What remained
  after M7 is permanently update-side, so naming it makes a future warning mean something again.

### M5-M6 — encoder detection and format selection

Launch-time `which avifenc` / `which cwebp` through `init_fx`, the SDK's boot-command hook, with
three distinct failure messages (avifenc only / cwebp only / both) each naming its own
`brew install` command — `libavif` for avifenc, `webp` (not `libwebp`) for cwebp. Two `?bool`
fields stayed `null` until each answered, so the join fired once both were known in either order.
Format selection was one line; the chip coercion and `selected="{f == format}"` binding had already
been proven at the markup level. (All of this was deleted in M14c.)

### M3-M4 — file acquisition, preview, and input limits

The load chain: `pick_file` → `dialog.openFile` → `file.stat` → thumbnail → `.ready`.

- **The preview MUST be a downscaled thumbnail — a hard SDK bound, not a shortcut.** Registered
  images cap at **1 MiB of DECODED RGBA** (512×512 exactly) and `fx.loadImage` refuses encoded
  sources past 1.25 MiB. No real photo can ever be registered directly. Measured across every
  fixture, 160px thumbnails come out 752 B - 37 KB, three orders of magnitude inside the bound.
- **`fx.readFile` is the wrong tool for images and was never used** — it caps at 1 MiB and returns
  `.truncated` past it.
- **`original_size` comes from a host command we bind ourselves, `file.stat`.** A stat is far too
  cheap for a worker thread or a `stat(1)` spawn, and `update` can never hold an `Io` — the bridge
  can. Kept separate specifically so the encode step could reuse it for output sizes.
- **Only the async effects need a stale-result guard.** A `.reset` cancels them and the
  cancellation arrives as a terminal indistinguishable from a genuine failure, so without the guard
  pressing Reset rendered "Couldn't build a preview for photo.jpg". Synchronously-answered host
  requests need none.
- **Reset keeps `Model.format`** — format is a user preference, not per-file state.
- **Reading dimensions off the thumbnail spawn did not work**, and was never testable without a
  real `sips`: combining a query flag with a modify flag exits 6,
  `"cannot get properties and modify file in the same invocation"`. The megapixel check needed its
  own spawn. (M13 replaced both with `image.probe`, which allocates no bitmap and so can run the
  guard before any decode — an ordering the `sips` path could not offer.)
- **Both limits are inclusive**: exactly 100 MB or exactly 50.0 MP passes.
- **The dialog-automation rule was born here, from a misfire.** Driving a real `NSOpenPanel` via
  AppleScript System Events sent keystrokes to the terminal instead — a file path was typed into
  the live session. The app runs as a bare executable from `.zig-cache` and System Events cannot
  bring it frontmost (`set frontmost` silently no-ops), so global keystrokes land on whatever IS
  frontmost. **Never automate a native file dialog**; have the user drive it by hand.

### M1-M2a — the Zig core, the markup shell, and the test harness

Deleted `src/core.ts`, `package.json`, `tsconfig.json`, `bun.lock`, `node_modules/`; stood up
`src/main.zig` with the platform and Runtime built by hand; added `src/app.native` and
`src/tests.zig`.

- **Automation and hot reload gate on `builtin.mode == .Debug`.** The CLI's `-Dautomation` flag is
  wired into its internal runner module only and is unreachable from a hand-authored root, so build
  mode is the gate we actually control. `native dev` gets both; `native build` gets neither, which
  is why verification runs against `native dev`.
- **The window config lives in THREE places, not two** — the `AppInfo.main_window` frame the host
  creates the real NSWindow from, the `ShellConfig` the runtime lays views out against, and
  `app.zon`. The CLI runner derives the first from `app.zon` at comptime; a hand-authored root has
  no such path.
- **Path buffers are `platform.max_dialog_path_bytes` (4096)**, not the sketch's 1024, to hold
  whatever `showOpenDialog` returns.
- **The chip pattern needs `pub const formats` declared *inside* `Model`** for `for each` to
  resolve — binding resolution only sees Model's own decls.
- **An unwired chip goes "uncontrolled" once clicked.** With `selected="{f == format}"` never
  evaluating true (because `format` never moves under a no-op `update`), the runtime retains each
  chip's own pressed visual state — documented behavior for a toggle whose source never asserts
  `true`, and it resolved itself the moment `set_format` was wired.
- **`update`'s arms were deliberately untested while empty** — tests asserting "nothing happened"
  would have been deleted one per milestone, and Msg-tag exhaustiveness is already a compile error
  via `update`'s switch.
- **The tests were mutation-checked, not just run green**, from the first eight onward. A markup
  test that cannot fail is worse than none. That discipline held through every later milestone and
  is what caught the format-mid-encode gap, the backwards copy payload, and the two reset-guard
  tests that could not fail.

### Before M1 — why this is a Zig core

Smoosh was planned as a TS-core app ("no JS runtime in the binary"). That reversed after spiking
file acquisition: native open/save dialogs and file drops are gated behind
`RunOptions.bridge`/`.builtin_bridge`, fields that only exist on a hand-authored `main.zig`.
Verified from `@native-sdk/cli@0.8.0`'s `build/app.zig`: `addApp`'s `AppOptions` has no passthrough
for them, the CLI-generated TS-core `main.zig` hardcodes them off with no override, and the build
hard-panics if a tree carries both `src/core.ts` and `src/main.zig` ("an app has exactly one
core"). **There is no partial-adoption path** — confirmed by building and `native check`-validating
a throwaway spike app, not by reading docs alone.

The file-acquisition spike also found two things that still shape `main.zig`: `runWithOptions`'s
per-platform bring-up is all non-`pub`, so a hand-authored root must replicate the relevant parts
with public APIs (`MacPlatform.createWithOptions` + `Runtime.initAt`) — in practice only the
platform handle and the Runtime are needed, and `runWithOptions`' extras (trace-sink fanout,
session recording, window-state persistence) can be added back deliberately later.

---

## Toolchain history

- **`native` 0.10.1** — current. Adds `--archive` DMG packaging; `addAppArtifacts` is public here,
  which is what M14a's ejected build depends on.
- **`native` 0.9.0** (2026-08-13) — no code changes needed; 93/93 and zero warnings.
- **`native` 0.8.4** (2026-08-13) — no code changes needed; 88/88 and zero warnings. 0.8.2 in this
  line is what added `UiApp.Options.on_drop`.
- **`native` 0.8.0** — the version the TS-core reversal was verified against.

There is no pinned SDK version in this tree: `build.zig.zon` depends on the globally installed CLI
by relative path. **Run `native test` before `native check` after any CLI upgrade** — `check`
degrades to grammar-only with a loud note until `test` regenerates the model contract, which is how
every one of the upgrades above was verified.
