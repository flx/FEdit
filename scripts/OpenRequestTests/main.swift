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
//  mapping every external open goes through — and for `WaitMarkers` (git-editor-wait), the
//  claim/GC scan behind `fedit --wait`. Not part of the app target — compiled and run manually:
//
//      swiftc FEdit/App/OpenRequest.swift FEdit/App/WaitMarkers.swift scripts/OpenRequestTests/main.swift -o /tmp/openreqtests && /tmp/openreqtests
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

// MARK: - CLIOpenToken tolerant decode (clitoken-tolerant-decode)

section("Tolerant decode: the system owns the read path, so every key defaults")
do {
    let decoder = JSONDecoder()

    // A PAST-version archive missing keys decodes with defaults rather than killing the scene
    // restore silently. (Unknown EXTRA keys were already ignored by synthesized Codable — the
    // future-shaped fixture below pins only that a present id is preserved, not regenerated.)
    let futureShaped = Data(#"{"id":"11111111-2222-3333-4444-555555555555","rootPath":"/tmp/x","filePath":null,"someFutureKey":42}"#.utf8)
    if let token = try? decoder.decode(CLIOpenToken.self, from: futureShaped) {
        check(token.rootPath == "/tmp/x", "unknown extra keys are ignored, known keys decode")
        check(token.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"), "a present id is preserved, not regenerated")
    } else {
        check(false, "future-shaped token failed to decode")
    }

    let missingId = Data(#"{"rootPath":"/tmp/x"}"#.utf8)
    if let token = try? decoder.decode(CLIOpenToken.self, from: missingId) {
        check(token.rootPath == "/tmp/x", "missing id: the remaining keys still decode")
    } else {
        check(false, "token with missing id failed to decode")
    }

    let empty = Data("{}".utf8)
    if let token = try? decoder.decode(CLIOpenToken.self, from: empty) {
        check(token.rootPath == "", "fully empty archive decodes to the inert empty-rootPath token")
        check(token.filePath == nil, "fully empty archive decodes with no file")
    } else {
        check(false, "empty-object token failed to decode")
    }

    // Wrong-TYPED present keys — the tolerance `try?` buys over WorkspaceSnapshot's
    // `try decodeIfPresent` contract. One fixture per field, because each `try?` is a separate
    // line that a "harmonize with WorkspaceSnapshot" edit could independently break.
    let corruptId = Data(#"{"id":12345,"rootPath":"/tmp/x"}"#.utf8)
    if let token = try? decoder.decode(CLIOpenToken.self, from: corruptId) {
        check(token.rootPath == "/tmp/x", "a wrong-typed id falls back to the sentinel without failing the rest")
    } else {
        check(false, "token with wrong-typed id failed to decode")
    }
    let corruptRoot = Data(#"{"id":"11111111-2222-3333-4444-555555555555","rootPath":42}"#.utf8)
    if let token = try? decoder.decode(CLIOpenToken.self, from: corruptRoot) {
        check(token.rootPath == "", "a wrong-typed rootPath falls back to the inert empty default")
        check(token.id == UUID(uuidString: "11111111-2222-3333-4444-555555555555"), "…without disturbing the healthy id")
    } else {
        check(false, "token with wrong-typed rootPath failed to decode")
    }
    let corruptFile = Data(#"{"rootPath":"/tmp/x","filePath":42}"#.utf8)
    if let token = try? decoder.decode(CLIOpenToken.self, from: corruptFile) {
        check(token.filePath == nil, "a wrong-typed filePath falls back to nil")
    } else {
        check(false, "token with wrong-typed filePath failed to decode")
    }

    // Decode is IDEMPOTENT for defaulted ids: the fallback is a stable sentinel, not a fresh
    // UUID, because this type's Hashable is the scene's window identity and the system may decode
    // the same archive more than once during restore. (Distinct ids only matter for
    // openWindow(value:), which only ever sees freshly built tokens with real UUIDs.)
    let a = try? decoder.decode(CLIOpenToken.self, from: missingId)
    let b = try? decoder.decode(CLIOpenToken.self, from: missingId)
    check(a != nil && a == b, "equal corrupt bytes decode to EQUAL tokens (identity is stable across re-decodes)")

    // The boundary of tolerance: a structurally alien archive (not a keyed container) must STILL
    // fail — SwiftUI then restores the window valueless, the accepted degrade. Full tolerance
    // here would materialize a plausible token out of arbitrary bytes.
    check((try? decoder.decode(CLIOpenToken.self, from: Data("[1,2,3]".utf8))) == nil,
          "a non-keyed archive still fails decode (tolerance has a floor)")

    // The encode side is untouched (synthesized): a freshly built token still round-trips to an
    // equal value. (The wire-format key spellings are pinned by the literal-JSON fixture above.)
    let request = OpenRequest(fileURL: notes)!
    let original = CLIOpenToken(request: request)
    let roundTripped = try! decoder.decode(CLIOpenToken.self, from: try! JSONEncoder().encode(original))
    check(roundTripped == original, "current-version round trip yields an equal token (tolerance changed nothing for healthy tokens)")
}

// MARK: - (git-editor-wait) WaitMarkers: the spool constant

section("WaitMarkers: the spool path IS the protocol constant")
// The other half of this assertion lives in FeditShimTests, which runs the shim under a fake HOME
// and checks where the marker lands. The path is spelled once here and once in `scripts/fedit`;
// these two tests are the only thing holding those spellings together.
check(WaitMarkers.spoolDirectory.path == NSHomeDirectory() + "/Library/Application Support/FEdit/wait",
      "spoolDirectory is ~/Library/Application Support/FEdit/wait")
check(WaitMarkers.spoolDirectory.hasDirectoryPath, "…spelled as a directory URL")

// MARK: - (git-editor-wait) WaitMarkers: claiming

let spool = fixtureRoot.appendingPathComponent("wait", isDirectory: true)

/// Writes one marker exactly the way the shim writes it: PID, newline, then the path verbatim with
/// no trailing newline. Defaults to this process's own (very much alive) PID.
@discardableResult
func writeMarker(path: String, pid: pid_t = getpid(), name: String = UUID().uuidString) -> URL {
    let url = spool.appendingPathComponent(name, isDirectory: false)
    fileManager.createFile(atPath: url.path, contents: Data("\(pid)\n\(path)".utf8))
    return url
}

func resetSpool() {
    try? fileManager.removeItem(at: spool)
    try! fileManager.createDirectory(at: spool, withIntermediateDirectories: true)
}

func spoolEntries() -> [String] {
    ((try? fileManager.contentsOfDirectory(atPath: spool.path)) ?? []).sorted()
}

section("Claiming a marker that names the file")
resetSpool()
let marker = writeMarker(path: notes.path)
if let claimed = WaitMarkers.claimMarker(for: notes, in: spool) {
    check(claimed.lastPathComponent == marker.lastPathComponent + ".claimed",
          "the claim is the marker renamed to <name>.claimed")
    check(!fileManager.fileExists(atPath: marker.path), "the unclaimed name is gone — the rename IS the claim")
    check(fileManager.fileExists(atPath: claimed.path), "and the claimed name is what the window now holds")
    // The exclusion the rename buys: nothing in memory records the claim, so this is the only
    // thing keeping a second window from taking the same shim's marker.
    check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "a claimed marker is not claimable again")
} else {
    check(false, "claimMarker returned nil for a marker naming the file")
}

section("A marker for some other file is left alone")
resetSpool()
let otherMarker = writeMarker(path: nested.path)
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "no marker names this file → nil")
check(fileManager.fileExists(atPath: otherMarker.path), "the other file's marker is untouched")

section("Two markers for the same file: one claim each, never the same one twice")
resetSpool()
let firstOfPair = writeMarker(path: notes.path)
let secondOfPair = writeMarker(path: notes.path)
if let claimedFirst = WaitMarkers.claimMarker(for: notes, in: spool),
   let claimedSecond = WaitMarkers.claimMarker(for: notes, in: spool) {
    check(claimedFirst != claimedSecond, "two waits on the same path get two different claims")
    check(Set([claimedFirst.lastPathComponent, claimedSecond.lastPathComponent])
        == Set([firstOfPair.lastPathComponent + ".claimed", secondOfPair.lastPathComponent + ".claimed"]),
          "…which are exactly the two markers that were there")
    check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "and a third call finds nothing left")
} else {
    check(false, "two same-path markers did not yield two claims")
}

section("Path spellings: both sides are standardized, so a /private prefix cancels out")
// Measured, and the reason the compare standardizes BOTH sides rather than predicting the rewrite:
// `standardizedFileURL` rewrites /private/tmp → /tmp only for a path that EXISTS, so this needs a
// real file under /tmp (the fixture lives in $TMPDIR, which is /var/folders/… and is not rewritten).
resetSpool()
let tmpFile = URL(fileURLWithPath: "/tmp/OpenRequestTests-\(UUID().uuidString).md")
fileManager.createFile(atPath: tmpFile.path, contents: Data("x\n".utf8))
let privateSpelling = "/private" + tmpFile.path
check(URL(fileURLWithPath: privateSpelling).standardizedFileURL.path != privateSpelling,
      "the fixture really does exercise a rewritten spelling (/private/tmp → /tmp)")
writeMarker(path: privateSpelling)
check(WaitMarkers.claimMarker(for: tmpFile, in: spool) != nil,
      "a marker written as /private/tmp/x is claimed for a file named /tmp/x")
resetSpool()
writeMarker(path: tmpFile.path)
check(WaitMarkers.claimMarker(for: URL(fileURLWithPath: privateSpelling), in: spool) != nil,
      "…and the other way round")
try? fileManager.removeItem(at: tmpFile)

// MARK: - (git-editor-wait) WaitMarkers: garbage collection and the entries it must not touch

section("A dead creator's marker is deleted, not claimed")
resetSpool()
// pid_t.max is beyond any live PID (macOS PIDs are five digits), and `kill` reports ESRCH for it —
// measured. This is the orphan case: a shim killed with -9, or one whose terminal closed before its
// HUP trap ran. Left in place, it would answer — and be RELEASED by — some unrelated later wait on
// the same fixed path, which for git is always the same .git/COMMIT_EDITMSG.
let deadMarker = writeMarker(path: notes.path, pid: pid_t.max)
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil,
      "a dead creator's marker is NOT claimed, even though its path matches")
check(!fileManager.fileExists(atPath: deadMarker.path), "…it is deleted on the spot")
check(spoolEntries().isEmpty, "and nothing is left behind under any name")

section("A dead creator's marker for another path is collected too")
resetSpool()
let deadElsewhere = writeMarker(path: nested.path, pid: pid_t.max)
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "still nothing to claim")
check(!fileManager.fileExists(atPath: deadElsewhere.path),
      "GC is not conditional on the path matching — any dead creator's marker goes")

section("Unparsable entries are skipped and NOT deleted")
resetSpool()
// The spool is a directory, and this function must never delete something it does not understand.
let noNewline = spool.appendingPathComponent("no-newline", isDirectory: false)
fileManager.createFile(atPath: noNewline.path, contents: Data("12345".utf8))
let noPID = spool.appendingPathComponent("no-pid", isDirectory: false)
fileManager.createFile(atPath: noPID.path, contents: Data("not-a-pid\n\(notes.path)".utf8))
let zeroPID = spool.appendingPathComponent("zero-pid", isDirectory: false)
fileManager.createFile(atPath: zeroPID.path, contents: Data("0\n\(notes.path)".utf8))
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "no claim comes out of junk")
check(spoolEntries() == ["no-newline", "no-pid", "zero-pid"], "and every junk entry is still there")

