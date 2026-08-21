# (preview-tables) — GFM tables render as one run-on paragraph

**Revision 2** (2026-08-21). Rev 1 was reviewed by `adv-review-plan`, which
returned 17 findings including **three critical**. The review invalidated Rev 1's
rendering choice on measured evidence; Rev 2 reverses it. See
`## Decisions taken`.

**Risk tier: `hi`.** A new block type in the shared classification loop, it
reverses a SPEC §8.2 non-goal, and it changes rendered output for any existing
document containing a pipe table.

**Ships after (preview-bold-spans)** — same file, same `parse` loop, and Rev 2
now depends on that item's accumulator protocol rather than merely following it.

## Goal

A GFM pipe table renders as a real grid. Ragged input degrades **without losing
characters**. A `|` line that is not part of a table keeps rendering as it does
today.

## What Rev 1 got wrong

**Rev 1 chose a monospaced fixed-width character grid**, arguing `NSTextTable`
was untestable in a headless harness. The reviewer measured the preview column
and the argument collapses:

- FEdit's preview column at the app's own defaults (`LayoutMetrics`: window
  1100, sidebar 1100/3, two 5pt dividers, `editorFraction` 0.5) is ≈361.7pt;
  minus the 10pt `textContainerInset` each side and line-fragment padding,
  ≈**332pt** of text width. At SF Mono 13pt (~7.8pt/char) that is ~**42
  characters**.
- The reporter's own table needs **83** characters per row. `SPEC.md:196` needs
  **146**. `SPEC.md:307` needs **195**.
- The preview has `hasHorizontalScroller = false`
  (`MarkdownPreviewView.swift:61`), `isHorizontallyResizable = false` (`:75`),
  `widthTracksTextView = true` (`:70`). So every one of those rows **wraps** —
  at the padding spaces, with no continuation indent. `SPEC.md:196` would wrap
  into display lines that are pure whitespace.

A grid that wraps into 4 unindented display lines per row is the *same complaint
the user filed*, in a different font. Rev 1's criteria 3 and 4 (`\n` counts and
character offsets in the emitted string) were green by construction and blind to
all of it.

**I probed the alternative rather than swapping one assumption for another.**
`NSTextTable` in a hand-built TextKit 1 stack:

| container width | laid-out grid |
|---|---|
| 332pt (FEdit's actual preview) | 326 × 142pt |
| 500pt | 494 × 110pt |
| 900pt | 893 × 94pt |

It fits the narrow column and reflows as the column widens — cells wrap
*inside* their cell, which is exactly what the character grid cannot do. And
the testability objection is simply false: iterating `.paragraphStyle` and
reading `NSTextTableBlock.startingRow` / `.startingColumn` recovered all 9 cell
coordinates in exact order. **Structure and content are fully assertable
headlessly; only pixel geometry is not.**

## Design (Rev 2)

### Rendering: `NSTextTable` / `NSTextTableBlock`

One `NSTextTable` per table block, `layoutAlgorithm = .automaticLayoutAlgorithm`,
one `NSTextTableBlock` per cell carrying `startingRow`/`startingColumn`, a 1pt
gray border and 4pt padding. Each cell's text is a paragraph whose
`paragraphStyle.textBlocks` holds its block; cell content is parsed with
`MarkdownInlineParser` so inline spans work inside cells. The header row is
**bold**, which is what makes it distinguishable — the repro's stated
expectation ("aligned columns, header row distinguishable") that Rev 1 never
addressed. The delimiter row is **consumed and not rendered**.

This choice dissolves five Rev 1 defects outright rather than patching them:
column widths are computed by the layout engine (so the "flattened inline width"
subtlety disappears), cell fonts can be the ordinary proportional preview fonts
(so no monospaced-bold gap), there is no inter-row `paragraphSpacing` problem to
solve, and CJK/emoji/tab cells lay out correctly because nothing counts
characters.

Alignment from the delimiter row (`:---`, `---:`, `:---:`) maps to the cell
paragraph's `alignment` (`.left` / `.right` / `.center`).

### Recognition

A table starts at line `i` iff:

- `lines[i]` contains at least one `|` (leading whitespace allowed — see the
  interaction section), **and**
- `lines[i+1]` exists, **contains at least one `|`**, and after stripping
  optional leading/trailing `|` every cell matches `:?-+:?` with surrounding
  whitespace allowed.

**The "contains at least one `|`" clause on the delimiter row is load-bearing**
and was missing in Rev 1. Without it a bare `---` splits into the single cell
`["---"]`, matches `-+`, and qualifies — so prose containing a pipe followed by
a thematic break becomes a table and **the horizontal rule silently
disappears**:

```
Use the `a | b` syntax.
---
Next section.
```

Rev 1 turned that into a 2-column table with a shredded code span and deleted
the `.rule`. The same bug swallowed YAML front matter (`---` / `title: A | B` /
`---`). Now `---` has no pipe and is rejected, so it reaches step 5 and stays a
rule.

**Row consumption** continues while the next line is non-blank, contains a `|`,
**and is not itself a block starter** (fence open / heading / rule / `>` /
list item, tested after trimming). Rev 1 omitted the block-starter test, so a
`> Note: \`|\` is the pipe character.` line following a table was eaten as a
table row. This reuses the exact predicate `(preview-bold-spans)` introduces for
list continuations — one helper, two callers.

### Cell splitting

Split on `|` **outside backtick pairs**, then trim. Rev 1 split on raw `|`,
which shreds `` `a | b` `` — the commonest cell in developer docs, and present
six times in this repo's own `plans/` files. Escaped `\|` remains an accepted
limitation.

### Ragged input: pad, never truncate

Column count is fixed by the **header**. A short row is padded with empty cells.
A **long** row has its surplus cells re-joined into the last cell with their `|`
separators restored — so no character is ever deleted.

Rev 1 said "padded **or truncated**", which is real data loss on real input:
`plans/syntax-highlighting.plan.md:52` is a 4-column table row whose regex cells
contain 70 pipes, splitting into 69 cells. Rev 1 truncated **65 of them**,
deleting the entire Swift keyword list from the preview. Today that line renders
as ugly-but-complete paragraph text; deleting it would be strictly worse than
the bug being fixed.

`alignments` is **normalized to the header's column count** (padded with
`.leading`) at parse time. Rev 1 left it un-normalized while deliberately
allowing a short delimiter row, so `| a | b | c |` + `| --- |` would index
`alignments[1]` out of range — a **crash**, and on the render queue
(`MarkdownPreviewView.swift:151`), not a glitch.

