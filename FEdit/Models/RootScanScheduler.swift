//
//  RootScanScheduler.swift
//  FEdit
//
//  Copyright © 2026 Felix Matschke
//
//  This file is part of FEdit.
//
//  FEdit is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your
//  option) any later version.
//
//  FEdit is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FEdit. If not, see <https://www.gnu.org/licenses/>.
//

import Foundation

/// (root-scan-consolidation) One root's scan bookkeeping. Before this item these eight fields were
/// eight parallel `Set`/`Dictionary` members on `WorkspaceModel`, drained by hand at four call sites
/// with the invariants held in prose; folding them into a single value keyed by URL makes "drain a
/// root" one removal, and gives every future per-root scan attribute a home that cannot be forgotten
/// at one of those sites. (The ninth member, the per-root cancellation token, lives in
/// `TokenRegistry` instead — it is the only piece that must be reachable from a `deinit`.)
///
/// The `Optional` fields are load-bearing, not shorthand for zero. `lastFinish == nil` means "no walk
/// of this root has ever landed", and that is exactly what makes the first watcher-driven rescan
/// after an add — or a re-add — immediate instead of damped (see `RootScanScheduler.requestScan`,
/// gate 2); a `0` default would read as "landed at the epoch" and change that behavior.
struct RootScan {
    /// (async-root-scan) A walk of this root is in flight, and the per-root serialization gate: a
    /// root with this set never enqueues a second walk (the request is recorded in `rescanRequested`
    /// instead). Cleared **only** by the owning job's own landing — never by `noteRootRemoved` — so a
    /// remove-then-re-add cannot slip a second concurrent walk past the gate.
    var isScanning = false

    /// (async-root-scan) This root's scan was superseded (a refresh arrived while a walk was in
    /// flight) or damped (a watcher event arrived inside the rescan gap) — re-run **exactly once**
    /// when the walk lands or the gap expires. Mirrors `WorkspaceModel`'s
    /// `isRecomputing`/`recomputeAgain` git coalescing deliberately.
    var rescanRequested = false

    /// (async-root-scan) Carries the `force` bit of such a deferred request forward, so an explicit
    /// Refresh folded into a running walk still republishes unconditionally. **Consumed** when the
    /// re-run fires, so one forced Refresh can never make every later rescan forced.
    ///
    /// Invariant I14: `forcedRescan == true` implies `rescanRequested == true` at every quiescent
    /// point — the two bits are always set together and cleared together. Entry GC leans on it.
    var forcedRescan = false

    /// (async-root-scan) This root's scan generation, bumped by `noteRootAdded` and by
    /// `noteRootRemoved`. A job captures it at start and its landing discards the result if the
    /// generation moved — which is what closes the remove-then-re-add splice: remove `U` mid-walk,
    /// re-add `U` before the walk unwinds, and the stale (possibly partial, possibly cancelled) tree
    /// must not land under the fresh placeholder.
    var generation = 0

    /// (async-root-scan) When this root's last walk landed. A **monotonic** `DispatchTime`, not a
    /// wall-clock `Date`, deliberately: the trailing-edge timer is scheduled against the monotonic
    /// clock, and a backwards wall-clock step (an NTP correction, a manual clock change) would
    /// otherwise stall every damped rescan for the size of the step — the gap would read as un-served
    /// until the wall clock caught back up. `nil` until the first landing (see the type's note).
    var lastFinish: DispatchTime?

    /// (async-root-scan) How long that walk took, measured the same monotonic way around the
    /// `FileNode.scanRecordingSkips` call on `scanQueue`. Feeds the proportional damping term.
    var lastDuration: TimeInterval?

    /// (async-root-scan) The gap a watcher-driven rescan of this root must currently wait out —
    /// doubled on every structurally-unchanged landing, reset to the floor by a real change or an
    /// explicit Refresh. `nil` means "never left the floor" (`minRescanGap`).
    var backoff: TimeInterval?

    /// (async-root-scan) The single armed trailing-edge re-entry for this root — a damped event is
    /// *deferred*, never dropped, so the tree is eventually right. At most one is armed at a time; a
    /// burst inside the gap coalesces into the pending one.
    var pendingDampedRescan: DispatchWorkItem?

