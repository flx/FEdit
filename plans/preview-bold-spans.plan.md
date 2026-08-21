# (preview-bold-spans) — `**bold**` is silently not bold, and the wrong run is bolded

**Revision 2** (2026-08-21). Rev 1 was reviewed by `adv-review-plan`, which
returned 14 findings including **two critical ones that invalidated Rev 1's
central design choice**. Both were verified against source before folding. See
`## Decisions taken`.

**Risk tier: `hi`.** It changes rendered output for existing documents, and it
reverses a rule the parser's own header comment documents as deliberate.

## Goal

Fix the two independent causes traced in `plans/preview-bold-repro.md`:

1. A `**…**` span wrapped across a **list item's** source lines is split across
   two blocks, so each half holds an unpaired `**`; the orphaned closer becomes
   an opener and bolds a long arbitrary run further down the document.
2. A stray `*` earlier in the same block re-pairs every asterisk after it.

## What Rev 1 got wrong (both verified against source, not taken on trust)

**Rev 1 proposed a two-sided flanking rule** (an opener must be followed by
non-whitespace; a closer must be *preceded* by non-whitespace, skipping invalid
candidates). The reviewer traced it against
`scripts/MarkdownRendererTests/main.swift:371-374`, which asserts today:

```swift
parse("*a **b** c*") == [.italic([.text("a ")]), .italic([.text("b")]), .italic([.text(" c")])]
```

— i.e. `a b c` renders fully italic, which is visually near-correct. Under
Rev 1's rule the closer candidate at index 3 is rejected (preceded by a space),
the scan takes index 4 instead, and the result is
`[.italic([.text("a *")]), .text("b** c*")]` — literal asterisks and mostly
un-italic text on *the most common nested-emphasis construct there is*. **I
re-read the assertion and re-traced it by hand: the reviewer is right.**

The underlying reason matters more than the case: CommonMark's flanking rule is
only meaningful **together with its delimiter stack**, where a closer pops the
nearest *compatible* opener. Bolting the closer-side test onto a
"nearest closer, opener never backtracks" scan is a different algorithm, and
flanking makes it *more* wrong on nesting, not less. Rev 1's claim that this was
"the minimal subset that fixes every reported case, and no more" was false: it
also broke a case that works today.

**Rev 1 also proposed CommonMark lazy continuation** (any non-blank line
continues a list item). The reviewer found a file in this very repo that it
would wreck — `SPEC.md:68-70`:

```
- **File-system watching (automatic refresh):**
  - **Open file:** watched with a precise vnode `DispatchSource`. …
  - **Sidebar roots:** each root is watched recursively with FSEvents; …
```

Indented sub-bullets match none of steps 1–7 (`parseListItem` tests
`characters.first`, so an indented `- ` never matches), so they reach step 8.
Under lazy continuation both children would be swallowed into the parent item as
one ~2,500-character run-on line with literal `-` separators. **Verified: that
text is in `SPEC.md` at those lines.** "Nested lists are a non-goal" licenses
not rendering them specially; it does not license rendering them *worse than
today*.

## Design (Rev 2)

### Cause 2 — adopt the **opening** half of the flanking rule, and only that

> A `*` or `**` opens emphasis only if the character immediately after the
> delimiter is **present and non-whitespace**. Closer selection is unchanged:
> still the nearest matching delimiter, still no backtracking.

A rejected opener emits its delimiter character(s) **literally** and the scan
resumes immediately after them — the existing no-closer path
(`MarkdownRenderer.swift:429-434`). It explicitly does **not** fall through to
be re-read as a lower-precedence construct: a rejected `**` must never be
re-read as two italic delimiters. (The reviewer showed the natural alternative —
folding the test into the branch *guard* — makes `** bold**` parse as
`[.italic([]), .text(" bold"), .italic([])]`, silently **deleting four
asterisks** from the output, since `emitInline` appends nothing for empty
children. Pinned by criterion 10 and by the new property fuzz.)

