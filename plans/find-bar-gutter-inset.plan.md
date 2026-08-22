# (find-bar-gutter-inset) Inset the find bar's controls past the line-number gutter

**Risk tier: `standard`.** Two files, no control flow, no state, no persisted
value — but it is a *layout contract* change (a second consumer of the live
gutter width) with a decision surface the item explicitly asked to have settled,
so it gets a plan file and one behaviour review rather than an inline one-liner.

## Goal

The find bar's controls start at the same x as the file name above them and the
first text column below them, instead of hanging a full gutter-width to the left
over the line-number gutter.

## What is actually true at HEAD (checked, not taken from the item)

- `ContentView.editorColumn` (`Views/ContentView.swift:363-380`) stacks, in one
  `VStack(spacing: 0)`: `ColumnHeaderBar(title: name, leadingInset:
  editorGutterWidth)`, then `FindBar(...)` when `workspace.isFindBarVisible`,
  then `CodeEditorView`.
- `ColumnHeaderBar` (`Views/ColumnHeaderBar.swift:38-46`) applies
  `.padding(.leading, leadingInset + 8)` — the 8 pt is *on top of* the inset, and
  its doc comment states that contract.
- `FindBar` (`Views/FindBar.swift`, modifiers at the end of `body`) applies a
  flat `.padding(.horizontal, 8)` and never sees `editorGutterWidth`.
- `editorGutterWidth` is `@State` on `ContentView`, written from
  `CodeEditorView`'s `onGutterWidthChange`, which `makeNSView` routes through a
  `DispatchQueue.main.async` hop (`Editor/CodeEditorView.swift:195-202`) both for
  the seed value and for every `ruler.onThicknessChange`.
- The gutter's own width is `ceil(widest-label width) + 2 × 4`
  (`LineNumberRulerView.updateThickness`, `horizontalPadding = 4` — the item
  guessed 2; it does not change the conclusion).

Measured off `plans/find-bar-gutter-inset-repro.png` (a 2× screenshot) to
confirm rather than assume: the header strip's hairline is at y=116–117 and the
find bar's at y=178–179, so the bar is 31 pt tall; the ruler's own background
(`NSColor(white: 0.95)` = 242) starts at x=617 and ends at x=666, i.e. a 25 pt
gutter; the Find field's border starts at x=647, which is *inside* that band.

## Acceptance criteria

1. `FindBar` takes a `leadingInset: CGFloat = 0` property and applies
   `.padding(.leading, leadingInset + 8)`, `.padding(.trailing, 8)` — the same
   shape `ColumnHeaderBar` uses, so the two strips cannot drift apart.
2. `ContentView.editorColumn` passes `leadingInset: editorGutterWidth`, the same
   expression it already passes to `ColumnHeaderBar` on the line above.
3. The bar's **background and hairline still span the full column width** —
   only the controls indent.
4. Default argument stays `0`, so a `FindBar` rendered anywhere else is
   unchanged.
5. `xcodebuild` green; all 12 harnesses green (none of them touch SwiftUI —
   this is a build-only gate by construction, stated so it is not mistaken for
   test coverage).

## Decisions taken

**2026-08-22 — the background spans, only the content indents.**
The item left this open. Decided: span. Three reasons, in order of weight.
(a) `ColumnHeaderBar` already resolves the identical question the same way — its
background and hairline are applied *after* `.frame(maxWidth: .infinity)`, so
only its title indents; making the find bar differ would put two strips with the
same hairline at the same boundary on two different rules. (b) The bar's hairline
must meet the column's left edge, because it is the top boundary of the editor
pane as a whole, and a hairline starting 25 pt in would leave a notch above the
gutter. (c) The gutter's own background begins immediately below that hairline;
an indented bar background would expose a bare column-width strip of window
background to the left of it. *Alternative rejected:* indenting the background
too, which would have read as "the find bar belongs to the text pane" — but it
does not; it is chrome for the whole column, which is why it also carries Done.

