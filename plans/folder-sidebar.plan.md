# folder-sidebar

**Risk tier:** standard — additive UI feature plus a simple synchronous recursive directory scan; no concurrency, no subtle algorithms, blast radius limited to two new model files, one new view, and small edits to `ContentView.swift` / `FEditApp.swift`.

## Goal

Implement the folder sidebar in tree mode per SPEC §5.1–§5.3 and the File → Open Folder… command per §10: users add one or more top-level folders via `NSOpenPanel` (Cmd+Shift+O or the empty-state button), each root appears as a sidebar section with a `~`-abbreviated header, contents are shown as a disclosure tree (recursive scan skipping dotfiles / `node_modules` / `.build` / `DerivedData`, folders-first sort), only files are selectable, the selected file's row is highlighted, and a header context menu offers Remove from Sidebar and Refresh. Selection only records the URL in `WorkspaceModel.selectedFileURL`; actually opening files arrives with (open-save). Filter field/flat mode is (filter-query), persistence of roots is (session-restore).

## Acceptance criteria — concrete and testable

1. `xcodebuild` succeeds after every tier; app launches without regression to prior criteria.
2. With no folders open, the sidebar column shows a placeholder message and an "Open Folder…" button; clicking the button presents an `NSOpenPanel` restricted to directories (`canChooseFiles == false`, `canChooseDirectories == true`, `allowsMultipleSelection == true`).
3. File → Open Folder… exists in the File menu with shortcut Cmd+Shift+O, acts on the focused window (adding a folder in window A does not change window B), and is disabled when no editor window is focused.
4. Selecting N folders in the panel adds N sections. Each section header shows the folder path with the home directory abbreviated to `~` (e.g. `~/Programming/swift/FEdit`), single line, truncated head-first when too narrow.
5. Adding a folder that is already a root is a no-op (no duplicate section, no rescan of it, remaining selected panel folders still added). Duplicate detection compares `url.resolvingSymlinksInPath().path`, so `/tmp/x` and `/private/tmp/x` count as the same root.
6. Tree contents, verified against a fixture folder created on disk:
   - dotfiles and dot-directories (e.g. `.git`, `.build`, `.hidden.txt`) do not appear;
   - directories named `node_modules` and `DerivedData` do not appear at any depth;
   - within every directory, all folders precede all files, each group sorted with `localizedStandardCompare` (so `file2` < `file10`).
7. Folders render with a disclosure triangle and folder icon and expand/collapse on click; files render with a type-appropriate icon. Clicking a folder row never sets a selection.
8. Clicking a file row sets `WorkspaceModel.selectedFileURL` to that file's URL and the row shows a highlight; clicking a different file moves the highlight. The same file listed under two overlapping roots highlights in both places (highlight is by URL — accepted v1 behavior). Manual test: add overlapping roots (e.g. `~/proj` and `~/proj/sub`) and confirm both sections render and expand/collapse independently with no ForEach identity glitches.
9. Right-clicking a section header shows **Remove from Sidebar** and **Refresh**. Remove drops only that section and touches nothing on disk. Refresh rescans **all** roots: a file created on disk after adding the folder appears after Refresh; a deleted one disappears.
10. Scanning a root that disappears mid-use or contains unreadable subdirectories does not crash — unreadable directories simply show as empty.
11. Sidebar content scrolls vertically within the existing fixed-width sidebar column; divider-drag behavior from (split-layout) is unchanged.

## Tiers

### Tier 1 — `FileNode` model and scanner (pure model, no UI)

**Create `FEdit/Models/FileNode.swift`** (GPL header per project convention):

- `struct FileNode: Identifiable` (no `Hashable` conformance — nothing in this plan needs it; dropped deliberately rather than carried unused)
  - `let url: URL` (standardized file URL), `let name: String` (last path component), `let isDirectory: Bool`
  - `var children: [FileNode]?` — non-nil (possibly empty) for directories, `nil` for files, so it can drive `OutlineGroup`/`DisclosureGroup` directly.
  - `var id: URL { url }`.
