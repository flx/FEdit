//
//  WaitMarkers.swift
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

/// (git-editor-wait) The app's half of the `fedit --wait` protocol — the one thing in FEdit that an
/// external open carries beyond a path, and it travels through the filesystem because nothing else
/// can: `open -a` hands the app a path and nothing more (odoc carries no side channel), and `open
/// -W` waits for the whole app to quit rather than for one window.
///
/// The shim writes a **marker** into `spoolDirectory` before opening — its own PID, a newline, then
/// the canonical path, verbatim and with no trailing newline (a path may itself contain newlines,
/// so everything after the first one is the path) — and then blocks. The window that ends up
/// showing that file **claims** the marker by renaming it to `<name>.claimed`, and deletes it when
/// the window closes; the shim polls for exactly that.
///
/// Three properties the rename buys, and the reason the claim is not an in-memory set:
///  - it is the **acknowledgement**. Claiming happens at token *apply* — a real window, on screen,
///    with a live model, showing the file — so every way an open can be dropped upstream simply
///    never claims, and the shim's bounded phase-1 timeout reports it instead of hanging.
///  - it is the **exclusion**: `rename` of a given source succeeds exactly once, so two waits on the
///    same path can never both claim the same marker (the loser moves on to the next candidate).
///  - it is **crash-visible state**: nothing in memory has to survive for a later run to clean up.
///
/// Deliberately Foundation-only (no AppKit, no SwiftUI), the same discipline as `OpenRequest.swift`
/// and for the same reason: that is what lets `scripts/OpenRequestTests` compile and assert it on
/// its own (SPEC §13 — there is no XCTest target).
enum WaitMarkers {
    /// The spool, spelled **twice**: here and in `scripts/fedit`. The two spellings are held
    /// together by nothing but a pair of assertions — `OpenRequestTests` pins this literal, and
    /// FeditShimTests runs the shim under a fake `HOME` and pins where the marker lands.
    ///
    /// `NSHomeDirectory()` is the real home because the app is unsandboxed (xcode-scaffold); a
    /// sandbox would move this into the container and the shim would have to follow, which is a
    /// change to the protocol, not to this line alone.
    static let spoolDirectory = URL(
        fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/FEdit/wait",
        isDirectory: true
    )

    /// Suffix that turns a marker into a claim. Also what makes an already-claimed marker invisible
    /// to the next scan: names containing it are skipped outright.
    private static let claimedSuffix = ".claimed"

    /// Caps on the work one scan may do. The scan runs on the main actor, once per cli-open window
    /// apply, so it must stay trivial no matter what is in the spool: a spool that has somehow
    /// accumulated thousands of entries costs a bounded prefix of them, and a marker that is not a
    /// marker at all (something else's file, or a huge one) costs one 4 KB read.
    private static let maxScannedMarkers = 512
    private static let maxMarkerBytes = 4096

    /// Claims the marker some `fedit --wait` left for `file`, and returns the claimed URL for the
    /// window to release when it closes — or `nil` when no marker names this file (the ordinary
    /// case: almost every open is not a wait).
    ///
    /// Garbage collection rides along, and is not optional: a marker whose creator process is gone
    /// (a shim killed with `kill -9`, or one whose terminal was closed before its `HUP` trap could
    /// run) would otherwise sit in the spool forever and be claimed — and *released* — by an
    /// unrelated later wait on the same fixed path, which for git is always the same
    /// `.git/COMMIT_EDITMSG`. So a dead creator's marker is deleted the moment it is seen, whatever
    /// path it names. `kill(pid, 0)` is the liveness test; only `ESRCH` counts as dead, since
    /// `EPERM` means the process exists and belongs to someone else. (PID reuse can keep one orphan
    /// alive for a round — accepted, and vastly rarer than the unconditional version.)
    ///
    /// The GC covers `.tmp` entries too, which are otherwise nobody's: a shim killed between its
    /// `printf` and its `mv` leaves one, and no later shim ever looks at another's. They are still
    /// never *claimed* — only the shim's own rename may take a `.tmp` out of that state.
    ///
    /// Everything else is skipped rather than deleted: an entry this function cannot parse is not
    /// its business (the spool is a directory, and other things may write there), and deleting
    /// foreign files is the one failure this protocol must not have.
    ///
    /// Matching standardizes **both** sides. The shim's path comes from `realpath` and this one from
    /// the odoc URL, and whatever `standardizedFileURL` does to a `/private` prefix it does to both,
    /// so the rewrite cancels out instead of having to be predicted.
    static func claimMarker(for file: URL, in directory: URL) -> URL? {
        let fileManager = FileManager.default
        // A missing spool is the normal state on a machine that has never run `fedit --wait`.
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }

