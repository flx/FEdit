# filter-anchors

**Risk tier:** standard — a localized, string-matching-only change to one already-tested pure model file (`FilterQuery.swift`) plus a placeholder string and SPEC prose. The tokenizer and the AND/OR grouping logic are untouched; only term *construction* changes. The existing `swiftc` assertion harness both guards regressions and is the delivery vehicle for new coverage.

## Goal

Add fzf/regex-style path anchors to the filter query language (SPEC §5.5): a trailing `$` on a term anchors the match to the **end** of the root-relative path, a leading `^` anchors to the **start**, and both together require both. Anchors are a per-term property, orthogonal to `AND`/`OR` grouping. Malformed anchor usage (bare `^`/`$`, or one appearing mid-term) degrades to a literal character per the existing malformed-input policy (SPEC §5.5 last bullet) — it must never crash, never silently drop the term, and never regress the current case-insensitive substring behavior for ordinary (non-anchored) terms.

## Acceptance criteria

All criteria are testable via the verification harness (H) unless marked (A) for a manual app run.

Anchor semantics:

1. (H) `.swift$` matches `foo.swift`; does **not** match `foo.swiftdep`.
2. (H) `^src/` matches `src/a.swift`; does **not** match `x/src/a.swift` or `lib/src/a.swift` (anchored to the start of the *whole* relative path, not a path-segment boundary).
3. (H) `^a$` (both anchors) matches path `a` exactly; does not match `ab` or `ba`. This is implemented as `hasPrefix(a) AND hasSuffix(a)` composed from the two anchored range checks — **not** a special-cased equality check — so it degrades correctly when the term is longer than the path (both checks fail, no match) and reduces to equality only because prefix-anchored and suffix-anchored searches for the same text on the same string coincide exactly when the string equals the text.
4. (H) Case-insensitivity is preserved for anchored terms: `.SWIFT$` matches `foo.swift`; `^SRC/` matches `src/a`.
5. (H) A bare `^` or bare `$` (the entire term is one anchor character, nothing else) is treated literally: `^` matches any path containing a literal `^` character (e.g. `a^b`); it does not act as an anchor. Same for a bare `$`.
6. (H) An anchor character appearing mid-term is literal, not an anchor: `a$b` matches `xa$by` as a plain substring; `.swift$b` (trailing char after `$`) is NOT end-anchored (the `$` is not the last character) and matches as a plain substring containing `.swift$b`.
7. (H) At most one leading `^` and one trailing `$` are ever stripped: `^^a` strips exactly one leading `^`, leaving the literal text `^a` (start-anchored) — it matches `^ab` and `^a` but not `ab` (no literal caret).
8. (H) Anchors are a per-term property independent of `AND`/`OR` grouping: `^src/ AND .swift$` is a single AND-group of two anchored terms — matches `src/main.swift`, does not match `src/main.py` or `lib/main.swift`.
9. (H) Existing non-anchored behavior is unchanged: every pre-existing harness assertion still checks the same values and passes. The `.groups ==` assertion *literals* are mechanically rewritten to the new `[[MatchTerm]]` element type (see Tier 1) — the behavior asserted is identical; only the literal syntax changes because the element type changed from `String` to `MatchTerm`.
10. (A) The sidebar search field placeholder mentions an anchor example and the field still filters correctly by eye with an anchored query (e.g. `.swift$`).

## Tiers

### Tier 1 — Anchor parsing + matching in `FilterQuery.swift`, with harness coverage

Independently buildable and revertible: touches one model file and one out-of-target test script; no view or SPEC change required for this tier to compile and pass.

**Modify `FEdit/Models/FilterQuery.swift`:**

