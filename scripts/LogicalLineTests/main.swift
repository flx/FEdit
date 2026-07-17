//
//  main.swift
//  LogicalLineTests
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
//  Standalone assertion harness for `LogicalLine` (editor-core Tier 2/3's shared `\n`-only
//  line-counting helper). Not part of the app target — compiled and run manually:
//
//      swiftc FEdit/Editor/LogicalLine.swift scripts/LogicalLineTests/main.swift -o /tmp/lltests && /tmp/lltests
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

// MARK: - count(in:before:) — empty document / no newlines

section("count(in:before:): empty document")
check(LogicalLine.count(in: "" as NSString, before: 0) == 0, "empty string, location 0, is line index 0")

section("count(in:before:): single line, no trailing newline")
check(LogicalLine.count(in: "abc" as NSString, before: 0) == 0, "location 0 is line index 0")
check(LogicalLine.count(in: "abc" as NSString, before: 3) == 0, "location at end of a single line is still line index 0")

// MARK: - count(in:before:): multi-line

section("count(in:before:): multi-line, no trailing newline")
let threeLines = "aaa\nbbb\nccc" as NSString
check(LogicalLine.count(in: threeLines, before: 0) == 0, "start of doc is line 0")
check(LogicalLine.count(in: threeLines, before: 1) == 0, "mid-first-line offset is still line 0 (not just exact line starts)")
check(LogicalLine.count(in: threeLines, before: 4) == 1, "start of second line is line 1")
check(LogicalLine.count(in: threeLines, before: 5) == 1, "mid-second-line offset is line 1")
check(LogicalLine.count(in: threeLines, before: 8) == 2, "start of third line is line 2")
check(LogicalLine.count(in: threeLines, before: threeLines.length) == 2, "end of doc is still line 2 (3rd, last line)")

section("count(in:before:): trailing newline (criterion 8 — trailing empty last line)")
let trailingNewline = "aaa\nbbb\n" as NSString
check(LogicalLine.count(in: trailingNewline, before: trailingNewline.length) == 2, "past the final \\n is line 2 (the trailing empty line)")

section("count(in:before:): CRLF content — \\r is NOT a line separator")
let crlf = "aaa\r\nbbb\r\nccc" as NSString
check(LogicalLine.count(in: crlf, before: 0) == 0, "start of doc is line 0")
// "aaa\r\n" -> \n at index 4 (a,a,a,\r,\n). Index 5 is start of "bbb...".
check(LogicalLine.count(in: crlf, before: 5) == 1, "right after the first \\n (index 5) is line 1, \\r alone doesn't split")
check(LogicalLine.count(in: crlf, before: 4) == 0, "the lone \\r at index 3 does not itself increment the line count")

section("count(in:before:): U+0085 (NEL) and U+2028 (LINE SEPARATOR) are NOT line separators")
let nelAndLineSep = "aaa\u{0085}bbb\u{2028}ccc" as NSString
check(LogicalLine.count(in: nelAndLineSep, before: nelAndLineSep.length) == 0, "NEL/LINE SEPARATOR never split logical lines — only \\n does (SPEC §11)")

// MARK: - lineStart(in:containing:)

section("lineStart(in:containing:): start-of-document and mid-line offsets")
check(LogicalLine.lineStart(in: threeLines, containing: 0) == 0, "location 0 is already a line start")
check(LogicalLine.lineStart(in: threeLines, containing: 1) == 0, "mid-first-line offset resolves back to the line's start (0)")
check(LogicalLine.lineStart(in: threeLines, containing: 4) == 4, "exact start of second line resolves to itself")
check(LogicalLine.lineStart(in: threeLines, containing: 6) == 4, "mid-second-line offset resolves to second line's start (4)")
check(LogicalLine.lineStart(in: threeLines, containing: threeLines.length) == 8, "end of doc resolves to the last line's start (8)")

section("lineStart(in:containing:): empty document")
check(LogicalLine.lineStart(in: "" as NSString, containing: 0) == 0, "empty doc's only line starts at 0")

// MARK: - nextLineStart(in:after:)

section("nextLineStart(in:after:): walks forward one logical line at a time")
check(LogicalLine.nextLineStart(in: threeLines, after: 0) == 4, "first line's next-line-start is right after its \\n (index 4)")
check(LogicalLine.nextLineStart(in: threeLines, after: 4) == 8, "second line's next-line-start is index 8")
check(LogicalLine.nextLineStart(in: threeLines, after: 8) == nil, "the last line (no trailing \\n) has no next-line-start")

section("nextLineStart(in:after:): trailing newline exposes one more (empty) line")
check(LogicalLine.nextLineStart(in: trailingNewline, after: 4) == 8, "second (trailing, empty) line starts right after the final \\n")
check(LogicalLine.nextLineStart(in: trailingNewline, after: 8) == nil, "the trailing empty line itself has no further next-line-start")

section("nextLineStart(in:after:): empty document has no next line")
check(LogicalLine.nextLineStart(in: "" as NSString, after: 0) == nil, "empty document: no \\n to walk to")

// MARK: - Consistency: count(...) and repeated nextLineStart(...) walks agree (used together by
// the ruler's starting-number prefix count and its fragment-by-fragment walk)

section("Consistency: count(before:) matches the number of nextLineStart hops from 0")
func lineIndex(of location: Int, in string: NSString) -> Int {
    var index = 0
    var cursor = 0
    while cursor < location, let next = LogicalLine.nextLineStart(in: string, after: cursor), next <= location {
        cursor = next
        index += 1
    }
    return index
}
check(lineIndex(of: 8, in: threeLines) == LogicalLine.count(in: threeLines, before: 8), "walking hops == \\n-count prefix at a line start")
check(lineIndex(of: 6, in: threeLines) == LogicalLine.count(in: threeLines, before: 6), "walking hops == \\n-count prefix at a mid-line offset")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
