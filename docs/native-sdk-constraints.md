# What Native markup cannot express

A catalogue of Native SDK limitations that shape Smoosh's UI, **every one of them found by reading
the SDK source after drawing something that could not be built.** They are recorded here rather
than in `CLAUDE.md` because you need them at the moment a design refuses to build, not before you
start — `CLAUDE.md` carries only the traps that must be known in advance.

Two companions: `CLAUDE.md`'s "Hover ink, and the three painters" is the one markup limitation
important enough to be read up front; PLAN.md's "Design decisions" records what Smoosh chose to do
about the constraints below, and `docs/design-board.md` records where the built app ended up
differing from the design canvas.

**These describe `native` CLI 0.10.1.** An SDK upgrade can retire any of them; nothing here is
enforced by a test, so treat an entry that no longer reproduces as out of date rather than as a
rule.

## The constraints

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
