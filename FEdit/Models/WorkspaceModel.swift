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

/// Per-window state for the folder sidebar (SPEC §5, §10) and the open document (SPEC §7). One
/// instance lives per window (SPEC §3) and is exposed to `Commands` via `.focusedSceneObject` so
/// File → Open Folder…/Save always target the focused window.
@MainActor
final class WorkspaceModel: ObservableObject {
    /// The single file open in this window's editor (SPEC §6.1: exactly one file at a time), or
    /// `nil` when nothing is open.
    struct OpenFile {
        let url: URL
        var text: String
        var isDirty: Bool
    }

    /// A read failure that isn't a generic I/O error — kept distinct so `requestOpen` can pick
    /// the "appears to be binary" wording (criterion 3) instead of a generic read-error one.
    private enum FileLoadError: Error {
        case binaryFile
        case notRegularFile
        case tooLarge
    }

    /// Cap on readable file size (100 MB), guarding against hangs/OOM from clicking a sidebar row
    /// that isn't an ordinary bounded text file (see `loadText(from:)`).
    private static let maxReadableFileSize = 100 * 1024 * 1024

    /// Outcome of `resolveDirtyFile()` (SPEC §7): whether the caller (a file switch, window
    /// close, or app quit) may proceed, or must stop where it is.
    enum DirtyResolution {
        case proceed
        case cancel
    }

    @Published private(set) var roots: [FileNode] = []

    /// Record-only until requestOpen. Writing this property has **zero side effects at the model
    /// layer** — no `didSet` — by design: the selection→load hook used to live in ContentView's
    /// `.onChange(of:)` (editor-core); it is now `requestOpen`, called directly from the sidebar
    /// row action. This stays a plain record, load-bearing for (open-save)'s Cancel-revert (a
    /// model-side reload here would silently destroy a dirty buffer).
    @Published var selectedFileURL: URL? = nil

    /// The sidebar's filter query text (SPEC §5.4–§5.5). Lives on the per-window model rather
    /// than view `@State` because SPEC §9 persists filter text per window, and (session-restore)
    /// snapshots from `WorkspaceModel` — parking it here now avoids a later move.
    @Published var filterText: String = ""

    /// The file currently loaded into the editor, or `nil` if none (SPEC §6.1, §7).
    @Published var openFile: OpenFile?

    /// The editor's last-reported caret offset (UTF-16, `NSRange.location`), sunk here by
    /// (session-restore) via `noteCursorMoved(_:)`. Drives `snapshotJSON()`'s `cursorLocation`.
    @Published private(set) var cursorLocation: Int = 0

    /// One-shot cursor value for (session-restore)'s consumer, `CodeEditorView`'s
    /// `cursorToRestore` parameter — stashed by `restore(fromJSON:)`, cleared by the next
    /// `noteCursorMoved(_:)` call (the editor's restore-consume reports back through the cursor
    /// callback, which fires `noteCursorMoved` and clears this).
    private(set) var pendingCursorRestore: Int?

    /// Real language stub (SPEC §6.3's full enum arrives with (syntax-highlighting)): `true` for
    /// a `.md`/`.markdown` extension (case-insensitive), driving the preview column's visibility
    /// (SPEC §8).
    var isMarkdown: Bool {
        guard let url = openFile?.url else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// The open file's display name for the window title, or `nil` when nothing is open.
    var openFileName: String? {
        openFile?.url.lastPathComponent
    }

    /// Whether File → Save should be enabled (SPEC §10): a file is open and has unsaved edits.
    var canSave: Bool {
        openFile?.isDirty == true
    }

    /// The editor's full text buffer (SPEC §6.1), backed by `openFile`. The setter only marks
    /// the file dirty when the value actually changed, so programmatic loads — which replace
    /// `openFile` wholesale — never go through here and never mark a freshly opened file dirty.
    var editorText: String {
        get { openFile?.text ?? "" }
        set {
            guard var file = openFile, file.text != newValue else { return }
            file.text = newValue
            file.isDirty = true
            openFile = file
        }
    }

    /// Sink for `CodeEditorView`'s `onCursorChange` callback (editor-core), including the
    /// synthetic report the coordinator fires right after consuming a restored cursor. Updates
    /// `cursorLocation` for the next snapshot, and clears `pendingCursorRestore` the first time
    /// this fires after a restore — the editor's one-shot restore-consume reports back through
    /// this same callback, so by the time it does, the seam has been used and must not be
    /// re-applied on a later document switch.
    func noteCursorMoved(_ location: Int) {
        cursorLocation = location
        pendingCursorRestore = nil
    }

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

    /// Reads `url`'s contents as text (SPEC §7): NUL bytes anywhere in the data mean the file is
    /// treated as binary and refused; otherwise UTF-8 is tried first, then Latin-1. `.isoLatin1`
    /// decoding of arbitrary bytes always succeeds, so the fallback is total for non-binary data.
    ///
    /// Before touching disk, stats `url` and refuses anything that isn't a bounded regular file:
    /// a sidebar row can point at a FIFO, socket, or device node (an unbounded `read()` on those
    /// can hang forever) or a multi-gigabyte file (which would exhaust memory), neither of which
    /// `Data(contentsOf:)` guards against on its own.
    private func loadText(from url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw FileLoadError.notRegularFile
        }
        if let fileSize = values.fileSize, fileSize > Self.maxReadableFileSize {
            throw FileLoadError.tooLarge
        }

        let data = try Data(contentsOf: url)

        guard !data.contains(0) else {
            throw FileLoadError.binaryFile
        }

        if let utf8Text = String(data: data, encoding: .utf8) {
            return utf8Text
        }

        return String(data: data, encoding: .isoLatin1)!
    }

