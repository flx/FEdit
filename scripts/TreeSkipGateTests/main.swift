//
//  main.swift
//  TreeSkipGateTests
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
//  Standalone assertion harness for `TreeSkipGate` (watcher-scan-skip-parity) — the FSEvents skip
//  gate: its two static rules, its consult of the scanner's recorded `skippedIndex`, its deliberate
//  NON-consult of `unreadableDirs`, and the deliberate final-component fall-through that keeps a
//  stale verdict from perpetuating itself. Not part of the app target — compiled and run manually:
//
//      swiftc FEdit/Models/FileNode.swift FEdit/Models/TreeSkipGate.swift \
//          scripts/TreeSkipGateTests/main.swift -o /tmp/tsgtests && /tmp/tsgtests
//
//  Named `main.swift` because Swift only allows top-level statements in a file with that exact
//  name when compiling multiple files together.
//
//  Its own compile line rather than an addition to `scripts/FileNodeTests`: the two tiers stay
//  independently revertible, and FileNodeTests' documented command is untouched. The gate is pure
//  (no filesystem, no clock, no thread), so every case below is a table row.
//
//  Deliberately NOT covered here, and recorded as such: `WorkspaceModel.handleTreeChange` /
//  `isSkippedTreePath`, which resolve the containing root and hand this gate its components.
//  `WorkspaceModel` imports AppKit, so no standalone harness can reach it; that wiring is
//  review-traced only. What CAN be pinned — the component derivation, including the `"/"`-root
//  shape — lives in `TreeSkipGate.belowRootComponents` precisely so that it is pinned here.
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

// MARK: - Table helpers

/// The gate, driven the way `WorkspaceModel.isSkippedTreePath` drives it: a below-root path split
/// into components, plus the containing root's record.
func gate(_ belowRootPath: String, _ record: SkipRecord? = nil) -> Bool {
    TreeSkipGate.isSkipped(
        belowRootComponents: belowRootPath.split(separator: "/"),
        record: record
    )
}

/// The full caller-side path: derive the components from an absolute event path against an absolute
/// root path, then gate them. Mirrors `isSkippedTreePath`'s body for a single (already-longest) root.
func gateAbsolute(path: String, root: String, _ record: SkipRecord? = nil) -> Bool {
    check(FileNode.path(path, isContainedIn: root), "precondition: \(path) is contained in \(root)")
    return TreeSkipGate.isSkipped(
        belowRootComponents: TreeSkipGate.belowRootComponents(of: path, root: root),
        record: record
    )
}

// MARK: - Rule 1: dot components (exact vs the scanner by construction)

section("Rule 1: a dot-prefixed component anywhere means skipped")
check(gate(".git"), "a dot FINAL component is skipped")
check(gate(".git/HEAD"), "a dot INTERMEDIATE component is skipped")
check(gate("src/.hidden.txt"), "a dot final component under a plain directory is skipped")
check(gate("src/.cache/blobs/ab/cd"), "a dot component at any depth is skipped")
check(!gate("src/main.swift"), "…while a dot-free path is not")
check(!gate("a.b/c.d.e"), "dots INSIDE a component do not count — only a leading one")

// MARK: - Rule 2: skip-names, intermediates only (the plain-file fix)

section("Rule 2: skip-names skip as INTERMEDIATES, fall through as FINAL components")
check(gate("node_modules/left-pad/index.js"), "an intermediate node_modules is skipped")
check(gate("DerivedData/Build/x.o"), "an intermediate DerivedData is skipped")
check(gate("src/node_modules/pkg/a.js"), "…at any depth")
check(!gate("node_modules"), "a FINAL node_modules is NOT skipped — it may be a plain file the scanner keeps")
check(!gate("src/DerivedData"), "…same for a final DerivedData")
check(!gate("node_modules_helper/x.js"),
      "an INTERMEDIATE name merely CONTAINING a skip-name is not skipped (the position rule 2 actually runs at)")

// MARK: - Rule 3: the recorded index, intermediates only (the un-stick rule)

