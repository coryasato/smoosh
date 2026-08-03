# Smoosh — PLAN.md

> Living plan. Update this file as decisions are made.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern web formats (AVIF and/or WebP) without leaving your desktop.

## Success criteria for v0.1 (MVP)
- [ ] App launches to a clean drop-zone UI
- [ ] User can pick an image via "Choose Image…" (native open dialog via `runtime.showOpenDialog`, wired through a custom `HostCallBinding` — spike this first, see "File acquisition, honestly" in CLAUDE.md); drag-and-drop is stretch, not required for v0.1
- [ ] Image appears as preview with original size
- [ ] User can choose output: AVIF (default), WebP, or Both
- [ ] "Smoosh" produces the selected format(s) via system tools and auto-saves next to the source file
- [ ] Before/after file size + savings % are shown
- [ ] User can optionally re-save output to a different location via "Save As…"
- [ ] Works on macOS only
- [ ] Reasonable input size limits with clear feedback

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
- Primary: native open dialog via `runtime.showOpenDialog`, called from a `HostCallBinding.request_fn` we bind ourselves in `src/main.zig` (see CLAUDE.md's "File acquisition, honestly"). Requires constructing `Runtime` by hand (`native_sdk.Runtime.init` + `runtime.run(app)`) instead of the CLI's `runner.runWithOptions` convenience wrapper, so `main.zig` can hold a `*Runtime` to close over. **Spiked and confirmed working (2026-08-03)** end-to-end against a real macOS open panel — reference implementation at `docs/spikes/dialog-open-file-spike.zig`, ready to transplant.
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
const Status = enum { idle, loading, ready, compressing, done, error };

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
};
```

## Next up (start of next session)

The file-acquisition unknown is resolved — nothing left to spike before writing the real app. Milestones are ordered by dependency; each ends with a `native build` + `native automate widget-click` (or equivalent) check against the *running* app, not just a compile check. Bracketed refs are the MVP success-criteria checkboxes (lines 9-17) each milestone satisfies.

**M1 — Zig-core skeleton.**
Delete `src/core.ts`, add `src/main.zig`, update `app.zon`'s `description`/window title away from the "counter" scaffold defaults. Adapt `docs/spikes/dialog-open-file-spike.zig` for app/Runtime bring-up (hand-rolled `Runtime.initAt` + `MacPlatform.createWithOptions`, per CLAUDE.md's "File acquisition, honestly") — no dialog wiring yet, just an app that launches to an empty window.
*Verify:* `native build` succeeds, app launches to a blank window.

**M2 — Model/Msg skeleton.**
Add the real `Model` (per "Core model sketch") and `Msg` (per "Msg sketch" above) to `main.zig`, with a no-op `update`. No UI yet.
*Verify:* builds clean, `native check` passes.

**M3 — File acquisition.** [✓ "pick an image via Choose Image…", ✓ "preview with original size"]
Wire `pick_file` -> `HostCallBinding` -> `showOpenDialog` (spike pattern), landing the real path into `Model.path_buffer` (not a display string). Follow with `fx.loadImage`/`fx.registerImageBytes` for the preview and populate `original_size`.
*Verify:* `native automate widget-click` on "Choose Image…" against a real file, confirm `Model` holds the real path + size, preview image id is set.

**M4 — Encoder detection at launch.** [✓ error-state: encoder binary missing]
`fx.spawn` a presence check for `avifenc`/`cwebp` (e.g. `which avifenc`) on startup, land results as `encoder_check_result`, surface the "Error states" messaging if either is missing.
*Verify:* temporarily rename/hide one binary, confirm the correct `brew install` message renders; restore and confirm no error state.

**M5 — Format selection.** [✓ "choose output: AVIF / WebP / Both"]
Wire `set_format` from the three format controls to `Model.format`.
*Verify:* click each option, confirm `Model.format` updates and the correct one renders selected.

**M6 — Smoosh encode pipeline.** [✓ "Smoosh produces selected format(s) and auto-saves", ✓ "before/after size + savings % shown"]
Wire `smoosh` -> `fx.spawn` the `avifenc`/`cwebp` invocation(s) per `Model.format`, auto-save next to source (silent overwrite per "Output handling"), land results as `encode_result`, compute before/after size + `savings_percent`, update `Status` through `compressing` -> `done`/`error`. Cover the "Encode failed" and "write failed" error states from this file.
*Verify:* run against a real image for AVIF, WebP, and Both; confirm output files exist next to source with correct sizes and the UI shows accurate savings %.

**M7 — Save As.** [✓ "optionally re-save output to a different location"]
Wire `save_as` -> `showSaveDialog` -> copy/write the already-produced output(s) to the chosen location. Does not replace auto-save from M6.
*Verify:* after a successful Smoosh, trigger Save As, confirm the file lands at the chosen path with matching bytes.

**M8 — Drop-zone UI assembly** (`src/app.native`). [✓ "launches to a clean drop-zone UI", ✓ works at small window sizes]
Build the real markup per the "UI sketch" above, binding every control to the `Msg`s wired in M3-M7. Confirm layout holds up at a small window size (per CLAUDE.md's "UI should work well at small window sizes").
*Verify:* resize the window small, run the full empty -> loading -> ready -> compressing -> done flow via `native automate`, confirm no layout breakage.

**M9 — Input size limits.** [✓ "reasonable input size limits with clear feedback"]
Enforce the 80-100MB / 40-50 megapixel soft limit from "Input size limits" at file-load time (M3's `image_loaded` path), surfacing the matching error state.
*Verify:* attempt to load an oversized test file, confirm the friendly limit message renders and no encode is attempted.

**M10 — Stretch: file-drop hook.**
Only after M1-M9 are solid and verified. Investigate whether `.native` markup exposes an app-facing `on-file-drop` seam (see CLAUDE.md's "still open" note). Not required for v0.1 — the open dialog already satisfies file acquisition.