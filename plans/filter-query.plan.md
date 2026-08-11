# filter-query

**Risk tier:** standard — the grammar has no parentheses or precedence stack (it flattens to OR-of-AND-groups, i.e. disjunctive normal form by construction), the evaluator is pure string matching, and the blast radius is one model file plus the sidebar view.

## Goal

Implement the filter query language of SPEC §5.5 as a pure, unit-verifiable model (`Models/FilterQuery.swift`) and wire it into the sidebar (SPEC §5.4): a rounded search field at the top of `Views/SidebarView.swift`; while the filter is non-empty each root section switches from the disclosure tree to a flat list of matching files shown as root-relative paths, with a muted "No matches" fallback per section. Malformed queries degrade gracefully and never crash or error.

## Acceptance criteria

All criteria are testable either via the verification harness (H) or by running the app (A).

Grammar / matching (H — encoded as assertion cases in the harness):

1. `.py .swift` — adjacency is implicit OR: matches `a/main.py` and `b/main.swift`; parsed groups are `[[".py"], [".swift"]]` (union).
2. `.py AND .swift` — single AND-group `[[".py", ".swift"]]`: matches `weird.py.swift`, does **not** match `main.py` or `main.swift` alone (over a corpus without a doubled extension, the result set is empty).
3. `.swift AND main OR .md` — AND binds tighter: groups `[[".swift", "main"], [".md"]]`; matches `src/main.swift` and `README.md`, does not match `src/helper.swift`.
4. Term match is a case-insensitive substring of the **root-relative path**: `.PY` matches `tools/gen.py`; `src/` matches `src/a.txt` (folder segment); `main` matches `sub/main.swift`.
5. Operators are exact-uppercase: `and` and `or` are ordinary terms (`or` matches `colors.swift`).
6. Graceful degradation (SPEC §5.5 last bullet), with these concrete rules:
   - Leading operator ignored: `AND .py` ≡ `.py`; `OR .py` ≡ `.py`.
   - Trailing operator ignored: `.py AND` ≡ `.py`; `.py OR` ≡ `.py`.
   - Consecutive operators: the first wins, later ones are ignored: `.py AND OR .md` ≡ `.py AND .md`; `.py OR AND .md` ≡ `.py OR .md`; `.py AND AND .md` ≡ `.py AND .md`.
   - Operator-only input (`AND`, `OR AND`) parses to zero groups; a zero-group query matches nothing.
7. Tokenization splits on any whitespace run (spaces, tabs, newlines — `.whitespacesAndNewlines`); no crash on any input (empty string, only whitespace, unicode, very long terms).

Sidebar behavior (A — manual run):

8. Search field at the top of the sidebar, `.roundedBorder` style, placeholder `Filter files (e.g. .py OR .swift)`.
9. Filter text empty or whitespace-only → tree mode exactly as before (no visual change vs. the (folder-sidebar) state).
10. Filter non-empty → every section shows a flat list of matching files as paths relative to that section's root (e.g. `swift-source/main.swift`), root path not repeated; folders never appear as rows; order is the depth-first order of the scanned tree (folders-first sort inherited from the scanner).
11. A section whose root has no matching file shows a single muted "No matches" row; the section header remains.
12. Clicking a flat row performs the same selection action as a tree row (records the selected URL per (folder-sidebar)); the row for the currently selected/open file is highlighted.
13. Clearing the field returns to tree mode; previously expanded/collapsed disclosure state is not required to survive (SwiftUI default behavior is acceptable).
14. Filtering with several thousand files does not beach-ball on each keystroke (linear scan is acceptable per SPEC §11; no async machinery required).

## Tiers

### Tier 1 — FilterQuery model + verification harness

Independently buildable: adds one pure-Foundation file to the app target and one script outside the target; app behavior unchanged.

**Create `FEdit/Models/FilterQuery.swift`** (GPL header boilerplate per project convention; imports Foundation only — this is load-bearing for the harness):

