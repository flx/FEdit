# (gutter-top-overflow) Stop the line-number gutter painting outside the editor

**Risk tier: `standard`.** One production line changes, but the item filed two
candidate mechanisms whose fixes differ and whose wrong choice is a regression,
so the mechanism had to be *measured* first, and the fix ships with the
project's first render-level regression harness.

## Tier 1 — reproduce and measure (DONE, before any fix was chosen)

The item required this and it is the load-bearing step, so the numbers are
recorded here rather than summarised. Both repros are 2× screenshots of the
shipped build; measured with PIL, filtering out the reporter's red annotation by
requiring `max(r,g,b) − min(r,g,b) < 25`.

`plans/gutter-top-overflow-repro.png` (find bar closed):

| what | y (device px) |
|---|---|
| `ColumnHeaderBar`'s bottom hairline (value 230) | 122–123 |
| the ruler's own background (`NSColor(white: 0.95)` = **242**) begins | **124** |
| ink of the `137` label | **117–129** |

`plans/find-bar-gutter-inset-repro.png` (find bar open):

| what | y (device px) |
|---|---|
| window content top | 60–61 |
| `ColumnHeaderBar`'s bottom hairline | 116–117 |
| `FindBar`'s bottom hairline | 178–179 |
| the ruler's background begins | **180** |
| ink of the `137` label | **≈176–185** |

Two facts fall out. First, the header strip measures `(117 − 61) / 2 = 28` pt,
which is exactly `LayoutMetrics.columnHeaderHeight` — the calibration the item
asked for, so the scale factor (2×) and the boundary identification are not
guesses. Second, **the label's ink starts 7 device px (3.5 pt) above the first
row the ruler fills with its own background.** The ruler's background fill is
`bounds.fill()`, so the top of the filled band *is* `bounds.minY`: the label is
drawn outside the view that draws it, over `ColumnHeaderBar`'s hairline and into
the header strip.

**That is mechanism (b), not (a).** The item's (a) — "flush against the top edge
and merely clipped, which is what Xcode does too" — is refuted: nothing is
clipping it. Had (a) been true the fix would have had to be justified against
normal editor behaviour; it is not true, so no such justification is needed.

**Why it escapes — and a correction to this plan's first draft.**
`NSView.clipsToBounds` has defaulted to `false` since macOS 14; before that
AppKit always clipped. Nothing in this project sets it. That much was confirmed
directly rather than from memory, with a throwaway AppKit program: a view
painting a rect above its own top edge puts 1600 dark subpixels above its frame
with `clipsToBounds = false` (the default the run printed) and 0 with `true`,
in-bounds ink unchanged at 1600.

But that is **not sufficient on its own**, and the first version of Tier 3 was
built on the assumption that it was. A harness that added the real scroll view
straight to a backing `NSView` could **not** reproduce the defect *even with the
fix reverted*: AppKit clipped the ruler's out-of-bounds label at its bounds
anyway, and every "nothing paints above the pane" assertion passed for the wrong
reason. Instrumenting the real ruler in that scene showed the geometry was
right — the topmost label's origin computed to `y = −5.5` against
`bounds.minY = 0`, i.e. it genuinely asked to draw 5.5 pt above itself — while
the rasterised result showed the ink starting exactly at the pane's first row.

The missing ingredient is the **SwiftUI hosting context**. Put the identical
scroll view inside an `NSHostingView` — which is what `CodeEditorView` is — and
the label escapes: 7 device rows of it land above the pane, over the header
strip. Seven rows is the same overhang measured on the shipped build, which is
what ties the reproduction to the report. So the harness must host SwiftUI; one
that skips it would pass forever while the app stayed broken. That is now
recorded in the harness's own header, because it is the single fact a future
reader is most likely to "simplify" away.

