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

Still open, now that the seam is proven: whether a drop-zone `on-file-drop` markup hook exists as a documented app-facing seam (see "Stretch" in PLAN.md's File acquisition section) — the open-dialog path above is sufficient for v0.1 either way, so this isn't a blocker.

## Core Principles for this project
1. **Extremely simple UX** — drop zone is the entire product. Minimal chrome.
2. **Predictable Native SDK patterns** — keep `update` pure, all I/O via the effects channel (`fx`), explicit messages.
3. **Beautiful by default** — lean on Native SDK design tokens and built-in components.
4. **Fast feedback** — preview + size delta should appear quickly.
5. **Honest about constraints** — Native SDK has no built-in encoder. We start with system tools, then move to a fully native Zig pipeline.
6. **macOS-first** — optimize for Apple Silicon and ImageIO. No Linux/Windows scope in v0.1.

## Key Native SDK capabilities we will use
- `file_drops` capability, `dialog` capability
- Native dialogs (`runtime.showOpenDialog`/`showSaveDialog`, wired through a custom `HostCallBinding` — see "File acquisition, honestly")
- `fx.loadImage` / `fx.registerImageBytes` + `<image>` for previews
- `fx.spawn` (for system tools in Phase A)
- `fx.readFile` / `fx.writeFile`
- Hot-reload on `.native` files (Debug builds, via `.markup.watch_path`)

## Conventions
- Zig core (`src/main.zig`) — no TypeScript in this tree.
- Messages are narrow and explicit.
- Keep `update`/`update_fx` pure and small. Heavy work lives in effects (`fx`).
- UI should work well at small window sizes (the app is meant to live in a corner of the desktop).

## Current status
See `PLAN.md`. Decisions locked:
- System tools for MVP encoding
- macOS only
- Format choice: AVIF (default) / WebP / Both
- Reasonable input size limits
- Auto-save output next to source; overwrite existing output silently
- Missing encoder binaries: detect at launch, show install instructions (no auto-install)