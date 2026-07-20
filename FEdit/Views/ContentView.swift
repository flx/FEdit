//
//  ContentView.swift
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

import SwiftUI

/// The three-column window skeleton (SPEC §4): sidebar | editor | (optional) markdown
/// preview, separated by two draggable dividers. Columns are placeholders — their real
/// content is delivered by later items ((folder-sidebar), (editor-core), (markdown-preview)).
struct ContentView: View {
    // Persisted globally (shared across all windows, survives relaunch).
    @AppStorage(SettingsKey.sidebarWidth) private var sidebarWidth: Double = LayoutMetrics.defaultSidebarWidth
    @AppStorage(SettingsKey.editorFraction) private var editorFraction: Double = LayoutMetrics.defaultEditorFraction

    // (editor-font-zoom) The single global editor font size (SPEC §6.1 default 13 pt). One
    // `@AppStorage` view onto `SettingsKey.editorFontSize`: the View menu writes it, this reads it
    // (clamped) and passes it down — every open window observes the same key, so a change in one
    // window relays out every other window's editor live.
    @AppStorage(SettingsKey.editorFontSize) private var editorFontSize: Double = EditorMetrics.defaultFontSize

    // Drag baselines: captured on the first callback of a gesture, cleared on drag end. This
    // makes clamping absolute, so dragging past a stop and back does not accumulate drift.
    @State private var sidebarDragBase: Double?
    @State private var fractionDragBase: Double?

    // (markdown-preview) Tier 3: the editor's throttled first-visible-line report (editor-core),
    // driving the preview's one-way scroll sync (SPEC §8.3). Reset to 0 on file switch (see
    // `.onChange(of:)` below) so a stale previous-file line can never drive the new file's
    // preview before its first throttled report arrives.
    @State private var editorFirstVisibleLine = 0

    // One per window (SPEC §3) — holds the open folders and selection for this window.
    @StateObject private var workspace = WorkspaceModel()

    // (session-restore) SPEC §3, §9: this window's persisted state — open folders, open file,
    // filter text, cursor — round-tripped through `WorkspaceModel.snapshotJSON()`/`restore(fromJSON:)`
    // as JSON. `@SceneStorage` keys this per-scene, so each window restores its own snapshot.
    @SceneStorage("workspaceSnapshot") private var workspaceSnapshot: String = ""

    // Guards the `.onAppear` restore call to once per scene, and also gates the save path so it
    // cannot write before the first restore decision has been made (see the `.onChange(of:
    // workspaceSnapshot)` recovery handler below) — a premature write here could otherwise race
    // and clobber a persisted snapshot that the platform hasn't finished delivering yet.
    @State private var didRestore = false

