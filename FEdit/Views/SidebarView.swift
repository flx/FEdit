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

/// The folder sidebar in tree mode (SPEC §5.1–§5.3): one section per open root, disclosure
/// tree contents, only files selectable, header context menu for Remove/Refresh, and an
/// empty-state button when no folders are open.
struct SidebarView: View {
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        if workspace.roots.isEmpty {
            emptyState
        } else {
            List {
                ForEach(workspace.roots) { root in
                    Section {
                        OutlineGroup(root.children ?? [], children: \.children) { node in
                            FileRow(node: node, workspace: workspace)
                        }
                    } header: {
                        header(for: root)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("No folders open")
                .foregroundStyle(.secondary)
            Button("Open Folder…") {
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

/// A single tree row: folders show a folder icon (disclosure handled by `OutlineGroup` itself);
/// files show a type-appropriate icon and are the only selectable rows.
private struct FileRow: View {
    let node: FileNode
    @ObservedObject var workspace: WorkspaceModel

    var body: some View {
        if node.isDirectory {
            HStack {
                Image(systemName: "folder")
                Text(node.name)
            }
        } else {
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(node.name)
                    .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                workspace.selectedFileURL = node.url
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
