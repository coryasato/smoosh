# Changelog

For the engineering record — the decisions still in force, and the measurements the encoder work was
held to — see [PLAN.md](PLAN.md) and [docs/phase-b-baseline.md](docs/phase-b-baseline.md).

## v0.3 — 2026-08-29

Smoosh runs on a Mac with nothing installed. The AVIF and WebP encoders are built into the app now
instead of shelling out to Homebrew command-line tools, so there is nothing to install and nothing
to keep up to date. Compressed output is the same quality and size as before.

- **No more `brew install libavif webp`.** The app runs no external programs at all.
- **WebP and AVIF sources work.** Feeding Smoosh a `.webp` or `.avif` file used to produce nothing.
- **Rotated photos come out upright in both formats.** Before, the same photo could produce an
  upright AVIF and a sideways WebP.
- **Display P3 photos no longer produce a washed-out WebP.** Everything is converted to sRGB and
  tagged, so colour is correct in every browser.
- **Multi-image HEIC files compress the right picture**, not whichever one happened to be first.
- **An interrupted encode can't leave a broken file.** Outputs are written whole or not at all.
- **EXIF, GPS and XMP metadata are stripped from every output.** AVIF files used to carry them
  through, so a photo published from Smoosh could leak its location. WebP never did; now the two
  behave the same.
- The app is larger — roughly 5.5 MB to 10.9 MB — because the encoders now ship inside it.

## v0.2 — 2026-08-28

Smoosh reads images through macOS itself rather than shelling out to `sips`, which made previews
and file checks accurate. The compressed files are byte-for-byte what v0.1 produced — this release
changed nothing about encoding.

- **Photos with rotation tags preview upright.**
- **Multi-image HEIC files preview the right picture.**
- **Images smaller than the preview box draw at their real size** instead of a blurry upscale.
- **Files that aren't images are rejected sooner**, before any decoding, with a clearer message.
- **Oversized files are rejected before the decode**, so a 51-megapixel file fails immediately
  rather than after the work.
- Compressing still required `brew install libavif webp`.

## v0.1 — 2026-08-13

The first working release: drag an image in, get AVIF and WebP back.

- Drag an image onto the window, or click to pick one.
- Preview and original file size.
- Choose AVIF, WebP, or Both.
- Compressed files auto-save next to the original, with before/after size and savings shown per
  format.
- A save icon on each result copies that one file elsewhere, leaving the auto-saved copy alone.
- In Both mode, one format failing doesn't lose the other — the file that landed is kept and
  reported.
- Files up to 100 MB or 50 megapixels; past either, Smoosh says so instead of trying.
- JPEG, PNG, WebP, HEIC/HEIF, TIFF, GIF and BMP sources.
- Ships as an ad-hoc signed `.app`.
- Required `brew install libavif webp`.