    /// (watcher-scan-skip-parity) What this root's last **applied** walk decided to leave out of the
    /// tree — the FSEvents gate's only source of truth about non-name-decidable skips (`UF_HIDDEN`
    /// entries and the like; the record's `unreadableDirs` half is carried but deliberately not
    /// consulted by the gate, see `SkipRecord`). Written by `applyScan` on the applied branch,
    /// drained by `noteRootRemoved`, collected with the entry.
    ///
    /// `Optional` per this type's rule, and load-bearing rather than shorthand for "empty": `nil`
    /// means **no walk has ever delivered verdicts for this root**, which is not the same claim as
    /// "the walk found nothing to skip". The gate must fall back to its static rules alone in the
    /// first case; in the second it may rely on the record's silence.
    var skipRecord: SkipRecord?
}

/// (watcher-scan-skip-parity) What a finished walk hands back. Was three loose arguments
/// `(FileNode, Bool, TimeInterval)` before the skip record needed a fourth; grouping them keeps the
/// `WalkCompletion`/`applyScan` seams from growing a positional-argument hazard, and makes the fake
/// launcher in `scripts/RootScanTests` name what it is delivering.
struct WalkResult: Sendable {
    /// The scanned tree. A cancelled walk's is **partial** — the generation check discards it.
    let node: FileNode

    /// The verdicts that produced `node`, and partial in exactly the same cases: discarded with it.
    let skipRecord: SkipRecord

    /// Whether `node` differs structurally from the diff baseline captured at walk start. Computed
    /// off-main inside the launcher, with the walk.
    let changed: Bool

    /// The walk's own measured cost, in seconds. Feeds the proportional damping term.
    let duration: TimeInterval
}

/// (root-scan-consolidation) The in-flight walks' cancellation tokens, and the **only** part of the
/// scan machinery that is reachable from a `deinit`. Nonisolated and lock-guarded rather than
/// main-actor state, for one concrete reason: its own `deinit` cancels every token it still holds, so
/// when a window's model — and with it the scheduler that owns this registry — deallocates, in-flight
/// home-scale walks stop within one directory entry with **no isolated-state access from a `deinit`**
/// at all. That is what let `WorkspaceModel.deinit` be deleted outright (root-scan-consolidation).
///
/// One token per root, in exactly one place: `RootScan` deliberately does not duplicate them.
private final class TokenRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [URL: ScanCancellationToken] = [:]

    deinit {
        // `deinit` runs only once the last reference is gone, so this body has exclusive access to
        // `tokens` by definition: the lock below and the `Array` materialization are defensive
        // hygiene (one access discipline for every method on this type), not load-bearing. In
        // particular they are *not* what makes the cancellation visible to a scan-queue thread —
        // `cancel()` runs outside the lock, and cross-thread visibility of the cancelled flag is
        // `ScanCancellationToken`'s own lock's job.
        lock.lock()
        let remaining = Array(tokens.values)
        tokens = [:]
        lock.unlock()
        for token in remaining {
            token.cancel()
        }
    }

    /// Records the token of a walk that is about to start, replacing any previous entry (there can be
    /// none: the in-flight gate admits one walk per root).
    func store(_ token: ScanCancellationToken, for url: URL) {
        lock.lock()
        tokens[url] = token
        lock.unlock()
    }

    /// Cancels and drops `url`'s token, if any — the drain path (`noteRootRemoved`). A cancelled
    /// walk's partial tree is discarded by the generation check, so cancellation never has to produce
    /// a usable tree.
    func cancelAndRemove(_ url: URL) {
        lock.lock()
        let token = tokens.removeValue(forKey: url)
        lock.unlock()
        token?.cancel()
    }

    /// Clears `url`'s token **only if it is still `token`** — identity-compared, so a landing job can
    /// only ever clear its own token and never a successor's.
    func clear(url: URL, ifIdentical token: ScanCancellationToken) {
        lock.lock()
        if tokens[url] === token {
            tokens[url] = nil
        }
        lock.unlock()
    }
}

