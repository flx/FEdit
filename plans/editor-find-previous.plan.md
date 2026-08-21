# (editor-find-previous) — Find Previous (Cmd+Shift+G)

**Risk tier: `standard`.** Additive mirror of a shipped, already-reviewed mechanism
((editor-find), commit 7b2a01e). It touches state logic (`FindSession` stepping) and the
editor's tick-consumption control flow, which puts it above `trivial`; but the reach is
one new method, one new `@Published` counter, one menu item and one consumption block —
no new subsystem, no boundary change, no change to output for existing documents. Not
`hi`.

**Plan review: deliberately skipped** (the tier permits it for genuinely simple items).
The only design decision with more than one defensible answer is one-tick-vs-two, decided
and justified in D1 below; everything else is dictated by the shipped `findNextTick`
path, which a reviewer already went over twice. Recorded here so the skip is visible
rather than silent.

## Goal

`Cmd+Shift+G` steps the find bar's current match **backwards**, wrapping past the first
match to the last, exactly mirroring Find Next. This is the standard reflex chord; today
it is unclaimed and does nothing (probe-confirmed in the TODO item and in
`EditCommands`' own doc comment: this app never requests `TextEditingCommands()`, so
`.textEditing` installs no Find submenu and registers no ⌘G/⇧⌘G of its own).

## Acceptance criteria

Each is checked by a `scripts/FindMatchTests` case unless marked otherwise.

1. `FindSession.stepPrevious()` on a seated session at index `i > 0` moves to `i - 1`.
2. `stepPrevious()` at index `0` wraps to `matches.count - 1`.
3. `stepPrevious()` with `matches` empty is a no-op: `currentIndex` stays `nil` and
   `matches` stays empty (it must not invent a seat — the mirror of criterion 8).
4. `stepPrevious()` on a non-empty but unseated session (`currentIndex == nil`,
   unreachable while the type invariant holds) seats on the **last** match, mirroring
   `stepNext`'s seat-on-first. Pinned so the unreachable branch cannot silently rot.
5. `stepNext()` then `stepPrevious()` returns to the original index, from every index of
   a multi-match session including both wrap edges — asserted as a round-trip sweep.
6. `countLabel` after a `stepPrevious()` reads the new ordinal (`2 of 17` → `1 of 17`,
   and the wrap `1 of 17` → `17 of 17`).
7. The randomized clamp-invariant run (criterion 11) exercises `stepPrevious()` alongside
   `stepNext()` and the invariant still holds: `currentIndex` non-`nil` exactly when
   `matches` is non-empty, and always in bounds.
8. **Build-checked, not harness-checked:** Edit → Find Previous exists with the
   `⇧⌘G` key equivalent, is disabled when no file is open (same `.disabled` predicate as
   Find Next), and is focused-window-scoped through the same `@FocusedObject`.
9. **Build-checked, not harness-checked:** a coordinator rebuilt by a Markdown↔non-Markdown
   file switch does not replay accumulated Find Previous presses — `makeNSView` seeds
   `lastConsumedFindPreviousTick` from the incoming tick, exactly as it seeds
   `lastConsumedFindTick` (this is criterion 22 of (editor-find), and forgetting it is
   the specific documented bug).

Criteria 8 and 9 are structural, not visual: 8 is "the code says so" and 9 is a
one-line seeding statement whose absence is visible in the diff. **No manual GUI pass is
owed** — per AUTONOMY.md the default is DON'T, and there is no visual or feel-based
judgement here that a headless oracle cannot reach. The stepping logic, which is the only
part that can be wrong in an interesting way, is fully covered by 1–7.

## Design

### D1 — a second tick, not a signed one

`WorkspaceModel` gets `@Published var findPreviousTick = 0` alongside `findNextTick`, and
the editor gets a matching `lastConsumedFindPreviousTick`.

