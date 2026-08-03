# Smoosh — PLAN.md

> Living plan. Update this file as decisions are made.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern web formats (AVIF and/or WebP) without leaving your desktop.

## Success criteria for v0.1 (MVP)
- [ ] App launches to a clean drop-zone UI
- [ ] User can pick an image via "Choose Image…" (native open dialog via `runtime.showOpenDialog`, wired through a custom `HostCallBinding` — pattern proven, see "File acquisition, honestly" in CLAUDE.md); drag-and-drop is stretch, not required for v0.1
- [ ] Image appears as preview with original size
- [ ] User can choose output: AVIF (default), WebP, or Both
- [ ] "Smoosh" produces the selected format(s) via system tools and auto-saves next to the source file
- [ ] Before/after file size + savings % are shown
- [ ] User can optionally re-save output to a different location via "Save As…"
- [ ] Works on macOS only
- [ ] Reasonable input size limits with clear feedback
- [ ] Ships as a packaged `.app` that launches on a machine that never ran `native build`

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

*Encoder invocations (starting point — confirm flags against the installed versions during M5, libavif's quality flags changed across releases):*
```
avifenc -q 58 --speed 6 <input> <output.avif>
cwebp  -q 80 <input> -o <output.webp>
```
Pin the resolved argv here once verified so M7 has no open questions.

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

**Gotcha — the window config exists twice.** A hand-authored `main.zig` builds its own
`native_sdk.ShellConfig` in Zig (window label/title/size, the view's gpu_* fields) and passes it as
`App.create(.{ .scene = ... })`; that is what the runtime actually renders. `app.zon`'s
`.shell.windows` still drives identity, `native check`, and packaging. Both must be edited together
or they will silently disagree.

### Verification strategy
Every milestone below ends with a check against the *running* app, not a compile check.
- `native build` + `native check` are necessary but never sufficient.
- `native automate widget-click` drives the real UI; this is why markup lands in M2, not last.
- Test fixtures (create once, in M2, under `test-images/`, gitignored): a small PNG, a large JPEG,
  a HEIC from an iPhone, a WebP, an already-tiny PNG (to see a *negative* savings case), a
  non-image file renamed `.jpg`, and one file over the size limit.

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
| M3 | File acquisition + preview | Opus | fresh |
| M4 | Input size limits | Sonnet | share M3 |
| M5 | Encoder detection at launch | Sonnet | fresh |
| M6 | Format selection | Sonnet | share M5 |
| M7 | Smoosh encode pipeline | Opus | fresh |
| M8 | Save As | Sonnet | share M7 |
| M9 | UI/UX pass | Opus | fresh |
| M10 | Packaging + v0.1 release | Sonnet | fresh |
| M11 | Stretch: file-drop hook | Opus | fresh |

---

**M1 — Zig-core skeleton + app.zon cleanup.** *(Opus, fresh session)*
Delete `src/core.ts`, `package.json`, and `tsconfig.json` (all three are the abandoned TS-core
editor surface; the build reads none of them). Add `src/main.zig`. Apply every item under
"app.zon changes required" above.
Adapt `docs/spikes/dialog-open-file-spike.zig` for app/Runtime bring-up (`MacPlatform.createWithOptions`
+ `Runtime.initAt`, per CLAUDE.md's "File acquisition, honestly") — no dialog wiring yet, just an app
that launches to an empty window. Also decide here how automation gets gated, since `build_options`
is unreachable from a hand-authored root (CLAUDE.md note 2) — `builtin.mode == .Debug` is the default answer.
*Opus because:* this is the one milestone with no reference pattern in-tree for the app.zon/manifest
side, and a wrong runtime bring-up blocks everything downstream.
*Verify:* `native build` succeeds, app launches to a blank window, `native check` passes.

**M2 — Model/Msg + minimal markup shell.** *(Sonnet, share M1's session)*
Add the real `Model` and `Msg` (per the sketches above) with a no-op `update`. Add a deliberately
ugly `src/app.native` containing every control the later milestones need to click — "Choose Image…",
the three format options, "Smoosh", "Save As…", and a status/error text line. No styling, no layout
work; this exists so M3-M8 have something `native automate` can drive. Create the `test-images/`
fixtures from "Verification strategy".
*Shares M1's session because:* it is the same file, the same build loop, and directly consumes M1's decisions.
*Verify:* builds clean, `native check` passes, `native automate` can see and click every control.

**M3 — File acquisition + preview.** *(Opus, fresh session)* [✓ "pick an image via Choose Image…", ✓ "preview with original size"]
Wire `pick_file` -> `HostCallBinding` -> `showOpenDialog` (spike pattern), landing the real path into
`Model.path_buffer` (not a display string). Follow with `fx.loadImage`/`fx.registerImageBytes` for the
preview and populate `original_size`. Wire `reset` while here — it is trivial now and awkward to retrofit.
*Opus because:* transplanting the host-call binding means holding the whole spike (237 lines of
unfamiliar API) in context and adapting it to a different Model; the `Effects`/`feedHostResult`
seam is the least forgiving code in the project.
*Fresh session because:* the spike file is the context that matters here, and M1/M2's scaffold churn is noise.
*Verify:* `native automate widget-click` on "Choose Image…" against a real fixture, confirm `Model`
holds the real path + size and the preview renders.

**M4 — Input size limits.** *(Sonnet, share M3's session)* [✓ "reasonable input size limits with clear feedback"]
Enforce the 80-100MB / 40-50 megapixel soft limit at file-load time, in the `image_loaded` path
M3 just built, surfacing the matching error state.
*Moved up from the old M9:* this is a branch inside M3's code path, not a separate feature. Writing
it five milestones later means re-loading M3's context to add three lines.
*Verify:* load the oversized fixture, confirm the friendly limit message renders and no preview loads.

**M5 — Encoder detection at launch.** *(Sonnet, fresh session)* [✓ error-state: encoder binary missing]
`fx.spawn` a presence check for `avifenc`/`cwebp` on startup, land results as `encoder_check_result`,
surface the "Error states" messaging if either is missing. While here, run both encoders by hand on a
fixture and **pin the confirmed argv back into "Encoder invocations" above** — M7 depends on it.
*Fresh session because:* first `fx.spawn` use; nothing from M3/M4 transfers.
*Verify:* run with a `PATH` that excludes the binary, confirm the correct `brew install` message
renders; restore `PATH` and confirm no error state.

**M6 — Format selection.** *(Sonnet, share M5's session)* [✓ "choose output: AVIF / WebP / Both"]
Wire `set_format` from the three format controls to `Model.format`.
*Verify:* click each option, confirm `Model.format` updates and the correct one renders selected.

**M7 — Smoosh encode pipeline.** *(Opus, fresh session)* [✓ "Smoosh produces selected format(s) and auto-saves", ✓ "before/after size + savings % shown"]
Wire `smoosh` -> `fx.spawn` the encoder invocation(s) per `Model.format`, auto-save next to source
(silent overwrite per "Output handling"), land results as `encode_result`, compute before/after size
and `savings_percent`, drive `Status` through `compressing` -> `done`/`failed`. Cover the "encode failed"
and "write failed" error states.
*Opus because:* this is the highest-complexity milestone — "Both" means two concurrent spawns whose
results arrive independently and must be joined before `done`, on top of a purity constraint that
keeps all of it in `update_fx`. Partial-failure handling (AVIF succeeds, WebP fails) is a real design
decision, not a wiring task; make it explicitly and record the answer here.
*Fresh session because:* it needs the encode design loaded, not six milestones of UI wiring.
*Verify:* run against real fixtures for AVIF, WebP, and Both; confirm output files exist next to source
with correct sizes and accurate savings %. Include the already-tiny PNG fixture — confirm negative
savings displays sanely rather than as a broken percentage.

**M8 — Save As.** *(Sonnet, share M7's session)* [✓ "optionally re-save output to a different location"]
Wire `save_as` -> `showSaveDialog` -> copy the already-produced output(s) to the chosen location.
Does not replace auto-save from M7.
*Sonnet because:* it is M3's dialog pattern and M7's write path, both already in the session's context.
*Verify:* after a successful Smoosh, trigger Save As, confirm the file lands at the chosen path with matching bytes.

**M9 — UI/UX pass.** *(Opus, fresh session)* [✓ "launches to a clean drop-zone UI", ✓ works at small window sizes]
Replace M2's ugly shell with the real markup per the "UI sketch", against the now-complete set of
working messages. Lean on Native SDK design tokens (Core Principle 3). Walk every state:
empty -> loading -> ready -> compressing -> done / failed.
*Opus because:* "Beautiful by default" is a stated core principle and taste-sensitive work is where
the model difference actually shows. Downgrade to Sonnet if the markup layer turns out to be more
mechanical than expected.
*Fresh session because:* this is a design task; six milestones of encoder debugging is the wrong context.
*Verify:* resize the window small, run the full flow via `native automate`, confirm no layout breakage
and that every state renders.

**M10 — Packaging + v0.1 release.** *(Sonnet, fresh session)*
`native package` the app, real icon in place of the scaffold's, confirm it launches from `/Applications`
on a machine that never ran `native build`. Decide and record whether v0.1 ships signed/notarized or
as an unsigned local build — this determines whether anyone but you can open it.
*New milestone:* the old plan ended at feature-complete with no path to a runnable artifact.
*Verify:* copy the packaged `.app` to a clean location, launch, run one full smoosh.

**M11 — Stretch: file-drop hook.** *(Opus, fresh session)*
Only after M1-M10 are solid. Investigate whether `.native` markup exposes an app-facing `on-file-drop`
seam (CLAUDE.md's "still open" note). Not required for v0.1 — the open dialog already satisfies file
acquisition. If the seam does not exist, record that finding in CLAUDE.md and close the question.
*Opus because:* it is an open-ended source-reading investigation against undocumented internals,
the same shape as the spike work that produced the Zig-core decision.

## Open decisions
- Partial failure in "Both" mode: report success-with-warning, or fail the whole operation? (decide in M7)
- Signed/notarized vs unsigned for v0.1 (decide in M10)
- Whether `native check` is meaningful for a zig-core tree (its help text describes core validation
  as "src/core.ts through the subset checker"; markup + app.zon validation should still apply — confirm in M1)