    /// Shared success-path assignment for both `loadFile` (interactive open) and
    /// (session-restore)'s silent restore-open: replaces `openFile` with a clean (non-dirty)
    /// buffer and syncs `selectedFileURL` to `url`. Factored out so the two routes' success
    /// behavior can never drift apart.
    private func applyLoadedFile(url: URL, text: String) {
        openFile = OpenFile(url: url, text: text, isDirty: false)
        selectedFileURL = url
    }

    /// Loads `url` into the editor unconditionally — no dirty check, no no-op-on-already-open
    /// guard; both live in `requestOpen`, the only public entry point for a sidebar selection.
    /// On success: assigns via `applyLoadedFile`. On failure: alerts (binary-refusal wording vs.
    /// a generic read-error wording) and reverts `selectedFileURL` back to whatever was already
    /// open, so the sidebar highlight doesn't follow a selection that failed to load
    /// (criterion 3).
    private func loadFile(_ url: URL) {
        do {
            let text = try loadText(from: url)
            applyLoadedFile(url: url, text: text)
        } catch {
            presentReadErrorAlert(for: url, error: error)
            selectedFileURL = openFile?.url
        }
    }

    /// (session-restore)'s silent, non-interactive counterpart to `loadFile`: reuses the same
    /// `loadText(from:)` core and the same success assignment (`applyLoadedFile`), but on
    /// failure swallows the error with no alert and no `selectedFileURL` revert — SPEC §9's "a
    /// missing file is simply not opened". Never routes through `requestOpen` (no dirty check,
    /// no dialog) — restore only ever runs against a pristine, freshly created model.
    private func silentlyLoadFile(_ url: URL) {
        guard let text = try? loadText(from: url) else { return }
        applyLoadedFile(url: url, text: text)
    }

    /// The sidebar's single entry point for opening a file (both tree rows and filter-query's
    /// flat filtered rows share `FileRow`'s tap action, so both route through here — criterion
    /// 9a). No-op if `url` is already the open file (criterion 18: re-clicking the open file's
    /// own row never reloads or resets the caret). Otherwise runs `resolveDirtyFile()` first:
    /// `.proceed` loads `url`; `.cancel` reverts the published selection back to the file that's
    /// still open — because writing `selectedFileURL` has zero side effects (see its doc
    /// comment), this only moves the sidebar highlight and cannot itself trigger another load.
    func requestOpen(_ url: URL) {
        guard url != openFile?.url else { return }

        switch resolveDirtyFile() {
        case .proceed:
            loadFile(url)
        case .cancel:
            selectedFileURL = openFile?.url
        }
    }

    /// Shared dirty-file guard (SPEC §7): runs before a file switch, and reused verbatim by
    /// `windowShouldClose`/`applicationShouldTerminate` (Tier 4) since it is synchronous and
    /// already app-modal. Clean or no open file needs no confirmation. Autosave ON saves
    /// silently — a failed save aborts (criterion 15). Autosave OFF shows the app-modal
    /// four-button dialog (criterion 9); Cancel gets Escape automatically from being the last
    /// button added with a default-looking title.
    ///
    /// **Dialog order (accepted for v1):** this runs before the target file's readability is
    /// known, so choosing Save and then hitting a binary/unreadable target means a "wasted" save
    /// followed by the refusal alert — accepted, not fixed, per the plan's recorded decision.
    func resolveDirtyFile() -> DirtyResolution {
        guard openFile?.isDirty == true else { return .proceed }

        if autosaveOnFileSwitch {
            return saveOpenFile() ? .proceed : .cancel
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to '\(openFile?.url.lastPathComponent ?? "")'?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Always Autosave")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveOpenFile() ? .proceed : .cancel
        case .alertSecondButtonReturn:
            autosaveOnFileSwitch = true
            return saveOpenFile() ? .proceed : .cancel
        case .alertThirdButtonReturn:
            return .proceed
        default:
            return .cancel
        }
    }

