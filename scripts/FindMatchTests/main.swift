//
//  main.swift
//  FindMatchTests
//
//  Copyright © 2026 Felix Matschke
//
//  This file is part of FEdit.
//
//  FEdit is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your
//  option) any later version.
//
//  FEdit is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FEdit. If not, see <https://www.gnu.org/licenses/>.
//
//  Standalone assertion harness for `FindMatcher` + `FindSession` (editor-find Tier 1), covering
//  the plan's headless criteria 1-12. Not part of the app target — compiled and run manually:
//
//      swiftc FEdit/Editor/FindMatcher.swift FEdit/Editor/FindSession.swift scripts/FindMatchTests/main.swift -o /tmp/findtests && /tmp/findtests
//
//  Named `main.swift` because Swift only allows top-level statements in a file with that exact
//  name when compiling multiple files together. Multi-file `swiftc` yields one module, so the
//  internal types (`FindMetrics`, `FindMatcher`, `FindSession`) are directly testable without
//  `@testable` or an XCTest target.
//

import Foundation

// MARK: - Tiny test harness

var failureCount = 0

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("  PASS: \(message)")
    } else {
        failureCount += 1
        print("  FAIL: \(message) (\(file):\(line))")
    }
}

func section(_ title: String) {
    print("\n== \(title) ==")
}

/// Harness-local range literal, so expected values are written by hand and never routed through
/// the code under test.
func r(_ location: Int, _ length: Int) -> NSRange {
    NSRange(location: location, length: length)
}

/// Harness-local shorthand for the matcher's ranges only (the truncation flag is asserted
/// separately, in criterion 6).
func found(_ haystack: String, _ query: String, caseSensitive: Bool = false) -> [NSRange] {
    FindMatcher.matches(in: haystack as NSString, query: query, caseSensitive: caseSensitive).ranges
}

// MARK: - Criterion 1: degenerate inputs yield no matches

section("Criterion 1: empty query / over-long query / empty haystack")
check(found("hello world", "").isEmpty, "empty query -> no matches")
check(
    FindMatcher.matches(in: "hello world" as NSString, query: "", caseSensitive: false).didTruncate == false,
    "empty query -> didTruncate == false"
)
// Not a general rule — see "finding 5" below, where an over-long query DOES match via Unicode
// case folding ("ss" inside "ß"). This particular pair has no such fold, so it genuinely misses.
check(found("abc", "abcd").isEmpty, "query longer than the haystack -> no matches (no case-fold escape here)")
check(found("", "a").isEmpty, "zero-length haystack -> no matches")
check(found("", "").isEmpty, "zero-length haystack AND empty query -> no matches (no hang)")
check(found("abc", "abc") == [r(0, 3)], "query exactly as long as the haystack still matches")

// MARK: - Criterion 2: case-insensitive is the default

section("Criterion 2: case sensitivity")
check(
    found("foo FOO fOo", "Foo", caseSensitive: false) == [r(0, 3), r(4, 3), r(8, 3)],
    "\"Foo\" in \"foo FOO fOo\" case-INsensitively -> 3 matches"
)
check(
    found("foo FOO fOo", "foo", caseSensitive: true) == [r(0, 3)],
    "\"foo\" in \"foo FOO fOo\" case-sensitively -> exactly 1 match"
)
check(
    found("foo FOO fOo", "FOO", caseSensitive: true) == [r(4, 3)],
    "\"FOO\" case-sensitively -> the middle occurrence only"
)
check(
    found("foo FOO fOo", "bar", caseSensitive: false).isEmpty,
    "a query that does not occur -> no matches"
)

// MARK: - Criterion 3: non-overlapping, strictly ascending (D5)

section("Criterion 3: non-overlapping and strictly ascending")
check(found("aaaa", "aa") == [r(0, 2), r(2, 2)], "\"aaaa\" / \"aa\" -> [(0,2), (2,2)], NOT 3 overlapping hits")
check(found("aaaaa", "aa") == [r(0, 2), r(2, 2)], "\"aaaaa\" / \"aa\" -> 2 matches; the trailing \"a\" is not one")
check(found("aaa", "aaa") == [r(0, 3)], "a whole-string match consumes the whole string")
do {
    let ranges = found("abababab", "abab")
    check(ranges == [r(0, 4), r(4, 4)], "\"abababab\" / \"abab\" -> 2 non-overlapping matches")
    var ascending = true
    // (editor-find, finding 10) Guarded on `ranges.count > 1`: `1..<ranges.count` is `1..<0` — an
    // invalid `Range` that TRAPS, not fails — the moment the matcher ever regresses to `[]` or a
    // single match. A guarded loop reports FAIL and exits 1 instead of crashing the suite.
    if ranges.count > 1 {
        for index in 1..<ranges.count where ranges[index].location < NSMaxRange(ranges[index - 1]) {
            ascending = false
        }
    }
    check(ascending, "returned ranges are strictly ascending and never overlap")
}

// MARK: - Criterion 4: every range is a valid, non-overlapping subrange of the haystack
//
// (editor-find, finding 5) Deliberately NOT asserting `range.length == queryLength` here — that
// claim is false in general (see the dedicated "finding 5" section below for the pinned
// counter-examples) even though it happens to hold for every case in THIS list. Asserting the
// weaker, universally-true properties instead — valid, non-empty, ascending/non-overlapping, and
// substring-equal to the query under the same compare options — is what the count label and the
// highlighter actually depend on.