- **Data model decision: introduce `struct MatchTerm`, replacing the raw `String` element of `groups`.** Rejected alternative: keep `groups: [[String]]` and re-parse `^`/`$` out of each term string inside `matches(_:)` on every call. Rejected because (a) `matches(_:)` is invoked once per file in the corpus on every keystroke (SPEC §11 accepts the linear scan but does not invite doing the same substring-stripping work redundantly for every file when it is invariant per term), (b) it would duplicate the stripping/degradation logic at two call sites if anything else ever needs a term's anchor state (e.g. future match-range highlighting), and (c) it breaks the project's own precedent — `groups` is already exposed as structured, harness-assertable state (see the existing internal-visibility comment on `groups` and on `FilterToken`) specifically so the harness can assert structure, not just behavior. A struct parsed once at term-construction time is the cleaner fit.

  ```swift
  /// A single filter term with optional fzf/regex-style path anchors (SPEC §5.5): a leading `^`
  /// anchors the match to the start of the root-relative path, a trailing `$` to the end. Parsed
  /// once from the raw token text; `matches(_:)` uses the stripped `text` plus the two flags to
  /// pick a case-insensitive contains/prefix/suffix/both check. Internal (not private) so the
  /// harness can assert the parsed fields directly.
  struct MatchTerm: Equatable {
      let text: String
      let anchorStart: Bool
      let anchorEnd: Bool

      /// Direct field initializer, used by the harness to build expected values without going
      /// through anchor parsing (avoids circular self-testing).
      init(text: String, anchorStart: Bool, anchorEnd: Bool) {
          self.text = text
          self.anchorStart = anchorStart
          self.anchorEnd = anchorEnd
      }

      /// Parses `raw` into literal text plus anchor flags. Order is left-to-right and each strip
      /// is vetoed if it would leave zero literal characters, so `text` is never empty:
      ///   1. Strip a leading `^` only if `raw` has more than one character.
      ///   2. On what remains, strip a trailing `$` only if that remainder has more than one
      ///      character.
      /// This directly implements the degradation rules: a bare `^` or bare `$` (one-character
      /// term) is left untouched (both flags false, literal text unchanged); an anchor character
      /// that is not the very first/last character is never stripped because `hasPrefix`/
      /// `hasSuffix` only ever look at position 0 / the last position; `^^a` strips exactly one
      /// leading `^` (the count-check applies to the second `^` only via the *remaining* text,
      /// which is `^a`, itself with a literal leading caret that fails the `> 1 char after strip`
      /// re-entry — there is no re-entry, this init runs once); and the corner case `^$` (two
      /// characters, both anchor characters, zero literal content either way) strips only the
      /// leading `^` — stripping it first leaves `$` (1 char), which then fails the "leave > 0
      /// chars" guard for the trailing strip — so `^$` parses to `anchorStart: true, anchorEnd:
      /// false, text: "$"`, never to an empty `text`. (Keeping at least one literal character is
      /// what makes bare `^`/`$` degrade to a *literal* match per SPEC §5.5. Note Foundation's
      /// `range(of: "", options:)` returns `nil`, so an empty `text` would make every branch of
      /// `matches` return `false` — the term would silently match nothing, not "everything"; the
      /// guard exists to preserve literal-degradation semantics, not to avoid a match-all.)
      init(_ raw: String) {
          var remainder = Substring(raw)
          var start = false
          var end = false

          if remainder.count > 1, remainder.hasPrefix("^") {
              start = true
              remainder = remainder.dropFirst()
          }
          if remainder.count > 1, remainder.hasSuffix("$") {
              end = true
              remainder = remainder.dropLast()
          }

          self.text = String(remainder)
          self.anchorStart = start
          self.anchorEnd = end
      }

      /// Case-insensitive match of `text` against `relativePath`, per the anchor flags. Naive
      /// `String.hasPrefix`/`hasSuffix` are case-SENSITIVE, so every branch goes through
      /// `range(of:options:)` instead:
      ///   - no anchors: `.caseInsensitive` (unchanged `contains` behavior).
      ///   - `anchorStart` only: `[.caseInsensitive, .anchored]` — anchors the search to the
      ///     start of `relativePath` (case-insensitive `hasPrefix`).
      ///   - `anchorEnd` only: `[.caseInsensitive, .anchored, .backwards]` — anchors to the end
      ///     (case-insensitive `hasSuffix`). `.backwards` combined with `.anchored` moves the
      ///     anchor from the start of the search range to the end; it is not a right-to-left
      ///     scan here since the range is unconstrained.
      ///   - both: the two anchored checks, ANDed — see criterion 3 for why this is not
      ///     special-cased as an equality check.
      func matches(_ relativePath: String) -> Bool {
          switch (anchorStart, anchorEnd) {
          case (false, false):
              return relativePath.range(of: text, options: [.caseInsensitive]) != nil
          case (true, false):
              return relativePath.range(of: text, options: [.caseInsensitive, .anchored]) != nil
          case (false, true):
              return relativePath.range(of: text, options: [.caseInsensitive, .anchored, .backwards]) != nil
          case (true, true):
              return relativePath.range(of: text, options: [.caseInsensitive, .anchored]) != nil
                  && relativePath.range(of: text, options: [.caseInsensitive, .anchored, .backwards]) != nil
          }
      }
  }
  ```

- `FilterToken` and `static func tokenize(_ text:)` are **unchanged**: operator detection (`"AND"`/`"OR"` exact-match) still runs on the raw token string before any anchor stripping, so a hypothetical term like `^AND$` never collides with the operator keywords (it is not string-equal to `"AND"`) and tokenizes as `.term("^AND$")` exactly as today.

- `let groups: [[String]]` → `let groups: [[MatchTerm]]`.

- In `init(_ text:)`, the parser state machine (`current`, `pendingOp`, the leading/trailing/consecutive-operator degradation) is **unchanged**. The only edit is at the two points that build `current` from a raw term string: `current.append(term)` → `current.append(MatchTerm(term))`, and `current = [term]` → `current = [MatchTerm(term)]`. This is the "parser change localized to term construction, not group logic" requirement — confirmed by inspection: no other line in `init` changes.

- `func matches(_ relativePath: String) -> Bool` body changes from `relativePath.range(of: $0, options: .caseInsensitive) != nil` to `$0.matches(relativePath)`, delegating to `MatchTerm.matches(_:)`.

**Modify `scripts/FilterQueryTests/main.swift`** — two edits:

**(a) Rewrite the existing `.groups ==` assertions for the new element type (REQUIRED — the plan previously and wrongly claimed these were untouched).** Changing `groups`' element type from `String` to `MatchTerm` makes every existing `q.groups == [[".py"], ...]` comparison a hard compile error (`cannot convert 'String' to 'MatchTerm'`); `MatchTerm` gets **no** `ExpressibleByStringLiteral` conformance (that would introduce a second, ambiguous anchor-parse path). Instead, add a harness-local helper near the top of `main.swift` (after the `check`/`section` helpers):

```swift
/// Harness-local: an unanchored MatchTerm, for rewriting the pre-anchor `.groups ==` assertions.
/// Uses the memberwise initializer (not the parsing one) so expected values never route through
/// the code under test.
func lit(_ s: String) -> MatchTerm { MatchTerm(text: s, anchorStart: false, anchorEnd: false) }
```

Then mechanically rewrite each pre-existing `.groups ==` literal to wrap its terms in `lit(...)` — every term in those assertions is a plain, unanchored term, so the checked values are identical. The affected assertions are the grammar cases (main.swift ~L86/92/98), the degradation cases (~L105/106/109/110/114/118/122 — note the `== []` empty-group cases need no change, `[]` is element-type-agnostic), the `"or"` term case (~L188), and the unicode/long-term cases (~L196/200). Examples:

```
FilterQuery(".py .swift").groups == [[lit(".py")], [lit(".swift")]]
FilterQuery(".py AND .swift").groups == [[lit(".py"), lit(".swift")]]
FilterQuery(".swift AND main OR .md").groups == [[lit(".swift"), lit("main")], [lit(".md")]]
FilterQuery("or").groups == [[lit("or")]]
unicodeQuery.groups == [[lit("日本語")]]
```

Everything else in those sections (the `.matches(...)` behavioral assertions, the tokenizer assertions which do not touch `groups`, the `isEmpty` assertions) is unchanged.

**(b) Append new sections** (after the existing "Robustness" section, before "Summary"):

```
section("MatchTerm parsing: anchor stripping")
check(MatchTerm(".swift$") == MatchTerm(text: ".swift", anchorStart: false, anchorEnd: true), "\".swift$\" strips trailing $")
check(MatchTerm("^src/") == MatchTerm(text: "src/", anchorStart: true, anchorEnd: false), "\"^src/\" strips leading ^")
check(MatchTerm("^a$") == MatchTerm(text: "a", anchorStart: true, anchorEnd: true), "\"^a$\" strips both")
check(MatchTerm("^") == MatchTerm(text: "^", anchorStart: false, anchorEnd: false), "bare \"^\" is left literal")
check(MatchTerm("$") == MatchTerm(text: "$", anchorStart: false, anchorEnd: false), "bare \"$\" is left literal")
check(MatchTerm("a$b") == MatchTerm(text: "a$b", anchorStart: false, anchorEnd: false), "mid-term \"$\" stays literal")
check(MatchTerm("a^b") == MatchTerm(text: "a^b", anchorStart: false, anchorEnd: false), "mid-term \"^\" stays literal")
check(MatchTerm(".swift$b") == MatchTerm(text: ".swift$b", anchorStart: false, anchorEnd: false), "\"$\" not in final position stays literal")
check(MatchTerm("^^a") == MatchTerm(text: "^a", anchorStart: true, anchorEnd: false), "\"^^a\" strips exactly one leading ^, leaving literal \"^a\"")
check(MatchTerm("^$") == MatchTerm(text: "$", anchorStart: true, anchorEnd: false), "\"^$\" strips only the leading ^ (stripping both would empty the term)")

