//
//  FilterRowCache.swift
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

import Foundation

/// (filter-walk-main-thread) Per-root cache of filter mode's derived rows (SPEC §5.4).
///
/// **The defect this exists for.** `SidebarView.flatRows` used to run `filesWithRelativePaths()` —
/// a full DFS allocating one `(String, FileNode)` tuple per file — *inside `body`, per root, per
/// render*. `SidebarView` observes the whole `WorkspaceModel`, so every-keystroke `openFile` and
/// every-caret `cursorLocation` write re-rendered it: with a filter active on a home-scale root,
/// typing in the **editor** re-walked the sidebar tree on the main thread. This type turns that
/// walk from per-render into per-*splice*.
///
/// **Threading/ownership.** A plain value type, main-actor-confined by its owner (`WorkspaceModel`
/// holds the single instance as a **non-published** stored property, so populating it during a
/// SwiftUI body pass publishes nothing and cannot loop). It imports Foundation only, deliberately:
/// the model itself imports AppKit and so cannot be exercised by a `swiftc` harness, whereas this
/// is pinned standalone by `scripts/FilterRowCacheTests`.
///
/// **Two levels, on purpose.** An entry holds the query-independent `flat` list (one DFS per tree
/// epoch, however the user then edits the query) *and* the subset `filtered` for the query it was
/// last asked about. The expensive half — the DFS plus one path-`String` concatenation per file —
/// is what the entry guards; refiltering an already-built flat list is a string-match pass that
/// allocates no paths.
///
/// **Memory, stated plainly.** An entry retains the flat list *and* the current filtered subset —
/// order 100–200 B per file (a `Match` held in up to two arrays plus its freshly-built path
/// `String`) — so a 500k-file `$HOME` root can approach SPEC §1's whole <100 MB budget by itself
/// **while a filter is active in that window**. That is the trade against the old inline walk, which reallocated the same
/// array transiently on every render: resident-while-filtering versus reallocated-per-keystroke.
/// `releaseAll()` on leaving filter mode bounds the exposure to filter-mode duration.
///
/// **Residual, not hidden.** The DFS is still O(N) on the main thread; it now runs once per splice
/// instead of once per render. Under heavy structural churn (a build, `npm install`) with a filter
/// active that is still a hitch at the damping cadence, until `tree-node-budget` bounds N.
struct FilterRowCache {
    /// One filter-mode row: a file's root-relative path (the label the flat list shows) and the
    /// node behind it. `Equatable` so the harness can compare a whole cached result against the
    /// inline `filesWithRelativePaths().filter { … }` reference, order included.
    struct Match: Equatable {
        let path: String
        let node: FileNode
    }

    /// One root's cached derivation. `flat` is a function of the root's *tree* alone; `filtered` is
    /// `flat` narrowed by `filteredFor`. Both are dropped together — see `invalidate(_:)`.
    private struct Entry {
        var flat: [Match]
        var filteredFor: FilterQuery
        var filtered: [Match]
    }

    private var entries: [URL: Entry] = [:]

    /// The single read path. `url` is the root's URL, `query` the caller's already-parsed query
    /// (the view parses once per render and passes it down — this type never parses).
    ///
    /// Three outcomes, and which of them runs `provider`:
    ///   - **hit** (entry present, same parsed query) → the cached rows; `provider` NOT called.
    ///   - **tree miss** (no entry) → `provider()` builds the flat list, which is filtered and
    ///     stored; `provider` called exactly once.
    ///   - **query miss** (entry present, different parsed query) → the cached flat list is
    ///     refiltered and the entry updated in place; `provider` NOT called.
    ///
    /// **Contract: `provider` must not touch this cache.** It is executed during a `mutating`
    /// access to the cache, so a re-entrant read or write from inside it traps on exclusive access.
    /// Its actual body is a pure `FileNode` walk, which touches nothing.
    mutating func rows(for url: URL, query: FilterQuery, provider: () -> [Match]) -> [Match] {
        if var entry = entries[url] {
            if entry.filteredFor == query {
                return entry.filtered
            }
            entry.filtered = entry.flat.filter { query.matches($0.path) }
            entry.filteredFor = query
            entries[url] = entry
            return entry.filtered
        }

        let flat = provider()
        let filtered = flat.filter { query.matches($0.path) }
        entries[url] = Entry(flat: flat, filteredFor: query, filtered: filtered)
        return filtered
    }

    /// Drops `url`'s entry entirely, so the next `rows(for:query:provider:)` re-runs the provider.
    ///
    /// **One operation for both callers** — a scan landing that actually spliced a new tree in, and
    /// a root leaving the sidebar — deliberately not two names for the same thing. And a **whole**
    /// entry drop, not a partial clear: there is no staleness bit to get wrong, so the
    /// reset-flat-keep-filtered bug (serving pre-splice rows for the current query) has nowhere to
    /// live. A URL with no entry is a silent no-op.
    mutating func invalidate(_ url: URL) {
        entries.removeValue(forKey: url)
    }

    /// Drops every entry — the memory-release path, called when the window leaves filter mode.
    /// The cost of releasing is one DFS per root if the user retypes a query; the benefit is that
    /// nothing is retained across the (typically much longer) tree-mode stretches.
    mutating func releaseAll() {
        entries.removeAll()
    }
}
