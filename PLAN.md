# Smoosh — PLAN.md

> Living plan: decisions still in force, requirements the code must keep satisfying, and what is
> still open. This file and `docs/phase-b-baseline.md` are the engineering record between them —
> `CHANGELOG.md` is written for users and carries no reasoning. Update this file as decisions are
> made; add a user-facing line to the changelog as work ships.

## Vision (one sentence)
A beautiful, instant native macOS app that lets you drop an image and get back high-quality modern
web formats (AVIF and/or WebP) without leaving your desktop.

## Status
**v0.6 — feature-complete and zero-dependency.** Pick, drop or paste an image, choose AVIF/WebP/Both,
Smoosh writes the outputs itself and says where they went; each landed result row carries its own
save icon to copy that one file elsewhere. Ships as an ad-hoc-signed `.app`.

**Where the outputs go is decided per file, before the run** — beside the source when that folder
takes a write, the Desktop for a screenshot stranded somewhere read-only, and nowhere-but-Save-As
otherwise (see `Destination` in `src/main.zig`). An ephemeral source is copied into the app cache
first, so a screenshot dragged off its floating thumbnail survives macOS deleting it mid-run.

The whole pipeline runs in-process: Apple ImageIO reads (`src/imageio.zig`), vendored static
libavif/libaom/libwebp write (`src/encoders.zig` over `src/encode.c`), and the encode runs on a
worker thread so the window keeps painting. **The app spawns no subprocess and needs nothing
installed.**

What is left is the standalone-app gaps — see "Roadmap".

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
  than none: `avif` was missing through v0.5 and greyed out real, decodable images.
- Real window-wide drag-and-drop via `UiApp.Options.on_drop`, which re-enters the exact same load
  chain a picked file does.
- Cmd+V, via a registered `platform.Shortcut` and `Options.on_command` — a file URL on the
  pasteboard loads like a pick, raw pixels are written into the cache and filed to the Desktop. See
  "Clipboard paste" under Roadmap for why neither the SDK's clipboard seam nor `on_key` could carry
  this.
- Accepts what macOS ImageIO decodes: JPEG, PNG, WebP, AVIF, HEIC/HEIF, TIFF, GIF, BMP — the same
  set through all three ways in, because only the probe decides.

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

## Testing strategy
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

## Verification strategy
Every change ends with a check against the *running* app, not just a compile check. `native build`
and `native check` are necessary and never sufficient.

- `native automate widget-click` drives the real UI for anything reachable without a native dialog
  or a real file drop.
- **Never automate a native file dialog** (open or save panel). The app runs as a bare executable
  under `native dev`/`native build`, and System Events cannot bring it frontmost, so global
  keystrokes land on whatever IS frontmost instead — this already typed a stray path into a live
  session once. Have the user drive every dialog by hand.
- **File drops cannot be automated at all** — a different constraint, same practical answer: have
  the user drag a real file onto the window by hand.
- Test fixtures live under `test-images/` (gitignored); `docs/phase-b-baseline.md` carries the
  recipe for regenerating each one and the inventory of what each proves.
- **`docs/phase-b-baseline.md` is append-only.** It is the ±15% parity gate, recorded before any of
  the native encode work and impossible to reconstruct afterwards. Every change to the encode path
  is re-checked against it, and **chroma subsampling is part of the check** — a size-and-PSNR match
  with the wrong `yuvFormat` is a failure.

## Known limitations
- **"Both" decodes the source twice.** The two formats are two independent `image.encode` workers —
  that independence is the partial-failure decision — and each calls `imageio.decode` on the same
  file. The cost is **peak memory, not latency**: two full-resolution RGBA buffers live at once, up
  to ~400 MB at the 50 MP guard. The two decodes run concurrently on separate threads. Sharing one
  decode would mean a refcounted buffer outliving both slots — real complexity for a memory win
  only, so this is a deliberate trade.
