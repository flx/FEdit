# (find-bar-narrow-column) Make the find bar fit the editor column

**Risk tier: `standard`.** One number changes in production, but the item was
filed with the rendering explicitly marked *reasoned, not observed*, and with the
fix left open as a product choice — so the whole value is in Tier 1 deciding
those two things with measurements rather than argument.

## Tier 1 — reproduce and measure (DONE, before any fix was chosen)

Probed by hosting the **real** `FindBar` in an `NSHostingView`, centred in a
wider magenta field, and counting non-magenta pixels outside the column's band.
`WorkspaceModel` compiles standalone once `FileWatcher` and
`DirectoryTreeWatcher` come along, and `FindBar` needs only
`LayoutMetrics.dividerLineWidth`, so nothing had to be replicated or faked.

**The spill is real, and SwiftUI centre-spills rather than clipping.** That was
the open question; it is now answered by rasterisation, not by reading the
`.frame(width:)` documentation. Below the threshold the bar's background *and*
its bottom hairline paint over both split dividers, growing linearly at exactly
1 device px per 1 pt of missing column, split evenly across the two sides.

Highest column width that still spills, by gutter inset (2 pt steps):

| gutter inset | before the fix | after |
|---|---|---|
| 0 pt | 398 pt | **302 pt** |
| 25 pt (3-digit gutter) | 422 pt | **322 pt** |
| 40 pt (4-digit, or a modest zoom) | 438 pt | **342 pt** |
| 107 pt (6-digit at `maxFontSize`) | 504 pt | **404 pt** |

**FEdit's default editor column is ≈ 366.7 pt** — window 1100,
`defaultSidebarWidth = 1100/3`, editor/preview split defaulting to half the
remainder. So with a 3-digit gutter the unfixed bar needed **more than 422 pt**
and overflowed **at the default window size**, and had done since the bar
shipped. Magnitude, to be unambiguous: ~58 device px measured across a single
row (≈29 px, i.e. ≈15 pt, past each of the two dividers), which summed over
every row of the bar is 4,560 stray pixels. This is what the filed item suspected from arithmetic; it
is now measured. It confirms the item's other claim too: this was never a
regression introduced by (find-bar-gutter-inset), which only raised an
already-exceeded threshold.

## Tier 2 — the fix

`FindBar`'s query field: `.frame(minWidth: 120, …)` → `.frame(minWidth: 60, …)`.

Revert: change the number back. Pays off alone.

## Tier 3 — the regression harness

New `scripts/FindBarWidthTests/main.swift`, the probe promoted to an assertion.
It counts stray pixels over **every row** of the render rather than sampling the
bar's mid row: the background spills across the bar's full height so a mid-row
sample catches today's defect, but a future change in which only the bottom
hairline escaped would slip past a single-row probe — and the hairline is half of
what makes the spill visible against the divider. The assertions are:
no ink outside the frame at the default column with 0/25/40 pt gutters, none at
520/600/700 pt, and — the anti-vacuity check — a deliberately tiny 200 pt column
that *does* still overflow, so a zero elsewhere means the measurement works
rather than that it cannot see.

## Acceptance criteria

1. At the default editor column with a typical gutter, the bar paints nothing
   outside its own frame, counted over every row. (Was 4,560 stray pixels; now 0.)
2. Roomy columns render **pixel-identically** to before the change.
3. The harness fails against the unfixed bar. (Checked: 3 of 8.)
4. `xcodebuild` green; every existing harness still green.

## Decisions taken

**2026-08-22 — the query field absorbs the shortfall; every other control keeps
its floor.** It is the only control in the bar whose minimum had no recorded
rationale, and it is the one that degrades gracefully: a short text field still
scrolls its contents, whereas a truncated "Case sensitive" label loses meaning
and a count readout that resizes on every keystroke reintroduces exactly the
jitter its fixed 90 pt width was documented to prevent. Every control stays
present and clickable. *Alternatives rejected:* shrinking the count label (its
width is load-bearing, and documented as such); an icon-only checkbox (SPEC §6.5
names the visible **Case sensitive** control, and this item is not the place to
renegotiate it); `.clipped()` on the bar (it would contain the spill by hiding
the Done button — trading a cosmetic defect for an unreachable control).

**2026-08-22 — 60 pt, chosen for margin rather than minimality.** It buys a 44 pt
margin at the default column with a 3-digit gutter (322 vs 366.7) and 24 pt with
a 40 pt gutter, so ordinary use has room rather than sitting on the boundary. A
60 pt field shows roughly seven characters and scrolls; it only ever binds when
the column is already very tight.

**2026-08-22 — `idealWidth` deliberately untouched, and the no-op verified.**
The floor only binds under pressure, so wherever there is room the field is still
220 pt. Checked rather than asserted: rendered at 520, 600 and 700 pt with a
query and a `3 of 17` readout, the before and after bitmaps have **no differing
pixel** (PIL `ImageChops.difference(...).getbbox()` is `None`).

**2026-08-22 — a candidate fix was refuted by measurement and dropped.**
`.frame(maxWidth: .infinity)` inserted before `.background`, to make the chrome
take the proposed width rather than the oversized content's, looked right and
does **nothing**: its spill numbers are identical to the baseline at every width
tested. Recorded because it is the obvious next idea and someone will otherwise
re-derive it.

