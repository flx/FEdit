//
//  main.swift
//  RootScanTests
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
//  Standalone assertion harness for `RootScanScheduler` — the per-root scan state machine
//  (root-scan-consolidation): coalescing gates, force-bit folding, damping arithmetic, generation
//  discard, entry GC, subsystem teardown, (watcher-scan-skip-parity) the per-root skip record's
//  plumbing, and (tree-node-budget) the per-root budget report's — including what the model-side
//  landing seam is handed and when. Not part of the app target — compiled and run manually:
//
//      swiftc FEdit/Models/FileNode.swift FEdit/Models/RootScanScheduler.swift \
//          scripts/RootScanTests/main.swift -o /tmp/rstests && /tmp/rstests
//
//  Named `main.swift` because Swift only allows top-level statements in a file with that exact
//  name when compiling multiple files together.
//
//  The whole machine is driven through the scheduler's injection seams, so this harness never
//  touches the filesystem, never spawns a thread, and never waits on a clock: the walk executor,
//  the trailing-edge timer, and the monotonic clock are all fakes, and every scenario runs to
//  completion synchronously inside one `MainActor.assumeIsolated` block (top-level code in
//  `main.swift` runs on the main thread, which is what makes that assumption sound).
//

import Foundation

// MARK: - Tiny test harness

var failureCount = 0

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("  PASS: \(message)")
    } else {
        failureCount += 1
        print("  FAIL: \(message) (\(file):\(line))")
    }
}

func section(_ title: String) {
    print("\n== \(title) ==")
}

// MARK: - Fakes

/// One walk the scheduler asked the (fake) executor to run. Kept in an append-only log so a
/// scenario can assert *how many* walks were launched, land them out of order, and inspect the
/// cancellation token the scheduler minted for each.
@MainActor
struct PendingWalk {
    let url: URL
    let old: FileNode?
    let token: ScanCancellationToken
    let completion: RootScanScheduler.WalkCompletion
}

/// One armed trailing-edge timer, captured instead of dispatched. `item.perform()` fires it; a
/// cancelled item's `perform()` is a documented no-op, which is what the scheduler leans on so a
/// superseded timer can never clear a successor's armed slot.
@MainActor
struct ArmedTimer {
    let delay: TimeInterval
    let item: DispatchWorkItem
}

/// What the model-side landing seam was asked to do.
@MainActor
struct LandingRecord {
    let url: URL
    let node: FileNode
    let changed: Bool
    let force: Bool
    /// (tree-node-budget) The budget report the seam was handed — recorded so a scenario can assert
    /// it arrived **verbatim**, on every landing and not only on the ones that splice.
    let report: TreeBudgetReport
    let applied: Bool
}

/// The fake `WorkspaceModel` half of the wiring: the published `roots`/`initialScanRootURLs` state
/// the scheduler splices into, plus the captured walks, timers and clock. Deliberately holds **no**
/// reference to the scheduler — the teardown scenarios need the scheduler to be the only strong
/// reference to itself.
@MainActor
final class Fakes {
    var roots: [FileNode] = []
    var initialScanRootURLs: Set<URL> = []
    /// Counts `initialScanRootURLs` removals that actually fired, so the membership guard (I10 — no
    /// spurious publish on a damped no-op landing) is observable.
    var initialScanRemovals = 0

    /// (tree-node-budget) The fake's copy of `WorkspaceModel.truncatedRootURLs` — the `@Published`
    /// set that drives the sidebar's per-root truncation notice — maintained by the `land` closure
    /// below with the **same membership guard** the model uses.
    var truncatedRootURLs: Set<URL> = []
    /// Mutations of that set that actually fired. A landing that leaves the flag where it already
    /// was must not touch it: on the model this set is `@Published`, so an unguarded write would
    /// re-render the whole sidebar on every damped no-op walk. Counting is what makes the guard
    /// observable rather than merely present.
    var truncatedPublishes = 0

    var walks: [PendingWalk] = []
    var timers: [ArmedTimer] = []
    var landings: [LandingRecord] = []

    /// A settable monotonic clock, started well away from zero so a scenario can never subtract
    /// below the epoch. Advanced by whole/fractional seconds via `advance(_:)`.
    var clock = DispatchTime(uptimeNanoseconds: 1_000_000_000_000)

    func advance(_ seconds: TimeInterval) {
        clock = DispatchTime(uptimeNanoseconds: clock.uptimeNanoseconds + UInt64(seconds * 1_000_000_000))
    }

    /// Mirrors `WorkspaceModel.addFolders`' ordering contract (I15): the generation bump happens
    /// **before** the placeholder is appended, so the scheduler's own `currentNode` reads `nil`
    /// during the bump.
    func addRoot(_ url: URL, to scheduler: RootScanScheduler) {
        scheduler.noteRootAdded(url)
        roots.append(placeholder(url))
        initialScanRootURLs.insert(url)
    }

    /// Mirrors `WorkspaceModel.removeRoot`' ordering contract (I15): the root leaves `roots`
    /// **before** the scheduler is told, so the entry GC's `currentNode` check sees it gone.
    func removeRoot(_ url: URL, from scheduler: RootScanScheduler) {
        roots.removeAll { $0.url == url }
        scheduler.noteRootRemoved(url)
        initialScanRootURLs.remove(url)
        // (tree-node-budget) Drained with its siblings, exactly as `WorkspaceModel.removeRoot` does:
        // a removed root owes no notice, and a re-add must not inherit the old incarnation's flag.
        truncatedRootURLs.remove(url)
    }

    var walkCount: Int { walks.count }
    var timerCount: Int { timers.count }
    var lastWalk: PendingWalk { walks[walks.count - 1] }
    var lastTimer: ArmedTimer { timers[timers.count - 1] }
}

