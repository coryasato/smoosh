# Smoosh — PLAN.md

> **Living plan**: what is still open, the requirements the code must keep satisfying, and the
> decisions still in force. Deliberately NOT a history — how and when something shipped lives in
> `CHANGELOG.md` (for users) and in git; the encoder measurements live in
> `docs/phase-b-baseline.md`; the traps you need before touching the code live in `CLAUDE.md`.
> A line that records none of those three things does not belong here.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern
web formats (AVIF and/or WebP) without leaving your desktop.

## Status
**v0.8 — feature-complete, zero-dependency, and not distributed.** Pick, drop or paste an image,
choose AVIF/WebP/Both, and Smoosh writes the outputs itself and says where they went; each landed
result row carries its own save icon to copy that one file elsewhere. Ships as an ad-hoc-signed
`.app`, arm64 only.

The whole pipeline runs in-process: Apple ImageIO reads (`src/imageio.zig`), vendored static
libavif/libaom/libwebp write (`src/encoders.zig` over `src/encode.c`), and each format encodes on
its own worker thread — with libaom itself spread across several cores since v0.8 — so the window
keeps painting. **The app spawns no subprocess and needs nothing installed.**

**Where the outputs go is decided per file, before the run** — beside the source when that folder
takes a write, the Desktop for a screenshot stranded somewhere read-only, and nowhere-but-Save-As
otherwise (see `Destination` in `src/main.zig`).

## What is open
Two things, and neither is a task waiting to be picked up. **Everything else in this file is
settled** — read it as constraint, not backlog.

1. **Distribution** — one decision with three costs attached. Nothing in it bites on the machine
   that built the app, so none of it is worth doing until handing the `.app` to someone else is
   actually the plan.
2. **A CLI** — undecided on purpose, and deferred behind everything else.

### Distribution — the gate, and what it costs
**Treat this as ONE decision with three line items, not three loose ends: decide to distribute, and
all of it comes due together.** That framing is deliberate: the same trigger governs the libaom
`-Os` rebuild declined under "Performance — measured and closed" below. If distribution happens,
reopen that too, because binary size starts costing a user something at download time.

**What the app is today:** arm64-only, ad-hoc signed, not notarized. Verified 2026-09-12 — all four
vendored archives and the binary report `arm64`; `codesign -dv` reports `Signature=adhoc`,
`TeamIdentifier=not set`.

**Ranked by size of the job.**

- **arm64-only — the big one.** An Intel or Rosetta-less user cannot run it at all. The vendored
  archives are non-fat, so this is a `third_party/` rebuild before it is a `build.zig` change:
  every archive needs an x86_64 twin and a `lipo` pass, and `docs/phase-b-baseline.md`'s parity
  gate would have to be re-measured on the second architecture.
  → [Building a universal macOS binary][universal] · `third_party/README.md` carries the CMake
  invocations that produced the current archives.
- **Not notarized.** A copy that travels — AirDropped, emailed, downloaded — picks up a quarantine
  flag and hits Gatekeeper's "unidentified developer" wall. Needs a paid Apple Developer identity.
  The ad-hoc decision itself is under "Key decisions carried forward"; what is unexplored is the
  work.
  → [Notarizing macOS software before distribution][notarize] ·
  [Customizing the notarization workflow][notary-workflow] (`xcrun notarytool`, then `stapler`) ·
  `native package --signing` and the `native-sdk` skill for the packaging half.
- **A Developer ID signature buys more than notarization does.** It also ends the TCC permission
  churn — see CLAUDE.md, "Ad-hoc signing and the TCC trap", which is where that lives because it
  is a debugging trap first and a distribution cost second. A local annoyance today; a support
  burden the moment anyone else installs a second build. **One purchase settles this item and the
  one above it.**

**Launch time is measured and fine: ~300-400 ms warm** (ReleaseFast v0.8, exec to window on
screen, three runs, ~50 ms polling granularity so read it as an upper bound). Cold-cache launch is
unmeasured. Nothing here needs work; the item is retired rather than carried.

*Suggested: **Opus 5, high** — but only once distribution is an actual decision. Read this whole
section before starting: the three items are one purchase and one architecture sweep, and doing
either without the other leaves the app still undistributable.*

