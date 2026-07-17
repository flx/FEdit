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

    /// Record-only until (open-save) wires this up to actually opening the file. Writing this
    /// property has **zero side effects at the model layer** — no `didSet` — by design: the
    /// selection→load hook lives in `ContentView`'s `.onChange(of:)`, so this stays a plain
    /// record load-bearing for (open-save)'s Cancel-revert (a model-side reload here would
    /// silently destroy a dirty buffer).
    @Published var selectedFileURL: URL? = nil

    /// The sidebar's filter query text (SPEC §5.4–§5.5). Lives on the per-window model rather
    /// than view `@State` because SPEC §9 persists filter text per window, and (session-restore)
    /// snapshots from `WorkspaceModel` — parking it here now avoids a later move.
    @Published var filterText: String = ""

    /// The file currently loaded into the editor (SPEC §6.1: exactly one file open at a time).
    /// Interim state — (open-save) replaces this with its full open-file model.
    @Published var openFileURL: URL?

    /// The editor's full text buffer, bound directly to `CodeEditorView`. Interim — (open-save)
    /// supersedes this with dirty tracking and the real open/save pipeline.
    @Published var editorText: String = ""

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

    /// Loads `url` into the editor (interim state — (open-save) supersedes this with the full
    /// open/save pipeline, including binary/NUL detection and read-error alerts per SPEC §7/§11).
    /// No-op if `url` is already the open file, so clicking the already-open file's sidebar row
    /// never reloads or resets the editor's caret/scroll. Tries UTF-8 first, then falls back to
    /// Latin-1; an unreadable file leaves `openFileURL`/`editorText` unchanged (no alert yet).
    func loadSelectedFile(_ url: URL) {
        guard url != openFileURL else { return }

        if let contents = try? String(contentsOf: url, encoding: .utf8) {
            openFileURL = url
            editorText = contents
        } else if let contents = try? String(contentsOf: url, encoding: .isoLatin1) {
            openFileURL = url
            editorText = contents
        }
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