Traced against every case in the report and every emphasis assertion in the
harness:

| input | today | after |
|---|---|---|
| `2 * 3 and **bold** here` | "bold" *italic*, stray `*` left | `*` literal, **bold** bold ✔ |
| `see footnote * and **bold**` | wrong pairing | `*` literal, **bold** bold ✔ |
| `a ** b and **bold** c` | wrong run bold | `**` literal, **bold** bold ✔ |
| `Rate is 5 * 4 …\nand … **very important**.` | wrong pairing | correct ✔ |
| `*a **b** c*` | three italics | **unchanged** ✔ |
| `**a*b**`, `***x***`, `**a**b**`, `****`, `**b`, `*i`, `*i*` | — | **all unchanged** ✔ |
| `**bold *italic* code \`x\`**` | correct | **unchanged** ✔ |

**Every one of the eleven existing emphasis assertions is unchanged**, because
each one's opener is followed by a non-whitespace character. I checked them
individually at `main.swift:336-374`, not as a class.

**This also dissolves the quadratic risk the reviewer raised** against Rev 1. A
rejected opener never searches for a closer at all — it emits and advances — so
there is no scan-and-skip loop. `"*a "` repeated N times stays linear: every `*`
is followed by `a`, opens, and finds no closer via the existing single
`firstIndex` scan, exactly as today. Cost is unchanged from HEAD.

**Residual limitation, deliberately accepted and documented:** a stray `*` with
**no** surrounding space still mispairs (`2*3 and **bold** here`). The reported
class is the spaced one, and fixing the unspaced class provably requires the
full delimiter stack (see Decisions). Narrowed from "any stray `*`" to "an
unspaced stray `*`", pinned by a criterion so the behaviour is recorded rather
than accidental, and filed as a follow-up TODO.

### Cause 1 — **indented**, non-block-starting continuation only

A line continues an open list item iff **both** hold:

1. it begins with a space or tab, **and**
2. its whitespace-trimmed form is not itself a block starter — not a fence
   open, ATX heading, rule, `>` quote, or list item.

Test 2 is what protects `SPEC.md:68-70`: `  - **Open file:** …` trims to a list
item, so it is **not** a continuation; it flushes the open item and falls
through to step 8 exactly as it does today. Test 1 is what keeps unindented
prose after a bullet behaving as it does today (`- a\nb` stays item +
paragraph). The blast radius is therefore *precisely* wrapped list items —
nothing else changes.

Mechanically: a fourth accumulator (`listItemLines`, `listItemMarker`,
`listItemStart`, `inListItem`) beside the paragraph and quote ones, with
`flushListItem()` emitting `.listItem(marker:text:line:)`. **Steps 2–7 and the
blank-line step must each flush it, and EOF must flush it.** Naming the failure
mode because it is silent: today step 7 does `blocks.append` inline
(`:179`), so blocks are emitted in source order by construction. An accumulator
emits at *flush* time, so a missed flush reorders `blocks` — `- a` followed by
`> q` with step 6 not flushing yields `[.blockquote(line:1), .listItem(line:0)]`,
which trips `assertStrictlyAscending` in debug and, because asserts compile out,
produces silently broken §8.3 scroll sync in release. The mutual-exclusion
comment at `:87-89`/`:193-194` must be updated to name the fourth accumulator.

**Joining rule.** A single-line item keeps `parseListItem`'s text **verbatim**
(so `- a ` still renders `"a "` — no silent trailing-space change to items that
were never continued). A continued item trims each segment's leading and
trailing whitespace, drops empty segments, and joins with one space. That fixes
both cosmetic halves of the report: the leaked indent (`"  fires]**"`) and the
double space (`"(shipped   2026-08-21"`), and handles `- \n  foo` → `"foo"`.

Paragraph joining is deliberately **unchanged**.

