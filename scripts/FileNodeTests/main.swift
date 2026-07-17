//
//  main.swift
//  FileNodeTests
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
//  Standalone assertion harness for `FileNode.scan(directory:)` (folder-sidebar Tier 1).
//  Not part of the app target — compiled and run manually:
//
//      swiftc FEdit/Models/FileNode.swift scripts/FileNodeTests/main.swift -o /tmp/fntests && /tmp/fntests
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

// MARK: - Fixture generator (plain mkdir/touch into a temp directory)

let fileManager = FileManager.default

func makeDirectory(_ url: URL) {
    try! fileManager.createDirectory(at: url, withIntermediateDirectories: true)
}

func makeFile(_ url: URL, contents: String = "") {
    fileManager.createFile(atPath: url.path, contents: Data(contents.utf8))
}

let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("FileNodeTests-\(UUID().uuidString)", isDirectory: true)

makeDirectory(fixtureRoot)

// Dotfiles / dot-directories — must be skipped entirely.
makeDirectory(fixtureRoot.appendingPathComponent(".git", isDirectory: true))
makeFile(fixtureRoot.appendingPathComponent(".git/HEAD"))
makeFile(fixtureRoot.appendingPathComponent(".hidden.txt"))

// Skip-list directories — must be skipped at any depth, not just the top level.
makeDirectory(fixtureRoot.appendingPathComponent("node_modules", isDirectory: true))
makeFile(fixtureRoot.appendingPathComponent("node_modules/left-pad.js"))
makeDirectory(fixtureRoot.appendingPathComponent("DerivedData", isDirectory: true))
makeFile(fixtureRoot.appendingPathComponent("DerivedData/Build.log"))

// Regular subdirectory containing a nested skip-list directory (depth check) and a plain file.
let subdir = fixtureRoot.appendingPathComponent("subdir", isDirectory: true)
makeDirectory(subdir)
makeDirectory(subdir.appendingPathComponent("node_modules", isDirectory: true))
makeFile(subdir.appendingPathComponent("node_modules/left-pad.js"))
makeFile(subdir.appendingPathComponent("nested_file.txt"))

// file2 / file10 siblings — asserts localizedStandardCompare order (file2 before file10),
// which differs from plain lexical ordering ("file10" < "file2" character-by-character).
makeFile(fixtureRoot.appendingPathComponent("file10"))
makeFile(fixtureRoot.appendingPathComponent("file2"))

// Unreadable directory (chmod 000) — must not crash the scan and must yield empty children.
let unreadable = fixtureRoot.appendingPathComponent("unreadable", isDirectory: true)
makeDirectory(unreadable)
try! fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)

// Skip check must key off "is this a directory or a symlink", not just "is this a directory" —
// a SYMLINK named after a skip-list entry (e.g. a pnpm-style `node_modules` symlink) must be
// skipped just like a real directory would be. A plain FILE with the same name is not a
// directory or symlink, so it must still survive as a leaf (deliberate, pre-existing behavior).
let skipNameVariants = fixtureRoot.appendingPathComponent("skip-name-variants", isDirectory: true)
makeDirectory(skipNameVariants)

let fileCaseDir = skipNameVariants.appendingPathComponent("file-case", isDirectory: true)
makeDirectory(fileCaseDir)
makeFile(fileCaseDir.appendingPathComponent("node_modules"))

let symlinkCaseDir = skipNameVariants.appendingPathComponent("symlink-case", isDirectory: true)
makeDirectory(symlinkCaseDir)
let symlinkTarget = symlinkCaseDir.appendingPathComponent("real_target", isDirectory: true)
makeDirectory(symlinkTarget)
makeFile(symlinkTarget.appendingPathComponent("inside.txt"))
try! fileManager.createSymbolicLink(
    at: symlinkCaseDir.appendingPathComponent("node_modules"),
    withDestinationURL: symlinkTarget
)

func teardown() {
    // Restore permissions before removal — an unreadable/unsearchable directory cannot be
    // descended into by `removeItem`, but this one is empty so restoring perms is just for
    // hygiene/safety in case a future fixture nests something inside it.
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
    try? fileManager.removeItem(at: fixtureRoot)
}

// MARK: - Scan

let root = FileNode.scan(directory: fixtureRoot)