[universal]: https://developer.apple.com/documentation/apple-silicon/building-a-universal-macos-binary
[notarize]: https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
[notary-workflow]: https://developer.apple.com/documentation/security/customizing-the-notarization-workflow

### A Smoosh CLI — undecided, on purpose
**LAST. Deferred behind everything above** — do not pick this up unless the owner asks for it by
name.

Not part of the desktop app and not on its roadmap: a second, tiny binary that shares the image
core. `smoosh hello.jpg` writes `hello.avif` and `hello.webp` next to the source and exits.

**Shape.**
- Flags: `--avif`, `--webp` (both if neither is given), `--dest=<dir>` (default: beside the source).
- `main` is: parse argv → for each requested format → `imageio.decode` → `encoders.encode{Avif,Webp}`
  → atomic write. One Smoosh run per invocation; no batch progress, no watch mode, no config file.
- Reuses `src/imageio.zig`, `src/encoders.zig`, `src/encode.c` UNCHANGED. They carry no Model / Msg
  / Runtime dependency — `imageio.decode` already returns straight-alpha 8-bit sRGB callable off any
  thread, and the encoders take that buffer directly. This is the dogfood: if the CLI cannot be
  built cleanly on these seams, the seams are wrong.

**Why it is its own session.** The cost is entirely in `build.zig`. A CLI is a third executable
artifact that must replicate the exe's link wiring on its own module: compile `src/encode.c`
exactly once (twice is a fatal `duplicate symbol`), link the vendored archives in order plus the
mandatory libsharpyuv, and `addFrameworkPath` for ImageIO / CoreGraphics or the link fails with
"searched paths: none". `build.zig`'s own comments flag every one of these as a trap that hides
until the other artifact builds. Then argv parsing, exit codes, a smoke test, and a distribution
decision (ship `smoosh` beside `Smoosh.app`; or a `--install` that symlinks it onto `PATH`).

**What it unlocks.** `smoosh` + drag an image into the terminal — the quick path the app's window
drop cannot be for a terminal user. And a Finder **Quick Action** becomes trivial: a `.workflow`
bundle running `smoosh "$@"` on the selection, installed to `~/Library/Services/` or shipped inside
the `.app`. The Quick Action has no independent design — it is this CLI with a Finder trigger.
## Product behavior

### Format selection
- **AVIF** — best compression for modern browsers.
- **WebP** — broader compatibility.
- **Both** (default) — two files, so a source can serve AVIF with WebP fallback.

When "Both" is selected each output shows its own savings line — never a summed "combined
savings", since no client ever downloads both.

### File acquisition
- Native open dialog via `runtime.showOpenDialog`, called from a `HostCallBinding.request_fn` bound
  by hand in `src/main.zig` — see CLAUDE.md's "File acquisition, honestly" for why this requires a
  hand-authored root. **It states no extension filter.** `image.probe` rules on the bytes and its
  failure already names the supported formats, and neither a drop nor a paste consults a list — so
  any list here is only a set of files the user can drag in but cannot pick. A partial one is worse
  than none: `avif` was missing from it and greyed out real, decodable images in the panel.
- Real window-wide drag-and-drop via `UiApp.Options.on_drop`, which re-enters the exact same load
  chain a picked file does.
- **An ephemeral source never writes beside itself.** `isEphemeralSource` decides two things, not
  one: whether to stash the BYTES, and whether the source's folder can hold the OUTPUT. The second
  half was missing until v0.7 and the bug it caused was invisible in a fast test — a
  `screencaptureui` staging directory is the user's own temp dir and answers the write probe
  truthfully (`writable`) during the load, then stops existing seconds later, so the output landed
  in a directory that had been torn down and reported a folder-permissions failure it was never
  about. Whoever presses Smoosh quickly never sees it. The two predicates have to move together:
  any source whose bytes were worth rescuing has a folder not worth writing to.
- Cmd+V, via a registered `platform.Shortcut` and `Options.on_command` — a file URL on the
  pasteboard loads like a pick, raw pixels are written into the cache and filed to the Desktop.
  CLAUDE.md's "Cmd+V is a THIRD seam" and `src/pasteboard.zig`'s header carry why neither the SDK's
  clipboard seam nor `on_key` could serve this.