/// (root-scan-consolidation) The per-window scan subsystem: it owns the per-root scan state
/// (`[URL: RootScan]`), the walk cancellation tokens, the coalescing gates, the generation discard,
/// and the damping arithmetic. `WorkspaceModel` keeps only the sidebar-visible half of a scan (the
/// `roots` splice and the "Scanning…" set), reached through the two model seams below.
///
/// **No-self-retain invariant.** The scheduler holds no strong reference to itself: the injected
/// closures are stored properties, so the defaults must not capture it — `launchWalk`'s default is a
/// `static` function and `armTimer`/`now`'s defaults are free closures. `currentNode`/`land` capture
/// the *model* `[unowned self]`, which is outside this object's ownership graph (the model owns the
/// scheduler, never the other way round). This is what makes teardown a reachability argument: when
/// the window's model goes, the scheduler goes, and `TokenRegistry.deinit` stops the walks.
///
/// **Recorded trap:** because `currentNode`/`land` hold the model unowned, **no teardown path may
/// call them.** They are only ever called from `requestScan`/`applyScan`, which run while the model
/// is alive by construction (the landing closure holds the scheduler weakly, and the scheduler cannot
/// outlive the model). `weak` + a guard was considered and rejected: it would silently no-op a
/// landing during teardown, hiding real bugs instead of trapping on them.
@MainActor
final class RootScanScheduler {
    /// The model's `roots` lookup — the current node for a root URL, or `nil` when no such root is in
    /// the sidebar. Captures the model **unowned**: see the type's trap note.
    typealias NodeLookup = @MainActor (URL) -> FileNode?

    /// The model-side landing: splice `scanned` into `roots` when `force || changed`, and clear the
    /// root's "Scanning…" affordance. Returns `false` when the root is no longer in `roots` — the
    /// scheduler then records no damping state for it (I8). Captures the model **unowned**.
    typealias Landing = @MainActor (_ url: URL, _ scanned: FileNode, _ changed: Bool, _ force: Bool) -> Bool

    /// What a finished walk hands back on the main actor. `@Sendable` is required, not decorative: the
    /// default launcher carries this closure into `scanQueue.async`'s `@Sendable` body, and a bare
    /// `@MainActor` function type is not implicitly `Sendable`.
    typealias WalkCompletion = @Sendable @MainActor (_ result: WalkResult) -> Void

    /// The walk executor: run `FileNode.scanRecordingSkips(directory:cancellation:)` off the main
    /// actor against `old` as the diff baseline, then deliver the `WalkResult` back on the main actor.
    typealias WalkLauncher = @MainActor (_ url: URL, _ old: FileNode?, _ token: ScanCancellationToken, _ completion: @escaping WalkCompletion) -> Void

    /// The trailing-edge timer: run `workItem` on the main actor after `delay` seconds.
    typealias TimerArming = @MainActor (_ delay: TimeInterval, _ workItem: DispatchWorkItem) -> Void

    /// The monotonic clock. Injected so the damping arithmetic is reachable from
    /// `scripts/RootScanTests` — without it the whole gate-2 branch is untestable.
    ///
    /// Exactly two consumers, both on the main actor and both halves of the *same* measurement: the
    /// landing's `lastFinish` mark and gate 2's elapsed-gap test. They must read one clock or a
    /// settable test clock would be differenced against real uptime. The walk's own duration is not
    /// one of them — it is measured off-main inside the launcher against the real clock, exactly as
    /// before this item, and the fake launcher supplies it directly.
    typealias Clock = @MainActor () -> DispatchTime

    /// (async-root-scan) The **only** place the blocking recursive directory walk runs — the whole
    /// point of that item: no user action can freeze the window on a home-scale root any more.
    ///
    /// `static` (shared app-wide, not per-window) and **concurrent**, not serial: per-root
    /// serialization is `RootScan.isScanning`' job, not the queue's, and a serial queue would park a
    /// small root's walk — and `createFile`'s "the new row appears" refresh (SPEC §5.2) — behind a
    /// multi-minute `$HOME` walk. Deliberately **not** the Swift cooperative pool, for the same
    /// reason `WorkspaceModel.gitQueue` isn't (see `GitStatus`): `contentsOfDirectory` is a blocking
    /// syscall and must not park a cooperative worker for minutes. Width is bounded by the live root
    /// count across all windows (a handful in practice) and GCD's own pool; no explicit cap is
    /// imposed — revisit only if a real session shows contention. `nonisolated` because the default
    /// walk launcher below is (it reads this from off the main actor's isolation domain);
    /// `DispatchQueue` is `Sendable`, so the shared constant is safe to reach from anywhere.
    private nonisolated static let scanQueue = DispatchQueue(label: "com.fedit.tree-scan", qos: .userInitiated, attributes: .concurrent)

