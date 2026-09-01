# Smoosh — PLAN.md

> Living plan: decisions still in force, requirements the code must keep satisfying, and what is
> still open. How it got here — every milestone, every measurement behind a decision — is in
> `CHANGELOG.md`. Update this file as decisions are made; append to the changelog as work lands.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern
web formats (AVIF and/or WebP) without leaving your desktop.

## Status
**v0.3 — feature-complete and zero-dependency.** Pick or drop an image, choose AVIF/WebP/Both,
Smoosh auto-saves next to the source; each landed result row carries its own save icon to copy that
one file elsewhere. Ships as an ad-hoc-signed `.app`.

The whole pipeline runs in-process: Apple ImageIO reads (`src/imageio.zig`), vendored static
libavif/libaom/libwebp write (`src/encoders.zig` over `src/encode.c`), and the encode runs on a
worker thread so the window keeps painting. **The app spawns no subprocess and needs nothing
installed.**

`native test` 118/118, `native check` zero warnings, `native build` 10.94 MB.

What is left is UI and style polish, plus the standalone-app gaps — see "Roadmap".

## Non-goals (for now)
- Linux or Windows support
- Batch processing of many files
- Advanced quality controls / comparison view / side-by-side
- Cloud upload / accounts / history
- Animated image support
- Vector / SVG handling
- In-app image editing (crop, resize, etc.)
- Any dependency on Node, ImageMagick or Sharp
- Metadata-preservation toggles (EXIF, GPS, ICC) — Smoosh strips unconditionally
- Wide-gamut output (P3 and beyond) — everything is converted to sRGB deliberately
- Quality/speed sliders — the pinned settings are the product

## Product behavior

### Format selection
- **AVIF** — best compression for modern browsers.
- **WebP** — broader compatibility.
- **Both** (default) — two files, so a source can serve AVIF with WebP fallback.

When "Both" is selected each output shows its own savings line — never a summed "combined
savings", since no client ever downloads both.

### File acquisition
- Native open dialog via `runtime.showOpenDialog`, called from a `HostCallBinding.request_fn` bound
  by hand in `src/main.zig` — see CLAUDE.md's "File acquisition, honestly" for why this requires a
  hand-authored root.
- Real window-wide drag-and-drop via `UiApp.Options.on_drop`, which re-enters the exact same load
  chain a picked file does.
- Accepts what macOS ImageIO decodes: JPEG, PNG, WebP, HEIC/HEIF, TIFF, GIF, BMP.

### Output handling
- Auto-save next to the source (`photo.jpg` → `photo.avif` / `photo.webp`) as soon as "Smoosh"
  completes — no save dialog in the default path.
- An existing output file is overwritten silently. Re-running "Smoosh" on the same source is
  "redo this".
- **"Overwrite silently" is about a previous OUTPUT, never the source.** A format whose destination
  would BE the source is skipped (`EncodeOutcome.same_path`), and the comparison is
  CASE-INSENSITIVE because macOS volumes are. Symlinked and hardlinked destinations are still not
  covered — that needs an `Io` to stat with, which `update` can never hold.
- Outputs are written **atomically**: a temp sibling in the destination directory, renamed into
  place. A crash leaves the temp, never a half-written output.
- Each landed result row carries its own save icon — an optional secondary action to copy that one
  file elsewhere. It does not replace auto-save.
- A negative-savings result (output larger than a tiny source) is real, not an error: it displays
  as `+1% larger`.

### Error states
Each maps to a user-facing message and the `.failed` Model state:
- Source unreadable (`file.stat` failed) → "Can't read that file."
- Unsupported/undecodable input → name the expected formats. `image.probe` is the gate, and it
  reports off the frame COUNT, not a null source (`CGImageSourceCreateWithURL` succeeds on 49 bytes
  of text named `.jpg`).
- Input exceeds the size or megapixel limit → show the limit and the file's actual size.
- Preview could not be built (`image.thumbnail` failed, or its reply would not parse) → one
  message; the load fails rather than showing a card with no image.
- Encode failed (the worker could not decode the source, or libavif/libwebp rejected the frame) →
  a short, non-technical message. There is no encoder stderr to surface.
- Write to output path failed (permissions, disk full, read-only volume) → points at the folder.
- Destination would be the source → skipped, and named as such ("already an AVIF file").

In "Both" mode a per-format failure is a WARNING on a `.done` run, not a `.failed` one — only a run
where no requested format landed sets `.failed` (see "the partial-failure decision" in `main.zig`).

**`.failed` is always paired with a populated `error_message_buffer`**; the list above enumerates
every message that can land there, and no other path may set `.failed`.

### Input size limits
**100 MB** or **50 megapixels**, whichever comes first — both checks inclusive. A local tool should
be more permissive than a typical web upload limit while still protecting against files that would
exhaust memory decoded to RGBA. The error names both the file's actual size and the limit.

## Correctness requirements
These are properties of the decode/encode path that must survive any change to it. Measurements
behind each are in `docs/phase-b-baseline.md`; the reasoning is in `CHANGELOG.md`.