- **arm64 only.** The vendored archives are non-fat arm64-macos; producing an x86_64 or universal
  build is unexplored. A genuine gap the moment the `.app` is handed to anyone else.
- **Launch time has never been measured.**

## Roadmap
Three tracks, independent of each other. Each carries a model/effort suggestion — judgment calls
about how much of the work is taste versus mechanism, not benchmarks.

### 1. Performance
**Measure before touching anything.** The app is already effectively instant on normal photos, and
optimizing without a number is how the parity gate gets perturbed for nothing. Every change here
must be re-checked against `docs/phase-b-baseline.md`.

Ranked by payoff-to-risk:
- **`drawToRgba8`'s `@memset(pixels, 0)`** — a full-buffer write, up to 200 MB, redundant because
  our transforms always cover the whole destination. Cheapest real win, no parity risk.
- **`encoder->maxThreads = 1`** — the single biggest wall-clock lever on large photos. Set for
  determinism while parity was being established; parity is banked now, so this is re-measurable as
  a decision rather than a constraint.
- **libaom rebuilt `-Os` instead of `-O3`** — Homebrew's is 5.4 MB against our 8.1 MB, so this
  meaningfully cuts the 10.94 MB binary. Needs a full parity re-measure: libaom's rate control
  carries FP math and optimization level can change contraction.
- **`copy_out`'s extra malloc+memcpy** of the whole encoded buffer in `src/encode.c` — tidy, low
  payoff, zero risk.
- **The Both-mode double decode** — see "Known limitations". Memory, not latency.

*Suggested: **Opus 5, medium** for the measuring and the first two items; **high** if touching
encoder settings or rebuilding an archive, where the parity judgment is the whole task.*

### 2. UI and style polish
**Shipped as v1 of the UI.** The canvas is the ORIGIN of this design, no longer a description of
it — 12 window states across light and dark, plus three sheets (design tokens, the result row, the
footer): <https://claude.ai/code/artifact/682de599-1cc7-4306-aac0-bbf9d886c2e6>

**The board is now behind the app.** Iterating against it means reading "Where the build left the
board" below first; every entry there is a place the drawn spec and the running app disagree, and
in each the app is deliberate. Re-seeding the board from the built UI is the obvious next move
before another visual pass.

Constraint respected: the app is meant to live in a corner of the desktop, so it must stay correct
at `window_min_width` (420). That floor is a TEST, not a comment — `tests.zig` lays the tallest
state (both formats landed) out at 420x400 and fails naming the overflow in points. The 144px
preview frame is what pays for everything else and is load-bearing.

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

**What the markup cannot express** — every one of these was found by reading the SDK source after
drawing something that could not be built:
- **A `<panel>` strokes a hairline and casts a shadow whether or not you ask.**
  `emitPanelWidgetChrome` always emits both and no attribute declines them, so the drop zone and
  preview frame get their wash-only treatment from `controls.panel.stroke_width = 0` and a zeroed
  `shadow.sm`. There is no dashed stroke anywhere in the SDK either. A `<badge>` DOES draw its own
  border, but ONLY `variant="outline"` — there is no badge stroke-width attribute — so the savings
  badge's 30–70% weight is `outline` and the other two are borderless by construction.
- **`<status-bar>` is a BAND, not a line.** It fills its frame with `surface`, draws its own top
  hairline, and insets text 14pt with no way to clear it (`padding="0"` falls back to the default).
  That is the filled-footer treatment this design rejected, and it broke the left edge. The status
  line is a plain `<text>`; one widget, one id, one colour either way.
- **`<span>` carries no `foreground`** (only weight/scale/mono/italic/underline). A two-tone result
  line needs separate `<text>` widgets and a model method per half — `resultLine` split into
  `avifSize`/`avifSavings` and their WebP twins.
- **`padding` is a single uniform number.** No per-side values anywhere. A result card's left inset
  is a leading `<spacer width="2">` and its height is stated outright, because 10pt of padding
  would be 10 top and bottom too.