- A drag onto the DOCK TILE, and Finder's "Open With", via an `application:openURLs:` method
  `src/dockopen.zig` adds to the SDK's own app delegate. Re-enters the load chain as
  `.dropped_file`, the same Msg the window drop uses. See CLAUDE.md's "The Dock-tile drop: three
  constraints, all load-bearing".
- Accepts what macOS ImageIO decodes: JPEG, PNG, WebP, AVIF, HEIC/HEIF, TIFF, GIF, BMP — the same
  set through the first three ways in, because only the probe decides. **The Dock tile is the one
  exception**, and not by choice: LaunchServices rules on the extension before the app is even
  woken, so `app.zon` has to enumerate them.

### Output handling
- Auto-save next to the source (`photo.jpg` → `photo.avif` / `photo.webp`) as soon as "Smoosh"
  completes — no save dialog in the default path.
- An existing output file is overwritten silently. Re-running "Smoosh" on the same source is
  "redo this".
- **"Overwrite silently" is about a previous OUTPUT, never the source.** A format whose destination
  would BE the source is skipped (`EncodeOutcome.same_path`), and the comparison is
  CASE-INSENSITIVE because macOS volumes are. Symlinked and hardlinked destinations are still not
  covered — that needs an `Io` to stat with, which `update` can never hold.
- Outputs are written **atomically**: a temp sibling in the destination directory, renamed into
  place. A crash leaves the temp, never a half-written output.
- Each landed result row carries its own save icon — an optional secondary action to copy that one
  file elsewhere. It does not replace auto-save.
- A negative-savings result (output larger than a tiny source) is real, not an error: it displays
  as `+1% larger`.

### Error states
Each maps to a user-facing message and the `.failed` Model state:
- Source unreadable (`file.stat` failed) → "Can't read that file."
- Unsupported/undecodable input → name the expected formats. `image.probe` is the gate, and it
  reports off the frame COUNT, not a null source (`CGImageSourceCreateWithURL` succeeds on 49 bytes
  of text named `.jpg`).
- Input exceeds the size or megapixel limit → show the limit and the file's actual size.
- Preview could not be built (`image.thumbnail` failed, or its reply would not parse) → one
  message; the load fails rather than showing a card with no image.
- Encode failed (the worker could not decode the source, or libavif/libwebp rejected the frame) →
  a short, non-technical message. There is no encoder stderr to surface.
- Write to output path failed (permissions, disk full, read-only volume) → points at the folder.
- Destination would be the source → skipped, and named as such ("already an AVIF file").

In "Both" mode a per-format failure is a WARNING on a `.done` run, not a `.failed` one — only a run
where no requested format landed sets `.failed` (see "the partial-failure decision" in `main.zig`).

**`.failed` is always paired with a populated `error_message_buffer`**; the list above enumerates
every message that can land there, and no other path may set `.failed`.

### Input size limits
**100 MB** or **50 megapixels**, whichever comes first — both checks inclusive. A local tool should
be more permissive than a typical web upload limit while still protecting against files that would
exhaust memory decoded to RGBA. The error names both the file's actual size and the limit.

## Correctness requirements
These are properties of the decode/encode path that must survive any change to it. The
measurements behind each are in `docs/phase-b-baseline.md`.

- **Primary frame, not index 0.** Everything reads `CGImageSourceGetPrimaryImageIndex` — the
  megapixel guard, the preview and the encoder input.
- **EXIF orientation is baked into the pixels.** `kCGImageSourceCreateThumbnailWithTransform` does
  it for the preview; the full decode does it by hand, because
  `CGImageSourceCreateImageAtIndex` returns the frame unrotated.
- **Convert to sRGB, and tag sRGB.** Drawing into a `CGBitmapContextCreate(..., kCGColorSpaceSRGB)`
  performs the conversion for free; the encoder must then tag it explicitly, because the same path
  drops the ICC profile.
- **Metadata is stripped, unconditionally.** Encoding from decoded pixels copies nothing unless
  asked — this is the do-nothing path mechanically and a product decision editorially. There is no
  toggle, and adding one is not on the table.
- **Decode to 8-BIT RGBA in `decode` and `thumbnail`; `probe` allocates no bitmap at all.** Pin the
  depth rather than inheriting the source's. Load-bearing on the current fixture set, not
  hypothetical: `small.png` reports Depth 16 and `tiny.png` reports Depth 1.
