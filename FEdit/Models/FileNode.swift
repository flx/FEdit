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

/// A single entry in the folder sidebar's directory tree (SPEC §5.2–§5.3). Value type so the
/// tree can be scanned synchronously and handed straight to `OutlineGroup`.
struct FileNode: Identifiable {
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

    /// Recursively scans `directory` into a `FileNode` tree. Synchronous on the calling thread
    /// per SPEC §11 — v1 accepts this; the skip list bounds the worst-case cost.
    static func scan(directory: URL) -> FileNode {
        let standardized = directory.standardizedFileURL
        let children = scanChildren(of: standardized)
        return FileNode(url: standardized, name: standardized.lastPathComponent, isDirectory: true, children: children)
    }

    private static func scanChildren(of directory: URL) -> [FileNode] {
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
                nodes.append(FileNode(url: standardizedEntry, name: name, isDirectory: true, children: scanChildren(of: standardizedEntry)))
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