- **`<toggle-group>` paints nothing at all** (an explicit no-op arm in the render switch). The
  segmented track is a `<row background="surface_pressed" radius="md" padding="1">` wrapped around
  it. The thumb needs no styling — a ghost `toggle-button` is already transparent at rest and
  `surface_subtle` when selected.
- **A ghost variant resolves ONE `foreground` for both states.** `active_foreground` is consulted
  only for `default` and detached-group members, and `foreground` is a token-NAME attribute that
  takes no binding — so the board's muted-unselected/full-ink-selected segments cannot be built
  without an `<if>` inside the `<for>` and the widget-identity collision that causes. All three
  segments take full ink, which is also what macOS does: the thumb marks the selection, not the ink.
- **No per-widget shadow, and no letter-spacing.** The label stays "Format" rather than a
  tracked-out FORMAT.
- **`background` takes a token NAME, not a hex** — and a `<badge>` ignores `background=` entirely.
  A badge fill comes only from `variant`: `outline`/`ghost` are transparent, `destructive` is a
  translucent wash (spoken for by the failure mark), and `default`/`primary` paint a solid fill
  read from the `accent` STYLE channel (`accent_foreground` for the ink). So the savings badge's
  70%+ "win" weight is `variant="primary" accent="success" accent-foreground="success_text"` — a
  solid lilac chip with knockout ink — not `background="success"`, which renders as invisible
  surface-on-surface text. Two more badge gotchas: a badge with no `radius` falls back to a
  height/2 FULL pill on its fixed 20pt frame (every arm states `radius="sm"`, which is 6 — see the
  radius bullet below), and `variant="outline"` pulls its ring from `tokens.colors.border` (grey) —
  `foreground` only colours the text — so the 30–70% weight also needs `border-color="success"` to
  ring in lilac.

**Where the build left the board.** Read this before iterating — each is measured, not a drift.
- **Light `text_muted` is `#6B6773`**, the value the drawn states use, not the `#75717C` the token
  sheet lists. The lighter value measures 4.25:1 on `surface_subtle`, and muted ink lands on that
  surface constantly (the drop zone's hint, every result row's size figure).
- **The creams are warmer than the sheet.** `surface_subtle` `#F7F1EA` → `#F4ECDF` and
  `surface_pressed` `#EAE1D3` → `#E7D7C7`. Not a correction — the sheet's values render exactly as
  drawn — but a compensation for WHERE they render: on the canvas that patch sits inside a cream
  window on a warm page and every neighbour confirms its warmth, while in a 540pt window on someone
  else's desktop the same field has nothing warm near it and 13 points of red-over-blue reads as
  grey. The ceiling is the track: past about `#F3EADB` for the cards it stops separating from them.
  The track also went three points DARKER, because warming the cards had squeezed it to ΔL* 3.81.
- **The peach is `#F2B79A` in both schemes**, deeper and slightly more saturated than the
  `#F8CDB7` it replaced (which was itself `#F3B89A` + 6 L*). `#F8CDB7` cleared ΔL* ~11.8 on the
  dark ground and read as a pale glowing bar with no body; `#F2B79A` drops ~5 L* and adds chroma so
  the one saturated fill carries weight. This walks back the "muddy tan" objection to the darker
  peach — at the button's size, against neutral desktops, and with one value serving both schemes,
  body beats brightness. Still ONE value across light and dark: peach does not flip. Knockout ink
  clears 8.1:1 either way.
