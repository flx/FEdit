//
//  GitStatus.swift
//  FEdit
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

import Foundation

/// Read-only git working-tree status for the sidebar's "(changed)" file-row badge (SPEC §5.6).
/// A dependency-free, UI-free namespace of static functions: repo-root detection, a blocking
/// off-main `git status` invocation with a bounded watchdog timeout, the `-z` porcelain-v1 parse,
/// and root-relative-path → absolute-URL mapping. Nothing here touches AppKit or the main actor.
///
/// `changedFileURLs(inRepositoryRoot:)` is **synchronous and blocking** and MUST be called off the
/// main actor on a **dedicated** thread (WorkspaceModel's `gitQueue`), never the Swift cooperative
/// pool: it drains an uninterruptible `readDataToEndOfFile()` that a cooperative worker must not be
/// parked on. Every failure — git missing, launch throwing, non-zero exit, or the watchdog timeout
/// — degrades to an empty set (no badges); it never throws and never crashes.
enum GitStatus {
    /// Watchdog timeout: a `git status` still running after this many seconds is `terminate()`d and
    /// the recompute degrades to an empty set. Caps the worst case of a pathologically slow `-uall`
    /// walk (a stray un-`.gitignore`d `node_modules`) or a hung git so the window never blocks.
    private static let timeoutSeconds: TimeInterval = 5

    /// The porcelain-v1 XY status alphabet (`!` excluded — we never pass `--ignored`). A primary
    /// field whose first two bytes are not both in this set (or whose third byte is not a space) is
    /// a `-z` desync and is skipped, bounding a mis-stepped rename advance to one missed entry
    /// rather than a misparsed tail.
    private static let statusAlphabet: Set<UInt8> = Set(Array(" MTADRCU?".utf8))

    /// Whether `root` is itself the root of a git repository (directly contains `.git`). True
    /// whether `.git` is a directory (normal repo) or a file (worktree/submodule gitlink) — we only
    /// need "this root is a repo root". A cheap `stat`, safe to call on the main actor.
    static func isRepositoryRoot(_ root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    /// Absolute, `.standardizedFileURL`-normalized URLs of every changed path under `root`
    /// (modified, staged, untracked, or the new side of a rename), or an **empty set on any
    /// failure**. Synchronous and blocking — see the type doc for the threading contract.
    nonisolated static func changedFileURLs(inRepositoryRoot root: URL) -> Set<URL> {
        guard let output = runGitStatus(inRepositoryRoot: root) else { return [] }
        var urls = Set<URL>()
        for relativePath in parsePorcelainZ(output) {
            urls.insert(absoluteURL(forRelativePath: relativePath, under: root))
        }
        return urls
    }

    // MARK: - Subprocess

    /// Runs `git status --porcelain=v1 -z -uall` in `root` and returns its raw stdout, or `nil` on
    /// any failure. Deadlock-safe: stderr is `/dev/null` (only stdout is a pipe, so no second
    /// undrained ~64 KB buffer can block git while we block reading stdout), and stdout is drained
    /// with `readDataToEndOfFile()` **before** `waitUntilExit()`. A watchdog on a **separate** GCD
    /// queue `terminate()`s a git still running after `timeoutSeconds`; terminating closes stdout,
    /// which unblocks the otherwise-uncancellable read — so a hung git can never park the calling
    /// (dedicated) thread past the timeout.
    private static func runGitStatus(inRepositoryRoot root: URL) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.currentDirectoryURL = root
        // `--no-optional-locks` so a badge recompute never takes the index lock and fights a
        // concurrent git; `--porcelain=v1` pins a stable machine format; `-z` emits NUL-terminated
        // *unquoted* paths (no `core.quotepath` handling); `-uall` lists untracked files
        // individually (default `-unormal` collapses a new dir to one entry that maps to no row).
        process.arguments = ["--no-optional-locks", "status", "--porcelain=v1", "-z", "-uall"]

        let pipe = Pipe()
        process.standardOutput = pipe
        // Mandatory: an undrained stderr *pipe* could fill its ~64 KB buffer and block git while we
        // block reading stdout. `/dev/null` sinks stderr so only stdout is ever read.
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Watchdog on a separate global-queue timer (never the cooperative pool). `timedOut` is
        // lock-guarded: the watchdog thread writes it and the calling thread reads it below.
        let lock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            lock.lock()
            timedOut = true
            lock.unlock()
            process.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

        // Drain first (deadlock-safe): returns on clean exit, or when the watchdog closes the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        lock.lock()
        let didTimeOut = timedOut
        lock.unlock()
        if didTimeOut { return nil }
        // Non-zero covers termination-by-signal, "not a repo", the CLT stub without tools, etc.
        guard process.terminationStatus == 0 else { return nil }
        return data
    }