section("Criterion 4: range validity")
do {
    let cases: [(haystack: String, query: String, caseSensitive: Bool)] = [
        ("foo FOO fOo", "Foo", false),
        ("aaaa", "aa", true),
        ("the quick brown fox jumps over the lazy dog", "the", false),
        ("Ünïcödé Ünïcödé", "Ünïcödé", true),
        ("a\nb\na\nb", "b", false),
    ]
    var allValid = true
    var allNonEmpty = true
    var allAscendingNonOverlapping = true
    var allSubstringsEqual = true
    for testCase in cases {
        let haystack = testCase.haystack as NSString
        let ranges = found(testCase.haystack, testCase.query, caseSensitive: testCase.caseSensitive)
        check(!ranges.isEmpty, "\(testCase.query.debugDescription) in \(testCase.haystack.debugDescription): at least one match")
        for (index, range) in ranges.enumerated() {
            if range.location < 0 || NSMaxRange(range) > haystack.length { allValid = false }
            if range.length <= 0 { allNonEmpty = false }
            if index > 0 && range.location < NSMaxRange(ranges[index - 1]) { allAscendingNonOverlapping = false }
            let options: NSString.CompareOptions = testCase.caseSensitive ? [.literal] : [.literal, .caseInsensitive]
            if haystack.substring(with: range).compare(testCase.query, options: options) != .orderedSame {
                allSubstringsEqual = false
            }
        }
    }
    check(allValid, "every returned range is a valid UTF-16 subrange (0 <= location, NSMaxRange <= length)")
    check(allNonEmpty, "every returned range is non-empty")
    check(allAscendingNonOverlapping, "returned ranges are strictly ascending and never overlap")
    check(allSubstringsEqual, "the text at every returned range compares equal to the query under the same options")
}

// MARK: - (editor-find, finding 5) Case-insensitive Unicode case folding can change match length
//
// `.literal` blocks CANONICAL folding (criterion 5 pins that: a decomposed query still does not
// match precomposed text) but does NOT block `.caseInsensitive`'s own Unicode case folding, which
// maps "ß" to "SS" independently of `.literal`. So a found range's length is not always
// `queryLength` — pinned here as real, measured behavior (probed directly on this OS) rather than
// assumed from the now-corrected doc comment in `FindMatcher.swift`.

section("Finding 5: case folding can expand or contract a match's length")
check(
    found("straße", "STRASSE") == [r(0, 6)],
    "\"STRASSE\" (7 units) matches \"straße\" with a SHORTER range (0,6) — ß folds to SS"
)
check(
    found("ﬁle", "file") == [r(0, 3)],
    "\"file\" (4 units) matches the \"ﬁ\" ligature with a SHORTER range (0,3)"
)
check(
    found("ß", "ss") == [r(0, 1)],
    "\"ss\" (2 units) matches the single-unit \"ß\" — a query LONGER than the haystack still hits, " +
        "which is exactly what the removed `queryLength <= haystack.length` guard used to reject"
)
check(
    found("aßa ssa", "ss") == [r(1, 1), r(4, 2)],
    "a folded match (length 1, at the ß) and a literal match (length 2) both report correctly in one pass"
)

// MARK: - Criterion 5: multi-byte content (surrogate pairs)

section("Criterion 5: UTF-16 offsets across surrogate pairs")
do {
    // "👍" is ONE Character but TWO UTF-16 code units, so a byte- or Character-indexed matcher
    // would report 2 here instead of 3.
    let haystack = "👍 hello"
    check((haystack as NSString).length == 8, "sanity: \"👍 hello\" is 8 UTF-16 units (surrogate pair + space + 5)")
    check(found(haystack, "hello") == [r(3, 5)], "a match after an emoji reports the UTF-16 offset 3, not 2")
    check(found(haystack, "👍") == [r(0, 2)], "an emoji query matches, with length 2 (the surrogate pair)")
    check(
        found("a👍b👍c", "👍") == [r(1, 2), r(4, 2)],
        "repeated emoji queries report ascending UTF-16 offsets (1 and 4)"
    )
    // (D5) `.literal` does NOT fold canonical equivalence, and the plan states that cost outright.
    let precomposed = "r\u{00E9}sum\u{00E9}"
    let decomposed = "re\u{0301}sume\u{0301}"
    check(found(precomposed, decomposed).isEmpty, "`.literal`: a decomposed query does not match precomposed text (D5)")
    check(found(precomposed, "resume").isEmpty, "`.literal`: \"resume\" does not match \"résumé\" — diacritics are not folded (D5)")
}

// MARK: - Criterion 6: the enumeration limit and its truncation flag