- **ONE outer radius, 10, on everything a hand lands on** — the segmented track, every button, and
  a result card. The board draws the track at 8 against a 10 button, and side by side that reads as
  a mistake rather than a distinction. The thumb keeps the board's one-step-in relationship (track
  minus its own padding, so 8). Surfaces keep their own scale: preview frame 12, drop zone 16. The
  `sm` step is 6, not 8: it is the savings badge's corner, and on the SDK's fixed 20pt badge frame
  an 8pt corner reads as a pill where 6pt is the 30%-of-height rounded rect the 34pt result row
  (10pt corner, 29%) sits it beside.
  **The track will still look slightly larger than the buttons and that is structural**: it is the
  segment height plus its padding, so it is always taller than the control inside it, and the same
  arc on a taller shape reads differently. Measured and confirmed identical — the probe was setting
  `radius.md` to 20, which moved the track and not the button.
- **The action buttons are 30pt tall and Smoosh is 88 wide.** `size="sm"` IS 28, so the buttons
  cannot reach the track's height through the rungs; both state it. Smoosh's width comes from
  `min-width` on that one button rather than `button_inset_sm`, which would widen Reset, both Save
  buttons and every segment with it — and the row has ~17pt of slack at the 420pt floor.
- **The type scale is three sizes and no more**: 14 (file name, drop-zone headline), 13 (everything
  else, labels and button text alike), 12 (the savings badge). `button_label_sm_step` is 1, not the
  house 1.2, so `sm` button labels land on 13 with the text beside them instead of 12.8.

**The contrast check is in the test suite**, over the real `tokens_fn` values: every adjacent
surface pair at ΔL* ≥ 3 and in the right DIRECTION, every drawn text pair at 4.5:1, the spinner at
3:1. Mutation-checked in both directions — restoring the `#17171C` dark track reports 2.07 L*,
restoring `#75717C` reports 4.25:1, and lifting the track above the thumb reports the direction
failure. The pairs asserted are the pairs the markup DRAWS, not the cross product of the palette.

**Verified live, not from source.** Every claim above was checked against the running app through
`native automate` — widget frames for geometry, framebuffer samples for colour, and a token probe
where the two could not be told apart by eye. Two things remain unverifiable from here and need a
person: **a real file drop** and **any native dialog** (see CLAUDE.md's two standing rules).

### 3. The standalone-app review
The umbrella, not a task. The correctness half was covered by the Phase B review (2026-08-30) —
one real bug found and fixed (the case-insensitive `same_path` collision). What it did NOT touch is
the last four "Known limitations" above: **arm64-only**, **notarization** (currently ad-hoc
signed, fine for one machine and not for distribution), **the icon's Dock shape** (now a scoped
session in §4), and **launch time**.

*Suggested: **Opus 5, high**, or run `/code-review ultra` for the correctness sweep — it is
user-triggered and billed, so it cannot be launched from inside a session.*

### App icon — settled, and the numbers that keep it settled
`assets/icon.png` is RGBA on Apple's macOS template: a **1024² canvas with the artwork occupying
824² centred, i.e. a 100px transparent margin on all four sides** (80.5%). Measured from the
packaged `AppIcon.icns`, all ten rungs 16→1024 carry alpha at the right dimensions.

macOS does NOT mask app icons the way iOS does, so this margin is the whole mechanism: an
opaque full-bleed square renders as a square tile with a smaller squircle floating inside it,
which is exactly what the earlier art did. **Any replacement must keep the 824/1024 ratio and the
transparency** — `design/icon-original.png` is the pre-fix source, kept for comparison. Nothing in
`build.zig` or `app.zon` is involved beyond the path; the geometry is the entire contract.

### 4. Deferred features — each its own session
One real want. The latent bug this list carried (the screenshot that vanished mid-run) and the
read-only-folder problem coupled to it are both fixed; the app-icon item is done too.