- **Primary frame, not index 0.** Everything reads `CGImageSourceGetPrimaryImageIndex` — the
  megapixel guard, the preview and the encoder input.
- **EXIF orientation is baked into the pixels.** `kCGImageSourceCreateThumbnailWithTransform` does
  it for the preview; the full decode does it by hand, because
  `CGImageSourceCreateImageAtIndex` returns the frame unrotated.
- **Convert to sRGB, and tag sRGB.** Drawing into a `CGBitmapContextCreate(..., kCGColorSpaceSRGB)`
  performs the conversion for free; the encoder must then tag it explicitly, because the same path
  drops the ICC profile.
- **Metadata is stripped, unconditionally.** Encoding from decoded pixels copies nothing unless
  asked — this is the do-nothing path mechanically and a product decision editorially. No toggle
  (see Non-goals).
- **Decode to 8-BIT RGBA in `decode` and `thumbnail`; `probe` allocates no bitmap at all.** Pin the
  depth rather than inheriting the source's. Load-bearing on the current fixture set, not
  hypothetical: `small.png` reports Depth 16 and `tiny.png` reports Depth 1.
- **`src/imageio.zig` returns STRAIGHT alpha to every caller.** `CGBitmapContextCreate`'s only
  8-bit RGBA layout is `kCGImageAlphaPremultipliedLast`, so `drawToRgba8` un-premultiplies. This is
  a contract, not an optimization: `fx.registerImage` documents its input as straight-alpha RGBA8
  and libwebp/libavif want the same, so one convention leaving the module beats two callers each
  remembering to convert. The buffer is also TOP-DOWN, so nothing downstream needs a flip.
- **An undecodable file is detected by frame COUNT, not by a null source.**
- **AVIF chroma subsampling is reproduced from the SOURCE CONTAINER**, per the table in
  `src/chroma.zig`'s header: a JPEG keeps its own sampling (parsed by hand from the SOF marker —
  ImageIO exposes no key for it), everything else is 4:4:4, grayscale is 4:0:0. This is the single
  most consequential encoder knob — invisible on photos, catastrophic on graphics (7.7 dB on a UI
  fixture). **Do NOT simplify this to "JPEG → 4:2:0"**, and **do NOT invent an "is this
  photographic?" heuristic**; `src/chroma.zig` says why at length.

## Key decisions carried forward
- **Partial failure in "Both" mode is partial SUCCESS.** The two encodes are independent; one
  landing while the other fails is `.done` with the failure named in the status bar. Only an
  all-failed run is `.failed` — the worker writes its own output file, so anything else would
  contradict a file already on disk.
- **Save As is per-format**, not a single "Both" action. Each result row has its own save icon, each
  running its own one-shot save-dialog-then-copy round. Pressing either while a round is in flight
  is a no-op.
- **Signed ad-hoc, not notarized, not unsigned**, for a single-machine local tool with no paid Apple
  Developer identity. Revisit if this ever needs sharing.
- **AVIF encoding stays on libaom; ImageIO does decoding only.** ImageIO's AVIF encoder is
  quality-indistinguishable on photographs and 2.6× faster, but it is hard-locked to YUV420 with no
  subsampling control exposed, which makes it decisively worse on the screenshot/UI/graphics
  content this tool exists to compress. It also has an alpha interop bug on 16-bit sources.
  Measurements in `CHANGELOG.md`, "why encode was NOT ImageIO's job".
- **The encoder settings are the pinned `avifenc`/`cwebp` ones, carried over literally** — AVIF
  q58/speed6, WebP q80 — because Smoosh vendors the same encoders those front-ends drive.
  `encoders.pinned` asserts the three archive versions so an upgrade cannot arrive silently with a
  re-copied file.
- **Long work runs off the loop thread through the WORKER-CARRIER seam, never `feedHostResult`.**
  `Effects` offers spawn/fetch/file/db/pty/channel and nothing that runs arbitrary Zig off-loop, so
  the seam is a `HostCallBinding.request_fn` that returns WITHOUT answering: the worker parks its
  answer in a bridge-owned mailbox and calls `services.wake()`, and the loop thread drains it
  through `poll_fn`/`pending_fn`/`bind_services_fn`. `shutdown_fn` is not optional — it is the one
  window in which a still-running worker can be joined while `PlatformServices` is live.
- **A full-resolution buffer can never ride a host result.** `max_effect_host_result_bytes` is
  256 KiB and an over-cap answer is silently rewritten to the err route. The 160px preview fits
  (100 KiB) behind a comptime assert; `imageio.decode` is deliberately not a host command at all.

## Testing strategy
Two tiers, in this order. Reaching for the GUI to answer a question a unit test answers faster is
the failure mode to avoid.

**Tier 1 — `native test` (`src/tests.zig`, `src/imageio_tests.zig`).** Deterministic, no GUI, no
processes, no network. This is where logic gets proven. The markup/model seam is driven through the
real dispatch path: build the markup against the real `Model`, find a widget, ask the tree for the
`Msg`, feed it to `update`. Effects-bearing paths drive `Effects` in fake-executor mode
(`fx.executor = .fake`, via the `Harness`) — assert the *request* an arm made, then feed the answer
and drain. ImageIO and the real encoders are reachable here, because `build.zig` states the
frameworks and archives on the test module too.