### Position in the classification loop, stated exactly

The table check is **step 7.5**: after the list-item check (step 7), before
`(preview-bold-spans)`'s list-continuation branch and before paragraph
continuation (step 8). It **flushes the paragraph, the quote, and the list-item
accumulators** before emitting, and the table is emitted at flush time like any
other block.

Rev 1 said only "at the classification loop", which the reviewer correctly
called the seam the implementer would have to invent — each position has a
different regression set. Recording the consequence of this one: an **indented**
table directly under a bullet (e.g. `SPEC.md:122-127`, a 2-space-indented table
under `- Token classes and light-theme colors:`) becomes a **table**, not a list
continuation. That is the better outcome and it is why the table check precedes
the continuation branch — but it is a deliberate interaction between the two
items, not the "they do not interact" that Rev 1 claimed.

**Consumption mechanics:** `for (index, line) in lines.enumerated()` cannot
skip, so the table's consumed rows are tracked by a `skipUntil` index checked at
the top of the loop body. The table block is appended when its last row is
consumed, and — because a table can be open at EOF — the EOF flush sequence
gains it beside the existing three accumulators.

### The harness's exhaustive switch

`scripts/MarkdownRendererTests/main.swift:874-906` is `ReferenceRenderer.emit`,
an exhaustive `switch` over `MarkdownBlock` with **no `default`**. Adding a
seventh case is a **compile error in the harness**, which Rev 1 did not mention.
Decision: `ReferenceRenderer` delegates `.table` to the production emitter, and
its doc comment says so. The differential oracle is thereby vacuous for tables —
acceptable and stated, because the fuzz alphabets contain no `|`
(`main.swift:978`), so tables were never inside its reach in the first place.

## Acceptance criteria

1. The reporter's exact **7-line** source (`plans/preview-tables-repro.md:8-14`
   — header + delimiter + **5** data rows) parses to exactly one `.table` with
   **5** columns.
2. Its ragged last row (**5** pipes → 4 cells against the header's 6 pipes → 5
   cells) is padded to 5 cells; nothing traps.
3. A row with MORE cells than the header keeps every character: the
   `plans/syntax-highlighting.plan.md:52` line (69 cells, 4-column header)
   round-trips with its full keyword list present in the last cell.
4. `| a | b | c |` + `| --- |` parses with `alignments.count == 3` and renders
   without trapping.
5. **`Use the \`a | b\` syntax.` + `---` + `Next section.` parses to paragraph,
   rule, paragraph — byte-identical to HEAD.** The bare-`---` guard.
6. A cell containing `` `a | b` `` yields ONE cell whose code span survives
   intact.
7. The emitted string exposes one `NSTextTableBlock` per cell at the expected
   `(startingRow, startingColumn)`, recovered by iterating `.paragraphStyle` —
   asserted for a 3×3 table, in order.
8. The header row's cells carry a bold font; body cells do not.
9. The delimiter row produces no rendered cell.
10. Alignment `:---` / `---:` / `:---:` produces `.left` / `.right` / `.center`
    on the cell paragraph styles.
11. Leading/trailing pipes optional: `a | b` + `--- | ---` gives the same
    2-column table as `| a | b |` + `| --- | --- |`.
12. A `|` line with no qualifying delimiter row after it still parses to a
    `.paragraph` — asserted against a hand-written expected value.
