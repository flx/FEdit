# md-link-scan-quadratic

**Risk tier:** hi — this edits the shipped HI-risk inline parser (`MarkdownInlineParser`), specifically the delimiter-search machinery inside the `[`…`]`…`(`…`)` link scan that the closer-selection rule and the downstream (markdown-preview) scroll-sync anchors both run through. The change is provably a no-op memoization (it returns the same indices the current `firstIndex` scans return), and the blast radius is one method plus one helper build-step in one file — but the tier stays **hi** because the code path is the exact one on which byte-identical `NSAttributedString` output and the strict anchor-ordering invariant depend; a subtle off-by-one in the memo would corrupt every link parse silently.

## Goal

Remove the O(n²) blow-up in `MarkdownInlineParser`'s inline link parsing on bracket-heavy input **without changing a single byte of observable output**. Today, on a failed link the driver emits `[` literally and advances ONE character, and the next `[` re-scans to EOF for `]`/`)`; a document of thousands of unmatched brackets degrades quadratically (`[`×40000 ≈ 6 s per the TODO), which is a live-preview cliff. The fix replaces the two to-EOF `firstIndex` scans inside `parseLink` with O(1) lookups into two per-invocation precomputed "nearest closer at/after position i" arrays, making the whole inline scan **truly O(n)** for every input — including the adversarial `[`×N + one `]` case that a watermark cannot fix. The produced `[InlineNode]` tree, the emitted `NSAttributedString` (string + attributes), and the `[MarkdownAnchor]` array must be **byte-identical to the current renderer for every input**.

## Chosen algorithm & why (not the watermark)

