# baked-in-autosave

**Risk tier:** hi — mutates the core save/dirty path (data-integrity stakes) and defines a last-writer coordination seam with (external-change-watch) planned in parallel; a wrong ordering or a missed echo silently loses either the user's or an external tool's edits.

## Goal

Make autosave **unconditional and always-on**, replacing (open-save)'s opt-in "Autosave on File Switch" model. After the user stops typing, the open file is written to disk on a short debounce (~0.75 s); it is also flushed on file switch, on app focus loss, and on window close / quit (reusing the existing `WindowCloseGuard` + quit path). The on-disk file therefore tracks the editor within a second, so an external tool editing the same file (e.g. Claude) has the smallest possible window to clobber unsaved edits, and "dirty" becomes a transient state rather than a mode. Because autosave is unconditional, the (open-save) "Autosave on File Switch" toggle, its persisted setting, and the four-button Save/Always Autosave/Don't Save/Cancel unsaved-changes dialog are all **removed** (this item edits `SPEC.md` accordingly — see the SPEC section — and supersedes (open-save)'s acceptance criteria 9–16). The failed-save alert is kept and surfaces at explicit save boundaries. The **one** surviving dialog is a minimal two-button "Close Without Saving / Cancel" escape shown only at the close/quit boundary when the flush keeps failing, so a persistently-unwritable location (read-only dir, full or unmounted volume) can never make the app un-quittable. This item also **defines the coordination seam** that (external-change-watch) will consume so a pending autosave never fights a just-detected external reload.

## Acceptance criteria

Manually testable against a folder containing `a.swift`, `b.md`, and (for the failure paths) a subfolder whose permissions can be flipped with `chmod`.

Always-on debounced autosave (Tier 1):
1. Type into `a.swift`, then stop. Within ~0.75 s the on-disk file matches the editor (verify with an external `cat`/`stat`) and the "Edited" subtitle clears **on its own**, with no Cmd+S.
2. During a continuous typing burst the file is **not** written per keystroke — the debounce coalesces. `a.swift`'s mtime does not advance while typing; a single write lands ~0.75 s after the last keystroke.
3. Cmd+S still works and is immediate; File → Save is enabled only while the buffer is dirty (unchanged `canSave` semantics — after an autosave the file is clean, so Save disables).
4. **Undo is untouched:** type, wait for the autosave to fire (subtitle clears), then Cmd+Z still reverts the typed text. Autosave creates no undo step and never resets the undo stack.
5. **No feedback loop:** an autosave (dirty→clean) does not re-schedule another autosave, does not re-enter the `editorText` setter, and does not trigger a highlight storm (the buffer text is unchanged by a save).

Switch / close / quit become a silent flush; toggle + dialog gone (Tier 2):
6. Type into `a.swift` and **immediately** (< 0.75 s, before the debounce fires) click `b.md`: `a.swift` is saved silently and `b.md` opens — **no dialog** (the four-button Save/Always Autosave/Don't Save/Cancel dialog is gone). Verify `a.swift` on disk has the edit.
7. Switching when the buffer is already clean (autosave already fired) is instant — no save, no dialog (unchanged).
8. **Failed flush aborts the switch:** `chmod 555` `a.swift`'s parent directory, type, then immediately click `b.md` — the "Cannot Save File" alert appears and the switch is aborted (still on `a.swift`, still dirty, sidebar highlight reverts).
9. File → menu no longer contains "Autosave on File Switch". File → Save is still present with correct enable/disable.
10. **Close / quit:** Cmd+W (or red button) / Cmd+Q on a just-typed (dirty, < 0.75 s) window saves silently then closes/quits — no dialog. With the parent directory read-only the flush fails; the `saveOpenFile` "Cannot Save File" alert appears, and then a **minimal two-button escape** alert "Couldn't save '<name>'" with **Close Without Saving** and **Cancel** — Cancel keeps the window open (quit aborts), Close Without Saving discards and closes/quits. This is the only surviving dialog, and it exists solely so a persistently-failing save can never make the app un-quittable. The existing `WindowCloseGuard` / `applicationShouldTerminate` paths are unchanged and simply observe `resolveDirtyFile(context:)`'s new body (they pass the close/quit context).

Focus-loss flush (Tier 3):
11. Type into `a.swift`, then switch to another app (FEdit resigns active) **before** the debounce fires: `a.swift` is written near-immediately and the subtitle clears — the exposure window collapses to ~0.

Anti-spam on repeated debounce failure (Tier 1 decision, verified in Tier 2):
12. With `a.swift`'s parent directory read-only, continuous typing does **not** spam a modal alert every 0.75 s. The buffer stays dirty ("Edited" persists as the passive signal); the failure is actively surfaced (alert) only at an explicit save boundary — Cmd+S, file switch, close, or quit.

(The (external-change-watch) coordination invariants are stated as seam guarantees below, not as manual criteria, since that item is not yet shipped.)

## Tiers

### Tier 1 — Always-on debounced autosave in WorkspaceModel

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify).

- New stored state:
  - `private var pendingAutosave: DispatchWorkItem?` — the in-flight debounced write, cancel-and-reschedule per keystroke (mirrors `CodeEditorView`'s existing `pendingHighlight` idiom).
  - `private static let autosaveInterval: TimeInterval = 0.75` (within the TODO's 0.5–1 s band).
- **Debounce hung off the `editorText` setter** (chosen over reusing `CodeEditorView`'s highlight debounce): after `openFile = file` in the existing setter, call `scheduleAutosave()`. Living on the model means every path that dirties the buffer — today the editor binding, tomorrow any programmatic edit — gets autosave for free, and the debounce sits next to the state it guards. (The current code has no programmatic `editorText` writes, but the model-side hook is the forward-safe placement and is what the TODO specifies.)
- `private func scheduleAutosave()`: `pendingAutosave?.cancel()`; build a `DispatchWorkItem { [weak self] in guard let self, self.openFile?.isDirty == true else { return }; self.saveOpenFile(alertOnFailure: false) }`; store it; `DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveInterval, execute:)`. `[weak self]` so a closed window's model isn't kept alive or fired; the `isDirty` re-check at fire time makes a straggler (fired after a save/reload cleaned the buffer) a no-op.
- `saveOpenFile(alertOnFailure: Bool = true) -> Bool` (extend the existing signature; default `true` keeps Cmd+S and `resolveDirtyFile` call sites source-compatible). On success: clear `isDirty`, republish `openFile`, and `cancelPendingAutosave()` (an explicit save makes the pending debounced one redundant). On failure: alert **only if `alertOnFailure`**, leave the file dirty, return `false`. (This success branch is the single shared write path (external-change-watch) will hang its `FileSignature` capture off when it ships — this item does not add that capture.)
- **Debounced-failure decision (anti-spam):** the debounced work item calls `saveOpenFile(alertOnFailure: false)`. A failing autosave in a read-only location must not throw a modal every 0.75 s. It stays silent, leaves the file dirty (the persistent "Edited" subtitle is the passive signal), and the failure is actively surfaced at the next explicit save boundary — Cmd+S or the `resolveDirtyFile()` flush (both `alertOnFailure: true`). Rejected alternatives: alert-per-tick (modal spam), and an alert-once-per-failure-streak flag (extra state for marginal benefit).
- `func cancelPendingAutosave()` (**required, exposed** — not private): `pendingAutosave?.cancel(); pendingAutosave = nil`. This is a consumed part of the coordination seam — `applyLoadedFile` and `saveOpenFile`'s success branch call it internally, and (external-change-watch) calls it at the top of its own reload path so a straggler autosave can't clobber a just-applied external reload. (external-change-watch) will also capture `FileSignature` where this item captures nothing; this plan owns only the cancellation hook.
- `applyLoadedFile(url:text:)`: **call `cancelPendingAutosave()` first** so a stale timer from the previous file can never write the newly loaded one, then the existing `openFile = …; selectedFileURL = url`. This is the file-switch load path only; external reloads do **not** route through it (that would re-arm the watcher) — (external-change-watch) has its own `reloadOpenFileFromDisk`.
- `deinit { pendingAutosave?.cancel() }` (a `WorkspaceModel` had no `deinit`; add one).

*Buildable/revertible:* typing writes the file ~0.75 s after you stop and clears "Edited" unattended; Cmd+S, undo, and highlighting are unchanged.

**Tier 1 and Tier 2 are a coupled pair — Tier 1 must NOT ship on its own.** A debounced autosave living next to (open-save)'s still-present four-button dialog is *incoherent* (D3): the dialog runs an app-modal `runModal`, but the main run loop keeps servicing `DispatchQueue.main.asyncAfter`, so a pending autosave can fire *behind* the modal and write the buffer to disk while the user is still deciding — defeating the dialog's "Don't Save" the instant it is chosen. There is no correct intermediate state where the debounce and the old dialog coexist. The two tiers are separated only to keep each diff reviewable; they land together, and neither is independently shippable or independently revertible. (Reverting *both* returns to (open-save) as shipped.)

### Tier 2 — Retire the toggle + four-button dialog; switch/close/quit become an unconditional flush ("minimal escape")

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify), `FEdit/App/FEditApp.swift` (modify), `SPEC.md` (modify — this item owns the §7/§9/§10 edits, see the SPEC section).

- Rewrite `resolveDirtyFile` to a flush-and-check that takes a **`context`** so its failure behavior can differ between a file switch and a close/quit (add `enum DirtyContext { case fileSwitch, closeOrQuit }` and change the signature to `resolveDirtyFile(context: DirtyContext) -> DirtyResolution`, or expose a distinct close/quit variant — the call sites already know which they are). Keep the `DirtyResolution` enum. Body:
  - clean / no open file → `.proceed`;
  - dirty → **`cancelPendingAutosave()` first** (so a straggler debounce can't fire behind whatever happens next — see D3), then flush via `saveOpenFile(alertOnFailure: true)`. On success → `.proceed`.
  - On flush **failure**, branch on `context`:
    - `.fileSwitch`: abort the switch — return `.cancel`. The caller reverts the sidebar selection; `saveOpenFile` already showed the "Cannot Save File" alert. This is exactly today's / (open-save)'s shipped criterion-15 behavior — no new dialog.
    - `.closeOrQuit`: present the **minimal two-button escape** alert `Couldn't save '<name>'` with buttons **Close Without Saving** and **Cancel** (Cancel gets Escape by title). Close Without Saving → `.proceed` (discard the unsaved buffer, close/quit); Cancel → `.cancel` (keep the window open / abort quit).
  Delete the four-button `NSAlert` (Save / Always Autosave / Don't Save / Cancel) and the `autosaveOnFileSwitch` branch entirely.
- **The close/quit escape is the ONLY surviving dialog** (T1 resolution). It exists solely so a persistently-failing save (read-only dir, full or *unmounted* volume) can never make the app un-quittable. The discard exit is offered **only** at the close/quit boundary, never on a plain file switch (a switch still safely aborts and preserves the buffer). This is the goal-preserving resolution of the un-quittable-app tension: safe-by-default plus a bounded, explicit escape hatch.
- Update the call sites to pass the context: `requestOpen` calls `resolveDirtyFile(context: .fileSwitch)`; `WindowCloseGuard.windowShouldClose` and `AppDelegate.applicationShouldTerminate` call `resolveDirtyFile(context: .closeOrQuit)`. Those two consumers are otherwise unchanged.
- Remove `var autosaveOnFileSwitch` from `WorkspaceModel` entirely.
- `FEditApp.swift`: remove the `Toggle("Autosave on File Switch", isOn:)` line and the `@AppStorage(SettingsKey.autosaveOnFileSwitch)` property from `FileCommands`; remove `static let autosaveOnFileSwitch` from `SettingsKey`. (Grep-confirmed these are the only references.)
- `SPEC.md`: apply the §7/§9/§10 edits described in the SPEC section below (they belong to this item, not a follow-up), and record that this item **supersedes (open-save) acceptance criteria 9–16** (their four-button dialog, Always Autosave, Don't Save, and toggle semantics).

*Buildable/revertible:* type-then-immediately-switch saves silently and switches with no dialog; the File menu no longer shows the toggle; a dirty close/quit flushes silently, and on a persistent flush failure the minimal Close Without Saving / Cancel escape appears. **Not independently revertible** — reverting this tier alone would reinstate (open-save)'s four-button dialog on top of Tier 1's debounce, which is the incoherent debounce-behind-modal state D3 rules out (see Tier 1's coupled-pair note). Revert Tier 1 + Tier 2 together to return to (open-save) as shipped.

### Tier 3 — Flush on focus loss (app resign-active)

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify).

- Add `func flushPendingAutosave()`: `cancelPendingAutosave(); if openFile?.isDirty == true { saveOpenFile(alertOnFailure: false) }` (silent, same anti-spam rule as the debounce; surfaces at explicit boundaries).
- Add an `init()` that observes `NSApplication.didResignActiveNotification` (closure-based, `queue: .main`, `[weak self]`, `MainActor.assumeIsolated { self?.flushPendingAutosave() }`), storing the observer token; extend `deinit` to also remove it (alongside the Tier 1 `pendingAutosave?.cancel()`).
- **Scope of what resign-active buys (T3, softened):** `didResignActiveNotification` fires only when the user **leaves** FEdit (switches to another app), so it covers the "user tabs over to Terminal/Claude and edits the file there" case, collapsing that exposure window to ~0. It does **not** cover the headline "a background agent (e.g. Claude) edits the file while FEdit stays focused" case — FEdit never resigns active then, so the exposure floor for a background writer remains the debounce interval (~0.75 s). **The lever for the background-agent case is a shorter `autosaveInterval`, not resign-active.** Intra-app file switches are already flushed by Tier 2's `resolveDirtyFile`.

*Buildable/revertible:* switching away from FEdit writes the buffer immediately. This tier's only footprint is the new `init()` and the resign-active observer removal added to `deinit`; reverting it deletes exactly those and lengthens the worst-case exposure window (for the leaves-FEdit case) back to `autosaveInterval` — nothing else in the model changes.

## Coordination seam for (external-change-watch)

(external-change-watch) will add a `DispatchSource` (vnode) watcher on the open file and, on an external change, reload a clean buffer (preserving cursor/scroll) or apply a conflict policy on a dirty buffer. Both plans are being reconciled to **one** contract in parallel; the six points below are the canonical, load-bearing terms and match verbatim on the (external-change-watch) side:

1. **Single write path.** Every disk write to the open file goes through `WorkspaceModel.saveOpenFile(alertOnFailure:)`. True today; this item preserves it — Cmd+S, the debounced autosave, the resign-active flush, and the `resolveDirtyFile` flush all funnel through it.
2. **Echo-suppression baseline = `lastWriteSignature: FileSignature?`, OWNED BY (external-change-watch).** `FileSignature` is inode (`st_ino`), size (`st_size`), and mtime (sec + nsec) captured via `stat(2)`. The field **and its capture** are added when **(external-change-watch)** ships — on `saveOpenFile()`'s post-write shared success branch and in `applyLoadedFile`. **This plan does NOT introduce any full-text save baseline** (the design's earlier "last saved text" `String?` is dropped entirely). Rationale: that baseline was dead machinery the consumer never reads, and it held a full second copy of the document (up to the 100 MB load cap) — undesirable given the open (memory-use-audit) item. A compact `FileSignature` (a few integers) replaces it, and baked-in-autosave provides the *shared success branch* the signature capture hangs off without adding any field of its own.
3. **`cancelPendingAutosave()` — exposed and required.** baked-in-autosave exposes `func cancelPendingAutosave()` (cancels + nils the pending autosave `DispatchWorkItem`). `applyLoadedFile` calls it on the file-switch path; **(external-change-watch) calls it at the top of its own reload path** so a straggler autosave can never clobber a just-applied external reload.
4. **Fire-time re-check.** The debounced autosave work item reads `openFile.text` and re-checks `isDirty` **at fire time** (not schedule time), so a straggler autosave that outlives any file switch or external reload finds a clean buffer and is a no-op.
5. **External reloads do NOT route through `applyLoadedFile`.** `applyLoadedFile` is the *file-switch* load path and re-arms the watcher; routing an external reload through it would be wrong. External reloads are (external-change-watch)'s own `reloadOpenFileFromDisk`, which calls `cancelPendingAutosave()` first. (Any earlier claim that "`applyLoadedFile` is the reload choke point for external-change-watch" is dropped.)
6. **(external-change-watch) assumptions.** It watches the symlink-resolved path (`openFile.url.resolvingSymlinksInPath()` — the same path `saveOpenFile` writes), applies external reloads through its own reload method (never by mutating `openFile` in ad-hoc ways), and calls `cancelPendingAutosave()` before applying a reload.

**Policy alignment:** baked-in-autosave only ever *writes*; it never reloads or merges — all reload/conflict decisions belong to (external-change-watch). When the buffer is dirty and the disk changes externally, the watcher's default "in-editor wins" plus baked-in-autosave's next flush (which writes the buffer over the external change) are consistent: the user's in-editor edits win and the external change is overwritten, never the reverse. This is the intended last-writer resolution, not a bug.

## Interface between tiers

`WorkspaceModel` surface, frozen at each tier boundary:

- **Tier 1 → 2/3 and → (external-change-watch):** `saveOpenFile(alertOnFailure: Bool = true) -> Bool` (alerts internally only when `alertOnFailure`, `false` = still dirty; its post-write success branch is the shared hook (external-change-watch) later hangs its `FileSignature` capture off); `func cancelPendingAutosave()` (**exposed, required** — cancels + nils the pending work item); `applyLoadedFile(url:text:)` calls `cancelPendingAutosave()` first (no full-text save baseline is set — the design carries no "last saved text" field); `private var pendingAutosave`, `scheduleAutosave()`, `autosaveInterval`; `deinit` cancels the timer.
- **Tier 2 → 3/4:** `resolveDirtyFile(context: DirtyContext) -> DirtyResolution` — signature gains the `context` parameter; still app-modal-safe and called from `WindowCloseGuard.windowShouldClose` and `AppDelegate.applicationShouldTerminate` (both pass `.closeOrQuit`) and from `requestOpen` (passes `.fileSwitch`). Body is a silent flush; on failure it aborts a switch or shows the minimal Close-Without-Saving/Cancel escape for a close/quit. `DirtyResolution` is unchanged; `enum DirtyContext { case fileSwitch, closeOrQuit }` is new. `SettingsKey.autosaveOnFileSwitch` and `WorkspaceModel.autosaveOnFileSwitch` are **deleted**.
- **Tier 3 → later:** `flushPendingAutosave()`; the `init()`/`deinit` resign-active observer.
- Consumers: `WindowCloseGuard.swift` and `AppDelegate` call `resolveDirtyFile(context: .closeOrQuit)` (the only body change is the added argument); `ContentView.swift` (binds `$workspace.editorText`, unchanged); `CodeEditorView.swift` (unchanged — its programmatic-content path already runs under `isProgrammaticUpdate`, so an external reload does not round-trip through `textDidChange` into the `editorText` setter and never spuriously schedules an autosave).

## Load-bearing assumptions

1. **(open-save) is shipped** (verified against source): `WorkspaceModel` has `struct OpenFile { url; text; isDirty }`, `@Published var openFile`, `var editorText { get set }` (setter dirties only on a real change), `saveOpenFile() -> Bool` (atomic UTF-8 write to the symlink-resolved path, alerts + returns false on failure), `applyLoadedFile(url:text:)`, `resolveDirtyFile() -> DirtyResolution`, `requestOpen(_:)`; `WindowCloseGuard` proxy + `AppDelegate` route close/quit through `resolveDirtyFile()`; `FileCommands` has Save + the autosave Toggle; `SettingsKey.autosaveOnFileSwitch` exists. All present as read.
2. The `editorText` setter is the **only** path that sets `isDirty = true`, and it is invoked on the main thread from `CodeEditorView.textDidChange` via the binding — so a debounce hung there fires exactly on user edits, on the MainActor. Verified.
3. Clearing `isDirty` inside `saveOpenFile()` republishes `openFile` but leaves the text identical, so the `$workspace.editorText` binding value is unchanged; SwiftUI does not write back through the setter on a re-eval, and `CodeEditorView`'s `documentID`/`text` guards fire no mutation. No feedback loop, no undo touch. Verified against `CodeEditorView.updateNSView`.
4. Clearing `isDirty` does not change `snapshotJSON()` (which reads only `roots`, `openFile?.url.path`, `filterText`, `cursorLocation`), so autosave never triggers (session-restore)'s `.onChange(of: workspace.snapshotJSON())` rewrite. Verified.
5. `DispatchQueue.main.asyncAfter` work items still fire while the app is inactive/backgrounded (the main run loop keeps running), so a pending autosave eventually lands even without the Tier 3 focus-loss flush — Tier 3 only shortens the window.
6. **(external-change-watch)** will watch the symlink-resolved path (`openFile.url.resolvingSymlinksInPath()`) — the same path `saveOpenFile` writes — and will apply external reloads through **its own** `reloadOpenFileFromDisk`, calling `cancelPendingAutosave()` first (not by routing through `applyLoadedFile`, which is the file-switch path and re-arms the watcher, and not by mutating `openFile` in ad-hoc ways). It also owns the `FileSignature` echo-suppression baseline. If it watches the unresolved URL, or reloads without first calling `cancelPendingAutosave()`, the coordination guarantees above do not hold — this is the cross-item contract that must be honored on the other side.
7. No sandbox (SPEC §2): plain-path atomic writes need no security-scoped access.

## SPEC update (part of this item — Tier 2 edits `SPEC.md`)

This item **does** edit `SPEC.md` (it is not a deferred follow-up); the edits ship with Tier 2:
- **§7:** Replace the "Switching files with unsaved changes" ON/OFF branch, the four-button dialog, and the "Autosave setting: global, persisted, toggleable" bullet with: autosave is **unconditional and always-on** — a ~0.75 s debounce after typing stops, plus a silent flush on file switch, focus loss, window close, and quit. A failed save is alerted at explicit boundaries; a failed **file switch** aborts (stays on the old file, still dirty), and a failed **close/quit** shows a single minimal "Close Without Saving / Cancel" escape so the app is never un-quittable; "dirty" is transient. Keep the atomic-UTF-8 write, the "Edited" subtitle, and the always-"FEdit" title.
- **§9:** Remove the "Autosave on/off | global | `UserDefaults`" persistence row.
- **§10:** Remove the "File → Autosave on File Switch | checkmark toggle" menu row (Save + shortcuts otherwise unchanged).
- **Supersession:** record that this item **supersedes (open-save) acceptance criteria 9–16** — their four-button Save / Always Autosave / Don't Save / Cancel dialog, the Always-Autosave toggle, and the Don't-Save discard-on-switch semantics no longer describe FEdit. The only discard path that survives is the close/quit "Close Without Saving" escape.

## Out of scope

- The file watcher / external-change detection / reload / conflict UI — that is (external-change-watch); this item only defines and provides the coordination seam.
- **Off-main-thread writes (accepted v1 bound, T2):** autosave flushes are synchronous `Data.write(.atomic)` on the MainActor, now firing ~0.75 s after every typing pause rather than only on an explicit Cmd+S. For a large file (up to the 100 MB load cap) this is a main-thread stall the Cmd+S-only model never imposed at that cadence. Accepted for v1 up to the cap; moving writes off the main thread (and any incremental/streaming write) is future work.
- A visible "couldn't save" indicator beyond the persistent "Edited" subtitle. **Accepted weakness (T4):** a silently-failing debounced or focus-loss autosave surfaces only as "Edited" *failing to clear* — the user must notice that passive signal until they hit an explicit boundary (Cmd+S, switch, close, quit) that raises the alert.
- Per-window autosave configuration, save-as, encodings beyond UTF-8/Latin-1, and multi-window coordination on the same file (last write wins per SPEC §11).

## Auto-resolved (plan review)

Findings from adversarial plan review, plus one user decision and the reconciled cross-item seam, folded in above:

**Defects fixed**

1. *(D3, Medium)* A debounce coexisting with a still-present dirty dialog is **incoherent**: the dialog runs an app-modal `runModal`, but the main run loop keeps servicing `DispatchQueue.main.asyncAfter`, so a pending autosave fires *behind* the modal and writes the buffer — defeating "Don't Save" the moment it is chosen. With the dialog now removed, Tier 1 and Tier 2 are flagged a **coupled pair** that land together (neither independently shippable nor independently revertible), and `resolveDirtyFile` calls `cancelPendingAutosave()` before anything else. The old "fully functional and independently shippable" / "still coherent when reverted" wording is deleted. (Tier 1 coupled-pair note; Tier 2 body and revert note.)
2. *(D4, Medium)* The SPEC §7/§9/§10 edits belong to **this** item, not a deferred follow-up: the old "do NOT edit SPEC in this item" heading is replaced, Tier 2 lists `SPEC.md` as a modified file, and the (open-save) acceptance-criteria **9–16 supersession** is stated explicitly. (SPEC section; Tier 2.)

**Tensions resolved (recorded decisions)**

3. *(T1, High)* Un-quittable app → resolved by the minimal close/quit "Close Without Saving / Cancel" escape. A discard exit is kept **only** at the close/quit boundary; a plain file switch still safely aborts and preserves the buffer. (Goal; criterion 10; Tier 2.)
4. *(T2, Medium)* Autosave writes are synchronous `Data.write(.atomic)` on the MainActor, now firing ~0.75 s after every typing pause — a main-thread stall for large files (up to the 100 MB cap) that the Cmd+S-only model never imposed at that cadence. Accepted for v1 up to the cap; off-main writes are future work. (Out of scope.)
5. *(T3, Medium)* Softened the Tier 3 resign-active claim: `didResignActiveNotification` fires only when the user *leaves* FEdit, so the headline "a background agent (e.g. Claude) edits the file while FEdit stays focused" case is **not** covered — its exposure floor stays the debounce interval (~0.75 s). A shorter `autosaveInterval`, not resign-active, is the lever for the background-writer case. (Tier 3.)
6. *(T4, Low)* Silent-failure UX relies on the user noticing "Edited" fails to clear — recorded as an accepted weakness. (Out of scope.)
7. *(T5, Low)* Tightened the Tier 3 "revert = nothing else changes" wording — the tier's actual footprint is the new `init()` and the resign-active observer removal added to `deinit`, and reverting deletes exactly those. (Tier 3 revert note.)

**User decisions**

8. **"Minimal escape" — autosave is unconditional; the four-button dialog and the toggle are gone.** Removed (open-save)'s four-button "Save changes?" `NSAlert`, the "Autosave on File Switch" menu Toggle, `SettingsKey.autosaveOnFileSwitch`, and `WorkspaceModel.autosaveOnFileSwitch`. `resolveDirtyFile` becomes a flush-and-check taking a `context` (`.fileSwitch` / `.closeOrQuit`): clean/no file → `.proceed`; dirty → `cancelPendingAutosave()` then flush via `saveOpenFile(alertOnFailure:)`, success → `.proceed`; on failure a file switch aborts (revert selection, alert already shown by `saveOpenFile`) exactly as today, while a close/quit shows the **sole surviving dialog** — a minimal two-button "Couldn't save '<name>' — Close Without Saving / Cancel" — so a persistently-failing save (read-only dir, full or unmounted volume) can never make the app un-quittable. (Goal; criteria 6 & 10; Tier 2; Interface; SPEC section.)
9. **Canonical reconciled seam with (external-change-watch).** Replaced the coordination-seam text with the contract shared verbatim across both plans: single write path through `saveOpenFile(alertOnFailure:)`; echo-suppression baseline is `lastWriteSignature: FileSignature?` (inode / size / mtime sec+nsec via `stat(2)`) **owned by (external-change-watch)**, added when that item ships. **This plan introduces no full-text save baseline** — the design's former "last saved text" `String?` is deleted everywhere (dead machinery the consumer never reads, holding a full second copy of the document up to the 100 MB cap — undesirable per the open (memory-use-audit) item). This item **exposes the required `cancelPendingAutosave()`**; the debounced work item re-checks `isDirty` at fire time; external reloads route through (external-change-watch)'s own `reloadOpenFileFromDisk` (which calls `cancelPendingAutosave()` first) and **not** through `applyLoadedFile` — dropping the old "`applyLoadedFile` is the reload choke point" claim. (Coordination seam; Interface; Load-bearing assumption 6.)