The alternative was one `findStepTick` plus a `findStepBackwards: Bool`. Rejected: the
existing tick is documented as consumed **as a level, not a delta**
(`WorkspaceModel.swift:235`), so a direction flag stored beside it is a second variable
the level-comparison does not cover — two presses of opposite direction inside one
SwiftUI update pass would collapse to the last direction with a tick delta of 2, and the
editor would step once in the wrong direction. Two independent level-compared counters
have no such coupling: each is consumed exactly once against its own last-consumed value.
Cost is one extra `Int` per window.

### D2 — one shared stepper in the coordinator

`Coordinator.stepFindNext` currently carries the whole step path: the
stale-by-edit re-enumeration guard, the two-range recolor, the scroll and the count
report. Rather than copy 20 lines, extract `private func stepFind(_ textView:
backwards: Bool)` and make `stepFindNext`/`stepFindPrevious` thin call sites. The
re-enumeration guard, the recolor pair and the scroll are all direction-independent, so
duplicating them would be a live drift risk against exactly the finding-3 fix that put
the guard there.

### D3 — `stepPrevious`'s unseated fallback is `?? 0`, mirroring `stepNext`'s `?? -1`

`stepNext` uses `((currentIndex ?? -1) + 1) % count`, so unseated steps to `0`.
The mirror is `((currentIndex ?? 0) + count - 1) % count`, so unseated steps to
`count - 1` — "wrap backwards from before the start" lands on the last match. `+ count -
1` rather than `- 1` because Swift's `%` on a negative left operand returns a negative
remainder, which would be an invalid index and a crash, not a wrap.

## Tiers

**Tier 1 — the state machine.** `FindSession.stepPrevious()` plus the harness cases
(criteria 1–7). Independently buildable, independently revertible (nothing calls it yet),
and it pays off alone only as a tested primitive. Revert: delete the method and its
harness section.

**Tier 2 — the wiring.** `findPreviousTick` on the model, the `findPreviousTick` input
and `lastConsumedFindPreviousTick` on `CodeEditorView`/`Coordinator`, the D2 refactor,
the `ContentView` pass-through, and the Edit → Find Previous menu item (criteria 8–9).
Pays off alone: this is the shipped user-visible feature. Revert: revert the commit;
Tier 1 keeps compiling.

**Interface between tiers:** Tier 2 calls `findSession.stepPrevious()` and nothing else
of Tier 1.

Both tiers land in **one commit** — Tier 1 is dead code without Tier 2, and a commit of
dead code is not a useful revert point.

## Load-bearing assumptions

- **`.keyboardShortcut("g", modifiers: [.command, .shift])` registers ⇧⌘G and collides
  with nothing.** *Partly measured, partly reasoned — corrected after code review, see
  Decisions.* Measured and recorded: this app never requests `TextEditingCommands()`, so
  `.textEditing` is an empty placement group and no Find submenu is installed; a bare
  menu bar has zero ⌘F/⌘G hits (`plans/editor-find.plan.md:36-39`). Measured by me this
  run: no other `keyboardShortcut` in the target binds ⇧⌘G (⇧⌘O is Add Folder to
  Window). **Not** measured, contrary to what the TODO item and
  `plans/editor-find.plan.md:125` both assert: a ⇧⌘G-specific result. Probe 2's recorded
  text covers Cmd+F and Cmd+G only. If the reasoning is wrong the cost is a duplicate key
  equivalent, not a crash; the menu item still works by click. Rewrite cost: none — it
  would become a different chord.
- **`stepPrevious` needs no change to `clamp`, `recompute` or `recomputeNearest`.** It
  only reads `matches.count` and writes `currentIndex` under the same invariant every
  other mutating member preserves. If false, criterion 7's randomized run is what catches
  it.

## Out of scope