section("Root node shape")
check(root.isDirectory, "root is a directory")
check(root.children != nil, "root.children is non-nil (directories drive OutlineGroup)")
check(root.url.standardizedFileURL == fixtureRoot.standardizedFileURL, "root.url is the standardized fixture root")
check(root.name == fixtureRoot.lastPathComponent, "root.name is the fixture root's last path component")

let rootChildren = root.children ?? []

section("Dotfiles and dot-directories are skipped")
check(!rootChildren.contains { $0.name == ".git" }, ".git is not in root.children")
check(!rootChildren.contains { $0.name == ".hidden.txt" }, ".hidden.txt is not in root.children")

section("Skip-list directories are skipped at any depth")
check(!rootChildren.contains { $0.name == "node_modules" }, "node_modules is not in root.children")
check(!rootChildren.contains { $0.name == "DerivedData" }, "DerivedData is not in root.children")

section("Folders-first ordering and localizedStandardCompare within groups")
check(rootChildren.count == 5, "root has exactly 5 visible children (skip-name-variants, subdir, unreadable, file2, file10), got \(rootChildren.map(\.name))")
if rootChildren.count == 5 {
    check(rootChildren[0].name == "skip-name-variants", "children[0] is skip-name-variants (folders first), got \(rootChildren[0].name)")
    check(rootChildren[1].name == "subdir", "children[1] is subdir (folders first), got \(rootChildren[1].name)")
    check(rootChildren[2].name == "unreadable", "children[2] is unreadable (folders first), got \(rootChildren[2].name)")
    check(rootChildren[3].name == "file2", "children[3] is file2 (file2 before file10 via localizedStandardCompare), got \(rootChildren[3].name)")
    check(rootChildren[4].name == "file10", "children[4] is file10, got \(rootChildren[4].name)")
}

section("children optionality: nil for files, non-nil for directories")
if let subdirNode = rootChildren.first(where: { $0.name == "subdir" }) {
    check(subdirNode.isDirectory, "subdir.isDirectory is true")
    check(subdirNode.children != nil, "subdir.children is non-nil")
    let subdirChildren = subdirNode.children ?? []
    check(subdirChildren.count == 1, "subdir has exactly 1 visible child (nested node_modules skipped), got \(subdirChildren.map(\.name))")
    check(subdirChildren.first?.name == "nested_file.txt", "subdir's only child is nested_file.txt")
    check(subdirChildren.first?.children == nil, "nested_file.txt.children is nil (it's a file)")
} else {
    failureCount += 1
    print("  FAIL: subdir not found in root.children")
}

if let file2Node = rootChildren.first(where: { $0.name == "file2" }) {
    check(!file2Node.isDirectory, "file2.isDirectory is false")
    check(file2Node.children == nil, "file2.children is nil (it's a file)")
}

section("Unreadable directory yields empty children, no crash")
if let unreadableNode = rootChildren.first(where: { $0.name == "unreadable" }) {
    check(unreadableNode.isDirectory, "unreadable.isDirectory is true (determined from the parent listing, not by reading it)")
    check(unreadableNode.children != nil, "unreadable.children is non-nil (empty, not nil)")
    check(unreadableNode.children?.isEmpty == true, "unreadable.children is empty")
} else {
    failureCount += 1
    print("  FAIL: unreadable not found in root.children")
}

section("Skip check covers symlinks named after a skip-list entry, not just directories")
if let skipNameVariantsNode = rootChildren.first(where: { $0.name == "skip-name-variants" }) {
    let skipNameVariantsChildren = skipNameVariantsNode.children ?? []

    if let fileCaseNode = skipNameVariantsChildren.first(where: { $0.name == "file-case" }) {
        let fileCaseChildren = fileCaseNode.children ?? []
        check(
            fileCaseChildren.contains { $0.name == "node_modules" && !$0.isDirectory },
            "a plain FILE named node_modules still survives as a leaf"
        )
    } else {
        failureCount += 1
        print("  FAIL: file-case not found in skip-name-variants children")
    }

    if let symlinkCaseNode = skipNameVariantsChildren.first(where: { $0.name == "symlink-case" }) {
        let symlinkCaseChildren = symlinkCaseNode.children ?? []
        check(
            !symlinkCaseChildren.contains { $0.name == "node_modules" },
            "a SYMLINK named node_modules is skipped, not shown as a leaf"
        )
    } else {
        failureCount += 1
        print("  FAIL: symlink-case not found in skip-name-variants children")
    }
} else {
    failureCount += 1
    print("  FAIL: skip-name-variants not found in root.children")
}

teardown()

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
