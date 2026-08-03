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

## Next up (start of next session)

The file-acquisition unknown is resolved — nothing left to spike before writing the real app. Next session should go straight to implementation:

1. **Convert the project from TS-core to Zig-core.** Currently `src/core.ts` + `src/app.native` are still the original TS-core scaffold (app.zon has the placeholder "counter" window/description too). Per CLAUDE.md's "Why Zig, not TS-core," delete `src/core.ts`, add `src/main.zig`, and update `app.zon`'s `description`/window title away from the scaffold defaults. `docs/spikes/dialog-open-file-spike.zig` is the starting point for `main.zig`'s app/Runtime/dialog wiring — adapt it rather than rewriting from scratch.
2. **Build out the real `Model`/`Msg`** per the "Core model sketch" above (file path, preview image id, per-format output paths/sizes, `Format`, `Status`, error message buffer).
3. **Wire "Choose Image…"** using the spike's `pick_file` -> `HostBridge` -> `showOpenDialog` pattern, but land the result as a real path into `Model` (not just a display string) and follow up with an `fx.loadImage`/`fx.registerImageBytes` call for the preview.
4. **Encoder detection at launch**: `fx.spawn` a presence check for `avifenc`/`cwebp` (e.g. `which avifenc`), surface the "Error states" messaging from this file if either is missing.
5. **Wire "Smoosh"**: `fx.spawn` the actual `avifenc`/`cwebp` invocation(s) per the selected `Format`, auto-save next to source, compute before/after size + savings %, update `Status`.
6. **Build the drop-zone UI** (`src/app.native`) per the "UI sketch" above, once 1–3 are working — the CLAUDE.md guidance is explicit that UI comes after the file-acquisition seam is proven, and it now is.
7. Stretch, only after the above: investigate whether `.native` markup exposes an app-facing file-drop hook (see CLAUDE.md's "still open" note) — not required for v0.1 since the open dialog already works.