# Where the build left the design board

Every place the drawn spec and the running app disagree — **each one measured, and in each the app
is deliberate.** Read this before another visual pass; treat a difference as a decision already
taken, not as drift to correct.

The design canvas is the ORIGIN of this design, no longer a description of it: 12 window states
across light and dark, plus three sheets (design tokens, the result row, the footer).
<https://claude.ai/code/artifact/682de599-1cc7-4306-aac0-bbf9d886c2e6>

**The board is behind the app**, and re-seeding it from the built UI is the obvious first move
before another visual pass. It slipped one step further when v0.6 moved the drop zone's two lines —
copy, not geometry, so nothing measured here changed.

Two companions: PLAN.md's "Design decisions" holds the palette and geometry choices still in force
(and the layout floor, which is a test), and `docs/native-sdk-constraints.md` catalogues what the
markup cannot express at all.

## The differences

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