section("Criterion 6: FindMetrics.matchLimit")
check(FindMetrics.matchLimit == 20_000, "the documented cap is 20,000")
do {
    let haystack = String(repeating: "ab", count: 25_000) as NSString
    let result = FindMatcher.matches(in: haystack, query: "ab", caseSensitive: false)
    check(result.ranges.count == FindMetrics.matchLimit, "25,000 occurrences -> exactly 20,000 ranges")
    check(result.didTruncate, "25,000 occurrences -> didTruncate == true")
    check(result.ranges.first == r(0, 2), "the kept ranges start at the beginning of the text")
    check(result.ranges.last == r(2 * (FindMetrics.matchLimit - 1), 2), "the kept ranges are the FIRST 20,000, in order")
}
do {
    // The boundary the `+` must not lie about: exactly at the cap is NOT truncation.
    let haystack = String(repeating: "ab", count: FindMetrics.matchLimit) as NSString
    let result = FindMatcher.matches(in: haystack, query: "ab", caseSensitive: false)
    check(result.ranges.count == FindMetrics.matchLimit, "exactly 20,000 occurrences -> 20,000 ranges")
    check(!result.didTruncate, "exactly 20,000 occurrences -> didTruncate == FALSE (no fabricated \"+\")")
}
do {
    let haystack = String(repeating: "ab", count: FindMetrics.matchLimit + 1) as NSString
    let result = FindMatcher.matches(in: haystack, query: "ab", caseSensitive: false)
    check(result.ranges.count == FindMetrics.matchLimit, "20,001 occurrences -> 20,000 ranges")
    check(result.didTruncate, "one match past the cap is enough to set didTruncate")
}

// MARK: - Criterion 7: FindSession.recompute seats the current match at the caret

section("Criterion 7: caret-relative seating and wrap")
do {
    // "x" at 0, 10, 20, 30.
    let text = "x123456789x123456789x123456789x" as NSString
    var session = FindSession()
    session.query = "x"

    session.recompute(text: text, caretLocation: 0)
    check(session.matches == [r(0, 1), r(10, 1), r(20, 1), r(30, 1)], "sanity: 4 matches at 0/10/20/30")
    check(session.currentIndex == 0, "caret 0 seats on the first match")

    session.recompute(text: text, caretLocation: 1)
    check(session.currentIndex == 1, "caret 1 seats on the first match at/after it (location 10)")

    session.recompute(text: text, caretLocation: 10)
    check(session.currentIndex == 1, "caret exactly ON a match seats on THAT match (>=, not >)")

    session.recompute(text: text, caretLocation: 21)
    check(session.currentIndex == 3, "caret 21 seats on the match at 30")

    session.recompute(text: text, caretLocation: 31)
    check(session.currentIndex == 0, "caret past every match WRAPS to the first")

    session.recompute(text: text, caretLocation: 9_999)
    check(session.currentIndex == 0, "a caret past the end of the text also wraps to the first")

    session.query = "nothing-here"
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.isEmpty, "a query with no matches enumerates to []")
    check(session.currentIndex == nil, "no matches -> currentIndex == nil")
    check(session.currentRange == nil, "no matches -> currentRange == nil")
}

// MARK: - (editor-find, finding 2) recomputeNearest: nearest-match seating, not first-at-or-after

