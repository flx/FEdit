# (find-bar-narrow-redesign) Wrap the find bar to a second row when the column is narrow

**Risk tier: `standard`.** A layout change to a shipped UI surface plus a new
parameter threaded from `ContentView`, but no state, no behaviour, and no SPEC
change.

## The decision, and who made it

Felix chose, from four options filed with the item: **wrap the count readout and
Done onto a second row below a threshold width**, over an icon-only checkbox
(which would need a SPEC §6.5 change, since §6.5 names a *visible* Case
sensitive checkbox), over folding the readout into the query field (a visible
change at every width, not just narrow ones), and over horizontal scrolling
(which can hide Done outright). Recorded here because it is the one decision in
this item that was not mine to take.

## What ships

- `FindBar.singleRowMinimumWidth = 340` — the measured single-row floor,
  excluding the gutter inset.
- `FindBar.availableWidth`, defaulting to `.infinity`, passed by `ContentView`
  from the same number it already uses for the column's own `.frame`.
- Above `singleRowMinimumWidth + leadingInset` the bar is the one row it has
  always been; below it, two rows — query field + checkbox, then count + Done.
- The controls are extracted to `queryField` / `caseToggle` / `countReadout` /
  `doneButton` so both layouts share one definition and cannot drift.

## Measured results

Overflow threshold, at 2 pt steps, by gutter inset:

| inset | before this item | after |
|---|---|---|
| 0 pt | 338 pt | **184 pt** |
| 25 pt (3-digit gutter) | 362 pt | **208 pt** |
| 40 pt | 378 pt | **224 pt** |
| 107 pt | 444 pt | **290 pt** |

A 154 pt improvement, and now `184 + inset` throughout. Against the real default
editor column of **361.7 pt** that is ~153 pt of headroom, where the previous
state overflowed by about 1 pt.

Bar height is **31 pt** on one row and **56 pt** on two. Above the threshold the
render is pixel-identical to the previous build (checked at 430, 500 and 600 pt).

## Acceptance criteria

1. The bar switches layouts exactly at `singleRowMinimumWidth + inset`, checked
   from BOTH sides and computed **from the constant** rather than a copied
   literal. (2 pt above → one row; 4 pt below → two rows; neither overflows.)
2. Two rows hold down to `184 + inset`, straddled at two insets.
3. The default editor column fits with nothing painted outside the frame.
4. Roomy columns are one row and unchanged.
5. In *either* layout the checkbox label never wraps — asserted as "the bar's
   height is exactly one-row or exactly two-row" across eight widths, since a
   wrapped label produces neither figure.
6. The harness fails against a build that never wraps. (Checked: 5 of 25.)
7. `xcodebuild` green; every existing harness still green.

## Decisions taken

**2026-08-22 — the width is passed in, not measured with a `GeometryReader`.**
`ContentView` already computes the column's width for its own `.frame`, so
passing the same value means the two cannot disagree; a reader inside the bar
would report the width *after* the bar had been given it, which is a layout pass
too late to choose a layout with. `availableWidth` defaults to `.infinity` so a
`FindBar` built without one keeps the layout it has always had.

**2026-08-22 — the constant is 340, not the 338.5 the arithmetic gives.**
The floors sum to 60 + 93 + 90 + 47.5 + 32 + 16 ≈ 338.5, and rounding DOWN to
338 left a 2 pt band at the boundary where the bar chose one row and then
overflowed it — visible in the first measurement as an inconsistent threshold
(338 at inset 0 and 378 at inset 40, but 208 at inset 25). Rounded up to the
next even point, and the harness straddles the constant so this cannot silently
regress.

**2026-08-22 — field + checkbox on row one, count + Done on row two.**
This is the split Felix chose, and it is also the one that buys width: the
binding row is field + checkbox at 161 pt of floor against count + Done's
145.5, so pairing the two widest controls on separate rows is what actually
helps. Putting the field alone on row one and the other three on row two was
measured as worse (a 262.5 pt second row).

**2026-08-22 — the residue is stated, not chased.** Row-wrapping bottoms out at
about `161.5 + inset`, because the count readout (90 pt) and Done (47.5 pt) plus
a gap and the bar's padding is itself that wide, and splitting those two apart
would be a fourth row. So the 700 pt minimum window's **161.7 pt** column and
the **108.5 pt** produced by dragging the editor/preview divider to
`editorFractionMin` still overflow. A third row does not fix them either — it
would move the floor to 186.5 pt at a 25 pt inset, still above 161.7 — so it was
not built. Closing those needs a *control* to change: a narrower count readout
(whose 90 pt is already smaller than its widest real value of 100.7 pt) or an
unlabelled checkbox (the SPEC change that was explicitly declined). Recorded in
the harness header and in DONE.md rather than filed as a third round.

## Out of scope

- SPEC §6.5, which states the bar's controls; all of them remain present,
  labelled and clickable in both layouts.
- The leading alignment shipped by (find-bar-gutter-inset) — `leadingInset` is
  untouched and still applies to the whole bar.