section("Grammar: anchors are per-term, orthogonal to AND/OR grouping")
check(
    FilterQuery(".swift$ AND ^src/").groups == [[
        MatchTerm(text: ".swift", anchorStart: false, anchorEnd: true),
        MatchTerm(text: "src/", anchorStart: true, anchorEnd: false),
    ]],
    "\".swift$ AND ^src/\" parses to one AND-group of two anchored MatchTerms"
)

section("Matching: end-anchored ($) — SPEC §5.5")
check(FilterQuery(".swift$").matches("foo.swift"), "\".swift$\" matches foo.swift")
check(!FilterQuery(".swift$").matches("foo.swiftdep"), "\".swift$\" does not match foo.swiftdep")
check(FilterQuery(".swift$").matches("weird.py.swift"), "\".swift$\" matches weird.py.swift (corpus)")
check(!FilterQuery(".swift$").matches("tools/gen.py"), "\".swift$\" does not match tools/gen.py")

section("Matching: start-anchored (^) — SPEC §5.5")
check(FilterQuery("^src/").matches("src/main.swift"), "\"^src/\" matches src/main.swift")
check(!FilterQuery("^src/").matches("x/src/main.swift"), "\"^src/\" does not match x/src/main.swift")
check(!FilterQuery("^src/").matches("lib/src/main.swift"), "\"^src/\" does not match lib/src/main.swift")