section("Finding 2: recomputeNearest seats on the NEAREST match, deletion above included")
do {
    // Deletion above the seated match: matches at 0/10/20/30, seated on 10 (index 1). Delete ONE
    // character above it (at offset 5) — every match at/after 10 shifts down by 1.
    let text = "x123456789x123456789x123456789x" as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 10)
    check(session.currentIndex == 1, "sanity: seated on the match at 10")

    let deleted = text.replacingCharacters(in: r(5, 1), with: "") as NSString
    check(deleted.length == text.length - 1, "sanity: the edited text is one character shorter")
    let deletedMatches = found(deleted as String, "x")
    check(deletedMatches == [r(0, 1), r(9, 1), r(19, 1), r(29, 1)], "sanity: matches shift to 0/9/19/29 after the deletion")
    check(
        deletedMatches.firstIndex { $0.location >= 10 } == 2,
        "sanity: OLD first-at-or-after rule would jump to index 2 (19) — the exact bug finding 2 fixed"
    )

    session.recomputeNearest(text: deleted, near: 10)
    check(session.matches == deletedMatches, "sanity: recomputeNearest enumerates the same matches as a plain scan")
    check(
        session.currentIndex == 1,
        "finding 2: a deletion above the seated match re-seats on the NEAREST match (9, index 1), not the next one (19)"
    )
}
do {
    // Insertion above the seated match: matches at 0/10/20/30, seated on 10 (index 1). Insert
    // THREE characters above it (at offset 5) — every match at/after 10 shifts up by 3.
    let text = "x123456789x123456789x123456789x" as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 10)
    check(session.currentIndex == 1, "sanity: seated on the match at 10")

    let inserted = text.replacingCharacters(in: r(5, 0), with: "ZZZ") as NSString
    let insertedMatches = found(inserted as String, "x")
    check(insertedMatches == [r(0, 1), r(13, 1), r(23, 1), r(33, 1)], "sanity: matches shift to 0/13/23/33 after the insertion")

    session.recomputeNearest(text: inserted, near: 10)
    check(
        session.currentIndex == 1,
        "finding 2: an insertion above the seated match still re-seats on the SAME logical match (13, index 1) — " +
            "nearest-by-distance agrees with first-at-or-after when offsets only grow"
    )
}
do {
    // The tie: two matches exactly equidistant from the hint — the earlier one wins.
    var chars = Array(String(repeating: "y", count: 400))
    chars[100] = "x"
    chars[300] = "x"
    let tieText = String(chars) as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: tieText, caretLocation: 0)
    check(session.matches == [r(100, 1), r(300, 1)], "sanity: two matches, 100 and 300, both 100 units from 200")

    session.recomputeNearest(text: tieText, near: 200)
    check(session.currentIndex == 0, "finding 2: an exact distance tie goes to the EARLIER match (100, index 0)")
}
do {
    // (editor-find, finding 2, second round) The exact case the first round's distance-only fix
    // did not remove, only moved the threshold on: matches at 100/200/300, seated on 200 (index 1,
    // "2 of 3"). Delete a 60-character span strictly between the seated match and the next one
    // (140..<200) — the match COUNT is unchanged (still 3), but 240 (the shifted 300) sits NEARER
    // the stale hint 200 than 140 (the shifted 200) does, so a distance-only re-seat would jump to
    // index 2 and silently flip the count to "3 of 3" with no user action.
    var chars = Array(String(repeating: "y", count: 400))
    chars[100] = "x"
    chars[200] = "x"
    chars[300] = "x"
    let text = String(chars) as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 200)
    check(session.currentIndex == 1, "sanity: seated on the match at 200")

    var deleted = chars
    deleted.removeSubrange(140..<200)
    let deletedText = String(deleted) as NSString
    let deletedMatches = found(deletedText as String, "x")
    check(deletedMatches == [r(100, 1), r(140, 1), r(240, 1)], "sanity: matches shift to 100/140/240 after the deletion")
    check(deletedMatches.count == 3, "sanity: the match COUNT is unchanged (3 before, 3 after)")
    check(
        abs(deletedMatches[2].location - 200) < abs(deletedMatches[1].location - 200),
        "sanity: 240 IS nearer the stale hint 200 than 140 — a distance-only re-seat would land on index 2"
    )

    session.recomputeNearest(text: deletedText, near: 200)
    check(
        session.currentIndex == 1,
        "finding 2 (second round): a count-unchanged edit keeps the ORDINAL (index 1, now 140) — not " +
            "the distance-nearer match (index 2, 240) — matching the \"2 of 3\" the user was actually on"
    )
}
do {
    // (editor-find, finding 2, second round) The complementary case: a count-CHANGING edit, where
    // the ordinal can no longer name the same match and the fallback (nearest-by-distance) is
    // exactly right — proving the ordinal-first fix does not regress the case it was never meant to
    // touch. The match at 100 (before the seat) is deleted outright; no offsets shift, but the
    // count drops from 3 to 2.
    var chars = Array(String(repeating: "y", count: 400))
    chars[100] = "x"
    chars[200] = "x"
    chars[300] = "x"
    let text = String(chars) as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 200)
    check(session.currentIndex == 1, "sanity: seated on the match at 200")

    chars[100] = "y"
    let editedText = String(chars) as NSString
    let editedMatches = found(editedText as String, "x")
    check(editedMatches == [r(200, 1), r(300, 1)], "sanity: the match at 100 is gone, 200 and 300 unmoved")

    session.recomputeNearest(text: editedText, near: 200)
    check(
        session.currentIndex == 0,
        "finding 2 (second round): a count-changing edit falls back to nearest-by-distance and seats " +
            "sensibly — still on the match at 200 (now index 0), not the ordinal's stale index 1"
    )
}

// MARK: - Criterion 8: stepNext advances and wraps

section("Criterion 8: stepNext")
do {
    // 17 matches, so the wrap under test is 16 -> 0.
    let text = String(repeating: "q.", count: 17) as NSString
    var session = FindSession()
    session.query = "q"
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 17, "sanity: 17 matches")
    check(session.currentIndex == 0, "sanity: seated on the first")

    for expected in 1...16 {
        session.stepNext()
        check(session.currentIndex == expected, "stepNext advances to \(expected)")
    }
    session.stepNext()
    check(session.currentIndex == 0, "stepNext at the LAST match (16 of 17) wraps to 0")
    check(session.currentRange == r(0, 1), "after the wrap, currentRange is the first match again")
}
do {
    var session = FindSession()
    session.query = "zzz"
    session.recompute(text: "aaa" as NSString, caretLocation: 0)
    session.stepNext()
    check(session.currentIndex == nil, "stepNext on an empty match array is a no-op (currentIndex stays nil)")
    check(session.matches.isEmpty, "stepNext on an empty match array invents no matches")
}

// MARK: - (editor-find-previous) stepPrevious retreats and wraps