    /// (async-root-scan) Damping bounds for **watcher-driven** rescans of one root: the minimum gap
    /// between the end of one walk and the start of the next. The required gap is the **larger** of
    /// two terms:
    /// - an exponential component that doubles from `minRescanGap` to `maxRescanGap` for each
    ///   consecutive rescan that comes back structurally unchanged (reset by a real structural
    ///   change or an explicit Refresh), and
    /// - `rescanDurationFactor × RootScan.lastDuration` — the previous walk's own measured cost —
    ///   applied **only once the backoff has left its floor**, i.e. only after a rescan has come
    ///   back unchanged, which is the evidence of a no-op drip. A lone genuine change on a quiet
    ///   root therefore reflects after at most the 1 s floor, never after 3× a home-scale walk.
    ///
    /// The second term is what makes the damping *proportional* rather than absolute: a fixed 1–30 s
    /// gap against a 135 s home-scale walk still leaves a sustained drip running the walk ~82 % of
    /// the time. Requiring a gap of at least 3× the last walk's duration caps a no-change drip's duty
    /// cycle at ~1/4 of one core (per dripping root, per window) no matter how big the root is, while
    /// a root whose walk is cheap (under `minRescanGap`/3 ≈ 333 ms) is governed by the 1 s floor
    /// exactly as before.
    ///
    /// This is what bounds a sustained event drip that can never surface anything, now that the walk
    /// no longer blocks the main thread. Its motivating case — `~/Library/**` under a `$HOME` root,
    /// whose events passed the watcher's dot-prefix gate while the scanner skipped the `UF_HIDDEN`
    /// directory outright — is since (watcher-scan-skip-parity) stopped one layer earlier, by
    /// `TreeSkipGate` consulting `RootScan.skipRecord`, so those events no longer *request* a rescan
    /// at all. Damping remains the bound on every drip the gate legitimately lets through; it is
    /// **not** a safety net for gate drops, which it structurally cannot be (it defers requests, it
    /// cannot manufacture one the gate never made).
    static let minRescanGap: TimeInterval = 1
    static let maxRescanGap: TimeInterval = 30
    static let rescanDurationFactor: Double = 3

    /// The per-root scan state, the whole point of (root-scan-consolidation). Readable from outside
    /// for tests and future per-root attributes; mutated only in this file.
    private(set) var scans: [URL: RootScan] = [:]

    /// The in-flight walks' tokens. Nonisolated on purpose — see `TokenRegistry`.
    private let tokens = TokenRegistry()

    private let currentNode: NodeLookup
    private let land: Landing
    private let launchWalk: WalkLauncher
    private let armTimer: TimerArming
    private let now: Clock

    init(
        currentNode: @escaping NodeLookup,
        land: @escaping Landing,
        launchWalk: @escaping WalkLauncher = RootScanScheduler.launchWalkOnScanQueue,
        armTimer: @escaping TimerArming = { delay, workItem in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        },
        now: @escaping Clock = { DispatchTime.now() }
    ) {
        self.currentNode = currentNode
        self.land = land
        self.launchWalk = launchWalk
        self.armTimer = armTimer
        self.now = now
    }

    // MARK: - Root lifecycle

    /// (async-root-scan) A root is being added: bump its generation so a walk of the *previous*
    /// incarnation that is still unwinding discards its stale tree instead of splicing it in under
    /// the fresh placeholder.
    ///
    /// **Call-ordering contract (I15): call this _before_ appending the placeholder to `roots`.** It
    /// deliberately does not consult `currentNode` — during an add that lookup still reads `nil`.
    func noteRootAdded(_ url: URL) {
        var scan = scans[url] ?? RootScan()
        scan.generation += 1
        scans[url] = scan
    }

