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
//  Standalone assertion harness for `FileNode.scan(directory:)` (folder-sidebar Tier 1) and, since
//  (watcher-scan-skip-parity), for `FileNode.scanRecordingSkips(directory:cancellation:)` — the owned
//  hidden predicate and the skip record the FSEvents gate consults.
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

// MARK: - (watcher-scan-skip-parity) Owned skip predicate + the recorded skip index
//
// A SECOND fixture root, deliberately: the assertions above pin exact child counts and orderings of
// `fixtureRoot`, so every new case gets its own tree rather than perturbing theirs.

let recordingRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("FileNodeTests-recording-\(UUID().uuidString)", isDirectory: true)

makeDirectory(recordingRoot)

/// Sets `UF_HIDDEN` on `url` via `chflags(1)` and returns its exit status. The status is **asserted**
/// at every call site: on a volume without BSD flags (SMB/FAT) `chflags` fails, and a silently
/// failing fixture would make every `UF_HIDDEN` case below vacuously pass.
///
/// `noFollow` passes `-h`, which is required to flag a **symlink itself**: plain `chflags` follows
/// the link and flags its target instead (verified against this fixture — the `-h` case below also
/// asserts that the link's target stayed visible, which is exactly what a missing `-h` would break).
func chflagsHidden(_ url: URL, noFollow: Bool = false) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
    process.arguments = (noFollow ? ["-h"] : []) + ["hidden", url.path]
    try! process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

// UF_HIDDEN with NO dot in the name — the `~/Library` shape, the divergence this item exists to
// close. Foundation's `.skipsHiddenFiles` dropped these; the owned predicate must too, AND record it.
let hiddenDir = recordingRoot.appendingPathComponent("Library", isDirectory: true)
makeDirectory(hiddenDir)
makeFile(hiddenDir.appendingPathComponent("Preferences.plist"))
let hiddenDirStatus = chflagsHidden(hiddenDir)

let hiddenFile = recordingRoot.appendingPathComponent("hidden_note.txt")
makeFile(hiddenFile)
let hiddenFileStatus = chflagsHidden(hiddenFile)

// Dot entries — skipped, but deliberately NOT recorded (a name-decidable skip carries no information
// the gate cannot derive on its own).
makeDirectory(recordingRoot.appendingPathComponent(".git", isDirectory: true))
makeFile(recordingRoot.appendingPathComponent(".git/HEAD"))
makeFile(recordingRoot.appendingPathComponent(".dotfile"))

// A plain FILE named after a skip-list directory: kept by the scanner, so it must NOT be recorded —
// the gate's own final-component fall-through is what stops it dropping this file's events.
makeFile(recordingRoot.appendingPathComponent("node_modules"))

// A nested directory carrying its own skips, so the index is pinned at a non-empty relative key.
let nested = recordingRoot.appendingPathComponent("deep", isDirectory: true)
makeDirectory(nested)
makeFile(nested.appendingPathComponent("keep.txt"))
makeDirectory(nested.appendingPathComponent("node_modules", isDirectory: true))
makeFile(nested.appendingPathComponent("node_modules/left-pad.js"))
makeDirectory(nested.appendingPathComponent(".cache", isDirectory: true))
let nestedHiddenDir = nested.appendingPathComponent("Caches", isDirectory: true)
makeDirectory(nestedHiddenDir)
let nestedHiddenDirStatus = chflagsHidden(nestedHiddenDir)

// The symlink triple. Symlinks are the one entry class where "hidden" can mean two different files,
// so the A1 differential below has to be exercised over all three shapes — the link's own flag, the
// target's flag, and no target at all — or it only pins the easy cases.
//
// 1. A symlink flagged hidden ITSELF (`chflags -h`): both walks must drop it, and its target must
//    stay visible (that is what tells the `-h` apart from a link-following `chflags`).
let linkTarget = recordingRoot.appendingPathComponent("link_target.txt")
makeFile(linkTarget)
let hiddenLink = recordingRoot.appendingPathComponent("hidden_link")
try! fileManager.createSymbolicLink(at: hiddenLink, withDestinationURL: linkTarget)
let hiddenLinkStatus = chflagsHidden(hiddenLink, noFollow: true)

// 2. A symlink whose TARGET carries UF_HIDDEN but which is not flagged itself — the link is a
//    distinct entry and neither walk may let the target's flag hide it.
let linkToHidden = recordingRoot.appendingPathComponent("link_to_hidden")
try! fileManager.createSymbolicLink(at: linkToHidden, withDestinationURL: hiddenDir)

// 3. A DANGLING symlink: `resourceValues` has nothing to resolve, so this is the shape where the two
//    walks could most easily disagree on what they even see.
let danglingLink = recordingRoot.appendingPathComponent("dangling_link")
try! fileManager.createSymbolicLink(
    at: danglingLink,
    withDestinationURL: recordingRoot.appendingPathComponent("no_such_target")
)

