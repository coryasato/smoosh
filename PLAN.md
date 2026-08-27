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
warnings, `native build` clean. No known limitations open. Next round: UI polishing (not yet
planned — see "Next up" below).

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

**Phase B — Native (future)**
- Move encoding into Zig.
- Decode via Apple's ImageIO / CoreGraphics (zero extra code, excellent HEIC/JPEG/PNG support) —
  this would also make the HEIC-staging workaround above moot outright.
- Statically link libavif + libwebp into the binary via `build.zig`.
- Full control, single binary, maximum performance on Apple Silicon.
- Promote this path once solid; keep system-tool path only as temporary fallback if needed.

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
- Each landed result row carries its own save icon, an optional secondary action to copy that one file to a different location; it does not replace auto-save.

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

## Known limitations
None currently open.

## Next up
The UI polishing round has not been planned yet. Add its milestones here when that starts.
