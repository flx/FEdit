//
//  WorkspaceModel.swift
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

import AppKit
import SwiftUI

/// Per-window state for the folder sidebar (SPEC §5, §10). One instance lives per window
/// (SPEC §3) and is exposed to `Commands` via `.focusedSceneObject` so File → Open Folder…
/// always targets the focused window.
@MainActor
final class WorkspaceModel: ObservableObject {
    @Published private(set) var roots: [FileNode] = []

    /// Record-only until (open-save) wires this up to actually opening the file.
    @Published var selectedFileURL: URL? = nil

    /// Adds each URL as a top-level root, standardizing it and skipping ones already present.
    /// Duplicate comparison resolves symlinks first (`/tmp` vs `/private/tmp` count as the same
    /// root) so it catches more than a plain standardized-path comparison would.
    func addFolders(_ urls: [URL]) {
        var existingResolvedPaths = Set(roots.map { $0.url.resolvingSymlinksInPath().path })

        for url in urls {
            let standardized = url.standardizedFileURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let resolvedPath = standardized.resolvingSymlinksInPath().path
            guard !existingResolvedPaths.contains(resolvedPath) else { continue }
            existingResolvedPaths.insert(resolvedPath)
            roots.append(FileNode.scan(directory: standardized))
        }
    }

    /// Removes `root` from the sidebar. Disk untouched. Clears `selectedFileURL` if it points
    /// inside the removed root, so a later (open-save) doesn't hold a selection to a folder that
    /// is no longer shown.
    func removeRoot(_ root: FileNode) {
        roots.removeAll { $0.id == root.id }
        if let selectedFileURL,
           selectedFileURL.path == root.url.path || selectedFileURL.path.hasPrefix(root.url.path + "/") {
            self.selectedFileURL = nil
        }
    }

    /// Rescans every root in place (SPEC §5.1: Refresh rescans all folders).
    func refreshAll() {
        roots = roots.map { FileNode.scan(directory: $0.url) }
    }

    /// Presents an `NSOpenPanel` restricted to directories, multi-select enabled, and adds the
    /// chosen URLs as roots on OK.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            addFolders(panel.urls)
        }
    }
}
