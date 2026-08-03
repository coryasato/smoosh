# Smoosh — PLAN.md

> Living plan. Update this file as decisions are made.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern web formats (AVIF and/or WebP) without leaving your desktop.

## Success criteria for v0.1 (MVP)
- [ ] App launches to a clean drop-zone UI
- [ ] User can drop an image (or use "Choose Image…" button)
- [ ] Image appears as preview with original size
- [ ] User can choose output: AVIF (default), WebP, or Both
- [ ] "Smoosh" produces the selected format(s) via system tools
- [ ] Before/after file size + savings % are shown
- [ ] User can save the result(s) (or auto-save next to original)
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
- Use `Cmd.spawn` against system tools already available via Homebrew or similar.
- Preferred tools:
  - `avifenc` (from libavif) for AVIF
  - `cwebp` (from libwebp) for WebP
- Detect presence at runtime and give clear error messages if missing.
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
- Primary: drag-and-drop (`file_drops` capability)
- Secondary: native open dialog (`native-sdk.dialog.openFile`)
- Accept common raster formats that macOS ImageIO / platform codecs can decode (JPEG, PNG, WebP, HEIC, etc.)

### Input size limits
- Soft limit around **80–100 MB** or ~40–50 megapixels (whichever comes first).
- Rationale: local tool should be more permissive than typical web upload limits, but we still need to protect against pathological files that would exhaust memory when decoded to RGBA.
- Clear, friendly error when exceeded.
- Exact numbers can be tuned once we measure real memory behavior.

### UI sketch (app.native)
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
│  [ Smoosh ]  [ Save… ]                       │
│                                              │
└──────────────────────────────────────────────┘

States: empty → loading → ready → compressing → done / error

### Core model sketch (high level)
```ts
interface Model {
  // file
  path: Uint8Array | null;
  originalSize: number;
  // preview
  imageId: number;          // ImageId from Cmd.imageLoad
  // result
  resultPaths: { avif?: Uint8Array; webp?: Uint8Array };
  resultSizes: { avif?: number; webp?: number };
  savingsPercent: number;
  // options
  format: "avif" | "webp" | "both";
  // ui
  status: "idle" | "loading" | "ready" | "compressing" | "done" | "error";
  errorMessage: Uint8Array | null;
}