13. A blank line ends the table; a **block-starter** line containing a pipe
    (`> Note: \`|\`…`) ends it and is reclassified as a blockquote.
14. A table inside a fenced code block is not recognized; a fence-open line
    containing `|` is not a table header.
15. A table open at **EOF** is emitted (no trailing newline in the input).
16. The table emits exactly **one** anchor, at the header row's source line; a
    mixed document emits strictly ascending anchors.
17. `- a` immediately followed by a table emits `[.listItem(line: 0),
    .table(line: 1)]` — in that order (the flush-protocol guard).
18. A one-column table works; an empty cell renders as an empty cell, not a
    missing column.
19. All pre-existing assertions pass, and all three fuzz oracles stay green.

## Out of scope, deliberately

- Escaped pipes (`\|`) inside cells.
- Nested tables, block content in cells, multi-line cells, row/column spans.
- Editor-side highlighting of tables: `Editor/SyntaxHighlighter.swift` gains no
  table rule, so the editor and preview will disagree about tables — recorded
  as an explicit no-change decision, matching how `(preview-bold-spans)` records
  the same class of divergence.
- Scroll sync *within* a table: it emits one anchor, so scrolling through a
  20-row table moves the preview zero pixels — the same trade code blocks
  already make. SPEC §8.3 gains a sentence.

## SPEC

§8.2's "Not in v1: tables, …" is edited to admit tables and to state the exact
subset: header + delimiter row required, delimiter row must contain a pipe,
leading/trailing pipes optional, `:---:` honored, inline spans work in cells,
short rows padded and long rows' surplus re-joined into the last cell, header
rendered bold, rendered via `NSTextTable`, no escaped pipes, no block content in
cells. §8.3 gains the one-anchor-per-table sentence.

## Files

`Preview/MarkdownRenderer.swift` — including the `MarkdownBlock` doc comment
(`:40-46`), `MarkdownBlockParser`'s precedence-order header comment (`:68-76`),
and the accumulator mutual-exclusion comments (`:87-89`, `:193-194`) —
`scripts/MarkdownRendererTests/main.swift`, `SPEC.md` §8.2/§8.3.

**Not README**: it has no Markdown-subset section to edit (`README.md:13` is a
single sentence about the preview), which Rev 1 listed in error.

## Decisions taken

*2026-08-21, folding in `adv-review-plan` Rev 1 findings: 17 findings, all
accepted; three critical.*

- **Reversed the rendering choice (Defect 4).** Rev 1 picked a character grid
  for headless testability. The reviewer measured the preview column (~332pt,
  ~42 chars) against real tables (83–195 chars) and showed every one wraps.
  Rather than accept or reject that on argument, I probed `NSTextTable` in a
  TextKit 1 stack: it fits 332pt, reflows with width, and its structure reads
  back through `.paragraphStyle.textBlocks` — so the testability objection that
  drove Rev 1 is simply false. *Alternative:* keep the grid and add a horizontal
  scroller to the preview. *Why not:* that changes the preview's shipped layout
  contract for every document, to serve one block type.
- **Accepted Defect 2 (bare `---` qualifies as a delimiter row) — critical.**
  The delimiter row must now contain a pipe. This was silently deleting
  horizontal rules and shredding prose.
- **Accepted Defect 3 (truncation deletes text) — critical.** Long rows now
  re-join their surplus into the last cell. *Alternative:* widen the table to
  the widest row. *Why not:* it invents columns the header never declared, and
  the header is the only honest source of column count.
- **Accepted Defect 1 (`alignments` index-out-of-range) — critical.**
  Normalized at parse time. This one was a crash on a background queue.
- **Accepted Defect 5 (the no-interaction claim was wrong, twice).** Rev 2
  states the flush protocol explicitly and pins the ordering decision: the table
  check precedes the list-continuation branch, so an indented table under a
  bullet becomes a table.
- **Accepted Defect 6** — the precedence position is now stated as step 7.5
  rather than left to the implementer.
- **Accepted Defects 7, 9** — row consumption stops at block starters (reusing
  bold-spans' predicate); cell splitting respects backtick pairs.
- **Accepted Defect 8** — the harness's exhaustive switch is a compile error,
  now handled, with the oracle consequence stated rather than discovered.
- **Defects 10, 11, 12 and Tensions 2, 5 dissolved** by the rendering reversal
  rather than patched — no width arithmetic, no monospaced-bold gap, no
  inter-row spacing, no CJK counting, no centre-padding tie-break.
- **Accepted Defects 13, 14, 15, 16** — the repro is 7 lines and the last row
  has 5 pipes (Rev 1 inherited "6 lines / 4 pipes" from the TODO text and called
  it verified — it was not); criterion 9 rewritten; criteria added for every
  regression class the reviewer found uncovered; README removed from Files and
  the three doc comments added.
- **Tension 1 (one anchor per table) accepted** and now recorded in SPEC §8.3
  rather than left implicit.
