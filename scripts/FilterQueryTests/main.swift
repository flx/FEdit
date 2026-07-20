//
//  main.swift
//  FilterQueryTests
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
//  Standalone assertion harness for `FilterQuery` (filter-query Tier 1). Not part of the app
//  target — compiled and run manually:
//
//      swiftc FEdit/Models/FilterQuery.swift scripts/FilterQueryTests/main.swift -o /tmp/fqtests && /tmp/fqtests
//
//  Named `main.swift` because Swift only allows top-level statements in a file with that exact
//  name when compiling multiple files together.
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

/// Harness-local: an unanchored MatchTerm, for rewriting the pre-anchor `.groups ==` assertions.
/// Uses the memberwise initializer (not the parsing one) so expected values never route through
/// the code under test.
func lit(_ s: String) -> MatchTerm { MatchTerm(text: s, anchorStart: false, anchorEnd: false) }

// MARK: - Tokenizer (criterion 7: whitespace splitting, no crash)

section("Tokenizer: empty / whitespace-only input")
check(FilterQuery.tokenize("") == [], "empty string tokenizes to []")
check(FilterQuery.tokenize("   ") == [], "spaces-only tokenizes to []")
check(FilterQuery.tokenize("\t\n  \n\t") == [], "tabs/newlines-only tokenizes to []")

section("Tokenizer: whitespace splitting (spaces, tabs, newlines)")
check(
    FilterQuery.tokenize("a\tb\nc  d") == [.term("a"), .term("b"), .term("c"), .term("d")],
    "splits on any whitespace run (tabs, newlines, multiple spaces)"
)

section("Tokenizer: operators are exact-uppercase")
check(
    FilterQuery.tokenize(".py AND .swift") == [.term(".py"), .and, .term(".swift")],
    "\"AND\" becomes .and"
)
check(
    FilterQuery.tokenize(".py OR .swift") == [.term(".py"), .or, .term(".swift")],
    "\"OR\" becomes .or"
)
check(
    FilterQuery.tokenize("and or And Or") == [.term("and"), .term("or"), .term("And"), .term("Or")],
    "non-exact-case \"and\"/\"or\" spellings are ordinary terms"
)

section("Tokenizer: no crash on unicode / very long input")
check(FilterQuery.tokenize("日本語 テスト") == [.term("日本語"), .term("テスト")], "unicode terms tokenize as terms")
let longTerm = String(repeating: "x", count: 10_000)
check(FilterQuery.tokenize(longTerm) == [.term(longTerm)], "a very long single term tokenizes without crashing")

// MARK: - Parsed groups structure (criteria 1-3: the three grammar examples)

section("Grammar: \".py .swift\" — adjacency is implicit OR (union)")
check(
    FilterQuery(".py .swift").groups == [[lit(".py")], [lit(".swift")]],
    "groups == [[\".py\"], [\".swift\"]]"
)

section("Grammar: \".py AND .swift\" — single AND-group")
check(
    FilterQuery(".py AND .swift").groups == [[lit(".py"), lit(".swift")]],
    "groups == [[\".py\", \".swift\"]]"
)

section("Grammar: \".swift AND main OR .md\" — AND binds tighter than OR")
check(
    FilterQuery(".swift AND main OR .md").groups == [[lit(".swift"), lit("main")], [lit(".md")]],
    "groups == [[\".swift\", \"main\"], [\".md\"]]"
)

// MARK: - Graceful degradation (criterion 6)

section("Degradation: leading operator ignored")
check(FilterQuery("AND .py").groups == [[lit(".py")]], "\"AND .py\" == [[\".py\"]]")
check(FilterQuery("OR .py").groups == [[lit(".py")]], "\"OR .py\" == [[\".py\"]]")

section("Degradation: trailing operator ignored")
check(FilterQuery(".py AND").groups == [[lit(".py")]], "\".py AND\" == [[\".py\"]]")
check(FilterQuery(".py OR").groups == [[lit(".py")]], "\".py OR\" == [[\".py\"]]")

section("Degradation: consecutive operators — first wins")
check(
    FilterQuery(".py AND OR .md").groups == [[lit(".py"), lit(".md")]],
    "\".py AND OR .md\" == [[\".py\", \".md\"]] (AND wins)"
)
check(
    FilterQuery(".py OR AND .md").groups == [[lit(".py")], [lit(".md")]],
    "\".py OR AND .md\" == [[\".py\"], [\".md\"]] (OR wins)"
)
check(
    FilterQuery(".py AND AND .md").groups == [[lit(".py"), lit(".md")]],
    "\".py AND AND .md\" == [[\".py\", \".md\"]]"
)

section("Degradation: operator-only input parses to zero groups")
check(FilterQuery("AND").groups == [], "\"AND\" alone == []")
check(FilterQuery("AND").isEmpty, "\"AND\" alone isEmpty")
check(FilterQuery("OR AND").groups == [], "\"OR AND\" == []")
check(FilterQuery("OR AND").isEmpty, "\"OR AND\" isEmpty")