    // MARK: - Parse

    /// Parses `git status --porcelain=v1 -z -uall` output (a run of NUL-terminated fields) into the
    /// set of root-relative POSIX paths that changed. Pure and side-effect-free (bar a desync log),
    /// so it is unit-testable without launching git (criterion 13).
    ///
    /// Each **primary** field is `XY<space>PATH`. Every primary field is validated before use
    /// (byte[2] is a space and byte[0]/byte[1] are in the porcelain XY alphabet); a field that
    /// fails is skipped + logged, bounding a `-z` desync to one missed entry rather than a
    /// misparsed tail (a bare rename-origin path is ≥4 bytes, so length alone is insufficient — the
    /// alphabet/space check is what catches a desync). A rename/copy (`R`/`C` in either status
    /// position) spans **two** fields — the primary field's PATH is the new/current path (kept), and
    /// the next field is the original path (consumed **raw**, not validated, and discarded).
    nonisolated static func parsePorcelainZ(_ data: Data) -> Set<String> {
        let bytes = [UInt8](data)
        let count = bytes.count
        var result = Set<String>()
        var index = 0

        while index < count {
            // Extract the next NUL-terminated field [fieldStart, fieldEnd), then advance the cursor
            // past this field and its NUL terminator for the following iteration.
            let fieldStart = index
            var fieldEnd = fieldStart
            while fieldEnd < count && bytes[fieldEnd] != 0 { fieldEnd += 1 }
            index = fieldEnd < count ? fieldEnd + 1 : fieldEnd

            // A primary field is at least "XY PATH" with a 1-byte path → 4 bytes. Anything shorter
            // (including a trailing empty field after the final NUL) is skipped silently.
            guard fieldEnd - fieldStart >= 4 else { continue }

            let x = bytes[fieldStart]
            let y = bytes[fieldStart + 1]
            guard bytes[fieldStart + 2] == 0x20,
                  statusAlphabet.contains(x), statusAlphabet.contains(y) else {
                NSLog("GitStatus: skipping unparseable porcelain field (possible -z desync)")
                continue
            }

            // Keep the primary (new/current) path: the bytes after "XY ".
            result.insert(String(decoding: bytes[(fieldStart + 3)..<fieldEnd], as: UTF8.self))

            // Rename/copy: the record spans two fields. Consume the next (origin) field raw — it is
            // a path, not a status field, so it is NOT validated — and discard it (the old path no
            // longer exists on disk and would match no row anyway).
            if x == UInt8(ascii: "R") || x == UInt8(ascii: "C")
                || y == UInt8(ascii: "R") || y == UInt8(ascii: "C") {
                var originEnd = index
                while originEnd < count && bytes[originEnd] != 0 { originEnd += 1 }
                index = originEnd < count ? originEnd + 1 : originEnd
            }
        }

        return result
    }

    // MARK: - Path mapping

    /// Maps a root-relative POSIX path `P` to an absolute URL by splitting on `"/"` and
    /// `appendPathComponent`-ing each segment onto `root`, then `.standardizedFileURL`.
    /// Segment-by-segment avoids any ambiguity in how `appendPathComponent` treats an embedded `/`.
    /// Because `FileNode` builds its node URLs the same way (`contentsOfDirectory` entries off the
    /// standardized root, each `.standardizedFileURL`), the result is byte-identical to the row's
    /// `node.url` and set-membership matches. Deliberately does **not** resolve symlinks (FileNode
    /// does not; resolving would desync `/tmp` vs `/private/tmp`).
    private static func absoluteURL(forRelativePath path: String, under root: URL) -> URL {
        var url = root
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            url.appendPathComponent(String(segment))
        }
        return url.standardizedFileURL
    }
}