section("(editor-find-previous) stepPrevious")
do {
    // The same 17-match text criterion 8 steps forward through, so the wrap under test is 0 -> 16.
    let text = String(repeating: "q.", count: 17) as NSString
    var session = FindSession()
    session.query = "q"
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 17, "sanity: 17 matches")
    check(session.currentIndex == 0, "sanity: seated on the first")

    // Walk forward to the end first, so the retreat below starts from a seat that was reached the
    // ordinary way rather than one poked in by hand.
    for _ in 1...16 { session.stepNext() }
    check(session.currentIndex == 16, "sanity: 16 stepNext calls seat on the last match")

    for expected in stride(from: 15, through: 0, by: -1) {
        session.stepPrevious()
        check(session.currentIndex == expected, "stepPrevious retreats to \(expected)")
    }
    session.stepPrevious()
    check(session.currentIndex == 16, "stepPrevious at the FIRST match (1 of 17) wraps to 16")
    check(session.currentRange == r(32, 1), "after the wrap, currentRange is the last match")
}
do {
    // Criterion 3: the mirror of criterion 8's empty-array case, built exactly the same way — a
    // query that matches nothing at all, so `recompute` leaves the session unseated and empty.
    var session = FindSession()
    session.query = "zzz"
    session.recompute(text: "aaa" as NSString, caretLocation: 0)
    session.stepPrevious()
    check(session.currentIndex == nil, "stepPrevious on an empty match array is a no-op (currentIndex stays nil)")
    check(session.matches.isEmpty, "stepPrevious on an empty match array invents no matches")
}
do {
    // Criterion 4: the unseated-but-NON-empty branch (`currentIndex == nil` with matches present).
    // No sequence of `recompute`/`stepNext`/`stepPrevious`/`clamp`/`clear` can reach this state —
    // every mutating member preserves the type's seated-exactly-when-non-empty invariant, and
    // `currentIndex`/`matches` are `private(set)`, so the technique the empty-array case above uses
    // cannot build it. It is reachable here only through the SYNTHESIZED memberwise initializer,
    // which is internal and therefore visible to this harness for the reason the file header gives
    // (multi-file `swiftc` yields one module). Nothing was added to `FindSession` to reach it. The
    // case is pinned rather than skipped because `?? 0` is the only line of `stepPrevious` that no
    // other test covers, and an unreachable branch with no test is a branch that rots into `?? -1`
    // (which would seat on the FIRST match here, not the last) at the first careless copy-paste.
    var session = FindSession(
        query: "q",
        caseSensitive: false,
        matches: [r(0, 1), r(2, 1), r(4, 1)],
        didTruncate: false,
        currentIndex: nil
    )
    check(session.currentIndex == nil, "sanity: the hand-built session is non-empty but unseated")
    session.stepPrevious()
    check(session.currentIndex == 2, "stepPrevious on a non-empty UNSEATED session seats on the LAST match")
    check(session.currentRange == r(4, 1), "... and currentRange is that last match, not an invalid index")
}
do {
    // Criterion 5: stepNext followed by stepPrevious is the identity, from EVERY index — including
    // both wrap edges (index 0's backwards wrap and the last index's forwards wrap), which is where
    // an off-by-one or a negative-remainder bug would hide.
    let text = String(repeating: "q.", count: 9) as NSString
    var session = FindSession()
    session.query = "q"
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 9, "sanity: 9 matches for the round-trip sweep")

    var roundTripMismatches = 0
    for index in 0..<9 {
        // Seat on `index` the ordinary way: recompute at the caret, then step forward `index` times.
        session.recompute(text: text, caretLocation: 0)
        for _ in 0..<index { session.stepNext() }
        check(session.currentIndex == index, "sanity: seated on \(index) for the round trip")

        session.stepNext()
        session.stepPrevious()
        if session.currentIndex != index { roundTripMismatches += 1 }
    }
    check(roundTripMismatches == 0, "stepNext then stepPrevious returns to the original index, from all 9 indices")

    // And the other order, which crosses the wrap edges the other way round.
    var reverseMismatches = 0
    for index in 0..<9 {
        session.recompute(text: text, caretLocation: 0)
        for _ in 0..<index { session.stepNext() }
        session.stepPrevious()
        session.stepNext()
        if session.currentIndex != index { reverseMismatches += 1 }
    }
    check(reverseMismatches == 0, "stepPrevious then stepNext returns to the original index, from all 9 indices")
}
do {
    // Criterion 6: the count label reads the NEW ordinal after a step back, including the wrap.
    let text = String(repeating: "q.", count: 17) as NSString
    var session = FindSession()
    session.query = "q"
    session.recompute(text: text, caretLocation: 0)
    session.stepNext()
    check(session.countLabel == "2 of 17", "sanity: one step forward -> \"2 of 17\"")
    session.stepPrevious()
    check(session.countLabel == "1 of 17", "stepPrevious back to the first -> \"1 of 17\"")
    session.stepPrevious()
    check(session.countLabel == "17 of 17", "stepPrevious wrapping off the front -> \"17 of 17\"")
}

// MARK: - Criterion 9: clamp(toLength:) — the anti-NSRangeException invariant

