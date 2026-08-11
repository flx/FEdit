# sidebar-row-density

**Risk tier:** standard — a pure SwiftUI layout tweak confined to `Views/SidebarView.swift`; no concurrency, no algorithms, no state/model change, no persisted contract, and it is trivially buildable and revertible (delete one modifier, optionally one more). The only non-obvious hazard is misaligning the `OutlineGroup` disclosure indentation, which is fenced off by making the row-height lever primary and the inset lever optional-behind-a-visual-gate.

## Goal

Tighten the folder-tree file rows in the sidebar so they read as compact, roughly single-line rows instead of the current ~one-extra-blank-line gap that makes the sidebar feel sparse (see the reference screenshot: files sit almost a full line apart). The sparseness is **not** caused by any padding in `FileRow` — the shipped `FileRow` (SidebarView.swift L120–156) has *no* explicit vertical padding and *no* frame height; its only sizing is the 16×16 file-icon `.frame` and the `Text`. The extra vertical space is contributed entirely by the SwiftUI `List`'s **default minimum row height** floor, which is well above the ~16–17 pt intrinsic content height of a 16 px icon + 13 pt label. The fix lowers that floor on the `List` (`.environment(\.defaultMinListRowHeight, 20)`) and, only if still needed after that, applies a tight vertical `listRowInsets` — while leaving the disclosure triangles, per-depth tree indentation, the full-width rounded selection highlight, and row clickability exactly as shipped. The change must keep tree mode (§5.3) and filtered flat mode (§5.4) visually consistent, which is automatic because both reuse the same `List` and the same `FileRow`.

## Chosen levers & target values (pinned)

Concrete, in `Views/SidebarView.swift` only:

1. **Primary (sufficient on its own): `.environment(\.defaultMinListRowHeight, 20)` on the `List`** (the `List { … }` at L43–57, applied adjacent to `.listStyle(.sidebar)` at L58). Target **20 pt**: the file row's intrinsic content is a 16×16 icon and a 13 pt label (line height ≈ 16–17 pt), so a 20 pt floor yields a snug single-line row with ~1–2 pt of breathing room, and — crucially — a 20 pt tap/selection target, which stays comfortably clickable. This lever changes only the row-height *floor*; it touches no insets, so it **cannot** move the disclosure triangles, the per-level indentation, or the selection-highlight geometry. Rows whose content is naturally taller than 20 pt (e.g. section headers) are unaffected because the env value is a *minimum*, not a fixed height.

2. **Secondary (optional, behind a visual gate): tight vertical `listRowInsets` on `FileRow`.** If, after lever 1, the rows still show visible extra vertical gap, apply `.listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 8))` to `FileRow`'s root view (so it applies uniformly in both the `OutlineGroup` tree closure at L47–49 and the flat `ForEach` at L80–82). **Vertical values (top/bottom = 2) are the point of this lever; the horizontal values are the hazard.** The `leading` is set to 0 **only** on the working assumption — to be visually verified (see acceptance criterion 2 and load-bearing assumptions) — that `OutlineGroup` renders the disclosure triangle and the per-depth indent in the outline cell *outside* the `FileRow` content box, so a 0 leading trims only the small gap between the indent region and the icon, not the tree indentation itself. If verification shows the triangles clip or the tree flattens, **drop this lever entirely** and ship lever 1 alone (lever 1 already meets the Goal); do **not** try to "rescue" it by guessing a leading value.

3. **No `FileRow` padding/frame change.** There is no vertical padding or frame height in `FileRow` to trim (confirmed against the shipped file); the 16×16 icon frame stays. Do not add negative padding or a fixed row `.frame(height:)` — the height reduction comes from the `List`-level levers above, not from squeezing `FileRow`.

4. **Section headers and "No matches" and flat-mode rows: no special-casing.** All live in the same `List`, so lever 1's floor applies to them uniformly, keeping the whole sidebar consistent (§5.4). Headers carry more content and generally sit above the 20 pt floor, so they keep their natural height; the "No matches" `Text` (L77) tightens along with file rows, which is desirable. `FileRow` is reused verbatim for the flat filtered list (via `displayText`, L81), so any `FileRow`-level inset from lever 2 lands in both modes automatically — tree/flat consistency is free.

## Acceptance criteria

1. **Rows are visibly tighter.** After the change, file rows in tree mode sit roughly a single line apart (icon-to-icon vertical pitch ≈ 20–22 pt), not the ~full-extra-line gap in the current build. Compared side-by-side with the pre-change build, the sidebar shows meaningfully more files in the same height.
2. **Disclosure + indentation intact.** Every folder still shows its disclosure triangle; the triangles are not clipped and are vertically centered in their (now shorter) rows; expanding/collapsing still works; each nesting level is still indented from its parent by the same tree indentation as before. This is the gate for lever 2: if applying `listRowInsets` collapses or misaligns the indentation or clips a triangle, lever 2 is reverted and only lever 1 ships (which by construction does not affect indentation).
3. **Selection highlight intact.** Clicking a file still paints the full-width rounded selection background (the `RoundedRectangle(cornerRadius: 4)` fill in `FileRow`, L146–149) across the row; the highlight spans the row's full width (`.frame(maxWidth: .infinity)` preserved) and its height matches the new compact row (no gap of unhighlighted space above/below within the row).
4. **Clickable / hit target preserved.** The whole file row remains tappable (`.contentShape(Rectangle())` + `.onTapGesture`, L142–145, unchanged); the effective hit height is ≥ 20 pt (the new floor), which stays comfortably usable. Folder rows still toggle via the disclosure control as before.
5. **Tree and flat modes consistent.** With a non-empty filter (flat mode, §5.4), the matching-file rows show the same compact density as tree mode — no visible density mismatch when toggling the filter on/off.
6. **No behavior/functional change.** Selection semantics (only files selectable), open-on-tap, header context menu (Remove/Refresh), the search field, and the empty-state button are byte-for-byte unchanged. `xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Debug -derivedDataPath build build` succeeds. No other file is modified.