- **Shift+Return in the query field.** The Xcode/Safari reflex, but SwiftUI's `.onSubmit`
  carries no modifier information, so it cannot distinguish Return from Shift+Return —
  reaching it would need an `NSViewRepresentable` text field or a key monitor, which is a
  larger change than this item, and the TODO item scopes to the menu chord ("one menu
  item, one tick"). Filed as a note in the DONE entry, not built.
- **Replace.** Stays a SPEC §12 non-goal; untouched.
- Any change to seating, clamping, highlighting, or the count label's format.

## Decisions taken

*(2026-08-21)*

- **D1 two ticks rather than one signed tick.** Alternative: `findStepTick` +
  `findStepBackwards`. Chose two because the shipped tick is level-compared, and a
  companion flag is not covered by that comparison — see D1 for the concrete
  two-presses-in-one-pass failure. Recorded because the extra `@Published` is the kind of
  thing a reader would otherwise want justified.
- **D2 extract a shared `stepFind(_:backwards:)`** rather than duplicate `stepFindNext`.
  Alternative: copy the body. Chose extraction because the copied part includes the
  finding-3 stale-by-edit guard, and two copies of a subtle guard drift.
- **D3 `?? 0` for the unseated backwards step**, seating on the last match. Alternative:
  seat on `0` (first match) for both directions. Chose the mirror because `stepNext`'s
  documented intent for the unreachable branch is "step from outside the array in the
  direction of travel", and `+ count - 1` avoids Swift's negative-remainder trap.
- **Plan review skipped.** Alternative: run `adv-review-plan`. Skipped because the item
  is an additive mirror of a mechanism reviewed twice under (editor-find); the one open
  design question is D1, decided above with a traced failure case for the alternative.
*(Folded in after code review — `adv-review-behavior` and `adv-review-edge`, run blind
and in parallel. Behavior found no functional defect; its five findings were all
documentation accuracy, and all five are accepted and applied.)*

- **Accepted: the ⇧⌘G "probe-confirmed" claim was an inference, not a measurement.**
  `plans/editor-find.plan.md:125` says "Probe 2 additionally shows Cmd+Shift+G is
  unclaimed"; Probe 2's own recorded text at `:36-39` says only Cmd+F and Cmd+G. The TODO
  item repeated the claim and so did the first draft of this plan and of
  `EditCommands`' doc comment. Verified by reading both sources: the reviewer is right.
  All three now state what is measured and mark the system-level ⇧⌘G question as
  reasoned. *Alternative considered:* actually run the probe — compile a bare SwiftUI app
  and walk `NSApp.mainMenu` recursively for ⇧⌘G. *Why not:* it requires launching a
  `.regular`-activation GUI app, which steals focus on Felix's desktop, and this is a
  background run where he may be away. Being accurate about the gap costs nothing and is
  worth more than a measurement taken rudely; if it matters later it is a five-minute
  probe to run interactively.
- **Accepted: `SPEC.md` §6.5 must not say Shift+Return "is not wired".** `FindBar`'s
  `.onSubmit` has no modifier gate, so ⇧↩ in the query field is an ordinary submit — it
  steps *forward*, the opposite of the ⇧↩ reflex users bring from Safari and Xcode.
  Rewritten to say so explicitly and point at Cmd+Shift+G. This is the finding that most
  improved the change: the original wording would have left a user-visible surprise
  undocumented.
- **Accepted: §14 item 10 must not absorb this item's work.** `DONE.md`'s record for
  `(editor-find)` states Find Previous was deliberately not done and filed as this item,
  and §14 asks the reader to follow that cross-reference. Item 10 is restored to Cmd+F /
  Cmd+G and a new item 11 carries this work. Item 11 is deliberately worded as an
  accumulator for this run's follow-on find/preview work, so items shipping after this one
  extend it rather than each claiming a numbered step.
- **Accepted: two stale comments corrected** — `FindBar.swift:41` still asserted "no Find
  Previous" (found independently before the review landed; the comment is now scoped to
  the bar's *controls*), and `WorkspaceModel.findPreviousTick`'s comment claimed the two
  ticks are read by "the same block, one line below" when they are two separate `if`
  blocks 14 lines apart — which contradicted the D1 rationale in the same comment.
- **SPEC §6.5's "There is no Find Previous." sentence is a reversal**, not an addition:
  it is edited out and replaced with the wrapping description, and the §10 menu table
  gains a row. §14's item-10 changelog line gains the chord. This is a spec-visible
  behavior change and is called out in the commit message.
