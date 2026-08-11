# open-cmd-o

**Risk tier:** standard — a one-token keyboard-shortcut change (`"n"` → `"o"`) on an existing menu button plus stale-comment/SPEC text touch-ups. No new API, no control flow, no state, no collision. The button, its group (`CommandGroup(replacing: .newItem)`), and its action are untouched.

## Goal

Rebind `File → Open Folder…` from Cmd+N to Cmd+O (matching the macOS Open = Cmd+O convention), vacating Cmd+N for the later (new-file) item; leave `Add Folder to Window…` on Cmd+Shift+O and everything else unchanged.

## Acceptance criteria

Manually verifiable on a debug build (menu-shortcut wiring; the repo's `scripts/*Tests` swiftc harnesses cannot drive menus):

1. **Cmd+O opens the folder-open flow.** `File → Open Folder…` shows **⌘O** and invoking it (menu click or Cmd+O) opens a new window that presents the directories-only picker exactly as before — behavior identical to the shipped (open-folder-new-window) flow; only the shortcut moved.
2. **Cmd+N no longer bound to Open Folder….** No File-menu item carries Cmd+N; pressing Cmd+N does nothing (the default "New Window" stays removed because the button remains in `CommandGroup(replacing: .newItem)`). Cmd+N is free for (new-file).
3. **No other binding changed / no collision.** `Add Folder to Window…` stays **⌘⇧O**, `Save` stays **⌘S**, the View-menu font items stay **⌘+ / ⌘- / ⌘0**. Cmd+O and Cmd+⇧O are distinct chords; both resolve to their own items with no conflict warning.
4. **SPEC matches.** SPEC.md's three Open Folder… shortcut mentions read Cmd+O (see Tier).

## Tier — Rebind the shortcut + refresh in-file/SPEC text

Single tier; compiles and is independently revertible.

**Modify `FEdit/App/FEditApp.swift` (only code file):**
- Line ~115, inside `CommandGroup(replacing: .newItem)`, on the `Button("Open Folder…")`: change `.keyboardShortcut("n", modifiers: [.command])` → `.keyboardShortcut("o", modifiers: [.command])`. Nothing else in the button, the group, or `FileCommands` changes.
- Refresh the now-stale in-file comments that name the shortcut (these are all inside the touched file, so in scope): line ~37 ("opens a *new* window per Cmd+N call"), line ~95 (`"Open Folder…" (Cmd+N) flow`), line ~104 (the `CommandGroup(replacing: .newItem)` comment). Reword to Cmd+O, and keep line ~104's point that `replacing: .newItem` is retained deliberately — it removes SwiftUI's default "New Window" so Cmd+N is left free (for (new-file)), while Open Folder… now answers Cmd+O.

**Modify `SPEC.md` (docs):**
- §3, line ~21: "File → Open Folder… (Cmd+N)" → "(Cmd+O)".
- §10 menu table, line ~166: the `File → Open Folder…` row's shortcut `Cmd+N` → `Cmd+O`.
- §10 note, line ~171: "**Open Folder… (Cmd+N)**" → "**Open Folder… (Cmd+O)**" (the app-level note is otherwise unchanged). (The TODO says "§3"; updating every Open Folder… shortcut mention keeps the doc self-consistent.)

Revert: flip `"o"` back to `"n"` and `git checkout` the SPEC/comment hunks.

## Interface

None. No symbols added, removed, or resignatured; the menu button's title and action are unchanged. Purely the `KeyEquivalent` on one `.keyboardShortcut` plus comment/doc text.

## Load-bearing assumptions

Verified against the shipped code/SPEC read at planning time:

1. **Open Folder… is currently bound to Cmd+N** via `.keyboardShortcut("n", modifiers: [.command])` at `FEditApp.swift:115`, inside `CommandGroup(replacing: .newItem)` in `FileCommands`. ✅ (confirmed).
2. **Cmd+O is currently free.** The only other File/View shortcuts are Cmd+Shift+O (Add Folder to Window…, line 124), Cmd+S (Save, line 130), and Cmd+/Cmd-/Cmd0 (View font). No plain Cmd+O exists anywhere in `.commands`. ✅ (confirmed via grep of all `keyboardShortcut` sites).
3. **No system Open… slot.** FEdit is a `WindowGroup` app, not `DocumentGroup`, so SwiftUI installs no built-in "Open…" (Cmd+O) menu item; the standard Open slot is not occupied and there is no `CommandGroup(replacing:)`/system conflict to reconcile. ✅.
4. **Cmd+N is genuinely vacated, not reassigned.** This item only removes the Cmd+N binding; because the button stays in `CommandGroup(replacing: .newItem)`, SwiftUI's default "New Window" does not reappear on Cmd+N. Nothing here adds a New item — (new-file) claims Cmd+N later. ✅.
5. **Cmd+Shift+O ≠ Cmd+O.** The `.shift` modifier makes Add Folder to Window… a distinct chord; rebinding Open Folder… to plain Cmd+O cannot collide with it. ✅.

If assumption 2 or 3 were wrong (some other item or a system slot already held Cmd+O), the rebind would create a duplicate-shortcut conflict — the single fact the whole plan rests on. Both are confirmed false, so the plan holds.

## Out of scope

- **Adding any "New" item / claiming Cmd+N** — that is (new-file), which ships after this. This item only vacates Cmd+N.
- **Reorganizing the File menu** — Open Folder… stays in the `.newItem` (New) group; it is not moved to an "Open" placement. Only its shortcut changes.
- **Add Folder to Window… (Cmd+Shift+O), Save (Cmd+S), the View font shortcuts, the picker/new-window flow, `LaunchCoordinator`, session-restore** — all untouched.
- **Cross-file comments outside `FEditApp.swift`** that mention "Cmd+N" in describing the Open Folder… new-window flow (`LaunchCoordinator.swift` ~L25–32, `WorkspaceModel.swift` ~L28/L358–359, `ContentView.swift` ~L125/L147/L153) become **factually wrong** once this ships — they name a shortcut Open Folder… no longer answers (and (new-file) will hand Cmd+N to new-file creation). Per the TODO's "touches `App/FEditApp.swift` only", they are **left as-is** here and the cleanup is **deferred to (new-file)** — which actually repurposes Cmd+N — as the natural place to refresh them. No behavioral effect. (See plan-review T1.)

## Auto-resolved (plan review)

Adversarial plan review found **zero defects**. Both load-bearing facts the whole plan rests on were re-verified against the shipped code and confirmed true:

- **Cmd+O is unbound today, so the rebind cannot create a duplicate.** No `.commands` item or menu shortcut carries plain Cmd+O (the only nearby chord is Cmd+⇧O on Add Folder to Window…), and — because FEdit is a `WindowGroup` app, not `DocumentGroup` — SwiftUI installs **no** built-in "Open…" (Cmd+O) slot. The standard Open slot is unoccupied and there is no system `CommandGroup(replacing:)` conflict to reconcile (assumptions 2 and 3 confirmed).
- **Removing the Cmd+N binding does not resurrect the default "New Window" (Cmd+N).** The button stays inside `CommandGroup(replacing: .newItem)`, which **structurally replaces** the group SwiftUI would otherwise populate with its default New Window (Cmd+N) item; dropping the button's own `.keyboardShortcut("n", …)` leaves that group replaced, so Cmd+N surfaces nothing until (new-file) claims it (assumption 4 confirmed).

**Tensions resolved (recorded decisions)**

- **T1 *(Low)*** — Cross-file comments describing the Open Folder… flow as "Cmd+N" (`LaunchCoordinator.swift` ~L25–32, `WorkspaceModel.swift` ~L28/L358–359, `ContentView.swift` ~L125/L147/L153) become **factually wrong** — not merely cosmetic — once this ships, and more so after (new-file) makes Cmd+N mean new-file creation. Because this item scopes code changes to `App/FEditApp.swift` only, the comment cleanup is **explicitly deferred to (new-file)**, which actually repurposes Cmd+N and is the natural place to refresh them. Deferral recorded; the "Out of scope" bullet above is sharpened from "cosmetic" to "factually wrong". No behavioral effect.
- **T2 *(Nit)*** — `DONE.md:7` ("Cmd+N opens more windows", the (xcode-scaffold) ledger row) becomes historically inaccurate once Cmd+N is vacated, but is **correctly left untouched**: DONE.md is a ship-time ledger recording what each item did when it shipped, not live documentation, so it is not rewritten retroactively.

**Confirmed unchanged by review**

- The exact edit is `.keyboardShortcut("n", modifiers: [.command])` → `.keyboardShortcut("o", modifiers: [.command])` on the `Open Folder…` button at `FEditApp.swift:115`.
- SPEC §3's Cmd+N shortcut mentions the implementer must update are the only three in the file, at **SPEC.md lines ~21, ~166, and ~171**.