    /// (async-root-scan) A root is being removed: drain everything that would otherwise linger or
    /// fire against a root that is gone — a permanently-set `rescanRequested` bit, an armed
    /// trailing-edge timer, a stale damping clock — and stop the walk itself.
    ///
    /// The generation bump is what invalidates an in-flight walk. `isScanning` is the one bit that is
    /// **not** cleared here: it is the gate that keeps a re-add from starting a second concurrent
    /// walk of the same root, so it (and the entry carrying the bumped generation) survives until the
    /// walk's own landing. Today the bump is redundant with `noteRootAdded`'s — `roots` re-entry only
    /// happens through `addFolders`, which bumps — but it is the stated guarantee (I7) that a removal
    /// alone invalidates every job captured before it, and later items may lean on it.
    ///
    /// **Call-ordering contract (I15): call this _after_ removing the root from `roots`.** The entry
    /// GC below consults `currentNode`, and calling this early would see the root as still present
    /// and never collect.
    func noteRootRemoved(_ url: URL) {
        var scan = scans[url] ?? RootScan()
        scan.generation += 1
        scan.rescanRequested = false
        scan.forcedRescan = false
        scan.lastFinish = nil
        scan.lastDuration = nil
        scan.backoff = nil
        scan.pendingDampedRescan?.cancel()
        scan.pendingDampedRescan = nil
        // (watcher-scan-skip-parity) Drained with the rest: a removed root's verdicts describe a tree
        // that is no longer shown, and a re-add must not have its first gate decisions made against
        // them. `nil` is the honest state — "no walk has delivered verdicts for this root".
        scan.skipRecord = nil
        scans[url] = scan
        tokens.cancelAndRemove(url)
        collectEntryIfIdle(url)
    }

    // MARK: - Scanning

    /// (async-root-scan) The single entry point for scanning a root; the app target's **only**
    /// `FileNode.scanRecordingSkips` call site is the walk launcher this drives. Returns immediately: the walk runs
    /// on `scanQueue`, and `applyScan` hands its result to the model's landing seam on the main actor
    /// when it comes back.
    ///
    /// - `force`: bypass the diff-guard so the result always republishes (explicit user Refresh),
    ///   and reset this root's damping backoff when it lands.
    /// - `damped`: subject this request to the per-root minimum rescan gap. Watcher-driven rescans
    ///   pass `true`; the initial scan from `addFolders`, an explicit Refresh, and the trailing-edge
    ///   re-entry (which has already served the gap) pass `false`.
    ///
    /// Two coalescing gates, in order — both record the request in `rescanRequested` rather than
    /// dropping it, so a superseded or damped event is always *deferred*, never lost:
    /// 1. a walk already in flight for `url` ⇒ record and return, so this window runs at most one
    ///    walk per root at any moment (this, not queue serialism, is what serializes a root; the
    ///    gate is per-scheduler, i.e. per-window, so two windows on the same root do walk it twice);
    /// 2. a damped request still inside the gap ⇒ record, arm the one trailing-edge re-entry, return.
    ///
    /// Past both gates the deferred request is **consumed** rather than left standing: the walk that
    /// is about to start reads the disk now, so it already delivers everything that request asked
    /// for (its `force` bit is folded in, its armed timer cancelled).
    func requestScan(of url: URL, force: Bool = false, damped: Bool = false) {
        var scan = scans[url] ?? RootScan()

        if scan.isScanning {
            scan.rescanRequested = true
            if force { scan.forcedRescan = true }
            scans[url] = scan
            return
        }

        // Gate 2. `damped` implies `!force` by construction — every call site passes `damped` as
        // `!force` or as a literal `false` — so a damped request never carries a force bit to
        // preserve here, and an explicit user Refresh is never delayed by this gate. A root with no
        // recorded `lastFinish` is never damped (I13): the binding below fails, which is what makes
        // the first watcher rescan after an add or re-add immediate.
        if damped, let finished = scan.lastFinish {
            // The required gap is the exponential backoff — and, once the previous rescan came back
            // structurally unchanged (`backoff > minRescanGap`, the evidence of a no-op drip), at
            // least 3× the previous walk's own cost, so the drip's duty cycle stays bounded on a
            // root of any size (see `minRescanGap`). The proportional term deliberately does NOT
            // apply while `backoff == minRescanGap` (the last walk found a real change): a lone
            // genuine change on a quiet root must reflect promptly, not wait out 3× a home-scale
            // walk. Monotonic throughout: a wall-clock step cannot lengthen or shorten the gap.
            let backoff = scan.backoff ?? Self.minRescanGap
            let proportional = backoff > Self.minRescanGap
                ? Self.rescanDurationFactor * (scan.lastDuration ?? 0)
                : 0
            let remaining = max(backoff, proportional) - Self.secondsElapsed(from: finished, to: now())
            if remaining > 0 {
                scan.rescanRequested = true
                scans[url] = scan
                scheduleDampedRescan(of: url, after: remaining)
                return
            }
        }

        // Both gates passed, so a walk starts *now* and will read the current state of the disk —
        // which is exactly what any request deferred earlier for this root was asking for. Consume
        // that deferred request here (folding its force bit into this walk) and disarm its timer:
        // otherwise a Refresh arriving during a damped gap would cost a second, redundant full walk
        // when the stale timer fires, and a timer armed against an old 30 s deadline would outlive
        // the backoff reset this walk is about to perform.
        scan.rescanRequested = false
        let effectiveForce = force || scan.forcedRescan
        scan.forcedRescan = false
        scan.pendingDampedRescan?.cancel()
        scan.pendingDampedRescan = nil

        scan.isScanning = true
        let generation = scan.generation
        scans[url] = scan

        let token = ScanCancellationToken()
        tokens.store(token, for: url)
        // Captured here and carried into the job rather than re-read on the way out: a root's
        // children can only change through a landing, and gate (1) above guarantees at most one walk
        // per root, so this *is* the value the landing would have read — and comparing against it
        // moves the deep `Equatable` walk off-main with the scan. (Before (async-root-scan) that
        // compare was itself an O(N) main-thread cost on every watcher event.)
        let old = currentNode(url)
        launchWalk(url, old, token) { [weak self] result in
            // `[weak self]`: a closed window's scheduler is neither kept alive nor written.
            self?.applyScan(
                result,
                of: url,
                generation: generation,
                token: token,
                force: effectiveForce
            )
        }
    }

