# open-save

**Risk tier:** standard — UI/state plumbing over well-known AppKit/SwiftUI APIs; no heavy algorithms or concurrency, and the blast radius is confined to WorkspaceModel, ContentView, SidebarView, and the File menu.

## Goal

Give FEdit a real document lifecycle per SPEC §7: opening a sidebar-selected file (UTF-8 with Latin-1 fallback, NUL-byte binary refusal), dirty tracking with an "Edited" window subtitle, atomic UTF-8 save via Cmd+S, and a guarded file-switch flow — silent autosave when the global setting is on (failed save aborts the switch), otherwise a four-button modal (Save / Always Autosave / Don't Save / Cancel, with Cancel reverting the sidebar selection). The same guard runs on window close and app quit. The File menu gains Save and the "Autosave on File Switch" checkmark toggle (§10). The stub `isMarkdown` flag (originally from (split-layout), since relocated by (editor-core) into a temporary debug bar at the top of the middle column) is replaced by the real value derived from the open file's extension; Tier 1 deletes that debug bar.

## Acceptance criteria

All manually testable against a folder containing `a.swift`, `b.md`, a Latin-1-encoded `.txt`, and a small binary (e.g. a PNG).

Opening:
1. Clicking a UTF-8 text file in the sidebar shows its content in the editor; window title becomes the file name; no subtitle.
2. A file that is not valid UTF-8 but contains no NUL bytes opens via Latin-1 fallback (content visible, no alert).
2a. **Encoding decision (SPEC-sanctioned):** editing and saving a Latin-1-opened file silently transcodes it to UTF-8 on disk — the original encoding is not preserved. This is a deliberate decision, not a bug. Note: the Latin-1 fixture is single-use — after one save it is a UTF-8 file and no longer exercises the fallback path.
3. **Binary refusal:** clicking a file containing NUL bytes shows an alert ("appears to be binary" wording); the editor keeps the previously open file and the sidebar highlight stays/reverts to it. An unreadable file (e.g. permissions) alerts likewise and stays put.
4. Opening `b.md` makes the preview column appear; switching to `a.swift` hides it (real `isMarkdown`; the (editor-core) temporary debug bar at the top of the middle column is gone).

Dirty tracking & save:
5. Typing in the editor sets the window subtitle to "Edited"; File → Save (Cmd+S) becomes enabled.
6. Cmd+S writes the file (verify on disk), clears the subtitle, and Save disables again. Save is disabled when no file is open or the file is clean.
7. Save into a read-only **parent directory** (`chmod 555` the folder) alerts and the file stays dirty. (Atomic saves are temp-file + rename and need only directory write permission — a `chmod 444` file does NOT make them fail, so the fixture must be the directory.)
7a. **Expected flip side of atomic writes:** saving over a `chmod 444` (read-only) file that sits in a writable directory **succeeds silently** — the rename replaces the read-only file. Verified behavior; documented as expected, not a bug.
8. Saving a file whose on-disk copy was deleted externally recreates it at the old path.

Switch with unsaved changes, autosave OFF (default):
9. With `a.swift` dirty, clicking `b.md` shows a modal "Save changes to 'a.swift'?" with exactly four buttons. (Dialogs are app-modal `runModal`, so all windows are blocked while one is up — deliberate, see Tier 3.)
9a. The dirty-file dialog also fires when the target file is clicked from a non-empty-filter **flat list** — filter-query's filtered rows must route through `requestOpen` exactly like tree rows.
10. **Save:** writes `a.swift`, then opens `b.md`. If that write fails, an error alert is shown and the switch is aborted (still on `a.swift`, still dirty).
11. **Always Autosave:** the File → "Autosave on File Switch" menu item becomes checked (persists across relaunch), `a.swift` is saved, `b.md` opens.
12. **Don't Save:** `b.md` opens; `a.swift` on disk is unchanged (edits discarded).
13. **Cancel** (and Escape): dialog closes, `a.swift` stays open and **the editor still shows the unsaved edited text** (not merely "stays dirty" — the buffer content must survive), and the sidebar highlight reverts to `a.swift` (not left on `b.md`).

Autosave ON:
14. **Silent path:** with the toggle checked and `a.swift` dirty, clicking `b.md` saves `a.swift` with no dialog and opens `b.md`.
15. **Failed autosave aborts the switch:** same as 14 but with `a.swift`'s **parent directory** read-only (`chmod 555`, per criterion 7 — a `chmod 444` file would not fail) — an error alert appears, the switch is aborted, selection reverts, `a.swift` stays open and dirty.

Close/quit:
16. Closing a window (Cmd+W / red button) with a dirty file runs the same decision: autosave-on saves silently then closes (failed save cancels the close); autosave-off shows the four-button dialog, where Cancel keeps the window open and Save/Always Autosave/Don't Save close it. **"Always Autosave" chosen here flips the global setting** (the File-menu checkmark turns on for all windows) — accepted, since the setting is global per SPEC.
17. Cmd+Q with a dirty window routes through the same per-window flow; Cancel in any window aborts quit. Clean windows close/quit without any dialog.
17a. **Two dirty windows, Cancel on the second:** Cmd+Q, resolve the first window's dialog (Save or Don't Save), then Cancel in the second — the first window's chosen action has already been applied (its save/discard stands), quit aborts, and **no window has closed**. Before showing each dialog the guard calls `makeKeyAndOrderFront` on that dialog's window so two same-named files in different windows are distinguishable.
17b. (session-restore)'s `@SceneStorage` persistence still works with the Tier 4 delegate proxy installed.
18. Re-opening the currently open file (clicking its own row) is a no-op — no dialog even when dirty.