section("Already-claimed and half-written entries are never considered")
resetSpool()
let preClaimed = writeMarker(path: notes.path, name: "\(UUID().uuidString).claimed")
let halfWritten = writeMarker(path: notes.path, name: "\(UUID().uuidString).tmp")
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil,
      "a .claimed marker (another window's live claim) is not re-claimed")
check(fileManager.fileExists(atPath: preClaimed.path), "…and is left exactly as it was")
check(!fileManager.fileExists(atPath: halfWritten.path + ".claimed"),
      "a .tmp marker (a shim mid-write) is not claimed either")
check(fileManager.fileExists(atPath: halfWritten.path), "…and is left for its shim to rename")

section("A FIFO in the spool is skipped, never opened")
resetSpool()
// Probed, and the reason `read` checks the file TYPE before it opens anything: `FileHandle` opens
// with a blocking `open(2)`, and a FIFO with no writer never returns from it — the scan, and with it
// the main actor, would be wedged by a file someone else dropped into a directory this protocol does
// not own. The name here is UUID-shaped, exactly like a marker, so nothing but the type can save it.
// (A regression makes this section HANG rather than fail. That is the defect itself, not the test.)
let fifo = spool.appendingPathComponent(UUID().uuidString, isDirectory: false)
check(mkfifo(fifo.path, 0o600) == 0, "the fixture really is a FIFO (mkfifo succeeded)")
let fifoScanStarted = Date()
let fifoClaim = WaitMarkers.claimMarker(for: notes, in: spool)
let fifoScanSeconds = Date().timeIntervalSince(fifoScanStarted)
check(fifoClaim == nil, "a FIFO is never claimed")
check(fifoScanSeconds < 1,
      "…and the scan returns promptly (\(String(format: "%.3f", fifoScanSeconds)) s), it does not block in open(2)")