// An unreadable directory: in the tree (empty), and in `unreadableDirs` under its relative path.
let denied = recordingRoot.appendingPathComponent("denied", isDirectory: true)
makeDirectory(denied)
makeFile(denied.appendingPathComponent("secret.txt"))
try! fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)

func recordingTeardown() {
    try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: denied.path)
    try? fileManager.removeItem(at: recordingRoot)
}

let outcome = FileNode.scanRecordingSkips(directory: recordingRoot, cancellation: nil)
let recordingChildren = outcome.node.children ?? []
let recordingNames = Set(recordingChildren.map(\.name))

section("chflags fixtures actually took (a flag-less volume must not make these cases vacuous)")
check(hiddenDirStatus == 0, "chflags hidden succeeded on the non-dot hidden DIRECTORY, got exit \(hiddenDirStatus)")
check(hiddenFileStatus == 0, "chflags hidden succeeded on the non-dot hidden FILE, got exit \(hiddenFileStatus)")
check(nestedHiddenDirStatus == 0, "chflags hidden succeeded on the nested hidden directory, got exit \(nestedHiddenDirStatus)")
check(hiddenLinkStatus == 0, "chflags -h hidden succeeded on the SYMLINK itself, got exit \(hiddenLinkStatus)")

section("UF_HIDDEN entries with no dot in their name are skipped and RECORDED")
check(!recordingNames.contains("Library"), "a UF_HIDDEN directory is excluded from the tree")
check(outcome.skippedIndex[""]?.contains("Library") == true,
      "…and recorded under the root's relative key \"\", got \(outcome.skippedIndex[""] ?? [])")
check(!recordingNames.contains("hidden_note.txt"), "a UF_HIDDEN non-dot FILE is excluded from the tree")
check(outcome.skippedIndex[""]?.contains("hidden_note.txt") == true,
      "…and recorded under the root's relative key \"\"")
check(outcome.skippedIndex["deep"]?.contains("Caches") == true,
      "a nested UF_HIDDEN directory is recorded under its parent's RELATIVE key \"deep\", got \(outcome.skippedIndex["deep"] ?? [])")

section("Dot-prefixed skips are skipped but NOT recorded (name-decidable at event time)")
check(!recordingNames.contains(".git"), ".git is excluded from the tree")
check(!recordingNames.contains(".dotfile"), ".dotfile is excluded from the tree")
check(outcome.skippedIndex[""]?.contains(".git") != true, ".git is NOT in the recorded index")
check(outcome.skippedIndex[""]?.contains(".dotfile") != true, ".dotfile is NOT in the recorded index")
check(outcome.skippedIndex["deep"]?.contains(".cache") != true, ".cache is NOT in the recorded index either")
check(!outcome.skippedIndex.values.joined().contains { $0.hasPrefix(".") },
      "no recorded name anywhere in the index starts with \".\"")

section("Skip-named DIRECTORY recorded; a plain FILE of the same name kept and not recorded")
check(outcome.skippedIndex["deep"]?.contains("node_modules") == true,
      "the node_modules DIRECTORY under deep/ is recorded at key \"deep\"")
check(recordingChildren.contains { $0.name == "node_modules" && !$0.isDirectory },
      "a plain FILE named node_modules survives in the tree")
check(outcome.skippedIndex[""]?.contains("node_modules") != true,
      "…and is NOT recorded — the gate must not drop its events")

section("Unreadable directories are in the tree (empty) and in unreadableDirs")
check(recordingChildren.contains { $0.name == "denied" && $0.children?.isEmpty == true },
      "the unreadable directory is in the tree with empty children")
check(outcome.unreadableDirs.contains("denied"),
      "…and is recorded in unreadableDirs under its relative path, got \(outcome.unreadableDirs)")
check(!outcome.unreadableDirs.contains(""),
      "a readable root is NOT in unreadableDirs")
check(!outcome.unreadableDirs.contains("deep"),
      "a readable subdirectory is NOT in unreadableDirs")

section("Symlinks: the link's own hidden flag decides, not its target's, and a dangling link survives")
check(!recordingNames.contains("hidden_link"), "a symlink flagged UF_HIDDEN with `chflags -h` is excluded from the tree")
check(outcome.skippedIndex[""]?.contains("hidden_link") == true,
      "…and recorded, like any other non-dot skip, got \(outcome.skippedIndex[""] ?? [])")
check(recordingChildren.contains { $0.name == "link_target.txt" && !$0.isDirectory },
      "…while its TARGET is still in the tree — i.e. `-h` flagged the link, not the file it points at")
check(recordingChildren.contains { $0.name == "link_to_hidden" && !$0.isDirectory && $0.children == nil },
      "a symlink whose TARGET is UF_HIDDEN is kept, as a leaf (the target's flag is not the link's)")
check(outcome.skippedIndex[""]?.contains("link_to_hidden") != true,
      "…and is therefore not recorded as skipped")
