# zero-window-session-relaunch — plan

**Risk tier: standard.** ~50 lines in the App layer, but launch-shape behavior with a manual-only
regression surface. Light plan; **no separate plan review** — the design is the stray-window
plan's Tier 3 net + app-level fallback opener, which ALREADY survived a full adversarial plan
review (plans/external-open-stray-window.plan.md Revision 2: D-R1..D-R6) and whose load-bearing
assumptions are ALL probe-verified (Revision 3: LB4, LB5 TRUE; the spike measurably turned the
0-window relaunch into 1). Re-reviewing a reviewed design would be a cycle spent re-deriving
recorded conclusions. ONE code reviewer (`adv-review-behavior`) on the diff.

## The bug (measured on HEAD, Revision 3 P4)

Close every window, Cmd+Q, relaunch ordinarily → **0 windows** — no scene, nothing. SPEC §3
expects one blank window. Mechanism: a zero-window saved session is not "no session" — restore
succeeds at restoring nothing, and SwiftUI then creates no default window either.

## Design (from the reviewed record, scoped to this bug — no suppression)

1. **App-level fallback opener** (LB4/LB5 probe-TRUE): `FEditApp` gains
   `@Environment(\.openWindow)`; a `let _ =` in `body` registers
   `{ openWindow(id: "editor") }` with `LaunchCoordinator` — a **pure store** (D-R2: idempotent,
   never dispatches from inside body evaluation). This opens the SAME editor group Cmd+O opens —
   no third routing path (the arch-review's condition); no mailbox increment, so the new window
   presents no folder panel — a plain blank window.
2. **The once-per-process net** (D-R3/D-R4): `noteLaunchFinished` schedules a single check at
   **+1.5 s** (the deadline exists for the launch-by-open shape, where the CLI window may not be
   visible yet at didFinishLaunching; P1 measured it visible in ms, P3 measured restored windows
   existing BEFORE didFinishLaunching — 1.5 s is generous either way):
   `guard liveWindowCount == 0 && undispatched.isEmpty else no-op; presentBlankEditorWindow()`.
   - `liveWindowCount` = `NSApp.windows` filtered on `isVisible && canBecomeKey` — the predicate
     D-R4 fixed and P3 empirically confirmed.
   - The `undispatched.isEmpty` clause: pending CLI opens will create their own windows; the net
     must not race them. The deliberately DELETED clause (D-R3): "no cli-open window issued" —
     if issued windows never materialize, the net fires and the user gets a blank window
     (visible, recoverable) instead of a windowless app. Failure direction chosen on purpose.
   - Once per process: the net never re-arms (Dock-reopen-with-zero-windows is a different,
     unfiled surface — out of scope, S9's baseline was never established as broken).

## Launch-shape trace (each verified against the probe record)

- Session with windows → restored windows visible before didFinishLaunching (P3) → count ≥ 1 →
  no-op.
- First-ever launch (no session) → SwiftUI's default window → count ≥ 1 → no-op.
- Zero-window session (the bug) → count 0, queue empty → one blank editor window. **The fix.**
- Cold launch-by-open, no session → cli window visible in ms (P1); at +1.5 s count ≥ 1 → no-op.
  Slow/failed window creation → net fires → blank window (accepted direction).
- NSOpenPanel modality delaying the timer: harmless — by firing time count > 0 (recorded, D-R3).

## Acceptance criteria

1. Build green; all 11 harnesses green unchanged (no harness-reachable code changes — the net
   lives in AppKit-importing files; recorded honestly as review-traced).
2. The registration is a pure store; no dispatch from body evaluation (review-traced).
3. The net cannot fire twice, cannot fire with a live window, cannot fire with a pending open
   (review-traced against the code).
4. **S11 scripted attempt**: install to temp dest, isolated TMPDIR (savedState lives under
   TMPDIR on this machine — Revision 3), launch → close all → quit → relaunch → count windows.
   Caveat recorded up front: osascript window counts silently read 0 on a locked screen
   (Revision 3); if the run is lock-suspect, the verification is recorded as OWED to the human
   GUI pass alongside the standing S-criteria — the probe record already demonstrated the exact
   mechanism (spike turned 0 into 1 with in-app counting).

## Out of scope

- `.defaultLaunchBehavior(.suppressed)` and the full launch-decision machinery — the stray
  window closed as not-reproducible; nothing needs suppressing.
- Dock-reopen with zero windows while running (S9) — separate surface, baseline not established
  as broken, not filed.
- Unifying Cmd+O onto the token mechanism — the arch-review note is satisfied negatively (this
  item adds no routing path); the unification itself remains a Watch item.

## Decisions taken

*(2026-08-11)*

- **No plan review** — the design carries the stray-window plan's completed adversarial review +
  probe record; re-review would re-derive recorded conclusions. (The code diff still gets its
  reviewer.)
- **Net + fallback opener only; no suppression** — the reviewed design's Tier 3 subset that this
  bug needs; suppression's motivation closed as not-reproducible.
- **1.5 s deadline kept** from the reviewed Tier 3 (P3-informed; failure direction one extra
  blank window, never a touched one).
- **Blank window via `openWindow(id: "editor")` with no mailbox increment** — same group as
  Cmd+O, no folder panel (SPEC §3 wants a blank window, not a picker).

*(2026-08-11, code review — `adv-review-behavior`; all 8 findings accepted, none rejected)*

- **Predicate widened to `(isVisible || isMiniaturized) && canBecomeKey`** (High 1): a session
  restored entirely miniaturized is a live session — `isVisible` alone reads it as windowless
  and the net would add an unrequested blank window on the RESTORE path.
- **Hidden app skipped** (High 1B): all a hidden app's windows read invisible; firing while
  hidden would surprise on unhide. The hidden + zero-window launch keeps pre-fix behavior —
  recorded corner, not silent.
- **The rescue clause** (High 2 — the reviewer's stuck-forever trace): `undispatched.isEmpty`
  alone made the net no-op-and-disarm on a zero-window session + external open, where
  `openNewWindow` is nil (no scene ever appears to register it), the retry chain exhausts at
  ~2 s, and the app stays windowless with the file never opened. The guard is now
  `undispatched.isEmpty || openNewWindow == nil`: with no opener, pending requests cannot
  create windows, and the blank window IS their rescue (its ContentView registers the opener,
  which re-dispatches the queue).
- **SPEC §3 gains the launch-window promise** (Medium 4 — the comment cited a sentence SPEC
  never contained; it does now, with the zero-window and hidden-app clauses) + §13's
  LaunchCoordinator line gains the net.
- **Doc honesty** (Medium 3/5, Low 6/7, Nit 8): the 1.5 s figure is labeled a generous guess
  built on single-run locked-screen observations, not a measured bound; the locked-screen
  `isVisible` doubt is carried in the predicate's comment as the recorded residual; a nil
  opener at fire time now NSLogs instead of silently restoring the bug; "fires once" corrected
  to "checked once" (`zeroWindowNetChecked`); the LB4/LB5 conflation in FEditApp untangled.
- **No re-review round**: the control-flow fixes are the reviewer's own prescribed minimal
  repairs, verified by orchestrator trace + rebuild; no harness reaches this code (recorded),
  the launch-shape matrix is review-traced, and the S11 scripted run was abandoned lock-suspect
  per the plan's pre-recorded fallback — the GUI verification is OWED (human, awake screen):
  S11 (zero-window relaunch → 1 blank window), the miniaturized-restore shape, and a
  locked-screen restore launch.
