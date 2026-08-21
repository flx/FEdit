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