## Tiers

### Tier 1 — Open-file state, reading, dirty tracking, real isMarkdown

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify), `FEdit/Views/ContentView.swift` (modify), `FEdit/Views/SidebarView.swift` (modify if it still sets selection directly).

- `WorkspaceModel` gains a nested `struct OpenFile { let url: URL; var text: String; var isDirty: Bool }` and `@Published var openFile: OpenFile?`. Computed: `var isMarkdown: Bool` (extension `md`/`markdown`, case-insensitive — the "language stub"; full language enum arrives in (syntax-highlighting)); `var openFileName: String?`; `var canSave: Bool` (`openFile?.isDirty == true`).
- Reading, private `loadText(from:) throws -> String`: `Data(contentsOf:)`; if data contains `0x00` throw a dedicated `binaryFile` error; decode UTF-8, else Latin-1 (`.isoLatin1` decode of arbitrary bytes always succeeds, so this is total for non-binary data).
- `open(_ url: URL)` (unguarded; guard comes in Tier 3): load, set `openFile` with `isDirty = false`, sync the published sidebar-selection property from (folder-sidebar) to `url`. On error: NSAlert (binary refusal wording vs. generic read error) and revert the selection property to `openFile?.url` so the highlight stays on the previous file (criterion 3).
- `var editorText: String { get set }` — getter returns `openFile?.text ?? ""`; setter writes `openFile.text` and sets `isDirty = true` only when the value actually changed. ContentView binds `CodeEditorView` to this via a `Binding` so programmatic loads (which set `openFile` wholesale) never mark dirty.
- ContentView: delete the (editor-core) **temporary debug bar at the top of the middle column** (where the old (split-layout) `isMarkdown` stub now lives) and the `(editor-core)` selection→load hook — per editor-core's plan this is a ContentView `.onChange` on the selection property; Tier 1 removes it and replaces it with the requestOpen flow. Drive the preview column from `model.isMarkdown` and the editor from `model.editorText` / `openFile == nil` placeholder. Pass `documentID: model.openFile?.url` to `CodeEditorView` — documentID drives undo-reset and the guarded text replace; wiring it to the selection property instead would break undo reset and the discard criterion (12). Add `.navigationTitle(model.openFileName ?? "FEdit")` and `.navigationSubtitle(model.openFile?.isDirty == true ? "Edited" : "")`.
- **Both** selection call sites call `model.open(url)` (renamed to `requestOpen` in Tier 3) instead of writing the selection property directly: the sidebar **tree rows** AND filter-query's **flat filtered rows** — per filter-query's plan they share the row tap action; verify both actually route through it (criterion 9a). Row highlight keeps reading the selection property.