section("Criterion 9: clamp(toLength:)")
do {
    // 40,000 characters with matches near the very end, then the text is (conceptually) replaced by
    // a 200-character one — exactly the "enumerated against one snapshot, consumed against another"
    // hazard that raises NSRangeException at addTemporaryAttributes/scrollRangeToVisible.
    let text = (String(repeating: "-", count: 39_990) + "needle") as NSString
    check(text.length == 39_996, "sanity: the 40,000-ish text is 39,996 UTF-16 units")
    var session = FindSession()
    session.query = "needle"
    session.recompute(text: text, caretLocation: 0)
    check(session.matches == [r(39_990, 6)], "sanity: one match near the end")
    check(session.currentIndex == 0, "sanity: seated")

    session.clamp(toLength: 200)
    check(session.matches.isEmpty, "clamp(toLength: 200) drops the match that lies past 200")
    check(session.currentIndex == nil, "no survivors -> currentIndex == nil")
    check(session.currentRange == nil, "no survivors -> currentRange == nil (nothing to scroll to or draw)")
}
do {
    // Partial survival: matches at 0, 10, 20, 30 clamped to 25 keeps the first three.
    let text = "x123456789x123456789x123456789x" as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 25)
    check(session.currentIndex == 3, "sanity: seated on the match at 30")

    session.clamp(toLength: 25)
    check(session.matches == [r(0, 1), r(10, 1), r(20, 1)], "clamp keeps only the matches that fit entirely")
    check(session.currentIndex == 2, "the seat is re-seated into the surviving array (last survivor)")
    check(session.currentRange == r(20, 1), "currentRange is a surviving range")

    session.clamp(toLength: 21)
    check(session.matches == [r(0, 1), r(10, 1), r(20, 1)], "a match ENDING exactly at the new length survives")
    check(session.currentIndex == 2, "a no-op clamp leaves the seat where it was")

    session.clamp(toLength: 20)
    check(session.matches == [r(0, 1), r(10, 1)], "a match ending one past the new length is dropped")
    check(session.currentIndex == 1, "the dropped seat re-seats onto the last survivor")

    session.clamp(toLength: 0)
    check(session.matches.isEmpty, "clamp(toLength: 0) drops everything")
    check(session.currentIndex == nil, "clamp to an empty text unseats")
}
do {
    // Identity preservation: a surviving current match stays current.
    let text = "x123456789x123456789x123456789x" as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 10)
    check(session.currentIndex == 1, "sanity: seated on the match at 10")
    session.clamp(toLength: 25)
    check(session.currentRange == r(10, 1), "a surviving current match stays current after a clamp")
}

// MARK: - (editor-find, finding 9) clamp(toLength:) must not allocate when nothing is out of bounds

section("Finding 9: a no-op clamp leaves `matches` as the same array instance")
do {
    /// The array's storage address — `nil` for an empty array (no storage to point at). Two
    /// arrays sharing this address are the SAME buffer under copy-on-write, which is exactly what
    /// `clamp`'s early-out must preserve to avoid an allocation on every idle `updateNSView` pass.
    func bufferAddress(_ array: [NSRange]) -> UInt? {
        array.withUnsafeBufferPointer { UInt(bitPattern: $0.baseAddress) }
    }

    let text = "x123456789x123456789x123456789x" as NSString
    var session = FindSession()
    session.query = "x"
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 4, "sanity: 4 matches")

    let addressBefore = bufferAddress(session.matches)
    // A no-op clamp: the length hasn't shrunk at all, so nothing is out of bounds.
    session.clamp(toLength: text.length)
    check(session.matches.count == 4, "a no-op clamp keeps every match")
    check(
        bufferAddress(session.matches) == addressBefore,
        "a no-op clamp leaves `matches` as the SAME array instance — no fresh allocation"
    )

    // A clamp to the exact same length again, repeatedly (simulating a run of idle passes): still
    // the same buffer every time.
    session.clamp(toLength: text.length)
    session.clamp(toLength: text.length)
    check(
        bufferAddress(session.matches) == addressBefore,
        "repeated no-op clamps never allocate — the buffer identity survives every one of them"
    )
}

// MARK: - (editor-find, finding 4) clamp(toLength:) must clear a stale didTruncate

section("Finding 4: clamp clears didTruncate when it drops matches")
do {
    // 25,000 occurrences over a capped enumeration -> didTruncate == true, "+" in the label.
    var session = FindSession()
    session.query = "ab"
    session.recompute(text: String(repeating: "ab", count: 25_000) as NSString, caretLocation: 0)
    check(session.didTruncate, "sanity: a 25,000-occurrence enumeration truncates")
    check(session.countLabel.hasSuffix("+"), "sanity: the label shows the \"+\"")

    // The document shrinks drastically (most of it deleted) — clamp drops the vast majority of
    // the truncated 20,000 kept matches, and the surviving ~1,500-ish set is now the EXACT count,
    // not a truncated one.
    session.clamp(toLength: 3_000)
    check(session.matches.count < FindMetrics.matchLimit, "sanity: the clamp actually dropped matches")
    check(!session.didTruncate, "clamp that drops matches clears didTruncate — the surviving count is exact")
    check(!session.countLabel.hasSuffix("+"), "the count label no longer fabricates a \"+\" after the clamp")
}
do {
    // A clamp that drops NOTHING must leave didTruncate exactly as it was (no unrelated flip).
    //
    // (editor-find, finding 7, second round) This is an ACCEPTED STALENESS, not a correctness
    // property: `lengthBefore` is exactly `NSMaxRange(matches.last)`, so `clamp`'s early-out
    // (`NSMaxRange(lastMatch) > length`) is false only because the boundary is exact — a document
    // shrunk to precisely this length keeps reporting a fabricated "20000+" for an exact 20,000
    // until the next debounce re-enumerates for real. It is self-healing (the very next settle
    // point corrects it) and cheap to accept (the alternative is a strict-inequality clamp that
    // pays for an enumeration-count comparison on the overwhelmingly common no-op pass), not
    // something the design claims to get right at this exact boundary.
    var session = FindSession()
    session.query = "ab"
    session.recompute(text: String(repeating: "ab", count: 25_000) as NSString, caretLocation: 0)
    let lengthBefore = session.matches.reduce(0) { max($0, NSMaxRange($1)) }
    session.clamp(toLength: lengthBefore)
    check(session.didTruncate, "a no-op clamp at the exact boundary leaves didTruncate stale (accepted, self-healing)")
}
do {
    // An UNtruncated session must not have didTruncate fabricated INTO true by a clamp either —
    // it only ever moves true -> false here, never false -> true.
    var session = FindSession()
    session.query = "x"
    session.recompute(text: "x123456789x123456789x123456789x" as NSString, caretLocation: 0)
    check(!session.didTruncate, "sanity: this small session never truncated")
    session.clamp(toLength: 15)
    check(!session.didTruncate, "clamping an untruncated session leaves didTruncate == false")
}

