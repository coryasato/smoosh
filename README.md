# Smoosh

A tiny native macOS app that compresses images into modern web formats — drop an
image in, get AVIF and/or WebP back, next to the original. No upload, no browser
tab, no account.

It exists to replace the "open TinyPNG / Squoosh in a tab" workflow with
something local and instant.

## Status

**v0.3 — fully native, zero dependencies.** Both halves of the pipeline now run in-process:
Apple's ImageIO reads your image (preview, dimensions, size limits, and the full-resolution
decode), and statically linked libavif / libaom / libwebp encode it. The app spawns no
subprocess and needs nothing installed — no Homebrew, no `avifenc`, no `cwebp`. Outputs are
written atomically. The encode runs on a worker thread so the window keeps painting.

**v0.1 — feature-complete and packaged.** Smoosh launches to a drop zone — pick an
image or drag one onto the window — see a preview and its size, choose AVIF / WebP
/ Both, and press Smoosh — the compressed files land next to the original and the
before/after size and savings percentage are shown per format, each with its own
save icon to copy that one file to a location you choose, without touching the
auto-saved original.

Ships as a `.app` (`native package --target macos --signing adhoc`) — ad-hoc
signed, not notarized (no Apple Developer account behind this build; fine for a
single-machine local tool, see PLAN.md's M10 entry). The app icon is a rough
placeholder pending a proper design pass, also noted there.

See [PLAN.md](PLAN.md) for milestones, locked decisions, and open questions.
See [CLAUDE.md](CLAUDE.md) for working context and toolchain notes.

## How it works

Built on the [Native SDK](https://native-sdk.dev): the view is declarative
markup (`src/app.native`), the logic is plain Zig on a `Model` / `Msg` / `update`
loop, and the SDK's own engine renders every pixel. No web view, no JS runtime in
the binary.

Encoding got there in phases:

- **Phase A (v0.1)** — shelled out to `sips`, `avifenc` and `cwebp` through the
  effects channel's `fx.spawn`. Fast to build, fast to iterate on the UI.
- **Phase B (v0.2 / v0.3)** — decode moved to Apple's ImageIO
  (`src/imageio.zig`), then encode to statically linked libavif / libaom /
  libwebp via a small C shim (`src/encode.c`). Both run on a worker thread. No
  subprocess touches your image, and the binary is self-contained.

## Requirements

- macOS (Apple Silicon targeted; no Linux or Windows)
- [`native`](https://native-sdk.dev) CLI **0.10.1**
- Zig **0.16.0**
- Nothing else — no Homebrew packages, no external encoders.

## Development

```sh
native dev      # Debug build + run, with markup hot reload
native build    # ReleaseFast binary into zig-out/bin/
native check    # validate markup + app.zon
native test     # test suite
native package --target macos --signing adhoc   # zig-out/package/smoosh.app
native package --target macos --signing adhoc --archive   # + zig-out/package/smoosh.dmg
```

`--archive` wraps the `.app` in a zero-config drag-to-Applications DMG (generated
Retina background, Applications alias, no `app.zon` configuration required).
Installing means double-clicking the `.dmg` to mount it, then dragging the app
icon onto the Applications alias inside that window — otherwise, just drag
`zig-out/package/smoosh.app` straight into `/Applications` yourself, no DMG
needed.

Driving the running app:

```sh
native automate snapshot                        # list widget ids
native automate widget-click <view-label> <id>  # ids are bare numbers from snapshot
native automate screenshot <view-label>
```

A clean `native build` proves the code compiles, not that it works — changes are
verified against the running app.

## Layout

```
src/main.zig      the app: Model, Msg, update, effects        (added in M1)
src/app.native    the view                                    (added in M2)
src/imageio.zig   the ImageIO seam: probe + thumbnail         (added in M13)
app.zon           identity, window, permissions, capabilities
docs/spikes/      proven reference implementations; not built as part of the app
PLAN.md           milestones and decisions
CLAUDE.md         working context for AI assistants
```

`package.json`, `tsconfig.json`, and `src/core.ts` were an abandoned TypeScript
core; deleted in M1, no npm/bun surface remains in this tree.

## Non-goals for v0.1

Batch processing, quality sliders, side-by-side comparison, animated images, SVG,
in-app editing, cloud upload or history, and any dependency on Node, ImageMagick,
or Sharp.
