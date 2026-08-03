# Smoosh — Project Context

## Product
**Smoosh** is a tiny native macOS utility that compresses images into modern web formats (AVIF and/or WebP) with a drag-and-drop interface.

Goal: replace the "upload to TinyPNG / Squoosh / browser tab" workflow with a zero-friction local tool that feels instantaneous.

## Stack
- **Framework**: Native SDK[](https://native-sdk.dev)
  - Declarative markup views (`.native`)
  - TypeScript core (`src/core.ts`) compiled to native (no JS runtime in binary)
  - Pure `Model` / `Msg` / `update` architecture + `Cmd` effects
- **Platform**: macOS only (for now)
- **Image handling**:
  - Phase A (MVP): system tools via `Cmd.spawn` (`avifenc`, `cwebp`)
  - Phase B (later): Zig + Apple ImageIO for decode + statically linked libavif/libwebp for encode

## Core Principles for this project
1. **Extremely simple UX** — drop zone is the entire product. Minimal chrome.
2. **Predictable Native SDK patterns** — keep the core pure, all I/O via `Cmd`, explicit messages.
3. **Beautiful by default** — lean on Native SDK design tokens and built-in components.
4. **Fast feedback** — preview + size delta should appear quickly.
5. **Honest about constraints** — Native SDK has no built-in encoder. We start with system tools, then move to a fully native Zig pipeline.
6. **macOS-first** — optimize for Apple Silicon and ImageIO. No Linux/Windows scope in v0.1.

## Key Native SDK capabilities we will use
- `file_drops` capability
- Native dialogs (`native-sdk.dialog.openFile` / `saveFile`)
- `Cmd.imageLoad` + `<image>` for previews
- `Cmd.spawn` (for system tools in Phase A)
- `Cmd.readFile` / `Cmd.writeFile`
- Hot-reload on `.native` files

## Conventions
- Prefer TypeScript core for velocity in Phase A. Zig enters for the image pipeline in Phase B.
- All dynamic text is `Uint8Array` (bytes). Use `asciiBytes` for literals.
- Messages are narrow and explicit.
- Keep `update` pure and small. Heavy work lives in effects.
- UI should work well at small window sizes (the app is meant to live in a corner of the desktop).

## Current status
See `PLAN.md`. Decisions locked:
- System tools for MVP encoding
- macOS only
- Format choice: AVIF (default) / WebP / Both
- Reasonable input size limits