## Tiers

One tier — the change is a couple of view modifiers in a single file, buildable and revertible on its own; splitting it would be artificial.

### Tier 1 — tighten row density in SidebarView.swift

Buildable/revertible unit: revert = remove the `.environment(\.defaultMinListRowHeight,)` modifier (and the `listRowInsets` modifier if lever 2 was applied). App returns to the current sparse rows with no other effect.

- **Modify `FEdit/Views/SidebarView.swift`, `List` at L43–57:** add `.environment(\.defaultMinListRowHeight, 20)` on the `List` (next to `.listStyle(.sidebar)` at L58). Do not change the `ForEach`/`Section`/`OutlineGroup`/`flatRows` structure.
- **Conditionally modify `FileRow` (L120–156):** *only if* criterion 1 is not yet met by the env lever, add `.listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 8))` to `FileRow`'s returned root view (applies to both the directory `HStack` and the file `HStack`, so tree and flat rows match). Then run the criterion-2 visual gate; if it fails, remove this modifier and ship the env lever alone.
- **Do not touch:** `searchField` (L63–67), `flatRows` logic (L74–84), `emptyState` (L86–95), `header(for:)` and its context menu (L97–112), the `FileRow` selection `.background`, `.contentShape`, `.onTapGesture`, the 16×16 icon `.frame`, the `isSelected` computation, `WorkspaceModel`, `FileNode`, or any other file.

Verification for the tier = acceptance criteria 1–6 (run the app, load a folder with nested directories, eyeball density + triangles + indentation, click a file to confirm the highlight and open, toggle a filter to confirm flat-mode parity, confirm the header context menu still works).

## Interface between tiers

Single tier — no inter-tier interface. The only external contract touched is the rendered appearance of the sidebar `List`; no type, signature, storage key, `@SceneStorage`/`@AppStorage` value, or public API changes, so nothing downstream (ContentView layout, WorkspaceModel, session restore) observes the change.

## Load-bearing assumptions (real symbols)

- **`Views/SidebarView.swift` is as read for this plan:** the `List` at L43–57 with `.listStyle(.sidebar)` at L58; `OutlineGroup(root.children ?? [], children: \.children) { node in FileRow(node:workspace:) }` at L47–49; the flat `ForEach(matches, id: \.node.id) { … FileRow(node:workspace:displayText:) }` at L80–82; and `FileRow` (L120–156) with the directory branch `HStack { Image(systemName: "folder"); Text(label) }` (L128–132) and the file branch carrying the 16×16 `Image`, `.frame(maxWidth: .infinity, alignment: .leading)`, `.contentShape(Rectangle())`, `.onTapGesture`, and the `RoundedRectangle` selection `.background` (L133–150). `FileRow` has **no** explicit vertical padding and **no** frame height — verified — so the `List` min-row-height floor is the dominant driver of the current gap.
- **`\.defaultMinListRowHeight` is an `EnvironmentValues` key** on macOS 26 / SwiftUI that sets the *minimum* row height for the `List`; lowering it lets rows shrink toward their intrinsic content height without forcing rows whose content is taller. This is the crux of lever 1 and why it cannot disturb indentation or headers.
- **`OutlineGroup` owns the disclosure triangle and per-depth indentation itself** (inside the outline cell), independent of `defaultMinListRowHeight`. Lever 1 therefore provably leaves indentation/triangles untouched. Lever 2's `leading: 0` rests on the further assumption that this indentation is applied *outside* the `FileRow` content box; **this specific assumption is the one thing lever 2 must visually verify** (criterion 2), with the documented fallback of dropping lever 2 if it proves false — which is safe because lever 1 alone satisfies the Goal.
- **`.listStyle(.sidebar)` stays**; the density levers are layered on top and do not change the sidebar list style, the selection model, or the header/section rendering.
- **SPEC §5.3 (tree) and §5.4 (filter/flat) mandate no specific row spacing** — confirmed by reading SPEC.md; they require disclosure triangles, folder/file icons, "only files selectable," open-file highlight, and the flat relative-path list, all of which are preserved. Tightening density is not constrained by the spec.
- **Target 20 pt clears the usability floor** for a mouse-driven file list (icon 16 px + 13 pt label ≈ 16–17 pt content; 20 pt leaves the row clickable and the highlight full-height). If 20 pt reads too cramped in practice, the value may be nudged within the 18–22 pt band without any structural change — the lever is a single numeric constant.
- `xcodebuild` builds this target as in sibling plans (file-system-synchronized `FEdit/` group; no `project.pbxproj` edit needed since no file is added).

## Out of scope

- **Any functional/behavior change:** selection semantics, open-on-tap, the header Remove/Refresh context menu, the filter field and query language (§5.5), the empty-state button, scanning/refresh — all unchanged.
- **Any other file:** `ContentView.swift`, `WorkspaceModel.swift`, `FileNode.swift`, `FilterQuery.swift`, `FEditApp.swift`, editor/preview code — untouched. The diff is `Views/SidebarView.swift` only.
- **Restyling beyond density:** no font change, no icon-size change (the 16×16 file icon stays), no indentation-width change, no custom disclosure control, no row-hover styling, no `.listRowSeparator`/background restyle, no section-header redesign.
- **Making folder rows selectable or changing the folder-row hit behavior** — folders still toggle via the disclosure control only, per §5.3.
- **Automated UI/snapshot tests** — the project has no UI test target; verification is manual per the acceptance criteria, consistent with sibling plans.
