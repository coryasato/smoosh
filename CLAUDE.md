# Smoosh — Project Context

## Product
**Smoosh** is a tiny native macOS utility that compresses images into modern web formats (AVIF and/or WebP) with a drag-and-drop interface.

Goal: replace the "upload to TinyPNG / Squoosh / browser tab" workflow with a zero-friction local tool that feels instantaneous.

## Stack
- **Framework**: [Native SDK](https://native-sdk.dev)
  - Declarative markup views (`.native`)
  - **Zig core** (`src/main.zig`) — `Model` struct, `Msg` union, `update` fn, run through `native_sdk.UiApp(Model, Msg)`. **Not TypeScript** — see "Why Zig, not TS-core" below.
  - Pure `Model` / `Msg` / `update` architecture + effects channel (`fx`)
- **Platform**: macOS only (for now)
- **Image handling**:
  - Phase A (MVP): system tools via `fx.spawn` (`avifenc`, `cwebp`)
  - Phase B (later): Zig + Apple ImageIO for decode + statically linked libavif/libwebp for encode

## Why Zig, not TS-core
Originally planned as a TS-core app (`src/core.ts`, "no JS runtime in binary" — see git history). Reversed after spiking file acquisition: native open/save dialogs (`native-sdk.dialog.openFile`/`saveFile`) and file drops are gated behind `RunOptions.bridge`/`.builtin_bridge`, fields that only exist on hand-authored `main.zig`. Verified from source (`@native-sdk/cli@0.8.0`'s `build/app.zig`): `addApp`'s `AppOptions` has no passthrough for them, the CLI-generated TS-core `main.zig` hardcodes them off with no override, and the build hard-panics if a tree carries both `src/core.ts` and `src/main.zig` ("an app has exactly one core"). There is no partial-adoption path — TS-core categorically cannot reach these. Confirmed by building and `native check`-validating a throwaway spike app, not by reading docs alone.

## File acquisition, honestly
**Spiked and confirmed working (2026-08-03).** A throwaway `native init --template zig-core` app proved the full round trip: a markup button dispatches `pick_file` -> `update_fx` calls `fx.hostRequest(.{ .name = "dialog.openFile", .on_result = Effects.hostMsg(.dialog_result) })` -> a `HostCallBinding.request_fn` we bind ourselves (closing over a hand-constructed `*Runtime`) calls `runtime.showOpenDialog(...)` synchronously and answers through `effects.feedHostResult(key, ok, bytes)` -> the result lands back in `Model` as an ordinary `Msg` and renders in the view. Verified with a real macOS `NSOpenPanel` via `native build` + `native automate widget-click` — the picked path (a real file from disk) rendered correctly, zero dispatch errors. Reference implementation, trimmed of scaffold cruft: `docs/spikes/dialog-open-file-spike.zig` (not built as part of the app — read it before writing the real `src/main.zig`'s dialog wiring, adapt field names/window config to Smoosh's real Model).

Two non-obvious things the spike surfaced:
1. `runner.runWithOptions`'s per-platform bring-up (`runMacos` and its helpers in the CLI's `app_runner/root.zig`) is all non-`pub` — a hand-authored `main.zig` can't call into it, only replicate the relevant parts with public APIs (`platform.macos.MacPlatform.createWithOptions` + `native_sdk.Runtime.initAt`). In practice this is fine: only the platform handle and the Runtime are actually needed; `runWithOptions` extras (trace-sink fanout, session recording, window-state persistence) can be skipped or added back deliberately later.
2. The `build_options` module (the `-Dautomation` comptime flag) is wired into the CLI's internal `runner` module only, not into a hand-authored root module — a hand-rolled `main.zig` can't gate `RuntimeOptions.automation` on `build_options.automation` the way the scaffold does. Gate on something else instead (e.g. `builtin.mode == .Debug`) once automation matters for the real app; the spike always builds it since it's a throwaway.

**Resolved in M11:** the app-facing seam is not markup — it's `UiApp.Options.on_drop`, a
`fn(platform.FileDropEvent) ?Msg` field beside `update_fx`/`init_fx` in `App.create`'s options, added
in SDK 0.8.2 and dispatched from `handleRuntimeEvent`'s `.files_dropped` arm. Full spec and the wiring
that landed from it are in PLAN.md's M11 entry.

## Core Principles for this project
1. **Extremely simple UX** — drop zone is the entire product. Minimal chrome.
2. **Predictable Native SDK patterns** — keep `update` pure, all I/O via the effects channel (`fx`), explicit messages.
3. **Beautiful by default** — lean on Native SDK design tokens and built-in components.
4. **Fast feedback** — preview + size delta should appear quickly.
5. **Honest about constraints** — Native SDK has no built-in encoder. We start with system tools, then move to a fully native Zig pipeline.
6. **macOS-first** — optimize for Apple Silicon and ImageIO. No Linux/Windows scope in v0.1.

## Working in this repo

**Read the `native-ui` skill before writing any `.native` markup or `UiApp` Zig**, and the
`native-sdk` skill for scaffolding, `app.zon`, and packaging questions. They are the authoritative
authoring guides; this file only records project-specific decisions.

### Toolchain (verified 2026-08-03)
- `native` CLI **0.8.0**, installed globally (`~/.npm-global/bin/native`) — not a devDependency.
- Zig **0.16.0** (`/usr/local/bin/zig-aarch64-macos-0.16.0/zig`).
- `node_modules/` + `package.json` + `tsconfig.json` are an **editor-only** surface for the
  now-abandoned TS-core path. Builds never read them. Do not run installs to "fix" a build.

### Commands
```sh
native dev      # Debug build + run, markup hot reload
native build    # ReleaseFast binary into zig-out/bin/
native check    # validate markup + app.zon
native test     # app test suite
native package --target macos [--signing ...]
native automate snapshot                       # widget ids (bare numbers, printed as #id)
native automate widget-click <view-label> <id> # drive the running app
native automate screenshot <view-label>        # gpu_surface views only
```
`native dev --core` is TS-core only and does not apply here.
Widget clicks take a **numeric id from `snapshot`**, not a label — snapshot first.

### Repo layout
- `src/main.zig` — the app. Hand-authored root: builds its own platform + Runtime.
- `src/app.native` — markup view.
- `src/tests.zig` — unit tests, pulled in by a `test {}` block at the bottom of `main.zig` (the
  scaffold's convention). Run with `native test`. See PLAN.md's "Testing strategy" for the two
  tiers and what belongs in each.
- `README.md` — rewritten for Smoosh; keep the Status section honest as milestones land.
- `docs/spikes/` — reference implementations, not built as part of the app.

(`src/core.ts`, `package.json`, `tsconfig.json`, `bun.lock`, and `node_modules/` were the abandoned
TS-core editor surface and were deleted in M1. There is no npm/bun surface in this tree at all.)

### Gotcha: window config exists in THREE places
For a hand-authored root, window geometry is stated three times and all three must move together
(confirmed the hard way in M1 — see the block comment in `src/main.zig`):

1. **`platform.AppInfo.main_window.default_frame`** — the host creates the real NSWindow from this,
   *before* the scene loads, and it defaults to **720x480**. The size passed to
   `MacPlatform.createWithOptions` only sizes the *surface*, not the window. Omit `main_window` and
   you get a 720x480 window no matter what the scene or `app.zon` says — this was the actual M1
   symptom. The CLI runner derives these `WindowOptions` from `app.zon` at comptime; a hand-authored
   root has no such path, so it must state them in Zig.
2. **`native_sdk.ShellConfig`** passed to `App.create(.{ .scene = ... })` — what the runtime lays
   views out against (`ShellWindow` label/title/size, the view's `gpu_*` fields).
3. **`app.zon`'s `.shell.windows`** — identity, `native check`, and packaging.

## Native SDK surfaces this app uses
- Native dialogs (`runtime.showOpenDialog`/`showSaveDialog`, wired through a custom `HostCallBinding` — see "File acquisition, honestly")
- `fx.loadImage` + `<image>` for previews — **of a `sips` thumbnail, never the source image.** Registered
  images cap at 1 MiB of *decoded* RGBA (512x512) and `fx.loadImage` refuses encoded sources past
  1.25 MiB, so no real photo can be registered directly. See PLAN.md's M3 entry.
- A second host command we bind ourselves, `file.stat` — `update` can never hold an `Io`, the bridge can.
  Reuse it for output sizes rather than adding a stat spawn.
- `fx.spawn` (for system tools in Phase A)
- `fx.readFile` / `fx.writeFile`
- Hot-reload on `.native` files (Debug builds, via `.markup.watch_path`)
- `on_drop` (`UiApp.Options`, SDK 0.8.2+) for real window-wide file drops — see PLAN.md's M11 entry.
- Manifest: `capabilities = .{ "native_views", "gpu_surfaces", "file_drops" }` — markup renders onto a
  gpu_surface, so `gpu_surfaces` stays; `file_drops` was added in M11 once `on_drop` landed.
  Permissions are just `command` + `view`; the dialog spike needed nothing more. (An earlier draft
  of this file claimed *no evidence* `dialog`/`file_drops` capabilities exist — wrong. Both are real
  `app_manifest.CapabilityKind` strings; M11 confirmed `file_drops` by reading the SDK source. Still
  no `dialog` capability added here, since nothing in the runtime reads it and the open-dialog seam
  keeps working without it — see PLAN.md M11 if that ever needs re-litigating.)

## Conventions
- Zig core (`src/main.zig`) — no TypeScript in this tree.
- Messages are narrow and explicit.
- Keep `update`/`update_fx` pure and small. Heavy work lives in effects (`fx`).
- `Model` is a plain struct heap-allocated by `UiApp.create`: fixed-size buffers, not slices or
  `ArrayList`. Derive display strings via `pub fn` methods rather than storing them.
- `error` is a Zig keyword — enum states use `failed`, not `error`.
- UI should work well at small window sizes (the app is meant to live in a corner of the desktop).
- Verify against the *running* app via `native automate`. A clean `native build` proves nothing
  about behavior.

## Current status
**M1-M12 done — v0.1 ships, with real file drops and working HEIC encode on top.** M1: skeleton launches to a blank window. M2: real `Model`/`Msg` (no-op `update`) and
an ugly-but-complete `src/app.native` every later milestone can drive via `native automate`;
`test-images/` fixtures created. M2a: `src/tests.zig` — the tier-1 harness (markup builds, dispatch,
chip payload coercion, model accessors) later milestones extend. M3: the real pick chain —
`pick_file` -> `dialog.openFile` -> `file.stat` -> `sips` thumbnail -> `fx.loadImage` -> `.ready`,
plus `reset`; `src/tests.zig` gained a fake-executor `Harness`. M4: the 100 MB / 50 MP input limits,
enforced in the same chain — `stat_result` now short-circuits on byte size, and a new
`dimensions_result` hop (a separate `sips -g pixelWidth -g pixelHeight -1` query — combining `-g`
with the thumbnail's `-s`/`-Z` in one `sips` call errors out, confirmed by running it) short-circuits
on megapixels before the thumbnail spawn. M5: launch-time `avifenc`/`cwebp` detection via
`UiApp.Options.init_fx` (the SDK's boot-command hook, runs once on the installing frame before the
first paint) spawning `/usr/bin/which avifenc` / `/usr/bin/which cwebp`; missing either surfaces the
named `brew install libavif`/`brew install webp` message through the existing `.failed` status path.
Also pinned the M7 encoder argv (`avifenc -q 58 --speed 6`, `cwebp -q 80`) by running both against
real fixtures — no changes needed. M6: `set_format` now moves `Model.format` (`update`'s only new
line); the chip payload coercion and `selected` binding were already proven at the markup level in
M2a. `native build`/`check`/`test` all clean (39/39 tests); M1-M3 verified live against a real
`NSOpenPanel`, M4 verified via the fake-executor tests only (a live-automation attempt misfired —
see PLAN.md's M4 entry for the full writeup and a flag for whoever next drives `NSOpenPanel`
automation), M5 verified live via `native dev` with a `PATH` excluding the encoders, M6 verified
live via `native automate widget-click` on all three format chips (see PLAN.md's M5/M6 entries). M7: the
encode pipeline — `smoosh` -> one `fx.spawn` per requested format -> `encode_result` -> a `file.stat` per
output -> `.done`/`.failed`, with per-format result lines and savings. **Its headline decision, recorded in
full in PLAN.md's M7 entry: partial failure is partial SUCCESS** — in "Both" mode the two encodes are
independent, one landing while the other fails is `.done` with the failure named in the status bar, and
only an all-failed run is `.failed`. The encoders write their own output files, so anything else would
contradict a file already on disk. `native build`/`check`/`test` all clean (62/62 tests, `check` now at
**zero** warnings after `Model.view_unbound` landed); M7 verified live against real fixtures for AVIF,
Both, redo, and the negative-savings fixture.
**Do not automate the open panel — or, per M8, ANY native file dialog.** The app runs as a bare executable
from `.zig-cache` and System Events cannot bring it frontmost (`set frontmost` silently no-ops), so global
keystrokes land on whatever IS frontmost — this is what typed a path into a live Claude Code session
during M4. Verified again in M7 (open panel) and M8 (save panel) and closed there: the seam is
unreachable until the app is a real `.app` bundle (M10). Have the user drive every dialog by hand;
everything else (button presses, chip selection, status/result assertions) drives fine with `native
automate widget-click`.
M8: "Save As…" — `save_as` -> `showSaveDialog` -> copy the chosen output(s) to the user's location,
without touching M7's auto-saved originals. **Its headline decision: "Both" mode runs two save rounds
SEQUENTIALLY** (one save-dialog-then-copy per landed format), not a folder picker — `showSaveDialog` only
ever returns one path, and a folder picker is a real, different UI PLAN never specified, so this was
asked rather than assumed. A cancelled round is silent and the other format is still offered. The copy
itself goes through a THIRD hand-bound host command, `file.copy` — not `fx.writeFile`, whose 1 MiB cap
(`max_effect_file_bytes`) a real encoder output can exceed, the same bound M3 already hit with the source
image. `native build`/`check`/`test` all clean (78/78 tests, `check` still at zero warnings); M8 verified
live — a "Both" run's two save rounds produced copies **MD5-identical** to a fresh by-hand encoder run,
and cancelling a single-format save left the status bar unchanged with `dispatch_errors=0`.
M9: the real view replaces M2's scaffold — a header, one middle band that swaps between a pressable
drop zone and a file card (preview left, name/size/results right), the format chips, the actions row
and the status line; the chrome around the band never moves, so widget ids survive the swap. The
window is now **540x400 with a declared minimum**, which closes M3's deferred `zero_canvas_layout`
overflow. Three decisions worth carrying: **the drop zone says "click", not "drop"** (drops are M11's
open question and do not work — the UI must not promise them); **error messages no longer name the
file** (`<status-bar>` is one line that takes no `wrap` and elides at ~65 chars, and the file card
names the file in every failable state — so the message only explains); and **the preview is clamped
to the source's real dimensions inside a fixed 168x168 frame**, since `sips -Z` upscales small
sources. `native build`/`check`/`test` all clean (85/85 tests, zero `check` warnings); every new
assertion mutation-checked. Watch for the `success_text` trap: it is the on-success-fill foreground
and renders nearly invisible as page text — `success` is the token for tinted text, and only a
screenshot catches it (snapshots report names, not contrast).
M10: `native package --target macos --signing adhoc` (ad-hoc — no paid Apple Developer identity exists
on this machine, and it's a single-machine local tool; full rationale in PLAN.md). **A real bug only
`/Applications` could surface**: `fx.spawn` children (M5's `which` check, M7's real encoders) inherit
`Runtime.Options.environ`, which was wired to the raw process environment — fine from a Terminal
(`native dev`/`native build`), but a Finder/Dock-launched packaged app gets launchd's minimal PATH with
no `/opt/homebrew/bin`, so the "install avifenc/cwebp" error fired with both genuinely installed. Fixed
once in `src/main.zig`'s `resolveSpawnEnviron`, which widens the bound environ's PATH before
`Runtime.initAt` so every spawn downstream inherits the fix. **The app icon (`assets/icon.png`) is a
placeholder**, built by hand-writing an SVG and rasterizing it with ImageMagick's MSVG delegate (the only
renderer on this machine) — MSVG only reliably draws flat fills, not gradients or stroked lines, so it
is visually rough. Full writeup, including exactly how to redo it properly, in PLAN.md's M10 entry.
M11: real file drops via `UiApp.Options.on_drop` (SDK 0.8.2+, added after the 0.8.0 -> 0.8.4 upgrade) —
a dropped path re-enters the exact same load chain a picked one does through a shared `beginLoad`
helper. `app.zon` gained the real `"file_drops"` capability. `native build`/`check`/`test` all clean
(93/93 tests, zero warnings); live, a hand-dragged `photo.heic` landed in `.ready` correctly (drops
cannot be automated at all, unlike dialogs — a different constraint, same "ask the user" answer), and a
hand-dragged `large.jpg` smooshed end to end to the exact numbers M7's own check recorded. Full writeup
in PLAN.md's M11 entry. **Known limitation found along the way, fixed in M12:** HEIC input could not be
encoded (`avifenc`/`cwebp` reject it as an input format outright, though `sips` decodes it fine for the
preview) — M12 stages a `sips`-to-PNG conversion ahead of the encode when the source is HEIC/HEIF. Full
writeup in PLAN.md's M12 entry.
**`PLAN.md` is the source of truth** for milestones,
locked decisions, per-milestone model/session guidance, and open questions. Do not restate its
contents here — link to it.