**The overflow is not bounded by one line height.** `drawHashMarksAndLabels`
walks from `LogicalLine.lineStart(in:containing: visibleCharRange.location)` —
the *logical* line start of the first visible character — and takes that line's
FIRST fragment. Scroll into the middle of a paragraph that wraps to ten
fragments and the label is placed at the paragraph's first fragment, several
rows above the viewport, i.e. potentially over the header strip's title or above
the window's content area entirely. Any fix must handle that case, not just the
3.5 pt boundary case.

## Tier 2 — the fix

`LineNumberRulerView.init` sets `clipsToBounds = true`.

Revert: delete the line. Pays off alone.

## Tier 3 — the regression harness

New `scripts/GutterRulerTests/main.swift`, in the established `swiftc`-run
shape, compiled from `FEdit/Editor/LogicalLine.swift` +
`FEdit/Editor/LineNumberRulerView.swift`. It hosts a real SwiftUI editor column
— a 28 pt title strip with a bottom hairline above an `NSViewRepresentable`
that assembles the same TextKit 1 stack `CodeEditorView` does — in an
`NSHostingView` inside an offscreen `NSWindow`, scrolls to an offset that leaves
the top line partly cut, rasterises the hierarchy with `cacheDisplay(in:to:)`,
and counts dark pixels in the header strip.

It asserts three things, and the second is what stops it passing vacuously:

1. **No ruler ink above the scroll view's top edge** — the regression itself.
2. **Forcing `clipsToBounds = false` puts ink there** — proof the scenario
   really does provoke the bug, so a scroll offset that happened to land on a
   line boundary can never let assertion 1 pass for the wrong reason.
3. **The in-band pixels are byte-identical between the two renders** — proof the
   fix removes only the overflow and does not skip, move or re-centre any label
   that was legitimately on screen.

Both the boundary case and the wrapped-paragraph case are covered.

## Acceptance criteria

1. `clipsToBounds` is `true` on the shipped ruler.
2. The harness passes, and its assertion 2 fails when the fix is reverted (i.e.
   the harness is checked to be capable of failing, by running it against the
   unfixed ruler, not merely written).
3. The topmost partially-visible line's number is still DRAWN, clipped at the
   top edge — not skipped and not re-centred. Assertion 3 pins this.
4. `xcodebuild` green; the existing 12 harnesses still green.

## Decisions taken

**2026-08-22 — `clipsToBounds = true` on the ruler, not a guard in the drawing
loop.** The alternatives were (i) skipping a fragment less than ~half visible
and (ii) clamping the drawn `y` into the visible band. Both were rejected on
behaviour, before cost: (i) makes the top number pop in and out during a slow
scroll and removes a number whose row is still 90% on screen; (ii) unsticks the
number from its text row, so it would sit at the top edge while the row it
labels scrolls away beneath it — a number that lies about which line it belongs
to is worse than one partly cut off. Clipping keeps the number attached to its
row and cut off exactly at the pane edge, which is what Xcode shows. It also
covers the wrapped-paragraph case above, which neither (i) nor (ii) addresses
without further special-casing, and the bottom edge for free.

**2026-08-22 — the property, not a manual `setClip` inside
`drawHashMarksAndLabels`.** A `NSGraphicsContext.saveGraphicsState()` +
`NSBezierPath(rect: bounds).setClip()` pair would fix the labels only.
`clipsToBounds` is the documented AppKit knob for exactly this, applies to
everything the ruler ever draws (markers and an accessory view included, should
either ever be added), and cannot be defeated by a later edit that draws outside
the one method that carries the manual clip.

**2026-08-22 — the harness renders, rather than testing an extracted pure
function.** A pure "where does this label go" seam would not have caught this
bug and would not catch its return: the drawing loop still *asks* to draw
outside the band, and that ask is identical before and after the fix — what
changed is whether it is clipped. Only a render-level oracle can tell those
apart. Proven, not assumed: instrumenting the label origin gives `y = −5.5`
against `bounds.minY = 0` both with and without the fix. The cost is that this
is the first harness in the project needing AppKit, SwiftUI and a window-server
connection — it creates an offscreen, never-ordered-front `NSWindow` with
`setActivationPolicy(.prohibited)`. Stated in its header so a future headless CI
knows why it is the one harness that would need a GUI session.

