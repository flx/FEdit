# column-header-bars

**Risk tier:** standard — purely additive SwiftUI view composition: two fixed-height title strips stacked vertically inside the sidebar and editor columns. No concurrency, no algorithms, no persistence, no model changes. Blast radius = one new reusable view file (`ColumnHeaderBar.swift`), the `sidebarColumn`/`editorColumn` accessors in `ContentView.swift`, one additive `LayoutMetrics` constant, and a SPEC note. The only thing to *not* regress is the shipped width/divider math — mitigated by construction, because the bars stack vertically and never enter the HStack width computations (see criterion 10 / assumption 6).

## Goal

Add two in-window column header strips to the three-column layout (`ContentView.swift`):

- **Folder bar** — a fixed-height strip over the sidebar (first) column showing the open folder name(s): each root's `url.lastPathComponent`, comma-separated (`~/Documents/Programming/swift/FEdit` → `FEdit`; two roots → `FEdit, FlyWheelCADV3`). Hidden (not rendered) when no folders are open, so the sidebar's empty state fills the column flush to the top.
- **Editor bar** — a fixed-height strip over the editor (second) column showing the open file's name (`workspace.openFileName`, e.g. `TODO.md`). Hidden when no file is open (`openFile == nil`), so the "No file open" placeholder fills flush to the top.

Both bars are non-interactive title strips: single line, tail-truncated, subtle background with a bottom hairline separator, leading-aligned text, fixed height, mounted **outside** their column's scroll region so they never scroll with content. They read only existing `@Published` state (`workspace.roots`, `workspace.openFileName`) and update live. The preview (third) column gets **no** bar (out of scope, per the TODO). The window `.navigationTitle`/`.navigationSubtitle` (open-save, SPEC §7) are **left exactly as shipped** — the in-content bars complement them, they do not replace them.

## Key decisions (pinned — one answer each)

