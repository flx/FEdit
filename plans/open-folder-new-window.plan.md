# open-folder-new-window

**Risk tier:** standard — with change (c) (the startup auto-picker) descoped, this is additive menu wiring plus a fresh-window panel: no launch-time race, no modification of the session-restore decision logic. The one genuine residual risk is D4 — adding an `id:` to a `WindowGroup` that currently has none *may* change `@SceneStorage` scene-restoration identity and drop a pre-existing snapshot on the first (upgrade) relaunch. That is bounded (one-time session reset at worst — files on disk untouched), explicitly tested (criterion 9), and carries a documented fallback, so it does not lift the whole plan to hi. (Implementer is feature-implementer-hi/opus regardless.)

## Goal

Rework the folder-open menu flow into two behaviors:

- **(a)** Rename `File → Open Folder…` (Cmd+Shift+O) to `File → Add Folder to Window…` — behavior unchanged: it adds one or more folders as additional sidebar sections to the **focused** window via `WorkspaceModel.addFolders`.
- **(b)** Turn the Cmd+N "New Window" command into `File → Open Folder…` (Cmd+N): it opens a **new** window (value-less `WindowGroup(id:)` + `openWindow(id:)`); that window immediately presents a directories-only `NSOpenPanel` on appear and opens the chosen folder as its **sole** root. Cancel leaves an empty new window.

**Startup is out of scope** (see "Out of scope"): behavior reverts to today's — a restored session comes back via `@SceneStorage`, otherwise SwiftUI opens a blank window. No auto-picker at launch.

## Key decisions (pinned — one answer each)

1. **Folder → new window mechanism:** the new window **picks its own folder on appear**; the menu command only *creates* an empty window (`openWindow(id: "editor")`) and flags intent via a one-item mailbox. We do **not** pass the folder as an `openWindow(value:)` payload. *Rationale:* `openWindow(value:)` makes the value the window's identity (equal values reuse an existing window; SwiftUI persists presented values through its own state restoration), which both defeats "always a new window" and would restructure the shipped `@SceneStorage` restore built on a value-less `WindowGroup`. A value-less `WindowGroup(id:)` + `openWindow(id:)` opens a fresh window every call.
2. **Panel timing / Cancel:** the panel runs **after** the window exists (dispatched one runloop turn past appear so the window is on screen first). *Rationale:* the window already exists, so Cancel trivially "leaves an empty new window" (TODO (b)) with no extra branching.
3. **New-window picker selection mode:** single-selection, directories-only, applied as the **sole** root (new method `presentNewWindowFolderPanel()`). *Rationale:* TODO says "sole root" (singular); multi-add stays available via "Add Folder to Window…".
4. **Cmd+N = Open Folder…; Cmd+Shift+O = Add Folder to Window…** *Rationale:* verbatim from the TODO; Cmd+Shift+O keeps the shipped chord.
5. **Removing the default New Window item:** `CommandGroup(replacing: .newItem)` hosts the new Cmd+N "Open Folder…". *Rationale:* `.newItem` is where SwiftUI auto-installs "New Window"; replacing it guarantees exactly one Cmd+N item (no leftover blank New Window firing a second window).
6. **"Open Folder…" (Cmd+N) is app-level, always enabled;** "Add Folder to Window…" / "Save" stay focused-window (`@FocusedObject`), disabled when appropriate. *Rationale:* creating a window must work with no window focused (e.g. after closing the last window); adding-to / saving a window cannot.
7. **How the new window knows to pick (vs. a restored/blank window not picking):** an app-level one-item mailbox `LaunchCoordinator.shared.pendingNewWindowPicks` incremented by the Cmd+N command and consumed by the next pristine window on appear. *Rationale:* the counter is only ever >0 as a direct result of the user's Cmd+N (a post-launch action), so restored and blank startup windows (counter == 0) never pick — today's startup behavior is preserved with no race and no deferred re-check.
8. **T3 — empty-state button label:** the sidebar empty-state button is **relabeled "Add Folder to Window…"** and continues to call `workspace.presentOpenPanel()` (same-window add). *Rationale:* the button adds to the *current* window — identical to the Cmd+Shift+O command — so sharing that label removes the collision with the new-window "Open Folder…" menu item and accurately signals "this window, not a new one".