/// An empty directory node — what `addFolders` appends synchronously before the first walk lands.
@MainActor
func placeholder(_ url: URL) -> FileNode {
    FileNode(url: url, name: url.lastPathComponent, isDirectory: true, children: [])
}

/// A scanned tree distinguishable by `marker`, so a scenario can tell *which* walk's result landed.
@MainActor
func tree(_ url: URL, _ marker: String) -> FileNode {
    FileNode(
        url: url,
        name: url.lastPathComponent,
        isDirectory: true,
        children: [FileNode(url: url.appendingPathComponent(marker), name: marker, isDirectory: false, children: nil)]
    )
}

/// The marker of a node built by `tree(_:_:)`, or `nil` for a placeholder.
@MainActor
func marker(of node: FileNode?) -> String? {
    node?.children?.first?.name
}

/// (tree-node-budget) A walk that fitted inside its budget: the default for every scenario that
/// predates the budget. Declared before its use as a default argument — top-level bindings in
/// `main.swift` initialize in source order.
let untruncated = TreeBudgetReport(nodeCount: 0, truncated: false)

/// (tree-node-budget) A report distinguishable by its node count, so a scenario can tell *which*
/// walk's report was stored or delivered — the budget analogue of `tree(_:_:)`/`skipRecord(_:)`.
func budgetReport(_ nodeCount: Int, truncated: Bool = true) -> TreeBudgetReport {
    TreeBudgetReport(nodeCount: nodeCount, truncated: truncated)
}

/// (watcher-scan-skip-parity) One walk's hand-back, the way the production launcher builds it. The
/// default `record` is the empty one — "the walk skipped nothing" — which is what every scenario that
/// predates the skip record wants; the record-specific scenarios pass `skipRecord(_:)` values whose
/// contents identify *which* walk they came from.
///
/// (tree-node-budget) `report` defaults to `untruncated`, the shape of every walk that fitted inside
/// its budget; the budget scenarios pass their own. Its `nodeCount` is deliberately not derived from
/// `node` — the scheduler carries the walk's own measurement and never recounts a tree, and a fake
/// that recounted would hide it if the scheduler started to.
@MainActor
func walk(
    _ node: FileNode,
    _ changed: Bool,
    _ duration: TimeInterval,
    record: SkipRecord = SkipRecord(),
    report: TreeBudgetReport = untruncated
) -> WalkResult {
    WalkResult(node: node, skipRecord: record, changed: changed, duration: duration, budgetReport: report)
}

/// A skip record distinguishable by `marker`, so a scenario can tell *which* walk's verdicts were
/// stored — the record analogue of `tree(_:_:)`.
@MainActor
func skipRecord(_ marker: String) -> SkipRecord {
    SkipRecord(skippedIndex: ["": [marker]], unreadableDirs: ["denied-\(marker)"])
}

/// Wires a scheduler to `fakes` exactly the way `WorkspaceModel` wires the real one — the same two
/// model seams, with the walk executor, timer and clock replaced by capture-only fakes. `fakes` is
/// captured strongly (it does not own the scheduler, so no cycle is possible).
@MainActor
func makeScheduler(_ fakes: Fakes) -> RootScanScheduler {
    RootScanScheduler(
        currentNode: { url in fakes.roots.first { $0.url == url } },
        land: { url, scanned, changed, force, report in
            guard let index = fakes.roots.firstIndex(where: { $0.url == url }) else {
                fakes.landings.append(LandingRecord(url: url, node: scanned, changed: changed, force: force, report: report, applied: false))
                return false
            }
            if force || changed {
                fakes.roots[index] = scanned
            }
            if fakes.initialScanRootURLs.contains(url) {
                fakes.initialScanRootURLs.remove(url)
                fakes.initialScanRemovals += 1
            }
            // (tree-node-budget) The truncation flag, updated **outside** the splice branch above and
            // membership-guarded — the same shape as `WorkspaceModel`'s seam, which is the code this
            // mirror exists to pin the contract of. Outside, because the flag can flip on a landing
            // that splices nothing (a tree sitting exactly at the budget boundary); guarded, because
            // the real set is `@Published` and an unguarded write would re-render the sidebar on
            // every damped no-op walk.
            if report.truncated != fakes.truncatedRootURLs.contains(url) {
                if report.truncated {
                    fakes.truncatedRootURLs.insert(url)
                } else {
                    fakes.truncatedRootURLs.remove(url)
                }
                fakes.truncatedPublishes += 1
            }
            fakes.landings.append(LandingRecord(url: url, node: scanned, changed: changed, force: force, report: report, applied: true))
            return true
        },
        launchWalk: { url, old, token, completion in
            fakes.walks.append(PendingWalk(url: url, old: old, token: token, completion: completion))
        },
        armTimer: { delay, item in
            fakes.timers.append(ArmedTimer(delay: delay, item: item))
        },
        now: { fakes.clock }
    )
}

/// Floating-point comparison for the damping arithmetic: the gaps under test are whole or
/// half seconds against an exact fake clock, so a nanosecond-scale tolerance is plenty.
func isClose(_ lhs: TimeInterval?, _ rhs: TimeInterval, tolerance: TimeInterval = 1e-9) -> Bool {
    guard let lhs else { return false }
    return abs(lhs - rhs) <= tolerance
}

let rootURL = URL(fileURLWithPath: "/tmp/fedit-root-scan-tests/alpha")
let otherURL = URL(fileURLWithPath: "/tmp/fedit-root-scan-tests/beta")

