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
16. All 148 pre-existing assertions still pass.

## Rev 3 (2026-08-21) — cause 2 is CUT from this item, and the reason is a proof

**Rev 2's central claim is false, and the falsification is in Rev 2's own text.**
Rev 2 says of the opener-only rule: *"Every one of the eleven existing emphasis
assertions is unchanged, because each one's opener is followed by a
non-whitespace character. I checked them individually at `main.swift:336-374`,
not as a class."* It is not true of `*a **b** c*`.

Index that string: `*`(0) `a`(1) ` `(2) `*`(3) `*`(4) `b`(5) `*`(6) `*`(7)
` `(8) `c`(9) `*`(10). Today the first italic runs 0→3 (body `"a "`), the second
4→6 (body `"b"`), and the third opens at **index 7, whose next character is the
space at index 8**. Rev 2's own quoted expected tree says so out loud —
`.italic([.text(" c")])`; a body that *begins with a space* is by definition an
opener followed by whitespace.

So under the opening clause the third italic is rejected and the tail emits
literally:

```
old: italic("a "), italic("b"), italic(" c")
new: italic("a "), italic("b"), text("* c*")
```

Confirmed twice: by hand against the shipped `parseNodes`, and by the
implementer's throwaway probe implementing exactly the Rev 2 rule.

