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
                // `.inset` (not `.sidebar`): the source-list `.sidebar` style computes its own
                // AppKit row metrics and ignores `defaultMinListRowHeight`, so it can't be
                // tightened; `.inset` honors the floor. Custom selection (no `List(selection:)`)
                // and OutlineGroup disclosure are unaffected by the style change.
                .listStyle(.inset)
                .environment(\.defaultMinListRowHeight, 20)
            }
        }
    }

    private var searchField: some View {
        TextField("Filter files (e.g. .swift$ OR ^src/)", text: $workspace.filterText)
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
                    // Explicit user action: force a republish even when the tree is unchanged, so
                    // Refresh is never a silent no-op (the watcher path keeps the diff-guard).
                    workspace.refreshAll(force: true)
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
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
                // (git-changed-badge) A right-aligned "(changed)" badge on a file whose working-tree
                // content differs from HEAD (SPEC §5.6). The `Spacer` pushes it to the trailing edge
                // and lets the name truncate (tail) *first*, so a long name never clips the badge
                // (criterion 10). `.fixedSize()` keeps the badge intrinsic-width. Directories never
                // reach this branch (criterion 2).
                Spacer(minLength: 6)
                if isChanged {
                    Text("(changed)")
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : .secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Give the row a defined height that meets the list's row-height floor, so the
            // selection pill below can inset within it for a little top/bottom breathing room
            // instead of filling the row edge-to-edge (which reads as cramped at tight density).
            .padding(.vertical, 2)
            .contentShape(Rectangle())
            .onTapGesture {
                workspace.requestOpen(node.url)
            }
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                    .padding(.vertical, 2)
            )
        }
    }

    private var isSelected: Bool {
        node.url == workspace.selectedFileURL
    }

    /// (git-changed-badge) Whether this row's file is in the window's changed-set (SPEC §5.6).
    /// Directories are excluded outright, so the badge only ever shows on file rows — in both the
    /// `OutlineGroup` tree and the flat filtered list, which share this view (criteria 2, 4).
    private var isChanged: Bool {
        !node.isDirectory && workspace.changedFileURLs.contains(node.url)
    }
}
