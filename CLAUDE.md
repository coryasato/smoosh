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
Zig apps *can* reach `runtime.showOpenDialog`/`showSaveDialog` (real methods on `Runtime`, confirmed in `src/runtime/system_services.zig`) and can set `.bridge`/`.builtin_bridge` on `RunOptions` directly. What's still unconfirmed (next concrete task, not a new unknown): `update`/`update_fx` receive `*Effects` (`fx`), not `*Runtime` — there's no documented `fx.showOpenDialog`. The seam to actually call the dialog synchronously and land the result back in `Model` is `Effects.bindHostCalls` (a `HostCallBinding` with your own `request_fn` closing over a `*Runtime`, answering through `effects.feedHostResult(key, ok, bytes)`), paired with a TEA `Cmd`-style request from `update` (e.g. `fx.hostRequest(.{ .name = "dialog.openFile", ... })`). This requires owning `Runtime` construction yourself (`native_sdk.Runtime.init(...)` + `runtime.run(app)`, per the core skill's "Runtime setup" reference) rather than the `runner.runWithOptions` convenience wrapper the CLI scaffolds by default — a documented pattern, just more manual wiring than a scaffolded app normally needs.

**Before building the drop-zone UI**: get one `pick_file` Msg round-tripping through `runtime.showOpenDialog` back into `Model` in a throwaway spike, to nail the exact `HostCallBinding` wiring. Only then design the real UI around it.

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