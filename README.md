# Smoosh

A tiny native macOS app that compresses images into modern web formats — drop an
image in, get AVIF and/or WebP back, next to the original. No upload, no browser
tab, no account.

It exists to replace the "open TinyPNG / Squoosh in a tab" workflow with
something local and instant.

## Status

**Working, unpolished.** Smoosh launches, you pick an image,
see a preview and its size, choose AVIF / WebP / Both, and press Smoosh — the
compressed files land next to the original and the before/after size and savings
percentage are shown per format. "Save As…" copies the produced file(s) to a
location you choose, without touching the auto-saved originals.

Not done yet: the window layout overflows at 480x320 and clips the button row,
and there is no packaged `.app`.

See [PLAN.md](PLAN.md) for milestones, locked decisions, and open questions.
See [CLAUDE.md](CLAUDE.md) for working context and toolchain notes.

## How it works

Built on the [Native SDK](https://native-sdk.dev): the view is declarative
markup (`src/app.native`), the logic is plain Zig on a `Model` / `Msg` / `update`
loop, and the SDK's own engine renders every pixel. No web view, no JS runtime in
the binary.

Encoding is phased:

- **Phase A (MVP)** — shell out to `avifenc` and `cwebp` through the effects
  channel's `fx.spawn`. Fast to build, fast to iterate on the UI.
- **Phase B (later)** — decode through Apple's ImageIO, encode through
  statically linked libavif/libwebp. One self-contained binary.

The Native SDK ships no image encoder, so Phase A depends on tools you install
yourself. Smoosh detects them at launch and tells you what is missing — it never
installs anything on your behalf.

## Requirements

- macOS (Apple Silicon targeted; no Linux or Windows in v0.1)
- [`native`](https://native-sdk.dev) CLI **0.8.0**
- Zig **0.16.0**
- Encoders, for Phase A:
  ```sh
  brew install libavif   # provides avifenc
  brew install webp      # provides cwebp
  ```

## Development

```sh
native dev      # Debug build + run, with markup hot reload
native build    # ReleaseFast binary into zig-out/bin/
native check    # validate markup + app.zon
native test     # test suite
```

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
app.zon           identity, window, permissions, capabilities
docs/spikes/      proven reference implementations; not built as part of the app
PLAN.md           milestones and decisions
CLAUDE.md         working context for AI assistants
```

`package.json` and `tsconfig.json` are leftovers from an abandoned TypeScript
core and serve the editor only — the build never reads them. They come out in M1
along with `src/core.ts`.

## Non-goals for v0.1

Batch processing, quality sliders, side-by-side comparison, animated images, SVG,
in-app editing, cloud upload or history, and any dependency on Node, ImageMagick,
or Sharp.