**Every new assertion gets mutation-checked, not just run green.** Break the thing it claims to
pin and confirm it fails — exactly one test, and the right one. A test that cannot fail is worse
than none, and this discipline is what caught the format-mid-encode gap, a backwards `file.copy`
payload, and two reset-guard tests that passed with the guard deleted.

**Tier 2 — `native automate` against `native dev`.** Proves the real seam end to end. `native build`
is ReleaseFast and has neither automation nor hot reload.

**Fixtures are gitignored**, so tier-1 tests must never read `test-images/`. Anything image-shaped
uses in-repo bytes: embedded PNG literals, or `canvas.png.writeRgba8` plus
`harness.null_platform.image_decode = true` for the decode→register→draw path.

## Verification strategy
Every change ends with a check against the *running* app, not just a compile check. `native build`
and `native check` are necessary and never sufficient.

- `native automate widget-click` drives the real UI for anything reachable without a native dialog
  or a real file drop.
- **Never automate a native file dialog** (open or save panel). The app runs as a bare executable
  under `native dev`/`native build`, and System Events cannot bring it frontmost, so global
  keystrokes land on whatever IS frontmost instead — this already typed a stray path into a live
  session once. Have the user drive every dialog by hand.
- **File drops cannot be automated at all** — a different constraint, same practical answer: have
  the user drag a real file onto the window by hand.
- Test fixtures live under `test-images/` (gitignored); `docs/phase-b-baseline.md` carries the
  recipe for regenerating each one and the inventory of what each proves.
- **`docs/phase-b-baseline.md` is append-only.** It is the ±15% parity gate, recorded before any of
  the native encode work and impossible to reconstruct afterwards. Every change to the encode path
  is re-checked against it, and **chroma subsampling is part of the check** — a size-and-PSNR match
  with the wrong `yuvFormat` is a failure.

## Known limitations
- **"Both" decodes the source twice.** The two formats are two independent `image.encode` workers —
  that independence is the partial-failure decision — and each calls `imageio.decode` on the same
  file. The cost is **peak memory, not latency**: two full-resolution RGBA buffers live at once, up
  to ~400 MB at the 50 MP guard. The two decodes run concurrently on separate threads. Sharing one
  decode would mean a refcounted buffer outliving both slots — real complexity for a memory win
  only, so this is a deliberate trade.
- **arm64 only.** The vendored archives are non-fat arm64-macos; producing an x86_64 or universal
  build is unexplored. A genuine gap the moment the `.app` is handed to anyone else.
- **The app icon is a placeholder** (see `CHANGELOG.md`'s M10 entry for what not to repeat).
- **Launch time has never been measured.**

## Roadmap
Three tracks, independent of each other. Each carries a model/effort suggestion — judgment calls
about how much of the work is taste versus mechanism, not benchmarks.

### 1. Performance
**Measure before touching anything.** The app is already effectively instant on normal photos, and
optimizing without a number is how the parity gate gets perturbed for nothing. Every change here
must be re-checked against `docs/phase-b-baseline.md`.

Ranked by payoff-to-risk:
- **`drawToRgba8`'s `@memset(pixels, 0)`** — a full-buffer write, up to 200 MB, redundant because
  our transforms always cover the whole destination. Cheapest real win, no parity risk.
- **`encoder->maxThreads = 1`** — the single biggest wall-clock lever on large photos. Set for
  determinism while parity was being established; parity is banked now, so this is re-measurable as
  a decision rather than a constraint.
- **libaom rebuilt `-Os` instead of `-O3`** — Homebrew's is 5.4 MB against our 8.1 MB, so this
  meaningfully cuts the 10.94 MB binary. Needs a full parity re-measure: libaom's rate control
  carries FP math and optimization level can change contraction.
- **`copy_out`'s extra malloc+memcpy** of the whole encoded buffer in `src/encode.c` — tidy, low
  payoff, zero risk.
- **The Both-mode double decode** — see "Known limitations". Memory, not latency.

*Suggested: **Opus 5, medium** for the measuring and the first two items; **high** if touching
encoder settings or rebuilding an archive, where the parity judgment is the whole task.*

### 2. UI and style polish
The `design` skill and Claude Design flows fit here. Constraint to respect: the app is meant to live
in a corner of the desktop, so it must stay correct at `window_min_width` (420) and the layout floor
recorded in `main.zig`.

*Suggested: **Opus 5, medium.** Iterative and visual; the work is in the looking, not the
reasoning.*

### 3. The standalone-app review
The umbrella, not a task. The correctness half was covered by the Phase B review (2026-08-30) —
one real bug found and fixed (the case-insensitive `same_path` collision). What it did NOT touch is
the first three "Known limitations" above: **arm64-only**, **notarization** (currently ad-hoc
signed, fine for one machine and not for distribution), **the placeholder icon**, and **launch
time**.

*Suggested: **Opus 5, high**, or run `/code-review ultra` for the correctness sweep — it is
user-triggered and billed, so it cannot be launched from inside a session.*
