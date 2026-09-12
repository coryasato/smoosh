# Changelog

For the engineering record — the decisions still in force, and the measurements the encoder work was
held to — see [PLAN.md](PLAN.md) and [docs/phase-b-baseline.md](docs/phase-b-baseline.md).

## v0.8 — 2026-09-12

Faster. A 12-megapixel photo — an ordinary phone picture — used to take about two seconds to come
out as AVIF. It now takes about three-quarters of a second, for a byte-for-byte identical file.

- **AVIF encoding uses several of your Mac's cores instead of one.** Nothing about the picture
  changes: the file Smoosh writes is identical to the one it wrote before, down to the byte. It
  just arrives sooner. The gain is largest on big photos and on "Both", where it is roughly 2.4x.
- **Small images were always fast and still are** — this is not something you will notice on an
  icon or a screenshot of a dialog box.

Smoosh never froze while it worked, so this does not fix a hang. It shortens a wait.

## v0.7 — 2026-09-11

Drop onto the Dock icon. Smoosh can be buried behind a browser and still take an image: drag a file
onto its icon in the Dock and it comes forward with the picture already loaded.

- **Drag an image onto the Smoosh icon in the Dock** — from Finder, from the Desktop, from a
  screenshot sitting where macOS left it. The tile highlights when it will take the file, and the
  run from there is identical to dragging onto the window: preview, size, Smoosh.
- **"Open With → Smoosh"** now appears on images in Finder, which is the same door by another
  handle. Smoosh never becomes the default app for any format — it only offers itself.
- **Dragging several images at once takes the first** and ignores the rest. Smoosh works on one
  image at a time everywhere else, and this is no different.
- Dragging a picture straight out of a web page onto the Dock icon does not work, and cannot: the
  Dock only accepts real files. Use Cmd+V for that — copy the image and paste it into the window.

This needs the packaged app. A Smoosh run straight from a build has no Dock identity for macOS to
attach any of this to.

**Fixed: a screenshot dragged off its floating thumbnail could fail to save.** It depended on how
long you took to press Smoosh. macOS stages that screenshot in a temporary folder and clears that
folder away a few seconds later; Smoosh copied the picture out in time but still aimed its output at
the folder, so a quick press landed and an unhurried one failed with a folder-permissions message
that had nothing to do with permissions. Those screenshots now go to the Desktop, where macOS was
about to file the original anyway, and the status line says so.

## v0.6 — 2026-09-10

Paste. Copy an image anywhere on your Mac — a screenshot taken with Cmd-Ctrl-Shift-4, "Copy Image"
in a browser, an image file copied in Finder — press Cmd+V over the Smoosh window, and it loads.

- **Cmd+V loads whatever image is on the clipboard.** It works from the same window state a drop
  does, and from there the run is identical: preview, size, Smoosh.
- **A file copied in Finder keeps its own name**, and its compressed copies are filed beside the
  original, exactly as if you had dragged it in.
- **A copied picture with no file behind it goes to your Desktop** — a screenshot, or an image
  copied out of a web page. It is named for the moment you pasted it
  (`smoosh-2026-09-10-143005`), so pastes never write over each other and a Desktop full of them
  still tells you which is which.
- **Pressing Cmd+V with no image on the clipboard says so** and leaves whatever you had loaded
  untouched.
- **AVIF files can now be opened, not just dropped.** The open panel used to grey them out even
  though dragging one in worked. It no longer filters by file type at all — it shows everything and
  lets the "Not an image" message do the judging, exactly as a drop and a paste always have — and
  AVIF is now named alongside the other formats in the window and in that message.
- The empty window now mentions pasting alongside dropping and clicking.

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
