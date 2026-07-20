//
//  main.swift
//  GitStatusTests
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
//  Standalone assertion harness for `GitStatus.parsePorcelainZ` (git-changed-badge, criterion 13).
//  `GitStatus` is Foundation-only (no AppKit), so it compiles standalone with its own source. Not
//  part of the app target — compiled and run manually:
//
//      swiftc FEdit/Models/GitStatus.swift scripts/GitStatusTests/main.swift -o /tmp/gstests && /tmp/gstests
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

/// Build `Data` from a string whose `\u{0}` escapes are real NUL field terminators.
func porcelain(_ s: String) -> Data { Data(s.utf8) }

// MARK: - Criterion 13: rename two-field advance + desync guard

section("Rename target kept, origin discarded, following record parsed (criterion 13)")

// `R`+two spaces, target `new`, NUL, bare origin `orig`, NUL, then `M `+space+`other`, NUL.
let renameCase = GitStatus.parsePorcelainZ(porcelain("R  new\u{0}orig\u{0}M  other\u{0}"))
check(renameCase == Set(["new", "other"]),
      "exactly { new, other } — rename origin `orig` never leaks (got \(renameCase.sorted()))")

// MARK: - Supporting coverage

section("Empty / trailing-only input")
check(GitStatus.parsePorcelainZ(porcelain("")) == Set<String>(),
      "empty input → empty set")
check(GitStatus.parsePorcelainZ(porcelain("\u{0}")) == Set<String>(),
      "a lone NUL (empty field) → empty set")

section("Plain status records")
check(GitStatus.parsePorcelainZ(porcelain(" M tracked.txt\u{0}")) == Set(["tracked.txt"]),
      "worktree-modified ` M tracked.txt` → { tracked.txt }")
check(GitStatus.parsePorcelainZ(porcelain("?? untracked.txt\u{0}")) == Set(["untracked.txt"]),
      "untracked `?? untracked.txt` → { untracked.txt }")
check(GitStatus.parsePorcelainZ(porcelain("A  staged.txt\u{0}")) == Set(["staged.txt"]),
      "staged `A  staged.txt` → { staged.txt }")
check(GitStatus.parsePorcelainZ(porcelain("M  a.txt\u{0} M b.txt\u{0}")) == Set(["a.txt", "b.txt"]),
      "two records → both paths")

section("Untracked file inside a new subfolder (-uall)")
check(GitStatus.parsePorcelainZ(porcelain("?? newdir/inside.txt\u{0}")) == Set(["newdir/inside.txt"]),
      "nested untracked path preserved verbatim")

section("Non-ASCII path (raw -z bytes → UTF-8)")
check(GitStatus.parsePorcelainZ(porcelain(" M unicödé.txt\u{0}")) == Set(["unicödé.txt"]),
      "multibyte UTF-8 filename decoded intact")

section("Desync guard: a bare (unstatused) field is skipped, not misparsed")
// `garbage` is ≥4 bytes so the length guard alone would pass it — the alphabet/space check must
// reject it. The valid record after it must still parse.
check(GitStatus.parsePorcelainZ(porcelain("garbage\u{0}M  ok.txt\u{0}")) == Set(["ok.txt"]),
      "invalid field dropped, following `M  ok.txt` still yields { ok.txt }")

section("Copy record spans two fields like rename")
check(GitStatus.parsePorcelainZ(porcelain("C  copy.txt\u{0}src.txt\u{0}M  z.txt\u{0}")) == Set(["copy.txt", "z.txt"]),
      "copy target kept, source `src.txt` discarded, `M  z.txt` parsed")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
