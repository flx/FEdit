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
/// File → Add Folder to Window…/Save always target the focused window. (Open Folder…/Cmd+N is
/// app-level — it opens a new window — and is not focused-window-scoped.)
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

    /// Autosave debounce interval (SPEC §7): the open file is written this long after the last
    /// keystroke. Within the plan's 0.5–1 s band — short enough that the on-disk file tracks the
    /// editor within a second, long enough to coalesce a typing burst into a single write.
    private static let autosaveInterval: TimeInterval = 0.75

    /// Outcome of `resolveDirtyFile(context:)` (SPEC §7): whether the caller (a file switch,
    /// window close, or app quit) may proceed, or must stop where it is.
    enum DirtyResolution {
        case proceed
        case cancel
    }

    /// Which boundary is invoking `resolveDirtyFile(context:)`. The flush is identical; only the
    /// **failure** behavior forks: a file switch aborts and preserves the buffer, while a
    /// close/quit offers the minimal "Close Without Saving / Cancel" escape so a persistently
    /// -failing save can never make the app un-quittable.
    enum DirtyContext {
        case fileSwitch
        case closeOrQuit
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

    /// The in-flight debounced autosave write, cancel-and-rescheduled on every edit (mirrors
    /// `CodeEditorView`'s `pendingHighlight` idiom). Nil when nothing is pending. Cancelled by
    /// `cancelPendingAutosave()` on a file switch / explicit save, and its work item re-checks
    /// dirtiness at fire time so a straggler that outlives a switch or reload is a no-op.
    private var pendingAutosave: DispatchWorkItem?

    /// Token for the `NSApplication.didResignActiveNotification` observer that flushes a dirty
    /// buffer the moment the user leaves FEdit (Tier 3), collapsing the leave-app exposure window
    /// to ~0. Removed in `deinit`.
    private var resignActiveObserver: NSObjectProtocol?

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
    /// On a real edit it (re)arms the debounced autosave, so the on-disk file tracks the editor
    /// within `autosaveInterval` of the last keystroke (SPEC §7).
    var editorText: String {
        get { openFile?.text ?? "" }
        set {
            guard var file = openFile, file.text != newValue else { return }
            file.text = newValue
            file.isDirty = true
            openFile = file
            scheduleAutosave()
        }
    }

    init() {
        // Flush a dirty buffer the instant the user leaves FEdit for another app (Tier 3), so an
        // external tool (Terminal, Claude) that then edits the same file starts from the editor's
        // latest text — the leave-app exposure window collapses to ~0. `didResignActiveNotification`
        // is app-wide, so every per-window model observes it and each flushes its own buffer; a
        // clean or unfocused-file buffer is a cheap no-op inside `flushPendingAutosave`. AppKit
        // posts this on the main thread; `assumeIsolated` just states that to the compiler.
        resignActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingAutosave() }
        }
    }

    deinit {
        // No window-scoped model outlives its window, but cancel defensively so a fired-but-not-yet
        // -run debounce can't touch a torn-down model. (`[weak self]` in the work item already
        // guards the closure body; this releases the retained `DispatchWorkItem` too.)
        pendingAutosave?.cancel()
        if let resignActiveObserver {
            NotificationCenter.default.removeObserver(resignActiveObserver)
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
    ///
    /// Cancels any pending autosave **first** (coordination seam): this is the file-switch load
    /// path, so a stale debounced write armed against the previous buffer must never fire and
    /// clobber the file being loaded here. (External reloads do **not** route through this — they
    /// re-arm the watcher — so (external-change-watch) has its own reload path that likewise calls
    /// `cancelPendingAutosave()` first.)
    private func applyLoadedFile(url: URL, text: String) {
        cancelPendingAutosave()
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
    /// own row never reloads or resets the caret). Otherwise runs `resolveDirtyFile(context:)`
    /// with the `.fileSwitch` context: `.proceed` loads `url`; `.cancel` (a failed autosave flush)
    /// reverts the published selection back to the file that's still open — because writing
    /// `selectedFileURL` has zero side effects (see its doc comment), this only moves the sidebar
    /// highlight and cannot itself trigger another load.
    func requestOpen(_ url: URL) {
        guard url != openFile?.url else { return }

        switch resolveDirtyFile(context: .fileSwitch) {
        case .proceed:
            loadFile(url)
        case .cancel:
            selectedFileURL = openFile?.url
        }
    }

    /// The dirty-file guard (SPEC §7): run before a file switch, and — via the `WindowCloseGuard`
    /// proxy — before a window close or app quit. Synchronous and app-modal, so the close/quit
    /// path reuses it unchanged. Autosave is unconditional now, so this is a **silent flush-and-
    /// check**, not the old four-button prompt: a clean or absent buffer proceeds untouched; a
    /// dirty buffer is flushed through `saveOpenFile`.
    ///
    /// Cancels any pending debounced autosave **first** (D3): the flush writes the buffer
    /// synchronously, so a straggler debounce firing behind whatever the caller does next must not
    /// re-write a buffer a discard/close is about to abandon.
    ///
    /// On a flush **failure** the behavior forks on `context`:
    /// - `.fileSwitch` aborts the switch (`.cancel`); `saveOpenFile` has already shown the "Cannot
    ///   Save File" alert and the caller reverts the sidebar selection — no second dialog.
    /// - `.closeOrQuit` shows the sole surviving unsaved-changes dialog — the minimal two-button
    ///   "Close Without Saving / Cancel" escape — so a persistently-unwritable location (read-only
    ///   dir, full or unmounted volume) can never make the app un-quittable.
    func resolveDirtyFile(context: DirtyContext) -> DirtyResolution {
        guard openFile?.isDirty == true else { return .proceed }

        cancelPendingAutosave()
        // `.fileSwitch` wants the "Cannot Save File" alert on a flush failure (criterion 8);
        // `.closeOrQuit` flushes silently so its sole `presentUnsavedCloseEscape()` dialog is the
        // only modal — SPEC's single-escape-dialog rule.
        let alertOnFail = (context == .fileSwitch)
        if saveOpenFile(alertOnFailure: alertOnFail) {
            return .proceed
        }

        switch context {
        case .fileSwitch:
            return .cancel
        case .closeOrQuit:
            return presentUnsavedCloseEscape()
        }
    }

    /// The sole surviving unsaved-changes dialog — shown only when a **close/quit** flush keeps
    /// failing (`resolveDirtyFile(context: .closeOrQuit)`), never on a plain file switch. Minimal
    /// by design: it exists solely so a persistently-failing save can't make the app un-quittable.
    /// "Cancel" (first, the default) keeps the window open / aborts the quit and owns the Return key;
    /// it also gets the Escape key equivalent automatically from AppKit for its title, so both Return
    /// and Escape resolve to the safe action. "Close Without Saving" (last) discards the unsaved
    /// buffer and proceeds.
    private func presentUnsavedCloseEscape() -> DirtyResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't save '\(openFile?.url.lastPathComponent ?? "")'"
        alert.addButton(withTitle: "Cancel")
        let closeButton = alert.addButton(withTitle: "Close Without Saving")
        closeButton.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertSecondButtonReturn:
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

    /// Debounces an autosave write `autosaveInterval` after the last edit (mirrors
    /// `CodeEditorView.scheduleHighlight`): cancels any already-pending write and reschedules, so a
    /// typing burst coalesces into a single write ~0.75 s after the last keystroke. The work item
    /// re-checks `openFile?.isDirty` **at fire time** (not schedule time), so a straggler that
    /// outlives a file switch, an explicit save, or an (external-change-watch) reload finds a clean
    /// buffer and is a no-op. Saves silently (`alertOnFailure: false`) — a failing autosave in a
    /// read-only location must not throw a modal every tick; the persistent "Edited" subtitle is
    /// the passive signal, and the failure is surfaced at the next explicit save boundary (Cmd+S or
    /// the `resolveDirtyFile` flush). `[weak self]` so a closed window's model is neither kept
    /// alive nor fired.
    private func scheduleAutosave() {
        pendingAutosave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Dispatched to `DispatchQueue.main` below, so this body runs on the main actor;
            // `assumeIsolated` states that to the compiler (matching the resign-active observer and
            // WindowCloseGuardProxy) so the `@MainActor` `openFile`/`saveOpenFile` access is sound.
            MainActor.assumeIsolated {
                guard let self, self.openFile?.isDirty == true else { return }
                self.saveOpenFile(alertOnFailure: false)
            }
        }
        pendingAutosave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveInterval, execute: workItem)
    }

    /// Cancels and clears any pending debounced autosave. **Exposed and required** — part of the
    /// coordination seam: `applyLoadedFile` and `saveOpenFile`'s success branch call it internally
    /// so a stale timer from the previous buffer can never write the current one, and
    /// (external-change-watch) calls it at the top of its own reload path so a straggler autosave
    /// can't clobber a just-applied external reload.
    func cancelPendingAutosave() {
        pendingAutosave?.cancel()
        pendingAutosave = nil
    }

    /// Flushes a dirty buffer immediately, replacing the pending debounce with an eager write —
    /// used when the app resigns active (Tier 3), so leaving FEdit doesn't leave the last edits
    /// exposed for up to `autosaveInterval`. Cancels the debounce first (this write supersedes it),
    /// then writes silently (`alertOnFailure: false`, the same anti-spam rule as the debounce —
    /// resign-active is not an explicit save boundary, so a failure stays passive as "Edited" and
    /// surfaces at the next Cmd+S / switch / close / quit). A clean or absent buffer is a no-op.
    func flushPendingAutosave() {
        cancelPendingAutosave()
        if openFile?.isDirty == true {
            saveOpenFile(alertOnFailure: false)
        }
    }

    /// Writes the open file's text to disk atomically (SPEC §7: Cmd+S, and the always-on autosave
    /// flushes). Recreating a file that was deleted out from under the app needs no special
    /// handling — an atomic write to a path with nothing there just (re)creates it. On success
    /// clears `isDirty`, republishes `openFile`, and cancels any pending debounced write (an
    /// explicit/flush save makes it redundant). On failure alerts **only if `alertOnFailure`**
    /// (the debounced and resign-active autosaves pass `false` to stay silent — see
    /// `scheduleAutosave`) and leaves the file dirty. `false` means "still dirty" for callers that
    /// must abort a switch/close/quit on a failed save. `alertOnFailure` defaults to `true` so
    /// Cmd+S and the `resolveDirtyFile` flush stay source-compatible and always surface a failure.
    @discardableResult
    func saveOpenFile(alertOnFailure: Bool = true) -> Bool {
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
            // The single shared post-write success branch: (external-change-watch) will hang its
            // `FileSignature` echo-suppression capture here when it ships. This item captures
            // nothing — it only cancels the now-redundant pending debounce.
            cancelPendingAutosave()
            return true
        } catch {
            if alertOnFailure {
                presentSaveErrorAlert(for: file.url, error: error)
            }
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

    /// Presents an `NSOpenPanel` restricted to directories, **single-select**, for the "Open
    /// Folder…" (Cmd+N) new-window flow: called only on a pristine (empty-`roots`) model when a
    /// Cmd+N-created window drains the launch mailbox on appear, so `addFolders` yields the chosen
    /// folder as this window's sole root. Cancel is a no-op, leaving the new window empty.
    func presentNewWindowFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

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