1. **Folder bar vs. the existing per-root section headers → COMPLEMENT; section headers stay unchanged.** The new folder bar is a single window-level *summary* strip above the whole sidebar showing only the last path components (`FEdit, FlyWheelCADV3`). The existing per-root `Section` headers in `SidebarView` (SPEC §5.1) show each root's **full** `~`-abbreviated path, head-truncated, and carry the **Remove from Sidebar / Refresh** context menu. They differ in content (name summary vs. full paths), in surface (one fixed strip above the entire list vs. inline per-section rows that scroll with the `List`), and in role (identification vs. required per-root actions). Removing the section headers would delete SPEC-required affordances and the full-path disambiguation; the bar therefore is a **distinct top strip**, not a replacement. This is not a confusing double-header: with one root the bar reads `FEdit` while its section header reads `~/…/FEdit` — a name summary over a full-path row, the same pattern as a navigator's project title above its group rows.
2. **Both bars mount in `ContentView`, not in `SidebarView`.** The TODO says "add the two header bars in the three-column layout" (`ContentView.swift`); keeping both in `ContentView` also makes them symmetric and co-located and keeps `SidebarView` focused on the list. The folder bar sits **above** the sidebar column's search field (bar = column title; search field = content), giving top-to-bottom order: folder bar → search field → list (with its per-root section headers). Rejected alternative: moving the folder bar inside `SidebarView` to co-locate the empty/non-empty branch — rejected for symmetry and the explicit TODO directive; the empty-state guard is a one-line conditional in `ContentView` instead.
3. **Editor bar shows the file name only — no dirty/"Edited" marker.** The TODO specifies the editor bar shows "the open file's name". The "Edited" marker stays where SPEC §7 puts it: `.navigationSubtitle`. Keeping dirty state out of the in-content bar avoids duplicating it and avoids a per-keystroke reason to re-render the bar.
4. **`.navigationTitle` / `.navigationSubtitle` → LEAVE AS-IS (complement, do not replace).** They render the macOS **window titlebar** (file name + "Edited" while dirty, SPEC §7) — a different surface from an in-content column header. Replacing them would regress SPEC §7 (the titlebar would lose the file name and the "Edited" dirty indicator, which the new bars deliberately don't show). Leaving them untouched also means **zero** regression risk to shipped title behavior. Both the titlebar and the editor bar then show the name; only the titlebar shows "Edited". This is the accepted redundancy.
5. **Preview column → NO bar (out of scope).** The TODO scopes the feature to the folder + editor columns only. Consequence pinned in decision 6.
6. **Editor-bar-without-preview-bar vertical offset → accepted.** In the Markdown case the editor column carries the bar (height H) while the preview column has none, so the editor's *text* starts H lower than the preview's *content*. Accepted for v1: adding a blank strip over the preview to realign tops would be a worse artifact (a titleless strip) and the TODO explicitly excludes a preview bar. Recorded, not fixed.
7. **Bars are a single reusable view (`ColumnHeaderBar`).** Both strips share identical chrome (height, background, bottom separator, padding, text style) and differ only in their string, so one reusable `ColumnHeaderBar(title:)` — mirroring the shipped `SplitDivider.swift` reusable-view precedent — is the clean design and keeps the `ContentView` diff to two call sites. The view owns no state; the caller decides when to show it.

## Acceptance criteria — concrete and testable

Verified **manually** on a debug build plus the build check below. The repo's `scripts/*Tests` swiftc harnesses (`FileNodeTests`, `FilterQueryTests`, `SnapshotTests`, …) are pure-logic and cannot instantiate or drive SwiftUI views, so there is no automated coverage for header strips (same posture as split-layout / open-folder-new-window). Numbered:

1. **Build.** `xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Debug -derivedDataPath build build` succeeds after **each** tier.
2. **Folder bar, one root.** Open `~/…/FEdit` → the sidebar column's top strip reads exactly `FEdit`.
3. **Folder bar, multiple roots.** Add a second root (`FlyWheelCADV3`) via Add Folder to Window… → the strip reads exactly `FEdit, FlyWheelCADV3` (each root's `lastPathComponent`, `", "`-joined, in `workspace.roots` order).
4. **Folder bar empty state.** With no folders open, **no** folder bar is rendered; the "No folders open" placeholder fills the sidebar column flush to the top (no blank strip, no gap).
5. **Editor bar.** Open `TODO.md` → the editor column's top strip reads exactly `TODO.md`. With no file open, **no** editor bar is rendered; the "No file open" placeholder fills the editor column flush to the top.
6. **Fixed, non-scrolling.** Scroll the sidebar list and scroll the editor text — both bars stay pinned at the top of their columns (they are siblings above the scroll region, not inside it).
7. **Truncation.** A very long folder/file name renders on a single line, tail-truncated with an ellipsis; it does not wrap and does not widen or otherwise change the column's width.
8. **Section headers intact (decision 1).** The per-root `Section` headers still show the full `~`-abbreviated path, still head-truncate, and their right-click **Remove from Sidebar / Refresh** menu still works. The top folder bar (names) and the section headers (full paths) coexist without duplication.
9. **Titlebar intact (decision 4).** The window titlebar still shows the open file's name and appends the "Edited" subtitle while the file is dirty, exactly as before; clearing the dirt clears "Edited". (Name appears in both the titlebar and the editor bar; "Edited" only in the titlebar.)
10. **No layout regression (decision, assumption 6).** Sidebar point-width, the editor/preview split fraction, both drag clamps (160–600 pt; 15–85 %), the no-drift baseline behavior, cross-window `@AppStorage` sharing, and relaunch persistence are all identical to the shipped build. Concretely: `defaults read <bundle-id> sidebarWidth` / `editorFraction` before/after are unaffected by the bars, and dragging either divider behaves as before. The bars add vertical content only; they never enter the width math.
11. **Preview has no bar (decisions 5–6).** With a `.md` file open (3 columns), the editor column shows its bar and the preview column shows none; the app does not crash and divider 2 still drags the editor/preview ratio. The editor's text starts one bar-height below the preview's first line — accepted (decision 6).
12. **Live updates (assumption 3).** Adding/removing a root updates the folder bar's text (and hides it when the last root is removed); opening or switching files updates the editor bar's text — with no explicit refresh, driven by the existing `@Published` `roots` / `openFile`.

## Tiers

Each tier compiles via the criterion-1 `xcodebuild` invocation and is independently revertible.

### Tier 1 — Reusable `ColumnHeaderBar` view + one metric (no behavior change)

Independently buildable: adds a self-contained view and one constant; `ContentView` is untouched, so the app runs exactly as it does today (the new view is unused and simply compiles). Revert = delete the new file and the one constant.

**Modify `FEdit/App/FEditApp.swift`** — append one field to the existing `LayoutMetrics` enum (single home for layout constants, SPEC §13):
- `static let columnHeaderHeight: CGFloat = 28` — fixed strip height. `CGFloat` (not storage-backed, like `dividerHitWidth`).

**Create `FEdit/Views/ColumnHeaderBar.swift`** (GPL header copied verbatim from an existing source file) — `struct ColumnHeaderBar: View`:
- API: `let title: String`. No state, no persistence, no visibility logic — the **caller** decides whether to render it (mirrors `SplitDivider` owning no state).
- Body (described, matching split-layout's Tier-1 SplitDivider prose): a `Text(title)` styled `.font(.system(size: 12, weight: .semibold))`, `.foregroundStyle(.primary)`, `.lineLimit(1)`, `.truncationMode(.tail)`, `.frame(maxWidth: .infinity, alignment: .leading)`, `.padding(.horizontal, 8)`, then `.frame(height: LayoutMetrics.columnHeaderHeight)`, `.background(Color(nsColor: .windowBackgroundColor))`, and `.overlay(alignment: .bottom)` a full-width `Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: LayoutMetrics.dividerLineWidth)` (reuses the shipped 1 pt hairline constant) to delineate the strip from the content below. Tail truncation (not head, unlike the section header's `.truncationMode(.head)`) because these are **names**, best read from the start.

### Tier 2 — Wire the two bars into `ContentView`

Revert = restore the `sidebarColumn` / `editorColumn` accessors from Tier 1's commit. `.navigationTitle`/`.navigationSubtitle` are **not** touched in this tier (decision 4).

**Modify `FEdit/Views/ContentView.swift`:**
- **`sidebarColumn`** (currently `SidebarView(workspace: workspace)`): wrap in `VStack(spacing: 0)`; before `SidebarView`, conditionally render the folder bar:
  ```
  VStack(spacing: 0) {
      if !workspace.roots.isEmpty {
          ColumnHeaderBar(title: workspace.roots.map { $0.url.lastPathComponent }.joined(separator: ", "))
      }
      SidebarView(workspace: workspace)
  }
  ```
  The `.frame(width: CGFloat(clampedSidebarWidth))` applied at the HStack call site now sizes the `VStack` — unchanged. The `!roots.isEmpty` guard keeps the bar and `SidebarView`'s empty-state branch consistent (criterion 4). The bar sits above `SidebarView`'s own search field (decision 2).
- **`editorColumn`** (already `VStack(spacing: 0) { if openFile != nil { CodeEditorView } else { Color.white … } }`): add the editor bar as the VStack's first child, guarded so it appears iff a file is open — `workspace.openFileName` is non-`nil` exactly when `openFile != nil`:
  ```
  VStack(spacing: 0) {
      if let name = workspace.openFileName {
          ColumnHeaderBar(title: name)
      }
      if workspace.openFile != nil { CodeEditorView(...) } else { Color.white.overlay(...) }
  }
  ```
  No change to the `.frame(width: editorWidth)` (Markdown) / `.frame(maxWidth: .infinity)` (non-Markdown) applied at the HStack call site — the bar consumes vertical space inside the column and the editor content takes the remainder.
- **`previewColumn`** and the width/divider math (`contentWidth`, `editorWidth`, `clampSidebar`, `clampFraction`, both `SplitDivider`s) are **untouched** (criterion 10, 11).

Manual verification for Tier 2 = acceptance criteria 2–12.

### Tier 3 — SPEC note (docs only)

**Modify `SPEC.md`:**
- **§4 (Layout):** add a bullet: the sidebar and editor columns each carry a fixed-height header strip — the sidebar strip shows the open folder name(s) (each root's last path component, comma-separated), the editor strip shows the open file's name; both are hidden when their column has nothing open; the preview column has no strip.
- **§5.1:** add a sentence noting the sidebar's top strip (folder-name summary) is **distinct from and complements** the per-root section headers (full `~`-path + Remove/Refresh), which are unchanged.
- **§7:** note that the editor column's in-content header strip shows the file name, complementing (not replacing) the window `.navigationTitle`/`.navigationSubtitle`, which continue to show the name plus the "Edited" dirty marker.

Docs only; revert = git revert the SPEC hunk.

## Interface between tiers

- **Tier 1 → 2:** `ColumnHeaderBar(title: String)` — a fixed-height (`LayoutMetrics.columnHeaderHeight`), leading-aligned, single-line, tail-truncated title strip with a subtle background and a bottom hairline; owns no state; shown/hidden entirely by the caller. `LayoutMetrics.columnHeaderHeight: CGFloat`. Tier 2 renders two instances and supplies the two guard conditions (`!roots.isEmpty`; `openFileName != nil`).
- **Tier 2 → 3:** none — SPEC documents the shipped behavior.
- **Contract with the rest of `ContentView`:** the width/divider math, persistence hooks, session-restore `.onAppear`/`.onChange` handlers, `WindowCloseGuard`, and `.navigationTitle`/`.navigationSubtitle` keep their exact shipped semantics. This plan adds vertical content to two columns and nothing else.

## Load-bearing assumptions

Verified against the code read at planning time; names are real:

1. **`WorkspaceModel.roots: [FileNode]`** is `@Published private(set)` (WorkspaceModel.swift L59); **`FileNode.url: URL`** (FileNode.swift L28) so `roots.map { $0.url.lastPathComponent }` yields the folder names. ✅
2. **`WorkspaceModel.openFileName: String?`** is a computed `openFile?.url.lastPathComponent`, `nil` exactly when no file is open (WorkspaceModel.swift L96–98). ✅ — so `if let name = workspace.openFileName` is the correct show/hide guard for the editor bar and matches `openFile != nil`.
3. **Reactivity:** `ContentView` holds `@StateObject private var workspace` (L45); its `body` reading `workspace.roots` / `workspace.openFileName` re-renders on `@Published` change (`roots` L59; `openFile` L74, which `openFileName` derives from). ✅ — criterion 12 needs no extra wiring.
4. **`sidebarColumn`** is `SidebarView(workspace: workspace)` (L178–180) and receives `.frame(width:)` at the HStack call site (L74–75); wrapping it in a `VStack` keeps that outer frame sizing the column. ✅
5. **`editorColumn`** is already a `VStack(spacing: 0)` (L182–212) with the `openFile != nil` branch — the editor bar becomes its first child under the equivalent `openFileName != nil` guard. ✅
6. **Divider/width math is width-only and independent of vertical column content:** `contentWidth` (L64–70), `editorWidth` (L71), `clampSidebar`/`clampFraction`, and the two `SplitDivider` frames (`.frame(maxHeight: .infinity)`) never read column height; adding a vertically-stacked strip cannot alter them. ✅ (criterion 10).
7. **The per-root section header** in `SidebarView.header(for:)` (SidebarView.swift L97–112) renders the full `~`-abbreviated path with `.truncationMode(.head)` and the Remove/Refresh context menu (SPEC §5.1) — separate from and untouched by the new bar. ✅ (criterion 8, decision 1).
8. **`.navigationTitle(workspace.openFileName ?? "FEdit")` / `.navigationSubtitle(... "Edited" ...)`** (ContentView.swift L121–122) set the window titlebar per SPEC §7 and are left intact. ✅ (criterion 9, decision 4).
9. **`LayoutMetrics`** is the shipped single home for layout constants in `FEditApp.swift` (L109–119) and already carries `dividerLineWidth: CGFloat = 1` (L118), reused for the bar's bottom hairline. Adding `columnHeaderHeight` there matches convention. ✅
10. **Reusable-view + one-view-per-file convention** is established by `SplitDivider.swift` (split-layout); `ColumnHeaderBar.swift` follows it. No existing type is named `ColumnHeaderBar` (grep: only `.navigationTitle`/`.navigationSubtitle` reference title chrome today). ✅
11. **`FEdit/` is a file-system-synchronized group** (split-layout assumption): creating `FEdit/Views/ColumnHeaderBar.swift` on disk adds it to the target with no `.xcodeproj` edit. ✅ (relied on by every prior added file).
12. **Test posture:** `scripts/*Tests` are swiftc pure-logic harnesses that cannot instantiate SwiftUI views; verification is manual + `xcodebuild`, per the split-layout / open-folder-new-window precedent. ✅

## Out of scope

- **A preview-column header bar** — the TODO scopes the feature to the folder + editor columns; the resulting editor/preview top offset is accepted (decision 6).
- **A dirty / "Edited" indicator in the in-content bars** — stays in `.navigationSubtitle` (decision 3); the bars show the name only.
- **Any interactivity on the bars** — no context menu, no click, no reveal-in-Finder; Remove/Refresh stays on the per-root section headers.
- **Removing or altering** the per-root section headers, the sidebar search field, or `.navigationTitle`/`.navigationSubtitle`.
- **Icons / file-type glyphs** in the bars (name text only, per the TODO).
- **Persisting bar state**, collapse/expand, hover affordances, or show/hide animation — not requested; the bars are static derived views.
- **New `UserDefaults`/`@SceneStorage` keys, model changes, or scanner/filter/editor/renderer changes.**

## Auto-resolved (recorded decisions & tensions)

- **Double-header risk (decision 1) — RESOLVED by keeping them distinct.** The top folder bar (name summary, one fixed strip, non-interactive) and the per-root section headers (full `~`-paths, inline+scrolling, Remove/Refresh menu, SPEC §5.1) serve different roles and stay side by side. Section headers are **not** removed; the bar is **not** made interactive.
- **`.navigationTitle` replace-vs-complement (decision 4) — RESOLVED as COMPLEMENT / leave-as-is.** Replacing would regress SPEC §7's titlebar name + "Edited" marker (the bars intentionally omit "Edited"); leaving them untouched yields zero regression risk. Accepted redundancy: the name shows in both the titlebar and the editor bar.
- **Editor bar present, preview bar absent (decision 6) — ACCEPTED, recorded.** In the Markdown split the editor text sits one bar-height below the preview's first line. A blank strip over the preview to realign would be a worse artifact and is excluded by the TODO scope.
- **Single-root visual overlap — ACCEPTED.** Folder bar `FEdit` over a section header `~/…/FEdit` is a name-over-full-path pattern, not a duplicate; the section header additionally carries the full path and the context menu.
- **Per-render string allocation** — `roots.map{…}.joined(...)` builds a small string each `ContentView` render; at the handful-of-roots scale this is negligible (SPEC §11 accepts synchronous linear sidebar work). Accepted, not cached.