- **`src/imageio.zig` returns STRAIGHT alpha to every caller.** `CGBitmapContextCreate`'s only
  8-bit RGBA layout is `kCGImageAlphaPremultipliedLast`, so `drawToRgba8` un-premultiplies. This is
  a contract, not an optimization: `fx.registerImage` documents its input as straight-alpha RGBA8
  and libwebp/libavif want the same, so one convention leaving the module beats two callers each
  remembering to convert. The buffer is also TOP-DOWN, so nothing downstream needs a flip.
- **An undecodable file is detected by frame COUNT, not by a null source.**
- **AVIF chroma subsampling is reproduced from the SOURCE CONTAINER**, per the table in
  `src/chroma.zig`'s header: a JPEG keeps its own sampling (parsed by hand from the SOF marker —
  ImageIO exposes no key for it), everything else is 4:4:4, grayscale is 4:0:0. This is the single
  most consequential encoder knob — invisible on photos, catastrophic on graphics (7.7 dB on a UI
  fixture). **Do NOT simplify this to "JPEG → 4:2:0"**, and **do NOT invent an "is this
  photographic?" heuristic**; `src/chroma.zig` says why at length.

## Known limitations
- **"Both" decodes the source twice.** The two formats are two independent `image.encode` workers —
  that independence is the partial-failure decision — and each calls `imageio.decode` on the same
  file. The cost is **peak memory, not latency**: two full-resolution RGBA buffers live at once, up
  to ~400 MB at the 50 MP guard. The two decodes run concurrently on separate threads. Sharing one
  decode would mean a refcounted buffer outliving both slots — real complexity for a memory win
  only, so this is a deliberate trade. Measured since (`docs/phase-b-baseline.md`, "Round 2"): a
  decode is 3-8% of a run, so the "not latency" half is a number now, not an expectation.
- **arm64 only.** The vendored archives are non-fat arm64-macos; producing an x86_64 or universal
  build is unexplored. A genuine gap the moment the `.app` is handed to anyone else.
- **`~/Desktop` is hardcoded in two places now.** A custom `com.apple.screencapture location` is
  not read — that needs a `CFPreferencesCopyAppValue` binding, since the app spawns no subprocess —
  so both the screenshot rescue (`Destination.desktop`) and a raw-bytes paste file to `~/Desktop`
  literally. A user who has moved their screenshot folder gets their files somewhere they did not
  choose. One binding fixes both.
- **A raw-bytes paste writes its file on the loop thread.** `clipboard.paste` must read the
  pasteboard from the main thread (AppKit), and `-[NSData writeToFile:atomically:]` then runs there
  too, so a very large pasted image stalls the window for the length of one write. Moving it would
  mean reading the pasteboard on the loop and handing the `NSData` to a worker — real work for a
  hitch nobody has reported at screenshot sizes.

## Key decisions carried forward
- **Partial failure in "Both" mode is partial SUCCESS.** The two encodes are independent; one
  landing while the other fails is `.done` with the failure named in the status bar. Only an
  all-failed run is `.failed` — the worker writes its own output file, so anything else would
  contradict a file already on disk.
- **Save As is per-format**, not a single "Both" action. Each result row has its own save icon, each
  running its own one-shot save-dialog-then-copy round. Pressing either while a round is in flight
  is a no-op.
- **Signed ad-hoc, not notarized, not unsigned**, for a single-machine local tool with no paid Apple
  Developer identity. Revisit if this ever needs sharing.
- **AVIF encoding stays on libaom; ImageIO does decoding only.** Measured, because the tempting
  answer is wrong: on PHOTOGRAPHS ImageIO's AVIF encoder is quality-indistinguishable from
  `avifenc -q 58 --speed 6` (714,717 B at 35.65 dB against 717,003 B at 35.73 dB on `large.jpg` —
  0.08 dB, far under the ~0.5 dB just-noticeable threshold) and runs 2.6× faster. Generalizing from
  photographs is the trap. On a UI/screenshot fixture `avifenc` produced 7,515 B at 47.77 dB in
  YUV444 where ImageIO's best was 9,911 B at 40.04 dB in YUV420 — **32% larger and 7.7 dB worse** —
  because ImageIO is hard-locked to YUV420 with no subsampling control exposed. Raising quality
  does not help; it plateaus near 40 dB. It also has an alpha interop bug: a 16-bit source with
  alpha yields a 10-bit AVIF whose alpha plane libavif/dav1d cannot decode, i.e. Chrome and
  Firefox. Screenshots and UI exports are core input for a web-asset tool, so this would be a real
  regression.
