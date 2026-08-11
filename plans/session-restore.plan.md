# session-restore

**Risk tier:** standard — pure state wiring (Codable snapshot + @SceneStorage) over already-shipped components; no algorithms, no concurrency, blast radius limited to `WorkspaceModel`, `ContentView`, one small additive hook in `CodeEditorView`, a new Foundation-only `Models/WorkspaceSnapshot.swift`, **and a refactor of open-save's shipped `open(_:)` routine** into a silent core + presenting wrapper (this modifies a shipped routine; its interactive alerting behavior must be regression-checked).

## Goal

Per-window session persistence per SPEC §3 and §9: each window's open top-level folders, open file path, filter text, and cursor position survive quit/relaunch via `@SceneStorage`-backed JSON snapshots, while window frames come back through system window restoration and the globally-persisted settings (dividers, autosave) continue to restore via `@AppStorage`. Restore is silent and dialog-free: missing folders are dropped, a missing file is simply not opened, file content is always re-read from disk, and the cursor is restored and scrolled into view. Finish with multi-window polish verification: independent per-window state and all menu commands targeting the focused window.

## Acceptance criteria

All manually verifiable on a debug build (quit with Cmd+Q; relaunch from Xcode or Finder — window restoration must be enabled in System Settings, the macOS default):

1. **Folders restore.** Open two folders in a window, quit, relaunch → same window shows both folders as sidebar sections, tree re-scanned fresh from disk.
2. **Missing folder dropped silently.** Open a folder, quit, delete the folder on disk, relaunch → that section is absent; no alert, no crash; other folders intact.
3. **File restores from disk.** Open `main.swift`, type nothing, quit, edit the file externally, relaunch → editor shows the *external* content (content is re-read from disk, never persisted by the app), window title shows the file name, syntax highlighting applied.
4. **Missing file not opened.** Open a file, quit, delete the file, relaunch → folders restore, editor shows the "No file open" placeholder; no alert.
5. **Cursor restored and visible.** Put the cursor at line ~200 of a long file, scroll elsewhere, quit, relaunch → cursor (insertion point) is at the same character offset and that location is scrolled into view. If the file shrank externally, the cursor clamps to the new end without crashing.
6. **Filter restores.** Type `.py OR .swift` in the filter, quit, relaunch → search field contains the text and the sidebar is in flat filtered mode with the same matches.
7. **No dialogs during restore.** With autosave OFF, relaunch never shows the unsaved-changes dialog (there is nothing dirty at launch, and the restore path must not route through `requestOpen`'s dialog); a restore-time read failure (file turned binary/unreadable) results in "not opened" silently, not an alert.
8. **Per-window independence.** Two windows with different folders/files/filters each restore their own state after relaunch; Cmd+N still opens a pristine empty window (no snapshot leakage into new scenes).
9. **Frames + globals.** Window positions/sizes restore via system restoration; divider positions and the autosave toggle restore globally exactly as before this item (no regression).
10. **Focused-window commands.** With two windows open, Cmd+Shift+O, Cmd+S, and the Autosave toggle act on / reflect the focused window's `WorkspaceModel` (Save disabled state tracks the focused window).
11. **Robustness.** Empty or corrupt `@SceneStorage` JSON → fresh empty window, no crash. Markdown file restore also restores the preview column.
12. **Cursor round-trip.** quit → relaunch → quit → relaunch preserves the cursor (round-trip, no touch in between) — guards against the immediate post-restore save clobbering the stored cursor with the model's default `0`.

## Tiers

### Tier 1 — Snapshot model in `WorkspaceModel`

**Add `FEdit/Models/WorkspaceSnapshot.swift` (Foundation-only) and modify `FEdit/Models/WorkspaceModel.swift`:**

- Add `struct WorkspaceSnapshot: Codable` in its own small file **`Models/WorkspaceSnapshot.swift`** with no AppKit import (`WorkspaceModel.swift` imports AppKit, so the snapshot lives separately to stay compilable by a swiftc-script harness): `rootPaths: [String]`, `openFilePath: String?`, `filterText: String`, `cursorLocation: Int?` (UTF-16 offset into the document, matching `NSRange.location`). Declare **tolerant decoding** up front — a custom `init(from:)` using `decodeIfPresent` + defaults — so missing keys decode to defaults; this makes the "all fields optional-with-defaults" contract real rather than aspirational.
- Add `scripts/SnapshotTests/main.swift` (repo swiftc-script convention; the file must be named `main.swift`) exercising the Foundation-only snapshot surface so corrupt-JSON handling is permanently testable: corrupt JSON → nil/no-op, missing keys → defaults, round-trip fidelity.
- Add `@Published private(set) var cursorLocation: Int = 0` plus `func noteCursorMoved(_ location: Int)` — the sink for the cursor callback that `(editor-core)` already emits (ContentView wires it in Tier 2). If `(open-save)` already tracks a cursor on the model, reuse that property instead of adding a duplicate. `noteCursorMoved` also clears `pendingCursorRestore` the first time it fires after a restore (the editor's restore-consume triggers it via the callback — see Tier 2). Accepted trade-off: `@Published cursorLocation` re-evaluates the window body per caret move, including the sidebar's inline filter scan — fine for v1 (spec sanctions linear scans; typing already re-evaluates per keystroke); the alternative (non-published property + timer-based save) was considered and rejected.
- Add `func snapshotJSON() -> String?` — builds `WorkspaceSnapshot` from current state (`roots` → absolute paths, open file URL → path, `filterText`, cursor), encodes with `JSONEncoder`. On encode failure it must **not** return `""` — it returns `nil` and the caller skips the write, keeping the last-good stored snapshot (an empty write would erase a valid stored snapshot).
- Add `func restore(fromJSON json: String)` — decodes (silently returns on empty/corrupt JSON), then:
  - roots: keep only paths where `FileManager.default.fileExists(atPath:isDirectory:)` (with its `ObjCBool` out-pointer) reports a directory; add via the existing root-adding/scan path (bypassing `NSOpenPanel`), so trees are scanned fresh;
  - filter: assign `filterText` directly;
  - file: if the path exists and reads successfully, open it via a **silent non-interactive open**. The existing non-interactive open in open-save ALERTS on failure, so merely exposing it is not enough: refactor open-save's `open(_:)` into a throwing/silent `loadText(from:)` core plus a presenting wrapper; restore calls the silent variant; the interactive path's alerting behavior is regression-checked. Never call `requestOpen` (no dialog per §9/§7) and swallow read/binary failures silently instead of alerting (spec: "simply not opened");
  - cursor: stash the decoded value in `var pendingCursorRestore: Int?` (clamped later against actual text length) for Tier 2's editor to consume, **and also write it into `cursorLocation`** — if only the stash were set, the immediate post-restore snapshot save would clobber the stored cursor with `cursorLocation`'s default `0` (see acceptance 12). The editor's clamped application then re-reports the (possibly clamped) value through the cursor callback, converging both.
  - Restore work (root rescans + one file read) runs synchronously on the main thread at launch — accepted per SPEC §11; no async loading in v1.
- Guard: `restore` is a no-op if the model already has roots or an open file (only pristine, freshly-created scenes restore).

Buildable alone: compiles, and the snapshot surface is exercised by `scripts/SnapshotTests` (round-trip, corrupt JSON, missing keys); missing-path dropping is checkable from a temporary debug hook. Revertible: delete the additions; nothing else references them yet.

### Tier 2 — `@SceneStorage` wiring + cursor restore

**First step of this tier:** verify the Cmd+N pristine-scene assumption (load-bearing assumption 7) before wiring anything else — it is the foundation the per-scene isolation rests on.

**Modify `FEdit/Views/ContentView.swift`** (model property name is `workspace`):

- `@SceneStorage("workspaceSnapshot") private var workspaceSnapshot: String = ""`.
- Restore: in `.onAppear` (once per scene, guarded by a `@State private var didRestore = false`), call `workspace.restore(fromJSON: workspaceSnapshot)`. **Late-arriving `@SceneStorage` recovery rule:** besides the `.onAppear` attempt, also attempt restore on the first `.onChange(of: workspaceSnapshot)` transition from empty → non-empty WHILE the model is still pristine (no roots, no open file); only after a successful or declined restore does the save path start writing. This prevents the `didRestore` guard from arming a clobber of the stored snapshot when the platform delivers the string late.
- Save: keep `workspaceSnapshot` current whenever restorable state changes — `.onChange(of:)` over **post-change values only** (a single `.onChange(of: workspace.snapshotJSON())`, or `.onChange` over the individual pieces: roots, open file URL, filterText, cursorLocation). `onReceive(model.objectWillChange)` is **struck as an option**: `objectWillChange` emits on `willSet`, so it would persist the PRE-change snapshot and the last change before quit would never be saved. Skip writes until restore has completed per the recovery rule above, and skip the write when `snapshotJSON()` returns `nil` (keep last-good). Accepted trade-offs: the snapshot is recomputed per keystroke/caret move with **no debounce** — it is an in-memory assignment and the system persists `@SceneStorage` at its own cadence; the `.onChange` dedup assumes `JSONEncoder` byte-stability for unchanged state, and a false-positive "change" is harmless (idempotent write).
- Pass `workspace.pendingCursorRestore` to the editor as `cursorToRestore` (see below).
- Wire the editor's existing cursor callback to `workspace.noteCursorMoved(_:)` if `(open-save)`/`(editor-core)` wiring didn't already land it on the model.

**`FEdit/Editor/CodeEditorView.swift` — cursor seam (cross-plan DECISION; editor-core's plan now ships this):**

- `CodeEditorView` has a defaulted parameter `cursorToRestore: Int? = nil`. The coordinator consumes it **one-shot per `documentID` change**: clamps to the text length, applies the selection synchronously (`setSelectedRange(NSRange(location: clamped, length: 0))`), defers `scrollRangeToVisible(_:)` to the next runloop pass, then fires `onCursorChange(clampedValue)`.
- The coordinator has **no model reference by design** — ContentView passes `workspace.pendingCursorRestore` as the parameter, and the model clears `pendingCursorRestore` itself the next time `noteCursorMoved` fires (which the restore-consume triggers via the `onCursorChange` callback).
- Scroll ordering vs initial layout: the deferred scroll runs on the next runloop pass **after** the doc-switch branch's scroll-to-top, and therefore wins — the restored cursor location ends up visible.
- UTF-16 clamp note: the clamped offset can land inside a surrogate pair; NSTextView tolerates/adjusts it. The clamp guards range validity, not grapheme alignment — accepted.

Buildable alone: full restore behavior works end-to-end (acceptance 1–8, 11). Revertible: remove the SceneStorage property, the onAppear/onChange modifiers, and the editor hook.

### Tier 3 — Multi-window polish and verification (no new features)

- **Frames:** confirm nothing opts out of restoration (`FEditApp` must not set `.windowResizability`/restoration-disabling modifiers beyond what shipped; no `NSQuitAlwaysKeepsWindows` tampering). Verify acceptance 9. Code changes only if a regression is found.
- **Focused window:** audit `FEdit/App/FEditApp.swift` commands — Open Folder…, Save, Autosave toggle must read the model through `@FocusedObject`/`focusedSceneObject` (SPEC §10) and Save's `disabled` state must track the focused window. Fix any command that captured a specific model instance.
- **New-window hygiene:** the Cmd+N pristine-scene verification was moved to the START of Tier 2 (load-bearing assumption 7); here only re-confirm it end-to-end and verify that closing a dirty window still routes through the `(open-save)` close/quit dialog — session-restore must not have changed that path.
- Run the full acceptance list, including the two-windows-same-file case (SPEC §11: allowed, last save wins).

Revertible: this tier is verification plus at most spot fixes in `FEditApp.swift`.

## Interface between tiers

- Tier 1 → Tier 2: `WorkspaceModel.snapshotJSON() -> String?`, `WorkspaceModel.restore(fromJSON:)`, `WorkspaceModel.noteCursorMoved(_:)`, `WorkspaceModel.pendingCursorRestore: Int?`. Tier 2 treats these as the complete persistence API; ContentView never encodes/decodes JSON itself. The cursor seam into the editor is editor-core's `cursorToRestore: Int? = nil` parameter (cross-plan decision, see Tier 2).
- Tier 2 → Tier 3: no new API; Tier 3 only observes behavior and touches `FEditApp.swift` command wiring if broken.
- Snapshot JSON shape (`rootPaths`/`openFilePath`/`filterText`/`cursorLocation`) is the stable contract; tolerant decoding is implemented from day one (custom `init(from:)` with `decodeIfPresent` + defaults, exercised by `scripts/SnapshotTests`), so additive fields later (e.g. the scene nonce in assumption 7's fallback) need no schema break or versioning in v1.

## Load-bearing assumptions

Expected state after all prior TODO items have shipped — verify each at implementation start and adapt names to what actually exists:

1. **`Models/WorkspaceModel.swift`** (from folder-sidebar, filter-query, open-save): per-window `ObservableObject` created per scene (one instance per `WindowGroup` scene, injected into `ContentView` as `workspace` and published to menus via `focusedSceneObject`); has `roots` (tree roots with their URLs), an internal add-root/scan path callable without `NSOpenPanel`, `filterText: String` (published), open-file state exposing the open file's `URL`, and a `requestOpen(_:)` that shows the unsaved-changes dialog plus an internal non-interactive open used after the dirty check. That non-interactive open **alerts on failure**, so Tier 1 refactors it into a silent `loadText(from:)` core + presenting wrapper (exposure alone is not enough).
2. **`Editor/CodeEditorView.swift`** (from editor-core): reports cursor position and first visible line via callbacks, and — per the cross-plan decision — ships the `cursorToRestore: Int? = nil` defaulted parameter with one-shot-per-`documentID` consumption in the coordinator. Tier 2 uses that seam; it does not add its own.
3. **`App/FEditApp.swift`** (from folder-sidebar, open-save): commands already use `focusedSceneObject`; autosave is a global `@AppStorage` Bool; divider positions are global `@AppStorage` (from split-layout) and need no per-scene handling here.
4. **Open flow** (from open-save): opening a file re-reads from disk, detects binary/encoding, resets undo, sets `isMarkdown` driving the preview column — so restoring a file automatically restores highlighting and preview with no extra work in this item.
5. **Restore-time cleanliness:** at scene appear there is never a dirty buffer (fresh model), so bypassing `requestOpen` during restore cannot lose data.
6. Cursor is representable as a single UTF-16 offset (`NSRange.location` of a zero-length selection) — consistent with the NSTextView stack from editor-core.
7. **Cmd+N pristine-scene (named, load-bearing):** a scene created via Cmd+N gets a fresh, empty `@SceneStorage` value — no leakage of another scene's snapshot into new scenes. Verified FIRST in Tier 2, before any other wiring. **Fallback if leakage is observed** (kept lightweight): add a scene nonce stored IN the snapshot; on restore, if the snapshot's nonce matches one already claimed by a live scene this launch, refuse restore. The design permits this without a schema break because decoding is tolerant (see the snapshot test harness in Tier 1).

## Out of scope

- Persisting file *content*, scroll position beyond cursor-visible, sidebar expansion state, or selection ranges with length (spec names cursor only).
- Divider positions and autosave persistence (already shipped globally in split-layout / open-save; only regression-checked here).
- Snapshot versioning/migration, iCloud/defaults export, or cross-window state sharing.
- File-system watching, security-scoped bookmarks (app is unsandboxed by spec §2).
- Any change to the unsaved-changes dialog flow, scanner, filter parser, highlighting, or renderer.

## Auto-resolved (plan review)

Findings from adversarial plan review, folded in above:

1. **Cursor round-trip (High):** `restore()` now writes the decoded cursor into `cursorLocation` in addition to stashing `pendingCursorRestore`, so the immediate post-restore save cannot clobber the stored cursor with `0`; the editor's clamped application re-reports through the cursor callback. New acceptance criterion 12 (quit → relaunch → quit → relaunch, no touch in between).
2. **Cursor seam (High, cross-plan DECISION):** editor-core's plan ships `cursorToRestore: Int? = nil` on `CodeEditorView`; the coordinator consumes it one-shot per `documentID` change (clamp, synchronous selection, `scrollRangeToVisible` deferred to the next runloop, then `onCursorChange(clampedValue)`). ContentView passes `workspace.pendingCursorRestore`; the model clears it on the next `noteCursorMoved`. The "coordinator clears via model reference" and "parameter or model reference" options were deleted — the coordinator has no model reference by design.
3. **Save mechanism (High):** `onReceive(model.objectWillChange)` struck entirely — it emits on `willSet`, persisting the pre-change snapshot, so the last change before quit would never be saved. `.onChange(of:)` over post-change values is mandated.
4. **Silent open (Medium):** the existing non-interactive open alerts on failure; Tier 1 now refactors open-save's `open(_:)` into a throwing/silent `loadText(from:)` core + presenting wrapper, restore calls the silent variant, the interactive alerting path is regression-checked, and the blast-radius statement names this shipped-routine modification.
5. **Scroll ordering (Medium):** the restore scroll is deferred to the next runloop pass after the doc-switch branch's scroll-to-top, and therefore wins — ordering stated explicitly in Tier 2.
6. **Cmd+N pristine-scene (Medium):** promoted from an acceptance bullet to named load-bearing assumption 7 with a stated lightweight fallback (snapshot nonce; refuse restore if a live scene already claimed it this launch — no schema break thanks to tolerant decoding); its verification moved to the START of Tier 2, not the end of Tier 3.
7. **Late-arriving `@SceneStorage` (Medium):** recovery rule added — also attempt restore on the first empty→non-empty `.onChange(of: workspaceSnapshot)` while the model is pristine; the save path starts writing only after a successful or declined restore, so the `didRestore` guard can't arm a clobber.
8. **Permanent testability (Low):** snapshot Codable + validation factored into Foundation-only `Models/WorkspaceSnapshot.swift` (WorkspaceModel imports AppKit), exercised by `scripts/SnapshotTests/main.swift` per the repo's swiftc-script convention: corrupt JSON → nil/no-op, missing keys → defaults (tolerant decoding declared, fixing the earlier contradiction), round-trip fidelity.
9. **Nits:** API corrected to `fileExists(atPath:isDirectory:)` with `ObjCBool` pointer; tolerant decoding made explicit (custom `init(from:)` with `decodeIfPresent` + defaults); `snapshotJSON()` returns `String?` and never `""` on encode failure (skip write / keep last-good); ContentView references aligned to the `workspace` property name.

Accepted tensions (recorded, not changed):

10. `@Published cursorLocation` re-evaluates the window body per caret move (including the sidebar's inline filter scan) — accepted for v1 (spec sanctions linear scans; typing already re-evaluates per keystroke); non-published + timer-based save considered and rejected.
11. Snapshot recomputed per keystroke/caret move with no debounce — in-memory assignment, system persists `@SceneStorage` at its own cadence; the `.onChange` dedup assumes `JSONEncoder` byte-stability, and a false-positive change is a harmless idempotent write.
12. Synchronous restore work (root rescans + file read) on the main thread at launch — accepted per SPEC §11.
13. UTF-16 clamp can land inside a surrogate pair — NSTextView tolerates/adjusts it; the clamp guards range validity, not grapheme alignment.