- **Read-only source folders, and the screenshot-that-vanishes bug.** Two coupled problems, both
  invisible from a Terminal `native dev` run (the responsible process is the terminal, which
  already holds the TCC grants) and both real once packaged.

  *The read bug — **SHIPPED** (step 1 of the build order below).* An ephemeral source is now copied
  into the app cache dir before anything reads it. `isEphemeralSource` (pure, in `main.zig`)
  classifies the path; an ephemeral one gets one extra hop ahead of the stat — the `file.stash`
  host command, which deletes and remakes `Library/Caches/smoosh/staged`, copies the bytes in, and
  answers with the copy's path. `Model.readPath()` is what `image.probe`, `image.thumbnail` and
  `image.encode`'s SOURCE field read; `Model.path()` stays the original, and remains what the file
  card names, what `outputPath` derives the destination from, and what `beginEncode`'s `same_path`
  guard compares against. Only the read moves. Ordinary sources are untouched and issue no stash at
  all.

  *The write destination — **SHIPPED** (steps 2 and 4).* Classified UP FRONT rather than retried
  after a failed write, because a blanket retry cannot tell a screenshot's staging directory apart
  from a read-only USB stick and would drop files where nobody asked. The last hop of the load chain
  is `file.destination`, which probes the SOURCE's folder with a real create-and-unlink (nothing
  short of a real write is honest — a folder can be mode 0755 and yours and still refuse, on a
  read-only mount, a full disk, an ACL or a sandbox denial) and returns that flag plus the two
  directories `update` cannot derive itself. `update` owns the policy over those facts, as
  `Model.Destination`:
  - **`.beside_source`** — the folder took the write. Today's behaviour, `destDir` empty.
  - **`.desktop`** — read-only AND `looksLikeScreenshot` (basename `Screenshot*`, or a
    `screencaptureui` path). `outputPath` keeps the NAME and replaces the DIRECTORY.
  - **`.ask`** — read-only, nothing else. Outputs are encoded into `Caches/smoosh/outbox` and Save As
    is the only way out; `canReveal` is false and the status line refuses to claim a save.

  A failed or malformed probe reply is NOT a load failure — it degrades to `.beside_source`, i.e.
  exactly the behaviour that predates the probe, and a write that then cannot land still reports
  `.write_failed` with the folder-permissions message.

  Still deferred inside this: a CUSTOM `com.apple.screencapture location` is not read (that needs a
  `CFPreferencesCopyAppValue` binding, since the app spawns no subprocess), so `.desktop` is
  literally `~/Desktop`. And `looksLikeScreenshot` does not chase LOCALIZED screenshot names — a
  German "Bildschirmfoto …" already filed in a read-only folder falls to `.ask` and gets a Save As
  rather than a wrong guess, which is the safe direction to be wrong in.

  *Packaging (step 3) — **NOT NEEDED for correctness; the premise was wrong**.* This item read
  "`NSDesktopFolderUsageDescription` in `app.zon`, or the Desktop write fails with no prompt."
  Both halves are false, and both were checked rather than reasoned about.

  **Measured** on macOS 26.6.2, against a packaged ad-hoc `.app` (`native package --target macos`)
  with the grant reset between runs (`tccutil reset SystemPolicyDesktopFolder dev.native_sdk.smoosh`)
  — the packaged app is the responsible process, which is what makes this the real test and a
  `native dev` run useless for it:
  - The bundle carries NO usage-description key (confirmed by reading the generated
    `Contents/Info.plist`), and macOS still PROMPTS: *"Smoosh.app" would like to access files in
    your Desktop folder.* The key is not a gate for the Desktop folder — unlike camera/microphone,
    where a missing key is fatal. All it would add is the explanatory sentence under the title,
    which is currently absent.
  - **Allow** → both outputs land on the Desktop.
  - **Don't Allow** → nothing is written and the run reports `.failed` with "Couldn't write to that
    folder — check its permissions." (the both-formats collapse branch). No false "Saved to
    Desktop." over files that do not exist.

  So this is a COPY nicety, not a blocker, and the destination split ships without it.

  If the reason line is ever wanted: the key still cannot be stated in `app.zon` —
  `tooling/package.zig`'s `macosInfoPlist` builds `Contents/Info.plist` from a fixed template whose
  only privacy strings come from `macosPrivacyUsageDescriptions`, hardcoded to the `microphone` and
  `system_audio` permissions; there is no arbitrary-key passthrough in `app_manifest/types.zig` and
  no user plist fragment is read. `build.zig` cannot reach it either, since packaging is CLI-side.
  The cheap route is a post-package `plutil -insert`, and it needs NO re-sign: `codesign -dv` on the
  packaged bundle reports `Info.plist=not bound` and `Sealed Resources=none`, because the ad-hoc
  signature is linker-signed and covers only the Mach-O. The proper route is an SDK passthrough,
  which is not this repo's to make.

  *The write-failure sentence follows the destination — **SHIPPED**.* The generic "check the
  folder's permissions" is only true for `.beside_source`. Aimed at the Desktop it was actively
  misleading (a TCC denial is not a `chmod` problem — the folder IS writable and the app was
  refused by Privacy & Security, so the user inspects Get Info, finds nothing wrong, and is stuck);
  aimed at the app's own cache it was meaningless, since the user cannot act on our cache
  directory's permissions at all. Two fns now carry it — `writeFailureAdvice` for the per-format
  sentence and `writeFailureCollapsed` for the both-failed one — and their remedies agree per
  destination, pinned separately because they can drift independently:

  | destination | one format | both formats |
  |---|---|---|
  | `.beside_source` | `Couldn't save the AVIF — check the folder's permissions.` | `Couldn't write to that folder — check its permissions.` |
  | `.desktop` | `Couldn't save the AVIF — check Privacy & Security.` | `Couldn't write to your Desktop — check Privacy & Security.` |
  | `.ask` | `Couldn't save the AVIF — the disk may be full.` | `Couldn't write the compressed files — the disk may be full.` |

  The collapsed forms are not the per-format sentence with the label removed: "Couldn't write to
  that folder — check the folder's permissions." says folder twice, and the Desktop one NAMES the
  Desktop because the user never chose it and "that folder" would point at nothing they have in
  mind. A test pins every one of the six at or under the status line's ~65 characters — the bar
  elides rather than wraps, and the clause that says what to do is the half that would be lost.

  Build order: (1) the read fix standalone — **done**; (2) the writability-probe destination split —
  **done**; (3) the plist string — **dropped, premise disproved above**; (4) the status-line copy —
  **done**. This item is closed.