section("Degradation: zero-group query matches nothing")
check(!FilterQuery("AND").matches("anything/at/all.swift"), "operator-only query never matches")
check(!FilterQuery("").matches("anything/at/all.swift"), "blank query never matches")
check(!FilterQuery("   ").matches("anything/at/all.swift"), "whitespace-only query never matches")

// MARK: - Matching corpus (criteria 1-5)

let corpus = [
    "src/main.swift",
    "src/helper.swift",
    "tools/gen.py",
    "README.md",
    "weird.py.swift",
    "colors.swift",
]

func matchedPaths(_ query: FilterQuery, in paths: [String] = corpus) -> Set<String> {
    Set(paths.filter { query.matches($0) })
}

section("Matching: \".py .swift\" union — matches every path except README.md")
check(
    matchedPaths(FilterQuery(".py .swift")) == Set(corpus.filter { $0 != "README.md" }),
    "\".py .swift\" matches everything except README.md"
)
check(FilterQuery(".py .swift").matches("a/main.py"), "\".py .swift\" matches a/main.py")
check(FilterQuery(".py .swift").matches("b/main.swift"), "\".py .swift\" matches b/main.swift")

section("Matching: \".py AND .swift\" — only the doubled extension matches")
check(
    matchedPaths(FilterQuery(".py AND .swift")) == ["weird.py.swift"],
    "\".py AND .swift\" matches only weird.py.swift"
)
check(!FilterQuery(".py AND .swift").matches("main.py"), "\".py AND .swift\" does not match main.py alone")
check(!FilterQuery(".py AND .swift").matches("main.swift"), "\".py AND .swift\" does not match main.swift alone")
check(
    matchedPaths(FilterQuery(".py AND .swift"), in: corpus.filter { $0 != "weird.py.swift" }).isEmpty,
    "over a corpus without the doubled extension, \".py AND .swift\" matches nothing"
)

section("Matching: \".swift AND main OR .md\" — AND binds tighter")
check(
    matchedPaths(FilterQuery(".swift AND main OR .md")) == ["src/main.swift", "README.md"],
    "\".swift AND main OR .md\" matches src/main.swift and README.md"
)
check(
    !FilterQuery(".swift AND main OR .md").matches("src/helper.swift"),
    "\".swift AND main OR .md\" does not match src/helper.swift"
)

section("Matching: case-insensitive substring of the root-relative path (criterion 4)")
check(FilterQuery(".PY").matches("tools/gen.py"), "\".PY\" matches tools/gen.py (case-insensitive)")
check(FilterQuery("src/").matches("src/a.txt"), "\"src/\" matches a folder-segment prefix")
check(FilterQuery("main").matches("sub/main.swift"), "\"main\" matches a path fragment mid-string")

section("Matching: operators are exact-uppercase; \"and\"/\"or\" are ordinary terms (criterion 5)")
check(FilterQuery("or").groups == [[lit("or")]], "\"or\" (lowercase) parses as a single term, not an operator")
check(FilterQuery("or").matches("colors.swift"), "\"or\" matches colors.swift as a substring")
check(!FilterQuery("or").matches("src/main.swift"), "\"or\" does not match src/main.swift")

// MARK: - No crash on any input (criterion 7)

section("Robustness: no crash on unicode / very long terms")
let unicodeQuery = FilterQuery("日本語")
check(unicodeQuery.groups == [[lit("日本語")]], "unicode query parses to a single term group")
check(unicodeQuery.matches("some/日本語/path"), "unicode term matches a path containing it")

let longQuery = FilterQuery(longTerm)
check(longQuery.groups == [[lit(longTerm)]], "very long single-term query parses without crashing")
check(longQuery.matches("prefix-\(longTerm)-suffix"), "very long term matches as a substring")

// MARK: - Anchors (filter-anchors)

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

section("Matching: both anchors (^X$) — case-insensitive whole-path EQUALITY")
check(FilterQuery("^a$").matches("a"), "\"^a$\" matches path \"a\" exactly")
check(!FilterQuery("^a$").matches("ab"), "\"^a$\" does not match \"ab\"")
check(!FilterQuery("^a$").matches("ba"), "\"^a$\" does not match \"ba\"")
check(FilterQuery("^main.swift$").matches("main.swift"), "\"^main.swift$\" matches the exact root-relative path")
check(!FilterQuery("^main.swift$").matches("src/main.swift"), "\"^main.swift$\" does not match when the path has a directory prefix")
// Regression (adv-review-behavior): ^X$ is EQUALITY, not prefix∧suffix — a longer path that both
// starts and ends with X must NOT match.
check(!FilterQuery("^a$").matches("aa"), "\"^a$\" does not match \"aa\" (equality, not prefix∧suffix)")
check(!FilterQuery("^a$").matches("aXa"), "\"^a$\" does not match \"aXa\"")
check(!FilterQuery("^a$").matches("aba"), "\"^a$\" does not match \"aba\"")
check(!FilterQuery("^test$").matches("test/test"), "\"^test$\" does not match \"test/test\" (folder+file share a name)")
check(!FilterQuery("^main.swift$").matches("main.swiftXmain.swift"), "\"^main.swift$\" does not match a longer path repeating it at both ends")
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

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