    private func presentReadErrorAlert(for url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot Open File"
        switch error {
        case FileLoadError.binaryFile:
            alert.informativeText = "\"\(url.lastPathComponent)\" appears to be binary and cannot be opened as text."
        case FileLoadError.notRegularFile:
            alert.informativeText = "\"\(url.lastPathComponent)\" is not a readable text file."
        case FileLoadError.tooLarge:
            alert.informativeText = "\"\(url.lastPathComponent)\" is too large to open (over 100 MB)."
        default:
            alert.informativeText = "\"\(url.lastPathComponent)\" could not be read: \(error.localizedDescription)"
        }
        alert.runModal()
    }

    /// Writes the open file's text to disk atomically (SPEC §7: Cmd+S). Recreating a file that
    /// was deleted out from under the app needs no special handling — an atomic write to a path
    /// with nothing there just (re)creates it. On success clears `isDirty`; on failure alerts
    /// with the underlying error and leaves the file dirty. `false` means "still dirty" for
    /// callers that need to abort a switch/close/quit on a failed save.
    @discardableResult
    func saveOpenFile() -> Bool {
        guard var file = openFile else { return false }

        do {
            // `Data(String.utf8)` is a direct byte copy of the string's own UTF-8 storage — it
            // cannot fail the way `String.data(using:)`'s optional-returning API can. Atomic
            // write replaces whatever is at the destination path with a new regular file, so
            // writing to `file.url` directly would replace a symlink with a plain file instead
            // of updating its target; resolving symlinks first writes through to the real path.
            try Data(file.text.utf8).write(to: file.url.resolvingSymlinksInPath(), options: .atomic)
            file.isDirty = false
            openFile = file
            return true
        } catch {
            presentSaveErrorAlert(for: file.url, error: error)
            return false
        }
    }

    private func presentSaveErrorAlert(for url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot Save File"
        alert.informativeText = "\"\(url.lastPathComponent)\" could not be saved: \(error.localizedDescription)"
        alert.runModal()
    }

    /// Global autosave-on-file-switch setting (SPEC §7, §9): shared with the File menu's
    /// `@AppStorage` toggle via the same `UserDefaults` key, so either side flipping it is
    /// immediately visible to the other.
    var autosaveOnFileSwitch: Bool {
        get { UserDefaults.standard.bool(forKey: SettingsKey.autosaveOnFileSwitch) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.autosaveOnFileSwitch) }
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

    // MARK: - Session restore (SPEC §3, §9)

    /// Builds the current per-window state as `WorkspaceSnapshot` JSON for `@SceneStorage`
    /// (ContentView, Tier 2). Returns `nil` — never `""` — on encode failure, so the caller skips
    /// the write and keeps whatever snapshot is already stored; an empty write would erase a
    /// valid one.
    func snapshotJSON() -> String? {
        let snapshot = WorkspaceSnapshot(
            rootPaths: roots.map { $0.url.path },
            openFilePath: openFile?.url.path,
            filterText: filterText,
            cursorLocation: cursorLocation
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(snapshot),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Restores this window's state from a `WorkspaceSnapshot` JSON string (ContentView, Tier 2's
    /// `.onAppear`/late-arriving-`@SceneStorage` recovery). A no-op if the model already has
    /// roots or an open file — only a pristine, freshly created scene restores, which also means
    /// this never has to contend with an in-progress dirty-file guard. Silent throughout: no
    /// dialogs, no alerts (SPEC §7/§9) — a missing folder is dropped, a missing/unreadable file is
    /// simply not opened, and empty/corrupt JSON leaves the model exactly as it was (an empty
    /// pristine window). Runs synchronously on the main thread (SPEC §11: root rescans + one file
    /// read at launch is acceptable).
    func restore(fromJSON json: String) {
        guard roots.isEmpty, openFile == nil else { return }
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else { return }

        // `addFolders` already validates each path with `fileExists(atPath:isDirectory:)` and
        // skips anything that isn't an existing directory, so a deleted root is dropped silently
        // here for free (SPEC §9: "missing folder dropped silently") — no separate filter needed.
        addFolders(snapshot.rootPaths.map { URL(fileURLWithPath: $0) })

        filterText = snapshot.filterText

        if let openFilePath = snapshot.openFilePath {
            silentlyLoadFile(URL(fileURLWithPath: openFilePath))
        }

        // Written to both `pendingCursorRestore` (Tier 2's editor consumes it) and
        // `cursorLocation` directly (criterion 12): if only the stash were set, the immediate
        // post-restore snapshot save — which reads `cursorLocation`, not the pending stash —
        // would clobber the stored cursor with the model's default `0` before the editor ever
        // gets a chance to apply and report it back through `noteCursorMoved`. Gated on `openFile
        // != nil` — when the restored file didn't actually open, no editor mounts to consume and
        // clear `pendingCursorRestore`, so it would otherwise leak onto the next file the user
        // opens and snap its caret to this stale offset.
        if openFile != nil, let cursorLocation = snapshot.cursorLocation {
            pendingCursorRestore = cursorLocation
            self.cursorLocation = cursorLocation
        }
    }
}
