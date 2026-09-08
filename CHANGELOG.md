# Changelog

For the engineering record — the decisions still in force, and the measurements the encoder work was
held to — see [PLAN.md](PLAN.md) and [docs/phase-b-baseline.md](docs/phase-b-baseline.md).

## v0.5 — 2026-09-08

Screenshots. Dragging one straight off its floating thumbnail is the fastest way to get a screenshot
into Smoosh, and it used to fail twice over — macOS moves the file out from under the app seconds
later, and the folder it hands the drag from cannot be written to. Both are fixed. The second fix is
the bigger one: Smoosh now works out where your compressed files can go *before* it starts, so it
never finishes the work and then discovers it has nowhere to put it.

- **A screenshot dragged straight off its floating thumbnail now smooshes.** macOS serves that drag
  from a staging folder it empties seconds later, so the image previewed fine and then failed to
  compress. Smoosh takes its own copy of the file the moment it arrives, and works from that.
- **Images in folders Smoosh can't write to no longer just fail.** The folder is checked when you
  open the file, not after the compression is finished:
  - A **screenshot** in such a folder is saved to your Desktop instead, and the status line says
    `Saved to Desktop.` rather than a bare "Done." — you are never left guessing where a file went.
  - **Anything else** is compressed but not filed anywhere on its own: the line reads
    `That folder is read-only — save a copy.`, and each result's Save button puts it where you want
    it. Smoosh will not guess a folder for your files.
- **When a save fails, the message says what to actually check.** Denying Smoosh access to your
  Desktop used to be reported as a folder-permissions problem, which sends you to Get Info to find
  nothing wrong — it now points at Privacy & Security instead.
- **The app icon sits flush in the Dock.** It used to render as a square tile with a smaller rounded
  square floating inside it, because macOS does not round off app icons the way iOS does — the
  artwork has to be its own shape. Now it matches every other Mac app.

## v0.4 — 2026-09-07

Smoosh saves your compressed images beside the original automatically, and until now nothing in the
window ever said where that was. Now it does.

- **"Show in Finder" next to the finished message.** Opens the folder Smoosh wrote to with the new
  files already selected — both of them after a "Both" run. It points at the automatic save, not at
  a copy you saved somewhere yourself, since that is the one you chose the location for.
- Hovering a label now brightens it instead of drawing a grey box behind it, on both the Save
  buttons and the new one.
- Hovering any quiet button in dark mode showed no response at all. It does now.

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