MainActor.assumeIsolated {

    // MARK: - Add, first walk, landing

    section("Add + first walk: gate state, placeholder baseline, landing splice")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)

        fakes.addRoot(rootURL, to: scheduler)
        check(scheduler.scans[rootURL]?.generation == 1, "noteRootAdded bumps the generation to 1")
        check(scheduler.scans[rootURL]?.isScanning == false, "an added root is not scanning until requested")

        scheduler.requestScan(of: rootURL)
        check(fakes.walkCount == 1, "requestScan launches exactly one walk")
        check(fakes.lastWalk.url == rootURL, "the walk is for the requested root")
        check(marker(of: fakes.lastWalk.old) == nil && fakes.lastWalk.old != nil,
              "the diff baseline captured at walk start is the appended placeholder")
        check(scheduler.scans[rootURL]?.isScanning == true, "the in-flight gate is set while the walk runs")
        check(fakes.timerCount == 0, "an initial (undamped) scan arms no trailing-edge timer")

        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.5))
        check(marker(of: fakes.roots.first) == "v1", "the landed tree is spliced into roots")
        check(fakes.initialScanRootURLs.isEmpty, "the first landing clears the root's \"Scanning…\" affordance")
        check(fakes.initialScanRemovals == 1, "…and it does so exactly once")
        check(scheduler.scans[rootURL]?.isScanning == false, "the landing clears the in-flight gate")
        check(scheduler.scans[rootURL]?.lastFinish != nil, "the landing records the damping clock")
        check(isClose(scheduler.scans[rootURL]?.lastDuration, 0.5), "…and the walk's measured duration")
        check(isClose(scheduler.scans[rootURL]?.backoff, RootScanScheduler.minRescanGap),
              "a changed landing puts the backoff at the floor")
        check(fakes.walkCount == 1, "no pending request means no re-fire at landing")
    }

    // MARK: - Gate 1

    section("Gate 1: requests during an in-flight walk coalesce into exactly one re-run (I1, I2)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)

        scheduler.requestScan(of: rootURL, damped: true)
        scheduler.requestScan(of: rootURL, damped: true)
        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.walkCount == 1, "three requests during a walk start no second walk")
        check(scheduler.scans[rootURL]?.rescanRequested == true, "the gated requests are recorded, not dropped")
        check(scheduler.scans[rootURL]?.forcedRescan == false, "unforced gated requests carry no force bit")

        // Structurally-unchanged landing: backoff doubles off the floor to 2 s, and the re-fire
        // (damped, since the coalesced request was unforced) is deferred by gate 2 rather than
        // running a second back-to-back walk.
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))
        check(fakes.walkCount == 1, "the coalesced re-fire is damped, not an immediate second walk")
        check(isClose(scheduler.scans[rootURL]?.backoff, 2), "an unchanged landing doubles the backoff to 2 s")
        check(fakes.timerCount == 1, "the deferred re-run arms exactly one trailing-edge timer")
        check(isClose(fakes.lastTimer.delay, 2), "the timer's delay is the unserved part of the 2 s gap")
        check(scheduler.scans[rootURL]?.rescanRequested == true, "the deferred request is still recorded")

        fakes.advance(2)
        fakes.lastTimer.item.perform()
        check(fakes.walkCount == 2, "the trailing-edge timer fires the deferred walk exactly once")
        // `.map` rather than `?.x == nil`: the latter is also true when the whole entry is gone,
        // which would make "the field was cleared, the entry survived" vacuously pass.
        check(scheduler.scans[rootURL].map { $0.pendingDampedRescan == nil } == true,
              "the fired timer clears its own armed slot (I6)")
        check(scheduler.scans[rootURL]?.rescanRequested == false, "walk start consumes the deferred request (I3)")
        check(scheduler.scans[rootURL]?.isScanning == true, "…and sets the in-flight gate")
    }

    // MARK: - Force-bit folding

    section("Force bit: preserved while gated, folded into the re-run, consumed once (I2, I3, I11)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.2))

        scheduler.requestScan(of: rootURL, force: true)          // explicit Refresh, undamped
        check(fakes.walkCount == 2, "an explicit Refresh is never damped (I4)")
        scheduler.requestScan(of: rootURL, force: true)          // arrives during the walk
        scheduler.requestScan(of: rootURL, damped: true)         // a watcher event during the walk
        check(scheduler.scans[rootURL]?.forcedRescan == true, "the gated request's force bit is preserved")
        check(scheduler.scans[rootURL]?.rescanRequested == true, "…alongside the request bit (I14)")

        fakes.lastWalk.completion(walk(tree(rootURL, "v2"), false, 0.2))
        check(fakes.walkCount == 3, "a forced re-fire skips the damping gate entirely (I11)")
        check(scheduler.scans[rootURL]?.forcedRescan == false, "the force bit is consumed by the re-fire")
        check(scheduler.scans[rootURL]?.rescanRequested == false, "…together with the request bit")

        fakes.lastWalk.completion(walk(tree(rootURL, "v3"), false, 0.2))
        check(fakes.landings.last?.force == true, "the folded force bit reaches the model-side landing")
        check(marker(of: fakes.roots.first) == "v3", "a forced landing republishes even with changed == false")
        check(isClose(scheduler.scans[rootURL]?.backoff, RootScanScheduler.minRescanGap),
              "a forced landing resets the backoff to the floor (I5)")
    }

    // MARK: - Damping arithmetic

    section("Damping: exponential backoff, its 30 s cap, and the reset on change/force (I5)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)

        /// One undamped request + one landing, i.e. a full walk cycle with a known outcome.
        /// `@MainActor` because a local function does not inherit the enclosing block's isolation.
        @MainActor
        func cycle(force: Bool = false, changed: Bool, duration: TimeInterval = 0.1) {
            scheduler.requestScan(of: rootURL, force: force)
            fakes.lastWalk.completion(walk(changed ? tree(rootURL, UUID().uuidString) : placeholder(rootURL), changed, duration))
        }

        for expected in [2.0, 4.0, 8.0, 16.0, 30.0, 30.0] {
            cycle(changed: false)
            check(isClose(scheduler.scans[rootURL]?.backoff, expected),
                  "consecutive unchanged landings back off to \(expected) s (cap \(RootScanScheduler.maxRescanGap) s)")
        }

        cycle(changed: true)
        check(isClose(scheduler.scans[rootURL]?.backoff, 1), "a structural change resets the backoff to 1 s")
        cycle(changed: false)
        check(isClose(scheduler.scans[rootURL]?.backoff, 2), "…and the doubling restarts from the floor")
        cycle(force: true, changed: false)
        check(isClose(scheduler.scans[rootURL]?.backoff, 1), "an explicit Refresh resets the backoff too")
    }

    section("Damping: the proportional term applies only once the backoff has left its floor (I5)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)

        // A changed landing of an expensive (10 s) walk: backoff sits at the 1 s floor, so the
        // proportional term is deliberately NOT applied — a lone genuine change on a quiet root
        // must reflect after 1 s, not after 3 × 10 s.
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 10))
        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.walkCount == 1, "a damped request inside the gap does not walk")
        check(isClose(fakes.lastTimer.delay, 1), "at the backoff floor the gap is 1 s, not 3 × the 10 s walk")

        // Serve the gap and let the deferred walk come back unchanged: the backoff leaves the floor
        // (2 s) and the proportional term — 3 × the walk's own 10 s cost — now dominates.
        fakes.advance(1)
        fakes.lastTimer.item.perform()
        check(fakes.walkCount == 2, "the served gap releases the deferred walk")
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 10))
        scheduler.requestScan(of: rootURL, damped: true)
        check(isClose(fakes.lastTimer.delay, 30), "off the floor the gap becomes 3 × the last walk's duration")

        // A burst inside the same gap coalesces into the already-armed timer: it keeps the ORIGINAL
        // deadline rather than re-arming against the (shorter) remaining gap, so a sustained drip
        // cannot walk the timer's deadline forward indefinitely.
        let armed = fakes.lastTimer.item
        fakes.advance(5)
        scheduler.requestScan(of: rootURL, damped: true)
        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.timerCount == 2, "a burst inside the gap arms no further timer")
        check(fakes.lastTimer.item === armed, "…the pending item is the very one armed before the burst")
        check(!armed.isCancelled, "…which was neither cancelled nor replaced")
        check(isClose(fakes.lastTimer.delay, 30),
              "…so its deadline is still the original 30 s, not re-armed to the 25 s that remain")
        check(scheduler.scans[rootURL]?.rescanRequested == true, "…and the burst stays recorded, never dropped")

        armed.perform()
        check(fakes.walkCount == 3, "the trailing-edge re-entry is never damped again (its gap is served)")
    }

    section("Damping: elapsed time is subtracted from the required gap")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.25))   // backoff → 2 s

        fakes.advance(0.5)
        scheduler.requestScan(of: rootURL, damped: true)
        check(isClose(fakes.lastTimer.delay, 1.5), "a request 0.5 s into a 2 s gap waits out the remaining 1.5 s")

        fakes.advance(10)
        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.walkCount == 2, "a damped request past the whole gap walks immediately")
        check(fakes.timerCount == 1, "…and arms no further timer")
    }

    // MARK: - I13

    section("I13: a root with no recorded landing is never damped")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)

        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.walkCount == 1, "the first watcher-driven rescan of a fresh root runs immediately")
        check(fakes.timerCount == 0, "…and arms no timer (no clock to measure a gap against)")
        check(scheduler.scans[rootURL].map { $0.lastFinish == nil } == true,
              "lastFinish is still nil while that first walk runs")

        // Removal wipes the clock, so the same rule applies again after a re-add.
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))
        check(scheduler.scans[rootURL]?.lastFinish != nil, "the landing records a clock")
        fakes.removeRoot(rootURL, from: scheduler)
        fakes.addRoot(rootURL, to: scheduler)
        check(scheduler.scans[rootURL].map { $0.lastFinish == nil } == true,
              "a remove/re-add leaves the root with a (fresh) entry that has no clock")
        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.walkCount == 2, "so the first rescan after a re-add is immediate, not damped")
    }

    // MARK: - Drain on remove

    section("Drain on remove: one call clears the request bits, the clocks and the armed timer")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))
        scheduler.requestScan(of: rootURL, damped: true)         // arms a timer + records the request
        check(fakes.timerCount == 1, "precondition: a trailing-edge timer is armed")

        let armed = fakes.lastTimer.item
        fakes.removeRoot(rootURL, from: scheduler)
        check(armed.isCancelled, "removal cancels the armed trailing-edge timer")
        check(scheduler.scans[rootURL] == nil, "an idle removed root's entry is collected outright")
        armed.perform()
        check(fakes.walkCount == 1, "a cancelled timer cannot fire a walk against a removed root")
    }

    section("Drain on remove: an in-flight walk keeps its gate and its bumped generation (I1, I7)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        scheduler.requestScan(of: rootURL, force: true)          // gated: sets both bits
        let token = fakes.lastWalk.token

        fakes.removeRoot(rootURL, from: scheduler)
        check(token.isCancelled, "removal cancels the in-flight walk's token")
        check(scheduler.scans[rootURL] != nil, "the entry survives while a walk is in flight")
        check(scheduler.scans[rootURL]?.isScanning == true, "the in-flight gate is never cleared by removal (I1)")
        check(scheduler.scans[rootURL]?.generation == 2, "removal bumps the generation (I7)")
        check(scheduler.scans[rootURL]?.rescanRequested == false, "removal clears the recorded request")
        check(scheduler.scans[rootURL]?.forcedRescan == false, "…and its force bit")
        check(scheduler.scans[rootURL].map { $0.lastFinish == nil } == true, "…and the damping clock")
        check(scheduler.scans[rootURL].map { $0.backoff == nil } == true, "…and the backoff")

        // The stale landing: discarded, but it still does its job-local teardown.
        fakes.lastWalk.completion(walk(tree(rootURL, "stale"), true, 0.3))
        check(fakes.landings.isEmpty, "a landing whose generation moved never reaches the model seam")
        check(fakes.roots.isEmpty, "…so the removed root's section cannot reappear")
        check(scheduler.scans[rootURL] == nil, "the entry is collected once the walk has landed")
    }

    section("Drain on remove: wiping the damping clock un-damps the re-added root's first rescan (I13)")
    do {
        // The shape that makes the three clock clears in `noteRootRemoved` observable. A landing
        // first puts the root deep into damping — backoff off its floor *and* an expensive (135 s)
        // walk recorded, so the proportional term would demand a 405 s gap — and the removal then
        // happens with a second walk in flight, so the entry (and with it the clock, had it not been
        // cleared) survives the removal.
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 135))  // unchanged: backoff → 2 s, clock set
        check(isClose(scheduler.scans[rootURL]?.backoff, 2), "precondition: the backoff has left its floor")
        check(scheduler.scans[rootURL]?.lastFinish != nil, "precondition: the damping clock is set")
        check(isClose(scheduler.scans[rootURL]?.lastDuration, 135), "precondition: an expensive walk is recorded")

        scheduler.requestScan(of: rootURL)                          // walk 2, left in flight
        check(fakes.walkCount == 2, "precondition: a second walk is in flight")

        fakes.removeRoot(rootURL, from: scheduler)
        check(scheduler.scans[rootURL] != nil, "the entry survives the removal — a walk is still in flight")
        check(scheduler.scans[rootURL].map { $0.lastFinish == nil } == true, "…but the removal wiped the damping clock")
        check(scheduler.scans[rootURL].map { $0.lastDuration == nil } == true, "…and the recorded walk cost")
        check(scheduler.scans[rootURL].map { $0.backoff == nil } == true, "…and the backoff")

        fakes.addRoot(rootURL, to: scheduler)                       // re-added: present again, generation moved
        scheduler.requestScan(of: rootURL, damped: true)            // gated behind the walk still unwinding
        check(fakes.walkCount == 2, "the re-added root's rescan is gated by the in-flight walk")
        check(scheduler.scans[rootURL]?.rescanRequested == true, "…and recorded as the pending request")

        // The stale walk lands: discarded (generation moved), so it records no damping state of its
        // own, and the I12 drain re-fires the recorded request with `damped: true`.
        let landingsBefore = fakes.landings.count      // the first walk's landing is legitimately in the log
        fakes.lastWalk.completion(walk(tree(rootURL, "stale"), true, 135))
        check(fakes.landings.count == landingsBefore, "the stale tree is discarded — generation moved")
        check(fakes.walkCount == 3, "the damped re-fire LAUNCHES IMMEDIATELY — the wiped clock means gate 2 cannot engage")
        check(fakes.timerCount == 0, "…and arms no trailing-edge timer at all")
    }

    section("Damping control: the same shape *without* a removal is damped by the surviving clock")
    do {
        // The control for the case above: identical shape — expensive unchanged landing, second walk
        // in flight, a damped request gated behind it, then the landing's I12 drain — but no removal,
        // so the damping clock is intact and the re-fire is deferred instead of walking.
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 135))  // unchanged: backoff → 2 s, clock set

        scheduler.requestScan(of: rootURL)                          // walk 2, left in flight
        scheduler.requestScan(of: rootURL, damped: true)            // gated behind it
        check(fakes.walkCount == 2, "precondition: the rescan is gated by the in-flight walk")

        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 135))  // lands normally: backoff → 4 s, clock re-set
        check(fakes.walkCount == 2, "with the clock intact the drain's re-fire does not walk")
        check(fakes.timerCount == 1, "…it arms a trailing-edge timer instead")
        check(isClose(fakes.lastTimer.delay, 405), "…for 3 × the 135 s walk, the proportional term")
    }

    // MARK: - I12

    section("I12: remove → re-add mid-walk → the stale landing still fires the fresh root's scan")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)                       // walk 1, generation 1
        let staleToken = fakes.lastWalk.token

        fakes.removeRoot(rootURL, from: scheduler)               // generation 2, walk 1 cancelled
        fakes.addRoot(rootURL, to: scheduler)                    // generation 3, fresh placeholder
        scheduler.requestScan(of: rootURL)                       // gated by walk 1's gate
        check(staleToken.isCancelled, "the superseded walk was cancelled by the removal")
        check(fakes.walkCount == 1, "the re-added root's scan is gated behind the walk still unwinding")
        check(scheduler.scans[rootURL]?.rescanRequested == true, "…and recorded as the pending request")
        check(scheduler.scans[rootURL]?.generation == 3, "add + remove + add leaves generation 3")

        fakes.lastWalk.completion(walk(tree(rootURL, "stale"), true, 0.4))
        check(fakes.landings.isEmpty, "the stale (partial) tree is discarded — generation moved")
        check(fakes.walkCount == 2, "the drain re-fires the re-added root's own scan unconditionally (I12)")
        check(fakes.timerCount == 0,
              "…undamped: the root has no recorded lastFinish — its only walk never landed — so gate 2 never engages (I13)")
        check(fakes.initialScanRootURLs.contains(rootURL), "the placeholder still shows \"Scanning…\" meanwhile")

        fakes.lastWalk.completion(walk(tree(rootURL, "fresh"), true, 0.4))
        check(marker(of: fakes.roots.first) == "fresh", "the fresh walk's tree lands under the fresh placeholder")
        check(!fakes.initialScanRootURLs.contains(rootURL), "…and \"Scanning…\" finally clears (the I12 defect)")
    }

    // MARK: - Skip record (watcher-scan-skip-parity)

    section("Skip record: absent until a landing applies, then it is the landed walk's own")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        // `.map` rather than `?.skipRecord == nil`: the latter also passes when the whole entry is
        // gone, which would make "no verdicts yet" vacuously true.
        check(scheduler.scans[rootURL].map { $0.skipRecord == nil } == true,
              "a freshly added root has no skip record — absence means \"no walk has delivered verdicts\"")

        scheduler.requestScan(of: rootURL)
        check(scheduler.scans[rootURL].map { $0.skipRecord == nil } == true,
              "…and still none while its first walk is in flight")

        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.5, record: skipRecord("v1")))
        check(scheduler.scans[rootURL]?.skipRecord == skipRecord("v1"),
              "an applied landing stores that walk's record verbatim, got \(String(describing: scheduler.scans[rootURL]?.skipRecord))")
    }

    section("Skip record: a structurally-unchanged landing still refreshes it (no publish, fresher verdicts)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.5, record: skipRecord("v1")))

        // Unchanged AND unforced: `land` reports the root is present (applied) but splices nothing.
        // The verdicts are nonetheless newer than v1's, so they must replace them.
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v2"), false, 0.5, record: skipRecord("v2")))
        check(marker(of: fakes.roots.first) == "v1", "precondition: the unchanged landing published nothing")
        check(scheduler.scans[rootURL]?.skipRecord == skipRecord("v2"),
              "…yet the skip record advanced to that landing's own, got \(String(describing: scheduler.scans[rootURL]?.skipRecord))")
    }

    section("Skip record: drained by removal, and a superseded walk's partial record is discarded")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)                      // walk 1, generation 1
        fakes.lastWalk.completion(walk(tree(rootURL, "settled"), true, 0.4, record: skipRecord("settled")))
        check(scheduler.scans[rootURL]?.skipRecord == skipRecord("settled"), "precondition: a record is stored")

        scheduler.requestScan(of: rootURL)                      // walk 2, left in flight at generation 1
        check(fakes.walkCount == 2, "precondition: a second walk is in flight")

        fakes.removeRoot(rootURL, from: scheduler)              // generation 2, walk 2 cancelled
        check(scheduler.scans[rootURL] != nil, "the entry survives the removal — a walk is still in flight")
        check(scheduler.scans[rootURL].map { $0.skipRecord == nil } == true,
              "…but the removal drained the skip record with the rest of the per-root state")

        fakes.addRoot(rootURL, to: scheduler)                   // generation 3, fresh placeholder
        scheduler.requestScan(of: rootURL)                      // gated behind walk 2 still unwinding

        // Walk 2 unwinds: cancelled, so its tree AND its record are partial, and its generation moved.
        // Neither may land — if `applyScan` stored the record outside the applied branch, the gate
        // would then be consulting a half-built index for a freshly re-added root.
        fakes.lastWalk.completion(walk(tree(rootURL, "partial"), true, 0.4, record: skipRecord("partial")))
        check(fakes.landings.count == 1, "precondition: the superseded landing never reached the model seam")
        check(scheduler.scans[rootURL].map { $0.skipRecord == nil } == true,
              "the superseded walk's partial record is discarded, not stored, got \(String(describing: scheduler.scans[rootURL]?.skipRecord))")

        // The control: the re-added root's own walk lands normally and its record does take.
        fakes.lastWalk.completion(walk(tree(rootURL, "fresh"), true, 0.4, record: skipRecord("fresh")))
        check(scheduler.scans[rootURL]?.skipRecord == skipRecord("fresh"),
              "…while the fresh walk's record lands normally")
    }

    section("Skip record: an idle removed root's record goes with its collected entry")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.4, record: skipRecord("v1")))
        check(scheduler.scans[rootURL]?.skipRecord != nil, "precondition: a record is stored")

        fakes.removeRoot(rootURL, from: scheduler)
        check(scheduler.scans[rootURL] == nil, "the idle removed root's entry — record included — is collected outright")

        // A re-add starts from no verdicts at all, so the gate cannot decide against a dead tree.
        fakes.addRoot(rootURL, to: scheduler)
        check(scheduler.scans[rootURL].map { $0.skipRecord == nil } == true,
              "a re-added root starts with no skip record")
    }

    // MARK: - Budget report (tree-node-budget)
    //
    // Two things are under test here, and they are deliberately separate: the scheduler's own
    // `RootScan.lastReport` (observability plus the notice's node count, stored on exactly the
    // applied branch), and the **model-side** flag the notice actually renders from — which this
    // harness can only reach through the `land` seam. `Fakes` maintains its own
    // `truncatedRootURLs` with the same membership guard `WorkspaceModel` uses, so what these
    // scenarios pin is the seam's *contract*: what `land` is handed, when, and what a correct
    // consumer must do with it. The model's own copy of that consumer is review-traced (no UI
    // harness exists), which is why the guard lives in one place there with a comment naming this.

    section("Budget report: absent until a landing applies, then it is the landed walk's own")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        // `.map` rather than `?.lastReport == nil`, for the same reason the skip-record scenarios use
        // it: the latter also passes when the whole entry is gone.
        check(scheduler.scans[rootURL].map { $0.lastReport == nil } == true,
              "a freshly added root has no budget report — absence means \"no walk has landed\"")

        scheduler.requestScan(of: rootURL)
        check(scheduler.scans[rootURL].map { $0.lastReport == nil } == true,
              "…and still none while its first walk is in flight")
        check(fakes.truncatedRootURLs.isEmpty, "…and no truncation notice is owed while it runs")

        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.5, report: budgetReport(50_000)))
        check(scheduler.scans[rootURL]?.lastReport == budgetReport(50_000),
              "an applied landing stores that walk's report verbatim, got \(String(describing: scheduler.scans[rootURL]?.lastReport))")
        check(fakes.landings.last?.report == budgetReport(50_000),
              "…and the model seam was handed the very same value, not a re-derivation")
        check(fakes.truncatedRootURLs == [rootURL], "…and the truncated root reaches the notice's published set")
        check(fakes.truncatedPublishes == 1, "…in exactly one mutation of it")
    }

    section("Budget report: an unchanged landing refreshes it — and can flip the flag with no splice")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.5, report: budgetReport(100)))
        check(fakes.truncatedRootURLs == [rootURL], "precondition: the first walk landed truncated")

        // Unchanged AND unforced: `land` reports the root present (applied) but splices nothing —
        // while the tree that had been sitting exactly at the budget boundary now fits. This is the
        // shape a splice-branch-only update gets wrong: the notice would stay up forever on a root
        // that is no longer truncated.
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v2"), false, 0.5, report: budgetReport(100, truncated: false)))
        check(marker(of: fakes.roots.first) == "v1", "precondition: the unchanged landing published no tree")
        check(fakes.landings.last?.report == budgetReport(100, truncated: false),
              "the report reaches the seam on an unchanged landing too, not only on splices")
        check(scheduler.scans[rootURL]?.lastReport == budgetReport(100, truncated: false),
              "…and the stored report advances to that landing's own, got \(String(describing: scheduler.scans[rootURL]?.lastReport))")
        check(fakes.truncatedRootURLs.isEmpty, "…and the FAKE seam's consumer set drops the root, splice or no splice (the model's own copy is review-traced)")
        check(fakes.truncatedPublishes == 2, "…in exactly one further mutation")

        // And the other half of the guard: a landing that leaves the flag where it already was must
        // touch nothing, or every damped no-op walk would re-render the sidebar.
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v3"), false, 0.5, report: budgetReport(100, truncated: false)))
        check(fakes.truncatedPublishes == 2, "a landing that changes nothing about truncation publishes nothing")
        check(fakes.truncatedRootURLs.isEmpty, "…and leaves the set correct")
    }

    section("Budget report: drained by removal, and a superseded walk's partial report is discarded")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)                      // walk 1, generation 1
        fakes.lastWalk.completion(walk(tree(rootURL, "settled"), true, 0.4, report: budgetReport(7)))
        check(scheduler.scans[rootURL]?.lastReport == budgetReport(7), "precondition: a report is stored")
        check(fakes.truncatedRootURLs == [rootURL], "precondition: …and published")

        scheduler.requestScan(of: rootURL)                      // walk 2, left in flight at generation 1
        fakes.removeRoot(rootURL, from: scheduler)              // generation 2, walk 2 cancelled
        check(scheduler.scans[rootURL] != nil, "the entry survives the removal — a walk is still in flight")
        check(scheduler.scans[rootURL].map { $0.lastReport == nil } == true,
              "…but the removal drained the budget report with the rest of the per-root state")
        check(fakes.truncatedRootURLs.isEmpty, "…and the model-side notice set is drained in the same breath")

        fakes.addRoot(rootURL, to: scheduler)                   // generation 3, fresh placeholder
        scheduler.requestScan(of: rootURL)                      // gated behind walk 2 still unwinding

        fakes.lastWalk.completion(walk(tree(rootURL, "partial"), true, 0.4, report: budgetReport(3)))
        check(fakes.landings.count == 1, "precondition: the superseded landing never reached the model seam")
        check(scheduler.scans[rootURL].map { $0.lastReport == nil } == true,
              "a cancelled walk's partial report is discarded, not stored, got \(String(describing: scheduler.scans[rootURL]?.lastReport))")
        check(fakes.truncatedRootURLs.isEmpty,
              "…so a re-added root shows no notice earned by a dead incarnation's walk")

        fakes.lastWalk.completion(walk(tree(rootURL, "fresh"), true, 0.4, report: budgetReport(9, truncated: false)))
        check(scheduler.scans[rootURL]?.lastReport == budgetReport(9, truncated: false),
              "…while the fresh walk's report lands normally")
        check(fakes.truncatedRootURLs.isEmpty, "…and an untruncated fresh walk owes no notice")
    }

    section("Budget report: an idle removed root's report goes with its collected entry")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(tree(rootURL, "v1"), true, 0.4, report: budgetReport(12)))
        check(scheduler.scans[rootURL]?.lastReport != nil, "precondition: a report is stored")

        fakes.removeRoot(rootURL, from: scheduler)
        check(scheduler.scans[rootURL] == nil, "the idle removed root's entry — report included — is collected outright")
        check(fakes.truncatedRootURLs.isEmpty, "…and its notice goes with it")

        fakes.addRoot(rootURL, to: scheduler)
        check(scheduler.scans[rootURL].map { $0.lastReport == nil } == true,
              "a re-added root starts from no report at all")
    }

    section("Budget report: a landing for a root that left `roots` publishes no notice (I8)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)

        // The root leaves `roots` **without** the scheduler being told, so its generation is unmoved
        // and the landing really does reach the model seam — the one path on which `land` returns
        // false. A notice inserted here would be one no section could show and no removal could
        // drain, which is why the seam's presence guard runs before the truncation update.
        fakes.roots.removeAll { $0.url == rootURL }
        fakes.lastWalk.completion(walk(tree(rootURL, "orphan"), true, 0.3, report: budgetReport(11)))
        check(fakes.landings.last?.applied == false, "precondition: the seam reported the root is gone from roots")
        check(fakes.landings.last?.report == budgetReport(11), "…having been handed the report all the same")
        check(fakes.truncatedRootURLs.isEmpty, "no notice is published for a root with no section")
        check(scheduler.scans[rootURL] == nil, "…and the unapplied landing records nothing at all (I8), entry collected")
    }

    // MARK: - Entry GC

    section("Entry GC: idle removed roots are collected, live and present ones are not")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        fakes.addRoot(otherURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        scheduler.requestScan(of: otherURL)
        fakes.lastWalk.completion(walk(tree(otherURL, "beta"), true, 0.1))

        check(scheduler.scans.count == 2, "both roots have entries while they are present")
        fakes.removeRoot(otherURL, from: scheduler)
        check(scheduler.scans[otherURL] == nil, "the idle removed root's entry is collected")
        check(scheduler.scans[rootURL] != nil, "the other root's entry is untouched")
        check(scheduler.scans[rootURL]?.isScanning == true, "…and still holds its in-flight gate")

        fakes.walks[0].completion(walk(tree(rootURL, "alpha"), true, 0.1))
        check(scheduler.scans[rootURL] != nil, "a *present* root's entry is never collected")
        check(scheduler.scans[rootURL]?.lastFinish != nil, "…so its damping clock survives its landing")

        // A re-add after a collection starts from a zero generation — which is safe exactly because
        // the collection admitted no live job for that URL.
        fakes.addRoot(otherURL, to: scheduler)
        check(scheduler.scans[otherURL]?.generation == 1, "a re-add after collection starts from generation 1")
    }

    // MARK: - Trailing-edge timer

    section("Trailing-edge timer: no-ops when its request was already consumed (I6)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))   // clock set, backoff 2 s

        scheduler.requestScan(of: rootURL, damped: true)
        let timer = fakes.lastTimer.item
        fakes.advance(2)
        timer.perform()
        check(fakes.walkCount == 2, "the armed timer fires the deferred walk")

        // Fire the same item again — the shape of a timer that lands after its request has already
        // been consumed. It must be a no-op, and must not leave a phantom armed slot behind.
        timer.perform()
        check(fakes.walkCount == 2, "a second fire with no recorded request starts no walk")
        check(scheduler.scans[rootURL].map { $0.pendingDampedRescan == nil } == true, "…and leaves no phantom armed slot")

        // The armed slot being genuinely clear is what lets the next damped request arm at all.
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))
        scheduler.requestScan(of: rootURL, damped: true)
        check(fakes.timerCount == 2, "a later damped request can still arm its trailing-edge timer")
    }

    section("Walk start disarms the pending timer, so a Refresh costs no second walk (I3)")
    do {
        let fakes = Fakes()
        let scheduler = makeScheduler(fakes)
        fakes.addRoot(rootURL, to: scheduler)
        scheduler.requestScan(of: rootURL)
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))

        scheduler.requestScan(of: rootURL, damped: true)
        let stale = fakes.lastTimer.item
        scheduler.requestScan(of: rootURL, force: true)               // explicit Refresh during the gap
        check(fakes.walkCount == 2, "the Refresh walks immediately")
        check(stale.isCancelled, "…and disarms the timer the damped request had armed")
        check(scheduler.scans[rootURL].map { $0.pendingDampedRescan == nil } == true, "…clearing the armed slot with it")

        // A cancelled item can never clear a *successor's* slot: that is what makes the armed-slot
        // bookkeeping single-owner even though it is not identity-compared.
        fakes.lastWalk.completion(walk(placeholder(rootURL), false, 0.1))
        scheduler.requestScan(of: rootURL, damped: true)
        let live = fakes.lastTimer.item
        stale.perform()
        check(scheduler.scans[rootURL]?.pendingDampedRescan != nil, "a cancelled predecessor cannot clear the live slot")
        check(fakes.walkCount == 2, "…nor fire a walk of its own")
        fakes.advance(30)
        live.perform()
        check(fakes.walkCount == 3, "the live timer still fires normally")
    }

    // MARK: - Teardown

    section("Teardown: releasing the scheduler cancels in-flight walks and leaves nothing behind")
    do {
        let fakes = Fakes()
        var scheduler: RootScanScheduler? = makeScheduler(fakes)
        weak let weakScheduler = scheduler

        // Two roots, two walks: the registry's teardown loop has to cancel *every* token it still
        // holds, and a single-token registry would pass even if it only ever cancelled one.
        fakes.addRoot(rootURL, to: scheduler!)
        scheduler!.requestScan(of: rootURL)
        let token = fakes.lastWalk.token
        fakes.addRoot(otherURL, to: scheduler!)
        scheduler!.requestScan(of: otherURL)
        let otherToken = fakes.lastWalk.token
        check(token !== otherToken, "precondition: the two roots minted distinct tokens")
        check(!token.isCancelled && !otherToken.isCancelled, "precondition: both in-flight walks' tokens are live")
        check(weakScheduler != nil, "precondition: the weak reference sees the live scheduler")

        scheduler = nil
        check(weakScheduler == nil, "the scheduler deallocates — it holds no strong reference to itself")
        check(token.isCancelled, "…and its token registry's deinit cancels the in-flight walk")
        check(otherToken.isCancelled, "…every one of them, not just one (the registry's cancellation loop)")

        // The landing closure the (now dead) scheduler handed to the walk holds it weakly, so a walk
        // that unwinds after teardown is a no-op rather than a resurrection or a crash.
        fakes.walks[0].completion(walk(tree(rootURL, "after-teardown"), true, 0.1))
        check(fakes.landings.isEmpty, "a walk landing after teardown reaches no model seam")
        check(marker(of: fakes.roots.first) == nil, "…and splices nothing into roots")
    }

    section("Teardown: the production default seams hold no reference to the scheduler either")
    do {
        // Every other scenario replaces `launchWalk`/`armTimer`/`now` with fakes, so the *shipped*
        // defaults are the one part of the ownership graph they never exercise. Constructed with no
        // injections at all — the real defaults land in the stored properties — and deliberately not
        // driven: the only claim under test is that none of them captured `self`.
        var scheduler: RootScanScheduler? = RootScanScheduler(
            currentNode: { _ in nil },
            land: { _, _, _, _, _ in false }
        )
        weak let weakScheduler = scheduler
        check(weakScheduler != nil, "precondition: the weak reference sees the live scheduler")

        scheduler = nil
        check(weakScheduler == nil, "production-default seams hold no strong reference to the scheduler")
    }
}

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
