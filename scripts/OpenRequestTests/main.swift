//
//  main.swift
//  OpenRequestTests
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
//  Standalone assertion harness for `OpenRequest` (cli-open Tier 1) — the path→(root, file)
//  mapping every external open goes through. Not part of the app target — compiled and run
//  manually:
//
//      swiftc FEdit/App/OpenRequest.swift scripts/OpenRequestTests/main.swift -o /tmp/openreqtests && /tmp/openreqtests
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

// MARK: - Fixture (plain mkdir/touch into a temp directory)

let fileManager = FileManager.default

let fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("OpenRequestTests-\(UUID().uuidString)", isDirectory: true)
    .standardizedFileURL

try! fileManager.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)

let subdir = fixtureRoot.appendingPathComponent("sub", isDirectory: true)
try! fileManager.createDirectory(at: subdir, withIntermediateDirectories: true)

let notes = fixtureRoot.appendingPathComponent("notes.md", isDirectory: false)
fileManager.createFile(atPath: notes.path, contents: Data("# Hi\n".utf8))

let nested = subdir.appendingPathComponent("nested.txt", isDirectory: false)
fileManager.createFile(atPath: nested.path, contents: Data("x\n".utf8))

// A symlink pointing at `notes.md`, for the "the app side does not resolve symlinks" assertion.
let link = fixtureRoot.appendingPathComponent("link.md", isDirectory: false)
try! fileManager.createSymbolicLink(at: link, withDestinationURL: notes)

func teardown() {
    try? fileManager.removeItem(at: fixtureRoot)
}

// MARK: - Regular file → root = parent, file = self

section("Regular file")
if let request = OpenRequest(fileURL: notes) {
    // These are the values `WorkspaceModel`/`FileNode` will be handed, so they must compare equal
    // to the URLs those types build themselves — a mismatch would break the sidebar-row highlight.
    // (`fixtureRoot` and `notes` are already standardized, so asserting standardization *here*
    // would be tautological; the `..`/`.` sections below assert it against unstandardized input.)
    check(request.root == fixtureRoot, "root is the containing folder")
    check(request.file == notes, "file is the file itself")
    // Directory-ness spelling matters for `==`: the root must carry the trailing-slash form a
    // directory URL has, the file must not.
    check(request.root.absoluteString.hasSuffix("/"), "root is spelled as a directory URL")
    check(!request.file!.absoluteString.hasSuffix("/"), "file is spelled as a file URL")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing regular file")
}

section("Regular file in a subdirectory")
if let request = OpenRequest(fileURL: nested) {
    check(request.root == subdir, "root is the immediate parent, not the top of the fixture")
    check(request.file == nested, "file is the file itself")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing nested file")
}

// MARK: - Directory → root = self, file = nil

section("Directory")
if let request = OpenRequest(fileURL: fixtureRoot) {
    check(request.root == fixtureRoot, "root is the directory itself")
    check(request.file == nil, "file is nil for a directory request")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing directory")
}

section("Directory with a trailing slash")
let trailingSlash = URL(fileURLWithPath: fixtureRoot.path + "/")
if let request = OpenRequest(fileURL: trailingSlash) {
    check(request.root == fixtureRoot, "trailing slash resolves to the same root")
    check(request.file == nil, "trailing slash still means a directory request")
    check(OpenRequest(fileURL: trailingSlash) == OpenRequest(fileURL: fixtureRoot),
          "trailing slash yields an equal request to the slash-less form")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for a directory with a trailing slash")
}

// MARK: - `..` components are standardized away

section("Path containing `..`")
let dotted = fixtureRoot
    .appendingPathComponent("sub", isDirectory: true)
    .appendingPathComponent("..", isDirectory: true)
    .appendingPathComponent("notes.md", isDirectory: false)
if let request = OpenRequest(fileURL: dotted) {
    check(request.file == notes, "`sub/../notes.md` standardizes to `notes.md`")
    check(request.root == fixtureRoot, "root of a `..` path is the standardized parent")
    check(!request.root.path.contains(".."), "no `..` survives into the root path")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for a `..`-containing path to an existing file")
}

section("Path containing `.`")
let singleDot = fixtureRoot
    .appendingPathComponent(".", isDirectory: true)
    .appendingPathComponent("notes.md", isDirectory: false)
if let request = OpenRequest(fileURL: singleDot) {
    check(request.file == notes, "`./notes.md` standardizes to `notes.md`")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for a `.`-containing path to an existing file")
}

// MARK: - Symlinks are NOT resolved (A27)

section("Symlink argument")
if let request = OpenRequest(fileURL: link) {
    // Deliberate boundary: only the `fedit` shim canonicalizes (via `realpath`). The app keeps the
    // path the user named, so a symlinked file opens under the name it was opened by.
    check(request.file == link, "a symlink is kept as the symlink path, not its destination")
    check(request.file != notes, "the symlink's destination is NOT substituted")
    check(request.root == fixtureRoot, "root is the symlink's own parent")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing symlink to a regular file")
}

// MARK: - Rejections

section("Nonexistent path")
let missing = fixtureRoot.appendingPathComponent("does-not-exist.md", isDirectory: false)
check(OpenRequest(fileURL: missing) == nil, "a path that names nothing yields nil")

section("Nonexistent directory")
let missingDir = fixtureRoot.appendingPathComponent("no-such-dir", isDirectory: true)
check(OpenRequest(fileURL: missingDir) == nil, "a nonexistent directory yields nil")