**Anchors.** Merging a continuation removes a block and therefore an anchor.
`assertStrictlyAscending` still holds — block start lines remain strictly
increasing, and `location` strictness rests on the unconditional `\n` separator
at `:627-629`, untouched. §8.3's lookup is "greatest anchor with `sourceLine ≤
line`", so a continuation line resolves to its item's anchor, which is the right
answer.

### The differential fuzz oracle, and what replaces its lost coverage

`scripts/MarkdownRendererTests/main.swift:654` defines `ReferenceInlineParser`
(a standalone reimplementation of the pre-memoization parser) and `:976-1016`
diffs it against the shipped parser over **5000 seeded random inputs whose
alphabet includes `*` and `" "`**. The emphasis change **will fail it on the
first run** unless the reference receives the same opener test. It must — the
oracle exists to prove the link-scan memoization is byte-identical, and it must
not be weakened (e.g. by dropping `*` from the alphabet) to go green.

But the reviewer is right that once both sides share the rule, criterion 11 is
green regardless of whether the rule is *correct* — the change with the widest
blast radius would lose all fuzz coverage. So this item **adds a second,
independent property fuzz** that does not depend on a reference implementation:

> Over 5000 seeded random inputs from the alphabet `["a", "*", " "]`, flattening
> the parsed tree and removing `*` must reproduce the input with `*` removed.

That is an oracle no shared-rule clone can satisfy vacuously, and it directly
catches the asterisk-deletion failure mode above. Reuses the existing `flatten`
helper at `:381`.

## Acceptance criteria

1. The reporter's exact three-line source parses to **one** `.listItem` whose
   text contains `fires]**`, and renders with
   `[hi · TRIGGERED — do not schedule until it fires]` bold and nothing after it
   bold.
2. `parse("- a\n  b")` → one `.listItem(text: "a b", line: 0)`.
3. `parse("- a \n  b")` → `"a b"`, not `"a  b"`.
4. `parse("- a\nb")` → list item + paragraph — **unindented lines are not
   continuations** (this is the reversal of Rev 1's lazy continuation).
5. **`parse("- a\n  - b")` → list item + paragraph, byte-identical to HEAD.**
   The `SPEC.md:68-70` regression guard.
6. `parse("- a\n  ```")`, `parse("- a\n  # h")`, `parse("- a\n  > q")`,
   `parse("- a\n  ---")` each → list item + paragraph, identical to HEAD.
7. Blank line, heading, rule, fence, blockquote, and a new list item each
   terminate an open list item — six assertions.
8. A list item open at **EOF** with a continuation flushes correctly (the
   commonest real case: a file ending on a wrapped bullet).
9. `parse("- a ")` (no continuation) → text `"a "` — trailing space preserved.
10. Every row of the cause-2 table, asserted as an `InlineNode` tree —
    including `** bold**` and `**bold **` rendering as **literal text with all
    four asterisks present**.
11. All eleven pre-existing emphasis assertions (`main.swift:336-374`) pass
    **unchanged** — in particular `*a **b** c*` still yields three italics.
12. The residual: `parse("2*3 and **bold** here")` is pinned to its current
    (still-imperfect) tree, so the narrowing is recorded, not accidental.
13. A wrapped list item's document emits strictly ascending anchors, and emits
    exactly **one fewer** anchor than the identical document with a blank line
    inserted before the continuation line.
14. The 5000-input differential fuzz reports 0 tree and 0 render mismatches,
    with `*` still in the alphabet and the count unchanged.
15. The **new** property fuzz reports 0 violations over 5000 inputs.
16. All 147 pre-existing assertions still pass.

## Out of scope, deliberately

- **The full CommonMark delimiter stack.** See Decisions — it is the only way to
  fix nesting and unspaced strays, it changes several existing expected trees,
  and it is a separate item. Filed as a follow-up TODO with the reviewer's
  `*a **b** c*` trace attached as the motivating evidence.
- `- [ ]` task-list checkboxes — named in the TODO as out of scope.
- Nested lists rendering as nested — still a SPEC §8.2 non-goal, and criterion 5
  pins that they render exactly as they do today.
- `Editor/SyntaxHighlighter.swift` is **deliberately unchanged**. Its per-line
  regexes have no flanking rule, so on `2 * 3 and **bold** here` the editor will
  still show `**bold**` styled while the preview now renders it correctly —
  they already disagree in both directions today, and unifying them is a
  separate concern.
- Closer scans still ignore code-span/link boundaries (pre-existing).

## SPEC

§8.2's list bullet gains the indented-continuation behaviour. The inline bullet
gains one precise sentence — *"a `*`/`**` immediately followed by whitespace
does not open a span"* — and deliberately **does not** claim CommonMark
conformance, because this is one clause of it and SPEC is the project's
authority document.

## Files

`Preview/MarkdownRenderer.swift` (block parser + inline parser + its header
comment, which needs three sentences changed, not one),
`scripts/MarkdownRendererTests/main.swift` (new cases, `ReferenceInlineParser`,
the new property fuzz), `SPEC.md` §8.2.

## Decisions taken

*2026-08-21, folding in `adv-review-plan` Rev 1 findings. 14 findings; the two
critical ones invalidated Rev 1's core design and both were verified against
source before acting.*

- **Rejected the two-sided flanking rule (Defect 1) — verified, then reversed.**
  Re-read `main.swift:371-374` and re-traced `*a **b** c*` by hand; the reviewer's
  result is correct and the regression is worse than the bug. Rev 2 adopts the
  **opening** clause only. *Alternative considered:* implement CommonMark's full
  delimiter stack, which fixes nesting properly. *Why not now:* it changes
  several existing expected trees (`***x***`, `*a **b** c*`), needs its own fuzz
  strategy, and is a substantially larger change than the reported bug warrants
  — so it is filed as its own item rather than smuggled into a bug fix. The
  opener-only rule fixes **every** case in the report with **zero** assertion
  changes, which is the better trade for this item.
- **Rejected lazy continuation (Defect 4) — verified, then reversed.** Confirmed
  the sub-bullets at `SPEC.md:68-70`. Continuation now requires indentation
  **and** a non-block-starting trimmed form, so nested sub-lists render exactly
  as they do today (criterion 5 pins it).
- **Accepted Defect 2 (unspecified rejected-opener path).** The plan now states
  it explicitly and criterion 10 pins that all four asterisks survive
  `** bold**`. The reviewer's trace of the "natural" alternative deleting
  characters is the reason this is spelled out rather than left to the
  implementer.
- **Defect 3 (quadratic scan) dissolved rather than mitigated** by the narrower
  rule: with no closer-side filtering there is no scan-and-skip, so cost is
  unchanged from HEAD. Rev 1's "no backtracking ⇒ linear" claim was wrong as
  stated; it happens not to matter once the closer side is untouched.
- **Accepted Defect 14 (the oracle goes vacuous).** Added an independent
  character-preservation property fuzz that no shared-rule clone can satisfy
  trivially. This is the finding that most improved the plan.
- **Accepted Defects 5, 6, 7, 8, 9, 10, 11, 12, 13**: SPEC no longer claims
  CommonMark conformance; the per-candidate reading is now the only one (the
  closer side is untouched, so the run-aware ambiguity cannot arise); criterion
  13 rewritten to a comparison that is actually different from its baseline;
  single-line items keep verbatim text and empty segments are dropped; the
  accumulator-reordering failure mode is named; the `(preview-tables)` handoff
  is noted (a `|…|` row at column 0 is unindented, so it is never a
  continuation, and the interim behaviour is unchanged); the missing criteria
  are added; the header comment rewrite is scoped to three sentences; and the
  editor-highlighter divergence is recorded as an explicit no-change decision.
- **Tension 3 (closer scans ignore code/link boundaries) accepted unchanged** —
  pre-existing, and the opener-only rule does not change which `*` is selected
  as a closer in those cases.
