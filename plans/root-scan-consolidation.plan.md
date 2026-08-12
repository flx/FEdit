# root-scan-consolidation — plan (Revision 2)

**Risk tier: hi.** Concurrency-subtle (the scan gate / generation / damping state machine whose
correctness the 2026-08-11 arch-review verified is carried by prose invariants), and wide blast
radius: every scan path in the app (add, remove, refresh, watcher, createFile, session restore)
routes through the code being restructured. Full plan, plan review, both code reviewers.

*Revision 2 folds in the adversarial plan review (16 findings, 3 tensions — all accepted; see
Decisions). Revision 1's shape survives; what changed: invariants I12–I15 added, criterion 3
reworded to match the measured baseline, tiers re-cut 3→2+docs, the `launchWalk` completion type
gains `@Sendable`, the clock-injection path is pinned, and the teardown gains two harness cases.*

## Goal

Collapse the per-root scan bookkeeping (`scanningRootURLs`, `rescanRequested`, `forcedRescans`,
`scanGeneration`, `scanTokens`, `lastScanFinish`, `lastScanDuration`, `rescanBackoff`,
`pendingDampedRescans` — nine of the arch-review's ten; see Decisions for `initialScanRootURLs`)
into one `RootScan` value keyed by URL, owned by an extracted `RootScanScheduler` subsystem, so
that "drain a root" is a type-level operation instead of four hand-maintained sites — and move the
scan teardown out of `WorkspaceModel.deinit` into the subsystem's owned lifecycle, eliminating the
file's three measured Swift 6 strict-concurrency errors.

**No user-visible behavior change.** This is a structure refactor; every observable scan behavior
(gating, coalescing, damping arithmetic, generation discard, "Scanning…" affordance) must be
preserved exactly.

## Acceptance criteria

1. `WorkspaceModel` no longer declares any of the nine per-root scan properties; per-root scan
   state lives in a single `[URL: RootScan]` inside a new `RootScanScheduler` type. Verified by
   grep over **code**: no declaration or code reference to the nine names remains in
   `WorkspaceModel.swift`. Doc comments that narrated the old machine (the `removeRoot` drain
   paragraph, `initialScanRootURLs`'s "Deliberately not `scanningRootURLs`" contrast, and the five
   blocks naming `requestScan`/`applyScan`/`deinit` — `refreshAll`, `handleTreeChange`,
   `isSkippedTreePath`, `createFile`, plus `FileNode.swift`'s threading contract §"only scan call
   site") are **rewritten in the same change** to name the scheduler; a doc-comment sweep for the
   nine names is part of the criterion.
2. Draining a root on removal is one scheduler call (`noteRootRemoved`), and the drain invariants
   (the entry — with its **bumped** generation — and the in-flight gate survive until the walk's
   own landing) are maintained inside the type, not at call sites. Verified by code reading +
   harness cases.
3. `WorkspaceModel` has **no `deinit`**. Measured baseline (2026-08-11, this session):
   `SWIFT_STRICT_CONCURRENCY=complete` emits exactly 4 diagnostics for `WorkspaceModel.swift` —
   the 3 nonisolated-deinit accesses (`:356`, `:357`, `:367`; errors in Swift 6 mode) + 1
   module-level "`add @preconcurrency` to `import Dispatch`" note (`:23`). After: the **3 deinit
   diagnostics are gone**; the `@preconcurrency` note is out of scope and may remain (and may
   equally attach to `RootScanScheduler.swift`, which also imports Dispatch-via-Foundation);
   **no new** strict-concurrency diagnostic appears in either file beyond that note.
4. Build green, all 8 existing harnesses green (same counts as baseline), plus a **new**
   `scripts/RootScanTests` swiftc harness covering the scheduler state machine (gate coalescing,
   force-bit folding, damping arithmetic incl. the proportional term, the no-clock rule I13, and
   backoff reset; generation discard on remove/re-add; the unconditional landing drain I12;
   drain-on-remove; entry GC; **teardown: scheduler dealloc cancels an in-flight walk's token,
   and a `weak` ref to a released scheduler reads nil** — the no-self-retain check). Target ≥ 30
   assertions.
5. No behavior change reachable from the UI: `addFolders` / `removeRoot` / `refreshAll` /
   `createFile` / `restore(fromJSON:)` / `handleTreeChange` call sequences produce the same scan
   requests, same publishes (`roots`, `initialScanRootURLs`), same damping decisions as before.
   Verification mechanism, stated honestly: the scheduler side is pinned by the harness; the
   model-side splice/publish wiring has no automated test (no UI test infra exists) and is
   verified by the I1–I15 trace during code review — plus the standing manual GUI pass owed on
   this subsystem since (async-root-scan).

## Design

### New file `FEdit/Models/RootScanScheduler.swift` (Foundation-only, @MainActor)

```swift
/// Per-root scan bookkeeping, one value per root URL.
struct RootScan {
    var isScanning = false           // was scanningRootURLs membership
    var rescanRequested = false      // was rescanRequested membership
    var forcedRescan = false         // was forcedRescans membership; I14: true ⇒ rescanRequested
    var generation = 0               // was scanGeneration[url]
    var lastFinish: DispatchTime?    // was lastScanFinish[url]; Optional is load-bearing (I13)
    var lastDuration: TimeInterval?  // was lastScanDuration[url]
    var backoff: TimeInterval?       // was rescanBackoff[url]
    var pendingDampedRescan: DispatchWorkItem?  // was pendingDampedRescans[url]
}

@MainActor
final class RootScanScheduler {
    private(set) var scans: [URL: RootScan] = [:]
    private let tokens = TokenRegistry()          // nonisolated; deinit cancels leftovers
    // seams (see Injection):
    //   currentNode: (URL) -> FileNode?          — model's roots lookup; nil ⇒ root gone
    //   land: (URL, FileNode, _ changed: Bool, _ force: Bool) -> Bool
    //                                            — model splices into roots (+ initialScan
    //                                              removal); returns false if root vanished
    //   launchWalk / armTimer / now              — walk executor, timer, clock (testability)
    func noteRootAdded(_ url: URL)                // generation bump (addFolders placeholder)
    func noteRootRemoved(_ url: URL)              // drain: bump generation, cancel+remove token,
                                                  // cancel timer, clear request/force bits +
                                                  // damping clocks; the entry (with its bumped
                                                  // generation) and isScanning survive while a
                                                  // walk is in flight; GC otherwise
    func requestScan(of url: URL, force: Bool = false, damped: Bool = false)
}
```

- **Call-ordering contract (explicit, was implicit in Rev 1):** `noteRootAdded(url)` is called
  **before** the placeholder is appended to `roots` (so the scheduler must not consult
  `currentNode` there — during an add it reads nil); `noteRootRemoved(url)` is called **after**
  `roots.removeAll` (its GC check *does* consult `currentNode`, and calling it early would see
  the root as present and never GC). Both orderings are documented on the methods and mirrored in
  the harness's fake `currentNode`.
- **No-self-retain invariant (teardown is a reachability argument):** the scheduler must hold no
  strong reference to itself — the injected closures are stored, so the **defaults must not
  capture the scheduler** (`launchWalk`'s default is a `static` function; `armTimer`/`now`
  defaults are free closures). `currentNode`/`land` capture the *model* `[unowned self]`, which
  is outside the scheduler's ownership graph. Checked by the criterion-4 weak-ref harness case.
  The `[unowned self]` in those closures is safe today (single strong owner, no teardown path
  invokes them) and is a recorded trap: **no future teardown path may call `currentNode`/`land`**
  — noted on both closure properties.
- **Token ownership moves entirely into a nonisolated `TokenRegistry`** (`final class`,
  `NSLock`-guarded `[URL: ScanCancellationToken]`, `@unchecked Sendable`). Tokens live in exactly
  one place; `RootScan` does not duplicate them. The registry's own (nonisolated) `deinit` cancels
  every remaining token — teardown owned by the subsystem's lifecycle: when the window's model
  (and with it the scheduler) deallocates, in-flight home-scale walks stop within one directory
  entry, with no isolated-state access from any `deinit`. Identity-compare semantics of
  `applyScan` ("a job clears only its own token") are a registry method (`clear(url:ifIdentical:)`).
  Registry behavior is harness-visible through the tokens the fake `launchWalk` receives.
- `requestScan` / `applyScan` / `scheduleDampedRescan` move over with their two-gate /
  consume-on-start / trailing-edge logic **unchanged in behavior** (I1–I15 below).
- **Entry GC (new; a recorded reversal of (async-root-scan)'s "scanGeneration never pruned
  (deliberate)" residual — see Decisions):** an entry is removed when
  `currentNode(url) == nil && !isScanning && !rescanRequested && pendingDampedRescan == nil`
  — checked at `noteRootRemoved` and at the end of `applyScan` (after the unconditional drain,
  I12). `forcedRescan` needs no conjunct: I14 (`forcedRescan ⇒ rescanRequested`) makes it vacuous.
  Rationale: a job exists only while `isScanning` (the gate guarantees it), so under this
  condition no in-flight job can hold a stale generation for the URL, and a later re-add starting
  from generation 0 is safe. A **present** root's entry is never GC'd (would reset damping clocks
  and the I13 no-clock rule wrongly).
- **The walk bridge drops `Task` + `withCheckedContinuation`** for the equivalent
  `scanQueue.async { … DispatchQueue.main.async { MainActor.assumeIsolated { completion } } }`
  inside the default `launchWalk`. Same hop, same delivery on the main actor, one vocabulary fewer
  (sanctioned by the arch-review's "Two concurrency vocabularies" finding). `[weak self]` on the
  completion, token captured strongly — identical liveness to today. `scanQueue` (static,
  concurrent, userInitiated) moves into this file unchanged. Known, accepted difference (A3):
  the `scanQueue.async` enqueue now happens synchronously inside the caller
  (`addFolders`/`refreshAll`) rather than after an unstructured-`Task` main-actor hop; no
  consumer observes enqueue timing.
- **Injection for the harness** (production defaults in the initializer):
  - `launchWalk: (URL, FileNode?, ScanCancellationToken, @escaping @Sendable @MainActor (FileNode, Bool, TimeInterval) -> Void) -> Void`
    — the completion **must be `@Sendable`** (it crosses into `scanQueue.async`'s `@Sendable`
    closure; a bare `@MainActor` function type is not implicitly Sendable and criterion 3's
    strict build would reject it). The default measures the walk's duration itself (off-main,
    real clock), matching today's timing-around-the-walk-only rule; the fake supplies durations
    directly.
  - `armTimer: (TimeInterval, DispatchWorkItem) -> Void` — default `DispatchQueue.main.asyncAfter`.
  - `now: () -> DispatchTime` — **consumed by exactly one site: gate 2's elapsed-gap test.**
    The old dual-clock `secondsElapsed` split (`:564` gap test on main / `:605` duration
    off-main) becomes: gap test → injected `now()`; duration → inside `launchWalk` only. This is
    what makes the damping arithmetic actually reach the harness's settable clock; without it the
    gap branch is untestable (review finding 5).

### `WorkspaceModel` changes

- The nine properties, `requestScan`, `applyScan`, `scheduleDampedRescan`, `secondsElapsed`, the
  three damping constants, and `scanQueue` are **deleted**; the model holds
  `private lazy var scanScheduler = RootScanScheduler(...)` wired with:
  - `currentNode: { [unowned self] url in roots.first { $0.url == url } }`
  - `land: { [unowned self] url, scanned, changed, force in … }` — the existing
    generation-current branch of `applyScan` minus bookkeeping: `roots.firstIndex` membership
    check, splice on `force || changed`, guarded `initialScanRootURLs` removal; returns whether
    the root was present.
- `addFolders`: `scanGeneration[…] += 1` → `scanScheduler.noteRootAdded(url)` (same position:
  before the append); the trailing per-root `requestScan(of:)` → `scanScheduler.requestScan(of:)`.
  `initialScanRootURLs.insert` stays in `addFolders` (model-owned UI state, see Decisions).
- `removeRoot`: the 8-line drain block → `scanScheduler.noteRootRemoved(root.url)` (after the
  `roots.removeAll`) + `initialScanRootURLs.remove(root.url)`.
- `refreshAll` / `createFile`: `requestScan(…)` → `scanScheduler.requestScan(…)` verbatim.
- **`deinit` is deleted — in the same tier as the rewiring** (Tier 2 deletes
  `pendingDampedRescans`, one of the three diagnostic lines, so `deinit` cannot survive Tier 2
  in compilable form; review finding 10). Its jobs disperse:
  - scan tokens → `TokenRegistry.deinit` (above);
  - armed damped-rescan timers → **not cancelled at teardown any more**: each work item is
    `[weak self]`-guarded and fires as a no-op; the only cost is the closure living until its
    deadline (≤ `maxRescanGap` or 3× last walk). Recorded trade (Decisions).
  - `pendingAutosave?.cancel()` → dropped for the same reason (fire-time dirty re-check +
    `[weak self]` make the straggler a no-op within ≤ 0.75 s);
  - `resignActiveObserver` removal → a private nonisolated `ObservationToken` holder class whose
    `deinit` calls `NotificationCenter.default.removeObserver` (thread-safe API); the model stores
    the holder, and release-on-dealloc does the removal with no isolated access.

### Invariants that must survive verbatim (review checklist)

- **I1** At most one walk per root per scheduler; the in-flight gate is cleared **only** by the
  owning job's landing, never by removal.
- **I2** A gated request is recorded (`rescanRequested`), its `force` bit preserved
  (`forcedRescan`), and re-fired exactly once at landing — see I12 for *which* landings.
- **I3** At walk start the deferred request is consumed: request+force bits cleared (force folded
  into this walk), armed timer cancelled.
- **I4** `damped` implies `!force` at every call site; an explicit Refresh is never damped.
- **I5** Damping gap = `max(backoff, backoff > minRescanGap ? 3 × lastDuration : 0)` against the
  **monotonic** injected clock; backoff doubles (cap 30 s) on structurally-unchanged landings,
  resets to the 1 s floor on `force || changed`.
- **I6** Trailing-edge timer: at most one armed per root; fires with `damped: false`; **clears
  its own armed entry *before* testing `rescanRequested`** (reversed order leaves a permanently
  armed phantom that blocks every future damped rescan of that root); no-ops if the pending
  request was already consumed.
- **I7** Generation is bumped by add **and by remove** (the remove-bump is redundant today —
  `roots` re-entry only happens via `addFolders`, which bumps — but it is the stated guarantee
  later items may lean on, so it is kept and tested), survives removal while a walk is in
  flight, and a landing with a moved generation discards its tree (partial trees from cancelled
  walks included) while still doing job-local teardown (gate + own token).
- **I8** Damping clocks/backoff are recorded only when the landing applied to a present root with
  current generation.
- **I9** `old` (the compare baseline) is captured at walk start on the main actor; the deep
  `Equatable` diff runs off-main inside the walk job.
- **I10** `initialScanRootURLs` is inserted on placeholder append, removed only in the
  land-branch, membership-guarded (no spurious `objectWillChange` on damped no-op landings), and
  removed on root removal.
- **I11** The landing re-fire passes `force: forcedBit, damped: !forcedBit` exactly as today.
- **I12** *(the machine's most counterintuitive rule — review finding 1)* The pending-request
  drain + re-fire at a landing runs **unconditionally**, outside the generation/presence branch:
  a superseded job's coalesced request is precisely the re-added root's own scan, and gating the
  re-fire on "landed successfully" leaves a re-added root's placeholder showing "Scanning…"
  forever. Harness case required (remove → re-add mid-walk → stale landing → fresh walk fires).
- **I13** A root with **no recorded `lastFinish` is never damped** — gate 2's `if damped, let
  finished = …` binding, not an arithmetic outcome. This is what makes the first watcher rescan
  after add/re-add immediate, and it couples to GC (which wipes the clock). `Optional` fields in
  `RootScan`, not zero-defaults.
- **I14** `forcedRescan == true ⇒ rescanRequested == true` at every quiescent point (the bits
  are set together and cleared together); GC and the drain rely on it.
- **I15** `noteRootAdded` before append / `noteRootRemoved` after remove (the ordering contract
  above).

## Tiers

**Tier 1 — the scheduler + its harness (pays off alone: the state machine gains its first tests).**
New `FEdit/Models/RootScanScheduler.swift` (RootScan, TokenRegistry, scheduler with injection
seams; compiles in the app target but is not yet referenced) + new
`scripts/RootScanTests/main.swift` (compile: `swiftc FEdit/Models/FileNode.swift
FEdit/Models/RootScanScheduler.swift scripts/RootScanTests/main.swift -o /tmp/rstests`; the
harness drives everything from one `MainActor.assumeIsolated` top-level block — probe-verified
this session, see A2). Revert: delete both files. Interface to Tier 2: the API block above,
frozen — including the `@Sendable @MainActor` completion type.

**Tier 2 — rewire `WorkspaceModel` + eliminate `deinit` (the risk tier; only pays off with
Tier 1).** Delete the nine properties + moved members; wire the scheduler via the three closures;
keep `initialScanRootURLs` handling at its three sites; `ObservationToken` holder; delete
`deinit`. Rewrite the stale doc blocks in `WorkspaceModel.swift` (criterion 1's list). Measure
`SWIFT_STRICT_CONCURRENCY=complete` after (criterion 3; baseline already measured). Revert:
single-commit revert restores the old in-model machine including `deinit` (Tier 1's file is
inert without this).

**Tier 3 — docs.** SPEC §13 file table + README harness list gain the new file/harness lines;
`FileNode.swift`'s threading-contract doc block (the "only scan call site" rule) is repointed at
`RootScanScheduler` (doc-only change to a gate-compiled file — harness output must stay
identical). Revert: revert the doc commit.

## Load-bearing assumptions

- **A1** The nine properties are `private` with no consumers outside `WorkspaceModel.swift` —
  **verified by grep** (only `initialScanRootURLs` is read elsewhere: `SidebarView.swift:46`;
  the only other out-of-file mention is a doc comment in `FileNode.swift`, repointed in Tier 3).
- **A2** A `@MainActor` Foundation-only file compiles and runs under standalone `swiftc` with the
  harness driving it from a top-level `MainActor.assumeIsolated` block — **probe-verified this
  session** (miniature scheduler with injected clock/timer: compiles, runs, asserts pass). The
  `@main` alternative Rev 1 mentioned is impossible in a `main.swift` module and is struck.
- **A3** Dropping `Task`+continuation for `queue.async`+`main.async` preserves delivery order and
  actor placement (completion on main actor after the walk). The one ordering that could matter —
  a landing racing an armed timer — is closed structurally (a timer can never be armed while a
  walk is in flight: gate 1 precedes gate 2, and walk-start disarms before setting the gate).
  Named difference: enqueue timing moves earlier (see Design); no consumer observes it.
- **A4** No code depends on removed-root generations surviving **after** the in-flight walk
  lands (the GC analysis above; reviewer could not construct a hazard either). If false, keep
  entries forever as today — one-line change, invariants unaffected.

## Out of scope

- The filter-walk cache and `cursorLocation` publishing — next item (`filter-walk-main-thread`);
  this item only provides the `RootScan` home it will extend.
- The per-root scan outcome record (landed/cancelled/failed…) — `tree-node-budget`'s design.
- The skip predicate / containment helper — `root-slash-prefix-match`, `watcher-scan-skip-parity`.
- `gitQueue`'s Task+continuation bridge and the broader concurrency-vocabulary decision (the
  arch-review "Watch" item); only the scan walk's bridge changes here, because it moves anyway.
- The `@preconcurrency import Dispatch` note (criterion 3) — part of the Swift 6 "Watch" item.
- Any change to damping constants, scan ordering, or SidebarView behavior.

## Decisions taken

*(2026-08-11, planning)*

- **`initialScanRootURLs` stays a separate `@Published` set on the model** rather than folding
  into `RootScan` as the review's "ten" suggests. Alternative: publish the whole scan dictionary.
  Why: the set is the only UI-observed scan state, and its documented contract — "scan-state
  churn no longer publishes" — would be destroyed by publishing the bookkeeping dict (every gate
  insert would re-render the sidebar) or contorted by a derived-mirror. Nine of ten consolidate;
  the tenth is view state, kept at its three write sites (its doc comment rewritten to lose the
  stale `scanningRootURLs` contrast).
- **Extraction as a separate `RootScanScheduler` file**, not an in-file consolidation.
  Alternative: keep the dict inside `WorkspaceModel`. Why: the TODO's fold-in requires teardown
  "into the extracted subsystem's owned lifecycle", the arch-review's god-module direction names
  exactly this extraction, and a Foundation-only file makes the state machine harness-testable —
  the app's only scan-logic tests.
- **Armed damped timers and the pending autosave are no longer cancelled at teardown.**
  Alternative: register them too in a nonisolated registry. Why: both are `[weak self]`-guarded
  no-ops at fire time; cancellation bought only early closure release, and the registry
  bookkeeping it would cost is the disease this item cures. Tokens are different — an uncancelled
  token wastes minutes of CPU walking a dead root — so tokens get the registry.
- **Entry GC on removed roots — recorded as a REVERSAL of (async-root-scan)'s deliberate
  "scanGeneration never pruned" residual** (DONE.md), not a discovery. The old reasoning
  (resetting a generation to zero could let a re-add's bump land on a stale job's captured value)
  is still honored: GC's conjuncts admit no live job. The new fact that flips the trade: the
  entry now retains damping clocks and a work-item slot per removed root, not one `Int`.
- **The walk bridge loses its `Task`+`withCheckedContinuation` wrapper.** Alternative: move it
  verbatim. Why: the arch-review measured the wrapper as pure overhead, and the bridge must be
  rebuilt inside the injection seam anyway; keeping the simpler shape reduces the subsystem's
  concurrency vocabulary to one.

*(2026-08-11, plan review fold-in — Revision 2)*

- **All 16 findings accepted**; none rejected. The High four: I12 added (unconditional drain —
  the reviewer's exposing scenario, remove→re-add mid-walk→"Scanning…" forever, becomes a named
  harness case); criterion 3 reworded against the measured 3+1 baseline ("zero diagnostics" was
  unachievable — the `@preconcurrency` note survives any version of this change and is Watch-item
  scope); the no-self-retain invariant + two teardown harness cases added (finding 3's cycle
  scenario — a default `launchWalk` capturing `self` — is now structurally excluded by making the
  default `static`); `noteRootRemoved`'s contract fixed to bump the generation (I7 kept as the
  stated guarantee — the bump is redundant today and the plan says so, rather than silently
  shipping one of two readings).
- **Tiers re-cut 3→2+docs** (finding 10): deinit elimination merged into Tier 2 because Tier 2
  deletes one of the three diagnostic lines — the old Tier 3 could neither start from a
  compilable state nor revert independently.
- **T1/T2/T3 tensions recorded** rather than re-designed: the GC reversal is labeled as such;
  A3's enqueue-timing difference is named; `[unowned self]` stays with a written
  "no-teardown-path-may-call-these" trap note (alternative — `weak` + guard — rejected: it would
  silently no-op a landing during teardown, hiding real bugs).

*(2026-08-11, implementation + code review — hi tier, both reviewers, blind/parallel)*

- **Implementer deviations accepted** (all reported honestly, all verified): the seam typealiases
  carry `@MainActor` (strict-concurrency requires it); `now()` has **two** consumers — gate 2's
  elapsed test *and* the landing's `lastFinish` mark — because the mark and the test are two
  halves of one measurement and mixing a test clock with real uptime would make the damping
  oracle noise-dependent (the plan's "exactly one site" was wrong); `scanQueue` became
  `nonisolated static` for the nonisolated default launcher. Also accepted: I6's ordering is
  *not falsifiable* from the public API (the implementer proved the phantom state unreachable,
  exhaustively) — the plan's order is implemented and its reachable half pinned; the mutant
  survives as equivalent, matching one further equivalent survivor (force-bit clear in the
  landing drain, made redundant by I14). 14/16 mutants killed overall.
- **Both code reviewers returned "behaviorally faithful; no reachable defect."** Accepted and
  fixed: (1) `applyScan`'s read-modify-write across the `land()` callout — state now written
  back *before* the model callout and re-read after, restoring the old code's re-entrancy shape
  (unreachable today — no synchronous `objectWillChange` subscriber exists — but it sat exactly
  on I2/I12); (2) the `noteRootRemoved` damping-clock clears were unpinned by the harness
  (deleting them left all ~110 assertions green — the reviewer's missed-regression scenario, a
  re-added root damped ~405 s by a dead root's clocks, becomes a named case with a
  delete-the-lines non-vacuity check); (3) vacuous optional-chaining nil-asserts hardened;
  (4) misleading assertion message and stale 25 s comment corrected; (5) teardown case extended
  to two tokens + a production-defaults dealloc case (the no-self-retain property was previously
  verified only by reading); (6) six doc corrections (stale `FileNode.swift:26` queue pointer,
  `TokenRegistry.deinit`'s false lock justification, I6 overstatement, "nine became one dict",
  the self-contradictory init comment, weak-scheduler-vs-weak-model precision).
- **Rejected:** converting the model seams to `weak` + guard (edge reviewer's optional
  hardening) — the trap-over-silence trade is already recorded above, and the reviewer himself
  could not construct a reachable instance (it needs an off-main final release of the model,
  which no holder today can produce).
- **No second full review round** after the fixes: the only control-flow change is the
  `applyScan` reorder, whose exact shape both reviewers prescribed; it is verified line-by-line
  by the orchestrator plus the full 110+-assertion harness re-run and the mutation-hardened I12
  cases. Everything else is harness/doc-only (non-material per the re-review rule).
