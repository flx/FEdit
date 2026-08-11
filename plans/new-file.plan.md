# new-file

**Risk tier:** standard — UI/state plumbing (a menu item + a per-window sheet + a published presentation flag) over well-known SwiftUI/AppKit APIs, plus one disk write. No concurrency, no algorithms; the only real substance is file-creation validation edge cases (collision, permission, dotfile-invisibility, TOCTOU) and correctly sequencing the open through the existing dirty-guard. Blast radius confined to `WorkspaceModel`, `ContentView`, `FEditApp`, and one new view.

## Goal

Add `File → New…` (Cmd+N, freed by (open-cmd-o)) that presents a per-window filename sheet. On confirm it writes an **empty** file next to the currently open file (or, if none is open, in the first top-level root), refreshes the sidebar so the file appears, then opens it in the editor **through the existing `requestOpen` dirty-switch guard**. Validation (non-empty, no path separators, no leading dot, no collision) keeps the sheet open with an inline error on failure; the created file is not overwritten on collision. Cancel closes the sheet with no change. With no place to create a file (no roots and nothing open), the menu item is disabled.

## Acceptance criteria

Manually testable against a window whose sole root is `~/tmp/demo/` containing `sub/` (with `sub/note.md`) and `a.txt`.

Menu & sheet:
1. The File menu shows **New…** at **⌘N**, above `Open Folder…` (now ⌘O per (open-cmd-o)). It is enabled whenever a file is open **or** at least one root is present.
2. ⌘N (or clicking New…) presents a sheet in the **focused** window with a filename `TextField` (focused on appear), a Create button, a Cancel button, and a line showing the target directory (tilde-abbreviated).
3. Enter in the field submits (= Create); Esc cancels. Cancel closes the sheet, creates nothing, and leaves the editor unchanged.

Target directory:
4. **File open →** create next to it: with `sub/note.md` open, creating `b.txt` writes `~/tmp/demo/sub/b.txt` (the open file's parent), not the root. Verify on disk and in the sidebar.
5. **No file open →** first root: with nothing open (≥1 root), creating `c.txt` writes it in the first root (`~/tmp/demo/c.txt`).

Creation & open:
6. Create writes a **0-byte** file; afterward — **with the target folder already expanded** — the sidebar shows the new row and the editor opens it, content empty, **no "Edited" subtitle** (clean). The new row is the selected/highlighted row. (A file created into a collapsed nested folder still opens, but its row appears only on expand — see decision D6; contingent on Refresh preserving disclosure — see assumption 7.)
7. An extension-less name (`notes`) creates a plain file that opens as plain text (no preview column). A `.md` name (`draft.md`) opens **with** the preview column (real `isMarkdown` from the extension).

Validation (sheet stays open, nothing written):
8. Empty / whitespace-only (trimmed) name: Create is disabled **and Return is inert** — the single submission source is the default-action Create button, which does nothing while disabled — so nothing is written and no error appears (D4).
9. Name containing `/` or `:` : inline error, sheet stays.
10. Name starting with `.` (e.g. `.env`): inline error, sheet stays (a dotfile would be hidden from the sidebar — see decision D3).
11. Collision: creating `a.txt` (already exists) shows an inline "already exists" error; the sheet stays and the existing `a.txt` is **not** modified (verify content/mtime unchanged).
12. Write failure: with the target directory read-only (`chmod 555 ~/tmp/demo`), Create shows an inline error and writes nothing.

Dirty-switch routing (the created file is opened exactly like a sidebar-row tap):
13. Opening the newly created file routes through `requestOpen` **exactly as a sidebar-row tap does**, honoring **whatever dirty-switch behavior is shipped at the time**. Post-(baked-in-autosave) that is a silent autosave-flush of the outgoing dirty file before the new file opens; the open runs from the sheet's `onDismiss` (after the sheet is fully gone), so any guard UI is never stacked under a live sheet.
14. On a `.cancel` outcome from the dirty-switch guard, the switch aborts: the new file is still created and visible in the sidebar but is **not** opened, and selection reverts to the previously open file.

Empty-window & focus:
15. With **no roots and no file open**, New… is disabled; ⌘N does nothing.
16. With two windows open, ⌘N presents the sheet in the **key** window and creates in that window's target directory only.

## Tiers

### Tier 1 — WorkspaceModel: target dir, validation, `createFile`, presentation seam

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify).