        let wantedPath = file.standardizedFileURL.path

        for name in names.prefix(maxScannedMarkers) {
            // Already claimed by some window (possibly this one, a moment ago). Marker names are
            // UUIDs, so the substring cannot occur by accident in a live marker's name.
            if name.contains(claimedSuffix) { continue }

            let marker = directory.appendingPathComponent(name, isDirectory: false)
            guard let (creatorPID, markerPath) = read(marker) else { continue }

            if isDead(creatorPID) {
                try? fileManager.removeItem(at: marker)
                continue
            }

            // Still being written by the shim (`printf` into `<uuid>.tmp`, then `mv`). Reading one
            // is harmless — a torn prefix has no newline yet and does not parse, and anything that
            // does parse already carries the whole PID, which the shim writes first — so a `.tmp`
            // whose creator is gone is collected above. It is never CLAIMED, though: the only
            // rename that may take a `.tmp` out of that state is its own shim's.
            if name.contains(".tmp") { continue }

            guard URL(fileURLWithPath: markerPath).standardizedFileURL.path == wantedPath else {
                continue
            }

            let claimed = directory.appendingPathComponent(name + claimedSuffix, isDirectory: false)
            // The rename IS the claim: if it fails, another window took this marker between the
            // read and here, so the next candidate is the right thing to try.
            guard (try? fileManager.moveItem(at: marker, to: claimed)) != nil else { continue }
            return claimed
        }

        return nil
    }

    /// Whether the process that created this spool entry is gone, `false` for anything that cannot
    /// be read as a marker at all — so an entry this protocol does not understand is never treated
    /// as collectable. The `ESRCH`-only rule is spelled out on `claimMarker`, which GCs on it.
    ///
    /// Exposed for `AppDelegate.applicationWillTerminate`, whose spool sweep has to tell this
    /// process's own crash residue from a *live* claim held by another FEdit instance.
    static func creatorIsDead(_ entry: URL) -> Bool {
        guard let (creatorPID, _) = read(entry) else { return false }
        return isDead(creatorPID)
    }

    /// `kill(pid, 0)`, read the one way this protocol reads it: only `ESRCH` is "gone". `EPERM`
    /// means the process is very much alive and simply belongs to someone else.
    private static func isDead(_ pid: pid_t) -> Bool {
        kill(pid, 0) != 0 && errno == ESRCH
    }

    /// One marker's `(creator PID, path)`, or `nil` for anything that isn't shaped like one — an
    /// entry that is not a regular file, an unreadable one, a first line that is not a PID, or no
    /// newline at all. The read is capped: a marker is two short lines, and nothing here should be
    /// able to pull a large file into memory because it happened to be sitting in the spool.
    private static func read(_ marker: URL) -> (pid_t, String)? {
        // The type is checked BEFORE the open, and that order is the point: `FileHandle` opens with
        // a blocking `open(2)`, so a FIFO left in the spool with no writer would wedge this scan —
        // and with it the main actor — forever (probe-confirmed: the open never returns). This scan
        // already assumes other things may write into this directory, so it cannot assume they only
        // write files. `attributesOfItem` is `lstat`, never a traversal: a symlink reports
        // `.typeSymbolicLink` and is skipped rather than followed, and only `.typeRegular` proceeds
        // (a FIFO reports `.typeUnknown` here, which the same comparison rejects). Skipped, never
        // deleted — the rule this whole scan follows for what it does not understand.
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: marker.path),
              attributes[.type] as? FileAttributeType == .typeRegular else { return nil }

        guard let handle = try? FileHandle(forReadingFrom: marker) else { return nil }
        defer { try? handle.close() }

        guard let data = try? handle.read(upToCount: maxMarkerBytes),
              let contents = String(data: data, encoding: .utf8),
              let newline = contents.firstIndex(of: "\n") else { return nil }

        // A non-positive PID would make `kill` mean something else entirely (0 is "this process
        // group"), so it is not a marker this app wrote — leave it alone.
        guard let creatorPID = pid_t(contents[..<newline]), creatorPID > 0 else { return nil }

        return (creatorPID, String(contents[contents.index(after: newline)...]))
    }
}