- `static let skippedDirectoryNames: Set<String> = ["node_modules", ".build", "DerivedData"]` (dotfile skipping already covers `.build`; kept explicit per spec).
- `static func scan(directory: URL) -> FileNode` — builds the root node; recursion via a private helper:
  - `FileManager.contentsOfDirectory(at:includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])`; a thrown error yields an empty `children` array (no crash on unreadable dirs).
  - Skips entries whose name is in `skippedDirectoryNames` when they are directories.
  - Symbolic links are treated as leaf files (no recursion) to avoid link cycles.
  - Sort: directories first, then files, each subgroup sorted by `name.localizedStandardCompare == .orderedAscending`.
  - Synchronous on the calling thread per SPEC §11 (v1 accepts this; skip list bounds the cost).

**Verification (Tier 1):** create `scripts/FileNodeTests/main.swift` — a top-level assertion harness (the file MUST be named `main.swift` for top-level statements to compile under multi-file swiftc; this mirrors the filter-query plan's established convention) — compiled and run via:

```
swiftc FEdit/Models/FileNode.swift scripts/FileNodeTests/main.swift -o /tmp/fntests && /tmp/fntests
```

The harness scripts a fixture generator (plain `mkdir`/`touch` into a temp directory): dotfiles and dot-directories, a `node_modules` directory, `file2`/`file10` siblings to assert `localizedStandardCompare` order (`file2` before `file10`), and an unreadable directory via `chmod 000` (restored/removed on teardown). Assertions cover: hidden entries skipped, skip-list directories skipped, folders-first ordering, `localizedStandardCompare` within groups, `children == nil` for files and non-nil for directories, and the unreadable directory yielding empty `children` with no crash. This tier verifies the scanner's behavior end-to-end without any UI.

Buildable alone (new file in the file-system-synchronized group; no other file touched). Revert = delete the file (and the test harness).

### Tier 2 — `WorkspaceModel`, menu command, window wiring

**Create `FEdit/Models/WorkspaceModel.swift`:**

- `@MainActor final class WorkspaceModel: ObservableObject`
  - `@Published private(set) var roots: [FileNode] = []`
  - `@Published var selectedFileURL: URL? = nil` (record-only until (open-save))
  - `func addFolders(_ urls: [URL])` — standardizes each URL, skips ones already present — duplicate comparison uses `url.resolvingSymlinksInPath().path` (catches `/tmp` vs `/private/tmp`), not just standardized paths — scans the rest via `FileNode.scan` and appends in panel order.
  - `func removeRoot(_ root: FileNode)` — removes by id; disk untouched. Also clears `selectedFileURL` if it points inside the removed root (one line; closes a bookkeeping gap the open-save plan never picks up).
  - `func refreshAll()` — rescans every root in place (spec: Refresh rescans all folders).
  - `func presentOpenPanel()` — configures `NSOpenPanel` (`canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = true`), on OK calls `addFolders(panel.urls)`.

**Modify `FEdit/App/FEditApp.swift`:**

- Add `struct FileCommands: Commands` with `@FocusedObject private var workspace: WorkspaceModel?`; body: `CommandGroup(after: .newItem) { Button("Open Folder…") { workspace?.presentOpenPanel() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(workspace == nil) }`. Note the lowercase KeyEquivalent with explicit `.shift` — the uppercase-`"O"`-plus-explicit-shift form is the historically fragile spelling. Verify the chord fires at manual test.
- Attach `.commands { FileCommands() }` to the existing `WindowGroup`.

**Modify `FEdit/Views/ContentView.swift`:**

- Add `@StateObject private var workspace = WorkspaceModel()` (one per window — per-window state per SPEC §3).
- Apply `.focusedSceneObject(workspace)` so the command targets the focused window (SPEC §10).
- Pass `workspace` into the sidebar column slot (still the split-layout placeholder in this tier; a temporary `Text("\(workspace.roots.count) folders")` is acceptable for verification and is replaced in Tier 3).

**Verification (Tier 2):** buildable and manually verifiable — Cmd+Shift+O opens the panel (confirm the chord fires; see keyboard-shortcut note above), chosen roots show up in the count, duplicate adds are no-ops, per-window independence checkable with Cmd+N. Revert = drop the two small edits and delete the file.

### Tier 3 — `SidebarView`: sections, tree, selection, context menu, empty state

**Create `FEdit/Views/SidebarView.swift`:**

- `struct SidebarView: View` with `@ObservedObject var workspace: WorkspaceModel`.
- **Empty state** (`workspace.roots.isEmpty`): centered `VStack` with a short caption ("No folders open") and `Button("Open Folder…") { workspace.presentOpenPanel() }`.
- **Populated state:** `List` (`.listStyle(.sidebar)`), one `Section` per root:
  - Header: root path via `(root.url.path as NSString).abbreviatingWithTildeInPath`, `.lineLimit(1)`, `.truncationMode(.head)`. The `.contextMenu` is attached to the full-width header container (not the `Text`) — e.g. the header content wrapped with `.frame(maxWidth: .infinity, alignment: .leading)` — so right-clicks anywhere on the header band work; menu items: `Button("Remove from Sidebar") { workspace.removeRoot(root) }` and `Button("Refresh") { workspace.refreshAll() }`.
  - Body: `OutlineGroup(root.children ?? [], children: \.children) { node in FileRow(node: node, workspace: workspace) }` — `OutlineGroup` supplies disclosure triangles and manages expansion state (transient expansion state is fine for v1).
- Private `FileRow` view with signature `FileRow(node:workspace:)` — it needs the node plus access to the selection (the workspace, or equivalently a selection binding); a bare `FileRow(node:)` could not read/write `selectedFileURL`. Body: `HStack` of icon + `Text(node.name)`.
  - Icon: folders `Image(systemName: "folder")`; files `Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))` sized ~16 pt (type-appropriate per §5.3).
  - Files only: `.frame(maxWidth: .infinity, alignment: .leading)` applied BEFORE `.contentShape(Rectangle())` so the whole row width is clickable, then `.onTapGesture { workspace.selectedFileURL = node.url }`; row background `RoundedRectangle` filled with `Color(nsColor: .selectedContentBackgroundColor)` (with matching text color) when `node.url == workspace.selectedFileURL`. Folder rows have no tap-select behavior (disclosure only).
  - List row selection binding is deliberately not used — manual highlight keeps "only files selectable" trivial and matches the by-URL highlight rule.

**Modify `FEdit/Views/ContentView.swift`:** replace the sidebar column placeholder (and the Tier 2 count text) with `SidebarView(workspace: workspace)`; column width/divider mechanics from (split-layout) untouched.

Sidebar column background: `SidebarView` owns its background via `.listStyle(.sidebar)`; split-layout's placeholder tint applies only while the placeholder exists.

**Verification (Tier 3):** manual, against the acceptance criteria — fixture folder for tree contents (criterion 6), disclosure/selection behavior (criteria 7–8, including the overlapping-roots case), header context menu with right-clicks across the full header band (criterion 9), empty state and scrolling (criteria 2, 11).

Revert = restore the placeholder line and delete the file.

## Interface between tiers

- Tier 1 → Tier 2: `FileNode` (`url`, `name`, `isDirectory`, `children: [FileNode]?`, `id: URL`) and `FileNode.scan(directory:) -> FileNode`. `WorkspaceModel` is the only scanner caller. The optionality of `children: [FileNode]?` is DELIBERATE (nil = file, drives `OutlineGroup` leaf detection) — downstream items must not "fix" it to a non-optional array.
- Tier 2 → Tier 3: `WorkspaceModel` surface consumed by the view layer — `roots: [FileNode]`, `selectedFileURL: URL?`, `presentOpenPanel()`, `removeRoot(_:)`, `refreshAll()`. `SidebarView` never touches `FileManager` directly.
- Tier 2 → later items: `WorkspaceModel` as the window's `focusedSceneObject` is the hook (open-save) and (session-restore) extend; `selectedFileURL` is the input (editor-core)/(open-save) consume; `roots` is what (filter-query) filters and (session-restore) snapshots.

## Load-bearing assumptions

From **(xcode-scaffold)**:
- `FEdit.xcodeproj` builds; the `FEdit/` group is file-system-synchronized, so new files under `FEdit/Models/` and `FEdit/Views/` are picked up without pbxproj edits.
- `FEdit/App/FEditApp.swift` contains the `@main` app with a `WindowGroup` whose content is `ContentView`, to which `.commands { }` can be attached (or an existing `.commands` block to extend).
- A GPL header boilerplate convention exists for new source files.
- No sandbox: `NSOpenPanel` URLs are plain paths, no security-scoped bookmark handling needed (SPEC §2).

From **(split-layout)**:
- `FEdit/Views/ContentView.swift` renders three columns with a fixed-width sidebar column that hosts a placeholder view; this plan replaces only that placeholder's content and does not touch divider/width logic.
- `SettingsKey` constants live in `App/FEditApp.swift`; this feature adds none (root persistence is (session-restore)'s job).

API-level assumptions:
- `@FocusedObject` + `.focusedSceneObject` deliver the focused window's `WorkspaceModel` to `Commands` (standard SwiftUI macOS pattern, SPEC §10 names it).
- `OutlineGroup` over a value-type tree with `children: [FileNode]?` provides disclosure triangles inside `List` sections.
- Overlapping roots (e.g. `~/proj` and `~/proj/sub` both added) produce duplicate `FileNode.id` values across sections; this is ASSUMED fine because `ForEach` identity is section-scoped. Fallback if the assumption fails (identity glitches at manual test): switch to a root-qualified id (e.g. root path + node path).

## Out of scope

- Filter field, query language, flat filtered mode ((filter-query), SPEC §5.4–§5.5).
- Actually opening/reading the selected file, dirty tracking, selection revert on cancel ((open-save), (editor-core)).
- Persisting open roots or selection across relaunch ((session-restore), SPEC §9).
- File-system watching or automatic refresh (SPEC §12 non-goal; refresh is manual).
- Async/background scanning (SPEC §11 explicitly accepts synchronous v1).
- File create/rename/delete from the sidebar (SPEC §12 non-goal).
- Persisted disclosure/expansion state.
- Special-casing symlinks: they appear as selectable leaf rows; selecting a symlink to a directory later produces (open-save)'s read-error alert (accepted v1).

## Auto-resolved (plan review)

Adversarial review findings folded in without open questions. Defects fixed: Tier 1 gained a scripted verification harness (`scripts/FileNodeTests/main.swift` compiled with the model file via swiftc, plus a mkdir/touch fixture generator covering dotfiles, `node_modules`, `file2`/`file10` ordering, and a chmod-000 unreadable directory), and each tier now states what it verifies; the Open Folder shortcut uses the lowercase-`"o"`-plus-`.shift` spelling; file rows get `.frame(maxWidth: .infinity, alignment: .leading)` before `.contentShape` so the full row is clickable; the section-header context menu sits on the full-width header container; `FileRow` carries its real `FileRow(node:workspace:)` signature; and `removeRoot` now clears `selectedFileURL` when it points inside the removed root. Tensions resolved by decision: overlapping-roots duplicate ids are accepted on the section-scoped-ForEach assumption with a root-qualified-id fallback named and a manual test added; duplicate-root dedup compares symlink-resolved paths; `children` optionality is documented as deliberate; dir-symlink selection defers to open-save's error alert; `SidebarView` owns the sidebar background via `.listStyle(.sidebar)`; criterion 1 reworded to "no regression to prior criteria" and the unused `Hashable` conformance dropped from `FileNode`.