    /// (async-root-scan) The main-actor landing point for a finished walk. Runs for **every** job,
    /// including ones whose result is thrown away, because the job-local teardown (clearing the
    /// in-flight gate and this job's token) has to happen either way or the root would never be
    /// scanned again.
    ///
    /// The result is discarded when the root's generation moved (`noteRootRemoved`, or a
    /// remove-then-re-add that raced the walk — the tree may also be a cancelled walk's partial one)
    /// or when `land` reports the root is simply no longer in `roots`.
    ///
    /// **I12 — the machine's most counterintuitive rule.** The pending-request drain and its re-fire
    /// run **unconditionally**, outside that branch: a superseded job's coalesced request is precisely
    /// the re-added root's own scan, and gating the re-fire on "landed successfully" would leave a
    /// re-added root's placeholder showing "Scanning…" forever.
    ///
    /// **Ordering around the `land` callout.** The job-local teardown is published to `scans` *before*
    /// `land` is called, and the entry is re-read *after* it: `land` is a call out of this object, so
    /// nothing here may hold a stale copy of the entry across it (see the comments inline).
    private func applyScan(
        _ result: WalkResult,
        of url: URL,
        generation: Int,
        token: ScanCancellationToken,
        force: Bool
    ) {
        // Clear the in-flight gate and publish it **before** the `land` callout below — deliberate,
        // for re-entrancy: `land` leaves this object, and anything it does that comes back in here
        // (a `requestScan` for this root, say) must see the gate down and must not have its own
        // mutation overwritten by a write-back of a copy taken before the call.
        var scan = scans[url] ?? RootScan()
        scan.isScanning = false
        scans[url] = scan
        tokens.clear(url: url, ifIdentical: token)

        // `&&` short-circuits, so a job whose generation moved never reaches the model seam.
        let applied = scan.generation == generation && land(url, result.node, result.changed, force)

        // Re-read across the callout, for the same reason the write above happens early: the entry
        // in `scans` — not this local — is the truth once `land` has run.
        scan = scans[url] ?? RootScan()
        if applied {
            // Damping clock, walk cost, and backoff: a rescan that came back structurally unchanged
            // doubles the gap the next watcher-driven one must wait out, up to `maxRescanGap`; a real
            // structural change — or an explicit user Refresh — resets it to `minRescanGap`. The
            // recorded duration additionally holds the next gap to >= 3× this walk's cost. Recorded
            // only on this branch (I8): a discarded landing must not restart a removed root's clock.
            //
            // (watcher-scan-skip-parity) The skip record is stored on this same branch, and on **all**
            // of it — including a structurally-unchanged landing, which publishes nothing but whose
            // verdicts are nonetheless the freshest ones there are. That is safe precisely because
            // `scans` is not `@Published` and this scheduler is not an `ObservableObject`, so the
            // store cannot re-render the sidebar. A discarded landing (generation moved, or the root
            // is gone from `roots`) stores nothing: `&&` short-circuited above, and its record may be
            // a cancelled walk's partial one.
            scan.skipRecord = result.skipRecord
            scan.lastFinish = now()
            scan.lastDuration = result.duration
            scan.backoff = (force || result.changed)
                ? Self.minRescanGap
                : min((scan.backoff ?? Self.minRescanGap) * 2, Self.maxRescanGap)
        }

        // I12: unconditional drain of the coalesced request, generation-current or not.
        let hadPendingRequest = scan.rescanRequested
        let forced = scan.forcedRescan
        scan.rescanRequested = false
        scan.forcedRescan = false
        scans[url] = scan

        if hadPendingRequest {
            requestScan(of: url, force: forced, damped: !forced)
        }
        // Entry GC: after the drain, an entry for a root that is gone and has nothing outstanding
        // carries no information anyone can read. A re-fire above always leaves something
        // outstanding (a walk in flight, or a recorded request plus its armed timer), so this is a
        // no-op on that path.
        collectEntryIfIdle(url)
    }