## Acceptance criteria

Manually verifiable on a debug build (the new-window/open-panel logic is verified **manually** — the repo's `scripts/*Tests` swiftc harnesses cannot drive `NSOpenPanel` or `openWindow`; see D6). Numbered:

1. **Rename (a).** The File menu shows **Add Folder to Window…** at **Cmd+Shift+O**; no item titled "Open Folder…" carries Cmd+Shift+O. It presents a directories-only, multi-select `NSOpenPanel`; chosen folders appear as additional sidebar sections in the **focused** window, exactly as before. With two windows open it targets only the focused one; disabled when no editor window is focused.
2. **New-window Open Folder… (b).** The File menu shows **Open Folder…** at **Cmd+N**. Invoking it opens a **new** window which immediately presents a directories-only, **single-select** `NSOpenPanel`; the chosen folder becomes that new window's **sole** root (the original window unchanged). Two consecutive Cmd+N invocations yield two distinct new windows, each with its own picker.
3. **Cmd+N Cancel (b).** Cancelling the new-window panel leaves a new **empty** window showing the "No folders open" empty state; no crash, no folder added, the original window untouched.
4. **Only one Cmd+N item.** Cmd+N opens exactly the picker window — no blank "New Window" opens in addition; there is no residual "New Window" menu item.
5. **Add Folder still multi-adds.** "Add Folder to Window…" with several folders selected adds all as sections to the focused window (multi-select preserved).
6. **App-level command enablement.** With all windows closed but the app still running, Cmd+N ("Open Folder…") still opens a new window + picker. "Add Folder to Window…" and "Save" are disabled when no window is focused.
7. **Empty-state button (decision 8).** In an empty (e.g. cancelled) window, the sidebar button is titled **"Add Folder to Window…"** and opens a folder into **that** window (no new window spawned).
8. **Startup unchanged (c descoped).** Launch with a saved session → windows restore their folders/file/filter/cursor and **no picker appears**. Launch with no session → a blank window appears (today's behavior), **no picker**. Per-window independence, Save, and the Autosave toggle still track the focused window (no session-restore regression).
9. **Upgrade session-restore (D4).** Build the current *committed* code; create a session (open a folder + a file), quit. Check out this change, build, relaunch → the prior snapshot **still restores** into the window. If adding `id:` changes scene identity and the snapshot does **not** restore, that is accepted as a **one-time session reset on upgrade** and must be recorded (see Auto-resolved D4); it must not crash, and subsequent quit/relaunch cycles must restore normally.
10. **Robustness.** Corrupt/empty `@SceneStorage` → blank window, no crash. Closing a dirty window / Cmd+Q still routes through the shipped dirty-file dialog (`WindowCloseGuard`/`AppDelegate` unaffected).
11. **SPEC updated.** SPEC.md §3 (Cmd+N semantics), §5.1, and the §10 menu table reflect the renamed/repurposed commands.

## Tiers

Each tier compiles (`xcodebuild`) and is independently revertible.

### Tier 1 — Model panel method + launch mailbox (no menu/UI change yet)

**Modify `FEdit/Models/WorkspaceModel.swift`:**

- Add `func presentNewWindowFolderPanel()` next to the existing `presentOpenPanel()` (~line 345): a **single-select**, directories-only panel (`canChooseDirectories = true`, `canChooseFiles = false`, `allowsMultipleSelection = false`); on `.OK` calls `addFolders(panel.urls)`. Called only on a pristine (empty-`roots`) model, so `addFolders` yields the chosen folder as the sole root; Cancel is a no-op. Leave `presentOpenPanel()` **unchanged** (multi-select) for "Add Folder to Window…" and the empty-state button.

**Add `FEdit/App/LaunchCoordinator.swift`** (GPL header per convention):

- `@MainActor final class LaunchCoordinator` with `static let shared = LaunchCoordinator()`, a private `init()`, and one plain (non-`@Published`) property `var pendingNewWindowPicks = 0` — a one-item mailbox incremented by the Cmd+N command and drained by the new window on appear. No `ObservableObject` conformance (ContentView mutates/reads it at discrete lifecycle moments, never observes it). Singleton is an accepted trade-off (tiny, `@MainActor`-confined; avoids plumbing an `@EnvironmentObject` into `Commands`).

Buildable alone: compiles; `presentNewWindowFolderPanel()` delegates to the already-tested `addFolders`. Revert: delete the method + the new file.

### Tier 2 — Menu rewire + new-window creation (`FEditApp.swift`)

**Modify `FEdit/App/FEditApp.swift`:**

- Give the scene an identifier: `WindowGroup(id: "editor") { ContentView().frame(...) }` (keep `.defaultSize`, `.commands`). Value-less `WindowGroup(id:)` + `openWindow(id:)` creates a **new** window per call. **D4 watch:** adding `id:` where there was none may alter `@SceneStorage` scene-restoration identity — verify criterion 9 in this tier.
- In `FileCommands`, add `@Environment(\.openWindow) private var openWindow`.
- Split the command body into two groups:
  - `CommandGroup(replacing: .newItem)` — removes the default "New Window" and installs `Button("Open Folder…") { LaunchCoordinator.shared.pendingNewWindowPicks += 1; openWindow(id: "editor") }` with `.keyboardShortcut("n", modifiers: [.command])`, **no `.disabled`** (app-level). The increment runs on the main actor immediately before `openWindow`, so the new window's appear observes it.
  - `CommandGroup(after: .newItem)` — the focused-window items, with the rename:
    - `Button("Add Folder to Window…") { workspace?.presentOpenPanel() }` `.keyboardShortcut("o", modifiers: [.command, .shift])` `.disabled(workspace == nil)` (lowercase `"o"` + explicit `.shift`, the shipped spelling).
    - `Button("Save") { workspace?.saveOpenFile() }` `.disabled(workspace?.canSave != true)` (unchanged).
    - `Toggle("Autosave on File Switch", isOn: $autosaveOnFileSwitch)` (unchanged).

Buildable alone: Cmd+N opens a new empty window (picker wiring lands in Tier 3); Cmd+Shift+O adds to the focused window; exactly one Cmd+N item. Revert: restore the single `CommandGroup(after: .newItem)`, drop the `id:` and `@Environment`.

### Tier 3 — Drain the mailbox on appear + empty-state relabel (`ContentView.swift`, `SidebarView.swift`)

**Modify `FEdit/Views/ContentView.swift`:**

- Extend the **existing** `.onAppear` (after the current `didRestore` / `restore(fromJSON:)` lines) with a single deterministic check:
  - if `LaunchCoordinator.shared.pendingNewWindowPicks > 0 && workspace.roots.isEmpty && workspace.openFile == nil` → decrement the counter *synchronously* (claim it), then `DispatchQueue.main.async { workspace.presentNewWindowFolderPanel() }` (present after the window is on screen).
- **No** change to the session-restore hooks: `.onChange(of: workspaceSnapshot)` (late-arriving recovery) and `.onChange(of: workspace.snapshotJSON())` (save) are left exactly as shipped. There is no `didAutoPresentPicker` flag and no deferred pristine re-check — a Cmd+N window is a fresh scene that never restores, so nothing races.

**Modify `FEdit/Views/SidebarView.swift`:**

- Empty-state button: relabel to `Button("Add Folder to Window…") { workspace.presentOpenPanel() }` (decision 8 — same-window add; avoids the identical-label collision with the new-window menu item). Behavior otherwise unchanged.

Buildable alone: full (a)+(b) behavior. Revert: remove the `onAppear` addition and restore the empty-state button title.

### Tier 4 — SPEC.md updates

**Modify `SPEC.md`:**

- **§3, line ~21:** replace the "multiple editor windows via File → New Window (Cmd+N)" bullet with: multiple editor windows opened via **File → Open Folder…** (Cmd+N), which opens a new window and prompts for a folder that becomes the new window's sole root (Cancel leaves an empty window). Do **not** add any startup-picker text (descoped).
- **§5.1, line ~47:** change "Added via **File → Open Folder…** (Cmd+Shift+O)" to "Added to the focused window via **File → Add Folder to Window…** (Cmd+Shift+O)". The empty-state-button bullet (line ~52) still describes a button that opens a folder into the current window.
- **§10 menu table, lines ~163–164:** replace the two rows:
  - `| File → Open Folder… | Cmd+N | opens a new window and prompts for a folder (its sole root); Cancel leaves an empty window |`
  - `| File → Add Folder to Window… | Cmd+Shift+O | add top-level folder(s) to the focused window |`
  - Keep the `focusedSceneObject` note but qualify that **Open Folder… (Cmd+N) is app-level** (creates a window; not focused-window-scoped).

Docs only; revert = git revert the SPEC hunk.

## Interface between tiers

- **Tier 1 → 2/3:** `WorkspaceModel.presentNewWindowFolderPanel()` (single-select, sole-root); `LaunchCoordinator.shared.pendingNewWindowPicks: Int`. These are the entire coordination surface; Commands/ContentView never touch `NSOpenPanel` directly.
- **Tier 2 → 3:** the Cmd+N command guarantees (i) a fresh window via `openWindow(id: "editor")` and (ii) `pendingNewWindowPicks` incremented immediately prior. Tier 3 drains exactly one pending pick per fresh window on appear.
- **Tier 3 → 4:** none (SPEC documents the shipped behavior).
- **Contract with session-restore:** untouched. `restore(fromJSON:)`, `snapshotJSON()`, `didRestore`, both `.onChange` handlers keep their exact shipped semantics.

## Load-bearing assumptions

Verified against the shipped code read at planning time; names are real:

1. **`WorkspaceModel.addFolders(_ urls:[URL])`** standardizes, symlink-dedupes, skips non-directories, appends roots — so `presentNewWindowFolderPanel()` on an empty model yields the chosen folder as the sole root. ✅ (WorkspaceModel.swift ~L131).
2. **`WorkspaceModel.presentOpenPanel()`** is the shipped multi-select directories panel calling `addFolders(panel.urls)`; reused verbatim for "Add Folder to Window…" and the empty-state button. ✅ (~L345). *Note:* the TODO called it `openFolderPanel()`; the real name is `presentOpenPanel()`.
3. **`ContentView`** owns `@StateObject workspace`, `@SceneStorage("workspaceSnapshot") = ""`, `@State didRestore`, the `.onAppear` restore, and the two `.onChange` handlers this plan leaves intact. ✅ (ContentView.swift L45–L162).
4. **`FileCommands`** uses `@FocusedObject var workspace: WorkspaceModel?` in `CommandGroup(after: .newItem)`; the default "New Window" (Cmd+N) is auto-provided by SwiftUI in `.newItem`. ✅ (FEditApp.swift L51–L76).
5. **A fresh scene created via `openWindow(id:)` gets an empty `@SceneStorage` and never restores** (session-restore's verified pristine-scene assumption) — so draining the mailbox on its appear cannot fight a restore.
6. **SwiftUI facts (docs/community-verified; macOS 26.0 target → all APIs available):** value-less `WindowGroup(id:)` + `openWindow(id:)` opens a **new** window per call (no value-dedup); `CommandGroup(replacing: .newItem)` removes the default New Window item; `Commands` may hold `@Environment(\.openWindow)`.
7. **`WindowCloseGuard` / `AppDelegate`** (dirty-file guard on close/quit) are independent of this change and untouched. ✅ (WindowCloseGuard.swift).
8. **D4 (NOT assumed away):** whether adding `id:` to the `WindowGroup` preserves `@SceneStorage` scene-restoration identity is **unverified** and tested by criterion 9, not assumed.

## Out of scope

- **Change (c) — the startup auto-picker — entirely.** No launch-time folder prompt; startup behavior is exactly today's (restored session or blank window). All associated machinery (a startup one-shot flag, launch-time `presentNewWindowFolderPanel()` on the first window, deferred pristine re-check, any `didAutoPresentPicker` guard on the late-arriving `.onChange`) is intentionally not built.
- Passing the folder via `openWindow(value:)` / converting to `WindowGroup(for:)` (rejected — decision 1).
- New persistence keys or changes to which windows restore (system window restoration only).
- Reworking the empty-state button into a new-window action (decision 8 keeps it same-window).
- Changes to the scanner, filter parser, editor, highlighter, renderer, dirty-file dialog, or Cmd+Q/close flow.

## Auto-resolved (plan review)

Findings from adversarial plan review + the coordinator/user decision to descope change (c):

- **D1, D2, D3, D5 — RESOLVED BY DESCOPING.** These were all facets of the startup-picker vs `@SceneStorage`-restore race (late-arriving-snapshot collision, the deferred one-runloop pristine re-check, the one-shot `startupPickerArmed` claim, and the `didAutoPresentPicker` conjunct grafted onto the shipped late-arriving `.onChange(of: workspaceSnapshot)` guard). With change (c) removed, none of that machinery is built: the session-restore decision logic is left byte-for-byte as shipped, and the only auto-presentation is Cmd+N's deterministic mailbox drain on a fresh scene that never restores. The race no longer exists.
- **D4 (Medium) — FOLDED, not hand-waved.** Adding an `id:` to a `WindowGroup` that currently has none *may* change the scene's `@SceneStorage` restoration identity, so the very first relaunch after shipping this change could fail to restore a snapshot saved by the pre-change build. This is explicitly tested by **acceptance criterion 9** (build committed code → make a session → apply change → relaunch → confirm restore). **Accepted fallback if identity does change:** treat it as a **one-time session reset on upgrade** (documented in release notes / commit message) — no crash, no disk data loss, and every subsequent quit/relaunch restores normally. If even the one-time reset is deemed unacceptable at implementation time, the fallback-to-the-fallback is to keep the scene value-less and open command-created windows via a distinct second `WindowGroup(id:)` used only for that path — but the default is: accept and document the reset.
- **D6 (Nit) — FOLDED.** The new-window creation and `NSOpenPanel` presentation are verified **manually** only; the repo's `scripts/*Tests/main.swift` swiftc harnesses cannot drive `openWindow` or an app-modal `NSOpenPanel`. Stated on the acceptance list. `presentNewWindowFolderPanel()`'s effect (sole-root add) is indirectly covered by the existing `addFolders` tests.
- **T3 (Tension) — RESOLVED.** The sidebar empty-state button is **relabeled "Add Folder to Window…"** (still `presentOpenPanel()`, same-window) so it no longer collides with the new-window "Open Folder…" menu item; the label now matches the command whose behavior it shares (decision 8, criterion 7).

Accepted tensions (recorded, not changed):

- `LaunchCoordinator` is a `@MainActor` singleton mailbox — accepted over `@EnvironmentObject` plumbing into `Commands` for a two-line launch-coordination counter.
- If `pendingNewWindowPicks` ever leaked (e.g. `openWindow` failed to produce a scene), the next pristine window would drain it and show one extra picker — astronomically unlikely (openWindow reliably creates a window) and harmless; accepted.
