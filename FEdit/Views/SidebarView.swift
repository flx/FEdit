//
//  SidebarView.swift
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
import AppKit

/// The folder sidebar (SPEC §5.1–§5.5): one section per open root, a filter field that switches
/// each section between a disclosure tree and a flat list of matching files, only files
/// selectable, header context menu for Remove/Refresh, and an empty-state button when no folders
/// are open.
struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        if workspace.roots.isEmpty {
            emptyState
        } else {
            // Computed once per render and shared by every section, so tree vs. flat mode is
            // consistent across all roots (SPEC §5.4–§5.5). An operator-only or blank query
            // (`query.isEmpty`) keeps tree mode rather than flashing "No matches" everywhere.
            let query = FilterQuery(workspace.filterText)
            VStack(spacing: 0) {
                searchField
                List {
                    ForEach(workspace.roots) { root in
                        Section {
                            if query.isEmpty {
                                OutlineGroup(root.children ?? [], children: \.children) { node in
                                    FileRow(node: node, workspace: workspace)
                                }
                            } else {
                                flatRows(for: root, query: query)
                            }
                        } header: {
                            header(for: root)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var searchField: some View {
        TextField("Filter files (e.g. .py OR .swift)", text: $workspace.filterText)
            .textFieldStyle(.roundedBorder)
            .padding(8)
    }

    /// Flat filtered contents of one section (SPEC §5.4): every file under `root` whose
    /// root-relative path matches `query`, in the scanner's depth-first (folders-first) order;
    /// a per-section "No matches" fallback when nothing matches. Computed inline per render — a
    /// synchronous linear scan is acceptable per SPEC §11, no caching layer.
    @ViewBuilder
    private func flatRows(for root: FileNode, query: FilterQuery) -> some View {
        let matches = root.filesWithRelativePaths().filter { query.matches($0.path) }
        if matches.isEmpty {
            Text("No matches")
                .foregroundStyle(.secondary)
        } else {
            ForEach(matches, id: \.node.id) { match in
                FileRow(node: match.node, workspace: workspace, displayText: match.path)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No folders open")
                .foregroundStyle(.secondary)
            Button("Add Folder to Window…") {
                workspace.presentOpenPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(for root: FileNode) -> some View {
        Text((root.url.path as NSString).abbreviatingWithTildeInPath)
            .lineLimit(1)
            .truncationMode(.head)
            // Full-width container carries the context menu so right-clicks anywhere on the
            // header band work, not just directly on the text.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                Button("Remove from Sidebar") {
                    workspace.removeRoot(root)
                }
                Button("Refresh") {
                    workspace.refreshAll()
                }
            }
    }
}

/// A single row for a `FileNode`: folders show a folder icon (disclosure handled by
/// `OutlineGroup` itself); files show a type-appropriate icon and are the only selectable rows.
/// Reused as-is for the flat filtered list (filter-query SPEC §5.4) via `displayText`, so tap
/// handling and selection highlight are identical in both the disclosure tree and the flat list —
/// only the label text differs (the node's own name vs. its filter-match relative path).
private struct FileRow: View {
    let node: FileNode
    @ObservedObject var workspace: WorkspaceModel
    var displayText: String? = nil

    private var label: String { displayText ?? node.name }

    var body: some View {
        if node.isDirectory {
            HStack {
                Image(systemName: "folder")
                Text(label)
            }
        } else {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(label)
                    .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                workspace.requestOpen(node.url)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
            )
        }
    }

    private var isSelected: Bool {
        node.url == workspace.selectedFileURL
    }
}