section("Matching: both anchors (^X$) — composed prefix AND suffix, not special-cased equality")
check(FilterQuery("^a$").matches("a"), "\"^a$\" matches path \"a\" exactly")
check(!FilterQuery("^a$").matches("ab"), "\"^a$\" does not match \"ab\" (fails suffix)")
check(!FilterQuery("^a$").matches("ba"), "\"^a$\" does not match \"ba\" (fails prefix)")
check(FilterQuery("^main.swift$").matches("main.swift"), "\"^main.swift$\" matches the exact root-relative path")
check(!FilterQuery("^main.swift$").matches("src/main.swift"), "\"^main.swift$\" does not match when the path has a directory prefix")
// Criterion 3's stated safety case: term LONGER than the path — both anchored checks fail, no match, no crash.
check(!FilterQuery("^abc$").matches("ab"), "\"^abc$\" (term longer than path) matches nothing without crashing")
check(!FilterQuery("^abc$").matches(""), "\"^abc$\" against the empty path matches nothing without crashing")

section("Matching: case-insensitivity preserved for anchored terms")
check(FilterQuery(".SWIFT$").matches("foo.swift"), "\".SWIFT$\" matches foo.swift (end-anchor case-insensitive)")
check(FilterQuery("^SRC/").matches("src/a.swift"), "\"^SRC/\" matches src/a.swift (start-anchor case-insensitive)")
check(FilterQuery("^A$").matches("a"), "\"^A$\" matches \"a\" (both-anchor case-insensitive)")