**2026-08-22 — the harness asserts it can FAIL, and was checked doing so.**
Every case renders twice, once as shipped and once with `clipsToBounds` forced
off, and asserts the forced-off render *does* put ink in the header strip. Run
against a deliberately reverted fix the suite reports 3 of 18 failing (22 and 42
stray subpixels above the pane, plus the property check); with the fix, 18 of
18 pass. The property check reads a value captured at construction, before any
render — an earlier version read it after the render helper had restored it and
therefore passed even with the fix reverted, which is exactly the vacuous
assertion this project has been bitten by before.

**2026-08-22 — the wrapped-paragraph case scrolls a controlled 24 pt into the
paragraph, not to its middle.** At half the document the overhang is hundreds of
points, which puts the escaped label above the scene's bitmap entirely, where no
assertion can see it — the first attempt measured 0 ink above the pane for that
reason rather than because the bug was absent. 24 pt is deliberately more than
one 16 pt line height, so the case still demonstrates that the overflow is not
bounded by a single line, while landing inside the strip the harness inspects.

**2026-08-22 — the gutter still has no vertical separator line.** The item asked
that this stay consistent with the deliberate absence documented in
`drawHashMarksAndLabels`. Clipping changes nothing there; no separator is added.

## Out of scope

- The find bar's own leading inset — that is (find-bar-gutter-inset), shipped
  separately, disjoint file.
- Any change to which lines the walk visits, to `updateThickness`, or to the
  extra-line-fragment handling.
- SPEC §6.2, which describes the gutter's content, not its clipping.

## Decisions taken — harness robustness, found by me rather than by review

**2026-08-22 — the harness pins `NSAppearance(named: .aqua)`.**
It was inheriting the machine's appearance. Under dark mode the header strip's
`windowBackgroundColor` fill is itself dark, so `darkCount` counts the CHROME as
gutter ink: measured 4 spurious failures and 2,464 phantom "dark subpixels above
the pane" on a scene that has none. Pinning light mirrors what `FEditApp` already
does for the real app (SPEC §3: light appearance only, regardless of the system
setting) and makes the brightness thresholds mean the same thing on every
machine. Without it the suite would have failed for every reader whose Mac is in
dark mode — and failed *loudly and wrongly*, which is worse than not existing.

**2026-08-22 — the wait for SwiftUI is deadline-bounded, not a fixed sleep.**
The first version ran the run loop for a flat 0.3 s and hoped the representable
had been instantiated. Generous on an idle machine, a flake waiting for a loaded
one — and the failure would have looked like a real defect (no ruler, therefore
no ink anywhere, therefore "no overflow") rather than a timeout. It now polls
the observable condition in 20 ms slices up to 5 s and exits with an explicit
FATAL if the representable never arrives, then runs one further pass so the
scroll view is tiled. 8 of 8 consecutive runs clean afterwards.

## Why only the TOP edge was ever visible

Worth stating, because the fix is symmetric and the report was not. The loop
breaks on `fragmentRectInTextView.minY > visibleRect.maxY`, so a fragment
starting just above `maxY` is still drawn and its label could extend below the
ruler too. That overflow was never *visible*: `ContentView` puts the columns in
an HStack filling the window and `editorColumn`'s VStack is header → find bar →
editor with nothing beneath, so the editor's bottom edge is the window's bottom
edge and anything painted below it leaves the window. The top edge has 28 pt of
header strip (plus 31 pt of find bar when open) sitting right above it, which is
exactly where the escaped label landed. Clipping fixes both; only one of them
was ever reportable.

## Decisions taken — round 2, after `adv-review-edge`

