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

    // Per-window @State is intentional: each window will later have its own open file.
    @State private var isMarkdown = false

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
                    - (isMarkdown ? LayoutMetrics.dividerHitWidth : 0)
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

                if isMarkdown {
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
    }

    private var sidebarColumn: some View {
        Group {
            Color(nsColor: .windowBackgroundColor)
                .overlay(
                    Text("Sidebar")
                        .foregroundStyle(.secondary)
                )
        }
    }

    private var editorColumn: some View {
        Group {
            Color(nsColor: .textBackgroundColor)
                .overlay(
                    VStack(spacing: 12) {
                        Text("No file open")
                            .foregroundStyle(.secondary)
                        // TODO(open-save): replace stub with real language detection from the open file.
                        Toggle("Markdown preview (stub)", isOn: $isMarkdown)
                    }
                )
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
