# split-layout

**Risk tier:** standard — pure SwiftUI layout plumbing with simple clamping arithmetic; no concurrency, no algorithms, blast radius limited to `ContentView.swift`, one new view file, and additive constants in `FEditApp.swift`.

## Goal

Implement the SPEC §4 three-column window skeleton: sidebar | editor | (optional) Markdown preview, separated by two draggable dividers. Divider 1 sets the sidebar width in points (default 1100/3 ≈ 366.7 pt, clamped 160–600 pt). Divider 2 sets the editor's fraction of the non-sidebar width (default 0.5 → 1/3·1/3·1/3 overall, clamped 15–85 %). Both positions persist globally via `@AppStorage` (`UserDefaults`), are shared across all windows, and survive relaunch. The preview column exists iff a stub `isMarkdown` flag is on (real detection arrives with (open-save)). The sidebar width never changes when the preview appears/disappears. Dividers have a 5 pt hit area, a thin visible separator line, and show the `resizeLeftRight` cursor on hover. Columns themselves are placeholders — their content is delivered by later items.

## Acceptance criteria — concrete and testable

1. `xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Debug -derivedDataPath build build` succeeds after each tier (project convention, empirically verified during plan review: no scheme file exists on disk, but xcodebuild auto-synthesizes scheme `FEdit` from the target; `-target` cannot be combined with `-derivedDataPath`).
2. Fresh state (`defaults delete <bundle-id>` first), stub off: window shows sidebar ≈ 366.7 pt wide and editor filling the rest; no preview column.
3. Turning the stub `isMarkdown` toggle on at defaults shows three columns of visually equal width (each ≈ 1/3 of the window minus divider widths); turning it off removes the preview and gives its width back to the editor only. Sidebar invariance is verified by (a) `defaults read <bundle-id> sidebarWidth` being identical before/after the toggle and (b) the by-construction argument in Tier 2 (sidebar width appears in neither branch of the fraction math).
4. Dragging divider 1 resizes the sidebar continuously; it stops hard at 160 pt (dragging further left does nothing) and at 600 pt (further right does nothing). Releasing and re-grabbing does not jump.
5. With the preview visible, dragging divider 2 changes the editor/preview ratio; the editor width never goes below 15 % or above 85 % of `contentWidth` (defined in Tier 2 — the fraction's render denominator; the drag math uses the same denominator).
6. After dragging both dividers to non-default positions: `defaults read <bundle-id> sidebarWidth` / `... editorFraction` before Cmd+Q, then relaunch and re-read — values identical pre-quit vs post-relaunch, and the rendered layout matches them.
7. Open a second window (Cmd+N) and enable the stub `isMarkdown` toggle in both windows (precondition for the divider-2 half): both show the same divider positions; dragging a divider in one window live-updates the other (shared `@AppStorage`).
8. Hovering either divider changes the cursor to `resizeLeftRight`; leaving it restores the arrow.
9. Resizing the window preserves the sidebar's point width (editor/preview absorb the change per the stored fraction); shrinking to the 700×400 minimum does not crash or produce negative frames.

## Tiers

### Tier 1 — Settings keys + reusable divider view (no behavior change)

Independently buildable: adds two self-contained pieces; `ContentView` is untouched, app runs exactly as after (xcode-scaffold). Revert = delete the new file and the constants block.

**Modify `FEdit/App/FEditApp.swift`** — append (GPL header already present):
- `enum SettingsKey` with `static let sidebarWidth = "sidebarWidth"` and `static let editorFraction = "editorFraction"` (string constants only; this enum is the single home for all future `UserDefaults` keys per SPEC §13 "settings keys").
- `enum LayoutMetrics` — a top-level enum in FEditApp.swift (decided; not nested) so ContentView has no magic numbers. All storage-backed values are `Double` (not CGFloat) to avoid cast noise at the `@AppStorage` boundary: `defaultWindowWidth: Double = 1100`, `defaultSidebarWidth: Double = 1100.0/3.0`, `sidebarMin: Double = 160`, `sidebarMax: Double = 600`, `defaultEditorFraction: Double = 0.5`, `editorFractionMin: Double = 0.15`, `editorFractionMax: Double = 0.85`, `dividerHitWidth: CGFloat = 5`, `dividerLineWidth: CGFloat = 1`.

**Create `FEdit/Views/SplitDivider.swift`** (GPL header) — `struct SplitDivider: View`:
- API: `let onDrag: (CGFloat) -> Void` (cumulative horizontal translation since drag start, in pt) and `let onDragEnded: () -> Void`.
- Body: a `ZStack` — centered 1 pt `Rectangle` filled with `Color(nsColor: .separatorColor)` — given `.frame(width: LayoutMetrics.dividerHitWidth)`, `.frame(maxHeight: .infinity)`, `.contentShape(Rectangle())` so the full 5 pt strip is hittable.
- `.gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { onDrag($0.translation.width) }.onEnded { _ in onDragEnded() })`.
- `.onHover { inside in inside ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }` for the hover cursor. (Known SwiftUI wart: a `pop` can be missed if the view disappears mid-hover; acceptable for v1, note in a comment.)
- SplitDivider owns no state and no persistence — clamping and storage live entirely in ContentView.

### Tier 2 — Three-column layout, clamped drag logic, persistence, stub flag

Revert = restore the placeholder `ContentView.swift` from tier 1's commit.

**Rewrite `FEdit/Views/ContentView.swift`** (keep GPL header):
- Storage: `@AppStorage(SettingsKey.sidebarWidth) private var sidebarWidth: Double = LayoutMetrics.defaultSidebarWidth` and `@AppStorage(SettingsKey.editorFraction) private var editorFraction: Double = LayoutMetrics.defaultEditorFraction`. `@AppStorage` on `standard` defaults gives both persistence and cross-window live sharing for free.
- Drag baselines: `@State private var sidebarDragBase: Double?` and `@State private var fractionDragBase: Double?`. On the first `onDrag` callback of a gesture the current stored value is captured into the baseline (`?? current`), each subsequent callback writes `clamp(base + translation)` (for divider 2: `clamp(base + translation / nonSidebarWidth)`); `onDragEnded` clears the baseline. This makes clamping absolute — dragging past a stop and back does not accumulate drift (criterion 4).
- Stub: `@State private var isMarkdown = false` plus a small temporary `Toggle("Markdown preview (stub)", isOn: $isMarkdown)` placed in the editor placeholder column, commented `// TODO(open-save): replace stub with real language detection from the open file`. Per-window `@State` is intentional (each window will later have its own open file).
- Layout: `GeometryReader { geo in HStack(spacing: 0) { ... } }`. **The editor's frame modifier is branch-dependent** — this is load-bearing, not stylistic:
  - preview shown (`isMarkdown`): `sidebarColumn.frame(width: sidebar); SplitDivider(...); editorColumn.frame(width: editorWidth); SplitDivider(...); previewColumn.frame(maxWidth: .infinity)`
  - preview hidden: `sidebarColumn.frame(width: sidebar); SplitDivider(...); editorColumn.frame(maxWidth: .infinity)` — the editor must NOT get a fixed `.frame(width:)` in this branch or it pins to `contentWidth * editorFraction` and leaves dead space (fails criteria 2 and 3).
  - Width math: `contentWidth = max(0, geo.size.width - CGFloat(sidebarWidth) - dividerHitWidth - (isMarkdown ? dividerHitWidth : 0))`. **Definition: `nonSidebarWidth ≡ contentWidth`** — the drag math for divider 2 (`clamp(base + translation / contentWidth)`) and the render math (`editorWidth = contentWidth * editorFraction`) use this same denominator, so a Δ pt drag moves the divider Δ pt and the 15/85 % clamp matches criterion 5 exactly.
  - Negative-frame safety (criterion 9) comes from `max(0, ...)` on `contentWidth` plus `max(0, editorWidth)`; no separate `effectiveSidebar` render guard (at the 700 pt window minimum with a 600 pt sidebar the guard is unreachable — dead code cut per plan review).
- Column placeholders: three `Group`s with distinct light background tints (`Color(nsColor: .windowBackgroundColor)` variants) and centered secondary-text labels "Sidebar", "No file open", "Preview" — deliberately minimal, replaced by (folder-sidebar), (editor-core), (markdown-preview).
- Private helpers `clampSidebar(_:) -> Double` (160…600) and `clampFraction(_:) -> Double` (0.15…0.85) so the clamp constants are applied in exactly one place each.

Manual verification for tier 2 = acceptance criteria 2–9.

## Interface between tiers

- `SplitDivider(onDrag: (CGFloat) -> Void, onDragEnded: () -> Void)` — tier 2 consumes exactly this two-callback shape; `onDrag` receives cumulative translation (not deltas), which is what the baseline-capture logic in ContentView is written against. Changing to per-event deltas would silently break clamping behavior — don't.
- `SettingsKey.sidebarWidth` / `SettingsKey.editorFraction` string values are the persisted contract; once shipped they must never be renamed (relaunch restore, criterion 6, depends on them). Later items add their own keys to the same enum.
- `LayoutMetrics` constants are the single source for defaults/clamps; tier 2 and any future layout code read them rather than re-deriving 1100/3.

## Load-bearing assumptions

From (xcode-scaffold), expected to have shipped:
- `FEdit.xcodeproj` exists, builds via `xcodebuild`, and uses a **file-system-synchronized group** for `FEdit/` — creating `FEdit/Views/SplitDivider.swift` on disk adds it to the target with no project-file edit.
- `FEdit/App/FEditApp.swift` exists containing the `@main` app with a `WindowGroup` presenting `ContentView()`, default window size 1100×700, minimum 700×400, light-only appearance. The 1100 default is what makes `1100/3` the correct sidebar default; if scaffold shipped a different default width, `LayoutMetrics.defaultWindowWidth` must match it.
- `FEdit/Views/ContentView.swift` exists as a placeholder that this item may fully rewrite.
- GPL header boilerplate convention established by the scaffold applies to `SplitDivider.swift`; copy the header verbatim from an existing source file.
- Target is macOS 26, Swift 5 mode, SwiftUI + AppKit available (`NSCursor`, `NSColor.separatorColor`).
- No existing type named `SettingsKey`, `LayoutMetrics`, or `SplitDivider` (repo has no other code yet).
- Cmd+N multi-window works (needed for criterion 7).
- The 700×400 minimum-size `.frame(minWidth:minHeight:)` is applied in **FEditApp.swift** (on `ContentView()` inside the `WindowGroup`), NOT inside ContentView's body — verify before rewriting ContentView, since criterion 9 depends on the floor surviving the rewrite. If the scaffold put it inside ContentView, re-apply it in the rewritten body.

## Auto-resolved (plan review)

DEFECT fold-ins: acceptance criterion 1 rewritten to the scheme-less `-target` invocation; Tier 2 layout sketch made explicitly branch-dependent (editor gets `maxWidth: .infinity` when no preview); `nonSidebarWidth` defined ≡ `contentWidth` so drag and render share one denominator; dead `effectiveSidebar` render guard cut (criterion 9 now attributed to `max(0,...)` clamps); criterion 7 gained the enable-stub-in-both-windows precondition; criteria 3/6 gained concrete measurement methods (`defaults read` pre/post).

TENSION resolutions: (a) cursor may flick to arrow when the pointer leaves the 5 pt strip mid-drag — accepted for v1, noted in a SplitDivider comment; the two-callback API stays frozen. (b) Per-tick `UserDefaults` writes during drags — accepted at this scale. (c) Storage-backed `LayoutMetrics` constants pinned to `Double`; `LayoutMetrics` fixed as a top-level enum in FEditApp.swift. (d) At the 700 pt window minimum with a 600 pt sidebar and preview on, the ~13 pt editor column may visually squash the stub Toggle — accepted; the Toggle is temporary scaffolding removed by (open-save).

## Out of scope

- Real Markdown detection / open-file state — (open-save) replaces the stub flag.
- Any real column content: sidebar tree ((folder-sidebar)), editor ((editor-core)), preview rendering ((markdown-renderer)/(markdown-preview)).
- Per-window persistence (`@SceneStorage`) and session restore — (session-restore).
- Menus/commands, keyboard shortcuts beyond what the scaffold ships.
- Double-click-divider-to-reset, divider snapping, animation polish — not in SPEC.
- Automated UI tests; verification is manual per acceptance criteria (project has no test target yet).
