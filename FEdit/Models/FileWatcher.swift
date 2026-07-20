//
//  FileWatcher.swift
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

/// A cheap, race-robust fingerprint of a file's on-disk identity+state (external-change-watch),
/// **owned here** — the self-write suppression key used by `WorkspaceModel`. `(inode, size, mtime)`
/// via a raw `stat(2)`: two distinct writes never collide on a high-resolution-mtime local volume
/// (APFS/HFS+ record nanosecond `st_mtimespec`), so an echo of FEdit's own write compares equal to
/// the captured baseline while a genuine external change compares unequal. A stateless value
/// compared per event, rather than a boolean "self-write in progress" flag — an atomic save emits
/// several coalesced vnode events with no clean point at which to clear a flag.
///
/// Coarse-mtime volumes (SMB/NFS/FAT/exFAT, ~1–2 s granularity) are an accepted v1 limitation: a
/// same-size in-place external write landing within one mtime tick of FEdit's own write yields an
/// identical signature and is read as an echo (SPEC §11 is last-writer-wins with no cross-writer
/// coordination; the timing criteria are scoped to local volumes).
struct FileSignature: Equatable {
    let inode: UInt64
    let size: Int64
    let mtimeSec: Int64
    let mtimeNsec: Int64

    /// `stat(2)`s the symlink-resolved path — resolving internally so it can never disagree with
    /// `saveOpenFile()`'s `resolvingSymlinksInPath()` write target or the watcher's resolved watch
    /// path. Returns `nil` when the file is currently absent (external delete, or mid-rename), which
    /// `WorkspaceModel` reads as "gone, retain the buffer".
    static func of(_ url: URL) -> FileSignature? {
        let path = url.resolvingSymlinksInPath().path
        var info = stat()
        guard path.withCString({ stat($0, &info) }) == 0 else { return nil }
        return FileSignature(
            inode: UInt64(info.st_ino),
            size: Int64(info.st_size),
            mtimeSec: Int64(info.st_mtimespec.tv_sec),
            mtimeNsec: Int64(info.st_mtimespec.tv_nsec)
        )
    }
}

/// A single-file `DispatchSourceFileSystemObject` (vnode) watcher for the one open file
/// (external-change-watch, Tier 1). Fires a coalesced `onChange` — **on the main queue** — whenever
/// the watched path changes on disk, and re-arms itself onto the new inode after an atomic save
/// (temp-file + `rename`) so a second external save is detected too, not just the first.
///
/// All mutable *watcher* state (`source`, `watchedPath`, `pendingFlush`, `pendingRearm`,
/// `needsRearm`) is confined to one private serial queue; `watch`/`stop` are called from the main
/// actor and immediately hop onto it, so there is a single serialization domain — which is what
/// justifies `@unchecked Sendable`. The one exception, `isActive`, is deliberately **not** part of
/// that confined state: it is a separate main-owned flag (below).
final class FileWatcher: @unchecked Sendable {
    /// Invoked on the **main queue** (this wrapper does the hop), so the consumer may perform
    /// `@MainActor` model mutation / editor reload directly.
    private let onChange: @Sendable () -> Void

    private let queue = DispatchQueue(label: "com.fedit.filewatcher")

    // MARK: Queue-confined state (touched only on `queue`)

    private var source: DispatchSourceFileSystemObject?
    private var watchedPath: String?
    private var pendingFlush: DispatchWorkItem?
    private var pendingRearm: DispatchWorkItem?
    private var needsRearm = false

    // MARK: Main-owned state

    /// The dormant-check flag read by `WorkspaceModel.saveOpenFile` on the `@MainActor`. It is
    /// **not** a cross-queue read of the confined state above: it is written only on the main queue
    /// (via `setActive`, a `.main` hop) and read only on the main actor, so both sides share the
    /// main queue's single serialization domain. `@unchecked Sendable`'s confinement argument covers
    /// exactly the queue-confined fields and excludes this one by construction.
    private(set) var isActive = false