- `enum FilterToken: Equatable { case term(String), and, or }` (internal, so the harness can test the tokenizer directly).
- `struct FilterQuery`:
  - `static func tokenize(_ text: String) -> [FilterToken]` — split on `.whitespacesAndNewlines` character set, drop empties; `"AND"` → `.and`, `"OR"` → `.or` (exact match, case-sensitive), everything else `.term`.
  - `let groups: [[String]]` — the parsed OR-of-AND-groups. Exposed (internal) so the harness can assert structure, not just behavior.
  - `init(_ text: String)` — tokenizes then parses with a single left-to-right pass implementing the degradation rules. State: `groups: [[String]]`, `current: [String]`, `pendingOp: FilterToken?` (an `Operator?`, NOT a `pendingAnd: Bool` — a bool cannot implement first-operator-wins; plan review executed the bool version and it turned `.py OR AND .md` into an AND):
    - `.term(t)`: if `pendingOp == .and` → append `t` to `current`; else (nil or `.or`) → flush `current` into `groups` if non-empty, then `current = [t]` (adjacency and OR both start a new group). Clear `pendingOp`.
    - `.and` / `.or`: if `current` is empty → ignore (leading operator); else if `pendingOp != nil` → ignore (consecutive operators: first wins); else `pendingOp = op`.
    - end of input: flush `current` if non-empty; a dangling `pendingOp` is simply dropped (trailing operator).
  - `var isEmpty: Bool` — `groups.isEmpty` (operator-only or blank input).
  - `func matches(_ relativePath: String) -> Bool` — `groups.contains { group in group.allSatisfy { relativePath.range(of: $0, options: .caseInsensitive) != nil } }`. Note: an empty query returns `false` for every path (criterion 6, zero groups match nothing). Non-localized `.caseInsensitive` for predictable behavior.

**Create `scripts/FilterQueryTests/main.swift`** (repo root `scripts/`, deliberately **outside** `FEdit/` so the file-system-synchronized group does not pull it into the app target; the file MUST be named `main.swift` — Swift only allows top-level statements in `main.swift` when compiling multiple files, so the originally planned `FilterQueryTests.swift` name fails with "expressions are not allowed at the top level"):

- Top-level script: a small `expect(_ condition:, _ label:)` helper that prints `PASS`/`FAIL` and tracks a failure count; `exit(1)` on any failure.
- Cases covering acceptance criteria 1–7: tokenizer cases, parsed-`groups` structure cases (the three grammar examples asserted structurally), matching cases against a fixed relative-path corpus (`["src/main.swift", "src/helper.swift", "tools/gen.py", "README.md", "weird.py.swift", "colors.swift"]`), and all degradation cases.
- Run command (documented in a comment at the top of the script):
  `swiftc FEdit/Models/FilterQuery.swift scripts/FilterQueryTests/main.swift -o /tmp/fqtests && /tmp/fqtests`

**Verification-approach justification:** the scaffold ((xcode-scaffold)) deliberately has no test target, and adding an XCTest target means hand-editing `project.pbxproj` — disproportionate risk and churn for one pure function. Because `FilterQuery.swift` depends only on Foundation, compiling it together with a standalone assertion script via `swiftc` gives real unit-test semantics (isolated process, non-zero exit on failure, runnable in CI) with zero project-file changes. If a test target is added later by another item, the script's cases port to XCTest mechanically.

Tier 1 done when: `xcodebuild` still succeeds and the harness exits 0.

### Tier 2 — Sidebar filter field and flat filtered mode

Independently revertible: touches only `WorkspaceModel.swift` (one property), `FileNode.swift` (one additive helper), and `SidebarView.swift`.

**Modify `FEdit/Models/WorkspaceModel.swift`:**

- Add `@Published var filterText: String = ""`. It lives on the per-window model (not view `@State`) because SPEC §9 persists filter text per window and (session-restore) snapshots from `WorkspaceModel`; putting it here now avoids a later move.

**Modify `FEdit/Models/FileNode.swift`** (additive only):

- `func filesWithRelativePaths() -> [(path: String, node: FileNode)]` — returns the files **under** `self`, with `self`'s own name excluded from every path (so it is callable directly on a root and yields `swift-source/main.swift`, never `FEdit/swift-source/main.swift` — the root-name leak would corrupt matching, e.g. query `fedit` matching every file under a root named FEdit). Implementation: iterate `(children ?? [])` (children is OPTIONAL per folder-sidebar — `[FileNode]?`, nil for files) with a private depth-first helper `collect(prefix:)`; files append `(prefix + name, self)`, directories recurse with `prefix + name + "/"`. Depth-first order preserves the scanner's folders-first sort.

**Modify `FEdit/Views/SidebarView.swift`:**

- Add the search field above the list/sections: `TextField("Filter files (e.g. .py OR .swift)", text: $workspace.filterText)` (the property is named `workspace` in SidebarView per folder-sidebar) with `.textFieldStyle(.roundedBorder)` and standard padding. Present in both modes. (`.roundedBorder` is the deliberate reading of SPEC §5.4 "standard rounded style" — recorded, not revisited.)
- Mode switch: `let query = FilterQuery(workspace.filterText)`; **tree mode when `query.isEmpty`** (blank, whitespace-only, or operator-only input — so typing a lone `AND`/`OR` keeps the tree instead of flashing "No matches" everywhere). This makes `isEmpty` a real consumer of the frozen Tier-1 API rather than dead surface. Otherwise flat mode.
- Flat mode per section: `let matches = root.filesWithRelativePaths().filter { query.matches($0.path) }` — called on the root `FileNode` directly (folder-sidebar ships `roots: [FileNode]`, no wrapper, no `.tree`); computed inline per render; per SPEC §11 the synchronous linear scan is acceptable, no caching layer. If `matches.isEmpty` → `Text("No matches").foregroundStyle(.secondary)` row; else one row per match showing the relative path (single line, `truncationMode(.middle)` or default tail truncation — pick whatever the tree rows already do), using the **same selection action and highlight logic as the existing tree file rows** (reuse/extract the existing row tap handling rather than duplicating it).
- Section headers, context menu (Remove/Refresh), and the empty-state placeholder are untouched and remain functional in both modes.