*Buildable/revertible:* app opens files, refuses binaries, shows Edited subtitle, preview toggles on `.md`. No save yet.

### Tier 2 — Save and the File menu

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify), `FEdit/App/FEditApp.swift` (modify).

- `WorkspaceModel.saveOpenFile() -> Bool`: `text.data(using: .utf8)` written with `.atomic`; on success clear `isDirty`, return true; on failure show an NSAlert with the underlying error and return false (file stays dirty). Recreating an externally deleted file needs no extra code (plain atomic write to the old path).
- `WorkspaceModel` reads the autosave setting via `UserDefaults.standard.bool(forKey: SettingsKey.autosaveOnFileSwitch)` and can set it (for "Always Autosave").
- `FEditApp.swift`: add `SettingsKey.autosaveOnFileSwitch` alongside the existing (split-layout) keys; extend the existing `.commands` block: in the File menu group that already hosts Open Folder…, add `Button("Save")` (Cmd+S) calling the focused model's `saveOpenFile()`, `.disabled(model?.canSave != true)`, and `Toggle("Autosave on File Switch", isOn:)` bound to `@AppStorage(SettingsKey.autosaveOnFileSwitch)` (default false) — a menu Toggle renders as a checkmark item. The commands struct uses `@FocusedObject var model: WorkspaceModel?` (matching the `focusedSceneObject` published since (folder-sidebar)) so enablement tracks the focused window live.

*Buildable/revertible:* Cmd+S works with correct enablement; toggle persists. Switching files still unguarded.

### Tier 3 — Guarded switching: requestOpen with autosave / four-button dialog

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify).

- `enum DirtyResolution { case proceed, cancel }` and the shared routine `resolveDirtyFile() -> DirtyResolution`:
  - clean or no file → `.proceed`;
  - autosave ON → `saveOpenFile() ? .proceed : .cancel` (save failure already alerted by Tier 2 — this is the failed-autosave-aborts path);
  - autosave OFF → app-modal `NSAlert.runModal()`: message `Save changes to '<name>'?`, buttons added in order **Save**, **Always Autosave**, **Don't Save**, **Cancel** (Cancel gets Escape automatically by title). Save → `saveOpenFile() ? .proceed : .cancel`; Always Autosave → set the UserDefaults flag true, then same as Save; Don't Save → `.proceed`; Cancel → `.cancel`.
