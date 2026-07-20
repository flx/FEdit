//
//  main.swift
//  SnapshotTests
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
//  Standalone assertion harness for `WorkspaceSnapshot` (session-restore Tier 1). Not part of
//  the app target — compiled and run manually:
//
//      swiftc FEdit/Models/WorkspaceSnapshot.swift scripts/SnapshotTests/main.swift -o /tmp/snaptests && /tmp/snaptests
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

// MARK: - Round-trip fidelity

section("Round-trip: full snapshot survives encode → decode")
let full = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
do {
    let data = try JSONEncoder().encode(full)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    check(decoded == full, "decoded snapshot equals the original")
} catch {
    check(false, "round-trip encode/decode threw: \(error)")
}

section("Round-trip: nil openFilePath and nil cursorLocation survive")
let noFile = WorkspaceSnapshot(rootPaths: [], openFilePath: nil, filterText: "", cursorLocation: nil)
do {
    let data = try JSONEncoder().encode(noFile)
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
    check(decoded == noFile, "decoded snapshot equals the original")
    check(decoded.openFilePath == nil, "openFilePath round-trips as nil")
    check(decoded.cursorLocation == nil, "cursorLocation round-trips as nil")
} catch {
    check(false, "round-trip encode/decode threw: \(error)")
}

// MARK: - Corrupt JSON → nil/no-op

section("Corrupt JSON: not even valid JSON")
let notJSON = Data("this is not json {{{".utf8)
check(
    (try? JSONDecoder().decode(WorkspaceSnapshot.self, from: notJSON)) == nil,
    "garbage bytes fail to decode (nil, no crash)"
)

section("Corrupt JSON: valid JSON, wrong shape entirely")
let wrongShape = Data("[1, 2, 3]".utf8)
check(
    (try? JSONDecoder().decode(WorkspaceSnapshot.self, from: wrongShape)) == nil,
    "a JSON array (not an object) fails to decode (nil, no crash)"
)

section("Corrupt JSON: empty data")
let empty = Data()
check(
    (try? JSONDecoder().decode(WorkspaceSnapshot.self, from: empty)) == nil,
    "empty data fails to decode (nil, no crash)"
)

section("Corrupt JSON: field with the wrong type")
let wrongFieldType = Data(#"{"rootPaths": "not an array", "filterText": ""}"#.utf8)
check(
    (try? JSONDecoder().decode(WorkspaceSnapshot.self, from: wrongFieldType)) == nil,
    "a type-mismatched field fails to decode (nil, no crash)"
)

// MARK: - Missing keys → defaults (tolerant decoding)

section("Missing keys: empty object decodes to all-defaults")
let emptyObject = Data("{}".utf8)
do {
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: emptyObject)
    check(decoded.rootPaths == [], "missing rootPaths defaults to []")
    check(decoded.openFilePath == nil, "missing openFilePath defaults to nil")
    check(decoded.filterText == "", "missing filterText defaults to \"\"")
    check(decoded.cursorLocation == nil, "missing cursorLocation defaults to nil")
} catch {
    check(false, "decoding an empty object threw: \(error)")
}

section("Missing keys: partial object fills in only the absent keys")
let partial = Data(#"{"rootPaths": ["/a"], "cursorLocation": 42}"#.utf8)
do {
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: partial)
    check(decoded.rootPaths == ["/a"], "present rootPaths is decoded as given")
    check(decoded.cursorLocation == 42, "present cursorLocation is decoded as given")
    check(decoded.openFilePath == nil, "absent openFilePath defaults to nil")
    check(decoded.filterText == "", "absent filterText defaults to \"\"")
} catch {
    check(false, "decoding a partial object threw: \(error)")
}

section("Missing keys: unknown extra keys are ignored")
let extraKeys = Data(#"{"rootPaths": [], "filterText": "x", "somethingNew": 123}"#.utf8)
do {
    let decoded = try JSONDecoder().decode(WorkspaceSnapshot.self, from: extraKeys)
    check(decoded.filterText == "x", "known keys still decode alongside an unrecognized extra key")
} catch {
    check(false, "decoding an object with an unknown extra key threw: \(error)")
}

// MARK: - Equatable ⟺ byte-identical JSON (currentSnapshot dedupe safety, memory-use-audit Tier 2)

// `ContentView`'s save `.onChange` diffs the cheap `Equatable` `WorkspaceModel.currentSnapshot`
// and encodes via `snapshotJSON()` only when it changed. That dedupe is safe **only** if
// Equatable-equality implies byte-identical JSON — otherwise two snapshots that compare equal but
// encode differently would drop a real save (data loss on restore). Lock the invariant here.
//
// `encodeSnapshot` mirrors `WorkspaceModel.snapshotJSON()`'s encoder configuration EXACTLY
// (`JSONEncoder` + `.sortedKeys` + UTF-8 string). This harness compiles only against
// `WorkspaceSnapshot` (no `WorkspaceModel` / AppKit), so the equivalence is expressed over the
// value type plus an identically-configured encoder.
func encodeSnapshot(_ snapshot: WorkspaceSnapshot) -> String? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    guard let data = try? encoder.encode(snapshot),
          let json = String(data: data, encoding: .utf8) else { return nil }
    return json
}

section("Equivalence: currentSnapshot equality ⟺ byte-identical snapshotJSON")
// Representative values covering equal pairs AND a difference in each of the four encoded fields
// (including nil↔non-nil for the two optionals). The all-pairs sweep below then exercises both
// directions of the biconditional (equal→same bytes, differing→different bytes).
let base = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
let baseCopy = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
let diffRoots = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
let diffRootOrder = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/other", "/Users/felix/proj"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
let diffOpenFile = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/other.swift",
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
let nilOpenFile = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: nil,
    filterText: ".py OR .swift",
    cursorLocation: 4213
)
let diffFilter = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: "",
    cursorLocation: 4213
)
let diffCursor = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: 0
)
let nilCursor = WorkspaceSnapshot(
    rootPaths: ["/Users/felix/proj", "/Users/felix/other"],
    openFilePath: "/Users/felix/proj/main.swift",
    filterText: ".py OR .swift",
    cursorLocation: nil
)
let allEmpty = WorkspaceSnapshot(rootPaths: [], openFilePath: nil, filterText: "", cursorLocation: nil)
let allEmptyCopy = WorkspaceSnapshot(rootPaths: [], openFilePath: nil, filterText: "", cursorLocation: nil)

let equivalenceCases: [WorkspaceSnapshot] = [
    base, baseCopy, diffRoots, diffRootOrder, diffOpenFile, nilOpenFile,
    diffFilter, diffCursor, nilCursor, allEmpty, allEmptyCopy
]

var equivalenceHeld = true
var sawEqualPair = false
var sawDifferingPair = false
for a in equivalenceCases {
    for b in equivalenceCases {
        guard let ja = encodeSnapshot(a), let jb = encodeSnapshot(b) else {
            equivalenceHeld = false
            continue
        }
        let equatableEqual = (a == b)
        let jsonEqual = (ja == jb)
        if equatableEqual != jsonEqual { equivalenceHeld = false }
        if equatableEqual { sawEqualPair = true } else { sawDifferingPair = true }
    }
}
check(equivalenceHeld, "a == b (Equatable) iff encode(a) == encode(b) (byte-identical JSON) across all pairs")
check(sawEqualPair, "the sweep exercised at least one Equatable-equal pair")
check(sawDifferingPair, "the sweep exercised at least one differing pair")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