Tier 2 done when: acceptance criteria 8–14 pass in a manual run with two roots open.

## Interface between tiers

Tier 2 consumes exactly this Tier-1 surface, which is frozen once Tier 1 lands:

```swift
struct FilterQuery {
    init(_ text: String)
    var isEmpty: Bool                       // zero groups (blank / operator-only input)
    func matches(_ relativePath: String) -> Bool
}
```

`groups` and `tokenize` are internal implementation surface used only by the harness; the view must not depend on them. Tier 2 additionally defines `FileNode.filesWithRelativePaths(prefix:)`, but that is intra-tier.

## Load-bearing assumptions

Expected state from shipped items (xcode-scaffold), (split-layout), (folder-sidebar) — verify at implementation start and adapt call sites (not the FilterQuery API) if names differ:

1. `FEdit/Models/FileNode.swift` exists: a node type with `url: URL`, `name: String`, `isDirectory: Bool`, `children: [FileNode]?` (**optional** — nil for files, load-bearing for OutlineGroup leaf detection; do not "fix" it), `Identifiable`, produced by the recursive scanner (dotfiles/`node_modules`/`.build`/`DerivedData` skipped, folders-first `localizedStandardCompare` sort). The flat list inherits this order.
2. `FEdit/Models/WorkspaceModel.swift` exists as a per-window `ObservableObject` with a `roots` array where each element exposes the root's URL/display path and its scanned `FileNode` tree (either `roots: [FileNode]` directly or a small wrapper struct — the plan's `root.tree` spelling adapts to whichever shape shipped).
3. `WorkspaceModel` exposes the selection mechanism from (folder-sidebar) — a recorded selected-file URL plus whatever method/binding tree rows use to select; flat rows reuse it unchanged. The open/selected file row highlight state is readable from the model.
4. `FEdit/Views/SidebarView.swift` exists with one section per root (`~`-abbreviated header, context menu, disclosure tree, selectable file rows) and observes `WorkspaceModel` (environment or observed object — reuse whatever wiring exists).
5. Project scaffold: file-system-synchronized group rooted at `FEdit/` (so new files under `FEdit/Models/` join the target automatically, and `scripts/` at repo root stays out), Swift 5 mode, no test target, GPL header boilerplate convention for new sources.
6. `swiftc` is available on the machine (Xcode toolchain — guaranteed by the project being buildable).

## Auto-resolved (plan review)

DEFECT fold-ins: parser state machine rewritten from `pendingAnd: Bool` to `pendingOp: Operator?` (the bool provably could not implement first-operator-wins — review executed it: `.py OR AND .md` came out as an AND); harness relocated to `scripts/FilterQueryTests/main.swift` (top-level statements require a `main.swift` filename in multi-file `swiftc` compiles — the original spelling did not compile); `filesWithRelativePaths()` pinned to exclude the root's own name and be callable on a root directly (root-name leak would have corrupted matching invisibly to the harness); `children` corrected to optional; tokenizer widened to `.whitespacesAndNewlines`.

TENSION resolutions: (a) mode switch now keys on `FilterQuery.isEmpty` instead of trimmed text — operator-only input stays in tree mode, and `isEmpty` stops being dead API. (b) First-operator-wins retained for consecutive mixed operators (plan-invented but now correctly implementable; matches criterion 6 as written). (c) `.roundedBorder` confirmed as the reading of SPEC's "standard rounded style". (d) SidebarView property name aligned to `workspace`.

## Out of scope

- Persisting `filterText` across relaunch (`@SceneStorage` snapshot) — belongs to (session-restore); this item only parks the property on `WorkspaceModel`.
- Opening files / dirty checks on selection — selection still only records the URL until (open-save).
- Grammar extensions: parentheses, NOT, quoted terms, fuzzy or glob matching, match-range highlighting in results.
- Performance work beyond the synchronous linear scan (no caching, no debounce, no background filtering).
- Adding an XCTest target or any `project.pbxproj` modification.
- Live re-filtering on disk changes (no FS watching in v1; Refresh remains manual).
