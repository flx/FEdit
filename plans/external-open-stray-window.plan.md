# (external-open-stray-window) One window per launch-by-open — implementation plan

Planned 2026-08-11 against the code in this worktree (post-(cli-open), commit 80609b5), not against
the TODO text — see "Where the item's description is unverified" below.

**Revision 2 — 2026-08-11, post adversarial plan review (verdict REVISE). Where the
`## Revision 2` section at the end of this file conflicts with anything above it, Revision 2
governs.** Headline changes: opener precedence is INVERTED (the review showed `openWindow` is a
non-optional environment value, so an inert app-level action would silently kill shipped CLI
opens under Revision 1's precedence); the Tier 3 net loses its self-disarming guard; the
window-count signal is rebuilt on live `NSApp.windows` counts; and Tier 0 gains a suppression
spike that empirically gates LB1/LB2/LB4/LB5 before any real code is written.

## Risk tier

**standard** — no new algorithm, no file/data path, no `WorkspaceModel` change, and every code change
is one scene modifier / one delegate method / one pure function. But it moves the *app launch*
decision ("does a window come up, and which one") from SwiftUI into our code, and that path runs on
**every** launch including session restore (a shipped SPEC §9 feature), so the blast radius is wider
than the one-line diff suggests. Both failure directions are non-destructive — an extra empty window
(today's bug) or a missing empty window (recoverable with Cmd+O / Dock click, and Tier 3 is the net)
— and no window's *contents* are ever read, mutated or closed by anything in this plan. That is the
line that separates it from the designs the (cli-open) reviews rejected.

## Where the item's description is unverified (checked against source and DONE.md)

1. **"AppKit/SwiftUI creates the blank startup window before the odoc Apple Event arrives" is a
   hypothesis, not a recorded observation.** Nothing in the repo establishes that ordering.
   `plans/cli-open.plan.md` Revision 2 records the *symptom* ("SwiftUI **may** create its blank
   startup window next to the CLI window") and explicitly kept the opposite branch alive (review
   defect 5's other branch: SwiftUI suppresses the startup window on an odoc launch, in which case
   no scene ever registers the window opener). DONE.md's (cli-open) entry files the residual as
   "stray blank window on launch-by-open", again without an ordering measurement. **Tier 0 exists to
   establish the ordering before any code is written**, and includes a first check that the bug
   still reproduces at all.
2. **The named files are right.** `App/FEditApp.swift` (two `WindowGroup`s, `"editor"` first — that
   is the group whose default launch produces the stray window), `App/LaunchCoordinator.swift`
   (`isSettled`, `undispatched`, `openNewWindow`, retry chain), `Views/ContentView.swift`
   (`registerWindowOpener` in `.onAppear`). `App/WindowCloseGuard.swift` is missing from the item's
   file list and is needed: `AppDelegate` lives there and gains two methods.
3. **Suppressing the startup window is not optional plumbing on top of (cli-open) — it *breaks*
   (cli-open) unless the window opener is moved to app level first.** Today the only registrar of
   `LaunchCoordinator.openNewWindow` is `ContentView.onAppear`. On a cold launch-by-open, the
   *stray blank window is what registers the opener*, and therefore what makes the CLI window
   possible at all. Delete the stray window without a replacement registrar and a cold `fedit x.md`
   opens **nothing** (the 20 × 100 ms retry chain exhausts). This is why Tier 1 below is the app-level
   opener and Tier 2 is the suppression, in that order and not the reverse.
4. **No `project.pbxproj` change.** `FEdit/` is a `PBXFileSystemSynchronizedRootGroup`, so the one
   new source file is picked up automatically ((cli-open) plan, "stale description" point 4).
5. **The APIs this plan needs exist in the SDK and in the deployment target** (`MACOSX_DEPLOYMENT_TARGET
   = 26.0`): `SwiftUI.Scene.defaultLaunchBehavior(_:)` / `SceneLaunchBehavior.suppressed`
   (`macOS 15.0+`, verified in `MacOSX.sdk` `SwiftUI.swiftinterface`), and
   `NSApplicationDidFinishRestoringWindowsNotification` (`macOS 10.7+`,
   `AppKit/NSWindowRestoration.h`), which is documented as posted **even when there was nothing to
   restore**, always after `willFinishLaunching` and possibly before or after `didFinishLaunching`.

## Goal

A launch caused by an external open produces **exactly the windows that open asked for** — no blank
extra. Concretely: with no saved session, `fedit /tmp/fedit-stray/notes.md` from a cold start gives
one window (the CLI window). Everything else about launch is unchanged: an ordinary launch with no
session still gives exactly one blank window, a launch with a saved session still restores exactly
its windows, and a launch with a saved session plus an external open gives the restored windows plus
one CLI window.

The mechanism is: **the app owns its launch window instead of SwiftUI.** No window is claimed,
inspected for content, reused, or closed.

## Engaging the Revision 2 / 3 history (why this is not another claim heuristic)

(cli-open) went through two DO-NOT-SHIP reviews on exactly this surface. The failure both times was
the same shape: *deciding that some existing window is "empty enough" to be repurposed.* Revision 2
removed fill-an-empty-window because the pristine guard both under- and over-matched; Revision 3 and
3.1 then showed the pristine guard is blind to a `@SceneStorage` snapshot that arrives after the
first render (the repo's own late-arrival recovery rule in `ContentView.body` proves late snapshots
are real), so a restored session window could be silently overwritten. The final design removed the
question entirely with a typed window payload.

Two consequences for this item:

* **The "close it if still pristine once the CLI window appears" option in the TODO is rejected, not
  deferred.** It is the *same* predicate (`roots.isEmpty && openFile == nil && snapshot.isEmpty`)
  with the same blindness, and a worse remedy: overwriting a restored window loses its state until
  the next save, closing it destroys the scene and its saved state outright. A wrong guess would be
  permanent and silent. Do not build it.
* **This plan does not ask "is that window empty?" at all.** It asks a different question, one
  runloop phase earlier: *"should a default launch window be created in the first place?"* The only
  inputs are (a) has an external open been received during this launch, (b) does any window of ours
  already exist. Nothing reads or writes a window's contents. A wrong answer is a window too few or
  a window too many, both visible immediately and both recoverable; it can never destroy state.

That difference in failure shape is the entire justification for touching this area again.

## Design

**D1 — Both `WindowGroup`s get `.defaultLaunchBehavior(.suppressed)`.** The `"editor"` group is the
one SwiftUI launches by default (it is first); `"cli-open"` is suppressed as well so that suppressing
the first scene cannot promote the second to default-launch scene (a nil-token `cli-open` window
would be the same stray window in a new costume).

**D2 — The launch-window decision runs once per process, when both launch signals have arrived**:
`applicationDidFinishLaunching` (already plumbed as `LaunchCoordinator.noteLaunchFinished()`) **and**
`NSApplication.didFinishRestoringWindowsNotification` (new; observed from a new
`AppDelegate.applicationWillFinishLaunching`, because the notification can precede
`didFinishLaunching`). One `DispatchQueue.main.async` hop after the later of the two, so an odoc
delivered in the same runloop turn is still counted.

**D3 — The decision itself is a pure function** in a new Foundation-only
`FEdit/App/LaunchWindowDecision.swift`, so the only branchy logic in this item is covered by a
`swiftc` harness (SPEC §13: there is no XCTest target):

```swift
struct LaunchWindowInputs: Equatable {
    let didFinishLaunching: Bool
    let didFinishRestoringWindows: Bool
    let alreadyDecided: Bool
    let externalOpenSeenThisLaunch: Bool   // ≥1 valid OpenRequest received before the decision
    let existingWindowCount: Int           // our windows/scenes known to exist right now
}

enum LaunchWindowDecision: Equatable {
    case wait                              // signals incomplete, or already decided
    case suppress(SuppressReason)          // .externalOpen | .windowsAlreadyExist
    case presentBlankWindow
}
```

**D4 — `existingWindowCount` is deliberately false-negative-biased.** It is
`max(scenesAppearedCount, NSApp.windows.count { $0.delegate is WindowCloseGuardProxy })` —
`scenesAppearedCount` incremented from `ContentView.onAppear`, the proxy count reusing the same
window identification `AppDelegate.applicationShouldTerminate` and
`LaunchCoordinator.bringWindowToFront(for:)` already rely on. Only *our* windows can match either
signal, so an over-count (→ windowless launch) is impossible; an under-count degrades to today's
behavior (one extra blank window). Every uncertainty in this design is pushed into that direction.

**D5 — `externalOpenSeenThisLaunch` is set in `enqueueFileOpens` only after URL resolution**, i.e.
only when at least one `OpenRequest` survived. `open -a FEdit /gone` therefore still yields the
ordinary blank startup window rather than a windowless launch. The flag is sticky for the process
(the decision is once-only, so there is nothing to clear).

**D6 — Nothing about *targeting* changes.** SPEC §3's "an external open always opens a **new**
window; no existing window is ever disturbed" stands verbatim; `CLIOpenToken`, the three-layer token
invariant, the pristine checks and the one-turn hop in `ContentView.applyCLITokenIfNeeded()` are all
untouched. This item only changes how many windows the *system* creates before that machinery runs.

## Acceptance criteria

Setup, run before each block:
`mkdir -p /tmp/fedit-stray/sub && printf '# Hi\n' > /tmp/fedit-stray/notes.md && printf 'x = 1\n' >
/tmp/fedit-stray/a.py && printf 'y\n' > /tmp/fedit-stray/sub/b.txt`.
"Cold, no saved session" = quit FEdit, then
`rm -rf "$HOME/Library/Saved Application State/com.felixmatschke.FEdit.savedState"` (this is where
both the window restoration state and SwiftUI's `@SceneStorage` values live).
Window count, used by every GUI criterion below, is **objective, not eyeballed**:
`osascript -e 'tell application "System Events" to tell process "FEdit" to count windows'`
(needs Automation/Accessibility permission for the terminal once; if it is refused, fall back to a
human count and say so in the run notes). Counts are read 3 s after the command, and small roots are
used throughout so the (async-root-scan) wedge cannot distort the timing.

* **S1 — the bug reproduces on HEAD [GUI, Tier 0, 3 runs].** Cold, no session, `fedit
  /tmp/fedit-stray/notes.md` → count == **2** (CLI window + blank). If it is already 1, the item is
  closed as not-reproducible and the remaining tiers are not built.
* **S2 — the fix [GUI, 5 runs, all must pass].** Same as S1 on the built branch → count == **1**, and
  that window has `fedit-stray` as its sole sidebar root with `notes.md` open and the preview column
  present (visual).
* **S3 — ordinary launch, no session, unchanged [GUI, 3 runs].** Cold, no session, `open -a FEdit`
  (or Finder) → count == **1**, sidebar shows the empty state, no folder panel. Time-to-one-window is
  recorded by polling the count every 100 ms; must be < 2 s (it is a *recorded number*, and the gate
  is only that a window appears).
* **S4 — session restore intact [GUI, 5 runs, all must pass].** Build a two-window session (window A
  root `/tmp/fedit-stray` with `notes.md` open, window B root `/tmp/fedit-stray/sub` with `b.txt`
  open, distinct caret positions), Cmd+Q, relaunch ordinarily → count == **2**, each window with its
  own root, open file and caret. This is the detector for LB1 (suppression disabling restoration) and
  LB3 (deciding before restoration produced its windows); it must be run before commit.
* **S5 — restore + external open [GUI, 5 runs].** Same session, quit, then cold `fedit
  /tmp/fedit-stray/notes.md` → count == **3**: both restored windows with their own content
  unchanged, plus the CLI window. Zero blank windows.
* **S6 — no-argument shim still gives a window [GUI, 3 runs].** Cold, no session, `fedit` (no
  operands, i.e. `open -a`) → count == **1**, blank. This is the criterion a naive "suppress whenever
  the app was launched from the CLI" would fail.
* **S7 — multi-path invocation [GUI].** Cold, no session, `fedit /tmp/fedit-stray/notes.md
  /tmp/fedit-stray/a.py` → count == **2**, one window per file, neither blank.
* **S8 — external open with zero windows [GUI] (Tier 1; also clears (cli-open)'s owed A24).** App
  running, close every window (count == 0), `fedit /tmp/fedit-stray/notes.md` → count == **1**, file
  open. Run once on HEAD to record the baseline and again after Tier 1.
* **S9 — Dock reopen parity [GUI] (Tier 3).** App running, count == 0, click the Dock icon → count ==
  **1**, blank. Compared against the Tier 0 P4 baseline recording of the same gesture — Tier 3 ships
  only if this regresses or if the baseline was already broken.
* **S10 — Cmd+O and Cmd+N unaffected [GUI].** From a launched app: Cmd+O → count increases by exactly
  1 and that window presents the folder panel; Cancel leaves it empty and the count unchanged. Cmd+N
  in a window with a root still opens the New File sheet in that window (count unchanged).
* **S11 — quit with zero windows, relaunch [GUI, 3 runs].** Close all windows, Cmd+Q (saved state
  exists but records no windows), relaunch ordinarily → count == **1**, blank. This is where a
  suppression bug shows up as a windowless launch.
* **S12 — decision truth table [UNIT].** `swiftc FEdit/App/LaunchWindowDecision.swift
  scripts/LaunchWindowDecisionTests/main.swift -o /tmp/lwdtests && /tmp/lwdtests` → 0 failures.
  Asserts: either signal missing → `.wait`; `alreadyDecided` → `.wait`; both signals + external open
  → `.suppress(.externalOpen)`; both + `existingWindowCount > 0` → `.suppress(.windowsAlreadyExist)`;
  both + external open + windows → `.suppress` (never `.presentBlankWindow`); both + neither →
  `.presentBlankWindow`. Failing-direction assertion included: no input combination with
  `externalOpenSeenThisLaunch == true` ever returns `.presentBlankWindow`.
* **S13 — no regressions [CLI].** Debug build green; the eight existing harnesses still report 430
  assertions / 0 failures (`OpenRequestTests`, `FeditShimTests`, `FileNodeTests`, `FilterQueryTests`,
  `GitStatusTests`, `LogicalLineTests`, `MarkdownRendererTests`, `SnapshotTests`).
* **S14 — no flash [GUI, light].** During S3, no window is shown and then hidden (watch the launch, or
  screen-record it and step through). Recorded, not a hard gate.

## Implementation tiers

### Tier 0 — Launch-order gate (instrumentation only; nothing ships)

Temporary `NSLog`s with timestamps, all reverted before any commit:
`AppDelegate.applicationWillFinishLaunching` / `application(_:open:)` (URL count) /
`applicationDidFinishLaunching`; an observer of `NSApplication.didFinishRestoringWindowsNotification`
logging `NSApp.windows.count`; `ContentView.onAppear` logging whether it is a cli-open scene
(`cliToken != nil`) and whether `workspaceSnapshot` was empty.

Probes:
* **P1** — does the bug reproduce (S1), and is the stray window an `"editor"`-group scene?
* **P2** — on a cold launch-by-open, does `application(_:open:)` fire before
  `applicationDidFinishLaunching`, and before/after the stray scene's `onAppear`?
* **P3** — is `didFinishRestoringWindows` posted on a launch with a two-window session *before* those
  scenes' `onAppear`, or after? (This is LB3, the assumption with the widest consequence.)
* **P4** — baseline recordings, on HEAD: S8 (zero-windows CLI open) and S9 (Dock reopen with zero
  windows), so Tier 1/Tier 3 can be judged as fixes rather than regressions.
* **P5** — cheap hypothesis kill: implement `applicationShouldOpenUntitledFile` returning `false` +
  a log. If SwiftUI honors it for the `WindowGroup` default window, the whole item collapses to
  ~5 lines in `AppDelegate` (AppKit does not send it on an odoc launch at all, so the answer is
  implicit in whether it is called) and Tiers 1–3 are replaced. Expected: not called / not honored.

*Revert:* `git checkout` the two touched files; nothing is committed from this tier.
*Pays off alone:* **yes** — it can close the item (P1) or replace the whole design (P5), and its
recorded orderings are what make the later tiers' assumptions falsifiable rather than hopeful.

### Tier 1 — App-level window opener (prerequisite; independently useful)

`FEdit/App/FEditApp.swift`: `@Environment(\.openWindow) private var openWindow` on `FEditApp`, and in
`body`, before the scenes, a declaration statement (result builders pass declarations through):

```swift
let _ = LaunchCoordinator.shared.registerAppWindowOpener(
    editor: { openWindow(id: "editor") },
    cliOpen: { openWindow(id: "cli-open", value: $0) }
)
```

`FEdit/App/LaunchCoordinator.swift`: store that pair; `registerAppWindowOpener` is idempotent and, if
requests are pending, re-enters `issueWindowsForPendingFileOpens()` exactly as `registerWindowOpener`
does. `issueWindowsForPendingFileOpens()` prefers the app-level opener; the scene-registered
`openNewWindow` stays as a fallback used only when no app-level opener exists, and
`registerWindowOpener` becomes a no-op once one does (documented — otherwise "last writer wins" would
let a soon-to-close window's captured action displace the durable one). The class doc comment's
paragraph about `openNewWindow` being nil until a scene appears is rewritten.

*Interface it publishes (this is what Tier 2 consumes):* **`LaunchCoordinator` can create an editor
window or a cli-open window at any time after `App.body` has been evaluated — including when zero
windows exist and no scene has ever appeared.**

*Revert:* remove the `let _ =` declaration and the coordinator's app-level fields/precedence (~25
lines). Window creation returns to the scene-registered opener exactly as (cli-open) shipped.
*Pays off alone:* **yes** — it closes (cli-open)'s recorded zero-windows residual (S8) and makes the
20 × 100 ms retry chain dead code on the normal path rather than the mechanism.

### Tier 2 — App-owned launch window (the fix)

* `FEdit/App/FEditApp.swift`: `.defaultLaunchBehavior(.suppressed)` on **both** `WindowGroup`s (D1),
  with a comment naming this item and the reason the second one is suppressed too.
* **New** `FEdit/App/LaunchWindowDecision.swift`: `LaunchWindowInputs`, `LaunchWindowDecision`,
  `SuppressReason`, and `func decideLaunchWindow(_:) -> LaunchWindowDecision` (D3). Foundation-only,
  no AppKit/SwiftUI, so the harness can compile it standalone.
* `FEdit/App/LaunchCoordinator.swift`: `didFinishRestoringWindows`, `externalOpenSeenThisLaunch`
  (set in `enqueueFileOpens` per D5), `scenesAppearedCount`, `didDecideLaunchWindow`;
  `noteWindowRestorationFinished()`, `noteSceneAppeared()`, and `maybeDecideLaunchWindow()` which
  gathers inputs (D4), calls `decideLaunchWindow`, and on `.presentBlankWindow` calls the Tier 1
  editor opener. `noteLaunchFinished()` calls it after its existing dispatch.
* `FEdit/App/WindowCloseGuard.swift`: `AppDelegate.applicationWillFinishLaunching` registering the
  `NSApplication.didFinishRestoringWindowsNotification` observer (it can fire before
  `didFinishLaunching`, so registering in `didFinishLaunching` would be too late).
* `FEdit/Views/ContentView.swift`: `LaunchCoordinator.shared.noteSceneAppeared()` in `.onAppear`
  (one line, next to the existing registration).
* **New** `scripts/LaunchWindowDecisionTests/main.swift`: S12, in the established harness shape
  (top-level `check(...)`, `failureCount`, PASS/FAIL summary).
* Docs (kept in the tier that causes them, per (cli-open) Revision 2 defect 7): SPEC §3 — the app
  decides its own launch window, so a launch caused by an external open comes up with only that
  open's window(s); §9 — restoration is unaffected and still wins; §13 — add
  `App/LaunchWindowDecision.swift` and `scripts/LaunchWindowDecisionTests`, and refresh the
  `App/LaunchCoordinator.swift` line to mention the launch-window decision.

*Gate, in order:* S12 → S3 → S11 → **S4** (the restoration detector — if this fails, stop and revert;
do not attempt to patch around it) → S2 → S5 → S6, S7, S10.

*Revert:* delete the two scene modifiers, `LaunchWindowDecision.swift` and its harness, the
coordinator's four fields and three methods, the `applicationWillFinishLaunching` method, the
`ContentView` line, and the SPEC hunks. Tier 1 keeps working; the stray window comes back and nothing
else changes.
*Pays off alone:* it **is** the fix, but it must not ship without Tier 1 — suppression with only a
scene-registered opener means a cold `fedit x.md` opens nothing at all.

### Tier 3 — Windowless safety net and Dock-reopen parity (insurance)

* `FEdit/App/LaunchCoordinator.swift`: after the decision, one `DispatchQueue.main.asyncAfter(1.5 s)`
  check — if `existingWindowCount == 0`, `undispatched.isEmpty`, and no cli-open window has been
  issued, present a blank editor window. Once per process, idempotent with the decision.
* `FEdit/App/WindowCloseGuard.swift`: `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)`
  → when `!hasVisibleWindows` and our window count is 0, call the Tier 1 editor opener and return
  `false`; otherwise return `true` and let AppKit do what it does today.
* SPEC §3 gets one sentence only if S9's baseline (P4) showed the reopen behavior changing.

*Revert:* delete both methods and the timer (~30 lines).
*Pays off alone:* only partly. The safety net is dead code unless Tier 2 is present. The reopen
handler pays off alone **iff** Tier 0's P4 baseline shows Dock reopen with zero windows is already
broken today; otherwise it is pure insurance against Tier 2's suppression changing that path, and it
should be built only if P4 or S9 says so.

## Interfaces between tiers

* **Tier 0 → everything:** facts only, no code. It fixes which branch the rest is built on (bug real /
  odoc ordering / restoration-notification ordering / baselines / the `applicationShouldOpenUntitledFile`
  shortcut).
* **Tier 1 → Tier 2:** the single contract quoted in Tier 1 — window creation no longer requires an
  existing window. Tier 2 depends on nothing else from Tier 1, and Tier 1 depends on nothing from
  Tier 2 (it is shippable and useful on its own).
* **Tier 2 → Tier 3:** `LaunchCoordinator` exposes "has the launch decision been made" and "how many
  of our windows exist"; Tier 3 reads exactly those two and calls the same Tier 1 opener. No new
  state.
* **Inside Tier 2:** `LaunchWindowDecision.swift` is the seam — every branch lives in a pure,
  Foundation-only function that the harness pins; `LaunchCoordinator` only *gathers* inputs and
  *executes* the verdict; `FEditApp` only declares suppression and registers openers; `ContentView`
  only reports that a scene appeared. No file in this item reads or writes a window's contents.

## Load-bearing assumptions

**LB1 — `.defaultLaunchBehavior(.suppressed)` suppresses only the *default launch* window and does
not disable system window restoration for that scene group.**
*If false:* session restore (SPEC §9) breaks — the app comes back with no windows and every saved
session is lost on the first quit-relaunch. This is the worst outcome in the plan. *Detected by:* S4,
run before commit, 5×. *Rewrite:* revert Tier 2 wholesale (~90 lines, one modifier + one file + one
method group) and fall back to the LB3 contingency below or close the item as won't-fix; Tier 1 still
stands on its own.

**LB2 — With every scene suppressed, SwiftUI creates no window at launch (it does not promote another
scene to default).**
*If false and it promotes `"cli-open"`:* the stray window returns as a nil-token cli-open window —
detected by S1/S2 and by Tier 0's scene-identity logging. *If false and suppression is ignored when
all scenes are suppressed:* the item is not fixable this way; revert Tier 2. *Rewrite:* revert Tier 2.

**LB3 — `NSApplicationDidFinishRestoringWindowsNotification` fires on every launch (documented) and,
by the time it fires, SwiftUI's restored windows exist or their scenes have appeared.**
The second half is the risky half: SwiftUI's scene-state delivery is demonstrably asynchronous in
this app (`ContentView`'s late-`@SceneStorage` recovery rule), and it is not established that scene
*window creation* is inside AppKit's restoration phase. *If false:* every session-restore launch
gains an extra blank window — a regression on the common path, strictly worse than the bug being
fixed. *Detected by:* Tier 0 P3 (ordering, before writing code) and S4/S5 (counts, before commit).
*Rewrite:* ~15 lines — replace the trigger with "later of the two signals, then a 500 ms deadline,
re-checking `existingWindowCount`". That reintroduces a timing argument of the kind Revision 3
criticised, so it is acceptable *only* because its failure direction is one extra empty window and
never a mutated window; if the deadline variant is also flaky in S4/S5, revert Tier 2.

**LB4 — `@Environment(\.openWindow)` resolves in an `App`, and a `let _ = …` declaration inside the
`SceneBuilder` body runs once, early, before the odoc arrives.**
*If false:* no app-level opener. *Fallback (already recorded as (cli-open)'s L4 fallback):* register
from `FileCommands`, whose `Commands` body is built with the menu bar and outlives every window
(~10 lines, same shape). If neither resolves, Tier 2 cannot ship at all and the item stops after
Tier 0/1. *Detected by:* Tier 1's S8.

**LB5 — A captured `OpenWindowAction` can create the process's *first* window (zero windows, no scene
ever appeared).** (cli-open) Revision 3 disposition #4 recorded scripted evidence of 0 → 1 working
from a scene-captured action; app-level is the same action type from a longer-lived source.
*If false:* a cold launch-by-open opens nothing — a hard failure. *Detected by:* S2 and S8.
*Rewrite:* revert Tiers 1–2; there is no other way to create a `WindowGroup` window.

**LB6 — On a cold launch-by-open, `application(_:open:)` is delivered before the launch decision
runs** (Apple's documented sequence puts odoc between `willFinishLaunching` and
`didFinishLaunching`). *If false:* no improvement — the blank window is created and the CLI window
joins it, i.e. exactly today's behavior; no regression. *Detected by:* Tier 0 P2 and S2.
*Rewrite:* the LB3 deadline variant (~15 lines) widens the window; if the odoc genuinely arrives
after `didFinishLaunching` the item is not fixable without a user-visible launch delay, and stops.

**LB7 — (async-root-scan) lands before this item and changes *when* a restored window finishes
loading, not *whether* its window exists by the restoration-finished signal.** The decision reads
window existence, never content, so it is insensitive to scan timing; and while the scan is still
synchronous, the main thread serialises everything, so the decision simply runs later and still sees
the windows. *If false* (async restore defers window creation past the signal): LB3's failure mode
and LB3's fallback. *If (async-root-scan) has not landed:* nothing structural changes — but every GUI
criterion must use the small `/tmp/fedit-stray` roots so a home-directory-scale wedge cannot mask a
window-count failure as a timing failure.

**LB8 — The stray window still reproduces on HEAD, from the `"editor"` group's default launch.**
*If false:* the item closes as not-reproducible (Tier 0 P1) — no code is written.

## Out of scope

* Any form of claiming, reusing, filling, or **closing** an existing window for an external open. The
  TODO's "close it if still pristine" option is rejected above, with reasons; SPEC §3's "always a new
  window, no existing window is ever disturbed" stands unchanged.
* Any change to `CLIOpenToken`, the three-layer token invariant, `OpenRequest`, `ContentView.applyCLITokenIfNeeded()`,
  `WorkspaceModel`, `@SceneStorage` snapshot semantics, or the save/dirty/autosave paths.
* (async-root-scan) itself — this plan only assumes it and stays insensitive to it.
* (cli-open)'s other recorded residuals: CLI-open-during-a-modal-folder-panel nesting, dotfile
  arguments having no highlighted sidebar row, symlink canonicalisation divergence, and
  window-creation-failure reconciliation beyond Tier 3's blunt safety net.
* `Info.plist` / `CFBundleDocumentTypes` / `project.pbxproj` — (cli-open)'s gate proved odoc is
  delivered without a document-type declaration, and no new file is added outside the synchronized
  group.
* Becoming a document-based app (`DocumentGroup`), a Dock menu, `applicationShouldTerminateAfterLastWindowClosed`,
  or any change to how many windows a *user* action creates.
* Restoring more or fewer session windows than macOS decides to restore.

## Files touched

| File | Tier | What |
|---|---|---|
| `FEdit/App/FEditApp.swift` | 1, 2 | app-level `@Environment(\.openWindow)` + opener registration; `.defaultLaunchBehavior(.suppressed)` on both `WindowGroup`s |
| `FEdit/App/LaunchCoordinator.swift` | 1, 2, 3 | app-level opener + precedence; restoration/appear/decision state; `maybeDecideLaunchWindow()`; safety net; doc comment rewrite |
| `FEdit/App/LaunchWindowDecision.swift` | 2 | **new** — pure decision function + input/verdict types (Foundation-only) |
| `FEdit/App/WindowCloseGuard.swift` | 0, 2, 3 | `AppDelegate.applicationWillFinishLaunching` (restoration observer); `applicationShouldHandleReopen`; Tier 0 instrumentation (reverted) |
| `FEdit/Views/ContentView.swift` | 0, 2 | `noteSceneAppeared()` in `.onAppear`; comment update on the scene-level opener now being a fallback; Tier 0 instrumentation (reverted) |
| `scripts/LaunchWindowDecisionTests/main.swift` | 2 | **new** — S12 truth-table harness |
| `SPEC.md` | 2, 3 | §3 (app-owned launch window), §9 (restoration unaffected), §13 (new file + harness, refreshed `LaunchCoordinator` line) |
| `README.md` | 2 | only if the "Command line" section's `fedit` (no-arg) description needs the "exactly one window" promise — likely a single sentence, possibly none |
| `TODO.md`, `DONE.md` | — | item bookkeeping at `/done` |

No `FEdit.xcodeproj/project.pbxproj` change (synchronized root group), no `scripts/fedit`,
`scripts/install.sh`, or `FeditShimTests` change — the shim's contract is untouched by this item.
An optional throwaway `scripts/window-count.sh` wrapper around the `osascript` count may be written
for the GUI pass; it is not part of the deliverable unless the GUI pass proves it worth committing.

---

# Revision 2 (2026-08-11) — post-review re-cut

Adversarial plan review verdict: REVISE. The three load-bearing findings (opener precedence,
Tier 3 guard, window-count signal) were re-verified against source before folding: `openWindow`
is indeed non-optional in the SDK interface, `undispatched.removeAll()` does precede
`openNewWindow(token)` (LaunchCoordinator.swift:199-206) with the retry chain gated on
`guard let openNewWindow`, and the close-guard proxy is installed from the same content mount
that would drive `scenesAppearedCount`. This section supersedes the conflicting parts of the
plan above. Everything not named here stands as written.

## Design changes

**D-R1 — Opener precedence inverted (fixes the review's Critical #1).** The scene-registered
opener — the shipped, proven mechanism — stays PRIMARY. The app-level opener registered from
`App.body` is a FALLBACK, consulted only when no scene-registered opener exists (cold launch
before any scene, or the zero-windows case). Rationale: a scene-registered action is captured
from a live window's environment and demonstrably works; an app-level action cannot be told
apart from an inert one, so it must never displace a working opener. `registerWindowOpener`
stays exactly as shipped (last-writer-wins per scene appear). Revision 1's
"`registerWindowOpener` becomes a no-op once an app-level opener exists" is retracted.

**D-R2 — `registerAppWindowOpener` stores; it never dispatches inside `App.body` evaluation
(fixes #6).** The registration is a pure store (idempotent — overwriting with a semantically
identical pair is harmless). If requests are pending at registration time, it schedules
`DispatchQueue.main.async { dispatchPendingFileOpens() }` — never a synchronous re-entry from
inside the `SceneBuilder` body. One semantic, stated in the code comment.

**D-R3 — The Tier 3 net's guard is `liveWindowCount == 0 && undispatched.isEmpty` — the
"no cli-open window issued" clause is DELETED (fixes #2).** If issued windows never materialized
(inert opener, window-creation failure), the net now fires and presents a blank editor window.
Failure direction: the user gets today's behavior (a blank window, Cmd+O works) instead of a
windowless app. The net remains once-per-process. Note: `NSOpenPanel.runModal()` can delay the
1.5 s timer's firing; harmless — by then `liveWindowCount > 0` and the net no-ops (recorded).

**D-R4 — Two window-count quantities, not one composite (fixes #3, #4).**
- `liveWindowCount`: computed on demand as `NSApp.windows.count(where: { $0.isVisible &&
  $0.canBecomeKey })` at first approximation — the exact predicate is FIXED BY TIER 0's P3/P6
  measurements (what does `NSApp.windows` contain at decision time on a restore launch?), not
  assumed. Used by the Tier 3 net and `applicationShouldHandleReopen` — the consumers that need
  "right now".
- `scenesAppearedCount` stays monotonic and is used ONLY inside the once-per-process launch
  decision as the false-negative-biased second signal (`max(scenesAppearedCount,
  liveWindowCount)`), where monotonic-vs-live cannot differ (nothing has closed yet at launch).
  The review's Dock-reopen trace (counter stuck at 1 after the only window closes) is void for
  the reopen handler because it reads `liveWindowCount` only.

**D-R5 — `LaunchWindowDecision` splits `.wait` (fixes #14):** `case wait` (signals incomplete —
ask again when the other signal lands) and `case alreadyDecided` (final — stop asking). The
truth-table harness asserts both.

**D-R6 — the "editor-group produces the stray window" claim moves to the UNVERIFIED list** —
it is exactly what P1 establishes (fixes #13).

## Tier 0 changes — the spike gates the killers (fixes #5, #12)

Tier 0 gains **P6, a throwaway suppression spike** (built on a scratch commit, reverted, never
merged): `.defaultLaunchBehavior(.suppressed)` on both groups + the minimal app-level opener +
nothing else. Run: (a) cold `fedit x.md` → does a CLI window appear? [LB4+LB5+LB6], (b) cold
ordinary launch → can the spike's decision path create a first window? [LB5], (c) launch with a
two-window saved session → do both windows restore? [LB1], and does any stray appear? [LB2/LB3].
This answers every assumption whose falsity would force "revert Tier 2 wholesale" BEFORE the
real Tier 1/2 are written. If (a) or (b) fails → the item stops after Tier 0 with the findings
recorded (the design is not buildable on this platform); if (c) fails → same, LB1 is the
worst-outcome assumption and there is no fallback that does not reintroduce claim heuristics.

**P5 is rewritten as pure instrumentation (fixes #12):** log whether and when
`applicationShouldOpenUntitledFile` is called on (i) an ordinary cold launch and (ii) a cold
launch-by-open — no behavioral `return false` in the probe. Only if the log shows it called on
(i) and not (ii), or called after the odoc on (ii), is a conditional-return collapse design even
coherent; that decision is taken after Tier 0 with the data, not speculated now.

## Acceptance criteria changes

- **S3 (fixes #11):** the GATE is: a window appears within **5 s**. The <2 s figure is a
  recorded measurement target, not a gate.
- **S9 moves into Tier 2's gate list (fixes #9),** run immediately after S11: Dock reopen with
  zero windows, post-suppression. Tier 3's reopen handler is built iff S9 regresses vs P4's
  baseline (or the baseline was already broken).
- **S10 (fixes #8):** counts are read at two defined moments only: before Cmd+O (n) and after
  Cancel (n+1, the new empty window remains — cli-open A3's documented shape). No count is read
  while the modal panel is up (`runModal` makes that moment ill-defined). Cmd+N clause unchanged.
- **NEW S15 [GUI, 3 runs] (fixes #7):** build a session that INCLUDES a live cli-open window
  (`fedit notes.md`, then add work in it), Cmd+Q, relaunch ordinarily → the cli-open window is
  restored with its content, per SPEC §3's "it is restored with the next session like any other".
  This is the detector for suppression interfering with the cli-open group's restoration.
- **NEW S16 [GUI, recorded, not a gate] (fixes #10):** resize/move the single blank window, quit
  (no session windows recorded), relaunch → record whether the frame is preserved vs default
  1100×700. SPEC §3's frame promise concerns *restored* windows (untouched); this records
  whether the app-created default window regresses frame memory for the no-session path.
- **S12** gains the `.alreadyDecided` assertions (D-R5).

## Decisions taken (Revision 2)

All dated 2026-08-11, folding the adversarial plan review (verdict REVISE).

- **Scene-registered opener stays primary; app-level is fallback-only** (review Critical #1
  verified: non-optional `EnvironmentValues.openWindow` means an inert action is
  indistinguishable from a working one). Alternative: Revision 1's app-level-first with the
  no-op'd scene registration. Rejected: it replaces a proven mechanism with an unverifiable one
  and removes the retry chain's rescue path.
- **Net guard simplified to live-count + empty-queue** (review #2 verified: the issued-token
  clause disarms the net in exactly the insured failure). Alternative: re-dispatch unappeared
  tokens. Rejected: re-dispatch needs issued-token→request bookkeeping and can double-open on
  slow scene creation; a blank window is the safe, visible, recoverable failure direction.
- **Live count from `NSApp.windows`, predicate fixed by measurement** (review #3/#4 verified:
  proxy-count and appear-count are one signal, and the monotonic composite made Tier 3 dead
  code). Alternative: keep the composite. Rejected outright — the review's traces are correct.
- **Suppression spike added to Tier 0** (review #5): the three revert-wholesale assumptions are
  now gated by a throwaway spike before real code, converting "build 90 lines then discover" into
  an hour of probing. Alternative: trust the SDK documentation. Rejected: `.suppressed`'s
  interaction with restoration is precisely the kind of behavior the docs do not pin.
- **Unconditional suppression accepted knowingly** (review Tension #15): `defaultLaunchBehavior`
  is fixed at scene-graph build time, so "suppress only when an open is in flight" is not
  expressible; the app must own the launch window on every launch. Mitigations: the pure decision
  function is harness-pinned, S3/S4/S5/S11/S15 cover every launch shape, and the GUI pass is
  recorded as owed where it cannot be scripted. The manual-only regression surface for future
  edits is recorded as a residual in DONE.md.
- **LB3's deadline fallback is now the acknowledged likely landing spot** (review #16), its
  number to be sized by P3's measured timing rather than the unmeasured 500 ms; acceptable only
  because its failure direction is one extra blank window, never a touched one. If the deadline
  variant proves flaky in S4/S5, Tier 2 is reverted — unchanged from Revision 1.
- **LB5's evidence staleness recorded** (review #5): the zero-windows 0→1 evidence is
  pre-token-redesign; S8 re-establishes it in Tier 1 before Tier 2 builds on it.