- **The encoder settings are the pinned `avifenc`/`cwebp` ones, carried over literally** — AVIF
  q58/speed6, WebP q80 — because Smoosh vendors the same encoders those front-ends drive.
  `encoders.pinned` asserts the three archive versions so an upgrade cannot arrive silently with a
  re-copied file.
- **The settings ARE the product: no sliders, no panels, no batch mode.** Smoosh exists to be a
  drop zone that does one thing well. Every feature that would add a control is a feature that
  makes it something else, and the answer is no by default.
- **Long work runs off the loop thread through the WORKER-CARRIER seam, never `feedHostResult`.**
  `Effects` offers spawn/fetch/file/db/pty/channel and nothing that runs arbitrary Zig off-loop, so
  the seam is a `HostCallBinding.request_fn` that returns WITHOUT answering: the worker parks its
  answer in a bridge-owned mailbox and calls `services.wake()`, and the loop thread drains it
  through `poll_fn`/`pending_fn`/`bind_services_fn`. `shutdown_fn` is not optional — it is the one
  window in which a still-running worker can be joined while `PlatformServices` is live.
- **A full-resolution buffer can never ride a host result.** `max_effect_host_result_bytes` is
  256 KiB and an over-cap answer is silently rewritten to the err route. The 140px preview fits
  (77 KiB) behind a comptime assert; `imageio.decode` is deliberately not a host command at all.
  The cap that actually binds the preview is now the LAYOUT, not that budget — see
  `imageio.max_thumbnail_edge`.

### Performance — measured and closed (v0.8)
**Closed — this track has no open work.** `docs/phase-b-baseline.md`'s "Round 2" carries the
numbers and the method; this is what they settled. Every item below is either shipped or measured
and deliberately declined, and the verdicts are recorded so they are not rediscovered as fresh
ideas.

**The ranking this section used to carry was inverted.** Four of its five items were guesses from
reading the code, and the profile disagreed with all four: the item flagged as needing the most
care was the only one that paid, and the two ranked cheapest are unmeasurable. Kept here as the
reason not to re-propose them.

- **`encoder->maxThreads = 1` — shipped in v0.8, and it was the whole task.** 2.4x on the wall
  clock of a "Both" run (1838 ms -> 754 ms on a 12 MP photo). The determinism the setting was
  protecting turned out not to need it: libaom's bytes are **identical at every thread count from
  2 to 16** and differ only at exactly 1, so `encoders.encodeThreads` derives the count from the
  host and `min_avif_threads` floors it at 2. Half the logical cores, because WebP's encode is
  single-threaded and handing AVIF every core makes AVIF finish sooner and the RUN finish later.
- **`drawToRgba8`'s `@memset(pixels, 0)` — measured, kept, do not re-propose.** 0.72 ms on a 48 MB
  buffer, inside a 1800 ms encode: **0.04%**. It is worth more where it is, as the guarantee that
  the buffer is defined if a draw ever fails to cover the destination, than the 0.04% is worth.
- **`copy_out`'s extra malloc+memcpy — measured, kept, do not re-propose.** Below noise (1800 ms
  against 1811 ms, and the two orderings swap between runs).
- **The Both-mode double decode** — unchanged, and the numbers back the original call: decode is
  3-8% of a run. Memory, not latency. See "Known limitations".

- **libaom rebuilt `-Os` instead of `-O3` — considered and DECLINED (2026-09-12).** `libaom.a` is
  7.7 MB of the 10.49 MB binary, so the ~2.5 MB prize was real, and this is the one item on the
  list that was never measured. It was declined on three grounds, in order of weight: it trades
  speed for bytes on the path Round 2 had just established as the app's entire latency budget; the
  binary is built from source rather than downloaded, so its size costs a user nothing at install
  time; and it is the most expensive task left in the repo, because optimization level can change
  libaom's FP contraction and the whole parity gate would have to be re-measured to find out. The
  Homebrew comparison that motivated it (5.4 MB against our 8.1 MB) was never like-for-like —
  different build config, and a dynamic library against a static archive.

  **Reopen it only if Smoosh starts being DISTRIBUTED as a download**, where binary size becomes
  something a user pays for. Nothing else changes the arithmetic.