    /// (async-root-scan) Arms the single trailing-edge re-entry for a damped root: the watcher event
    /// that arrived inside the rescan gap fires `delay` seconds later instead of being dropped, so
    /// the tree is eventually right. Exactly one work item per root is armed at a time — a burst
    /// inside the gap coalesces into the pending one — and `noteRootRemoved` (plus the walk-start
    /// consume in `requestScan`) cancels it. A cancelled item never runs its body, which is what
    /// keeps a superseded timer from clearing a successor's armed slot.
    ///
    /// Called only from gate 2, which has just written `scans[url]`.
    private func scheduleDampedRescan(of url: URL, after delay: TimeInterval) {
        var scan = scans[url] ?? RootScan()
        guard scan.pendingDampedRescan == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            // Dispatched to `DispatchQueue.main` by the default `armTimer`, so this body runs on the
            // main actor; `assumeIsolated` states that to the compiler (the same idiom as
            // `WorkspaceModel.scheduleAutosave`).
            MainActor.assumeIsolated {
                guard let self, var scan = self.scans[url] else { return }
                // I6: clear the armed entry **before** testing the pending request, so no path out
                // of this body can leave the slot pointing at an item that has already run. Today
                // that is belt-and-braces rather than load-bearing: every other consumer of the slot
                // either cancels the item (whose `perform()` is then a no-op) or clears the slot in
                // the same breath as the request bit, so the "already-consumed request, slot still
                // armed" state is not reachable. The ordering is here so a future consumer that
                // clears the request bit without touching the slot cannot strand a permanent phantom.
                scan.pendingDampedRescan = nil
                // This *is* the deferred request; if something already consumed it (an intervening
                // walk's landing did), there is nothing left to fire.
                let hadPendingRequest = scan.rescanRequested
                let forced = scan.forcedRescan
                scan.rescanRequested = false
                scan.forcedRescan = false
                self.scans[url] = scan
                guard hadPendingRequest else { return }
                // `damped: false`: the gap has been served. Re-checking it here would let a fencepost
                // between the timer's deadline and the clock read in gate 2 re-defer the same
                // request in a tight loop.
                self.requestScan(of: url, force: forced, damped: false)
            }
        }