// MARK: - Criterion 10: countLabel

section("Criterion 10: countLabel")
do {
    var session = FindSession()
    check(session.countLabel == "", "a fresh session (empty query) reports \"\"")

    session.recompute(text: "anything" as NSString, caretLocation: 0)
    check(session.countLabel == "", "an EMPTY query reports \"\" even after a recompute")

    session.query = "zzz"
    session.recompute(text: "anything" as NSString, caretLocation: 0)
    check(session.countLabel == "Not found", "a non-empty query with no matches reports \"Not found\"")

    session.query = "q"
    session.recompute(text: String(repeating: "q.", count: 17) as NSString, caretLocation: 0)
    check(session.countLabel == "1 of 17", "seated on the first of 17 -> \"1 of 17\"")
    session.stepNext()
    session.stepNext()
    check(session.countLabel == "3 of 17", "two steps later -> \"3 of 17\"")

    session.query = "ab"
    session.recompute(text: String(repeating: "ab", count: 25_000) as NSString, caretLocation: 0)
    check(session.didTruncate, "sanity: the 25,000-occurrence text truncates")
    session.stepNext()
    session.stepNext()
    check(session.countLabel == "3 of 20000+", "a truncated enumeration reports the \"+\" -> \"3 of 20000+\"")

    session.clear()
    check(session == FindSession(), "clear() returns the session to its initial value")
    check(session.countLabel == "", "a cleared session reports \"\"")
    check(session.currentRange == nil, "a cleared session has no current range")
}

// MARK: - Criterion 11: the randomized clamp invariant
//
// The oracle: after EVERY operation, `currentRange` (and every kept match) must lie inside the
// smallest length the session has been clamped/recomputed against since. This is the property that
// keeps `addTemporaryAttributes`/`scrollRangeToVisible` from raising. It is deliberately checked
// against a bound the harness tracks ITSELF — never one read back out of the session — so a
// `clamp` that forgot to drop anything fails here.

section("Criterion 11: randomized recompute/step/clamp invariant")
do {
    /// A tiny deterministic LCG (Numerical Recipes constants), seeded by a fixed constant so this
    /// run is reproducible run to run (no `Date`/system-entropy seeding). Same shape as the
    /// generator `MarkdownRendererTests` fuzzes with, with **one deliberate difference**:
    /// `nextInt(upperBound:)` reduces the HIGH bits, not the low ones.
    ///
    /// That is not a stylistic preference — it is load-bearing here, and the
    /// "clamps that DROPPED ranges" assertion below is what caught it. An LCG modulo 2^64 has bit
    /// `k` cycling with period 2^(k+1), so `state % 4` reads the two lowest bits and repeats with
    /// period 4: the op selector below then walked a FIXED cycle (clear, clamp, step, recompute,
    /// …), every clamp landed on a just-cleared empty session, and the whole invariant check passed
    /// vacuously while never once exercising a clamp that had to drop anything.
    struct SeededLCG {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
            return state
        }
        mutating func nextInt(upperBound: Int) -> Int {
            Int((next() >> 33) % UInt64(upperBound))
        }
    }

    var rng = SeededLCG(seed: 0xF1_AD_1234_5678_9ABC)
    let queries = ["a", "ab", "x", "needle", "👍", ""]
    let corpus = "a👍b needle ab abab x needle aaaa 👍👍 xx needle-ish ababab a" as NSString

    var session = FindSession()
    var bound = 0                 // the tightest length the session has been held to so far
    var violations = 0
    var clampsThatDroppedSomething = 0
    var seatMismatches = 0
    var sawNonEmpty = false

    for _ in 0..<20_000 {
        switch rng.nextInt(upperBound: 5) {
        case 0:
            session.query = queries[rng.nextInt(upperBound: queries.count)]
            session.caseSensitive = rng.nextInt(upperBound: 2) == 0
            let length = rng.nextInt(upperBound: corpus.length + 1)
            let text = corpus.substring(to: length) as NSString
            session.recompute(text: text, caretLocation: rng.nextInt(upperBound: corpus.length + 5))
            bound = text.length
        case 4:
            // (editor-find-previous, adv-review-edge finding 2) `recomputeNearest` was missing from
            // this op alphabet — a gap inherited from (editor-find), not introduced by this item,
            // but one that made this item's own load-bearing assumption ("if stepPrevious needs a
            // change to the other mutating members, the randomized run is what catches it") weaker
            // than it claimed. It is the ONE mutating member the live Find Previous path actually
            // invokes that this run never built: `stepFind` calls `reenumerateFindSession(...,
            // seatOnNearest: true)` when the session is stale-by-edit, which is `recomputeNearest`.
            // Without this case the run could not construct a single `stepPrevious`-after-
            // `recomputeNearest` interleaving, which is precisely the sequence a Cmd+Shift+G pressed
            // inside the ~150 ms debounce window produces.
            let length = rng.nextInt(upperBound: corpus.length + 1)
            let text = corpus.substring(to: length) as NSString
            session.recomputeNearest(text: text, near: rng.nextInt(upperBound: corpus.length + 5))
            bound = text.length
        case 1:
            // (editor-find-previous, criterion 7) Both step directions ride this one op slot,
            // chosen by the same seeded generator, so the randomized run mixes forwards and
            // backwards steps against every session shape it builds — a `stepPrevious` that
            // produced a negative or out-of-bounds `currentIndex` would surface as a seat mismatch
            // (or, past a clamp, a range violation) in the assertions below, which are unchanged.
            if rng.nextInt(upperBound: 2) == 0 {
                session.stepNext()
            } else {
                session.stepPrevious()
            }
        case 2:
            let newLength = rng.nextInt(upperBound: bound + 1)
            let before = session.matches.count
            session.clamp(toLength: newLength)
            if session.matches.count < before { clampsThatDroppedSomething += 1 }
            bound = min(bound, newLength)
        default:
            session.clear()
            bound = 0
        }

        if !session.matches.isEmpty { sawNonEmpty = true }
        for match in session.matches where match.location < 0 || NSMaxRange(match) > bound {
            violations += 1
        }
        if let range = session.currentRange, range.location < 0 || NSMaxRange(range) > bound {
            violations += 1
        }
        // The type's own invariant: seated exactly when there is something to seat on.
        if (session.currentIndex == nil) != session.matches.isEmpty { seatMismatches += 1 }
        if let index = session.currentIndex, !session.matches.indices.contains(index) { seatMismatches += 1 }
    }

    check(sawNonEmpty, "the randomized run actually produced matches (the oracle is not vacuous)")
    check(clampsThatDroppedSomething > 0, "the randomized run actually exercised clamps that DROPPED ranges")
    check(violations == 0, "20,000 randomized ops: every kept match and currentRange stayed inside the last clamped length")
    check(seatMismatches == 0, "20,000 randomized ops: currentIndex is non-nil exactly when matches is non-empty, and always valid")
}