- **"Saved to Desktop." for the special-cased writes — SHIPPED** (step 4 of the item above).
  `statusLine`'s `.done` arm now switches on `Destination`: `Done.` beside the source,
  `Saved to Desktop.` for the screenshot rescue, and `That folder is read-only — save a copy.` for
  `.ask`, which deliberately refuses to claim a save that did not happen. A lost format still wins
  the line over any of them — the loss is what the user has to act on. For the record, the
  "Show in Finder" control had already SHIPPED —
  the footer reads `Done.` beside a hover-lit label that opens Finder with every output of the run
  selected (`shell.reveal` → `NSWorkspace`, `src/workspace.zig`). It deliberately points at the
  AUTOMATIC write and never follows a Save As: a user who drove a save panel already knows where
  that copy went, and the button exists to unveil the write nobody was asked about.

  What is still owed is the COPY: when the destination is not source-adjacent the line must read
  `Saved to Desktop.` instead of `Done.` That string cannot exist until the writability-probe
  destination split ABOVE lands, because until then everything is written beside the source. Build
  it as one arm of that classification, not before.

- **Clipboard paste (Cmd+V) — SHIPPED in v0.6.** Both payload shapes land, through one host
  command (`clipboard.paste`) answering `"<nominal>\x00<read>"`, which `parsePasteReply` splits.

  **The SDK's clipboard seam turned out to be a dead end, for two independent reasons.**
  `PlatformServices.readClipboardData(mime_type, buffer)` looks like the call and is not: its macOS
  mime map (`NativeSdkPasteboardTypeForMime`) resolves `text/plain`, `text/html` and `text/rtf` and
  returns nil for everything else, so an `image/png` read is unrepresentable rather than merely
  awkward — and `max_clipboard_data_bytes` is 64 KiB anyway. `src/pasteboard.zig` is therefore an
  Objective-C seam of its own, `workspace.zig`'s sibling. The bytes never enter the process:
  `-[NSData writeToFile:atomically:]` does the copy, which is what keeps a multi-megabyte static
  buffer out of the tree and makes the write atomic for free.

  **Cmd+V could not go through `on_key`** either, which is where every other key in this app lives.
  AppKit resolves key EQUIVALENTS against the menu bar before the responder chain, so the standard
  Edit menu's Paste claims the chord and the surface's `keyDown:` never runs; the SDK's canvas view
  answers that menu item by re-emitting the chord only when a text widget has focus, and this window
  has none. `RuntimeOptions.shortcuts` + `Options.on_command` is the working seam — it installs a
  local `NSEventMaskKeyDown` monitor that runs before `NSApp.sendEvent:`, so nothing downstream can
  claim the event first. `main.zig`'s `app_shortcuts` carries the account.

  The two shapes:
    - **a file URL** (an image copied in Finder) → answered with an empty `read`, so it takes the
      ordinary `beginLoad` — the ephemeral stash included, since a file copied out of /tmp is as
      perishable as one dragged from there;
    - **raw bytes** (a `Cmd-Ctrl-Shift-4` screenshot, "Copy Image" in a browser) → written into the
      cache `staged` slot, and paired with an INVENTED nominal path on the Desktop. That reuses
      `Model.stash_path_buffer`'s existing split (the run is ABOUT one path, it READS another)
      rather than adding a second mechanism, and it is what puts the outputs somewhere durable
      instead of in the purgeable cache. The nominal name is a LOCAL timestamp
      (`smoosh-2026-09-10-143005`), so two pastes cannot clobber each other's outputs and a Desktop
      full of them says which is which. A re-press of Smoosh on the same pasted image deliberately
      reuses the name — it is fixed at paste time, which is what makes a redo a redo.

  The raw-bytes flavours are PNG, JPEG, WebP, AVIF, TIFF, in that order — **the producer's own
  encoded bytes over anything re-rendered**, with TIFF last because it is what macOS hands over once
  it has re-rendered the picture, uncompressed and stripped of the JPEG entropy data `chroma.zig`
  reads. WebP and AVIF are there for completeness only: every browser re-encodes to PNG when it puts
  an image on the pasteboard, verified by reading `NSPasteboard.types` directly — an image copy
  carries `public.png`/`public.tiff`, a JPEG copy `public.jpeg`/`public.tiff`, and nothing else.
  (AppleScript's `clipboard info` lists AVIF, GIF, BMP and more; those are its own *coercion
  candidates*, not pasteboard flavours, and reading them as flavours will mislead you.)

  An empty or text-only pasteboard is `.failed` with "No image on the clipboard." and deliberately
  does NOT clear a loaded file: nothing was acquired, so nothing was replaced.


**Not planned — Dock-icon / Finder drop.** macOS delivers Dock-icon drops and "Open With" through
`application:openURLs:` (an `odoc` Apple Event), a different channel from the drag machinery
`on_drop` uses. It would need `CFBundleDocumentTypes` / `LSItemContentTypes` in `app.zon` AND an
openURLs hook reachable from the hand-authored root — and `runMacos`'s document handling is
non-`pub`, so that may not exist without platform-layer work. It also only applies to the packaged
`.app`. Set aside: the payoff over a window drop is thin, and the "type `smoosh`, drag a file in"
workflow it is usually wanted for is the CLI's job (below). Revisit only if an openURLs hook proves
to be a one-liner.

## A Smoosh CLI — beyond the app
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
