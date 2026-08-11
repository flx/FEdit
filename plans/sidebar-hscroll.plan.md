# sidebar-hscroll

**Risk tier:** standard — the chosen approach (line-wrap) is a *removal* of two modifiers (`.lineLimit(1)`, `.truncationMode(.tail)`) plus a small `HStack` alignment tweak, all confined to `FileRow` in `FEdit/Views/SidebarView.swift`. No `List`/`ScrollView` restructuring, no `OutlineGroup`/selection/gesture changes, no concurrency, no model/state/persistence change. Variable-height `List` rows are fully supported by SwiftUI; trivially buildable and revertible.

## Decision (resolved with the user, /ship-all gate)

The TODO deferred the truncation-vs-scroll call to this plan and asked for horizontal scroll. Resolution, after two decision rounds with the user:

1. A real horizontal scroller (wrapping the sidebar `List` in a `ScrollView(.horizontal)`) is **rejected as too fragile** — it touches `List` row-width contracts, `OutlineGroup` disclosure/indent geometry, the full-width selection pill, and row tap-gesture ownership, with no unit-test harness to catch a regression (it would be `hi` tier). See **## Rejected alternatives**.
2. The user proposed **line-wrap** as the fallback, and chose **"wrap fully."**

**Chosen — wrap the row's name to as many lines as needed.** Over-wide `FileRow` labels stop truncating; the `Text` wraps and the `List` row grows to fit, so the complete name (tree mode) or complete relative path (filter mode, where tail-truncation was worst because it cut the trailing filename) is always visible with no hover and no scroll. This is robust because it changes nothing about `List`/`OutlineGroup`/selection/gesture handling — it only relaxes a per-`Text` line limit and lets the row size to content.

*Accepted tradeoff:* rows become variable-height, so long filter-mode paths take 2–3 lines and the list is less dense/uniform than the single-line layout `sidebar-row-density` tuned. The `defaultMinListRowHeight: 20` floor is unchanged, so short rows (the common case, especially tree mode) look exactly as they do today; only over-wide rows grow.

## Goal

SPEC §5.3 (tree mode) and §5.4 (filter mode) rows currently tail-truncate when a row's content is wider than the fixed sidebar column (§4, 160–600 pt). In filter mode the label *is* a root-relative path, so tail truncation cuts the trailing filename/extension — the part the user most needs. Make over-wide rows **wrap to multiple lines** instead of truncating, so the full name is readable in place. Keep the vertical `List`, selection highlight, `OutlineGroup` disclosure, `.inset` density floor, and the `(changed)` badge all working; the fixed folder-name top strip (§4) and per-root section headers (§5.1, head-truncated) stay put and unchanged.

## Acceptance criteria