*Nothing here is open. Read this section before proposing a performance change, not after — four of
its five items are recorded refusals with numbers behind them.*

## Design decisions
The palette and geometry choices still in force. **Where the built app differs from the design
canvas** — measured, and deliberate in every case — is in
[`docs/design-board.md`](docs/design-board.md); read that before another visual pass. **What the
markup cannot express at all** is in
[`docs/native-sdk-constraints.md`](docs/native-sdk-constraints.md); read that when a design will
not build, not before.

**The layout floor is a TEST, not a comment.** The app must stay correct at `window_min_width`
(420): `tests.zig` lays the tallest state out at 420x400 and fails naming the overflow in points.
The 144px preview frame is what pays for everything else and is load-bearing.

**Settled decisions.**
- **The palette is app-owned**, set through `UiApp.Options.tokens_fn` (not `tokens`: the scheme is
  model state fed by `on_appearance`, so the flip is one ordinary `Msg` and `tokens` stays a pure
  function of the model). It is stated as OVERRIDES on the house theme, so roles the app never
  draws keep the house value for the CURRENT scheme instead of inheriting the light register's ink
  in a dark window.

  Peach is the Smoosh button and nothing else — the only saturated peach fill in the window.
  Lilac is the savings figure on every result row, and at 70%+ savings it also fills that row's
  badge solid (same hue, graded by weight). Sky is work in progress (the spinner). The format
  segments stay neutral.
- **Both schemes are WARM.** The board's dark neutrals lean blue-over-red by 4-6, which put cool
  surfaces under this scheme's warm ink and made dark read as a different app. The built ramp
  mirrors light's STRUCTURE instead of its values: a near-neutral ground with the warmth spent on
  the surfaces sitting on it. Every dark value holds the board's L* to within 0.25 — only the hue
  moved, so nothing about legibility shifted.
- **A manual appearance toggle PINS the scheme.** The footer's ghost icon button offers the other
  scheme (`moon` in light, `sun` in dark) and sets `scheme_pinned`; from then on `on_appearance` no
  longer moves `color_scheme`. Contrast and reduce-motion keep following the OS either way — those
  are accessibility settings, not a preference the button offers. `reset` preserves all four.
- **The window ground is painted, not cleared.** `background="background"` on the root column is a
  REPAINT fix, not decoration: the ground is otherwise the surface's clear colour, which is not a
  display-list command, so a theme flip changed it while nothing damaged the bare regions. The
  runtime's incremental present repainted every widget and left every uncovered patch of ground in
  the OLD scheme — the window came out half light, half dark, until the next content change forced
  a full repaint. Painting the ground as a real fill puts it in the diff.
- **`surface_pressed` is DARKER than `surface_subtle` in BOTH schemes** — the one place this
  palette departs from the stock pack, where pressed is normally the lighter step in a dark scheme.
  It is forced: `surface_pressed` is the segmented-control track and a ghost `toggle-button`'s
  selected state is hard-wired to `surface_subtle`, so the track must sit under the thumb. The test
  pins the DIRECTION, not just the separation.
- **No in-window header.** The titlebar already says Smoosh; a wordmark and app icon said it twice
  more in a 540pt window. Removing the row also fixed a Reset button that sat above an empty drop
  zone offering to undo nothing. Worth 46px, most of which went back to the preview frame.
- **ONE control row.** Format choice on the left, the two actions on the right, all on one
  baseline — the board stacks them. Folded together they read as a single "set it, then run it"
  line, and the row plus its 12pt gap went back to the tallest state's budget.
- **Result rows sit BELOW the preview, spanning the content width.** Beside a 168px preview a row
  carrying a labelled Save overflowed the 420pt minimum by 40px. The preview frame pays: 168 → 144,
  and `imageio.max_thumbnail_edge` 160 → 140 — the cap that binds the thumbnail is now the LAYOUT
  (a longer edge than the frame overflows it), not the 256 KiB host-result budget.
- **A run RESERVES its result rows** (`showAvifRow`/`showWebpRow`, not `hasXResult`). For the whole
  `.compressing` phase a row is drawn at full `height="34"` for every format in the run — size an
  em dash, no badge, no Save — so on a "Both" run the two encodes finishing out of order fill their
  own rows in place. Before this the faster format drew its row and the slower one then inserted
  ABOVE it, punting it down a frame later. The reservation ends at settle: a format that failed
  collapses its row then (one reflow, off the common path), so "a failed format shows no row; the
  status bar names it" still holds.
