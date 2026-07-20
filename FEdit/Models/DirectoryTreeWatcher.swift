//
//  DirectoryTreeWatcher.swift
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

import CoreServices
import Foundation

/// A recursive directory-tree watcher for the sidebar roots (external-change-watch, Tier 3), built
/// on **FSEvents** rather than vnode `DispatchSource`. A vnode source watches a single fd (one
/// directory); recursive coverage would need one open fd per directory across the whole tree and
/// exhaust `RLIMIT_NOFILE` on a large repo. FSEvents is macOS's purpose-built cheap recursive path
/// watcher: one kernel stream per set of roots, latency-batched. Unsandboxed (SPEC §2), plain paths
/// need no entitlement. (The open *file* stays on the precise/immediate vnode `FileWatcher`; the
/// *tree* — existence/structure — uses this.)
///
/// The `onChange` callback carries the **batch of changed paths** so the consumer can gate on them
/// (FSEvents has no built-in self-write suppression), and is delivered on the **main queue**.
///
/// The C callback cannot capture context, so it trampolines through a `WeakBox` handed to the stream
/// as its `info` pointer. The box holds a *weak* reference to the watcher, so the stream ↔ watcher
/// relationship carries no retain cycle and the watcher deallocates normally; the box (owned as a
/// stored property) outlives the stream teardown in `deinit`, and a callback racing that teardown
/// safely reads `nil` for the weak watcher. This is what justifies `@unchecked Sendable`: the
/// FSEvents stream is confined to the private serial queue, and `watch`/`stop` hop onto it.
final class DirectoryTreeWatcher: @unchecked Sendable {
    private final class WeakBox {
        weak var watcher: DirectoryTreeWatcher?
    }

    /// Delivered on the **main queue** with the batch of changed paths.
    private let onChange: @Sendable ([String]) -> Void

    private let queue = DispatchQueue(label: "com.fedit.directorytreewatcher")

    /// Kept alive as a stored property so the `info` pointer (passed unretained) stays valid for the
    /// stream's whole life; released only after `deinit`'s teardown, together with everything else.
    private let box = WeakBox()

    /// Queue-confined (and read once in `deinit`, where there is no concurrent access).
    private var stream: FSEventStreamRef?

    /// FSEvents' own coalescing latency — a burst of many creates collapses into a single callback.
    private static let latency: CFTimeInterval = 0.3

    /// The bare C trampoline: recover the watcher from the `info` box (weak — a `nil` watcher means
    /// this raced a teardown and is a safe no-op) and hand it the changed paths. `kFSEventStreamCreateFlagUseCFTypes`
    /// makes `eventPaths` a `CFArray` of `CFString`, bridged here to `[String]`.
    private static let callback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
        guard let clientInfo else { return }
        let box = Unmanaged<WeakBox>.fromOpaque(clientInfo).takeUnretainedValue()
        let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
        box.watcher?.handleEvents(paths)
    }

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
        box.watcher = self
    }

    deinit {
        // No concurrent access at deinit (last reference is gone). Tear the stream down in the
        // documented order; a callback racing this reads a `nil` weak watcher and no-ops.
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// (Re)creates the stream for `roots`' symlink-resolved paths. Called from the two sites where
    /// the *set* of roots changes (`addFolders`/`removeRoot`); `refreshAll` re-scans in place and
    /// does not re-point. An empty `roots` tears the stream down (watching nothing).
    func watch(roots: [URL]) {
        let paths = roots.map { $0.resolvingSymlinksInPath().path }
        queue.async { [weak self] in self?.restart(paths) }
    }

    func stop() {
        queue.async { [weak self] in self?.teardown() }
    }

    // MARK: - Queue-confined implementation

    private func restart(_ paths: [String]) {
        teardown()
        guard !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        // `kFSEventStreamEventIdSinceNow` so a fresh watch — including the one `addFolders` issues
        // during session-restore — does not replay the volume's historical events (which would
        // trigger a spurious full rescan on every launch).
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Runs on the FSEvents dispatch queue (this watcher's private `queue`); hops the batch to the
    /// main queue for the `@MainActor` consumer's skip gate.
    private func handleEvents(_ paths: [String]) {
        let callback = onChange
        DispatchQueue.main.async { callback(paths) }
    }
}