    private static let eventMask: DispatchSource.FileSystemEvent = [.write, .extend, .delete, .rename, .revoke, .link]
    /// One atomic save fires a `delete`+`rename`+`write` burst; this debounce collapses it to a
    /// single flush.
    private static let debounceInterval: DispatchTimeInterval = .milliseconds(150)
    /// A delete-then-create writer can leave the path momentarily absent; ride out that window on
    /// `ENOENT` (a true atomic `rename` never hits it and re-opens first try).
    private static let rearmAttempts = 5
    private static let rearmRetryInterval: DispatchTimeInterval = .milliseconds(50)

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    deinit {
        // No concurrent access at deinit (last reference is gone). Cancel the source so its
        // cancel handler `close()`s the fd, and drop any scheduled work.
        source?.cancel()
        pendingFlush?.cancel()
        pendingRearm?.cancel()
    }

    /// (Re)points the watcher at `url`'s symlink-resolved target inode — matching the write path's
    /// `resolvingSymlinksInPath()`, so watcher and writer track the same inode.
    func watch(_ url: URL) {
        let path = url.resolvingSymlinksInPath().path
        queue.async { [weak self] in self?.startWatching(path) }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFlush?.cancel(); self.pendingFlush = nil
            self.pendingRearm?.cancel(); self.pendingRearm = nil
            self.cancelSource()
            self.needsRearm = false
            self.watchedPath = nil
            self.setActive(false)
        }
    }

    // MARK: - Queue-confined implementation

    private func startWatching(_ path: String) {
        pendingFlush?.cancel(); pendingFlush = nil
        pendingRearm?.cancel(); pendingRearm = nil
        cancelSource()
        needsRearm = false
        watchedPath = path
        openAndArm(path)
    }

    /// Cancels the current source; the fd is `close()`d **only** in the source's cancel handler
    /// (never eagerly), so a re-used fd number can never race a still-open descriptor.
    private func cancelSource() {
        source?.cancel()
        source = nil
    }

    private func openAndArm(_ path: String) {
        // `O_EVTONLY` (no `O_NOFOLLOW`) follows a symlinked open file through to its target inode,
        // matching the write target.
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { setActive(false); return }
        armSource(fd: fd)
        setActive(true)
    }

    private func armSource(fd: Int32) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: Self.eventMask, queue: queue
        )
        src.setEventHandler { [weak self] in self?.handleEvent() }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
    }

    private func handleEvent() {
        guard let source else { return }
        let data = source.data
        // A delete/rename/revoke unlinks the watched inode — the fd must be re-armed onto the new
        // path. A plain write/extend/link does not.
        if !data.intersection([.delete, .rename, .revoke]).isEmpty {
            needsRearm = true
        }
        scheduleFlush()
    }

    private func scheduleFlush() {
        pendingFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flush() }
        pendingFlush = work
        queue.asyncAfter(deadline: .now() + Self.debounceInterval, execute: work)
    }

    private func flush() {
        pendingFlush = nil
        if needsRearm {
            needsRearm = false
            cancelSource()
            attemptReopen(attemptsRemaining: Self.rearmAttempts)
        } else {
            fireOnChange()
        }
    }

    /// Re-opens the watched path after an unlink, retrying on transient `ENOENT`. Fires `onChange`
    /// exactly once per flush — after the re-arm settles (success or final give-up) — so the reload
    /// consumer sees a stable watcher state. On ultimate failure the watcher is left dormant;
    /// `WorkspaceModel` re-establishes it on the next `saveOpenFile()` / file open.
    private func attemptReopen(attemptsRemaining: Int) {
        pendingRearm = nil
        guard let path = watchedPath else { setActive(false); return }

        let fd = open(path, O_EVTONLY)
        if fd >= 0 {
            armSource(fd: fd)
            setActive(true)
            fireOnChange()
            return
        }

        let err = errno
        if err == ENOENT && attemptsRemaining > 1 {
            let work = DispatchWorkItem { [weak self] in
                self?.attemptReopen(attemptsRemaining: attemptsRemaining - 1)
            }
            pendingRearm = work
            queue.asyncAfter(deadline: .now() + Self.rearmRetryInterval, execute: work)
        } else {
            setActive(false)
            fireOnChange()
        }
    }

    private func fireOnChange() {
        let callback = onChange
        DispatchQueue.main.async { callback() }
    }

    /// Mirrors the arm/disarm state into the main-owned `isActive` on a `.main` hop, preserving the
    /// serial queue's ordering into the main queue (so a `stop` after a `watch` can never leave a
    /// stale `true`).
    private func setActive(_ value: Bool) {
        DispatchQueue.main.async { [weak self] in self?.isActive = value }
    }
}
