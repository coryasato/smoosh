# Smoosh — PLAN.md

> Living plan. Update this file as decisions are made.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern web formats (AVIF and/or WebP) without leaving your desktop.

## Success criteria for v0.1 (MVP)
- [x] App launches to a clean drop-zone UI *(M9: the real view — a pressable drop zone that becomes a
  file card. M11 made the drop real; the zone's copy says so.)*
- [x] User can pick an image via "Choose Image…" (native open dialog via `runtime.showOpenDialog`, wired through a custom `HostCallBinding` — pattern proven, see "File acquisition, honestly" in CLAUDE.md); drag-and-drop was stretch for v0.1 and landed anyway in M11 (`UiApp.Options.on_drop`, SDK 0.8.2+)
- [x] Image appears as preview with original size
- [x] User can choose output: AVIF (default), WebP, or Both
- [x] "Smoosh" produces the selected format(s) via system tools and auto-saves next to the source file
- [x] Before/after file size + savings % are shown
- [x] User can optionally re-save output to a different location via "Save As…"
- [x] Works on macOS only
- [x] Reasonable input size limits with clear feedback
- [x] Ships as a packaged `.app` that launches on a machine that never ran `native build`
  *(M10: `native package --target macos --signing adhoc`; installed to `/Applications` and confirmed
  working, including a real bug found only by that install — see M10's entry.)*

## Non-goals (for now)
- Linux or Windows support
- Batch processing of many files
- Advanced quality controls / comparison view / side-by-side
- Cloud upload / accounts / history
- Animated image support
- Vector / SVG handling
- In-app image editing (crop, resize, etc.)
- Shipping a Node or ImageMagick dependency

## Technical approach

### Encoding strategy (phased)

**Phase A — MVP (system tools, fast UI iteration)**
- Use `fx.spawn` against system tools already available via Homebrew or similar.
- Preferred tools:
  - `avifenc` (from libavif) for AVIF
  - `cwebp` (from libwebp) for WebP
- Detect presence of `avifenc`/`cwebp` at launch. If missing, show which tool is absent and the exact `brew install` command — user runs it themselves in Terminal.
- Quality defaults: AVIF ~q55–60, WebP ~q80 (tunable later).
- No ImageMagick. No Sharp. No sidecars.

*Encoder invocations — pinned in M5, confirmed against the installed versions (libavif 1.4.2 /
avifenc "Version: 1.4.2", libwebp 1.6.0 / `cwebp -version` "1.6.0") by running both by hand against
`test-images/large.jpg` (4000x3000, 5.6 MB) and `test-images/tiny.png` (312 B, the negative-savings
fixture). Both flag sets work as originally sketched — no changes needed:*
```
avifenc -q 58 --speed 6 <input> <output.avif>
cwebp  -q 80 <input> -o <output.webp>
```
`large.jpg` (5,846,465 B) -> AVIF 717,003 B, WebP 671,054 B, both exit 0. `tiny.png` (312 B) -> AVIF
315 B, WebP 68 B — confirms the negative-savings case encodes cleanly rather than erroring (AVIF is
*larger* than the tiny source; M7's savings-percent math needs to display that sanely, not treat it
as a failure). M7 can use this argv as-is.

**Phase B — Native (later)**
- Move encoding into Zig.
- Decode via Apple’s ImageIO / CoreGraphics (zero extra code, excellent HEIC/JPEG/PNG support).
- Statically link libavif + libwebp into the binary via `build.zig`.
- Full control, single binary, maximum performance on Apple Silicon.
- Promote this path once solid; keep system-tool path only as temporary fallback if needed.

### Format selection
- User choice in the UI:
  - **AVIF** (default) — best compression for modern browsers
  - **WebP** — broader compatibility
  - **Both** — produce both files so the source can serve AVIF with WebP fallback for older browsers
- When “Both” is selected, write two files (e.g. `photo.avif` + `photo.webp`) and show combined savings.

### File acquisition
- Primary: native open dialog via `runtime.showOpenDialog`, called from a `HostCallBinding.request_fn` we bind ourselves in `src/main.zig` (see CLAUDE.md's "File acquisition, honestly"). Requires standing up the platform + runtime by hand (`platform.macos.MacPlatform.createWithOptions` + `native_sdk.Runtime.initAt`) instead of the CLI's non-`pub` `runner.runWithOptions` wrapper, so `main.zig` can hold a `*Runtime` to close over. **Spiked and confirmed working (2026-08-03)** end-to-end against a real macOS open panel — reference implementation at `docs/spikes/dialog-open-file-spike.zig`, ready to transplant.
- Stretch (post-spike): file-drop widget events (`canvas_widget_file_drop` — internal runtime plumbing exists but no documented app-facing hook yet; investigate `ElementOptions` for a drop-target seam once the dialog path works) or file-association / CLI-arg opening (`native app.jpg`) as a zero-click alternative.
- Accept common raster formats that macOS ImageIO / platform codecs can decode (JPEG, PNG, WebP, HEIC, etc.)

### Output handling
- Auto-save next to the source file (e.g. `photo.jpg` → `photo.avif` / `photo.webp`) as soon as "Smoosh" completes — no save dialog in the default path.
- If an output file already exists, overwrite it silently. Re-running "Smoosh" on the same source is treated as "redo this."
- "Save As…" is an optional secondary action to copy the result(s) to a different location; it does not replace auto-save.

### Error states
Each maps to a user-facing message and the `status: "error"` Model state:
- Encoder binary missing (`avifenc` and/or `cwebp` not found) → name the missing tool + `brew install` command.
- Unsupported/undecodable input format → name the file and expected formats.
- Input exceeds size/megapixel limit → show the limit and the file's actual size.
- Encode failed (non-zero exit from `fx.spawn`) → surface a short, non-technical message; details available on demand (e.g. expandable/log).
- Write to output path failed (permissions, disk full, read-only volume) → name the path and the reason if known.

### Input size limits
- Soft limit around **80–100 MB** or ~40–50 megapixels (whichever comes first).
- Rationale: local tool should be more permissive than typical web upload limits, but we still need to protect against pathological files that would exhaust memory when decoded to RGBA.
- Clear, friendly error when exceeded.
- Exact numbers can be tuned once we measure real memory behavior.

### UI sketch (app.native)
```
┌──────────────────────────────────────────────┐
│  Smoosh                                      │
├──────────────────────────────────────────────┤
│                                              │
│         ┌──────────────────────┐             │
│         │                      │             │
│         │   Drop image here    │             │
│         │   or click to choose │             │
│         │                      │             │
│         └──────────────────────┘             │
│                                              │
│  Format:  (•) AVIF   ( ) WebP   ( ) Both     │
│                                              │
│  [preview]          Original: 2.4 MB         │
│                     Smooshed:  187 KB  (−92%)│
│                                              │
│  [ Smoosh ]  [ Save As… ]                    │
│                                              │
└──────────────────────────────────────────────┘
```

States: empty → loading → ready → compressing → done / error

### Core model sketch (high level)
```zig
const Format = enum { avif, webp, both };
const Status = enum { idle, loading, ready, compressing, done, failed };
// NOTE: `failed`, not `error` — `error` is a Zig keyword and won't parse as a bare enum field.

const Model = struct {
    // file
    path_buffer: [1024]u8 = undefined,
    path_len: usize = 0,
    original_size: u64 = 0,
    // preview
    image_id: u64 = 0,           // ImageId from fx.loadImage / fx.registerImageBytes
    // result
    avif_path_buffer: [1024]u8 = undefined,
    avif_path_len: usize = 0,
    avif_size: u64 = 0,
    webp_path_buffer: [1024]u8 = undefined,
    webp_path_len: usize = 0,
    webp_size: u64 = 0,
    savings_percent: f32 = 0,
    // options
    format: Format = .avif,
    // ui
    status: Status = .idle,
    error_message_buffer: [256]u8 = undefined,
    error_message_len: usize = 0,
};
```
(Fixed buffers, not `[]const u8`/`ArrayList`, because `Model` is a plain struct `UiApp` heap-allocates via `create` — see native-ui's Zig-0.16 idioms. Derived display strings — savings text, formatted sizes — are `pub fn` methods over the model, per "Derive, don't store.")

### Msg sketch (high level)
```zig
const Msg = union(enum) {
    pick_file,                          // "Choose Image…" clicked
    dialog_result: DialogResult,        // host open-dialog callback
    image_loaded: ImageLoadResult,      // fx.loadImage/registerImageBytes callback
    set_format: Format,                 // format radio changed
    smoosh,                             // "Smoosh" clicked
    encode_result: EncodeResult,        // fx.spawn callback, one per format encoded
    save_as,                            // "Save As…" clicked
    save_as_dialog_result: DialogResult,// host save-dialog callback
    save_as_result: SaveResult,         // fx.writeFile/copy callback
    encoder_check_result: EncoderCheckResult, // launch-time `which avifenc`/`which cwebp`
    reset,                              // clear current image, return to idle (load another)
};
```

### Status → error mapping
`status: .failed` is always paired with a populated `error_message_buffer`. The "Error states"
list above enumerates every message that can land there; no other path may set `.failed`.

### app.zon changes required
The tree still carries the `native init` counter scaffold. Before M2:
- `description` — replace the "counter that lives in one native window" placeholder.
- The `main-canvas` view's `role`/`accessibility_label` are both "Counter" — retarget to Smoosh.
- `web_engine` / `cef` blocks are unused by this app — remove.

**Keep** `gpu_surfaces` and the `kind = "gpu_surface"` view: native markup renders *onto* a
gpu_surface (the spike's own `ShellConfig` declares exactly that, metal/bgra8_unorm/timer), and
`native automate screenshot <view-label>` only works against a gpu_surface view.

**Keep** permissions as-is: the spike shipped with only `permission_command` + `permission_view`
and the open dialog worked. No separate `dialog` permission was needed. (CLAUDE.md's "Key Native
SDK capabilities" list claims `dialog` and `file_drops` capabilities — that appears to be wrong.)

**Gotcha — the window config exists in THREE places** (corrected in M1; it was written as two).
`platform.AppInfo.main_window.default_frame` is the one that actually sizes the NSWindow and
defaults to 720x480; the `ShellConfig` passed to `App.create` drives view layout; `app.zon`'s
`.shell.windows` drives identity/`native check`/packaging. Full writeup in CLAUDE.md.

### Verification strategy
Every milestone below ends with a check against the *running* app, not a compile check.
- `native build` + `native check` are necessary but never sufficient.
- `native automate widget-click` drives the real UI; this is why markup lands in M2, not last.
- Test fixtures (create once, in M2, under `test-images/`, gitignored): a small PNG, a large JPEG,
  a HEIC from an iPhone, a WebP, an already-tiny PNG (to see a *negative* savings case), a
  non-image file renamed `.jpg`, and one file over the size limit.

### Testing strategy
Two tiers, in this order. Reaching for the GUI to answer a question a unit test answers faster is
the failure mode to avoid.

**Tier 1 — `native test` (`src/tests.zig`, landed with M2).** Deterministic, no GUI, no processes,
no network. This is where a milestone's logic gets proven. The seam is the same dispatch path the
runtime uses: build the markup against the real `Model`, find a widget, ask the tree for the `Msg`,
feed it to `update`.
- Effects milestones drive `Effects` in fake-executor mode (`fx.executor = .fake`) — assert the
  *request* the arm made, then feed the answer and drain:
  - **M3**: `pendingHostAt(0)` names `dialog.openFile`; `feedHostResult(key, true, "/path/…")` then
    a `.wake` drain must land the real path in `Model.path_buffer` and a nonzero `image_id`.
  - **M4**: the oversized fixture's *dimensions/size* reach the limit branch — test the predicate
    over numbers, not a real 51 MP decode.
  - **M5**: `pendingSpawnAt(0)` argv is the presence check; `feedExit(key, 1)` produces the
    `brew install` message with no `PATH` manipulation.
  - **M7**: "Both" is the reason this tier exists — two spawns, results fed in *either* order, and
    the partial-failure case (AVIF `feedExit(0)`, WebP `feedExit(1)`) is how the open decision below
    actually gets made. Also pin the negative-savings arithmetic here; the tiny-PNG fixture is the
    live confirmation, not the primary check.
- What tier 1 does *not* cover: whether the host actually shows an `NSOpenPanel`, whether the
  encoder binary really exists, whether anything renders. Those are tier 2 by definition.

**Tier 2 — `native automate` against `native dev`.** Proves the real seam end to end.
`native build` is ReleaseFast and has neither automation nor hot reload (M1's gate) — verification
runs against `native dev`.

**Fixtures are gitignored**, so tier-1 tests must never read `test-images/`. Anything image-shaped
in a unit test uses in-repo bytes: `canvas.png.writeRgba8` to encode a raw RGBA fixture plus
`harness.null_platform.image_decode = true` for the decode→register→draw path.

## Milestones — v0.1

Ordered by dependency. The file-acquisition unknown is resolved; nothing is left to spike.
Bracketed refs are the MVP success-criteria checkboxes each milestone satisfies.

**Model column:** *Opus* for milestones with real design surface or dense unfamiliar API wiring —
places where a wrong first move costs a rewrite. *Sonnet* for milestones that follow a pattern
already established in the tree; it is faster and the blast radius is small.

**Session column:** *fresh* means start a clean session — the milestone's context is largely
disjoint from what came before, and carrying over stale detail hurts more than it helps.
*share* means continue the previous milestone's session; the working context is directly reusable.

| # | Milestone | Model | Session |
|---|-----------|-------|---------|
| M1 | Zig-core skeleton + app.zon cleanup | Opus | fresh |
| M2 | Model/Msg + minimal markup shell | Sonnet | share M1 |
| M2a | Test harness (`src/tests.zig`) | Opus | share M2 |
| M3 | File acquisition + preview | Opus | fresh |
| M4 | Input size limits | Sonnet | share M3 |
| M5 | Encoder detection at launch | Sonnet | fresh |
| M6 | Format selection | Sonnet | share M5 |
| M7 | Smoosh encode pipeline | Opus | fresh |
| M8 | Save As | Sonnet | share M7 |
| M9 | UI/UX pass | Opus | fresh |
| M10 | Packaging + v0.1 release | Sonnet | fresh |
| M11 | File drops (`on_drop`, new in SDK 0.8.2) | Sonnet | fresh |

---

**M1 — Zig-core skeleton + app.zon cleanup.** *(Opus, fresh session)* — **DONE**
Deleted `src/core.ts`, `package.json`, `tsconfig.json`, `bun.lock`, `node_modules/`. Added
`src/main.zig` (platform + Runtime stood up by hand per the spike, no dialog wiring yet) and a
placeholder `src/app.native`. Applied every "app.zon changes required" item.
Settled here:
- **Automation gate: `builtin.mode == .Debug`.** `dev` in `main.zig` gates both the automation
  server (`native_sdk.automation.Server.init(init.io, ".zig-cache/native-sdk-automation", title)`)
  and markup `watch_path`. So `native dev` gets hot reload + automation; `native build`
  (ReleaseFast) gets neither. **Verification must run against `native dev`, not `native build`.**
- **The window config lives in three places, not two** — see the corrected gotcha above.
- `Model`/`Msg` are deliberate stubs (`Model = struct {}`, `Msg = union(enum) { noop }` with
  `view_unbound`); M2 replaces both with the real sketches.
*Verified:* `native build` clean, `native check` clean (typed, after `native test` built the model
contract), `native test` passes, and the live app renders a 480x320 centered window with
`gpu_nonblank=true` and zero dispatch errors under `native automate`.

**M2 — Model/Msg + minimal markup shell.** *(Sonnet, share M1's session)* — **DONE**
Added the real `Model`/`Msg` to `src/main.zig` and a deliberately ugly `src/app.native` with every
control M3-M8 need: "Choose Image…", an `avif`/`webp`/`both` chip row, "Smoosh", "Save As…", "Reset",
and a `<status-bar>{statusLine}</status-bar>` line. `update` is a no-op switch (one empty arm per
`Msg` tag) — each milestone fills in its own arm.
Settled/found here:
- **Path buffers are `[platform.max_dialog_path_bytes]u8` (4096), not the sketch's literal 1024.**
  The spike's own dialog wiring sizes `path_buf` this way to hold whatever `showOpenDialog` returns,
  and M3 transplants that pattern directly — matching it now avoids a resize when M3 lands.
- **Effect payload types are real SDK types**, not placeholders: `dialog_result`/`save_as_dialog_result:
  native_sdk.EffectHostResult`, `image_loaded`/`save_as_result: native_sdk.EffectFileResult`,
  `encode_result`/`encoder_check_result: native_sdk.EffectExit`. Also corrected against the SDK: images
  register *synchronously* via `fx.registerImageBytes` inside an `update` arm (no completion Msg of
  their own) — so `image_loaded` is really the `fx.readFile` result Msg, and M3's arm calls
  `registerImageBytes` on its bytes in the same handler.
- **The chip pattern needs `pub const formats = [_]Format{...}` declared *inside* `Model`** (not
  file-scope next to it) for `for each="formats"` to resolve — binding resolution only sees Model's
  own decls.
- **`native check` warns** on every model field/fn M2 doesn't bind yet (`path_len`, `original_size`,
  `avif_size`, `status`, the `path`/`errorMessage` fns, ...) — expected and left alone rather than
  papered over with `view_unbound`, since M3-M8 genuinely bind these soon; `view_unbound` is for
  permanently update-only/Zig-view-only state, not "not wired yet."
- **The two unwired chips (`webp`, `both`) go "uncontrolled" once clicked**: since `selected="{f ==
  format}"` never evaluates true for them (format never leaves `.avif` under a no-op `update`), the
  runtime retains their own pressed visual state per click instead of the model overriding it — the
  documented behavior for a toggle whose source never asserts `true`. Confirmed live (all three chips
  render selected after clicking each once); resolves itself the moment M6 wires `set_format` for real,
  since `format` will then actually move and each chip's source will assert both true and false.
- Created the `test-images/` fixtures (gitignored): `small.png`, `tiny.png` (already-tiny, negative-savings
  case), `large.jpg` (~5.6 MB), `photo.heic` (via `sips`), `photo.webp` (via `cwebp`), `not-an-image.jpg`
  (plain text renamed), `oversized.jpg` (8000x6400 = 51.2 MP, clears the 40-50 MP limit while staying
  ~5.7 MB — exercises the megapixel branch distinct from the file-size branch). Confirmed `avifenc`,
  `cwebp`, `dwebp`, `sips`, and `magick` are all already installed on the dev machine.
*Verified:* `native build`/`test`/`check` all clean (check's warnings are the expected unbound-field
kind above); live under `native dev`, the snapshot shows all 8 controls with correct roles/labels,
clicking each of Choose Image…/avif/webp/both/Smoosh/Save As…/Reset delivered with zero dispatch
errors, and a screenshot confirms the rendered layout.

**M2a — test harness.** *(share M2's session)* — **DONE**
Added `src/tests.zig` (+ `test { _ = @import("tests.zig"); }` in `main.zig`, the scaffold's
convention) with the tier-1 seam every later milestone extends: `buildTree`/`findByText`/
`expectByText`/`expectMsgTag` helpers, then 8 tests over what M1-M2 actually produced — markup
builds against the real `Model` in all six `Status` values, all 8 controls are present, widget ids
survive a rebuild, each button dispatches its claimed `Msg`, each chip coerces its loop variable
into a typed `set_format` payload, `selected="{f == format}"` is model-driven for every `Format`,
the path/error accessors slice correctly at 0 and at `max_dialog_path_bytes`, and `statusLine`
returns a distinct non-empty line per status with `.failed` deferring to `errorMessage()`.
Settled here:
- **`update`'s arms are deliberately untested.** They are empty until M3-M8 fill them in; tests
  asserting "nothing happened" would be deleted one per milestone. Msg-tag exhaustiveness is
  already a compile error via `update`'s switch, so it needs no test either.
- **The tests were mutation-checked, not just run green**: flipping `selected="{f == format}"` to
  `selected="false"` and `set_format:{f}` to `set_format:{format}` each failed exactly one test.
  Do this for any new assertion here — a markup test that cannot fail is worse than none.
*Verified:* `native test` 10/10 pass; `native check` still clean with only the expected
unbound-field warnings (no new ones).

**M3 — File acquisition + preview.** *(Opus, fresh session)* [✓ "pick an image via Choose Image…", ✓ "preview with original size"] — **DONE**
Transplanted the spike's `HostBridge` into `src/main.zig` and wired the pick chain. The load is four
hops, one `update` arm each: `pick_file` -> `dialog.openFile` -> `file.stat` -> `sips` thumbnail ->
`fx.loadImage` -> `.ready`. `reset` landed here too.
Settled/found here:
- **The preview MUST be a downscaled thumbnail — this is a hard SDK bound, not a shortcut.** Registered
  images are capped at **1 MiB of DECODED RGBA** (`max_registered_canvas_image_pixel_bytes`, i.e. 512x512
  exactly) and `fx.loadImage` refuses encoded sources past 1.25 MiB. *No real photo can ever be
  registered directly* — `large.jpg` (5.6 MB) and even a 1 MB JPEG both blow the decoded bound. So
  `stat_result` spawns `/usr/bin/sips -s format png -Z 160 <src> --out $TMPDIR/smoosh/preview.png`
  and `fx.loadImage` reads *that*. Measured across every fixture: 160px thumbnails come out 752 B -
  37 KB, three orders of magnitude inside the bound. (This means M3 uses `fx.spawn` before M5 does;
  `sips` is a macOS system binary, so it needs no detection and no `brew install` path. Absolute
  path, so it does not depend on the inherited `PATH`.)
- **`fx.readFile` is the wrong tool for images and was never used.** It caps at 1 MiB
  (`max_effect_file_bytes`) and returns `.truncated` past it — M2's note that `image_loaded` is "really
  the `fx.readFile` result Msg" is superseded: `image_loaded` carries `EffectImageResult`, and
  `fx.loadImage` does read + decode + register in one effect with one terminal Msg.
- **`original_size` comes from a second host command we bind ourselves, `file.stat`**, which stats via
  `std.Io.Dir.cwd().statFile` and answers the byte count as decimal text. A stat is far too cheap for a
  worker thread or a `stat(1)` spawn, and `update` can never hold an `Io` — the bridge can.
  **M7 should reuse it for the output files' sizes**; that reusability is why it is a separate command
  rather than being folded into the dialog's reply.
- **Only the async effects need a stale-result guard.** `thumbnail_result` and `image_loaded` check
  `status == .loading` first: `.reset` cancels them and the cancellation arrives as an ordinary
  terminal that is *indistinguishable from a genuine failure*, so without the guard pressing Reset
  renders "Couldn't build a preview for photo.jpg". `dialog_result`/`stat_result` need no guard — our
  `HostBridge` answers them synchronously inside `hostRequest`, and cancelling a host request delivers
  no Msg at all. Both facts are pinned by tests (each guard was mutation-checked).
- **Reset keeps `Model.format`** and clears everything else — format is a user preference, not per-file state.
- Two Model fns beyond the sketch: `fileName()` (basename, what every error message named until M9
  moved that job to the file card) and `fileSummary(arena)` ("large.jpg (5.6 MB)", replaced in M9 by
  `originalSize`), plus `hasPreview()` gating the `<image>`. All derived,
  none stored. `preview_width`/`preview_height` are stored, from `EffectImageResult` — they are source
  data (the decode's real output), and binding them keeps the preview's aspect ratio honest.
- ~~**Known, deferred to M9:** the window logs `zero_canvas_layout`~~ **Fixed in M9** (540x400 with a
  declared minimum; see that entry).
- ~~Minor: `sips -Z` *upscales* sources smaller than 160px (`tiny.png` renders as a blurry 160x160).~~
  **Clamped in M9** via `previewWidth`/`previewHeight` against the source dimensions.
*Verified:* `native test` 25/25 (nine new fake-executor tests covering the full chain, both cancel paths,
every error state, and reset), `native check` clean with only the expected unbound-field warnings, `native build`
clean. Live under `native dev` against a real `NSOpenPanel` driven to a real fixture: `large.jpg` rendered a
160x120 preview with `large.jpg (5.6 MB)` and status "Ready to smoosh."; the thumbnail really existed at
`$TMPDIR/smoosh/preview.png` (35219 B); Reset cleared it; `not-an-image.jpg` produced the exact
supported-formats message with no preview. `dispatch_errors=0` throughout, screenshot confirms real pixels.

**M4 — Input size limits.** *(Sonnet, share M3's session)* [✓ "reasonable input size limits with clear feedback"] — **DONE**
Enforces **100 MB** / **50 megapixels** at file-load time (the top of PLAN's 80-100MB/40-50MP
range — a local tool should be more permissive than a web upload limit). The byte check landed in
`stat_result`, right after `original_size` lands and before any spawn. The megapixel check needed a
new hop: `stat_result` -> `dimensions_result` (a `sips -g` query) -> `thumbnail_result`, same
stale-result guard pattern as `thumbnail_result`/`image_loaded`, same key-cancellation treatment in
`reset`.
Settled/found here:
- **PLAN.md's original plan — reading dimensions off the thumbnail spawn's own `-g` flags — does not
  work, and was never actually testable against a real `sips`.** Confirmed by running it:
  `sips -g pixelWidth -g pixelHeight -s format png -Z 160 <src> --out <dest>` exits 6,
  `"cannot get properties and modify file in the same invocation"` — `sips` refuses to combine a
  query flag with a modify flag in one call, full stop. The megapixel check needs its own spawn:
  `sips -g pixelWidth -g pixelHeight -1 <path>` (the `-1` one-line form, pipe-delimited:
  `<path>|pixelWidth: <n>|pixelHeight: <n>|`), run from `stat_result` right after the byte check,
  landing as `dimensions_result` before the (unchanged) thumbnail spawn. One extra cheap process per
  pick, not zero as originally hoped — `sips` on a source file is near-instant either way.
- **`sips -g` exits 0 even for a non-image or a missing file** — it prints literal `<nil>` for both
  properties rather than failing. Confirmed against `not-an-image.jpg`. This is harmless: an
  unparseable dimensions result just means "skip the megapixel check," and the thumbnail spawn right
  after is still the real format gate (unchanged from M3). `parseDimensions` returns `null` for
  anything that doesn't parse as two decimal properties, deliberately including this case.
- **Both limits are inclusive, not exclusive**: exactly 100 MB or exactly 50.0 MP passes. `>`, not `>=`.
- Error messages spell out the actual number and the limit (`"\"huge.jpg\" is 132.0 MB — Smoosh
  handles files up to 100 MB."` / `"\"oversized.jpg\" is 51 megapixels — Smoosh handles images up to
  50 MP."`), formatted straight into `fail`'s fixed buffer with `{d:.1}`/`{d:.0}` — no arena needed,
  unlike `fileSummary`.
*Live verification skipped this milestone* — see below.
*Verified:* `native test` 31/31 (six new fake-executor tests: over-byte-limit short-circuits before
any spawn, exactly-at-byte-limit passes, over-megapixel-limit fails and spawns nothing further,
exactly-at-megapixel-limit passes, unparseable dimensions fall through to the thumbnail spawn as the
real gate, and a dimensions query cancelled by `reset` is not reported as a broken image); `native
check` clean with only the same pre-existing unbound-field warnings; `native build` clean.
**Live GUI verification was skipped for this milestone, by user choice, after an automation misfire**:
driving a real `NSOpenPanel` via AppleScript System Events (the method M3 used successfully) sent
keystrokes to the terminal instead — the `native automate widget-click` on "Choose Image…" apparently
didn't bring the Smoosh window frontmost first, so `System Events`' global keystrokes landed on
whatever WAS frontmost (the terminal running Claude Code) instead of the about-to-open panel, typing
a file path into the live session. No files were touched and nothing destructive happened, but the
user opted to trust the fake-executor coverage (which exercises the exact same `update` code path
`sips` really drives, per PLAN's own testing-strategy rationale for this kind of predicate-over-numbers
check) rather than retry the OS-level automation. **Flag for whoever runs M4's live check later**:
confirm the app window is actually frontmost/key before scripting further `NSOpenPanel` interaction —
M3's version of this same trick worked, so something about window focus differed this time.

**M5 — Encoder detection at launch.** *(Sonnet, fresh session)* [✓ error-state: encoder binary missing] - **DONE**
`fx.spawn` a presence check for `avifenc`/`cwebp` on startup, land results as `encoder_check_result`,
surface the "Error states" messaging if either is missing. While here, run both encoders by hand on a
fixture and **pin the confirmed argv back into "Encoder invocations" above** — M7 depends on it.
*Fresh session because:* first `fx.spawn` use; nothing from M3/M4 transfers.
*Verify:* run with a `PATH` that excludes the binary, confirm the correct `brew install` message
renders; restore `PATH` and confirm no error state.
*Implementation:* used `UiApp.Options.init_fx` — the SDK's boot-command hook, not a hand-rolled
lifecycle Msg — since it "runs exactly once, on the installing frame, before the first view build,"
which is exactly "checked at launch." `initFx` spawns `/usr/bin/which avifenc` and
`/usr/bin/which cwebp` (`.collect` output, absolute `which` so the check itself needs no PATH, while
`which`'s own job is searching that PATH — the same resolution a real encode spawn's argv[0] would
get). Both land through the existing `encoder_check_result: EffectExit` Msg (already in the M2 sketch,
disambiguated by `exit.key`); `Model` gained two `?bool` fields (`avifenc_present`, `cwebp_present`)
that stay `null` until each answers, so the join fires only once both are known, in either order.
Three distinct `fail()` messages (avifenc only / cwebp only / both) rather than one templated string,
each naming its own `brew install` command — `libavif` for avifenc, `webp` (not `libwebp`) for cwebp,
confirmed against `brew info`.
*Test harness change:* `Harness.create()` now boots through a new `Harness.createBare()` +
`resolveEncoders(true, true)` pair — `createBare` sets `effects.executor = .fake` **before**
`harness.start`, matching the SDK's own `init_fx` test, so the boot spawns are recorded rather than
actually executed; `resolveEncoders` then feeds both as present so M3/M4's tests see the same
`pendingSpawnAt(0)` shape they always did. M5's own tests call `createBare` directly and drive the
two presence spawns themselves (missing-avifenc, missing-cwebp, missing-both, present/present, and an
order-independence check feeding cwebp before avifenc).
*Verified:* `native test` 37/37 (six new tests). Live: `native dev` with the normal dev-machine PATH
renders the ordinary idle status line ("Drop or choose an image to get started."); relaunched with
`PATH` narrowed to exclude `/opt/homebrew/bin` (so `avifenc`/`cwebp` are unresolvable, while `native`,
`node`, and `zig` stay reachable) and `native automate snapshot` showed the status-bar text update to
"Smoosh needs avifenc and cwebp to compress images. Install with: brew install libavif webp" — the
exact message the fake-executor test predicts. Restored PATH and reran; idle line returned. `native
build`/`check` clean.

**M6 — Format selection.** *(Sonnet, share M5's session)* [✓ "choose output: AVIF / WebP / Both"] - **DONE**
Wire `set_format` from the three format controls to `Model.format`.
*Verify:* click each option, confirm `Model.format` updates and the correct one renders selected.
*Implementation:* one line — `.set_format => |format| model.format = format,`. The chip -> payload
coercion and the `selected="{f == format}"` binding were already proven at the markup level in M2a;
`update` moving `Model.format` was the only piece M2a could not test without a real `update` arm.
*Verified:* `native test` 39/39 (two new tests: each option moves `Model.format` in one send, and
`format` survives a full pick chain unclobbered — the same "format is a standing preference"
invariant `reset` already protects). Live: `native dev` + `native automate widget-click main-canvas
<id>` against all three chips — `avif` selected by default, clicking `webp` moved `state=[selected]`
to it and cleared `avif`'s, clicking `both` did the same. `native build`/`check` clean (same
pre-existing unbound-field warnings only).

**M7 — Smoosh encode pipeline.** *(Opus, fresh session)* [✓ "Smoosh produces selected format(s) and auto-saves", ✓ "before/after size + savings % shown"] — **DONE**
`smoosh` -> one `fx.spawn` per requested format -> `encode_result` -> a `file.stat` per output ->
`encode_size_result` -> `.done`/`.failed`. The pinned M5 argv is used verbatim, with a bare `avifenc`/
`cwebp` as argv[0] (the PATH resolution M5's `which` check was proving).
Settled/found here:
- **PARTIAL FAILURE: partial success wins.** In "Both" mode the two encodes are INDEPENDENT — if one
  succeeds and the other fails, the run is `.done`, the successful format's numbers are shown, and the
  failed one is named in the status bar. Only when NO requested format landed is the run `.failed`.
  *The deciding fact is that the encoders write their own output files:* by the time WebP's nonzero exit
  arrives, `photo.avif` is already on disk next to the source, so failing the whole run would mean either
  claiming failure with a good file sitting right there, or deleting a file the user can see. It also makes
  a missing encoder degrade instead of block — a machine with only `avifenc` still gets its AVIF out of a
  "Both" run, where M5's launch check alone would have dead-ended it. The all-failed floor keeps the
  "Status → error mapping" invariant intact, and in single-format mode it IS the ordinary failure path —
  no special case, one branch.
- **The join must never re-read `Model.format`.** Completion is "neither format is `.pending`", tracked on
  a per-format `EncodeOutcome` (`none`/`pending`/`ok` + four failure reasons). The chips stay live while
  encoding, so a join that re-read the current selection would end the run early when the user narrows
  Both -> AVIF mid-flight, silently orphaning the WebP file still being written. Caught by mutation
  testing, not by the first version of the test — the original test changed the format too late to expose it.
- **`.done` needed its own warning buffer**, separate from `error_message_buffer`. The two coexist in
  exactly the case this milestone exists to handle, and keeping them apart is what preserves "`.failed` is
  always paired with an error message, and no other path sets `.failed`".
- **A zero exit is not a result.** The output's size comes from a `file.stat` on the destination (M3's own
  host command, kept separate for precisely this reuse), which doubles as the only available signal for
  the "write to output path failed" state — the encoder writes its own destination, so there is no
  separate write step to fail.
- **Encoding a `.webp` source to WebP is skipped, not performed** (`same_path`): the destination would BE
  the source, handing the encoder one file to read and overwrite. "Overwrite silently" is about a previous
  OUTPUT, never the user's original. Not in PLAN's original error list; found while deriving output paths.
- **Output paths scope the extension search to the last path component** — `/a/my.photos/holiday` must
  become `/a/my.photos/holiday.avif`, not `/a/my.photos.avif`.
- **`savings_percent` was deleted from the Model sketch**, not implemented: it is pure arithmetic over
  `original_size` and each output size, so it is derived per rebuild ("Derive, don't store"). Negative
  savings is real and reads as `+1% larger`; a sub-half-percent difference either way reads `same size`.
- **"Combined savings" for Both mode resolved as per-format lines, not a sum.** A summed total describes a
  download that never happens — no client fetches both files — so each line reports what would really be
  served if that format were chosen. Degrades cleanly to one line when the other format failed.
- **Widget ids were NOT stable across conditional rows, and now are.** Every `<if>` child of the root
  column that starts rendering re-disambiguates its unkeyed same-kind siblings, so ids after it all move —
  the Smoosh button took three different ids across idle -> ready -> done, which broke an automation script
  mid-run during this milestone's own live check. Fixed by giving every root child a `key`. This predates
  M7 (M3's preview `<if>` did it too); M2a's id-stability test could not catch it because it only changes
  `status`, which alters no structure. A second test now covers it.
- **`Model.view_unbound` landed**, taking `native check` from 17 warnings to zero. M2 deliberately left
  them, reasoning "M3-M8 genuinely bind these soon"; what remains after M7 is permanently update-side, so
  naming it makes a future warning mean something again.
*Verified:* `native test` 62/62 (23 new: both single-format argvs pinned, Both joined in either order,
both partial-failure directions, the all-failed floor, missing-encoder per format, write-failure, the
same-path skip, output-path derivation, negative savings, lifecycle guards, and the id-stability
regression). **All 11 mutations applied to the new logic were caught** — including two that initially were
NOT, which is how the format-mid-encode gap and a compile-broken mutation were found; the tests were
tightened until each failed exactly the assertion it should. `native check` clean with zero warnings,
`native build` clean.
*Live (against `native dev`, real fixtures, `dispatch_errors` clean — the only two were my own malformed
automation command strings):* `large.jpg` as AVIF wrote `test-images/large.avif` at 717,003 B and rendered
`AVIF  700.2 KB  −88%`; switching to Both and re-pressing Smoosh redid AVIF and added
`test-images/large.webp` at 671,054 B rendering `WebP  655.3 KB  −89%`; `tiny.png` as Both wrote 315 B and
68 B rendering `AVIF  315 B  +1% larger` and `WebP  68 B  −78%` — the negative-savings case displaying
sanely, as required. Every size matches the by-hand encoder run exactly. Widget ids confirmed identical
across `.done` and `.idle` after the `key` fix.
**Live automation of the open panel was NOT used, and should not be**: the app runs as a bare executable
from `.zig-cache`, and System Events cannot bring it frontmost (`set frontmost` silently no-ops), which is
the exact condition behind M4's misfire — global keystrokes land on whatever IS frontmost, i.e. the
terminal. The two file picks in this milestone were performed by hand by the user; everything after the
file loads was driven normally with `native automate widget-click`. **This resolves M4's open flag:** the
answer is not "check frontmost first", it is that this seam is unreachable until the app is a real `.app`
bundle (M10). Until then, treat the open panel as a manual step.

**M8 — Save As.** *(Sonnet, share M7's session)* [✓ "optionally re-save output to a different location"] — **DONE**
`save_as` -> `showSaveDialog` -> copy the chosen output(s) to the chosen location. Does not replace M7's
auto-save.
Settled/found here:
- **"Both" mode needed a real design decision PLAN's one-line sketch didn't cover**: `showSaveDialog`
  only ever returns ONE path, but Smoosh can produce two files. Asked the user rather than guess; settled
  on SEQUENTIAL rounds — one save-dialog-then-copy per landed format, one after another (AVIF's panel,
  then WebP's), over a folder-picker (`showOpenDialog` with `allow_directories=true`, an SDK-sanctioned
  idiom but one PLAN never mentions) or disabling Save As for "Both" (rejected: Both is the headline
  feature, and silently disabling its own Save As reads as a regression). A cancelled round is silent and
  the other format is still offered; only a copy failure is reported.
- **`save_as_result` changed type from PLAN's sketch** (`fx.writeFile`'s `EffectFileResult`) **to
  `EffectHostResult`**: `fx.writeFile`/`fx.readFile` cap at `max_effect_file_bytes` (1 MiB), and a real
  encoder output can exceed that — the identical bound M3 already hit with the source image itself. Copy
  goes through a THIRD host command bound by hand, `file.copy` (`std.Io.Dir.copyFileAbsolute`, unbounded),
  payload shaped `"<source>\n<destination>"` — the same newline-joined convention the SDK's own multi-path
  open-dialog results use.
- **The Model tracks a `save_queue: [2]Output` + index**, not a per-format outcome enum like M7's
  `EncodeOutcome`: the two save rounds are strictly SEQUENTIAL (never concurrent), so there is no
  either-order join to handle — the queue is simpler and sufficient. `index == len` at rest (true even at
  `0 == 0`) means "no round in flight"; `save_as` rebuilds the queue fresh every press.
- **A save note lives in its own `save_message_buffer`**, not `warning_message_buffer`: an encode warning
  and a save note are different facts about different actions, and folding them into one field would mean
  one silently overwriting the other. `statusLine()` shows the save note first when present — the freshest
  thing the user did — falling back to the ordinary status text otherwise; both `clearResults` (a new pick
  or a re-`smoosh`) and `.reset` clear it, so it can never outlive the run it's about.
- **Host requests turned out to need no staleness guard, confirmed rather than assumed**: dialogs block
  the loop (same fact M3 already established for `dialog_result`/`stat_result`), so a save round can never
  be mid-flight when another Msg is dispatched. The defensive `index >= len` guards on both result arms
  are provably unreachable through the effects channel itself — mutation-tested by dispatching a raw
  `save_as_dialog_result`/`save_as_result` Msg directly (bypassing `fx` entirely), the only way to reach
  them at all.
- **Mutation testing caught two real test gaps, not just main.zig bugs.** A same-key `fx.hostRequest`
  re-issue REPLACES the pending one (the channel's documented behavior), which made a naive "second
  Save As press -> still exactly one pending request" test pass whether or not the double-press guard
  existed — the guard's removal was invisible until the test was rebuilt around a "Both" run with an
  ALREADY-ADVANCED round (AVIF's copy done, WebP's dialog pending), where a missing guard visibly
  swaps out the in-flight round instead of just no-op-ing. Separately, no test ever asserted the exact
  `file.copy` payload text, so swapping source and destination in the format string — which would copy
  the chosen destination OVER the real output, backwards — passed every existing assertion; added a test
  pinning the full `"source\ndestination"` string.
*Verified:* `native test` 78/78 (16 new: single-format and "Both" happy paths — including the copy
payload's exact source/destination order — sequential-not-concurrent dialog ordering, both cancel
shapes (one-of-two, all), a copy failure not blocking the next round, the two "nothing to save"/"already
in flight" guards, both defensive dead-code guards via direct Msg dispatch, `clearResults`/`reset`
interaction, and the destination filename deriving from the FORMAT's extension rather than the source's).
Every mutation applied to the new logic was caught, including two where the first version of the test
did not — tightened until each failed exactly the assertion it should, same discipline as M7. `native
check` clean at zero warnings, `native build` clean. Live against `native dev` and real fixtures (open
and save panels driven by the user by hand, per M7's now-standing rule — see CLAUDE.md): a "Both" run's
two sequential save rounds (AVIF's panel, then WebP's) produced copies verified **MD5-identical** to a
fresh by-hand encoder run at the exact expected sizes; a single-format (AVIF-only) run's Save As,
cancelled at the panel, left the status bar reading exactly "Done." with `dispatch_errors=0` — matching
the fake-executor coverage exactly.

**M9 — UI/UX pass.** *(Opus, fresh session)* [✓ "launches to a clean drop-zone UI", ✓ works at small window sizes] — **DONE**
Replaced M2's scaffold with the real view: a header, one middle band that swaps between a pressable
drop zone (empty) and a file card — preview left, name/size/results right (with a file), the format
chips, the actions row, and the status line. The chrome around the middle band never moves, so every
control keeps its widget id across the swap (verified live: the ids in the empty-state and
ready-state snapshots are identical).
Decisions worth keeping:
- **The drop zone says "click", not "drop".** PLAN's sketch reads "Drop image here"; file drops are
  M11's open question and do not work in v0.1, so the zone (and `statusLine`'s idle text, changed to
  "Choose an image to get started.") promises only what the app does. A drop zone that lies about
  accepting drops is the one thing a drop zone must not do.
- **The window grew to 540x400, with `min_width`/`min_height` declared** (420 / 400 — all three
  places, per CLAUDE.md's three-declarations gotcha). 480x320 was M2's guess made before any content
  existed; the ready state overflowed it, which is the `zero_canvas_layout` diagnostic M3 deferred
  here. `min_height` equals the default on purpose: every row is fixed-height and the preview frame
  is a fixed box, so vertical shrink buys nothing and costs the layout its only slack. The extra 60px
  of WIDTH is for the status line (below).
- **Error messages stopped naming the file.** `<status-bar>` is one honest line — it takes no `wrap`
  (a validation error: "put wrap on the text leaf itself") and `size="sm"` does not shrink its text,
  both confirmed by trying them — so it elides at roughly 65 characters. A quoted filename cost ~18
  of those, and the live failed state read `"not-an-image.jpg" isn't an image Smoosh can read. Try
  JPEG,…` — the truncated half being the half that says what to do. The file card now names the file
  in every state that can fail, so the five load/write messages explain what happened and nothing
  else ("Not an image Smoosh can read. Try JPEG, PNG, HEIC or WebP."). PLAN's "Status → error
  mapping" invariant is untouched: `.failed` still always surfaces the error buffer through
  `statusLine`. The alternative — a wrapping error inside the card — would have duplicated the same
  string in two places in one small window.
- **Smoosh and Save As disable on exactly the predicates `update`'s own arms enforce**
  (`canSmoosh`/`canSave`, each a Model fn mirroring its arm's guards) — a press that would be a
  silent no-op now says so. `isBusy` (loading OR compressing) drives a spinner beside the status
  line, `isFailed` an alert icon: every message lands in the same line of text, so a failure needs a
  mark. The icon rides BESIDE the bar rather than recolouring it — two `<status-bar>`s behind an
  if/else would give the status line two different widget ids, and automation addresses it as one.
- **The chip iterable became `[]FormatChip{ value, label }`**, so the chips read "AVIF"/"WebP"/"Both"
  instead of the lowercase Zig tag names. A `pub fn label` on `Format` was tried first and rejected
  by the checker — bindings resolve FIELDS on a loop item, and an enum has none ("binding does not
  name a field on the loop item"). `{c.value}` still coerces into the `set_format` payload.
- **`sips -Z`'s upscaling is clamped** (M3's deferred minor note): `previewWidth`/`previewHeight`
  cap the thumbnail at the SOURCE's real dimensions, now kept from M4's `sips -g` hop. The preview
  sits in a fixed 168x168 frame so an 8x8 icon draws 8x8 centred rather than a blurry 160x160 —
  clamping alone made the card look broken, which is why the frame is fixed and the image is not.
- **A bug the new card exposed:** a new pick never cleared the previous file's preview. It was
  invisible under M2's scaffold and obvious the moment name and thumbnail sat side by side — live,
  picking `not-an-image.jpg` after `tiny.png` drew tiny.png's thumbnail beside the new name. Fixed
  with `clearPreview()` at the successful `dialog_result`, i.e. at the PICK, not at the failure: the
  whole load chain runs with the card already naming the new file.
*Verified:* `native test` 85/85 (11 new: the drop zone's pressable panel and its disappearance, the
disabled matrix across idle/ready/compressing/done, the spinner tracking `isBusy` across every
Status, the alert icon appearing for `.failed` but NOT for a partial-success `.done`, the preview
clamp in all three directions — upscale, larger source, unparsed dimensions — the file card's
name/size lines, and the stale-preview regression). Every new assertion was mutation-checked:
dropping `disabled="{not canSmoosh}"`, defeating the clamp, swapping `isFailed` for `isBusy`, and
removing `clearPreview()` each failed exactly the one test that should catch it. `native check`
clean at zero warnings, `native build` clean. Live under `native dev`, with the open panel driven by
hand (M7's standing rule): empty, ready, done (a "Both" run on `large.jpg` showing both result
lines), the tiny-source clamp, and the failed state all render with `dispatch_errors=0` and no
`zero_canvas_layout` in any state.
*Note for M10:* the first pass coloured the result lines `success_text`, which is the on-success-fill
foreground and rendered nearly invisible on the dark background — `success` is the token for tinted
TEXT. Caught only by looking at a screenshot; the snapshot reports names, not contrast.

**M10 — Packaging + v0.1 release.** *(Sonnet, fresh session)* — **DONE**
`native package` the app, real icon in place of the scaffold's, confirm it launches from `/Applications`
on a machine that never ran `native build`. Decide and record whether v0.1 ships signed/notarized or
as an unsigned local build — this determines whether anyone but you can open it.
*New milestone:* the old plan ended at feature-complete with no path to a runnable artifact.
Settled/found here:
- **Signed adhoc, not notarized, not unsigned.** `security find-identity -v -p codesigning` found zero
  identities on this machine — no Apple Developer Program membership, so real Developer ID signing +
  notarization is not available. Between the two options that ARE free, `--signing adhoc` over
  `--signing none`: ad-hoc costs nothing, needs no account, and gives the bundle a valid local code
  signature (`codesign -dv` confirms `flags=0x2(adhoc)`, verified). Its real limitation — it does
  nothing for Gatekeeper's "unidentified developer" prompt on a QUARANTINED copy (AirDropped, emailed,
  downloaded) — doesn't bite here: this app is for one person on one Mac, dragged locally into
  `/Applications`, never quarantined. Revisit only if this ever needs sharing with someone else, which
  would need a paid Developer ID + `notarytool`.
- **A real bug, found only by actually launching from `/Applications`:** the packaged app opened to
  M5's "install avifenc/cwebp" error — with both genuinely installed via Homebrew. Cause: every
  `fx.spawn` child (M5's `which` check, M7's real encoder spawns) inherits `Runtime.Options.environ`,
  which was wired straight to the RAW process environment. A GUI-launched process (Finder/Dock
  double-click — what EVERY packaged `.app` is) inherits launchd's minimal PATH
  (`/usr/bin:/bin:/usr/sbin:/sbin`); Homebrew's `/opt/homebrew/bin` only lands on PATH via
  `brew shellenv` in `.zshrc`/`.zprofile`, which only an interactive/login shell sources — exactly what
  `native dev`/`native build` always was, and a packaged app never is. M5's own comment ("Absolute so
  the check does not depend on the inherited PATH") had already named the dependency without the
  packaged case existing yet to expose it. Fixed once, at the source: `resolveSpawnEnviron` (`src/main.zig`)
  widens the bound environ's PATH with Homebrew's four standard dirs before `Runtime.initAt`, so every
  spawn downstream — presence check and real encodes alike — inherits the fix without touching either
  call site. No-ops (returns the original `Environ` unchanged, provably by pointer identity, not just
  content) when `/opt/homebrew/bin` is already on PATH, so `native dev` behavior is untouched — confirmed
  by the three new tests, one of which is exactly that identity check.
- **`native package` does not clean its output directory.** A stray `assets/icon.png.bak` (a backup
  made while iterating on the icon) rode along into `Contents/Resources/assets/` on the first package
  run and was still there on the SECOND, after the source file was deleted — `native package` only
  overwrites files it knows about, it never removes ones that used to exist. `rm -rf zig-out/package`
  before any packaging run that matters, not just the first.
- **The icon is a placeholder, not a real design pass — flagged as ugly and kept anyway.** Built by
  hand-writing an SVG (dark squircle background, a gray rounded-square "original" shrinking via a green
  arrow into a smaller white rounded-square "result") and rasterizing it with
  `magick icon.svg -background none icon.png` at 1024x1024 — the only rasterizer available on this
  machine (`rsvg-convert`/`inkscape` are not installed). ImageMagick's built-in SVG delegate (MSVG) is
  primitive: `<linearGradient>` fills silently rendered solid black, and `<line>`/`<path>` elements with
  `stroke`/`stroke-width` did not render AT ALL (confirmed with an isolated test SVG) — the arrow had to
  be built as two filled `<polygon>`s (a quadrilateral shaft + a triangle head) by hand-computing their
  corners, because MSVG only reliably draws flat-filled shapes. Source SVG was scratchpad-only and does
  not persist in the repo; **a future session redoing this should use a real vector tool (Inkscape,
  Figma export, or an installed `rsvg-convert`) instead of fighting MSVG's fill-only subset**, and should
  treat the current `assets/icon.png` purely as a placeholder to replace, not a baseline to iterate on.
*Verify:* copy the packaged `.app` to a clean location, launch, run one full smoosh.
*Verified:* `native test` 88/88 (3 new, covering `resolveSpawnEnviron`'s append/no-op/from-scratch
cases; the no-op case is a pointer-identity check, and mutation-tested by disabling the early return —
which broke exactly that one test, with a leak, confirming a fresh allocation had happened where the
function should have returned its input untouched). `native check`/`native build` clean. Packaged with
`native package --target macos --signing adhoc`; `codesign -dv` confirms a verified ad-hoc signature.
Copied to `/tmp` (no quarantine attribute, confirmed via `xattr -l`) and separately installed to
`/Applications/Smoosh.app` — both launched clean with zero `.zig-cache`/build tooling nearby, proving no
hardcoded repo paths (confirmed by grepping `src/main.zig` for `assets/`/`test-images`/`zig-out` — none
outside a comment). First `/Applications` launch reproduced the PATH bug live; after the
`resolveSpawnEnviron` fix, rebuilt/repackaged/reinstalled and the same launch showed the normal idle
status line. User then ran one full smoosh from the installed `/Applications` copy by hand (open dialog
driven manually, per the standing dialog-automation rule) and confirmed it completed correctly.

**M11 — File drops.** *(Sonnet, fresh session)* — **DONE**
The open question CLAUDE.md left ("whether a drop-zone `on-file-drop` markup hook exists") has an
answer, and it changed with the toolchain: **`@native-sdk/cli` was upgraded 0.8.0 -> 0.8.4, and 0.8.2
added the app-facing seam.** Everything below is read out of the installed CLI's source
(`~/.npm-global/lib/node_modules/@native-sdk/cli`), with the version claim verified by unpacking the
0.8.0/0.8.1/0.8.2/0.8.3 tarballs. No code was written; this entry IS the spec.

*The seam.* Not markup — a `UiApp.Options` field:
```zig
on_drop: ?*const fn (drop: platform.FileDropEvent) ?MsgT = null,   // src/runtime/ui_app.zig:635
```
Dispatched from `handleRuntimeEvent`'s `.files_dropped` arm (ui_app.zig:4025) against `drop.window_id`.
`platform.FileDropEvent` (src/platform/types.zig:1608) is `{ window_id, view_label, point, paths:
[]const []const u8 }`. `on_drop` occurrences in `ui_app.zig` by version: 0.8.0 → 0, 0.8.1 → 0,
0.8.2 → 2, 0.8.3 → 2, 0.8.4 → 2. The platform already emitted `files_dropped` in 0.8.0 and `flow.zig`
already routed it; what 0.8.2 added is the app-facing hook. **The TypeScript `dropMsg` the release
notes advertise is literally this field** — the ts-core adapter wires `on_drop` from an exported
`dropMsg` (skill-data/ts-core/SKILL.md:492). Zig sits one layer *below* the advertised feature, so
this is a direct call, not a port of anything.

*Four constraints that shape the UI, all verified in source:*
1. **The drop is WINDOW-wide, not drop-zone-shaped.** On a real drag the macOS host builds the event
   from `window_id` + paths only — no `view_label`, no `point` (src/platform/macos/root.zig:962).
   Anywhere in the Smoosh window accepts. Fine for a one-window single-purpose app; the copy must not
   promise a targeted zone.
2. **The widget-level channel is a double dead end — do not chase it.** A `canvas_widget_file_drop`
   event and a `routeCanvasWidgetFileDrop` router do exist, but (a) `UiApp.handleRuntimeEvent` has no
   case for it and silently drops it into `else => {}` (its only mention in `ui_app.zig` is the
   hover-drain switch at 3951), and (b) the router bails immediately when `view_label.len == 0` or
   `point == null`, which per (1) is every physical drag. There is also no `on-file-drop` /
   `accepts-drop` markup attribute at all (grepped `src/primitives/canvas/ui_markup.zig`).
3. **A drag-over highlight is impossible.** The AppKit host's event enum has exactly one drag kind,
   `NATIVE_SDK_APPKIT_EVENT_FILES_DROPPED` (appkit_host.h:24); `draggingEntered:` returns
   `NSDragOperationCopy` unconditionally and emits nothing (appkit_host.m:1199). The zone stays
   visually static — no hover state to design.
4. **Nothing needs enabling.** The NSWindow registers `NSPasteboardTypeFileURL` unconditionally at
   creation (appkit_host.m:7775 — the comment explains it: the main WebView is lazy now, so the window
   took over the registration; a canvas-only app never creates that WebView and
   `NativeSdkMetalSurfaceView` does not register, so the window delegate receives every drop). No
   `RunOptions.bridge` gate, no permission, no runtime capability check anywhere on the path.

*app.zon.* `"file_drops"` IS a real capability string (`app_manifest.CapabilityKind.file_drops`) — so is
`"dialog"`. **CLAUDE.md's "no evidence either exists, do not add them speculatively" line is wrong and
must be corrected when this lands.** Both carry a `void` payload and nothing in the runtime reads them,
so adding `"file_drops"` to `.capabilities` is honest metadata, not a switch.

*Wiring — one Options field, one Msg arm.* Add `.on_drop = onDrop` to the `App.create` options beside
`.update_fx`/`.init_fx`. Recommended shape: `onDrop` returns the **existing** `.dialog_result` arm,
synthesizing `native_sdk.EffectHostResult{ .key = dialog_key, .ok = true, .bytes = drop.paths[0] }`,
so a drop re-enters M3/M4's already-validated chain (`setPath` → `clearResults`/`clearPreview` →
`file.stat` → 100 MB check → `sips -g` → 50 MP check → thumbnail → `fx.loadImage` → `.ready`) with
zero new pipeline. A dedicated `dropped_file: []const u8` arm that does the same work reads more
honestly in a transcript — pick one in the session; either way it goes in `Msg.view_unbound`.
Things the session must decide or handle:
- `drop.paths` is **drain scratch**, borrowed for the callback and the dispatch. `Model.setPath`
  already copies into a fixed buffer, which is the rule — do not stash the slice.
- **`on_drop` has no model access** (it is `fn(event) ?Msg`, not `fn(*Model, event) ?Msg`). It cannot
  ignore a drop that arrives mid-`.encoding`; that gating belongs in `update`'s arm.
- Multi-file drop: `paths` may hold up to `max_drop_paths` entries. Take `paths[0]` and ignore the
  rest for v0.1, or refuse a multi-drop loudly — a real decision, make it explicitly. Empty `paths` →
  return `null`.
- Folders and non-images arrive on the same channel and land in M4's existing `dimensions_result`
  failure path (`sips -g` errors on them), so they fail correctly but with a generic message.

*Testing.* `onDrop` is a pure function — tier-1 testable with no runtime at all (feed a synthetic
`FileDropEvent`, assert the Msg; then push that Msg through the existing fake-executor `Harness` to
prove the whole chain). **The live half cannot be automated, at all.** `native automate` has no bare
drop verb; `widget-action <view> <id> drop-files <paths>` does exist
(automation_commands.zig:374) but requires the target widget to declare
`semantics.actions.drop_files`, which markup cannot express — and it drives the widget channel that
constraint (2) says a real drag never reaches, so it would prove the wrong thing. **The user must drag
a real file onto the window by hand.** Note this is a *different* constraint from the standing
dialog rule (dialogs are dangerous to automate; drops are simply not automatable) — the practical
instruction is the same: ask. Optional follow-up if a regression test is ever wanted: `native automate
record --out session.journal` around one hand-drag captures `files_dropped` (journal tag 17) and
`native automate replay` re-runs it headlessly.

*UI copy M9 deliberately deferred.* With drops real, the zone can finally say so — suggested "Drop an
image here — or click to choose", with `statusLine`'s idle text following. No new widgets, no id churn.

*The 0.8.4 upgrade is otherwise a no-op for this app.* Verified before touching anything: `native test`
**88/88 pass** and `native check` clean with **zero** warnings on 0.8.4. (The first `check` warned only
that `zig-out/model-contract.zon` was stale from the 0.8.0 build; rerunning `native test` regenerated it
and `check` went quiet — the M1 note about running `test` before `check` applies after every upgrade.)
There is no pinned SDK version in the tree to bump: no `build.zig.zon` exists, so `native build` links
whatever the globally installed CLI carries.

*Before writing code, refresh the skills.* `~/.claude/skills/native-ui/SKILL.md` was installed
2026-08-03 (0.8.0) and differs from 0.8.4's `skill-data/native-ui/SKILL.md`; `native skills get`
re-emits them. Be aware that **even 0.8.4's `native-ui` and `zig` skills do not document `on_drop`** —
only ts-core's does, and only as a one-line adapter aside — so this entry is the authoritative
reference for the Zig signature.
Built exactly the spec above: one `Msg` field, one pure callback, one shared helper, one options
wire-up.
Settled/found here:
- **`Msg` gained `dropped_file: []const u8`, a dedicated arm — not a synthesized `.dialog_result`.**
  Both shapes were offered as options above; the dedicated arm won because a transcript (or a test
  name) that reads "`dropped_file`" says what happened, where a synthesized `EffectHostResult{ .key =
  dialog_key, ... }` would read as a dialog answer that never happened.
- **The two entry points share one helper, `beginLoad(model, fx, path)`**, factored out of what used
  to be `.dialog_result`'s ok-branch body: set `.loading`, `setPath`, `clearResults`, `clearPreview`,
  issue the `file.stat` request. `.dialog_result`'s ok branch now just calls it; `.dropped_file` calls
  it directly, since there is no dialog round trip to answer first. This is the concrete form of the
  PLAN's own claim that "a drop re-enters the already-validated chain with zero new pipeline" — after
  this refactor that is true by construction, not just by intent, and mutation-testing `clearResults`/
  `clearPreview` out of `beginLoad` fails BOTH the pre-existing pick-based regression test and the new
  drop-based one, confirming the sharing is real.
- **`onDrop` takes `paths[0]` and ignores the rest**, matching `showOpenDialog`'s existing single-select
  behaviour (`allow_multiple` defaults false) — a drop and a pick now behave alike for a multi-file
  case rather than one silently accepting more than the other. Empty `paths` returns `null`, so
  `handleRuntimeEvent` dispatches nothing (a drag of something with no file, e.g. dragged text).
- **`onDrop` is `pub`, matching `formatBytes`/`formatSavings`/`resolveSpawnEnviron`'s precedent** for a
  pure helper worth testing directly rather than only through the dispatch path — PLAN's own testing
  note ("`onDrop` is a pure function — tier-1 testable with no runtime at all") needed this to be
  callable as `main.onDrop(...)` from `tests.zig`.
- **`app.zon` gained `"file_drops"` in `.capabilities`.** Confirmed real (`app_manifest.CapabilityKind
  .file_drops`) by the investigation above; nothing in the runtime reads it (same as `native_views`/
  `gpu_surfaces`'s existing honesty-not-a-switch status), so this is metadata, not wiring. **CLAUDE.md's
  "no evidence either exists, do not add them speculatively" line was corrected** — it was wrong about
  `file_drops` (real) though right that nothing reads it as a gate.
- **The drop zone's copy changed from "Click to choose an image" to "Drop an image here — or click to
  choose"**, and `statusLine`'s idle text reverted from M9's "Choose an image to get started." back to
  the original M5-era "Drop or choose an image to get started." — M9 had removed "drop" specifically
  because it didn't work yet (PLAN's own M9 entry: "a drop zone that lies about accepting drops is the
  one thing a drop zone must not do"); M11 is what makes the word true again. A pre-existing test
  (`"the empty state offers a drop zone that picks a file"`) pinned the old copy literally and needed
  updating — expected, not a regression.
*Verified:* `native test` 93/93 (5 new: `onDrop` returns the right `dropped_file` payload, takes the
first of several paths, returns `null` on an empty list; a dropped path reaches `.ready` through the
unmodified `stat_result` -> `dimensions_result` -> `thumbnail_result` -> `image_loaded` chain; a drop
clears a previous run's results and preview the same way a pick does). Each new assertion was
mutation-checked: swapping `paths[0]` for the last path failed exactly the "takes the first" test;
deleting `clearResults`/`clearPreview` from `beginLoad` failed 4 tests (both the new drop-based
regression test and the pre-existing pick-based one it now shares code with) rather than 0, which is
what proves the sharing is load-bearing and not just parallel code that happens to agree. `native
check` clean at zero warnings, `native build` clean.
**Live, by the user's own hand (drops cannot be automated at all — see the investigation above; this
is a different constraint from the standing "don't automate dialogs" rule, but the same practical
answer):** dragging `test-images/photo.heic` onto the running `native dev` window landed it in `.ready`
with the real name ("photo.heic") and size ("Original 2.2 MB") shown, `dispatch_errors=0` — a drop is
provably indistinguishable from a pick past `onDrop`, live and not just in the fake-executor tests.
Pressing Smoosh on that file failed with "AVIF encoding failed."; independently confirmed by running
`avifenc`/`cwebp` against the same file from a shell that this is `avifenc`/`cwebp` themselves
rejecting HEIC as an INPUT format ("Unrecognized file format for input file") — a pre-existing Phase A
system-tool gap a picked HEIC would hit identically, unrelated to drops, and out of M11's scope.
Dragging `test-images/large.jpg` instead and pressing Smoosh (via `native automate widget-click`, which
*is* fair game once a file has loaded) produced `AVIF  700.2 KB  −88%` and status "Done." with
`dispatch_errors=0` — the exact numbers M7's own live check recorded — and `test-images/large.avif`'s
mtime confirmed a fresh write at the moment of the click, not a stale file from M7's original run
sitting untouched. This is PLAN's "one full smoosh from a dropped file," done.
*Sonnet because:* the open-ended source investigation that justified Opus was already DONE and written
down above before this session started. What remained was the small, fully specified change against a
pipeline this repo already owned — M8-shaped, as predicted. The hand-drag behaved exactly as the
investigation predicted; no escalation was needed.

## Open decisions
- ~~Partial failure in "Both" mode: report success-with-warning, or fail the whole operation?~~
  **Resolved in M7: success-with-warning**, with an all-failed floor that stays `.failed`. The
  encoders write their own output files, so a failed whole-operation would contradict a good file
  already on disk. Full rationale in the M7 entry above.
- ~~Signed/notarized vs unsigned for v0.1~~ **Resolved in M10: ad-hoc signed, not notarized.** No paid
  Apple Developer identity exists on this machine; ad-hoc is free and strictly better than unsigned for
  a single-machine local tool. Notarization is a future concern only if this ever needs sharing with
  someone else. Full rationale in the M10 entry above.
- ~~Whether `native check` is meaningful for a zig-core tree~~ **Resolved in M1: yes.** It validates
  markup + app.zon, and once `native test` has emitted `zig-out/model-contract.zon` it also
  type-checks every binding path, message tag, and payload against the real `Model`/`Msg`. Without
  that artifact it degrades to grammar-only with a loud note — so run `native test` before `check`
  if you want the typed pass.

## Known limitations

- **HEIC input cannot be encoded to AVIF or WebP.** `avifenc`/`cwebp` (Phase A's system tools) reject
  `.heic`/`.heif` outright as an INPUT format — confirmed by running both directly against
  `test-images/photo.heic`: `avifenc` says "Unrecognized file format for input file", `cwebp` says
  "Cannot read input picture file". A HEIC picks, drops, and previews correctly (`sips` decodes it fine
  for the thumbnail — see M3), and the file card names and sizes it correctly, so nothing looks wrong
  until Smoosh is pressed, where it fails every time with "AVIF encoding failed." / "WebP encoding
  failed.", regardless of whether the file arrived via the open dialog or a window drop (confirmed live
  for both paths in M11's entry above).
  - **This makes existing copy inaccurate, not just the encode itself.** PLAN's own "Accept common
    raster formats" line names HEIC as accepted, the open-dialog's file filter offers `.heic`/`.heif`,
    `test-images/photo.heic` exists specifically to exercise it (M2), and M9's failed-decode message
    ("Try JPEG, PNG, HEIC or WebP.") implies HEIC round-trips end to end — none of that is true today
    for the encode side, only for decode/preview.
  - **Two directions for a follow-up session, not yet decided between:**
    1. *Narrow the promise.* Drop HEIC from the accepted-formats copy, the open-dialog filter, and the
       error message until it genuinely works — fail a picked/dropped HEIC earlier and honestly (at
       pick time) instead of letting it ride the full chain into a confusing encode failure.
    2. *Fix it in Phase A.* `sips` already decodes HEIC correctly — it is what builds the preview
       thumbnail — so convert HEIC to PNG first (`sips -s format png <input> --out <tmp>.png`, the same
       shape as M3's thumbnail spawn) and feed `avifenc`/`cwebp` that PNG instead of the original file,
       one more `sips` hop ahead of each encode.
    - Either way, this is exactly the kind of gap Phase B (native decode via Apple ImageIO/CoreGraphics
      into Zig, see "Technical approach" above) makes moot outright — decoding to RGBA ourselves removes
      the "can avifenc's own file reader open this container" question entirely. Worth keeping in mind so
      a Phase A patch here isn't over-engineered against a problem Phase B deletes for free.