**Where the quadratic actually is.** Only the LINK path is quadratic. The scan-position driver in `parseNodes` tries constructs in the fixed order code span → link → bold → italic. For code span (`` ` ``), bold (`**`), and italic (`*`), a *repeated* delimiter always pairs up and is consumed (the first opener finds the next occurrence as its closer and the index jumps past it), so a delimiter can fail its forward scan **at most once** per invocation — those paths are already amortized linear. The `[` is different: a link needs the whole `]`…`(`…`)` shape, and on any failure the driver emits just `[` and advances ONE character, so the *next* `[` re-scans from scratch. `parseLink` performs two to-EOF scans (`firstIndex(of: "]", from: open + 1)` then `firstIndex(of: ")", from: paren + 1)`); with N unmatched `[`, that is N scans of O(N) each = O(N²).

**Three distinct pathological families** (all measured/derived, all must end up linear AND byte-identical):
1. `[`×N — no `]` anywhere: each `[` scans to EOF for `]`, returns nil. (`[`×40000 ≈ 6 s.)
2. `[a](b`×N — no `)` anywhere: each `[` finds a nearby `]` and `(`, then scans to EOF for `)`, returns nil. (`[a](b`×10000 = 50 000 chars.)
3. `[`×N + one `]` (or `[`×N + `](`) — a `]` (or `](`) *does* exist at the end: each `[` scans forward and **finds** the far `]`, then fails because it is not followed by `(` (or the `(` has no `)`). Every scan *succeeds* at finding `]`, so no "there is no `]` after p" fact is ever learned.

**Why the watermark is rejected.** A monotonic watermark ("cache: no `]` at/after p; no `)` at/after q; once a forward scan returns nil, short-circuit all later scans from ≥ that position") fixes families 1 and 2 — which happen to be the two *measured* inputs — but leaves family 3 fully quadratic, because in family 3 every `firstIndex(of: "]")` scan *returns non-nil* (it finds the trailing `]`), so the "no `]`" watermark never trips and each `[` still walks ~N characters to the far `]`. Shipping a fix that is still O(n²) on `[`×40000 + `]` would not survive adversarial review.

**Chosen fix: precomputed nearest-closer arrays (true linear, provably identical), built lazily.** In each `parseNodes(_ characters:)` invocation, **only if `characters` contains at least one `[`**, build two `[Int]` of length `count + 1` in a single backward pass; when the slice has no `[` at all, skip the build entirely and take the zero-allocation path exactly as today (`parseLink` is never reached, so the arrays are never consulted). This keeps the hot path free: bracket-free paragraphs — the overwhelmingly common per-keystroke-debounce preview input — pay **zero** extra allocation versus the current renderer. The `[` pre-check is a single O(m) `characters.contains("[")` scan (the loop already walks the slice), amortized into the same linear budget. As `Optional` locals `nextCloseBracket: [Int]?` / `nextCloseParen: [Int]?` built on first need, or gated behind the `contains` pre-check — either spelling is fine so long as no array is allocated for a bracket-free slice.

```
// only when characters.contains("[")
nextCloseBracket[count] = count            // sentinel: "none at/after here"
nextCloseParen[count]   = count
for i in stride(from: count - 1, through: 0, by: -1):
    nextCloseBracket[i] = (characters[i] == "]") ? i : nextCloseBracket[i + 1]
    nextCloseParen[i]   = (characters[i] == ")") ? i : nextCloseParen[i + 1]
```

By construction `nextCloseBracket[f]` equals `firstIndex(of: "]", in: characters, from: f)` for every `f` (the nearest occurrence at/after `f`), with the sentinel `count` standing in for `nil`; identically for `nextCloseParen` / `)`. Since `parseLink` runs only after the driver sees a `[`, the arrays are guaranteed built whenever they are read. `parseLink` then does **O(1)** lookups instead of scans:

- `let closeBracket = nextCloseBracket[open + 1]; guard closeBracket < count else { return nil }`
- `let paren = closeBracket + 1; guard paren < count, characters[paren] == "(" else { return nil }`
- `let closeParen = nextCloseParen[paren + 1]; guard closeParen < count else { return nil }`
- `title`, `url`, `end` computed exactly as today.

This covers **all three families** including family 3 (the array lookup is O(1) regardless of how far the far `]` is), so the whole `parseNodes` scan is O(n). It is a pure **memoization of the existing `firstIndex` calls** — the returned index is identical for every position — so the parse tree cannot change. This is the decisive reason it is chosen over the watermark: same asymptotics guarantee across *every* bracket shape, and a one-line-lemma correctness argument ("the array is the memo of `firstIndex`").

**True linearity under recursion (the one thing to prove).** `parseNodes` recurses only on **bold bodies** and **italic bodies**, each on a fresh `Array` slice, so the arrays are rebuilt per invocation at O(slice length). Total work stays O(n) because emphasis nesting depth is O(1): an italic body contains **no** `*` (the nearest `*` after the opener *is* the closer, so the body `[open+1, close)` has none) ⇒ an italic body never re-enters bold or italic; a bold body contains **no** complete `**` (the first `**` after the opener is the closer) ⇒ a bold body may contain single `*` (italic) but no nested bold. So the emphasis recursion is at most top → bold → italic → leaf (depth ≤ 3), and the slices at each depth are disjoint substrings of the original ⇒ Σ(slice lengths) ≤ 3·n. The current code *already* pays this Σ via its `Array(characters[range])` slice copies at every bold/italic; adding an O(slice length) array build alongside each copy is the same order, so there is **no asymptotic regression** from the per-invocation rebuild.

**Interaction with code span / bold / italic (unchanged).** The scan-position driver's try-order (code span → link → bold → italic) is untouched; only the two delimiter searches *inside* `parseLink` change. The backtick / `**` / `*` searches are deliberately **not** memoized — they are already amortized linear (delimiters pair up; at most one failed scan each), and memoizing them would enlarge the diff and the space for zero benefit. Because the inline tree is byte-identical, the Tier-3 emitter produces a byte-identical `NSAttributedString`, hence identical block emission lengths, hence an identical `[MarkdownAnchor]` array (anchors are a function only of block structure + emitted lengths, neither of which moves).

## Acceptance criteria

All criteria are asserted by the existing swiftc harness `scripts/MarkdownRendererTests/main.swift`, extended in the tiers below and run via:

```
swiftc FEdit/Preview/MarkdownRenderer.swift FEdit/Editor/Theme.swift scripts/MarkdownRendererTests/main.swift -o /tmp/mdtests && /tmp/mdtests
```

1. **No regression** — all **133** existing assertions pass **unchanged** (the four adversarial closer-selection trees `**a*b**` / `***x***` / `**a**b**` / `*a **b** c*`, the anchor strict-double-ascent incl. empty blocks, no-character-loss, edge inputs, determinism). Not one existing assertion is edited or deleted.
2. **Exact output equivalence — inline trees.** For a battery of bracket-heavy inputs, `MarkdownInlineParser.parse` returns exactly the trees the *current* parser returns (hand-derived from the unchanged semantics and verified against the shipped binary during planning):
   - `[`×N → `[.text(String(repeating: "[", count: N))]` (family 1; all `[` literal, coalesced into one node).
   - `[a](b`×N → `[.text(<the whole input>)]` (family 2; all literal, coalesced).
   - `[`×N + `"]"` → `[.text(<input>)]` and `[`×N + `"]("` → `[.text(<input>)]` (family 3; the `]`/`](` exists but the link still fails — the watermark-defeating cases).
   - Real link followed by trailing unmatched brackets: `"[a](b)" + [`×N → `[.link(text: "a", url: "b"), .text(String(repeating: "[", count: N))]`.
   - Nearest-closer with a bracket inside the title (locks the "nearest `]`" semantics the array must reproduce): `"[[x](y)"` → `[.link(text: "[x", url: "y")]`; `"[[[[[x](y)"` → `[.link(text: "[[[[x", url: "y")]`.
   - Code span containing a link shape (confirms code-span precedence and that brackets inside a code span never reach `parseLink`): `` "`[a](b)`" `` → `[.code("[a](b)")]`.
   - Bold body containing unmatched brackets (confirms the per-invocation array is rebuilt correctly for a recursive slice): `"**[[[**"` → `[.bold([.text("[[[")])]`.
3. **Differential-fuzz / golden equivalence (insurance beyond the enumerated battery).** A randomized bracket-heavy differential fuzz (Tier 1) generates many inputs drawn from the alphabet `{ [ ] ( ) a * ` space }` (the characters that exercise link, code-span, and emphasis interaction) at varied lengths and asserts, for each, that the new `MarkdownInlineParser.parse` output equals a **reference tree computed by a naive nearest-`firstIndex` link scan** implemented locally in the harness (the pre-fix semantics), across a fixed seed so runs are deterministic. This catches an implementation slip (e.g. an off-by-one in the array build or a `< count` vs `<= count` guard) that the hand-enumerated cases in criterion 2 might miss. The fuzz additionally feeds each input through `MarkdownRenderer.render` and asserts the produced `output` is `isEqual(to:)` the reference renderer's output **and** the `anchors` array is equal — so anchor `sourceLine`/UTF-16 `location` non-regression is proven directly, not just inferred. (A captured golden corpus of `(input → expected [InlineNode] + output + anchors)` pairs, snapshotted from the current renderer, is an acceptable substitute if a harness-local reference scan is deemed heavier than warranted.)
4. **Zero extra allocation on the hot path.** For any slice containing no `[`, the fix allocates nothing beyond what the current renderer allocates — the two arrays are built only when `characters.contains("[")`. This keeps the per-keystroke-debounce preview of ordinary (bracket-free) prose exactly as cheap as today.
5. **Complexity / performance (advisory tripwire).** The pathological inputs no longer degrade quadratically: `parseLink` is O(1) and the `parseNodes` scan is O(n) (argument in "Chosen algorithm"). This is the guarantee. As an **advisory** regression tripwire, Tier 2 asserts `[`×40000, `[a](b`×10000, and `[`×40000 + `"]"` each render under a loose wall-clock ceiling with ~100× margin over expected linear time (the current code takes ≈ 6 s on `[`×40000; the ceiling sits between linear-with-margin and the quadratic cliff). The ceiling is deliberately generous to avoid CI flakiness; a wall-clock number is never the proof, only the complexity argument is.
6. **No API / behavior change.** The public surface (`MarkdownInlineParser.parse`, `MarkdownRenderer.render`, `MarkdownAnchor`, `InlineNode`) is byte-for-byte unchanged in signature and in output. The only edited code is internal to `MarkdownInlineParser`. No project-file, scheme, or `Theme.swift` change.

## Tiers

Verification for every tier is the swiftc harness command above (`xcodebuild` must also still succeed, since the edited file is in the app target).

### Tier 1 — memoize `parseLink`'s closer search + exact-equivalence assertions

Buildable/revertible unit: revert = restore `parseLink`'s two `firstIndex(of: "]" / ")")` calls, delete the array build in `parseNodes`, and drop the new equivalence assertions. All 133 existing + new equivalence assertions green.

- **Modify `FEdit/Preview/MarkdownRenderer.swift` — `MarkdownInlineParser` only:**
  - In `parseNodes(_ characters: [Character]) -> [InlineNode]`, before the `while index < count` loop, **only when `characters.contains("[")`**, build `nextCloseBracket: [Int]` and `nextCloseParen: [Int]` (length `count + 1`, sentinel `count`) via the single backward pass shown above. A bracket-free slice allocates neither array (criterion 4) — the driver never calls `parseLink` in that case, so the arrays are never read. Spelling is implementer's choice (`Optional` locals lazily built, or a `contains` gate) as long as the zero-allocation-when-no-`[` property holds.
  - Change `parseLink`'s signature to take the two arrays (e.g. `parseLink(_ characters: [Character], from open: Int, nextCloseBracket: [Int], nextCloseParen: [Int])`) and replace its two `firstIndex` calls with the O(1) lookups + `< count` guards shown above. Everything else in `parseLink` (the `characters[paren] == "("` check, `title` / `url` / `end` slicing) is unchanged.
  - Update the one call site (`if let link = parseLink(characters, from: index)`) to pass the two arrays. This call site is reached only after `characters[index] == "["`, which implies the slice contains a `[` and the arrays are built.
  - **Do not touch** the code-span (`firstIndex(of: "`")`), bold (`firstDoubleIndex(of: "*")`), or italic (`firstIndex(of: "*")`) paths, the driver try-order, `firstIndex`/`firstDoubleIndex` helpers (still used by those paths), the block parser, the emitter, or the anchor logic.
- **Extend `scripts/MarkdownRendererTests/main.swift`** — two new sections:
  - "md-link-scan-quadratic: bracket-heavy output equivalence" asserting every tree in acceptance criterion 2 (using small N, e.g. N = 5–8, so the expected trees are written out explicitly and are readable). These lock byte-identical output on the named cases.
  - "md-link-scan-quadratic: differential fuzz" implementing acceptance criterion 3: a harness-local `referenceParse` using the naive nearest-`firstIndex` link scan (the pre-fix semantics), a seeded PRNG generating N inputs over `{ [ ] ( ) a * ` space }` at varied lengths, asserting `MarkdownInlineParser.parse(input) == referenceParse(input)` and `MarkdownRenderer.render(input)` output+anchors equal the reference for each. Fixed seed ⇒ deterministic run.

### Tier 2 — advisory performance tripwire

Buildable/revertible unit: revert = delete the perf section. Harness green.

- **Extend `scripts/MarkdownRendererTests/main.swift`** — a new section "md-link-scan-quadratic: no quadratic cliff (advisory)" that, for each of `[`×40000, `[a](b`×10000, and `[`×40000 + `"]"`, measures wall-clock around `MarkdownRenderer.render` (or `MarkdownInlineParser.parse`), prints the elapsed time, and `check`s it against a conservative absolute ceiling (e.g. `< 1.0` s) that the shipped linear version clears by ~100× and the pre-fix quadratic version (≈ 6 s on the first input) blows through. This tripwire is **accepted as advisory** (criterion 5): the ceiling is loose to avoid CI flakiness on slow machines, and the real guarantee is the O(n) complexity argument, not the wall-clock number. The section header comment must state this. (Optional secondary check: a doubling-ratio sanity assertion `t(2N) < 3·t(N)` for the `[`×N family, noting it is advisory on fast machines where both times are noise-dominated.)

## Interface between tiers

- **Public API is frozen and unchanged** across both tiers: `MarkdownInlineParser.parse(_:) -> [InlineNode]`, `MarkdownRenderer.render(_:) -> (NSAttributedString, [MarkdownAnchor])`, `MarkdownAnchor`, `InlineNode`. The whole point of the change is that these are byte-identical before and after.
- Tier 1 changes only the *private* `parseLink` signature and adds a private array build in `parseNodes`; nothing outside `MarkdownInlineParser` observes it.
- Tier 2 depends only on Tier 1 having made `parse` / `render` linear; it adds no code surface, only harness assertions.

## Load-bearing assumptions

- **`nextCloseX[f]` ≡ `firstIndex(of: X, in: characters, from: f)`** for all `f`, with sentinel `count` ≡ `nil`. This is the entire correctness argument; it is exact because the backward recurrence records the nearest occurrence at/after each position. Verified during planning against the shipped binary for all criterion-2 inputs.
- **Emphasis recursion depth is O(1)** (top → bold → italic → leaf): an italic body contains no `*`, a bold body contains no complete `**`. This bounds Σ(slice lengths) ≤ 3·n, keeping the per-invocation array rebuild linear overall. It is the same Σ the existing `Array(characters[range])` slice copies already pay, so there is no asymptotic regression.
- **Only the link path is quadratic.** Code-span/bold/italic delimiters pair up and fail at most once per invocation, so they need no memoization; the driver try-order (code span → link → bold → italic) is preserved.
- **The lazy `[` pre-check preserves the hot path.** Building the arrays only when `characters.contains("[")` means bracket-free prose (the common debounced-preview input) allocates exactly what it does today; the pre-check is one O(m) scan folded into the same linear budget. `parseLink` is reached only after a `[` is seen, so "read implies built" holds without a nil-array hazard.
- **Anchors depend only on block structure + emitted lengths.** Because the inline tree and thus every emitted run length is unchanged, the `[MarkdownAnchor]` array (strict-ascending `sourceLine` and UTF-16 `location`) is unchanged. (markdown-preview) scroll-sync is unaffected.
- The existing harness (133 assertions) is the source of truth for current semantics; `swiftc` is available; `Theme.swift`'s `import AppKit` compiles under plain `swiftc` on macOS (as today). No test target / `project.pbxproj` / scheme change.

## Out of scope

- **Any parser behavior change.** This is purely a performance optimization; no new construct, no altered closer-selection, no changed literality, no backslash escapes — all remain as shipped (SPEC §8.2 non-goals unchanged).
- **Memoizing the backtick / `**` / `*` scans** — already amortized linear; left untouched to keep the diff and correctness argument minimal.
- **The recursive `Array(characters[range])` slice copies** in the bold/italic branches — their own O(n)-total cost is pre-existing and not addressed here (it is not quadratic).
- **The block parser (`MarkdownBlockParser`)**, the Tier-3 emitter, `MarkdownAnchor`/anchor logic, `Theme.swift`, and any view/preview/scroll-sync code — none are modified.
- **Precise benchmarking / a benchmark harness** — Tier 2 ships a loose cliff tripwire, not a performance-tracking suite.

## Auto-resolved (plan review)

Plan review found **NO defects**: a 600k-input bracket-heavy differential fuzz confirmed byte-identical output between the memoized and current parsers, and the core lemma (`nextCloseX[f]` ≡ `firstIndex(of: X, from: f)`) was checked against the real `parseLink`. The following **TENSION** resolutions were folded in; no criterion was weakened.

1. **(T1 — hot-path allocation) Lazy array build.** The `nextCloseBracket`/`nextCloseParen` arrays are built **only when the local `characters` contains at least one `[`** (a cheap `contains` pre-check / lazy build). Bracket-free paragraphs — the dominant per-keystroke-debounce preview input — pay **zero** extra allocation versus today, since the driver never reaches `parseLink` and the arrays are never referenced. Folded into the Chosen-algorithm section, acceptance criterion 4, the Tier-1 step, and load-bearing assumptions. `parseLink` is reached only after a `[` is seen, so "read implies built" holds with no nil-array hazard.
2. **(T2 — verification depth) Differential fuzz added.** Beyond the enumerated bracket-heavy battery (criterion 2), the harness gains a seeded randomized differential fuzz over `{ [ ] ( ) a * ` space }` that diffs `MarkdownInlineParser.parse` **and** `MarkdownRenderer.render` (output + anchors) against a harness-local naive-`firstIndex` reference implementing the pre-fix semantics (criterion 3, Tier-1 step). This is insurance against an off-by-one the enumerated cases miss; a snapshotted golden corpus is accepted as an equivalent substitute.
3. **(T3 — perf assertion status) Wall-clock accepted as advisory.** The wall-clock ceiling is explicitly an **advisory** regression tripwire (~100× margin, loose to avoid CI flakiness); the guarantee is the O(n) complexity argument, never the timing number. Recorded in criterion 5 and the Tier-2 heading.
4. **(T4 — vague criterion) Old render-equivalence wording replaced.** The original criterion 3 ("`output` is `isEqual(to:)` the string built from the equivalent all-literal paragraph") was vague about the reference construction. It is **dropped** — tree identity (criterion 2) plus the differential fuzz (criterion 3, which diffs `render` output + anchors against a named reference renderer) prove render-level and anchor/UTF-16 equivalence more rigorously than the hand-built-string comparison did.