        scan.pendingDampedRescan = workItem
        scans[url] = scan
        armTimer(delay, workItem)
    }

    /// (root-scan-consolidation) Drops a root's entry once it holds nothing anyone can read: the root
    /// is gone from `roots`, no walk is in flight, no request is recorded, and no timer is armed.
    /// `forcedRescan` needs no conjunct — I14 makes it vacuous.
    ///
    /// This **reverses** (async-root-scan)'s deliberate "scanGeneration is never pruned" residual.
    /// The old reasoning — resetting a generation to zero could let a re-add's bump land right back
    /// on a stale job's captured value — is still honored, because these conjuncts admit no live job:
    /// a job exists only while `isScanning` (the in-flight gate guarantees it), so under this
    /// condition no in-flight job can hold a stale generation for this URL, and a later re-add
    /// starting from generation 0 is safe. What flipped the trade is that the entry now retains
    /// damping clocks and a work-item slot per removed root, not one `Int`.
    ///
    /// A **present** root's entry is never collected: that would wipe its damping clocks and, through
    /// I13's no-clock rule, silently un-damp it.
    private func collectEntryIfIdle(_ url: URL) {
        guard let scan = scans[url],
              currentNode(url) == nil,
              !scan.isScanning,
              !scan.rescanRequested,
              scan.pendingDampedRescan == nil else { return }
        scans[url] = nil
    }

    // MARK: - Default walk executor

    /// (async-root-scan) The production `launchWalk`: hop to `scanQueue`, walk, hop back to the main
    /// actor with the tree, the structural diff, and the walk's own cost.
    ///
    /// `static` deliberately — a default that captured `self` would put the scheduler in its own
    /// stored property and defeat the no-self-retain invariant. `nonisolated` because everything it
    /// touches is either a local or nonisolated (`FileNode.scanRecordingSkips`, `secondsElapsed`), and it must be
    /// convertible to the main-actor-isolated `WalkLauncher` seam without dragging isolation into the
    /// queue closure.
    ///
    /// (root-scan-consolidation) This is the same hop the `Task` + `withCheckedContinuation` bridge
    /// performed before, written directly: `queue.async` out, `DispatchQueue.main.async` back,
    /// `MainActor.assumeIsolated` to enter the completion — one concurrency vocabulary fewer for the
    /// same delivery point. The token is captured strongly (the walk needs it), the completion holds
    /// the scheduler weakly. Known, accepted difference: the `scanQueue` enqueue now happens
    /// synchronously inside the caller rather than after an unstructured-`Task` main-actor hop; no
    /// consumer observes enqueue timing.
    private nonisolated static func launchWalkOnScanQueue(
        url: URL,
        old: FileNode?,
        token: ScanCancellationToken,
        completion: @escaping WalkCompletion
    ) {
        let queue = scanQueue
        queue.async {
            // Timed around the walk itself, not around the hop: the damping gap is a multiple of
            // what this root actually costs to walk (see `minRescanGap`), and the diff below is
            // deliberately excluded — it is cheap next to the syscalls and including it would
            // inflate the gap on the *changed* path, which resets.
            let started = DispatchTime.now()
            // (watcher-scan-skip-parity) The app target's single walk call: the recording entry point,
            // so every landing carries the verdicts the FSEvents gate consults. The record is
            // produced by the walk itself and carried through unchanged — never re-derived on the
            // main actor, which would cost the syscalls this whole design exists to avoid.
            let outcome = FileNode.scanRecordingSkips(directory: url, cancellation: token)
            let duration = secondsElapsed(from: started, to: DispatchTime.now())
            // `old` is `FileNode?`; a nil `old` (no such root at job start — not reachable today,
            // since every caller appends the root first) reads as "changed".
            let changed = outcome.node != old
            let result = WalkResult(
                node: outcome.node,
                skipRecord: outcome.skipRecord,
                changed: changed,
                duration: duration
            )
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion(result) }
            }
        }
    }

    /// (async-root-scan) Seconds between two monotonic marks, clamped to `>= 0`. `DispatchTime`
    /// cannot run backwards, so the clamp only guards the degenerate equal/rounding case (and makes
    /// the `UInt64` subtraction underflow-proof). `nonisolated` because the walk measures itself
    /// off-main with it; the damping gap test on the main actor uses the same helper against the
    /// injected clock.
    private nonisolated static func secondsElapsed(from start: DispatchTime, to end: DispatchTime) -> TimeInterval {
        guard end.uptimeNanoseconds > start.uptimeNanoseconds else { return 0 }
        return TimeInterval(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }
}