- `requestOpen(_ url: URL)` replaces Tier 1's `open`: no-op if `url == openFile?.url` (criterion 18); else run `resolveDirtyFile()` — `.proceed` calls the Tier 1 load path, `.cancel` reverts the published sidebar selection to `openFile?.url`. **Invariant (established in Tier 1, relied on here):** after Tier 1, writing the selection property has **zero side effects** — every selection→load trigger is removed regardless of where editor-core put it (editor-core's plan pins the hook as a ContentView `.onChange` on the selection; Tier 1 deletes that `.onChange` and replaces it with the requestOpen flow). Reverting on Cancel therefore only moves the highlight; it cannot re-trigger a load.
- **Dialog order (accepted for v1):** dirty resolution runs *before* the target file's readability is known, so choosing Save and then hitting a binary/unreadable target means a "wasted" save followed by the refusal alert (still on the old file, now clean). Accepted knowingly; the alternative — probe the target first, resolve dirtiness after — was rejected as added complexity for v1.
- `runModal` is deliberately synchronous/**app-modal** (not a per-window sheet) so Tier 4 can reuse the exact routine inside `windowShouldClose`. Consequence, accepted deliberately: while any dirty-file dialog is up, **all** windows are blocked, not just the affected one.

*Buildable/revertible:* criteria 9–15, 18 pass. Reverting this tier degrades to Tier 2 behavior (unguarded switch), nothing else breaks.

### Tier 4 — Same flow on window close and quit

*Files:* new `FEdit/App/WindowCloseGuard.swift` (or fold into `App/FEditApp.swift` if under ~60 lines), `FEdit/Views/ContentView.swift` (modify), `FEdit/App/FEditApp.swift` (modify).

- `WindowCloseGuard`: a tiny `NSViewRepresentable` placed in ContentView's background that walks to `view.window` on `viewDidMoveToWindow`/`updateNSView` and installs the guard, holding a weak reference to the window's `WorkspaceModel`. `windowShouldClose(_:)` returns `model.resolveDirtyFile() == .proceed`.
- **SwiftUI DOES install its own `NSWindowDelegate` on WindowGroup windows** — its scene lifecycle and `@SceneStorage` machinery depend on it — so the guard must NOT simply replace `window.delegate`. Mandated approach: a **forwarding proxy object** that wraps the existing SwiftUI delegate — implementing `windowShouldClose` itself and forwarding everything else — and **overrides `responds(to:)` to return the union of both delegates' selectors** (`forwardingTarget(for:)` alone is insufficient: NSWindow checks `responds(to:)` before dispatching optional protocol methods, so unadvertised selectors would silently never reach SwiftUI's delegate). Additionally, **re-verify after scene updates** (in `updateNSView`) that the proxy is still installed — SwiftUI can reassert its own delegate — and re-wrap if it was replaced.
- Quit: add `@NSApplicationDelegateAdaptor` in `FEditApp` with `applicationShouldTerminate(_:)` iterating `NSApp.windows` and invoking each window delegate's `windowShouldClose` logic (via the same guard objects); any `.cancel` returns `.terminateCancel`, else `.terminateNow` — this is the SPEC-sanctioned "route quit through the same dialog per window". Before showing each window's dialog, call `makeKeyAndOrderFront` on that window so the user can see which document the dialog refers to (criterion 17a); a Cancel aborts the loop immediately — actions already applied to earlier windows (saves/discards) stand, and no window is closed.

*Buildable/revertible:* criteria 16–17b pass, including "(session-restore)'s `@SceneStorage` persistence still works with the proxy installed" (17b); removing this tier only loses close/quit guarding.

## Interface between tiers

`WorkspaceModel` public surface, frozen at the end of each tier:

- Tier 1 → later: `struct OpenFile { url, text, isDirty }`, `@Published var openFile: OpenFile?`, `var editorText: String { get set }`, `var isMarkdown: Bool`, `var canSave: Bool`, private `loadText(from:)` + the load/alert path.
- Tier 2 → 3/4: `func saveOpenFile() -> Bool` (alerts internally, `false` = still dirty), `SettingsKey.autosaveOnFileSwitch` as the single UserDefaults key shared by the menu `@AppStorage` and the model's direct `UserDefaults` reads/writes.
- Tier 3 → 4: `enum DirtyResolution { proceed, cancel }`, `func resolveDirtyFile() -> DirtyResolution` (synchronous, app-modal, safe to call from `windowShouldClose`), `func requestOpen(_ url: URL)`.
- Tier 4 consumes only `resolveDirtyFile()`; it adds no model API.

## Load-bearing assumptions

From items expected to have shipped before this one:

1. **(folder-sidebar)** `Models/WorkspaceModel.swift` exists as a per-window `ObservableObject` with `roots`, a published selected-file URL property, and is exposed to commands via `.focusedSceneObject(model)`; `App/FEditApp.swift` already has a `.commands` File group (Open Folder…). If the shipped selection property is named differently (e.g. `selection` vs `selectedFileURL`), Tier 1/3 adopt the existing name — revert-on-cancel writes that property.
2. **(editor-core)** `Editor/CodeEditorView.swift` takes a `Binding<String>` for text (feedback-loop-guarded), resets undo when the bound `documentID` changes (Tier 1 wires this to `model.openFile?.url`), and exposes cursor/first-visible-line callbacks (untouched here). Editor-core's plan pins its selection→load hook as a ContentView `.onChange` on the selection property — Tier 1 deletes that `.onChange` and replaces it with the requestOpen flow.
3. **(split-layout)/(editor-core)** the stub `isMarkdown` flag now lives in editor-core's temporary debug bar at the top of the middle column (Tier 1 deletes the bar), and `SettingsKey` constants live in `App/FEditApp.swift` — the autosave key joins them.
4. SwiftUI on macOS 26 supports `.navigationSubtitle` on window content and renders a `Toggle` inside `.commands` as a checkmark menu item (both long-standard macOS SwiftUI behavior). SwiftUI **does** install its own `NSWindowDelegate` on WindowGroup windows — Tier 4's proxy wraps it rather than replacing it.
5. No sandbox (SPEC §2): plain-path `Data(contentsOf:)`/atomic writes need no security-scoped access.

## Out of scope

- Language detection beyond the `isMarkdown` extension check — the real language enum belongs to (syntax-highlighting).
- Preview column content and scroll sync — (markdown-renderer)/(markdown-preview); this item only supplies the real `isMarkdown` gate.
- Persisting open file/cursor/filter across relaunch — (session-restore).
- File-system watching, external-change detection, save-as, encodings beyond UTF-8/Latin-1, multi-window coordination on the same file (last save wins per SPEC §11), find/replace, tabs.

## Auto-resolved (plan review)

Findings from adversarial plan review, folded in above:

**Defects fixed**

1. *(High, empirically verified)* `chmod 444` on a file does NOT fail an atomic save — atomic writes (temp file + rename) need only directory write permission, and the write succeeds and replaces the read-only file. Criteria 7 and 15 now use a read-only parent directory (`chmod 555`); new criterion 7a documents the flip side (silent success over a 444 file) as expected behavior.
2. *(High)* Tier 4's original assumption ("WindowGroup windows have no delegate") was backwards: SwiftUI installs its own `NSWindowDelegate` (scene lifecycle + `@SceneStorage`). Tier 4 now mandates a forwarding proxy wrapping the existing delegate, with `responds(to:)` overridden to union both delegates (forwardingTarget alone is insufficient because NSWindow checks `responds(to:)` before dispatching optional protocol methods), plus re-verification after scene updates that the proxy is still installed. New criterion 17b: `@SceneStorage` persistence still works with the proxy.
3. *(High)* Replaced the vague "revert must not recurse" with the real invariant: after Tier 1, writing the selection property has zero side effects — editor-core's ContentView `.onChange` selection→load hook is explicitly deleted and replaced by the requestOpen flow. Criterion 13 sharpened: Cancel must preserve the unsaved edited *text*, not just the dirty flag.
4. *(Medium)* Tier 1 now names both selection call sites — sidebar tree rows AND filter-query's flat filtered rows (shared row tap action) — and criterion 9a verifies the dialog fires from a filtered flat list.
5. *(Medium)* New criterion 17a: two dirty windows with Cancel on the second — the first window's applied action stands, quit aborts, no window closed; the guard brings each dialog's window to front (`makeKeyAndOrderFront`) so same-named files are distinguishable.
6. *(Low)* Tier 1's ContentView bullet now explicitly passes `documentID: model.openFile?.url` to CodeEditorView (wiring it to the selection property would break undo reset and the discard criterion).
7. *(Nit)* Wording updated: the isMarkdown stub being deleted now lives in editor-core's temporary debug bar at the top of the middle column.

**Tensions resolved (recorded decisions)**

8. Dialog order: dirty resolution runs before target readability is known — accepted for v1 (a wasted save before a binary-refusal alert is acceptable); probe-target-first rejected as extra complexity. (Tier 3 note.)
9. "Always Autosave" in a window-close dialog flips the global setting — accepted, setting is global per SPEC. (Criterion 16.)
10. Latin-1 files are silently transcoded to UTF-8 on first save — SPEC-sanctioned decision; the Latin-1 fixture is single-use. (Criterion 2a.)
11. App-modal `runModal` (not per-window sheets) — deliberate, so Tier 4 reuses the routine in `windowShouldClose`; all windows are blocked during dialogs. (Tier 3 note, criterion 9.)