Add, all additively (no existing member changes — see the overlap note):

- `@Published var isPresentingNewFileSheet: Bool = false` — the per-window presentation flag ContentView binds `.sheet(isPresented:)` to (Tier 2). This is the **seam** by which the app-level menu command reaches the focused window's ContentView.
- `private var pendingNewFileURL: URL?` — set by a successful `createFile`, consumed by `openPendingNewFileIfNeeded()` from the sheet's `onDismiss` (so any dirty-switch guard UI can only appear after the sheet is fully gone).
- `var newFileTargetDirectory: URL? { openFile?.url.deletingLastPathComponent() ?? roots.first?.url }` — precise target rule. With `todo/2026-01.txt` open under root `~/Documents`, `openFile.url.deletingLastPathComponent()` is `~/Documents/todo/` (matches the TODO example, verified). Falls back to `roots.first?.url` when nothing is open; `nil` only when there is neither an open file nor a root.
- `var canCreateNewFile: Bool { newFileTargetDirectory != nil }` — drives menu enablement (Tier 2). Note: because `removeRoot` leaves `openFile` intact (verified — it only clears `selectedFileURL`), `openFile != nil` can hold with `roots` empty; the `openFile?...deletingLastPathComponent()` branch keeps New… working then (target = the open file's parent), see decision D5.
- `func presentNewFileSheet()` — `guard canCreateNewFile else { return }; isPresentingNewFileSheet = true`. (Defensive guard; the menu is already `.disabled` when `!canCreateNewFile`.)
- `enum NewFileResult { case created; case invalidName; case duplicateName; case writeFailed(String) }` with `var message: String?` — `nil` for `.created`; `.invalidName` → "Enter a file name that isn't empty, contains no “/” or “:”, and doesn't start with a dot."; `.duplicateName` → "A file named “<name>” already exists."; `.writeFailed(let s)` → s.
- `func createFile(named rawName: String) -> NewFileResult`:
  1. `let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)`.
  2. Validate → `.invalidName` if: empty; contains `"/"` or `":"`; equals `"."` or `".."`; or `name.hasPrefix(".")` (decision D3).
  3. `guard let dir = newFileTargetDirectory else { return .writeFailed("No folder is open to create the file in.") }` (unreachable while the sheet is up, but total).
  4. `let fileURL = dir.appendingPathComponent(name).standardizedFileURL` — **standardized** so it compares equal to the `FileNode.url` (`.standardizedFileURL`) the sidebar highlight matches against (`node.url == selectedFileURL`). The same standardized URL is both the write target and the value stashed in `pendingNewFileURL` (assumption 8, mirroring git-changed-badge's URL-identity assumption); without this the created row would open but never highlight.
  5. Collision fast-path: `if FileManager.default.fileExists(atPath: fileURL.path) { return .duplicateName }`.
  6. Write empty + race-safe: `do { try Data().write(to: fileURL, options: .withoutOverwriting) } catch { ... }`. In `catch`, map a `CocoaError.fileWriteFileExists` (TOCTOU: created between step 5 and here) to `.duplicateName`, any other error to `.writeFailed(error.localizedDescription)`. `.withoutOverwriting` (not `.atomic`) is deliberate — `.atomic`'s temp-file-then-rename would clobber an existing file, defeating the no-overwrite guarantee; the content is 0 bytes so atomicity is moot.
  7. Success: `refreshAll()` (reuses the shipped Refresh — rescans all roots so the new node appears; see assumption 7 on disclosure preservation), `pendingNewFileURL = fileURL` (the standardized URL from step 4, so the highlight matches — assumption 8), `return .created`. Does **not** touch `isPresentingNewFileSheet` (the sheet dismisses itself — Tier 2) and does **not** call `requestOpen` yet (that runs from `onDismiss`).
- `func openPendingNewFileIfNeeded()` — `guard let url = pendingNewFileURL else { return }; pendingNewFileURL = nil; requestOpen(url)`. Routes the open through the existing dirty-guard/no-op-on-same-file logic exactly like a sidebar tap. On the outgoing file's dirty-guard Cancel, `requestOpen` aborts and reverts selection (criterion 13); the created file simply stays unopened but present in the tree.

Also (cosmetic, in scope since this file is touched): refresh the now-stale "Cmd+N" comments that (open-cmd-o) left describing the Open Folder… flow (`WorkspaceModel.swift` class doc ~L28 and `presentNewWindowFolderPanel` ~L358–359) to say Cmd+O.

*Buildable/revertible:* compiles; the model API is complete and independently exercisable (call `createFile` from a scratch harness → file created on disk + `pendingNewFileURL` set). No menu entry point or sheet yet — that is Tier 2. Reverting drops the whole added surface with no effect on existing behavior.

### Tier 2 — The sheet view, its presentation, and the menu item

*Files:* new `FEdit/Views/NewFileSheet.swift`; `FEdit/Views/ContentView.swift` (modify); `FEdit/App/FEditApp.swift` (modify).

- **`NewFileSheet.swift`** — `struct NewFileSheet: View { @ObservedObject var workspace: WorkspaceModel }` plus `@State private var filename = ""`, `@State private var errorMessage: String?`, `@FocusState private var fieldFocused: Bool`.
  - Layout: a title ("New File"), a caption showing the destination — `Text("Create in \((workspace.newFileTargetDirectory?.path as NSString?)?.abbreviatingWithTildeInPath ?? "")")` (same tilde style as the sidebar header), a `TextField("File name", text: $filename)` (`.focused($fieldFocused)` — **no** `.onSubmit`, see below), the inline `errorMessage` in red when non-nil, and an HStack with Cancel + Create.
  - `.onAppear { fieldFocused = true }` — focus-on-appear is a **known-flaky** macOS pattern (the field may not be in the window hierarchy yet); recorded as a tension against criterion 2.
  - Create button: `.keyboardShortcut(.defaultAction)` (Return), `.disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)`, action `create`. This default-action button is the **single submission source** (the TextField has **no** `.onSubmit`) — so Return fires `create()` exactly once (D4) and is inert while the button is disabled on an empty/whitespace name (D2, criterion 8). Cancel button: `.keyboardShortcut(.cancelAction)` (Esc), action `{ workspace.isPresentingNewFileSheet = false }`.
  - `func create()`: `let result = workspace.createFile(named: filename); if case .created = result { workspace.isPresentingNewFileSheet = false } else { errorMessage = result.message }`. (On `.created` the flag flip dismisses the sheet; `onDismiss` in ContentView then performs the open. On any failure the sheet stays with the inline error.)
- **`ContentView.swift`** — add one modifier alongside the existing outer-view modifiers:
  `.sheet(isPresented: $workspace.isPresentingNewFileSheet, onDismiss: { workspace.openPendingNewFileIfNeeded() }) { NewFileSheet(workspace: workspace) }`.
  `onDismiss` fires **after** the sheet is fully dismissed — this is the load-bearing seam (A5) that guarantees any dirty-switch guard UI `requestOpen` might surface never appears under a live sheet. On Cancel, `pendingNewFileURL` is `nil`, so `openPendingNewFileIfNeeded()` is a no-op. (Cosmetic: refresh the stale Cmd+N/Open-Folder comments at ~L125/L147/L153 to reflect that Cmd+N is now New… and Open Folder… is Cmd+O.)
- **`FEditApp.swift`** — in `FileCommands`, add a `Button("New…")` as the **first** item inside the existing `CommandGroup(replacing: .newItem)` (which, after (open-cmd-o), holds `Open Folder…` on ⌘O), so the File menu reads New… → Open Folder…:
  ```
  Button("New…") { workspace?.presentNewFileSheet() }
      .keyboardShortcut("n", modifiers: [.command])
      .disabled(workspace?.canCreateNewFile != true)
  ```
  This is **focused-window-scoped** (unlike Open Folder…, which is app-level): `@FocusedObject var workspace` already resolves to the key window's `focusedSceneObject(workspace)` model — **reusing Save's focused-model resolution** — and setting its `@Published isPresentingNewFileSheet` publishes into that window's ContentView `.sheet` binding. Note the seam is only half-proven: the focused-model resolution is exercised by Save, but the **flag → `.sheet(isPresented:)` presentation round-trip is standard SwiftUI yet unexercised elsewhere in this app** — smoke-test the multi-window case (criterion 16). `.disabled` covers both "no window focused" (`workspace == nil`) and "nowhere to create" (`!canCreateNewFile`).

*Buildable/revertible:* the full feature works from the menu (criteria 1–16). Reverting this tier leaves the Tier 1 model API dormant (no entry point) — a clean degrade with no behavior change.

## Interface between tiers

`WorkspaceModel` surface frozen at end of Tier 1, consumed by Tier 2:
- `@Published var isPresentingNewFileSheet: Bool` — presentation flag (menu sets true; sheet sets false).
- `var newFileTargetDirectory: URL?`, `var canCreateNewFile: Bool` — target rule + menu enablement + sheet caption.
- `func presentNewFileSheet()` — menu action.
- `enum NewFileResult { created, invalidName, duplicateName, writeFailed(String) }` (+ `var message: String?`).
- `func createFile(named:) -> NewFileResult` — validates, writes (`.withoutOverwriting`), `refreshAll()`, stashes `pendingNewFileURL`.
- `func openPendingNewFileIfNeeded()` — called from ContentView's `.sheet(onDismiss:)`; pops `pendingNewFileURL` and `requestOpen`s it.

## Design decisions (recorded)

- **D1 — Empty window: disable, don't prompt.** When there is no root and no open file, New… is `.disabled` (there is genuinely no target directory). Matches how Save / Add Folder to Window… already disable on `workspace == nil`, avoids a two-step "open a folder first" flow, and Add Folder to Window… (⌘⇧O) remains available to acquire a root. Preferred over an alert.
- **D2 — Inline error in the sheet, not a separate alert.** Collision and write-failure report via red inline text in the still-open sheet (a "re-prompt"), rather than an NSAlert stacked over the sheet. Cleaner, and keeps the user's typed name editable. The *dirty-switch guard* (whatever modal form it takes at ship time) is the only other modal path, and it surfaces only after the sheet dismisses (via `onDismiss`).
- **D3 — Reject leading-dot (hidden) names.** `FileNode.scan` uses `.skipsHiddenFiles` (verified), so a created dotfile would never appear in the sidebar — directly breaking this feature's "refresh so it appears" contract. Rejecting leading-dot names in validation keeps the promise coherent for v1 (SPEC §5.2 deliberately hides dotfiles). Alternative (allow, but it opens in the editor while staying invisible in the tree) was rejected as confusing.
- **D4 — Do not force an extension.** The user types the full name including any extension; an extension-less name is valid. `isMarkdown`/preview follows naturally from the extension via existing logic (criterion 7).
- **D5 — `openFile` parent can be outside all roots (accepted edge).** `removeRoot` leaves `openFile` intact, so a file can stay open after its containing root is removed. `newFileTargetDirectory` then targets the open file's parent (correct on disk), but `refreshAll()` — which only rescans existing roots — won't surface the new file in the (now-rootless) tree. The file is still created and opened; it just isn't shown. Rare, and not worth special-casing in v1.
- **D6 — New row visible only when its folder is expanded.** `OutlineGroup` self-manages disclosure state; New… does not force-expand the target folder. In the common case (target = a root's direct child or the currently-open file's already-expanded folder) the row is visible; a new file created into a collapsed nested folder exists + opens but its row is revealed only on expand. Force-expansion would require managing OutlineGroup expansion state the sidebar doesn't currently track — out of scope.

## Load-bearing assumptions

1. **(open-cmd-o) ships first and frees Cmd+N** — it rebinds Open Folder… to ⌘O while keeping the button in `CommandGroup(replacing: .newItem)` (verified in `plans/open-cmd-o.plan.md`). new-file adds New… on ⌘N into that same group; if new-file shipped first, ⌘N would double-bind (Open Folder… + New…). **Build gate:** implementation **MUST NOT start** until (open-cmd-o) is merged — first verify `FEditApp.swift` binds Open Folder… to **Cmd+O** (not Cmd+N) before adding the New… button. This item **also** ships after (baked-in-autosave) — see the Overlap / integration note.
2. **`@FocusedObject` / `.focusedSceneObject(workspace)` reaches the focused window's model** (folder-sidebar/open-save; verified in `FileCommands` and `ContentView`) — the New… button reaches the focused model exactly as Save calls `saveOpenFile()`. The subsequent published-flag → `.sheet(isPresented:)` presentation round-trip is standard SwiftUI but **unexercised elsewhere here**; smoke-test the multi-window case so the sheet presents in the key window only, with no cross-window leakage (criterion 16).
3. **`requestOpen`, `resolveDirtyFile`, `refreshAll`, `roots`, `openFile`, `selectedFileURL` exist and behave as in the shipped source** (verified in `WorkspaceModel.swift`): `requestOpen` runs the dirty guard on the outgoing file, no-ops when the URL is already open, and syncs `selectedFileURL` on success. Creating+opening therefore honors unsaved-changes exactly like a sidebar click.
4. **`FileNode.scan` skips hidden files** (`.skipsHiddenFiles`, verified) — the fact behind D3's dotfile rejection.
5. **`.sheet(isPresented:onDismiss:)`'s `onDismiss` runs after full dismissal** (standard SwiftUI) — so `openPendingNewFileIfNeeded()` → `requestOpen` fires once the sheet is gone, no timing hacks. Post-(baked-in-autosave) the dirty-switch flush is silent and usually shows no UI, so "no modal under a live sheet" is largely moot; any guard UI that does appear (e.g. a failed-flush alert) is still not a child of the live sheet. This ordering is standard SwiftUI but a **manual-check** item here, not a proven guarantee.
6. **No sandbox (SPEC §2):** a plain-path `Data().write(to:options:.withoutOverwriting)` needs no security-scoped access.
7. **Refresh preserves `OutlineGroup` disclosure state.** `createFile` relies on `refreshAll()` (which reassigns `roots` to freshly-scanned nodes) leaving an already-expanded target folder expanded, so the new nested row renders — a known SwiftUI fragility. **Pre-implementation check:** verify the shipped Refresh preserves disclosure of an expanded folder; if it collapses on refresh, the new nested row won't render and disclosure-state management moves **in-scope** (currently out of scope per D6). Criterion 6 is scoped to a target folder that is already expanded.
8. **URL identity: the created URL is standardized.** The sidebar highlight matches `node.url == selectedFileURL` and `FileNode` stores `.standardizedFileURL`, so the created file's URL must be `.standardizedFileURL` (Tier 1 step 4) for **both** the write target and `pendingNewFileURL`; otherwise the new row opens but never highlights. Mirrors git-changed-badge's assumption #5.

## Overlap / integration note

This item touches the same three files as (baked-in-autosave) / (external-change-watch) / (git-changed-badge). Its additions are strictly **additive and localized** — one new published flag + one private URL + a target-dir computed property + `createFile`/`presentNewFileSheet`/`openPendingNewFileIfNeeded` on `WorkspaceModel`; one `.sheet` modifier on ContentView; one `Button` in FileCommands; one new file. No existing member is re-signatured.

**Ordering dependency — ships after (baked-in-autosave).** new-file is **not** disjoint from (baked-in-autosave): that item makes autosave **unconditional** — deleting the four-button "Save changes?" dialog, the "Autosave on File Switch" toggle, and `SettingsKey.autosaveOnFileSwitch`, and rewriting `resolveDirtyFile()` into a silent flush (with only a "Close Without Saving / Cancel" alert if a *close/quit* flush fails). That is exactly the dirty-switch machinery new-file routes through in criteria 13–14. new-file therefore ships **after** (baked-in-autosave) (like the (open-cmd-o) dependency) and states the routing behavior-agnostically so it stays correct whichever guard is live. `requestOpen`'s signature is unchanged by (baked-in-autosave), so the `createFile → refreshAll → requestOpen` composition is unaffected.

new-file **remains disjoint** from (external-change-watch) and (git-changed-badge): neither re-signatures `refreshAll`, `requestOpen`, `roots`, `openFile`, or `selectedFileURL` (verified), so new-file's `createFile → refreshAll → requestOpen` composes cleanly with them as a merge of disjoint additions.

## SPEC updates (to apply during implementation — do NOT edit SPEC now)

- **§7 (Open / save / autosave):** add a "Creating a file" bullet — File → New… writes an empty file at the target (open file's parent, else first root), refreshes the sidebar, and opens it through the same dirty-switch guard; validation (non-empty, no `/`/`:`, no leading dot, no collision) with an inline error on failure; collision does not overwrite.
- **§5 (Folder sidebar):** note that a file created via New… appears after the automatic refresh (subject to D6's disclosure caveat).
- **§3 (Windows) / §10 (Menus table & note):** add the `File → New…` — **Cmd+N** row ("create a new file in the open file's folder, or the first root; disabled when neither exists"); it is focused-window-scoped. (The Open Folder… → ⌘O cell is (open-cmd-o)'s edit.)
- **§12 (Non-goals):** reconcile "file create/rename/delete from the sidebar" — file **create** is now supported via the File menu (not the sidebar); rename/delete remain non-goals. (Beyond the TODO's listed §3/§5/§7 but required for doc self-consistency.)

## Out of scope

- Sidebar-driven create, and any rename/delete (SPEC §12 keeps rename/delete as non-goals).
- New-folder creation, file templates, or choosing an arbitrary destination via a save panel.
- Force-expanding the target folder's disclosure to reveal the new row (D6).
- Batch/multi-file creation; duplicating an existing file's contents (the created file is always empty).
- Any change to the dirty-guard, autosave, or save machinery itself — new-file only *routes through* the existing `requestOpen`/`resolveDirtyFile`.

## Auto-resolved (plan review)

Findings from adversarial plan review, folded in above:

**Defects fixed**

1. *(High)* The "Overlap / integration note" falsely claimed disjointness with (baked-in-autosave), and criteria 13–14 were written against the four-button "Save changes?" dialog and the "Autosave on File Switch" toggle that (baked-in-autosave) **deletes** (it makes autosave unconditional and rewrites `resolveDirtyFile()` to a silent flush). Fixed: (baked-in-autosave) dropped from the "disjoint additions" claim and added as an explicit **ordering dependency** — new-file ships **after** it — while disjointness from (external-change-watch)/(git-changed-badge) is kept (verified: neither re-signatures `refreshAll`/`requestOpen`/`roots`/`openFile`/`selectedFileURL`; `createFile → refreshAll → requestOpen` composes cleanly). Criteria 13–14 restated **behavior-agnostically**: opening the created file routes through `requestOpen` exactly as a sidebar-row tap, honoring whatever dirty-switch behavior is shipped (post-autosave: a silent flush of the outgoing file); on a `.cancel` outcome the new file is created and visible but not opened, and selection reverts. No four-button dialog or autosave toggle is named.
2. *(Medium)* Criterion 8 ("Enter is inert on empty name") contradicted the plan's own `.onSubmit(create)`, which on an empty name ran `createFile → .invalidName → red error`. Fixed: submission is gated on a non-empty trimmed name via the disabled default-action button (the sole submission source), so Return on an empty field is truly inert; criterion 8 reconciled to that.
3. *(Medium)* Criterion 6 ("the new row shows and is highlighted") silently depended on `refreshAll()` (which reassigns `roots` to freshly-scanned nodes) preserving `OutlineGroup` disclosure — a known SwiftUI fragility. Fixed: added assumption 7 as a **pre-implementation check** (verify Refresh preserves an expanded folder's disclosure; if it collapses, disclosure-state management moves in-scope) and scoped criterion 6 to "target folder already expanded," reconciling it with decision D6.
4. *(Low)* `.onSubmit(create)` + `.keyboardShortcut(.defaultAction)` could invoke `create()` **twice** on Return (the second call sees the file now exists → spurious `.duplicateName` written onto a dismissing sheet). Fixed: submission is **single-sourced** through the default-action Create button; the TextField's `.onSubmit` is removed.
5. *(Low)* The dependency on the unshipped (open-cmd-o) (which still binds Open Folder… to ⌘N on main) was a soft preference. Fixed: assumption 1 is now a **build gate** — implementation MUST NOT start until (open-cmd-o) is merged, and must first verify `FEditApp.swift` binds Open Folder… to Cmd+O.
6. *(Low)* The created URL wasn't standardized, but the sidebar highlight is `node.url == selectedFileURL` and `FileNode` stores `.standardizedFileURL`. Fixed: Tier 1 step 4 standardizes the URL (`dir.appendingPathComponent(name).standardizedFileURL`) for **both** the write target and `pendingNewFileURL`; assumption 8 states the URL-identity requirement (mirrors git-changed-badge's assumption #5).

**Tensions resolved (recorded decisions)**

7. **Presentation seam** — "same mechanism as Save" overstated the proof. `@FocusedObject`/`focusedSceneObject` reaching the focused model is proven by Save, but the published-flag → `.sheet(isPresented:)` round-trip is new to this app. Reworded (Tier 2 bullet / assumption 2) to "reuses Save's focused-model resolution; the flag→sheet presentation is standard SwiftUI but unexercised here" — smoke-test the multi-window case (criterion 16).
8. **`.onDismiss → requestOpen` timing** — `.sheet(onDismiss:)` runs after dismissal, so any (post-autosave, usually absent) dirty alert isn't a child of the live sheet. Recorded (assumption 5): post-autosave this is largely moot; before it, the ordering is a manual-check item, not a proven guarantee.
9. **`.onAppear { fieldFocused = true }`** is a known-flaky macOS pattern (the field may not be in the window hierarchy yet), so criterion 2 ("focused on appear") may intermittently fail. Recorded (Tier 2 bullet); not gated.
10. **`.duplicateName` copy imprecision** — "A file named “<name>” already exists" also fires when the colliding entry is a **directory** (e.g. typing `sub`). Recorded as a wording imprecision, not fixed for v1.
11. **Verified-correct edges accepted as-is:** D5's open-file parent outside all roots; `roots.first?.url` typed as `FileNode.url`; `.withoutOverwriting` closing the TOCTOU window between the `fileExists` check and the write; and `.skipsHiddenFiles` justifying the leading-dot rejection (D3).