// MARK: - Criterion 12: flipping caseSensitive re-enumerates

section("Criterion 12: caseSensitive re-enumeration")
do {
    let text = "foo FOO" as NSString
    var session = FindSession()
    session.query = "foo"

    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 2, "case-insensitive (default): \"foo\" in \"foo FOO\" -> 2 matches")
    check(session.countLabel == "1 of 2", "... and the label reads \"1 of 2\"")

    session.caseSensitive = true
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 1, "flipping caseSensitive to true re-enumerates -> 1 match")
    check(session.countLabel == "1 of 1", "... and the label reads \"1 of 1\"")

    session.caseSensitive = false
    session.recompute(text: text, caretLocation: 0)
    check(session.matches.count == 2, "flipping it back re-enumerates -> 2 matches again")
}

// MARK: - editor-find: enumeration cost (advisory)
//
// ADVISORY tripwire only, in the style of `MarkdownRendererTests`'s `measureRender`: the ceiling is
// deliberately loose (a large margin over expected time) so a slow or loaded machine cannot fail
// the suite. The real guarantee is the algorithm — one forward `NSString.range(of:)` scan per
// match, capped at `FindMetrics.matchLimit` (D8) — not this wall-clock number. What it would catch
// is a regression into re-scanning from offset 0 per match (quadratic), which is the classic way to
// write this loop wrong.

section("editor-find: enumeration cost (advisory)")
func measureFind(_ label: String, ceiling: TimeInterval, haystack: NSString, query: String, caseSensitive: Bool) {
    let start = Date()
    let result = FindMatcher.matches(in: haystack, query: query, caseSensitive: caseSensitive)
    let elapsed = Date().timeIntervalSince(start)
    print("  TIME: \(label) took \(elapsed)s for \(result.ranges.count) match(es) (advisory ceiling \(ceiling)s)")
    check(elapsed < ceiling, "\(label) enumerates in under \(ceiling)s (advisory; got \(elapsed)s)")
}

do {
    // ~2.7 MB of text; the no-hit query forces a scan of every code unit.
    let big = String(repeating: "lorem ipsum dolor sit amet ", count: 100_000) as NSString
    measureFind("2.7 MB / no hits / case-insensitive", ceiling: 2.0, haystack: big, query: "zzzz", caseSensitive: false)
    measureFind("2.7 MB / no hits / case-sensitive", ceiling: 2.0, haystack: big, query: "zzzz", caseSensitive: true)
    // 100,000 occurrences, capped at 20,000 — the scan stops at the cap instead of building them all.
    measureFind("2.7 MB / 100,000 hits (capped)", ceiling: 2.0, haystack: big, query: "dolor", caseSensitive: false)
    // The single-character worst case for the cap: every 5th unit is a hit.
    measureFind("2.7 MB / single-character query", ceiling: 2.0, haystack: big, query: "o", caseSensitive: false)
}

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
