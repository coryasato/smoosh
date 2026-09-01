# Smoosh

A tiny native macOS app that compresses images into modern web formats. Drop an image in, get AVIF
and/or WebP back, next to the original. No upload, no browser tab, no account.

## What it does

Drag an image onto the window — or click the drop zone to pick one. Smoosh shows a preview and the
original file size. Choose **AVIF**, **WebP**, or **Both**, press **Smoosh**, and the compressed
files land next to the original:

```
large.jpg
Original  5.6 MB

AVIF  700.2 KB  −88%
WebP  655.3 KB  −89%
```

Each result row carries a save icon to copy that one file somewhere else — the auto-saved copy next
to the original stays put.

"Both" writes two files so a page can serve AVIF with a WebP fallback. Each is measured on its own:
there is no combined savings number, because no browser downloads both.

## What you get

- **AVIF** at quality 58, speed 6. **WebP** at quality 80. These are fixed — the settings are the
  product, not a panel to tune.
- **Chroma subsampling follows the source.** A JPEG keeps its own; everything else is encoded 4:4:4.
  This is what keeps screenshots, UI exports and other flat-colour graphics sharp, where a blanket
  4:2:0 would soften them.
- **Metadata is stripped** — EXIF, GPS, XMP, and the ICC profile. Web output is the whole point of
  the tool, and location data in a file you are about to publish is rarely what you meant.
- **Everything is converted to sRGB**, and tagged as such. A Display P3 photo comes out with correct
  colour in every browser rather than a wide-gamut file most clients mishandle.
- **Rotation is baked into the pixels**, so an orientation-tagged photo is upright everywhere,
  including in clients that ignore the tag.
- **Outputs are written atomically.** A crash or a full disk mid-encode leaves the previous file
  intact, never a truncated one.

Outputs are named after the source and overwrite a previous Smoosh run silently — running it again
is "redo this". A format whose output would *be* the source is skipped and says so, so a `.webp`
source never overwrites itself.

## Input

JPEG, PNG, WebP, HEIC/HEIF, TIFF, GIF and BMP — whatever macOS itself can decode.

Up to **100 MB** or **50 megapixels**, whichever comes first. Past either, Smoosh names the limit
and your file's actual size instead of trying.

If one format fails and the other succeeds, that is a success: the file that landed is reported
normally and the one that did not is named in the status bar.

## Installing

There is no download yet — build it from source:

```sh
native package --target macos --signing adhoc            # zig-out/package/smoosh.app
native package --target macos --signing adhoc --archive  # + zig-out/package/smoosh.dmg
```

Drag `smoosh.app` into `/Applications`. `--archive` also produces a drag-to-Applications DMG if you
prefer that route.

The build is **ad-hoc signed, not notarized.** That is fine for an app you build and install on
your own machine. A copy that travels — AirDropped, emailed, downloaded — picks up a quarantine
flag and will hit Gatekeeper's "unidentified developer" prompt; distributing it properly needs a
paid Apple Developer identity.

### Requirements

- macOS on Apple Silicon. There is no x86_64 or universal build, and no Linux or Windows support.
- [`native`](https://native-sdk.dev) CLI **0.10.1** and Zig **0.16.0** to build.
- Nothing at runtime. No Homebrew packages, no external encoders, no Node.

### Rough edges

The app icon renders as a square tile in the Dock rather than sitting flush like other Mac apps —
its source PNG has no alpha channel and draws its own rounded-square background.

## How it's built

Smoosh is built on the [Native SDK](https://native-sdk.dev): the view is declarative markup
(`src/app.native`), the logic is plain Zig on a `Model` / `Msg` / `update` loop, and the SDK's own
engine renders every pixel. No web view, and no JS runtime in the binary.

Both halves of the image pipeline run in-process. Apple's **ImageIO** reads the file — preview,
dimensions, and the full-resolution decode. Statically linked **libavif / libaom / libwebp** encode
it, through a small C shim (`src/encode.c`). Both run on a worker thread, so the window keeps
painting while a large photo encodes.

The app spawns no subprocess and reads nothing from your `PATH`.

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

A clean `native build` proves the code compiles, not that it works — changes are verified against
the running app.

```
src/main.zig      the app: Model, Msg, update, effects
src/app.native    the view
src/imageio.zig   the ImageIO seam: probe, thumbnail, decode
src/encoders.zig  the encoder seam, over the C shim in src/encode.c
src/chroma.zig    the source-container chroma table + JPEG SOF parser
third_party/      vendored encode-only static archives
app.zon           identity, window, permissions, capabilities
```

[PLAN.md](PLAN.md) holds the decisions, requirements and open work.
[CHANGELOG.md](CHANGELOG.md) is the development history.
[CLAUDE.md](CLAUDE.md) is working context for AI assistants.

## License

Smoosh is [MIT licensed](LICENSE).

The binary also statically links libavif, libaom and libwebp, which are BSD-licensed and carry
their own terms — see [third_party/README.md](third_party/README.md).