section("Non-file URL")
check(OpenRequest(fileURL: URL(string: "https://example.com/notes.md")!) == nil,
      "an https: URL yields nil")
check(OpenRequest(fileURL: URL(string: "fedit:///tmp/notes.md")!) == nil,
      "a custom-scheme URL yields nil")

// MARK: - Equatable

section("Equatable")
check(OpenRequest(fileURL: notes) == OpenRequest(fileURL: notes),
      "two requests for the same file are equal")
check(OpenRequest(fileURL: notes) != OpenRequest(fileURL: nested),
      "requests for different files are not equal")
check(OpenRequest(fileURL: notes) != OpenRequest(fileURL: fixtureRoot),
      "a file request differs from a request for its own parent directory")

// MARK: - CLIOpenToken: the window payload built from a request

section("CLIOpenToken round trip")
if let request = OpenRequest(fileURL: notes) {
    let token = CLIOpenToken(request: request)
    // The rebuilt URLs are what `ContentView` hands `addFolders`/`requestOpen`, so they have to be
    // the request's URLs exactly — trailing-slash spelling included.
    check(token.root == request.root, "root survives the URL → String → URL trip")
    check(token.file == request.file, "file survives the URL → String → URL trip")
    // The two `==`s above would also hold without the `isDirectory:` hints in `CLIOpenToken`,
    // because `URL(fileURLWithPath:)` stats a path that exists to decide directory-ness. These
    // assert the spelling itself; the vanished-path section below is the falsifiable version.
    check(token.root.hasDirectoryPath, "the rebuilt root is spelled as a directory URL")
    check(token.file?.hasDirectoryPath == false, "the rebuilt file is not spelled as a directory URL")

    let encoded = try! JSONEncoder().encode(token)
    let decoded = try! JSONDecoder().decode(CLIOpenToken.self, from: encoded)
    check(decoded == token, "encoding and decoding preserves the whole token")
    check(decoded.id == token.id, "the identity survives encoding (a restored window keeps its own)")
    check(decoded.root == request.root, "the decoded token still names the same root")
    check(decoded.file == request.file, "the decoded token still names the same file")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing regular file")
}

section("CLIOpenToken for a directory")
if let request = OpenRequest(fileURL: subdir) {
    let token = CLIOpenToken(request: request)
    check(token.filePath == nil, "a directory request's token carries no file path")
    check(token.file == nil, "and rebuilds no file URL")
    check(token.root == subdir, "its root is the directory itself")

    let decoded = try! JSONDecoder().decode(CLIOpenToken.self, from: try! JSONEncoder().encode(token))
    check(decoded == token, "a nil file path round-trips as nil")
    check(decoded.file == nil, "the decoded directory token still opens no file")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing directory")
}

section("CLIOpenToken identity: no two opens are the same window")
if let request = OpenRequest(fileURL: notes) {
    let first = CLIOpenToken(request: request)
    let second = CLIOpenToken(request: request)
    // Load-bearing: `openWindow(value:)` focuses the existing window for an EQUAL value. Two
    // `fedit notes.md` calls must give two windows (SPEC §3), so equal paths must NOT be equal
    // tokens — and a restored window's token can never be re-targeted by a later open.
    check(first != second, "two tokens for the same path are not equal")
    check(first.rootPath == second.rootPath && first.filePath == second.filePath,
          "…even though they name exactly the same root and file")
    check(Set([first, second]).count == 2, "they also hash apart, so a Set keeps both")
    check(first == CLIOpenToken(request: request, id: first.id),
          "only the id distinguishes them: same id and same paths compare equal")
} else {
    check(false, "OpenRequest(fileURL:) returned nil for an existing regular file")
}

// MARK: - Restored-token decoding (paths that no longer exist)

section("CLIOpenToken decoded from persisted state, for paths that are gone")
// The restored-window case: the system persists the window's value and hands it back on the next
// launch, by which time the paths may name nothing. That is the only case where the `isDirectory:`
// hints are load-bearing — `URL(fileURLWithPath:)` cannot stat its way to the right spelling — so
// this is the falsifiable form of the two spelling assertions above. Built by decoding because
// `init(request:)` is only reachable through an `OpenRequest`, which requires the paths to exist.
let ghostID = UUID()
let ghostRoot = "/tmp/fedit-vanished-\(ghostID.uuidString)"
let ghostJSON = Data(#"""
{"id":"\#(ghostID.uuidString)","rootPath":"\#(ghostRoot)","filePath":"\#(ghostRoot)/notes.md"}
"""#.utf8)
let ghost = try! JSONDecoder().decode(CLIOpenToken.self, from: ghostJSON)
check(!fileManager.fileExists(atPath: ghostRoot), "the fixture path really is absent from disk")
// Load-bearing for the relaunch identity check (`LaunchCoordinator.wasIssuedThisProcess`): a
// restored token carries the id it was persisted with, which is precisely how the app tells it
// apart from a token this process issued.
check(ghost.id == ghostID, "a decoded token keeps the id it was persisted with")
check(ghost.root.hasDirectoryPath, "root of a vanished path is still spelled as a directory URL")
check(ghost.root.absoluteString.hasSuffix("/"), "…the trailing-slash spelling `==` compares on")
check(ghost.file?.hasDirectoryPath == false, "file of a vanished path is still spelled as a file URL")
check(ghost.file?.absoluteString.hasSuffix("/") == false, "…with no trailing slash")
check(ghost.root == URL(fileURLWithPath: ghostRoot, isDirectory: true),
      "the rebuilt root equals the directory URL the app would build for the same path")

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