- **The savings badge is weight-graded by a savings threshold** (`savingsGate` in `main.zig`):
  under 30% a borderless muted chip, 30–70% the outline it has always drawn, 70%+ a solid `success`
  fill. One hue throughout — only the weight moves. This reverses the earlier "one hue, not two"
  call: at −89% vs −88% two format rows do land the same gate, so the cue cannot compare AVIF to
  WebP — but that comparison is deliberately not a goal (by the time both rows exist the encode is
  done), and the badge instead answers the per-file "was this worth running". An output that grew
  (`+N% larger`, `same size`) reads quiet, not keep. `foreground` on a `<badge>` takes no binding,
  so the three weights are three keyed `<if>` arms, not one bound badge.
- **`icon="download"`, NOT `icon="save"`.** The registry's `save` is a floppy disk — three paths
  with an inner label plate that collapses into mush at 14px. `download` is the arrow-into-tray
  glyph. The failure mark is `alert`, a circle with a bang, not a triangle.

### App icon — settled, and the numbers that keep it settled
`assets/icon.png` is RGBA on Apple's macOS template: a **1024² canvas with the artwork occupying
824² centred, i.e. a 100px transparent margin on all four sides** (80.5%). Measured from the
packaged `AppIcon.icns`, all ten rungs 16→1024 carry alpha at the right dimensions.

macOS does NOT mask app icons the way iOS does, so this margin is the whole mechanism: an
opaque full-bleed square renders as a square tile with a smaller squircle floating inside it,
which is exactly what the earlier art did. **Any replacement must keep the 824/1024 ratio and the
transparency** — `design/icon-original.png` is the pre-fix source, kept for comparison. Nothing in
`build.zig` or `app.zon` is involved beyond the path; the geometry is the entire contract.

## Testing and verification strategy
Two tiers, in this order. Reaching for the GUI to answer a question a unit test answers faster is
the failure mode to avoid.

**Tier 1 — `native test` (`src/tests.zig`, `src/imageio_tests.zig`).** Deterministic, no GUI, no
processes, no network. This is where logic gets proven. The markup/model seam is driven through the
real dispatch path: build the markup against the real `Model`, find a widget, ask the tree for the
`Msg`, feed it to `update`. Effects-bearing paths drive `Effects` in fake-executor mode
(`fx.executor = .fake`, via the `Harness`) — assert the *request* an arm made, then feed the answer
and drain. ImageIO and the real encoders are reachable here, because `build.zig` states the
frameworks and archives on the test module too.

**Every new assertion gets mutation-checked, not just run green.** Break the thing it claims to
pin and confirm it fails — exactly one test, and the right one. A test that cannot fail is worse
than none, and this discipline is what caught the format-mid-encode gap, a backwards `file.copy`
payload, and two reset-guard tests that passed with the guard deleted.

**Tier 2 — `native automate` against `native dev`.** Proves the real seam end to end. `native build`
is ReleaseFast and has neither automation nor hot reload.

**Fixtures are gitignored**, so tier-1 tests must never read `test-images/`. Anything image-shaped
uses in-repo bytes: embedded PNG literals, or `canvas.png.writeRgba8` plus
`harness.null_platform.image_decode = true` for the decode→register→draw path.

**Every change ends with a check against the RUNNING app.** `native build` and `native check` are
necessary and never sufficient. `native automate widget-click` drives the real UI for anything
reachable without a native dialog or a real file drop; **the two things that cannot be automated at
all — a native dialog and a real file drop — are CLAUDE.md's "Two standing rules about
automation"**, which is canonical for both. Do not restate them here.

- Test fixtures live under `test-images/` (gitignored); `docs/phase-b-baseline.md` carries the
  recipe for regenerating each one and the inventory of what each proves.
- **`docs/phase-b-baseline.md` is append-only.** It is the ±15% parity gate, recorded before any of
  the native encode work and impossible to reconstruct afterwards. Every change to the encode path
  is re-checked against it, and **chroma subsampling is part of the check** — a size-and-PSNR match
  with the wrong `yuvFormat` is a failure.