**2026-08-22 — THE SWIFTUI CLAIM ABOVE IS WRONG, AND IS RETRACTED.**
Everything in this plan and in the first version of the harness that says the
`NSHostingView` context is required to reproduce the escape is false. The
reviewer refuted it by building the plain-AppKit reproduction it claimed was
impossible, and I re-verified independently before accepting: a plain `NSView`
root with the real scroll view and ruler reproduces the escape at **21 stray
subpixels above the pane**, matching the SwiftUI harness's own figure, and it
does so **with no `NSWindow` at all** (checked in a fresh process, so it is not
an artefact of an earlier window in the same run).

What is actually load-bearing is **subview paint order**. Measured, same document
and scroll offset, clip forced off:

| arrangement | stray subpixels above the pane |
|---|---|
| chrome strip added BEFORE the scroll view | **21** |
| chrome strip added AFTER the scroll view | **0** — the strip repaints over it |
| no strip; the root fills its own bounds | **21** |

A strip added last simply paints over the escaped label. That is also why the
overflow at the bottom edge measured 0 in an early probe, and it is the most
likely reason the first harness reported a clean 0 and was misread as "plain
AppKit clips it". The harness is now plain AppKit — no SwiftUI, no window — and
its header records the three-way measurement so the arrangement is not
"simplified" back into a vacuous pass. The claim also went into README and the
DONE.md record and is corrected in both.

The general lesson is the one this project keeps relearning: a **null result is
not evidence of a mechanism.** The first harness's 0 was read as proof that
AppKit clips in plain hierarchies, when it only ever showed that *that* harness
did not observe an escape.

**2026-08-22 — case 2 cannot distinguish clipping from skipping; said so.**
The reviewer showed that mid-paragraph the shipped gutter is entirely blank: the
paragraph's only label belongs to its first fragment, now clipped, and the next
logical line starts below `visibleRect.maxY` so the loop breaks first. Every one
of case 2's assertions therefore also passes for an implementation that simply
skipped such labels; only case 1's sliver check rules that out. The harness now
asserts the blankness explicitly and both it and the production comment say which
case is the discriminator. The production comment previously claimed clipping
"merely cuts it off at the pane's edge", which is wrong for exactly the case it
cited as motivation — corrected to state both outcomes and why blank is right.

**2026-08-22 — the dark-pixel threshold raised from 0.6 to 0.75.**
Accepted from the review, with the arithmetic re-derived: `secondaryLabelColor`
in light aqua is sRGB 0 at α ≈ 0.498 over the ruler's `NSColor(white: 0.95)`, so
a fully covered pixel composites to ≈ 0.476 and a pixel of coverage `c` to
`0.949 × (1 − 0.498c)`. At 0.6 a pixel needed ≈ 74 % coverage to register, which
left roughly 4 qualifying pixels at 1×; 0.75 admits ≈ 42 % coverage while still
excluding the white chrome and the ruler's own 0.95 background. The revert check
now reports 30 and 58 stray subpixels where it previously reported 22 and 42.

**2026-08-22 — the in-pane comparison is now pixel identity, not a count.**
The plan claimed "byte-identical" while the assertion compared dark-pixel
*counts*, which two different images can share. Rather than soften the wording,
the assertion was strengthened to compare every pixel in the band.

**2026-08-22 — the harness's chrome strip carries no title text.**
It previously drew one at a hardcoded 35 pt inset, chosen to match a 3-digit
gutter. At 5 digits `ruleThickness` is 39 and the title's leading glyph falls
inside the inspected band, so anyone enlarging the test document would have hit a
failure unrelated to the bug. A plain fill makes any ink in the strip
unambiguously the gutter's.

**2026-08-22 — accepted without change:** the reviewer's finding that the bottom
edge also overflowed and is now clipped, with no user-visible effect today
because the editor pane's bottom edge is the window's. Recorded in the section
above; if a status bar is ever added below the editor, the clip already covers it.

**Rejected:** nothing. Every finding was real.