section("Matching: bare ^/$ degrade to literal single-character terms")
check(FilterQuery("^").matches("a^b"), "bare \"^\" matches a path containing a literal caret")
check(!FilterQuery("^").matches("abc"), "bare \"^\" does not match a path without a caret")
check(FilterQuery("$").matches("a$b"), "bare \"$\" matches a path containing a literal dollar sign")
check(!FilterQuery("$").matches("abc"), "bare \"$\" does not match a path without a dollar sign")

section("Matching: mid-term ^/$ degrade to literal substrings")
check(FilterQuery("a$b").matches("xa$by"), "\"a$b\" matches as a plain substring")
check(!FilterQuery("a$b").matches("a.b"), "\"a$b\" does not match a.b")

section("Matching: anchors compose with AND/OR (criterion 8)")
check(FilterQuery("^src/ AND .swift$").matches("src/main.swift"), "\"^src/ AND .swift$\" matches src/main.swift")
check(!FilterQuery("^src/ AND .swift$").matches("src/main.py"), "\"^src/ AND .swift$\" fails when the suffix term fails")
check(!FilterQuery("^src/ AND .swift$").matches("lib/main.swift"), "\"^src/ AND .swift$\" fails when the prefix term fails")
check(FilterQuery("^src/ OR .md$").matches("README.md"), "\"^src/ OR .md$\" matches README.md via the OR branch")
check(FilterQuery("^src/ OR .md$").matches("src/x.py"), "\"^src/ OR .md$\" matches src/x.py via the OR branch")
check(!FilterQuery("^src/ OR .md$").matches("lib/x.py"), "\"^src/ OR .md$\" matches neither branch")
```

Tier 1 done when: `swiftc FEdit/Models/FilterQuery.swift scripts/FilterQueryTests/main.swift -o /tmp/fqtests && /tmp/fqtests` exits 0 with zero `FAIL` lines (all pre-existing assertions plus all of the above), and `xcodebuild` still succeeds (the model file remains Foundation-only and part of the app target).

### Tier 2 — Placeholder text and SPEC documentation

Independently revertible: touches only a string literal in the view and prose in `SPEC.md`; no dependency on `MatchTerm` or any other Tier-1-internal shape (`SidebarView.swift` only ever calls the already-frozen `FilterQuery(text)` / `.isEmpty` / `.matches(_:)` surface, all unchanged in signature by Tier 1).

**Modify `FEdit/Views/SidebarView.swift`** (line 69):

```swift
TextField("Filter files (e.g. .swift$ OR ^src/)", text: $workspace.filterText)
```

Replaces `"Filter files (e.g. .py OR .swift)"`. Kept short (matches the existing length/format); demonstrates one end-anchor and one start-anchor example rather than the old plain-substring example, since that is the new capability worth surfacing.

**Modify `SPEC.md` §5.4** (filter mode) — update the placeholder example quoted in the first bullet to match the new literal string:

> The search field (standard rounded style, placeholder like `Filter files (e.g. .swift$ OR ^src/)`) sits at the top of the sidebar's list content, below the column's folder-name header strip (§4) when one is shown — top-to-bottom order: folder-name strip → search field → list.

(Only the placeholder example text changes; the rest of §5.4 is unrelated to anchors and stays as-is.)

**Modify `SPEC.md` §5.5** (filter query language) — insert one new bullet directly after the existing substring-match bullet ("A term matches if it is a **case-insensitive substring**..."), before the grammar code block:

> - A term may be **anchored** to the root-relative path, mirroring fzf/regex: a leading `^` anchors the match to the **start** of the path (`^src/` matches `src/a.swift`, not `lib/src/a.swift`); a trailing `$` anchors to the **end** (`.swift$` matches `foo.swift`, not `foo.swiftdep`); both together (`^main.swift$`) require both — equivalent to path equality when the anchored text and the path have the same length, and never matching when the text is longer than the path. Anchored matching is still case-insensitive. Anchoring is a per-term property, independent of `AND`/`OR` grouping (`^src/ AND .swift$` is a valid AND-group of two anchored terms).

And extend the existing last bullet ("Malformed input degrades gracefully: ...") with one more clause, appended after the existing sentence:

> Malformed input degrades gracefully: leading/trailing/duplicate operators are ignored; an operator with a missing operand keeps the side that exists; a term that is only `^` or only `$` with no other characters, or has a `^`/`$` appearing anywhere other than the very first/last character, is matched literally rather than treated as an anchor (only one leading `^` and one trailing `$` per term are ever consumed as anchors).

Tier 2 done when: the app builds, the search field visibly shows the new placeholder when the filter is empty (criterion 10, manual check), and `SPEC.md` §5.4/§5.5 read consistently with the shipped behavior.

## Interface between tiers

Tier 2 has no code dependency on Tier 1's internals. `SidebarView.swift` interacts with `FilterQuery` only through the surface already frozen by (filter-query):

```swift
struct FilterQuery {
    init(_ text: String)
    var isEmpty: Bool
    func matches(_ relativePath: String) -> Bool
}
```

None of these signatures change. `MatchTerm` and the new shape of `groups: [[MatchTerm]]` are internal implementation/harness surface, exactly as `groups: [[String]]` was before — the view must not and does not touch them. This means Tier 2 (placeholder + SPEC prose) can land before, after, or without Tier 1 with no compile-time coupling; the only reason to sequence Tier 1 first is that shipping the placeholder/SPEC text without the matching behavior would document a capability that doesn't exist yet.

## Load-bearing assumptions

1. (filter-query) has shipped (confirmed: `DONE.md` lists it, `FilterQuery.swift` and `scripts/FilterQueryTests/main.swift` exist in their planned shapes as read for this plan).
2. `String.range(of:options:)` with `.anchored` anchors the search to the start of the (default, whole-string) search range, and `.anchored` combined with `.backwards` anchors to the end — the standard Foundation idiom for case-insensitive `hasPrefix`/`hasSuffix`. This plan does not re-verify it beyond citing standard Foundation behavior; Tier 1's harness assertions are the actual proof (criteria 1–4 exercise exactly this).
3. `swiftc` and the existing harness invocation command are unchanged and still available.
4. The file-system-synchronized Xcode group still auto-includes `FEdit/Models/FilterQuery.swift` in the app target (no `project.pbxproj` edit needed) — unchanged from (filter-query).

## Auto-resolved (adv-review-plan folds, /ship-all autonomy policy)

- **DEFECT 1 (critical) — harness `.groups ==` assertions won't compile against `[[MatchTerm]]`.** Folded: Tier 1 now rewrites the ~13 pre-existing `.groups ==` assertions via a harness-local `lit(_:)` helper (memberwise, non-circular); criterion 9 restated (values unchanged, literals rewritten). No user-visible behavior change.
- **DEFECT 2 (medium) — diff-footprint mischaracterized.** Folded implicitly by DEFECT 1's fix; risk tier stays `standard` (rewriting test literals is mechanical, no behavior change).
- **DEFECT 3 (medium) — criterion 3's "term longer than path" never exercised.** Folded: added `^abc$` vs `ab` and vs `""` assertions to the both-anchors harness section.
- **TENSION T1 — whole-path vs segment anchoring.** Resolution: keep whole-path anchoring. It matches the TODO's own `^src/` example and the plan's "mirrors fzf" framing (fzf's `^`/`$` are not segment-aware either); already disclosed in Out of scope. Preserves the stated goal.
- **TENSION T2 — empty-`text` doc rationale factually wrong.** Folded: corrected the `MatchTerm.init(_:)` doc comment (Foundation `range(of:"")` returns `nil` → empty text matches nothing, not everything; guard retained for literal-degradation semantics).

## Out of scope

- Any regex metacharacter beyond `^` and `$` (no `*`, `.`, `[...]`, `+`, etc.) — anchors only, per the TODO item.
- Glob-style matching.
- Any change to the `AND`/`OR` grammar, precedence, or the tokenizer's operator detection.
- Per-group or per-query anchors — anchoring is strictly per-term.
- Highlighting the matched/anchored range in the sidebar's flat-list rows.
- A UI affordance beyond the placeholder text (no help popover, no legend of supported operators).
- Anchoring against anything other than the root-relative path (e.g. no separate "anchor to path segment" mode beyond what `^`/`$` naturally give against the full string).