    var body: some View {
        GeometryReader { geo in
            // Clamp at the read site so garbage/NaN persisted values (e.g. from a bogus
            // `defaults write`) can't render an off-screen or unbounded layout.
            let clampedSidebarWidth = clampSidebar(sidebarWidth)
            let clampedEditorFraction = clampFraction(editorFraction)
            let contentWidth = max(
                0,
                geo.size.width
                    - CGFloat(clampedSidebarWidth)
                    - LayoutMetrics.dividerHitWidth
                    - (workspace.isMarkdown ? LayoutMetrics.dividerHitWidth : 0)
            )
            let editorWidth = max(0, contentWidth * CGFloat(clampedEditorFraction))

            HStack(spacing: 0) {
                sidebarColumn
                    .frame(width: CGFloat(clampedSidebarWidth))

                SplitDivider(
                    onDrag: { translation in
                        let base = sidebarDragBase ?? clampedSidebarWidth
                        sidebarDragBase = base
                        sidebarWidth = clampSidebar(base + Double(translation))
                    },
                    onDragEnded: {
                        sidebarDragBase = nil
                    }
                )

                if workspace.isMarkdown {
                    editorColumn
                        .frame(width: editorWidth)

                    SplitDivider(
                        onDrag: { translation in
                            let base = fractionDragBase ?? clampedEditorFraction
                            fractionDragBase = base
                            let denominator = Double(contentWidth)
                            let delta = denominator > 0 ? Double(translation) / denominator : 0
                            editorFraction = clampFraction(base + delta)
                        },
                        onDragEnded: {
                            fractionDragBase = nil
                        }
                    )

                    previewColumn
                        .frame(maxWidth: .infinity)
                } else {
                    editorColumn
                        .frame(maxWidth: .infinity)
                }
            }
        }
        // Exposes this window's workspace to `FileCommands` via `@FocusedObject`, so
        // File → Add Folder to Window…/Save always target the focused window (SPEC §10).
        // (Open Folder…/Cmd+N is app-level — it creates a new window — and is not scoped here.)
        .focusedSceneObject(workspace)
        // Window title/subtitle (SPEC §7): the open file's name, with an "Edited" marker while
        // dirty. Sidebar row taps route through `WorkspaceModel.requestOpen` directly — there is
        // no selection→load `.onChange` any more (editor-core's temporary hook is gone; see
        // `WorkspaceModel.selectedFileURL`'s doc comment for why writing it must stay inert).
        // Window title is always "FEdit" — the open file's name is shown in the editor column's
        // header strip (§4), not the titlebar. The subtitle keeps the "Edited" dirty marker (§7).
        .navigationTitle("FEdit")
        .navigationSubtitle(workspace.openFile?.isDirty == true ? "Edited" : "")
        // Invisible: walks up to this window once mounted and installs the dirty-file guard on
        // its close button / Cmd+W (SPEC §7). See `WindowCloseGuard` for why this can't just
        // replace `window.delegate`.
        .background(WindowCloseGuard(model: workspace))
        // (markdown-preview) High defect #1: without this, `editorFirstVisibleLine` would keep
        // holding the *previous* file's line for ~100–200 ms after a switch (until the editor's
        // throttled report for the new file arrives), and that stale value must not drive the
        // new file's preview.
        .onChange(of: workspace.openFile?.url) {
            editorFirstVisibleLine = 0
        }
        // (session-restore) SPEC §3, §9: restore this scene's state once, on first appear. A
        // freshly created (Cmd+N) scene's `@SceneStorage` value is empty, so `restore` is a
        // no-op there — the pristine-scene guarantee this relies on.
        .onAppear {
            guard !didRestore else { return }
            didRestore = true
            workspace.restore(fromJSON: workspaceSnapshot)
            // "Open Folder…" (Cmd+N) new-window flow: the menu command incremented the launch
            // mailbox immediately before opening this window. Drain exactly one pending pick if
            // this window is genuinely pristine (nothing restored above), then present the
            // folder picker one runloop turn later so the window is on screen first — Cancel
            // then trivially leaves an empty window. Restored / blank-startup windows (counter
            // == 0) skip this, so today's startup behavior is unchanged.
            if LaunchCoordinator.shared.pendingNewWindowPicks > 0 && workspace.roots.isEmpty && workspace.openFile == nil {
                LaunchCoordinator.shared.pendingNewWindowPicks -= 1
                DispatchQueue.main.async {
                    workspace.presentNewWindowFolderPanel()
                }
            }
        }
        // Late-arriving `@SceneStorage` recovery rule: the platform can deliver the persisted
        // string *after* the first render (`workspaceSnapshot` starts at `""` and is updated once
        // the real value has loaded). If that empty→non-empty transition happens while the model
        // is still pristine, retry the restore — otherwise a slow-arriving snapshot would never
        // get applied.
        .onChange(of: workspaceSnapshot) { oldValue, newValue in
            guard oldValue.isEmpty, !newValue.isEmpty,
                  workspace.roots.isEmpty, workspace.openFile == nil else { return }
            workspace.restore(fromJSON: newValue)
        }
        // Save: keeps `workspaceSnapshot` current whenever restorable state changes, tracked over
        // **post-change** values only — `onReceive(workspace.objectWillChange)` is deliberately
        // not used here: it fires on `willSet`, which would persist the *pre*-change snapshot and
        // lose the last edit made before quit. Gated on `didRestore` so this can never write
        // before the first restore decision above has run (so it can't race and clobber a
        // snapshot the platform is still in the middle of delivering — the late-arriving rule's
        // whole point). `snapshotJSON() == nil` (encode failure) skips the write, keeping
        // whatever was last stored (last-good).
        .onChange(of: workspace.snapshotJSON()) { _, newValue in
            guard didRestore, let newValue else { return }
            workspaceSnapshot = newValue
        }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            if !workspace.roots.isEmpty {
                ColumnHeaderBar(title: workspace.roots.map { $0.url.lastPathComponent }.joined(separator: ", "))
            }
            SidebarView(workspace: workspace)
        }
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if let name = workspace.openFileName {
                ColumnHeaderBar(title: name)
            }
            if workspace.openFile != nil {
                CodeEditorView(
                    text: $workspace.editorText,
                    documentID: workspace.openFile?.url,
                    // (syntax-highlighting): derived from the open file's extension at the
                    // ContentView call site — `WorkspaceModel.openFile` has no `language` of its
                    // own yet (load-bearing assumption #4), so this piggybacks on the same URL
                    // that already drives `documentID`.
                    language: SyntaxLanguage(fileExtension: workspace.openFile?.url.pathExtension),
                    // (session-restore): the one-shot cursor-restore seam (editor-core cross-plan
                    // decision) — the model clears this itself the next time `noteCursorMoved`
                    // fires, which the editor's own restore-consume triggers via `onCursorChange`.
                    cursorToRestore: workspace.pendingCursorRestore,
                    onFirstVisibleLineChange: { line in
                        editorFirstVisibleLine = line
                    },
                    onCursorChange: { location in
                        workspace.noteCursorMoved(location)
                    },
                    // (editor-font-zoom): the live global editor font size, clamped at this read
                    // site (mirrors `clampSidebar`/`clampFraction`) so a bogus persisted value
                    // renders bounded, not at its raw magnitude.
                    fontSize: CGFloat(clampFontSize(editorFontSize))
                )
            } else {
                Color.white
                    .overlay(
                        Text("No file open")
                            .foregroundStyle(.secondary)
                    )
            }
        }
    }

    private var previewColumn: some View {
        // A "Preview" header strip so the preview content starts at the same vertical level as the
        // editor (which carries the file-name strip). The preview column only appears for Markdown,
        // so a file is always open here; the strip is unconditional.
        VStack(spacing: 0) {
            ColumnHeaderBar(title: "Preview")
            MarkdownPreviewView(
                text: workspace.editorText,
                fileURL: workspace.openFile?.url,
                firstVisibleLine: editorFirstVisibleLine
            )
        }
    }

    private func clampSidebar(_ value: Double) -> Double {
        // NaN fails every comparison, so min/max alone would pass it straight through.
        guard value.isFinite else { return LayoutMetrics.defaultSidebarWidth }
        return min(max(value, LayoutMetrics.sidebarMin), LayoutMetrics.sidebarMax)
    }

    private func clampFraction(_ value: Double) -> Double {
        // NaN fails every comparison, so min/max alone would pass it straight through.
        guard value.isFinite else { return LayoutMetrics.defaultEditorFraction }
        return min(max(value, LayoutMetrics.editorFractionMin), LayoutMetrics.editorFractionMax)
    }

    private func clampFontSize(_ value: Double) -> Double {
        // NaN fails every comparison, so min/max alone would pass it straight through.
        guard value.isFinite else { return EditorMetrics.defaultFontSize }
        return min(max(value, EditorMetrics.minFontSize), EditorMetrics.maxFontSize)
    }
}

#Preview {
    ContentView()
}
