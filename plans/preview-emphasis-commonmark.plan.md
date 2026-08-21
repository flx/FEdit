# (preview-emphasis-commonmark) — CommonMark's delimiter-stack algorithm for preview emphasis

**Revision 2** (2026-08-21) — folds in `adv-review-plan`, which returned **10
defects, 6 gaps, 3 tensions** and the verdict BUILD WITH THE FIXES ABOVE. It
verified Rev 1's hardest claim by building a spec-faithful CommonMark parser,
swapping it into `MarkdownInlineParser.parse` and running all 278 assertions:
**exactly three fail**, the three Rev 1 named. No ninth. That table stands.

Everything else needed work. **Read `## Rev 2 — what Rev 1 got wrong` before the
Design section**, which Rev 2 rewrites rather than appends to.

**Revision 1** (2026-08-21).

**Risk tier: `hi`.** Algorithm-heavy; changes rendered output for existing
documents; and it reverses a rule the inline parser's own header comment
documents as deliberate ("the closer is the nearest matching closing delimiter
… with NO backtracking"), so the comment is part of the change, not collateral.

## Why this item exists, and what it inherited

Filed originally for **nesting** (`*a **b** c*` parses to three sibling italics
rather than `em(a, strong(b), c)`). It then **absorbed cause 2 of
`(preview-bold-spans)`** — the stray-asterisk mispairing — because that item
proved, during implementation, that cause 2 cannot be fixed without this
algorithm. The proof, verified twice there (by hand against the shipped
`parseNodes` and by a probe implementing exactly the proposed rule):

`(preview-bold-spans)` Rev 2 proposed the **opening clause alone** — a `*`/`**`
immediately followed by whitespace cannot open — claiming it changed no existing
expected tree. Index `*a **b** c*` as `*`(0) `a`(1) ` `(2) `*`(3) `*`(4) `b`(5)
`*`(6) `*`(7) ` `(8) `c`(9) `*`(10). The third italic opens at index **7**, whose
next character is the **space** at index 8 — and Rev 2's own quoted expected
tree, `.italic([.text(" c")])`, is a body *beginning with a space*, i.e. by
definition an opener followed by whitespace. So under that rule the tail emits
literally and the tree becomes `italic("a "), italic("b"), text("* c*")`.
Structurally forced: fixing `2 * 3 and **bold** here` **requires** rejecting
`"* "`, and `*a **b** c*` contains `"* "`. **No opener-only rule that fixes the
report can leave the existing assertion unchanged.**

So the honest framing is: the previous item shipped the half that was separable
(the block-level fix), and deliberately left the emphasis half here, where the
expected-tree changes can be justified one at a time instead of smuggled into a
bug fix.

## Goal

Replace the "nearest closer, no backtracking" emphasis scan with CommonMark's
**delimiter-run + delimiter-stack** algorithm, so that emphasis nests correctly
and stray asterisks stop re-pairing every delimiter after them.

Explicitly **not** a claim of full CommonMark conformance — this parser supports
a documented subset (no `_` emphasis, no HTML, no reference links, no
backslash escapes). SPEC must state the subset adopted, not the standard's name.

## What changes, tree by tree — the whole justification

I enumerated every existing emphasis assertion (`main.swift:335-374`) and traced
each by hand. **Three change; eight do not.**

| input | today | after | why the change is an improvement |
|---|---|---|---|
| `***x***` | `bold("*x") + text("*")` | `italic([bold("x")])` | Today emits a stray literal `*` and bolds a leading asterisk. CommonMark's `<em><strong>x</strong></em>` is what every other renderer produces. |
| `*a **b** c*` | three sibling italics | `italic("a ", bold("b"), " c")` | The commonest nested-emphasis construct there is. Today's output is *visually* near-correct by accident (three adjacent italics look like one) but the tree is wrong, and it is why nesting was filed. |
| `****` | `bold([])` | `text("****")` | **Today's output DELETES four characters** — `emitInline` appends nothing for empty children, so `****` vanishes from the preview. A literal `****` is strictly better and is what CommonMark does. |
| `**b**`, `**b`, `*i*`, `*i`, `**a*b**`, `**a**b**`, `**bold *italic* code \`x\`**`, `*a \`c\` b*` | — | **unchanged** | Traced individually, not as a class. |

Newly **fixed** (the inherited half), traced under the new rules:

| input | today | after |
|---|---|---|
| `2 * 3 and **bold** here` | `"bold"` *italic*, stray `*` left over | `*` literal, **bold** bold ✔ |
| `2*3 and **bold** here` | mispairs | `*` literal, **bold** bold ✔ |
| `see footnote * and **bold**` | wrong pairing | correct ✔ |
| `a ** b and **bold** c` | wrong run bold | correct ✔ |

Note the second row: the **unspaced** stray, which `(preview-bold-spans)`
explicitly could not reach and recorded as a residual limitation, is fixed here.
Trace: the `*` in `2*3` is preceded by `2` and followed by `3`, so it is both
left- and right-flanking and can open *and* close; but the `**` before `bold` is
preceded by a space, so it cannot close, and the final `**` is followed by a
space, so it cannot open. The stack therefore pairs the two `**` with each other
and leaves the lone `*` unmatched → literal.

## Design

### Three phases, replacing one scan

**Phase 1 — tokenize.** One left-to-right pass producing a flat array of
`InlineToken`:

- `.node(InlineNode)` — a finished code span or link, produced by the **existing**
  `parseLink` / code-span logic, unchanged and still higher precedence than
  emphasis.
- `.text(String)` — a literal run.
- `.delimiter(count: Int, canOpen: Bool, canClose: Bool, index: Int)` — a maximal
  run of `*`.

Code spans and links stay opaque to emphasis exactly as today, so their
memoization (`md-link-scan-quadratic`) and their assertions are untouched.

**Phase 2 — `processEmphasis`.** CommonMark's algorithm over the delimiter list:
walk forward to each closer; walk back to the nearest compatible opener; on a
match, emit `.bold` for two delimiters or `.italic` for one, wrapping the tokens
between them; remove the consumed delimiters; on no match, record
`openers_bottom` so the backward scan stays linear overall.

**Phase 3 — build.** Fold the residual token array into `[InlineNode]`, turning
unmatched delimiters back into literal text and coalescing adjacent `.text`.

### Flanking, exactly as specified

- **left-flanking**: not followed by whitespace, **and** either not followed by
  punctuation, or preceded by whitespace or punctuation.
- **right-flanking**: not preceded by whitespace, **and** either not preceded by
  punctuation, or followed by whitespace or punctuation.
- For `*`: `canOpen = leftFlanking`, `canClose = rightFlanking`.

Start/end of the block count as whitespace, per the spec. "Whitespace" and
"punctuation" must be **Unicode** categories, not ASCII — and this is where the
last two items were bitten twice (`CharacterSet.whitespaces` vs `{" ","\t"}`
disagreeing; VT/FF/NEL excluded). One helper each, used by both flanking tests,
so the two can never disagree.

### The rule of three

If a delimiter can both open and close, a pair is forbidden when the sum of the
two runs' original lengths is a multiple of 3, unless **both** lengths are
multiples of 3. Without it `*foo**bar**baz*` mis-nests. It is three lines and
skipping it would be a silent, hard-to-find divergence.

### Complexity

`openers_bottom` (per closer-length × opener-can-also-close) is what keeps the
backward scan from being quadratic on inputs like `*a *a *a *a …`. The existing
harness has an advisory no-quadratic-cliff section; this item adds a case to it
for a delimiter-dense input, because that is the failure mode a naive stack has.

## Acceptance criteria

1. `***x***` → `italic([bold("x")])`.
2. `*a **b** c*` → `italic([text("a "), bold([text("b")]), text(" c")])`.
3. `****` → `text("****")` — and specifically **no character is lost**, which
   today's `bold([])` does lose.
4. The eight unchanged assertions above still pass, **byte-identical**, each
   asserted individually.
5. `2 * 3 and **bold** here` and `2*3 and **bold** here` both → `*` literal,
   `bold("bold")` correct. Both spellings, since the unspaced one is the newly
   reachable case.
6. The three other report cases from `plans/preview-bold-repro.md` parse
   correctly.
7. Rule of three: `*foo**bar**baz*` → `italic([text("foo"), bold([text("bar")]),
   text("baz")])`; and a case where the rule *forbids* a pair is asserted with
   its expected tree.
8. Flanking uses Unicode categories: a delimiter adjacent to NBSP, an em-dash, a
   CJK character and an emoji each behave per spec, asserted.
9. **Character conservation, as a property over fuzz**: flattening the tree and
   re-inserting the delimiters of unmatched runs reproduces the input's
   non-delimiter characters exactly. This is the oracle that catches
   `****`-style deletion, which `(preview-bold-spans)` proved a plain
   flatten-and-strip property **cannot** catch.
10. The differential fuzz (`ReferenceInlineParser`) still reports 0 mismatches
    with `*` in the alphabet and the count unchanged — **the reference must
    receive the same algorithm**, and must not be weakened to go green.
11. Both existing corpus guards still hold (`> 4_000` distinct), and any new
    fuzz carries one.
12. No quadratic cliff: a delimiter-dense input of 40,000 `*` renders inside the
    existing advisory ceiling.
13. Every pre-existing non-emphasis assertion passes unchanged (275 at HEAD).
14. `MarkdownRenderer.render` output and anchors are unchanged for every document
    containing no emphasis, verified by a differ against HEAD over generated
    documents — the same technique the previous two items used, because the
    differential fuzz is structurally blind to changes it shares.

## Rev 2 — what Rev 1 got wrong

Every item below was verified against source or measured by the reviewer before
being folded in. The two that matter most are D1 and D2.

### R1 (was D1, critical) — the phase split CHANGES code-span and link scoping, and Rev 1 denied it

Rev 1 said code spans and links stay opaque "exactly as today" and that this
parser "already" resolves them before emphasis. **False.** `parseNodes` recurses
into the emphasis *body slice*, so a backtick's closer search is **truncated at
the emphasis boundary**. A single global phase-1 tokenizer removes that
truncation. Measured:

| input | today | after |
|---|---|---|
| `` *a`b* c`d `` | `italic("a\`b"), text(" c\`d")` | `text("*a"), code("b* c"), text("d")` |
| `*a [b* c](d)` | `italic("a [b"), text(" c](d)")` | `text("*a "), link(text: "b* c", url: "d")` |

The second is user-visible and sharp: text that was **not** a link becomes a
**live clickable link** (`URL(string: "d")` is non-nil, so the emitter attaches
it). Over the existing 5000-input differential corpus — whose alphabet already
contains `[ ] ( ) a * ` and space — **1821/5000 trees differ, 1777/5000 renders
differ, and 862/5000 change what is inside a code span or link.**

**Decision: accept it as an intended behaviour change, and test it explicitly.**
It is the CommonMark-correct direction (verified against markdown-it), and the
current truncation is an artifact of recursive descent, not a designed rule.
Rejecting it would mean keeping per-body recursion for code spans while running a
global delimiter stack for emphasis — two different scoping rules in one parser,
which is worse than either. But it stops being a silent side effect: hand-written
expected trees for `` *a`b* c`d ``, `*a [b* c](d)`, and `` *a `c b* `` (verified
NOT to change), plus a SPEC sentence, plus a line in the DONE record.

Load-bearing assumption 3 is restated: *code spans and links are still resolved
before emphasis, but now over the whole block rather than per emphasis body —
this is a behaviour change, not a preserved invariant.*

### R2 (was D2, critical) — criterion 9's oracle was not computable, and was blind anyway

Rev 1's property ("re-insert the delimiters of unmatched runs") is not a function
of `[InlineNode]` — "unmatched run" is internal `processEmphasis` state, so the
oracle would have to ask the parser to grade itself. And even granting that, it
scores **0 violations** against the very mutant it claimed to catch: for
`"** bold**"` → `[.italic([]), .text(" bold"), .italic([])]` the mutant considers
all four asterisks matched, so nothing is re-inserted, and `" bold" == " bold"`.
Identical blindness to the property `(preview-bold-spans)` already measured as
useless.

**Replaced with a delimiter-RECONSTRUCTING property**: walk the tree and re-emit
`**` around every `.bold` and `*` around every `.italic`, concatenating literals
and code/link payloads in order; the result must be **byte-equal to the input**.
That is a pure function of the tree, and it gives `"**** bold****"` ≠
`"** bold**"` for the mutant. The reviewer confirmed it holds for `***x***`,
`**a*b**`, `*a **b** c*`, `**a**b**`, `****`, `**b` and `*foo**bar**baz*`.

This is now **the** independent oracle for the emphasis change (see R10), so it
is not optional and it must be fuzzed, not just spot-checked.

### R3 (was D3, high) — the complexity claim named the wrong input and the test could not fail

Measured backward-scan steps:

| input | with `openers_bottom` | without |
|---|---|---|
| `"*"` × 40,000 — **Rev 1's criterion 12** | 0 | 0 |
| `"*a "` × 20,000 — **Rev 1's named input** | 0 | 0 |
| `"a** * "` × 2,000 | 1,999 | 1,999,000 |

`"*"` × 40,000 is one run, flanked by whitespace on both sides — it does no work
at all. `"*a *a *a…"` is all openers and no closers, so nothing ever scans
backward. Rev 1's test was untriggerable and its diagnosis wrong.
`openers_bottom` *is* load-bearing — the third row is exactly N(N−1)/2 without it
— but only for that shape.

Worse, Rev 1's own phase-1 layout hides a second quadratic: if phase 2 walks the
**token array** backward, the scan is O(tokens), not O(delimiters), and
`openers_bottom` does not bound it. Measured on an array-based implementation:
`"a* "` × 10,000 (30 KB) → **1.235 s**, past the harness's 1.0 s advisory
ceiling; × 20,000 → 5.05 s, i.e. 4× input for 16× time. Zero backward *delimiter*
steps; the cost is pure token traversal. This is the `(preview-tables)` failure
mode verbatim — invisible to reading, obvious to measurement.

**Fixes:** (i) the backward scan walks a **separate delimiter list**, never the
token array; (ii) a run that is neither left- nor right-flanking never enters
that list, and a failed closer that cannot open leaves it — with inert runs
excluded, every quadratic shape the reviewer found collapses to linear;
(iii) criterion 12 becomes `"a** * "` × 2,000 **and** `"a* "` × 10,000, the two
shapes that actually bite.

### R4 (was D4, high) — `openers_bottom`'s key was misstated and uncomputable

Rev 1 said "per closer-length × opener-can-also-close". The flag belongs to the
**closer**, not the opener — at the moment the key is formed there is no opener
yet, which is what the scan is looking for, so the key as written cannot be
computed. Correct key: **(delimiter char, closer run length mod 3, whether the
closer can also open)**. Getting this wrong by over-bounding silently produces
*missed matches*, i.e. wrong trees, which criterion 4 catches only by luck.

### R5 (was D5+D6, high) — neither stock `CharacterSet` is correct, in either direction

Rev 1's "one helper each so the two can never disagree" solves the wrong half:
it makes left- and right-flanking agree **with each other**, while the
`(preview-bold-spans)` defect was a notion disagreeing with **the rest of the
file**. Measured against CommonMark:

- `CharacterSet.punctuationCharacters` is missing **`$ + < = > ^ ` | ~`**, all of
  which *are* CommonMark punctuation. Consequence: `x**$**y` should be literal
  and would instead render `<strong>$</strong>`.
- `CharacterSet.whitespaces` **omits FF (U+000C)**, which CommonMark counts as
  whitespace, and **contains ZWSP (U+200B)**, which it does not.
  `whitespacesAndNewlines` additionally contains NEL (U+0085), which it does not.

So both must be **explicit, owned sets**, and the plan must say so rather than
naming a Foundation API. Rev 1's criterion 8 named NBSP, em-dash, CJK and emoji —
**all four pass on the wrong implementation**, so it was a test that could not
fail. Replaced by the discriminating set: `$ + < = > ^ ` | ~`, plus FF, ZWSP and
NBSP.

**This plan targets CommonMark 0.30**, named explicitly because 0.31.2 moved the
Symbol categories into "Unicode punctuation" and flips exactly the emoji case
(`x**🙂**y`). Rev 1 said "per spec" while forbidding naming the spec, leaving the
one potentially-discriminating case unresolvable.

### R6 (was D7, medium) — the token type could not express the rule of three

`.delimiter(count:…)` alone is wrong: phase 2 decrements `count` as delimiters
are consumed, but the rule of three needs the **original** run lengths, which
Rev 1 itself said. After `***x***` consumes 2 of 3 from each run the rule would
evaluate on the wrong numbers. The token carries **both** `remaining` and an
immutable `originalLength`.

### R7 (was D8, medium) — the `****` justification was factually wrong

Rev 1 said today's `****` "vanishes from the preview". It does not: `isRule`
accepts three-or-more `*`, so a line of `****` is a **horizontal rule** and never
reaches the inline parser (`render("****")` gives 32 `─` glyphs). The character
loss is real but only in the **embedded** form Rev 1 never mentioned:
`render("a****b")` is `"ab"` at HEAD. Criterion 3 asserted the loss on the one
input where no loss occurs; it now asserts
`render("a****b").output.string == "a****b"`.

### R8 (was D9+D10, medium) — the phase 2/3 seam and three missing rules

- **Coalescing must apply at every nesting depth.** If phase 2 builds children
  eagerly and phase 3 only folds the top level, `**a*b**` yields
  `bold([text("a"), text("*"), text("b")])` instead of `bold([text("a*b")])`,
  failing an existing assertion. The literality contract the parser's header
  documents holds at all depths, not just the root.
- **Strong iff both opener and closer have ≥2 *remaining*** — `***x***` →
  `italic([bold("x")])` is produced by two passes over the same pair (2, then 1)
  and is impossible without this.
- **Partial-consumption ordering**: leftover opener asterisks emit *before* the
  new node, leftover closer asterisks *after* (`***x**` → `*<strong>x</strong>`).
- **Remove delimiters between opener and closer from the stack** — without it
  `**a*b**` leaves the inner `*` pointing at a token now nested inside the bold.
- Opener and closer must belong to **separate runs** (falls out of scanning from
  `closer.prev`, but state it, or `a***b` self-pairs).

### R9 (was N1) — the rule of three fails loudly, not silently

Rev 1 called skipping it "a silent, hard-to-find divergence". Measurably false:
ablating it changes `**a*b**` to `italic([italic("a"), text("b")]), text("*")`,
tripping an existing assertion. And criterion 7's demand for a case where the
rule *forbids* a pair is already met by `**a*b**` — Rev 1 didn't know it had one.

### R10 (was G1) — with R2 fixed, the oracle situation is coherent

`ReferenceInlineParser` must receive the same algorithm or the differential fuzz
fails; but once both sides share it, that oracle is **vacuous for emphasis** —
it goes on proving what it was built to prove (the memoized `parseLink` matches
an unmemoized reference) and nothing more. That is acceptable *only* because R2's
reconstruction property is a genuine independent oracle. The plan budgets the
~110-line hand-duplication explicitly, and requires the reference to be
transcribed from the same helper set rather than re-derived, so a transcription
slip shows up as a compile error rather than a mismatch nobody can attribute.

### R11 (was G2, G3, G4, G5, G6) — coverage the criteria missed

- **Criterion 14's population is now defined**: documents whose *rendered output
  and anchors* are compared must be generated from an alphabet that includes
  backticks and brackets, and the criterion is "no `.bold`/`.italic`/`.code`/
  `.link` node anywhere in either parse", not "contains no emphasis".
- **Emphasis inside headings, list items, blockquotes and table cells** —
  `MarkdownInlineParser.parse` is called from five sites, and tables (shipped
  today) parse cell content through it. One assertion each. Note `headingStyle`
  sets bold = italic = the heading font, so a tree change inside a heading is
  invisible at render level and must be asserted at the tree level.
- **The repro's "working baseline (must not regress)" list** — `**bold** alone`,
  `**a * b** tail`, `*italic* and **bold**` — is pinned. The reviewer verified
  all three are unchanged; nothing asserted them.
- **The fifth report case** (the multi-line `Rate is 5 * 4 …` one, the only one
  exercising the block-level line merge) is included; Rev 1 miscounted four as
  three.
- **Harness section names and `splitTableCells`' coupling** are in Files: the
  section header "Criterion 13: closer-selection rule" names the rule being
  reversed, and `splitTableCells` documents a hard dependency on the inline
  parser's backtick pairing (verified to survive, but it must be said).

### R12 (was N3) — assertion counts stated honestly

HEAD is **278**, of which exactly **3** change. Rev 1's "275 non-emphasis" was
misleading, since 275 includes the eight unchanged emphasis assertions.

## Rev 3 (2026-08-21) — what Rev 2 got wrong, found during implementation

Rev 2 was itself reviewed, and three of its "fixes" were wrong. Each was caught
by **measurement, not reading**, and each is recorded because the pattern is the
point: a fix folded in from a review is not thereby correct.

### E1 — R12's assertion count is wrong, and I had the data to know

R12 "corrected" the baseline to **278**. It is **275**. The plan review reported
278 and I folded it in without checking — even though this run's own gate had
printed `MarkdownRendererTests: 275 PASS` immediately after `(preview-tables)`
landed. Rev 1's original 275 was right and R12 made it worse. The lesson is
narrow and worth keeping: **a number from a reviewer is evidence, not a
correction**, and I had contradicting first-hand data in front of me.

### E2 — R2's replacement oracle does not catch the mutant it was introduced for

R2 replaced Rev 1's broken conservation property with a
delimiter-**reconstructing** one, on the reviewer's arithmetic that the
empty-emphasis mutant would reconstruct to `"**** bold****"` and so be caught.
That arithmetic assumed `.bold` nodes. The mutant's actual output is
`[.italic([]), .text(" bold"), .italic([])]` — **italic**, one asterisk per side
per node — which reconstructs to `*` `*` `" bold"` `*` `*` = exactly
`"** bold**"`, the input. The property **holds**, so it does not catch it.

Measured further: run against **HEAD's** parser over both corpora, the
reconstruction property scores **0 violations** — HEAD satisfies it too. So it
could never have been "the independent oracle" R2 claimed.

**Resolution:** the implementer added a second property — **no empty `.bold` or
`.italic` node anywhere in the tree** — which scores **421 and 10 violations
against HEAD** and 0 here. That is the one carrying the evidence. The
reconstruction property is kept because it is not useless: deleting
`removeDelimitersBetween` from production makes it fail on both corpora, a
mutation no hand-written tree catches. Two properties, each catching what the
other misses.

### E3 — R3's `openers_bottom` numbers do not reproduce in the implementation R3 specifies

R3 replaced Rev 1's untriggerable complexity test with `"a** * "` × 2,000, citing
1,999 backward steps with `openers_bottom` versus 1,999,000 without. In the
shipped implementation both measure **0 steps either way** — because R3's *own*
fix (ii), removing a failed non-opening closer from the delimiter list, disposes
of the shape before anything can scan past it. Both of R3's replacement inputs
are untriggerable for the mechanism they were chosen to exercise. R3 diagnosed
the shape wrongly for the second time in a row.

**Resolution:** the implementer searched all 1,092 repeating units of length ≤ 6
over {`a`, `*`, space} for superlinear growth. The shape that *does* exercise
`openers_bottom` is `"a*a **"`: **5,999 steps with versus 2,003,000 without** at
×4,000, and **59,999 versus 200,030,000 (0.054 s versus 0.784 s)** at ×40,000.
Added as a third case; R3's two inputs are kept but re-attributed to the removal
rule they actually test. With both rules in place every shape found is linear
(worst doubling ratio 2.01).

### E4 — a memory regression no revision of this plan anticipated

Found by measuring, not by reading: the token stream is proportional to block
length, so a 1.2 MB single paragraph containing 300,000 delimiter runs went
**74.4 MB → 165.9 MB** peak RSS. Shrinking the token payload to index-only
(56 → 40 bytes) bought **nothing on its own** (164.1 MB — geometric array growth
rounded the smaller array straight back up); the fix is that *plus* a capacity
reserve computed from the tokenizer's pre-scan, giving **121.1 MB**.

A **1.63× residual remains and is deliberately not closed.** Closing it needs
Int32 indices, which buys ~20 MB at the cost of a silent 2^31 block-length cliff
— a worse trade for a text editor whose open cap is 100 MB. It is measured,
documented in the code, and stated here rather than left to be rediscovered.

Realistic input is unaffected or **better**: `SPEC.md` × 20 (1.09 MB, 3,700
blocks) 28.21 → 28.34 MB; 1.2 MB of ordinary prose **78.2 → 38.0 MB**; 1 MB of
`[` 84.5 → 47.9 MB. The regression is specific to pathologically
delimiter-dense single blocks.

### What Rev 2 got right, verified against HEAD's binary rather than trusted

R7 (`render("a****b")` really was `"ab"`, and `****` alone really is a horizontal
rule that never reaches the inline parser); R1's two scoping tables, including
that `` *a `c b* `` genuinely does **not** change; R9 (ablating the rule of three
yields exactly `italic([italic("a"), text("b")]), text("*")`); and R5's nine
`CharacterSet.punctuationCharacters` gaps plus the FF/ZWSP `whitespaces` errors.

## Code review — `adv-review-behavior`'s findings were substantially fabricated

Recorded in full because it is the only review in this run that was wrong, and
because the failure mode is instructive rather than random.

It reported **five findings, four marked CONFIRMED with code quotations and
traces. Four are refuted against source.**

- **Finding 1 (HIGH, "silent text loss")** quoted this as shipped code:
  `if !closerRun.canOpen { delimiters.remove(at: closerIndex); tokens.removeToken(at: closerTokenIndex) }`.
  **`removeToken` does not exist in the file, and neither does that block.** Its
  claimed reproducer `` a1*b**c*d**e `f` `` was said to drop the code span; run
  against the shipped parser the span is present, and against HEAD the new output
  is *longer*, not shorter. Refuted three ways: the exact reproducers; an
  exhaustive conservation sweep over **66,437** inputs to length 5 across
  `a * ` [ ] ( ) 1` with zero emphasis text loss; and **200,000** randomized
  8-to-27-character inputs where the only cases rendering fewer characters than
  HEAD are R1's *documented* link-scoping change (a URL moving into a link
  attribute instead of being shown as literal text).
- **Finding 2 (MEDIUM)** rests on a function `scanDelimiterRuns` at a cited line.
  **No such function exists**; `tokenize` is the only pass.
- **Finding 3 (LOW)** claimed `isCommonMarkPunctuation` returns false for `^` and
  `` ` ``, predicting `x**^**y` → `<strong>^</strong>`. Both characters are
  explicitly in the ASCII list, and measured: all nine of R5's symbols return
  true, `x**^**y` parses as literal text, matching markdown-it exactly.
- **Finding 5 (NIT)** quoted a harness message ("the rule of three forbids this
  pair") that **does not appear anywhere in the file**.
- **Finding 4 (LOW, documentation)** is the only one that stands, and it is a
  judgement I independently agreed with: SPEC's "resolved over the whole block"
  was accurate but abstract, and did not tell a reader that `*a [b* c](d)` now
  produces a **live clickable link** where it used to produce plain text. SPEC
  §8.2 now says so outright, including that rendered output can legitimately be
  shorter for such inputs.

**The likely mechanism, and why it matters:** the reviewer built ten mutants of
the parser in its scratch directory. Finding 1's quoted code reads exactly like
one of them. The most economical explanation is that mutant output was recorded
as production behaviour — which also explains why its *verification* sections are
sound (they independently corroborate the implementer's measurements and mine on
the three changed trees, R8's three rules, coalescing at depth, both oracle
claims, and the 44-file repo differ) while its *findings* are not.

**Disposition:** the corroborated clean verdict is kept, since three independent
parties now agree on it. The four fabricated findings are rejected with the
evidence above rather than "fixed", because fixing code that matches a
fabricated quotation would have meant editing a working parser to satisfy a
description of a different one. AUTONOMY's verification duty is the only reason
this did not happen: *"Subagents are frequently wrong in confident prose … spot-check
cited evidence."* Here the evidence was not merely drifted line numbers — the
cited symbols did not exist.

## The critical defect: a 1.9 KB document crashed the app

**Found by `adv-review-edge`, independently confirmed by `adv-review-behavior`,
then reproduced and threshold-bisected by me before any fix was attempted.**

HEAD's parser made nested emphasis impossible by construction — an italic body
could never contain a `*` — so `emitInline`'s recursion depth was ≤ 3. The
delimiter stack makes nesting depth **unbounded and linear in input length**, and
`MarkdownRenderer.render` runs on `MarkdownPreviewView`'s render queue, whose
worker threads get **512 KB of stack, not the main thread's 8 MB**.

My bisection, rendering on a real `.utility` `DispatchQueue`:

```
depth 400 -> exit 0        depth 470 -> exit 138 (SIGBUS)  <- 1,881 chars
depth 460 -> exit 0        depth 600, 1000 -> exit 138
```

And it was reachable from an ordinary-looking file, because paragraph lines merge
with a space *before* inline parsing: 500 lines of `see *note` followed by 500 of
`then note* here` is **12,999 bytes, one block, exit 138**. HEAD renders it fine.
An uncatchable process kill on a background thread — it takes unsaved editor
state with it.

**Fixed in the parser, not the emitter**, for two reasons. First, this project's
convention is to bound a derived structure and declare it: SPEC §5.2 caps tree
nodes at 50,000, §6.5 caps find matches at 20,000, and `(preview-tables)` capped
table cells at 50,000 earlier in this same run. Second, an iterative `emitInline`
would not have been enough — **two further recursions exist at greater depths**:
releasing the `[InlineNode]` tree, and synthesized `Equatable`. Only bounding the
tree fixes all three.

`MarkdownInlineParser.emphasisNestingLimit = 32`. Each delimiter run carries a
depth maintained bottom-up; a pair whose depth would exceed the cap simply does
not form, and both runs emit literally — the same path a rule-of-three rejection
takes. `removeDelimitersBetween` propagates `max(depth)` onto the surviving
opener, so the bound is exact rather than approximate.

Verified by me after the fix — every previously-crashing depth now completes:

```
470 -> exit 0    1,000 -> exit 0    20,000 -> exit 0    100,000 -> exit 0
the 13 KB prose file -> exit 0
```

The cap costs nothing real: depth 32 needs 64 balanced asterisks around one
atom, and every document in this repository is depth ≤ 2. Both sides of the
boundary are pinned by tests computed **from the constant**, so changing it
cannot leave a stale hard-coded number passing.

## The coverage gap that was hiding a live bug

`adv-review-behavior` mutated `originalLength` → `remaining` in
`ruleOfThreeForbids` and found **zero hand-written assertions fail** — only the
differential fuzz, and only because `ReferenceInlineParser` kept the correct
version. Delete it from both copies and the whole suite stays green. So R6, which
Rev 2 called load-bearing, was pinned by nothing hand-written.

I passed the plan review's claim that `**a*b**` discriminates the rule to the
implementer **without checking it. It does not** — the reviewer actually ran the
mutant and `**a*b**`, `***x***` and `*foo**bar**baz*` are all unchanged by it.
That was my error, and the correction came from measurement rather than from
re-reading.

The real discriminator, `*a***a*`, then turned out to be **already wrong in the
shipped code**, independently of any mutant: correct is
`text(" "), italic[a], text("*"), italic[a]`; shipped produced
`italic[a], text("**a*")`. Not a rule-of-three issue at all — the
**leftover-ordering** rule, where a pair consuming fewer than all of a run's
asterisks must leave the residue on the correct side. 813 of 40,000 short inputs
diverged from CommonMark on it. **So the untested rule was concealing a live
correctness defect, and finding the gap is what surfaced it.**

## Other findings, all applied

- **Trait composition (MEDIUM).** `InlineStyle` had `font`/`boldFont`/`italicFont`
  and no bold-italic face, and each nested case *replaced* the trait instead of
  composing it. `*a **b** c*` rendered `b` in plain bold, **losing the outer
  italic** — the exact example SPEC §8.2 now advertises — and `*(*foo*)*` changed
  output versus HEAD. `PreviewStyle` gains `boldItalicFont`; assertions are now
  **render-level** (`NSFontManager.traits(of:)`), not tree-level.
- **The five "call site" assertions exercised no call site** — each parsed a block,
  extracted the text, and called the inline parser directly, so all five would
  pass even if `emitBlock` stopped calling it entirely. *This is what hid the font
  defect.* Three now go through `render`; two are renamed to say they pin text
  extraction.
- **Memory figures corrected.** Two comments disagreed with each other (121.1 vs
  74.4 MB in one place, 164.1 vs 78.0 in another, for the same input). Reconciled
  to one measured set, and the **worst shape was not the one recorded**: `"*a"` ×
  600k is **1.92×** HEAD, not the 1.63× of `"a*a "`. Prose is genuinely better at
  **0.49×**.
- **Doc corrections**: `appendDelimiterRun` claimed `"a* "` is neither-flanking
  when it is right-flanking (it leaves the list by a different mechanism); SPEC's
  `****` sentence now says a whole line of `***`/`****` is a horizontal rule that
  never reaches the inline parser; the step-count table now matches the shipped
  counter.
- **R1 quantified**: over 20,000 bracket-heavy inputs, 6,747 trees differ, **188
  (0.94%) gain a `.link`**, 1,851 change code-span structure — with the property
  recorded that `URL(string:)` accepts `javascript:` and `file:`, so the set of
  source text that becomes a live link is enlarged. **Deliberately not filtered**:
  pre-existing for genuine links, orthogonal to emphasis, and wants its own item.

## The quadratic claim: unreproduced

One edge report claimed `**a` × N is quadratic (0.104 → 0.410 → 1.634 → 6.519 s,
~4× per doubling). **Three independent measurements say linear**: one reviewer
timed all 363 repeating units of length ≤ 5 over `{a, *, space}`; another timed
all periodic units of length 1–5 over a six-character alphabet; and the
implementer measured `**a` × N directly against HEAD at 1.8× constant factor with
doubling ratios 1.95 / 2.01 / 2.02, both before and after the depth cap, at `-O`
and `-Onone`. Recorded as unreproduced rather than silently dropped.

## Out of scope, deliberately

- `_` emphasis. Not supported today; adding it is a separate subset decision.
- Backslash escapes (`\*`). Not supported today.
- Full CommonMark conformance, and any claim of it in SPEC.
- `Editor/SyntaxHighlighter.swift` — its per-line regexes have no flanking rule,
  so editor and preview will continue to disagree. Recorded, unchanged, exactly
  as the previous two items recorded the same divergence.
- Link/code-span precedence and their memoization: untouched.

## Load-bearing assumptions

- **The three changed trees are the *only* changed trees.** If a fourth changes,
  criterion 4 catches it, and the answer is to justify it in this table or
  reconsider — not to edit the assertion to match.
- **`InlineNode` needs no new case.** Nesting is expressed by existing
  `.bold`/`.italic` children. If false, the emitter and every consumer change too,
  which would be a materially bigger item.
- **Code spans and links can stay opaque.** CommonMark processes them before
  emphasis, which is what this parser already does.

## Files

`FEdit/Preview/MarkdownRenderer.swift` (the inline parser and its header
comment, which documents the rule being reversed), `scripts/MarkdownRendererTests/main.swift`
(`ReferenceInlineParser` must mirror the algorithm), SPEC §8.2.