/// The `~/Library` shape: the root's own listing skipped a `UF_HIDDEN`, dot-free directory.
let libraryRecord = SkipRecord(skippedIndex: ["": ["Library"]], unreadableDirs: [])
/// The same verdict one level down, to pin that index keys are RELATIVE paths, not bare names.
let nestedRecord = SkipRecord(skippedIndex: ["deep": ["Caches"]], unreadableDirs: [])
/// A **two-level** key: the only shape that tells a relative-path key apart from a bare-name one
/// (at depth 1 the two coincide, so a `deep`-keyed record alone cannot pin this).
let deepKeyRecord = SkipRecord(skippedIndex: ["src/gen": ["Cache"]], unreadableDirs: ["src/vendor/blobs"])

section("Rule 3: a recorded INTERMEDIATE component is skipped")
check(gate("Library/Preferences/com.apple.finder.plist", libraryRecord),
      "the ~/Library storm case: a recorded intermediate drops the whole subtree's events")
check(gate("Library/x", libraryRecord), "…at any depth beneath it")
check(gate("deep/Caches/blob", nestedRecord), "a record keyed at a nested RELATIVE path applies there")
check(!gate("Caches/blob", nestedRecord),
      "…and NOT at the root: \"deep\" is part of the key, so a same-named entry elsewhere is unaffected")
check(!gate("deep/other/blob", nestedRecord), "a sibling of the recorded entry is unaffected")
check(!gate("Library/Preferences/com.apple.finder.plist", nil),
      "with no record at all the same path falls through — the pre-item behavior")

section("Rule 3: index keys are RELATIVE PATHS, not bare directory names")
check(gate("src/gen/Cache/blob.bin", deepKeyRecord),
      "a two-level key \"src/gen\" is matched by the full ancestor path")
check(!gate("gen/Cache/blob.bin", deepKeyRecord),
      "…and NOT by the bare name \"gen\" alone (a bare-name key scheme would wrongly skip this)")
check(!gate("other/gen/Cache/blob.bin", deepKeyRecord),
      "…nor by \"gen\" reached along a different path")
check(!gate("src/vendor/blobs/x/y", deepKeyRecord),
      "an unreadable ancestor does NOT skip — unreadableDirs is not consulted at all (see below)")

section("Rule 3: a recorded FINAL component is NOT skipped (this is what un-sticks a stale record)")
check(!gate("Library", libraryRecord),
      "an event naming the recorded entry itself falls through, so its `chflags nohidden` fires a rescan")
check(!gate("deep/Caches", nestedRecord), "…at any depth")

// MARK: - unreadableDirs is recorded but NEVER consulted (black-hole avoidance)
//
// The gate cannot gate on readability, because nothing ever announces that readability came back: a
// probe (2026-08-11) established that a TCC grant fires no filesystem event at all, and that
// creating/writing inside a directory never delivers that directory's own path. So the un-stick
// event rule 3 relies on (a `chflags` toggle DOES name the directory — same probe) has no analogue
// here, and a consulted `unreadableDirs` entry would make its whole subtree a PERMANENT auto-refresh
// black hole — worst case the key "", a TCC-denied root, going dead until relaunch. The events below
// therefore get through, drive damped rescans that surface nothing while the directory stays
// unreadable, and recover on their own the moment it becomes readable.

/// The TCC-denied `~/Documents` shape.
let deniedRecord = SkipRecord(skippedIndex: [:], unreadableDirs: ["Documents"])
/// A root the scanner could not read at all.
let deniedRootRecord = SkipRecord(skippedIndex: [:], unreadableDirs: [""])

section("unreadableDirs never skips: events under a recorded-unreadable directory get through")
check(!gate("Documents/notes.txt", deniedRecord),
      "an event under an unreadable directory is NOT skipped — gating it would never un-stick (no event announces a TCC grant)")
check(!gate("Documents/a/b/c", deniedRecord), "…at any depth")
check(!gate("Documents", deniedRecord), "…and neither is an event naming the unreadable directory itself")
check(!gate("Documents_other/x", deniedRecord), "a sibling sharing the name's prefix is likewise unaffected")
check(!gate("Other/x", deniedRecord), "as is an unrelated subtree")

section("unreadableDirs never skips: the \"\" (unreadable ROOT) key is not a whole-root black hole")
check(!gate("anything", deniedRootRecord),
      "a direct child of an unreadable root is NOT dropped — the \"\" key is precisely the permanent black hole this avoids")
check(!gate("a/b/c", deniedRootRecord), "…nor is anything deeper")
check(!gate("", deniedRootRecord), "…nor an event naming the root itself")

