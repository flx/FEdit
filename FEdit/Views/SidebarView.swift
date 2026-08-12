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
                            if workspace.initialScanRootURLs.contains(root.url) {
                                // (async-root-scan) The root is still the empty placeholder
                                // `addFolders` appended; its walk is running off the main thread.
                                // Keyed to *first* scans only, so a later refresh of a populated
                                // root never blanks it and a genuinely empty root never flickers.
                                Text("Scanning…")
                                    .foregroundStyle(.secondary)
                            } else if query.isEmpty {
                                truncationNotice(for: root, filtering: false)
                                OutlineGroup(root.children ?? [], children: \.children) { node in
                                    FileRow(node: node, workspace: workspace)
                                }
                            } else {
                                truncationNotice(for: root, filtering: true)
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

    /// (tree-node-budget) The per-root declaration that this tree is **incomplete**: shown iff the
    /// root's last applied walk hit the node budget (SPEC §5.2, §5.4, §11). Silent truncation was
    /// rejected — this row is the whole visible half of the item.
    ///
    /// Shown in **both** modes, because both misreport otherwise: tree mode as "this folder is
    /// empty", filter mode as "this file does not exist". Deliberately **not** shown for a root that
    /// is still `Scanning…` — its walk has not landed, so there is nothing to declare yet, and
    /// `body`'s first branch intercepts those before this is ever reached.
    ///
    /// The copy names the one recovery that works: adding the subfolder you want as its **own** root,
    /// since the budget is per root. It deliberately does **not** suggest Refresh — truncation is
    /// deterministic, so a rescan of the same tree provably cuts in exactly the same place, and
    /// advising it would send the user round a loop that cannot help.
    @ViewBuilder
    private func truncationNotice(for root: FileNode, filtering: Bool) -> some View {
        if workspace.truncatedRootURLs.contains(root.url) {
            Group {
                if filtering {
                    Text("Results may be incomplete — the tree is truncated.")
                } else if let count = workspace.truncatedNodeCount(for: root.url) {
                    // Interpolated from the walk's own measurement, so the budget constant lives in
                    // exactly one place (`FileNode.defaultNodeBudget`) and changing it needs no edit
                    // here.
                    Text("Showing the first \(count.formatted()) items — deeper folders are incomplete. Add a subfolder as its own root to see more.")
                } else {
                    // The count is missing only if a truncated landing published this flag without
                    // storing its report — unreachable, since both happen in one `applyScan` turn.
                    // The declaration still goes out: dropping the notice would hide the truncation,
                    // and inventing a number would be worse than omitting it.
                    Text("Deeper folders are incomplete — the tree is truncated. Add a subfolder as its own root to see more.")
                }
            }
            .foregroundStyle(.secondary)
            // The notice is a sentence, not a name: it wraps to as many lines as it needs rather
            // than truncating — the same outcome as the file-name rows below it, by different means (SPEC §5.3).
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var searchField: some View {
        TextField("Filter files (e.g. .swift$ OR ^src/)", text: $workspace.filterText)
            .textFieldStyle(.roundedBorder)
            .padding(8)
    }

    /// Flat filtered contents of one section (SPEC §5.4): every file under `root` whose
    /// root-relative path matches `query`, in the scanner's depth-first (folders-first) order;
    /// a per-section "No matches" fallback when nothing matches.
    ///
    /// (filter-walk-main-thread) These rows are **cached derived state**, not recomputed here. This
    /// used to run `root.filesWithRelativePaths()` — a full DFS allocating one tuple per file —
    /// inline in `body`; since this view observes the whole model, every editor keystroke and every
    /// caret move re-ran that walk on the main thread for each root. `filteredMatches` recomputes
    /// only when the root's tree is spliced or the query changes, so a render with unchanged inputs
    /// costs a dictionary lookup. `query` is the single per-render parse from `body`, passed down
    /// rather than re-derived, and the mode decision, "No matches", and `FileRow` are unchanged.
    ///
    /// (async-root-scan) Only reached for a root whose first scan has landed — the "Scanning…"
    /// branch in `body` intercepts the others in *both* modes, so an incomplete tree is never
    /// misreported here as "this file doesn't exist".
    @ViewBuilder
    private func flatRows(for root: FileNode, query: FilterQuery) -> some View {
        let matches = workspace.filteredMatches(for: root, query: query)
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
            HStack(alignment: .top) {
                Image(systemName: "folder")
                Text(label)
            }
        } else {
            HStack(alignment: .top) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                Text(label)
                    .foregroundStyle(isSelected ? Color(nsColor: .selectedMenuItemTextColor) : .primary)
                // (git-changed-badge) A right-aligned "(changed)" badge on a file whose working-tree
                // content differs from HEAD (SPEC §5.6). The `Spacer` pushes it to the trailing edge;
                // the name wraps (sidebar-hscroll) within the remaining width and the enclosing
                // `HStack(alignment: .top)` pins the badge beside the name's first line, so a long
                // name never clips the badge (criterion 10). `.fixedSize()` keeps the badge
                // intrinsic-width. Directories never reach this branch (criterion 2).
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
