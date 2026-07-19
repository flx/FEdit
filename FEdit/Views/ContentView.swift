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

    // Drag baselines: captured on the first callback of a gesture, cleared on drag end. This
    // makes clamping absolute, so dragging past a stop and back does not accumulate drift.
    @State private var sidebarDragBase: Double?
    @State private var fractionDragBase: Double?

    // Debug-only sinks for `CodeEditorView`'s scroll/cursor callbacks (editor-core Tier 3). The
    // real consumers arrive with (markdown-preview) (scroll sync) and (session-restore) (cursor
    // persistence); for now these just prove the callbacks fire correctly.
    @State private var debugFirstVisibleLine = 0
    @State private var debugCursorPosition = 0

    // One per window (SPEC §3) — holds the open folders and selection for this window.
    @StateObject private var workspace = WorkspaceModel()

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
        // File → Open Folder…/Save always target the focused window (SPEC §10).
        .focusedSceneObject(workspace)
        // Window title/subtitle (SPEC §7): the open file's name, with an "Edited" marker while
        // dirty. Sidebar row taps route through `WorkspaceModel.requestOpen` directly — there is
        // no selection→load `.onChange` any more (editor-core's temporary hook is gone; see
        // `WorkspaceModel.selectedFileURL`'s doc comment for why writing it must stay inert).
        .navigationTitle(workspace.openFileName ?? "FEdit")
        .navigationSubtitle(workspace.openFile?.isDirty == true ? "Edited" : "")
        // Invisible: walks up to this window once mounted and installs the dirty-file guard on
        // its close button / Cmd+W (SPEC §7). See `WindowCloseGuard` for why this can't just
        // replace `window.delegate`.
        .background(WindowCloseGuard(model: workspace))
    }

    private var sidebarColumn: some View {
        SidebarView(workspace: workspace)
    }

    private var editorColumn: some View {
        VStack(spacing: 0) {
            if workspace.openFile != nil {
                CodeEditorView(
                    text: $workspace.editorText,
                    documentID: workspace.openFile?.url,
                    onFirstVisibleLineChange: { line in
                        debugFirstVisibleLine = line
                        #if DEBUG
                        print("[CodeEditorView] onFirstVisibleLineChange: \(line)")
                        #endif
                    },
                    onCursorChange: { location in
                        debugCursorPosition = location
                        #if DEBUG
                        print("[CodeEditorView] onCursorChange: \(location)")
                        #endif
                    }
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
        Group {
            Color(nsColor: .underPageBackgroundColor)
                .overlay(
                    Text("Preview")
                        .foregroundStyle(.secondary)
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
}

#Preview {
    ContentView()
}
