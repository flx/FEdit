//
//  FileNode.swift
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

/// A single entry in the folder sidebar's directory tree (SPEC §5.2–§5.3). Value type so a tree
/// built off the main thread on `WorkspaceModel`'s scan queue can be handed back to the main actor
/// **by value** and straight to `OutlineGroup` (async-root-scan).
///
/// The `Sendable` conformance is load-bearing, not decoration: every stored property is a value
/// type with no reference payload and no lazily-populated cache, and that is the *only* reason the
/// cross-thread hand-back needs no deep copy or lock. Adding a class-typed field or a mutable cache
/// here would turn that hand-back into a data race — one Swift 5's minimal concurrency checking
/// does **not** diagnose, so the failure mode would be a silent intermittent crash. Re-check this
/// whenever a property is added.
struct FileNode: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// Non-nil (possibly empty) for directories, `nil` for files — this optionality is
    /// deliberate: it is exactly what `OutlineGroup`/`DisclosureGroup` use to tell leaves from
    /// expandable nodes. Do not "simplify" this to a non-optional array.
    var children: [FileNode]?

    var id: URL { url }

    /// Directory names skipped everywhere in the scan, regardless of depth (SPEC §5.2). Dotfile
    /// skipping already covers `.build`, but it is listed explicitly per spec.
    static let skippedDirectoryNames: Set<String> = ["node_modules", ".build", "DerivedData"]

    /// Recursively scans `directory` into a `FileNode` tree.
    ///
    /// **Threading contract (async-root-scan).** This is `nonisolated` and *pure with respect to app
    /// state*: it reads the filesystem and returns a fresh value, holds no reference to
    /// `WorkspaceModel`, and so can neither observe nor mutate main-actor state — a walk in flight
    /// owns a private local tree that no other thread can see until it is handed back. It is still
    /// **synchronous within its own thread**, and a blocking one (`contentsOfDirectory` is a
    /// syscall; a home-scale root measured ~135 s), so the app target calls it from exactly one
    /// place — `WorkspaceModel.requestScan(of:force:damped:)`, on `WorkspaceModel.scanQueue`. Never
    /// call it on the main actor; SPEC §11 no longer accepts a main-thread walk.
    ///
    /// This no-argument entry point is deliberately behavior-identical to the pre-async scanner and
    /// is what `scripts/FileNodeTests` pins; the cancellable overload below is purely additive (a
    /// `nil` token makes it this function).
    static func scan(directory: URL) -> FileNode {
        scan(directory: directory, cancellation: nil)
    }

    /// (async-root-scan, Tier 2) `scan(directory:)` plus cooperative cancellation: the walk checks
    /// `cancellation` once per directory entry and unwinds early when it is set, so removing a
    /// home-scale root does not leave a scan-queue thread walking it for minutes. A cancelled walk
    /// returns a **partial** tree — by contract the caller must discard it (`WorkspaceModel` does,
    /// via the root's scan generation), never publish it.
    static func scan(directory: URL, cancellation: ScanCancellationToken?) -> FileNode {
        let standardized = directory.standardizedFileURL
        let children = scanChildren(of: standardized, cancellation: cancellation)
        return FileNode(url: standardized, name: standardized.lastPathComponent, isDirectory: true, children: children)
    }

    private static func scanChildren(of directory: URL, cancellation: ScanCancellationToken?) -> [FileNode] {
        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            // Unreadable directory (permissions, disappeared mid-scan, etc.) — show as empty
            // rather than crashing or propagating the error (SPEC §11).
            return []
        }

        var nodes: [FileNode] = []
        nodes.reserveCapacity(entries.count)

        for entryURL in entries {
            // (async-root-scan, Tier 2) One lock-guarded flag read per entry — cheap beside the
            // `resourceValues` syscall a few lines down. Unwinding with `break` (not by returning
            // `[]`) keeps the function total: the partial listing is well-formed, and the caller
            // discards it anyway.
            if cancellation?.isCancelled == true { break }

            let standardizedEntry = entryURL.standardizedFileURL
            let name = standardizedEntry.lastPathComponent

            let resourceValues = try? standardizedEntry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let isSymbolicLink = resourceValues?.isSymbolicLink ?? false
            // Symbolic links are treated as leaf files (no recursion) to avoid link cycles.
            let isDirectory = !isSymbolicLink && (resourceValues?.isDirectory ?? false)

            if (isDirectory || isSymbolicLink) && skippedDirectoryNames.contains(name) {
                continue
            }

            if isDirectory {
                nodes.append(FileNode(url: standardizedEntry, name: name, isDirectory: true, children: scanChildren(of: standardizedEntry, cancellation: cancellation)))
            } else {
                nodes.append(FileNode(url: standardizedEntry, name: name, isDirectory: false, children: nil))
            }
        }

        return sorted(nodes)
    }

    /// Directories first, then files; each subgroup sorted with `localizedStandardCompare`
    /// (SPEC §5.2), e.g. `file2` before `file10`.
    private static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        let directories = nodes.filter { $0.isDirectory }
        let files = nodes.filter { !$0.isDirectory }
        let byName: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return directories.sorted(by: byName) + files.sorted(by: byName)
    }

    /// Every file under `self`, paired with its path relative to `self` — `self`'s own name is
    /// excluded from every path (callable directly on a root: yields `swift-source/main.swift`,
    /// never `FEdit/swift-source/main.swift`; a root-name leak would corrupt filter matching,
    /// e.g. a query for "fedit" matching every file under a root named FEdit). Depth-first order
    /// preserves the scanner's folders-first sort (filter-query §5.4).
    func filesWithRelativePaths() -> [(path: String, node: FileNode)] {
        var results: [(path: String, node: FileNode)] = []
        for child in children ?? [] {
            child.collect(prefix: "", into: &results)
        }
        return results
    }

    private func collect(prefix: String, into results: inout [(path: String, node: FileNode)]) {
        if isDirectory {
            for child in children ?? [] {
                child.collect(prefix: prefix + name + "/", into: &results)
            }
        } else {
            results.append((prefix + name, self))
        }
    }
}

/// (async-root-scan, Tier 2) The **only** cross-thread mutable state the asynchronous scan
/// introduces: a one-way "stop walking" flag, set on the main actor (`WorkspaceModel.removeRoot`
/// and `deinit`) and read on the scan queue once per directory entry.
///
/// `NSLock` rather than `os_unfair_lock`/`Synchronization`'s `Atomic` for one concrete reason:
/// `FileNode.swift` must keep compiling against **Foundation alone**, because
/// `scripts/FileNodeTests` builds it standalone with `swiftc`. One-way by construction — there is
/// no `uncancel()` — so a walk can never observe cancellation un-happening mid-unwind, and the flag
/// needs no generation of its own (`WorkspaceModel` allocates a fresh token per job).
final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