**2026-08-22 — no animation suppression, and none is needed.**
The item asked that the field not visibly jump or animate when the gutter grows
while the bar is open. `editorGutterWidth` is written from a bare
`DispatchQueue.main.async` closure with no enclosing `withAnimation`, so SwiftUI
attaches no implicit animation to the resulting padding change; the value lands
in the same layout pass for the header strip and the bar, because both read the
one `@State`. Decided: add nothing — no `.animation(nil, value:)`, no
`.transaction` scrub. *Alternative rejected:* pre-emptively disabling animation
on the padding, which would be a modifier defending against a transaction that
does not exist and would then have to be kept in sync with `ColumnHeaderBar`,
which has run without one since (column-header-bars) shipped. The header strip
is the existing proof: it has been consuming this exact value through this exact
hop, and no jump has been reported against it.

**2026-08-22 — no lower bound / no `max(0,)` guard.**
`ruleThickness` is `ceil(width) + 8` and can never be negative, and the property
defaults to `0`, so a clamp would be dead code.

## Out of scope

- The gutter's own top-boundary overflow — that is (gutter-top-overflow), a
  separate item touching a disjoint file.
- The trailing edge: the Done button stays 8 pt from the column's right edge,
  which is already flush with the preview divider and matches every other strip.
- Any SPEC edit. §6.5 specifies the bar's controls, not its metrics.

## Revert

One commit, two files, no data or persisted state involved. Reverting restores
the flat 8 pt padding exactly.

## Decisions taken — round 2, after `adv-review-behavior`

**2026-08-22 — finding 1 (Medium, "the inset raises the bar's minimum column
width") is REAL, is pre-existing, and is filed rather than fixed here.**
The reviewer's mechanism is verified against source by me: `FindBar`'s controls
carry hard floors — `TextField(...).frame(minWidth: 120, …)`,
`Text(findCountLabel).frame(minWidth: 90, alignment: .leading)`, a `Toggle` and
a `Button` at intrinsic width, `HStack(spacing: 8)`, and `Spacer(minLength: 0)`
— so below some column width the stack cannot compress, reports a size larger
than its proposal, and `.frame(width: editorWidth)` in `ContentView` centres
rather than clips it. Adding `leadingInset` to the leading padding raises that
threshold by exactly `gutterWidth` (~20 pt for a short file at the default font
size, ~107 pt for a 6-digit document at `EditorMetrics.maxFontSize = 32`).

Not fixed in this item, for a reason that is checkable rather than a preference:
the threshold is **already exceeded at the default window size**. `LayoutMetrics`
gives `defaultWindowWidth = 1100` and `defaultSidebarWidth = 1100/3 ≈ 366.7`,
and the editor/preview split defaults to half the remainder, so the default
editor column is ≈ 365 pt — below the ≈ 398.5 pt minimum the reviewer measured
off the repro screenshot *at HEAD, with no inset at all*. So this is not a
regression this change introduces; it is a pre-existing narrow-column defect
that this change makes reachable at more widths. Fixing it means deciding how
the bar degrades (drop the count label's floor? let the checkbox go icon-only?
clip instead of centring?), which is a different item with a different
acceptance surface. Filed as (find-bar-narrow-column) with the arithmetic.
*Alternative rejected:* clamping the inset to some fraction of the available
width — it needs a `GeometryReader`, it would misalign the bar from the header
strip exactly when the window is tight (the one thing this item exists to fix),
and it would paper over the pre-existing overflow rather than resolve it.
The threshold arithmetic is the reviewer's, measured off the screenshot; what I
verified independently is the mechanism (the hard floors and the `Spacer`) and
the default-window numbers above.

**2026-08-22 — finding 2 (Nit, the query TEXT still sits ~4 pt right of the file
name) accepted as correct and deliberately not chased.**
`TextField`'s rounded bezel and focus ring consume ~3.5 pt before the text
begins, so matching the *frame* edges — which is what criterion 1 asks for and
what `ColumnHeaderBar` does — leaves the glyphs slightly right of the title's.
Compensating would mean subtracting a magic bezel constant that AppKit does not
publish and that changes with control size and OS version. Recorded here so it
is not re-filed as a new bug after someone compares the two edges in a
screenshot.

**Not accepted:** nothing. Both findings are real; one is filed, one is
documented.