**2026-08-22 — the extreme case is NOT fixed, and that is deliberate.** At a
107 pt gutter (a 6-digit document at `EditorMetrics.maxFontSize = 32`) the bar
still needs more than 404 pt, so a default-width column still overflows. Fixing
that would mean taking width from a control whose floor is load-bearing, for a
configuration where the gutter alone is nearly a third of the column. The
threshold improved by ~100 pt at every inset; the residue is recorded here and
in the harness rather than being quietly rounded up to "fixed".

## Out of scope

- The leading alignment shipped by (find-bar-gutter-inset), which this must not
  disturb — and does not: `leadingInset` is untouched.
- Any SPEC change. §6.5 specifies the bar's controls, not its metrics.
- The sidebar's filter field, which has its own layout and was not measured.

## Decisions taken — round 2, after `adv-review-behavior`

The review found six real defects, three of them in the numbers this plan was
built on. Everything below was re-measured from one build before being written.

**2026-08-22 — THE FIRST FIX DEGRADED THE CHECKBOX, WHICH IS THE DEGRADATION
THIS PLAN HAD EXPLICITLY REJECTED.** The reviewer noticed that the before/after
threshold deltas (96, 100, 96, 100 pt) could not come from a 60 pt change to one
child's floor, and was right. Rendering the bar down the width range shows why:
once the query field gives up its space, the **`Toggle`'s label is next to
yield** — it wraps to two lines from about 380 pt ("Case / sensitive") and
truncates by 324 pt ("Case / sensi…"), which silently makes the bar taller and
eventually unreadable. So the extra ~36-40 pt of apparent headroom was bought
with exactly the outcome this plan's own "Decisions taken" called out as worse
than a short field. Fixed by pinning the label:
`.fixedSize(horizontal: true, vertical: false)` on the `Toggle`. With it, the
threshold moves by **exactly 60 pt** at every inset — 398/422/438/504 becomes
338/362/378/444 — which is the arithmetic the reviewer predicted and is now the
evidence that only ONE control yields.

**2026-08-22 — the default editor column is 361.7 pt, not 366.7, and the earlier
figure was wrong.** `ContentView` computes
`contentWidth = width − sidebar − dividerHitWidth − (isMarkdown ? dividerHitWidth : 0)`
and then takes `contentWidth × editorFraction`, so the two 5 pt hit widths come
off before halving. Every place that carried 366.7 — this plan, the production
comment, the harness — is corrected.

**2026-08-22 — the item is NOT fully fixed, and that is now stated rather than
rounded up.** With the threshold at `338 + inset` and the real default column at
361.7 pt, a 2-digit-line-count file (gutter 21 pt) fits, and a **3-digit one
(gutter 25 pt) still overflows — by about 1 pt**, against about 61 pt before.
Worse, the reviewer traced how easily narrower columns are reached: at the 700 pt
minimum window with an otherwise untouched layout the editor column is
**161.7 pt**, and dragging the editor/preview divider to `editorFractionMin`
gives **108.5 pt**. The harness's original comment calling 200 pt "far below
anything the window's 700 pt minimum can produce" was simply false. No amount of
floor-lowering reaches those widths — the count readout's 90 pt is load-bearing
(its widest real value, `20000 of 20000+`, measures **100.7 pt**, so the existing
floor is if anything already too small) and the checkbox is now pinned on
purpose. What remains needs the bar to have a genuine narrow-width design, which
is a product decision and is filed as its own item with these numbers.

**2026-08-22 — the "pixel-identical" claim was checked at the wrong widths and is
re-scoped.** The reviewer pointed out that old and new can only differ where the
field's residual lands between the two floors, and that the smallest width I had
compared (520 pt) sat just outside that band. Re-run: identical at 430, 450, 480,
500 and 600 pt; at **424 pt** — two points above the OLD threshold — they differ
by about a one-pixel shift of everything right of the field, because pinning the
checkbox rounds its width differently. Visually indistinguishable, but the claim
is now "identical at 430 pt and above", not an unqualified no-op.

**2026-08-22 — the harness was rebuilt around what the review showed it could
not see.** It now (a) counts every row rather than the bar's mid row, so a spill
confined to the bottom hairline cannot slip past; (b) counts ink INSIDE the band
on every render and fails if there is none, so a render that never laid out can
no longer report "fits" — the exact null-result trap this project post-mortemed
in 679b698; (c) **straddles** the threshold from both sides at two insets, so a
floor that crept back up to 100 would fail rather than pass; (d) pins the
contents by measuring the bar's natural height, which is 31 pt on one line and
grew to 38 / 52 / 94 pt at 360 / 330 / 260 pt before the checkbox was pinned;
(e) prints its measurements on success, so the margin can be watched eroding;
and (f) drops a check that was a tautology of `Int()` truncation and could not
fail for any reason involving `FindBar`. Against the unfixed bar it now reports
**6 of 16 failing**.

**2026-08-22 — "paints out over both split dividers" is overstated, and the
harness says so.** `ContentView` declares sidebar → divider → editor → divider →
preview and later siblings paint over earlier ones, so the left spill covers the
left divider while most of the right spill is repainted by the divider and the
preview. Ink-outside-the-frame is still the right invariant to pin; the symptom
is asymmetric.

**Rejected:** nothing. All six findings were real.