check(recordingChildren.contains { $0.name == "dangling_link" && !$0.isDirectory && $0.children == nil },
      "a DANGLING symlink is kept as a leaf rather than dropped or descended into")

// MARK: - The A1 differential (standing assertion)
//
// The whole item rests on `isHidden`-based classification being equivalent to Foundation's
// `.skipsHiddenFiles` (dot ∪ UF_HIDDEN). The dot half is true by construction (the scanner's belt);
// this pins the UF_HIDDEN half, and keeps pinning it on future OS versions — if Foundation's
// invisibility rule ever drifts from `NSURLIsHiddenKey`, this fails instead of the sidebar silently
// gaining or losing entries.

/// The pre-(watcher-scan-skip-parity) classification, verbatim: Foundation decides hidden-ness via
/// `.skipsHiddenFiles`, the scanner only applies the skip-name rule. Collects every KEPT entry's path
/// relative to `directory`.
func referenceKeptPaths(of directory: URL, relativePath: String = "", into paths: inout Set<String>) {
    let entries = (try? fileManager.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles]
    )) ?? []
    for entry in entries {
        let standardized = entry.standardizedFileURL
        let name = standardized.lastPathComponent
        let rv = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let isLink = rv?.isSymbolicLink ?? false
        let isDir = !isLink && (rv?.isDirectory ?? false)
        if (isDir || isLink) && FileNode.skippedDirectoryNames.contains(name) { continue }
        let relative = relativePath.isEmpty ? name : relativePath + "/" + name
        paths.insert(relative)
        if isDir { referenceKeptPaths(of: standardized, relativePath: relative, into: &paths) }
    }
}

/// Every node the production scanner kept, by path relative to the scanned root.
func keptPaths(of node: FileNode, relativePath: String = "", into paths: inout Set<String>) {
    for child in node.children ?? [] {
        let relative = relativePath.isEmpty ? child.name : relativePath + "/" + child.name
        paths.insert(relative)
        keptPaths(of: child, relativePath: relative, into: &paths)
    }
}

var referenceKept: Set<String> = []
referenceKeptPaths(of: recordingRoot, into: &referenceKept)
var productionKept: Set<String> = []
keptPaths(of: outcome.node, into: &productionKept)

section("A1 differential: the owned predicate keeps exactly what .skipsHiddenFiles kept")
check(!referenceKept.isEmpty, "precondition: the reference walk kept something (the differential is not empty-vs-empty)")
check(!referenceKept.contains("Library") && !referenceKept.contains("hidden_note.txt"),
      "precondition: the reference walk ALSO drops the UF_HIDDEN entries — so this fixture exercises the half under test")
check(referenceKept.contains("deep/keep.txt"), "precondition: the reference walk descends into subdirectories")
check(!referenceKept.contains("hidden_link"),
      "precondition: the reference walk also drops the `chflags -h` SYMLINK — the differential covers the link-own-flag shape")
check(referenceKept.contains("link_to_hidden") && referenceKept.contains("dangling_link"),
      "precondition: the reference walk keeps the target-hidden and dangling symlinks — the shapes the two walks could most easily split on")
check(productionKept == referenceKept,
      "production kept-set == .skipsHiddenFiles reference kept-set; only-production: \(productionKept.subtracting(referenceKept).sorted()), only-reference: \(referenceKept.subtracting(productionKept).sorted())")

// MARK: - Wrapper equivalence
//
// The two `scan` entry points are thin wrappers over `scanRecordingSkips`, which is what keeps the
// 34 assertions above pointed at production code rather than a twin.

section("scan(directory:) / scan(directory:cancellation:) are the same walk, record discarded")
check(FileNode.scan(directory: recordingRoot) == outcome.node, "scan(directory:) returns the recording walk's node")
check(FileNode.scan(directory: recordingRoot, cancellation: nil) == outcome.node,
      "scan(directory:cancellation:) returns the same node")

recordingTeardown()

// MARK: - path(_:isContainedIn:) (root-slash-prefix-match)

print("\n== path(_:isContainedIn:) containment, including the \"/\" root ==")
check(FileNode.path("/a/b/c.txt", isContainedIn: "/a/b"), "descendant is contained")
check(FileNode.path("/a/b", isContainedIn: "/a/b"), "the root itself counts as contained (equality)")
check(!FileNode.path("/a/bc", isContainedIn: "/a/b"), "a sibling sharing the prefix string is NOT contained")
check(!FileNode.path("/a", isContainedIn: "/a/b"), "an ancestor is NOT contained")
check(!FileNode.path("/x/y", isContainedIn: "/a/b"), "an unrelated path is NOT contained")
check(FileNode.path("/usr/lib/x.dylib", isContainedIn: "/"), "a \"/\" root contains every absolute path (the old inline `+ \"/\"` idiom built \"//\" and matched nothing)")
check(FileNode.path("/", isContainedIn: "/"), "\"/\" is contained in itself")
check(!FileNode.path("/a/b", isContainedIn: "/a/b/c"), "containment is not symmetric")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