1. **Full name readable via wrap.** A `FileRow` whose label is wider than the sidebar column wraps to multiple lines and shows the complete text — in tree mode the file's own name, in filter mode the full root-relative path (e.g. `swift-source/nested/deep/main.swift`) — with no hover and no horizontal scroll. The row grows in height to fit.
2. **Vertical `List` scroll unaffected.** Scrolling up/down works exactly as before; no horizontal scroller is introduced anywhere.
3. **Selection/highlight unaffected.** Clicking a file row still calls `workspace.requestOpen(node.url)`; the `RoundedRectangle` selection pill (`.frame(maxWidth: .infinity)` + `.padding(.vertical, 2)`, applied as the row's `.background`) covers the full **taller** wrapped row, since it backs the framed `HStack` and sizes to its content.
4. **`OutlineGroup` disclosure unaffected.** Expand/collapse, per-depth indent, and the disclosure triangle work unchanged — variable-height rows are supported; no `List`/`ScrollView` wrapping changes.
5. **Fixed strip + search field + section headers stay put.** The top folder-name strip (`ColumnHeaderBar` in `ContentView.swift`, out of scope, untouched) and the `searchField` (in `SidebarView.swift`, above the `List`) are unaffected. Per-root section headers (`header(for:)`) keep their existing **head**-truncation and Remove/Refresh context menu — headers are **not** switched to wrap (the head-truncated `~`-path already keeps its meaningful tail visible; wrapping full absolute paths would be noisy).
6. **`(changed)` badge preserved.** The badge stays at the trailing edge and is never clipped or truncated. With a multi-line name, the row `HStack` is **top-aligned** (`HStack(alignment: .top)`) so the icon and the badge sit beside the first line of the wrapped name rather than centered against the tall text block. The badge keeps its own `.lineLimit(1)` + `.fixedSize()` (the badge itself never wraps).
7. **`.inset` style + row-height density preserved.** `.listStyle(.inset)` and `.environment(\.defaultMinListRowHeight, 20)` are untouched. The 20 pt floor still applies; only rows wider than the column grow beyond it. Short rows are visually unchanged.
8. **Folder rows wrap consistently.** Directory rows today are a bare `HStack { Image(systemName: "folder"); Text(label) }` with **no** `.lineLimit`/`.truncationMode`, so a long folder name already wraps; this plan top-aligns that `HStack` too (`HStack(alignment: .top)`) so a wrapped folder name aligns its icon to the first line, matching file rows.
9. **Build succeeds.** `xcodebuild -scheme FEdit -destination 'platform=macOS' build` succeeds after each tier.

## Tiers

Each tier is independently buildable and revertible.

### Tier 1 — wrap file rows

- **Modify `FileRow`'s file branch** (`SidebarView.swift`, the `else` of `if node.isDirectory`, currently lines ~140–177):
  - **Remove** `.lineLimit(1)` and `.truncationMode(.tail)` from `Text(label)` (the file-name text, ~lines 146–147). Keep its `.foregroundStyle(...)`.
  - **Change** the outer `HStack {` (~line 141) to `HStack(alignment: .top) {` so the 16×16 icon and the trailing `(changed)` badge align to the first line of a wrapped name.
  - **Do not touch:** the icon, `Spacer(minLength: 6)`, the badge's `.lineLimit(1)`/`.fixedSize()`/`.font`, `.frame(maxWidth: .infinity, alignment: .leading)`, `.padding(.vertical, 2)`, `.contentShape(Rectangle())`, `.onTapGesture`, the selection `.background`, `isSelected`, `isChanged`.
- Revert = re-add the two modifiers and change the `HStack` back to center alignment.

Verification: acceptance criteria 1 (file rows), 2, 3, 6, 7, 9.

### Tier 2 — folder-row alignment parity

- **Modify `FileRow`'s directory branch** (`SidebarView.swift`, the `if node.isDirectory` branch, ~lines 135–139): change `HStack {` to `HStack(alignment: .top) {`. No `.lineLimit`/`.truncationMode` is added — folder names should wrap (they already do, since the branch has no line limit); this only fixes icon alignment for a wrapped folder name. The folder icon and the disclosure-only (no-tap) behavior are otherwise unchanged.
- Revert = restore `HStack {`.
- Independent of Tier 1 (different `if`/`else` branch). Grouped here for locality.

Verification: acceptance criteria 4, 8, 9.

### Tier 3 — SPEC.md wording

Docs only; revert = git-revert the SPEC hunk.

- **§5.3 (tree mode):** add a sentence — a file or folder row whose name is wider than the sidebar column **wraps to multiple lines** (rather than truncating); the row grows to fit so the full name is readable.
- **§5.4 (filter mode):** add a sentence — a flat-mode row's relative path likewise wraps to multiple lines when wider than the column, so the full relative path (including the trailing filename) stays readable; this is the primary case, since single-line tail truncation would cut the filename.
- **§5.6 (git badge) — REQUIRED update:** the current clause reads *"A long file name truncates (tail) before the badge is clipped; the badge is never truncated."* Since long names now **wrap** instead of truncating, reword to: *"A long file name **wraps to multiple lines**; the badge stays at the trailing edge of the row (aligned to the first line) and is never clipped or truncated."* (This is the one SPEC clause outside §5.3/§5.4 the wrap change forces; the tooltip approach would have left it alone — flagged and handled.)
- Do not touch §5.1 (section headers remain head-truncated, criterion 5).

## Interface between tiers

- **Tier 1 → Tier 2:** none functionally (different branch of the same `FileRow.body`); either can ship alone.
- **Tier 1/2 → Tier 3:** SPEC documents the shipped wrap behavior; no code reads SPEC, so no downstream code dependency.
- **External contract:** no type, signature, `@Published` property, `UserDefaults`/`@AppStorage` key, or public API change. The only observable change is that over-wide rows wrap (grow taller) instead of tail-truncating. Nothing downstream (`ContentView.swift`, `WorkspaceModel`, session-restore, git-changed-badge) depends on `FileRow`'s single-line-ness.

## Load-bearing assumptions (real symbols)

- **`FileRow` as read for this plan** (`SidebarView.swift` L127–190): file branch (L140–177) computes `label` (L132, `displayText ?? node.name`), applies `.lineLimit(1)` + `.truncationMode(.tail)` (L146–147) to `Text(label)`, a trailing `Spacer(minLength: 6)` (L154) + optional `(changed)` badge (L155–161), `.frame(maxWidth: .infinity, alignment: .leading)` (L163), `.padding(.vertical, 2)` (L167), `.contentShape` + `.onTapGesture` (L168–171), and the selection `RoundedRectangle` `.background` (L172–176). The directory branch (L135–139) is a bare `HStack { Image(systemName: "folder"); Text(label) }` with **no** `.lineLimit`/`.truncationMode`/`.frame` — confirmed by reading the shipped file.
- **SwiftUI `List` supports variable-height rows**; removing a `Text`'s `.lineLimit(1)` lets it wrap and the row grows to fit. This is standard, well-supported behavior (unlike horizontal scroll inside `List`), which is why the chosen approach is `standard` tier.
- **The selection pill is a `.background` of the framed `HStack`**, so it sizes to the (now taller) row automatically — no width/height math needed.
- **No test harness exists for `SidebarView`** — the repo's `scripts/*Tests` swiftc harnesses are pure-logic (`FileNode`, `FilterQuery`, snapshot JSON) and cannot instantiate SwiftUI views. Verification is manual (see below), matching the posture of column-header-bars/split-layout/sidebar-row-density.

## Manual verification (no view test harness)

Build via `xcodebuild -scheme FEdit -destination 'platform=macOS' build`, run the app, then:
1. Open a folder containing a deeply nested file with a long name (or a top-level file with a long filename) → in tree mode, expand to it and confirm the name **wraps** to multiple lines and is fully readable (no ellipsis).
2. Type a filter query that matches a deeply nested file → in filter mode, confirm the full relative path wraps and is fully readable.
3. Confirm the vertical list still scrolls, clicking a row still selects/highlights (pill covers the full wrapped row) and opens the file, and folder disclosure still expands/collapses.
4. In a git root, confirm a modified file's `(changed)` badge still shows at the trailing edge, uncut, beside the first line of a wrapped name.
5. Confirm short rows are unchanged (still single-line at the 20 pt density).

## Auto-resolved (decision + adv-review-plan folds, /ship-all autonomy policy)

- **Open decision (truncation vs scroll) — resolved with the user.** Horizontal scroll rejected as `hi`-risk/fragile; user chose **wrap fully**. This plan was rewritten from the earlier tooltip draft to the line-wrap approach accordingly.
- **New finding caught during re-plan:** SPEC §5.6's badge clause references tail-truncation and MUST be updated for wrap (Tier 3) — the tooltip draft had explicitly left §5.6 untouched.
- **Skipped a second plan-review round (deliberate):** the wrap approach is a strict simplification of an already-reviewed file whose structural facts (line numbers, modifier presence, badge/pill/density layout) were verified by the first adv-review-plan pass; the implement-time `adv-review-behavior` + `adv-review-edge` on the actual diff is the stronger gate for a change this concrete. Recorded here for audit.
- **Prior-draft findings, now resolved/mooted by the approach change:** D1 (`.help()` placement) — moot, no tooltip. D2 (verify `.help()` renders) — moot. T1 (tooltip vs literal scroll) — superseded by the wrap decision. T2 (folder-row parity scope) — folders already wrap; Tier 2 reduced to an alignment tweak. T3 (tooltip on all rows) — moot. Nit ("both"/three-tiers wording) — this plan states three tiers correctly.

## Out of scope

- **Actual horizontal scrolling of the sidebar list** — rejected (`hi` tier); not built.
- **Hover tooltips (`.help()`)** — superseded by wrap; not added (wrap makes the full name visible without hover, so a tooltip would be redundant).
- **Section header (`header(for:)`) changes** — headers stay head-truncated per §5.1; not switched to wrap.
- **The column's top folder-name strip (`ColumnHeaderBar`)** in `ContentView.swift` — untouched.
- **Capping the wrap** (e.g. `.lineLimit(2)` + truncate/tooltip for the remainder) — considered as a density-preserving middle option and not chosen; the user picked full wrap.
- **Any change to `WorkspaceModel`, `FileNode`, `FilterQuery`, `ContentView.swift`, or any file other than `SidebarView.swift` and `SPEC.md`.**