section("…but the static rules still apply inside an unreadable subtree")
check(gate("Documents/.git/HEAD", deniedRecord), "the dot rule still fires under an unreadable directory")
check(gate("Documents/node_modules/a.js", deniedRecord), "…as does the skip-name intermediate rule")

// MARK: - Record absence / emptiness: statics only

let emptyRecord = SkipRecord()

section("A nil or empty record leaves exactly the two static rules standing")
for (label, record) in [("nil", SkipRecord?.none), ("empty", SkipRecord?.some(emptyRecord))] {
    check(gate(".git/HEAD", record), "\(label) record: the dot rule still applies")
    check(gate("node_modules/a.js", record), "\(label) record: the skip-name intermediate rule still applies")
    check(!gate("node_modules", record), "\(label) record: a final skip-name still falls through")
    check(!gate("src/main.swift", record), "\(label) record: an ordinary path is not skipped")
}

// MARK: - Empty components: an event on the watched root itself

section("Empty components (an event naming the root itself) are never skipped")
check(!gate(""), "no components, no record → not skipped")
check(!gate("", libraryRecord), "…and a record cannot make the root itself skipped")
check(!gate("", deniedRootRecord), "…nor one that records the root as unreadable (which never skips anything anyway)")

// MARK: - Caller-side component derivation, including the "/" root

section("belowRootComponents: the \"/\" root and ordinary roots produce the same shapes")
check(TreeSkipGate.belowRootComponents(of: "/usr/lib/x.dylib", root: "/").map(String.init) == ["usr", "lib", "x.dylib"],
      "a \"/\" root yields the components with no empty leading element (the \"//\" class is structurally excluded)")
check(TreeSkipGate.belowRootComponents(of: "/a/b/c/d.txt", root: "/a/b").map(String.init) == ["c", "d.txt"],
      "an ordinary root drops exactly its own prefix")
check(TreeSkipGate.belowRootComponents(of: "/a/b", root: "/a/b").isEmpty,
      "the root itself yields no components")
check(TreeSkipGate.belowRootComponents(of: "/", root: "/").isEmpty,
      "the \"/\" root naming itself yields no components")
check(TreeSkipGate.belowRootComponents(of: "/a/b//c///d", root: "/a/b").map(String.init) == ["c", "d"],
      "repeated separators collapse — no empty component ever reaches the gate")

section("The full caller path: absolute event path + absolute root, including \"/\"")
check(gateAbsolute(path: "/Users/felix/Library/Preferences/x.plist", root: "/Users/felix", libraryRecord),
      "the ~/Library storm case, end to end from an absolute FSEvents-shaped path")
check(!gateAbsolute(path: "/Users/felix/Library", root: "/Users/felix", libraryRecord),
      "…and the un-stick event on Library itself still gets through, end to end")
check(gateAbsolute(path: "/Library/Caches/x", root: "/", SkipRecord(skippedIndex: ["": ["Library"]], unreadableDirs: [])),
      "a \"/\" root consults the record under the same relative keys")
check(!gateAbsolute(path: "/Library", root: "/", SkipRecord(skippedIndex: ["": ["Library"]], unreadableDirs: [])),
      "…with the same final-component fall-through")
check(!gateAbsolute(path: "/Users/felix", root: "/Users/felix", libraryRecord),
      "an event naming the root itself is not skipped")

// MARK: - Combined shapes

section("Combined: the rules compose, and each direction is reachable")
let mixedRecord = SkipRecord(skippedIndex: ["": ["Library"], "src": ["Generated"]], unreadableDirs: ["private"])
check(gate("src/Generated/parser.swift", mixedRecord), "a recorded intermediate at a nested key skips")
check(!gate("src/Generated", mixedRecord), "…while naming it directly does not")
check(!gate("private/a", mixedRecord), "an unreadable ancestor does not skip, even alongside a non-empty index")
check(!gate("private", mixedRecord), "…nor does naming it directly")
check(gate("src/.git/config", mixedRecord), "the dot rule still fires inside a recorded root's tree")
check(!gate("src/main.swift", mixedRecord), "an ordinary path under the same record is not skipped")
check(gate("Library/node_modules", mixedRecord),
      "a path under a recorded intermediate is skipped even when its final component is a skip-name (that the final component ALONE would not skip is pinned by the `!gate(\"node_modules\")` case above)")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