**This is structurally forced, not incidental.** Fixing the reported case
`2 * 3 and **bold** here` *requires* rejecting `"* "` as an italic opener, and
`*a **b** c*` contains `"* "` at indices 7-8. Therefore **no opener-only rule
that fixes the report can leave `main.swift:371` unchanged.** Rev 2 fails on the
same input that invalidated Rev 1 — via the opening clause instead of the
closing one. The trade Rev 2 claimed ("fixes every case in the report with zero
assertion changes") does not exist; the real choice is "opener-only plus a
*worse* tree on the commonest nested-emphasis construct" versus "the full
delimiter stack".

Two further Rev 2 errors, both probe-confirmed by the implementer:

- **Criterion 10's `**bold **` sub-claim is wrong.** Under opener-only,
  `**bold **` stays `.bold([.text("bold ")])` — nothing rejects a closer
  *preceded* by whitespace, and Rev 2 deliberately leaves the closer side
  untouched. Only `** bold**` becomes literal. Making `**bold **` literal needs
  exactly the closer-side clause Rev 2 rejected.
- **The new property fuzz does NOT "directly catch the asterisk-deletion failure
  mode"**, as Rev 2 claims. `[.italic([]), .text(" bold"), .italic([])]` for
  `"** bold**"` satisfies flatten-and-strip-`*` *exactly* — both sides reduce to
  `" bold"`. Measured: a mutant that swallows empty emphasis scores 0 violations
  over 5000 inputs, while two other mutants score 1559 and 4570. Only a
  hand-written expected tree catches that one. The shipped comment now records
  the limitation instead of overclaiming.

### Decision: ship cause 1, transfer cause 2 to (preview-emphasis-commonmark)

Cause 1 — the **reported** bug, the wrapped-list-item block split — is complete,
independently valuable, and lands here. Cause 2 is transferred, with this proof,
into `(preview-emphasis-commonmark)`, which is the delimiter-stack item and
**already anticipates changing `*a **b** c*`'s expected tree** ("That changes
several existing expected trees (`***x***`, `*a **b** c*`)"). The two items were
always going to collide on that assertion; Rev 2's error was believing cause 2
could be fixed without touching it.

*Alternative 1:* implement opener-only anyway and change the assertion. Rejected
— `a b* c*` with a literal `* c*` is visibly worse than today's fully-italic
`a b c`, and Rev 1's reviewer rejected precisely this regression. Shipping a
known-worse rendering of the commonest nested-emphasis construct in order to fix
a stray-asterisk edge case is a bad trade.

*Alternative 2:* implement the full delimiter stack here and now. Rejected — it
is substantially larger than the reported bug warrants, it is already filed as
its own item, and smuggling it into a bug fix is exactly what Rev 2's own
Decisions section forbids.

**Criteria 10, 11 and 12 are dropped as unmeetable as written** (10 and 11
cannot both hold), along with the inline-parser header rewrite, the
`ReferenceInlineParser` mirror and the SPEC inline sentence. That sentence was
deliberately *not* added: it would document a rule that is not there. Criteria
1-9 and 13-16 all stand and are met.

### Code review (Rev 3) — one real rendering defect, found and fixed

`adv-review-behavior` and `adv-review-edge`, blind and in parallel on a frozen
diff. Behavior's headline finding is a genuine shipped-in-the-first-draft bug,
and it is worth recording in full because the cause is subtle:

**`isListItemContinuation` trimmed BOTH ends before consulting `startsBlock`.**
But `parseListItem` and `parseHeading` each require a space or tab **after** the
marker, so the trailing trim destroyed the exact character they test for. A
marker-only indented line — `"  - "`, `"  # "`, `"  1. "` — trimmed to `"-"` /
`"#"` / `"1."`, failed those classifiers' `count >= 2` guard, reported "starts no
block", and was **absorbed into the parent item**. Measured by the reviewer
across 11 forms; the concrete case is a nested list caught mid-edit:

```
- Parent
  - 
  - Child
```

which rendered `"•\tParent -"` instead of leaving the parent's text alone. It
also directly contradicted the SPEC sentence this very item added (*"an indented
sub-bullet is not absorbed into its parent"*) — false for a marker-only one.

Fixed by stripping **leading** whitespace only:
`String(line.drop(while: { $0 == " " || $0 == "\t" }))`. `isRule` strips its own
trailing whitespace and `isFenceOpen` only counts leading backticks, so neither
is affected; the hole was exactly the two marker-plus-space classifiers. The
helper's doc comment now states both halves of the requirement and why.

**The test gap that let it through is closed too**, and that matters more than
the fix: every criteria-5-6 case used marker-plus-CONTENT lines (`  - b`,
`  1. b`, `  # h`), so nothing exercised a marker alone. A new section pins all
11 marker-only forms, the mid-edit case whole, three controls (`>`, rule, fence
— never affected, so a future trimming change that breaks them also fails here),
and both unindented forms.

Other findings, all accepted and fixed:

- `startsBlock`'s comment claimed "two callers by design" when the second
  arrives only with `(preview-tables)`. Present tense for future work is a
  comment the code does not support; reworded.
- SPEC omitted that a **blank line ends the item**, including a whitespace-only
  one — it satisfies both stated conditions (indented, starts no block) yet
  terminates, because the blankness step runs first. Added, along with the
  marker-only rule.
- The "terminators emit in SOURCE ORDER" section used the same six inputs the
  six exact-array checks above already assert in full, so it could not fail
  independently while its comment claimed to be *the* guard for the reordering
  failure mode. Rewritten to use inputs those checks do not cover (a **continued**
  item, not first in the document) and to go through `MarkdownRenderer.render` so
  it checks anchor `location` ordering — the half `assertStrictlyAscending` cares
  about that block-level checks never reach.
- Criterion 13's loop formed `1..<wrappedAnchors.count` unguarded, so a
  regression emitting zero anchors would **trap** rather than FAIL. Guarded, with
  the count asserted first so emptiness is itself a failure.
- Criterion 16's "147" corrected to 148.

**One of my own new assertions was wrong and is corrected**: I guessed that an
unindented `- ` parses to a paragraph. It does not — `parseListItem` accepts it,
so it is a second list item with empty text; only a bare `-` (no trailing space)
falls through to paragraph. Probed rather than re-guessed, and both forms are now
pinned, because the difference *is* the trailing space this whole finding is
about.

Behavior also confirmed clean, by measurement rather than inspection: **block
ordering across 300,000 random 1-6 line documents** — 0 non-ascending block
lines, 0 non-ascending anchor locations, 0 out-of-range anchors, including the
unterminated-fence-at-EOF case; the joining rule on every boundary case; all 148
pre-existing assertions passing with unchanged messages; and the property fuzz
biting when the bold-closer advance is mutated.

### Edge review — the fix for the first defect introduced a second one

`adv-review-edge` reviewed the *current* staged state rather than the frozen
diff (it noticed the tree had moved and said so), which is why it caught this:

**My leading-only trim fix stripped space and tab specifically — and that was
wrong.** `flushListItem` trims each segment with `CharacterSet.whitespaces`,
which contains **17 further space characters** (U+00A0 NBSP, U+1680,
U+2000–U+200B, U+202F, U+205F, U+3000). A line indented with spaces and then an
NBSP therefore *kept* its NBSP at the guard, reported "starts no block", was
accepted as a continuation — and then the flush deleted the NBSP anyway,
collapsing a sub-bullet into its parent as `"a - x"`. Exactly the regression the
guard exists to prevent, and the doc comment I had just written claimed the
opposite outcome ("keeps the NBSP … that is the right answer"). The previous
`trimmingCharacters(in: .whitespaces)` version handled this case correctly, so
the marker-only fix traded one defect for another.

Reachability is not theoretical: **Option+Space types U+00A0 on macOS**, and NBSP
is the standard indentation artefact of anything pasted from a web page, Word or
Google Docs.

Fixed by a named `leadingWhitespaceStripped` that strips the leading run of
`CharacterSet.whitespaces` — the *same* notion the flush uses. The lesson is
written into its doc comment: **the two notions of whitespace must agree; the
guard is only ever as strong as the weaker one.** Ten of the 17 characters are
now pinned by a test.

Other findings:

- **Memory (accepted, one word).** `flushListItem`'s
  `.map{}.filter{}.joined()` materialised two intermediate N-element arrays
  where `flushParagraph` does one `joined`. Measured on one bullet followed by
  400,000 indented lines (~30 MB): parse-attributable peak RSS **145.2 MB vs
  HEAD's 89.9 MB — 1.62×, +55 MB** — and `.lazy` restores it to 88.5 MB with
  byte-identical output. Taken without hesitation: the preview renders the whole
  buffer uncapped, SPEC §7's open cap is 100 MB, and SPEC §1's whole premise is
  a steady-state band to "add nothing" to.
- **A table regression this item would have shipped (accepted, prevented).**
  Table rows are not block starters, so this repo's own `SPEC.md:122-128` — a
  six-row table indented under a bullet — was being absorbed into that bullet
  (`SPEC.md` 183→182 blocks; `plans/cli-open.plan.md` 297→212). The reviewer
  noted `(preview-tables)` plans to fix it at step 7.5 and flagged it as a
  deliberate temporary regression. **I chose not to ship it even temporarily:**
  `startsBlock` now reports a `|`-leading line as a block starter, which keeps
  every such line exactly where HEAD puts it. It is a hold-the-line guard, not a
  claim that `|` is a block, and `(preview-tables)` replaces it with real
  recognition. Cost is one line; the alternative was a known-worse preview for
  every table in the repo until the next item lands.
- **A false comment guarantee (accepted, recorded not fixed).** The blank-line
  step's comment claimed it keeps every whitespace-only line out of the
  continuation test. `isBlank` uses `CharacterSet.whitespaces`, which excludes VT,
  FF, CR, NEL and LSEP — so `space + form-feed` is not blank, is absorbed, and
  carries a control character into the item's text. Left as-is deliberately:
  fixing it means changing `isBlank`, which every block type consults, for input
  a Markdown file realistically never contains. The comment now states the gap
  instead of denying it.
- **SPEC prose corrected**: it said "continuation lines are trimmed", but in fact
  once an item is continued *every* segment including its own text is trimmed —
  so a boundary NBSP survives on an uncontinued item and vanishes on a continued
  one. That asymmetry is now stated.

Edge confirmed clean by measurement: **300,000-document differential fuzz** vs
HEAD (compiled `-Onone` so `assertStrictlyAscending` was live) with zero
ordering, range or character-preservation failures, and zero across all 43 `.md`
files in the repo; **no quadratic cliff** (successive doublings 2.25×, 1.96×,
1.95× — linear, at a flat 1.6–1.9× constant factor); no width/wraparound/indexing
risk; no resource, lifetime or concurrency exposure; and grapheme-cluster edges
degrade to HEAD's behaviour rather than corrupting.

It also recorded a standing obligation: flush order is safe **only** because at
most one accumulator is active, which it proved for the four that exist.
`(preview-tables)` adds a fifth — that invariant must be re-proven there, not
assumed.

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