check(fileManager.fileExists(atPath: fifo.path), "…and it is left where it was, not deleted")

section("A .tmp is collected when its creator is dead, and only then")
resetSpool()
// The `kill -9` between the shim's `printf` and its `mv`. Nobody else ever looks at another shim's
// `.tmp`, so an uncollected one would sit in the spool forever, occupying a scan-budget slot. The
// live one is the shim mid-write: still nobody's to claim, and NOT the scan's to delete either.
let deadTmp = writeMarker(path: notes.path, pid: pid_t.max, name: "\(UUID().uuidString).tmp")
let liveTmp = writeMarker(path: notes.path, name: "\(UUID().uuidString).tmp")
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "no .tmp is claimable, dead creator or live")
check(!fileManager.fileExists(atPath: deadTmp.path), "a dead creator's .tmp is collected")
check(fileManager.fileExists(atPath: liveTmp.path), "a live creator's .tmp is left for its own shim to rename")
check(!fileManager.fileExists(atPath: liveTmp.path + ".claimed"), "…and was not claimed under any name")
check(spoolEntries() == [liveTmp.lastPathComponent], "…so exactly one entry survives the scan")

section("creatorIsDead: what the quit-time sweep asks of a .claimed entry")
resetSpool()
// `AppDelegate.applicationWillTerminate` sweeps `.claimed` residue on this. It must answer "dead"
// only for a shim that really is gone: LaunchServices single-instancing is per bundle, so a
// DerivedData build and an installed FEdit share this spool, and a quit that deleted every `.claimed`
// would exit the OTHER instance's shims 0 in the middle of an edit.
let deadClaim = writeMarker(path: notes.path, pid: pid_t.max, name: "\(UUID().uuidString).claimed")
let liveClaim = writeMarker(path: notes.path, name: "\(UUID().uuidString).claimed")
check(WaitMarkers.creatorIsDead(deadClaim), "a .claimed whose shim is gone is crash residue")
check(!WaitMarkers.creatorIsDead(liveClaim), "a .claimed whose shim is alive is a live wait, and untouchable")
let junkClaim = spool.appendingPathComponent("junk.claimed", isDirectory: false)
fileManager.createFile(atPath: junkClaim.path, contents: Data("not-a-pid\n\(notes.path)".utf8))
check(!WaitMarkers.creatorIsDead(junkClaim), "an entry that does not parse as a marker is never reported dead")
check(!WaitMarkers.creatorIsDead(spool.appendingPathComponent("nothing-here.claimed", isDirectory: false)),
      "and neither is a name that is not there at all")

section("A missing spool is the normal state, not an error")
try? fileManager.removeItem(at: spool)
check(WaitMarkers.claimMarker(for: notes, in: spool) == nil, "a spool directory that does not exist yields nil")

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
