//
//  FileNode.swift
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

/// A single entry in the folder sidebar's directory tree (SPEC §5.2–§5.3). Value type so a tree
/// built off the main thread on `RootScanScheduler`'s scan queue can be handed back to the main
/// actor **by value** and straight to `OutlineGroup` (async-root-scan).
///
/// The `Sendable` conformance is load-bearing, not decoration: every stored property is a value
/// type with no reference payload and no lazily-populated cache, and that is the *only* reason the
/// cross-thread hand-back needs no deep copy or lock. Adding a class-typed field or a mutable cache
/// here would turn that hand-back into a data race — one Swift 5's minimal concurrency checking
/// does **not** diagnose, so the failure mode would be a silent intermittent crash. Re-check this
/// whenever a property is added.
struct FileNode: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool

    /// Non-nil (possibly empty) for directories, `nil` for files — this optionality is
    /// deliberate: it is exactly what `OutlineGroup`/`DisclosureGroup` use to tell leaves from
    /// expandable nodes. Do not "simplify" this to a non-optional array.
    var children: [FileNode]?

    var id: URL { url }

    /// Directory names skipped everywhere in the scan, regardless of depth (SPEC §5.2). Dotfile
    /// skipping already covers `.build`, but it is listed explicitly per spec.
    static let skippedDirectoryNames: Set<String> = ["node_modules", ".build", "DerivedData"]

    /// (tree-node-budget) The per-root node budget the **production** walk runs under — passed by
    /// `RootScanScheduler`'s walk launcher, the app target's only walk call site. It bounds one
    /// root's tree and, with it, every downstream per-node cost (the filter mode's flat list,
    /// `OutlineGroup`'s diffing), so a `$HOME`-scale root can no longer grow the window's working
    /// set with the disk (SPEC §1, §11).
    ///
    /// A **knob, not a contract** (assumption B2): ~10–15 MB of tree per root at this size, per root
    /// *per window*, so many huge roots still multiply. Nothing hardcodes the number anywhere else —
    /// the sidebar's truncation notice interpolates the count the walk actually built, and SPEC
    /// states the order of magnitude rather than this constant — so changing this one line changes
    /// the shipped bound.
    static let defaultNodeBudget = 50_000

    /// Scans `directory` into a `FileNode` tree, whole subtree included and (tree-node-budget)
    /// unbounded.
    ///
    /// **Threading contract (async-root-scan).** This is `nonisolated` and *pure with respect to app
    /// state*: it reads the filesystem and returns a fresh value, holds no reference to the model or
    /// the scan scheduler, and so can neither observe nor mutate main-actor state — a walk in flight
    /// owns a private local tree that no other thread can see until it is handed back. It is still
    /// **synchronous within its own thread**, and a blocking one (`contentsOfDirectory` is a
    /// syscall; a home-scale root measured ~135 s), so the app target calls it from exactly one
    /// place — `RootScanScheduler`'s walk launcher, on `RootScanScheduler.scanQueue`, reached only
    /// through `RootScanScheduler.requestScan(of:force:damped:)` (root-scan-consolidation). Never
    /// call it on the main actor; SPEC §11 no longer accepts a main-thread walk.
    ///
    /// (watcher-scan-skip-parity) A **thin wrapper** that discards the skip record: there is exactly
    /// one walk implementation, `scanRecordingSkips(directory:cancellation:nodeBudget:)`, so
    /// `scripts/FileNodeTests` pins production code rather than a twin. The app target no longer calls
    /// either wrapper — the scan queue needs the record — so they exist for the harness's pinned entry
    /// points (and their equivalence to the recording walk is itself asserted there).
    ///
    /// (tree-node-budget) Both wrappers pass `nodeBudget: nil` — **unbounded** — so the pinned entry
    /// points stay behavior-identical by construction; only the scheduler's launcher budgets a walk.
    static func scan(directory: URL) -> FileNode {
        scan(directory: directory, cancellation: nil)
    }

    /// (async-root-scan, Tier 2) `scan(directory:)` plus cooperative cancellation: the walk checks
    /// `cancellation` once per directory entry and unwinds early when it is set, so removing a
    /// home-scale root does not leave a scan-queue thread walking it for minutes. A cancelled walk
    /// returns a **partial** tree — by contract the caller must discard it (`RootScanScheduler` does,
    /// via the root's scan generation), never publish it.
    ///
    /// (watcher-scan-skip-parity) The second thin wrapper over `scanRecordingSkips`; see above.
    static func scan(directory: URL, cancellation: ScanCancellationToken?) -> FileNode {
        scanRecordingSkips(directory: directory, cancellation: cancellation, nodeBudget: nil).node
    }

    /// (watcher-scan-skip-parity) The **single** walk implementation: the tree, plus a record of what
    /// the walk decided to skip, so the FSEvents gate can ask the scanner's own verdicts instead of
    /// re-deriving them.
    ///
    /// Why the record exists at all: `WorkspaceModel.isSkippedTreePath` runs per changed path inside
    /// an FSEvents burst under a **no-syscall-per-path** rule, so it cannot `stat` anything. Before
    /// this item it re-implemented the scanner's rule as a dot-prefix test plus
    /// `skippedDirectoryNames`, and diverged in both directions — a `UF_HIDDEN` non-dot directory
    /// (`~/Library`) passed the gate and drove a rescan that could never surface anything; and a plain
    /// *file* named `node_modules` was dropped by the gate although the scanner keeps it. Recording
    /// the verdicts where the syscalls already happen and consulting them where none are allowed makes
    /// parity structural instead of a re-derivation that has to be kept in sync by hand. (Unreadable
    /// directories are recorded too, but the gate deliberately does not consult that half — see
    /// `SkipRecord.unreadableDirs`.)
    ///
    /// A **partial** record accompanies a cancelled walk's partial tree, and the same contract
    /// applies: the caller must discard both (`RootScanScheduler`'s generation check does).
    ///
    /// (tree-node-budget) **The walk is breadth-first**, and `nodeBudget` — `nil` for unbounded, which
    /// is what both `scan` wrappers pass — cuts it in **level order**: every shallower level is
    /// complete before any deeper node is built, so what a truncated root loses is its deep interior,
    /// never the rows a collapsed sidebar shows. (A depth-first cut would delete exactly those: with
    /// folders sorted first, a root's own files are the *last* preorder nodes, so `~/notes.md` would
    /// have no row at all on a truncated `$HOME`.) The order within each directory is unchanged —
    /// folders first, then files, `localizedStandardCompare` inside each group — so with `nil` the
    /// output tree is identical to the recursive walk this replaced (assumption B1, pinned by
    /// `scripts/FileNodeTests`' exact preorder path pins).
    ///
    /// Counting rule, pre-order by construction: **every child node built counts, the root node does
    /// not**, so a finished walk builds exactly `min(nodeBudget, total)` nodes.
    /// `TreeBudgetReport.truncated` is true iff at least one classified survivor was actually
    /// refused — a budget of 0 over an *empty* root is therefore not truncated, and a budget that
    /// exactly equals the tree's size is not either (the walk keeps draining the frontier past a
    /// spent budget until something is refused or the frontier empties; at most one LISTING per
    /// already-counted directory — a node-count bound, not a work bound: each drained listing
    /// still pays classification per entry, per SPEC §11's stated cost). A **negative** budget
    /// behaves exactly like 0 — never like unbounded; `nil` is the only way to ask for unbounded.
    ///
    /// Known limitation (review, SUSPECTED-exotic): tree assembly keys directories by relative
    /// path `String`, whose equality is Unicode-canonical — two sibling directories byte-distinct
    /// but canonically equal (NFC vs NFD) would collide. APFS/HFS+ cannot host such siblings;
    /// on normalization-preserving volumes (some SMB/exFAT) the assembly would conflate them.
    ///
    /// Cancellation is checked per directory entry exactly as before and wins over the budget: a
    /// cancelled walk stops where it is, and its `truncated` is about the *budget* alone (the caller
    /// discards a cancelled walk's tree and record wholesale anyway).
    static func scanRecordingSkips(
        directory: URL,
        cancellation: ScanCancellationToken?,
        // No default, deliberately (review): `nil` means UNBOUNDED, and the one production call
        // site passing `defaultNodeBudget` is the only line that makes the app bounded at all — a
        // silent default here would let a dropped argument silently un-bound every walk with all
        // harnesses green. Every caller states its intent (the tree-only wrappers pass `nil`).
        nodeBudget: Int?
    ) -> ScanOutcome {
        let fileManager = FileManager.default
        let standardized = directory.standardizedFileURL

        var skippedIndex: [String: Set<String>] = [:]
        var unreadableDirs: Set<String> = []

        // The breadth-first frontier: directories admitted as nodes but not yet listed, each with its
        // path **relative to the scanned root** (`""` for the root itself), built from
        // `lastPathComponent`s alone and never by string arithmetic on absolute paths. That is what
        // makes the recorded keys independent of whether the caller handed in a standardized or a
        // canonical (realpath'd) root URL, which in turn is what lets the gate compare them against
        // components it derives from an FSEvents path without a rebase step.
        //
        // An index-advanced array rather than a `removeFirst()` queue (which is O(n) on `Array`).
        // Every entry past the root is itself a counted node, so the frontier is bounded by the
        // budget exactly as the tree is.
        var frontier: [(url: URL, relativePath: String)] = [(standardized, "")]
        var nextVisit = 0

        // Visit order, and each visited directory's admitted children. The tree is assembled from
        // these at the end: under BFS a directory node is built long before its own children are
        // discovered, so `children` cannot be filled in at creation time the way the recursive walk
        // did it.
        var visitOrder: [String] = []
        var childrenByPath: [String: [FileNode]] = [:]

        var nodeCount = 0
        var truncated = false

        visits: while nextVisit < frontier.count {
            let visit = frontier[nextVisit]
            nextVisit += 1
            visitOrder.append(visit.relativePath)

            let entries: [URL]
            do {
                // (watcher-scan-skip-parity) `.skipsHiddenFiles` is deliberately **gone**: hidden-ness
                // is now this scanner's own decision (see the predicate below), so the gate can be
                // told what it decided. Foundation would otherwise filter entries out before the loop
                // ever saw them, leaving nothing to record.
                entries = try fileManager.contentsOfDirectory(
                    at: visit.url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey],
                    options: []
                )
            } catch {
                // Unreadable directory (permissions, disappeared mid-scan, etc.) — show as empty
                // rather than crashing or propagating the error (SPEC §11). No `childrenByPath` entry
                // is written, which the assembly below reads as the same empty-children shape the
                // recursive walk returned.
                //
                // (watcher-scan-skip-parity) Recorded, not merely swallowed: this is the one place
                // that knows a subtree is missing from the tree for a reason other than a skip
                // verdict. The record is for observability and per-root scan-outcome reporting, NOT
                // for the FSEvents gate — `TreeSkipGate` deliberately never consults
                // `unreadableDirs`; see `SkipRecord.unreadableDirs` for why gating on it would be
                // permanent.
                unreadableDirs.insert(visit.relativePath)
                continue
            }

            // Classification pass: it decides what this directory *offers*, and it runs to the end of
            // the listing regardless of the budget. That is deliberate — a visited directory's skip
            // record is then exactly the unbounded walk's, so the FSEvents gate never sees a
            // half-built verdict set for a directory it was told about. What the budget governs is
            // the admission pass below.
            var survivors: [FileNode] = []
            survivors.reserveCapacity(entries.count)
            // Names this directory skipped, **excluding** dot-prefixed ones: those are decidable from
            // the name alone at event time, so recording them would swell the index for zero
            // information.
            var skippedNames: Set<String> = []
            var cancelled = false

            for entryURL in entries {
                // (async-root-scan, Tier 2) One lock-guarded flag read per entry — cheap beside the
                // `resourceValues` syscall a few lines down. Unwinding with `break` (not by
                // abandoning the directory) keeps the walk total: the partial listing is well-formed,
                // and the caller discards it anyway.
                if cancellation?.isCancelled == true {
                    cancelled = true
                    break
                }

                let standardizedEntry = entryURL.standardizedFileURL
                let name = standardizedEntry.lastPathComponent

                // `.isHiddenKey` joins the keys this call already fetches — one `resourceValues` call
                // regardless of key count, so owning the hidden test costs no extra syscall per entry.
                // (It does surface hidden entries to this loop that `.skipsHiddenFiles` used to drop
                // before it, so each pays one `resourceValues` before being skipped; hidden *subtrees*
                // are still never descended.)
                let resourceValues = try? standardizedEntry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey])
                let isSymbolicLink = resourceValues?.isSymbolicLink ?? false
                // Symbolic links are treated as leaf files (never enqueued) to avoid link cycles.
                let isDirectory = !isSymbolicLink && (resourceValues?.isDirectory ?? false)

                // (watcher-scan-skip-parity) The owned hidden predicate, replacing `.skipsHiddenFiles`
                // (dot ∪ `UF_HIDDEN`). The dot term is deliberate **belt**: it makes "dot ⟹ skipped"
                // true by construction, on any volume, which is what lets the gate keep a static dot
                // rule that matches this scanner unconditionally rather than by a volume-behavior
                // assumption. A non-dot entry whose `resourceValues` failed reads as not hidden and is
                // therefore kept — a deliberate tree-fidelity change vs Foundation in that rare
                // failure case, favoring showing an entry over silently hiding it.
                let hidden = (resourceValues?.isHidden ?? false) || name.hasPrefix(".")

                if hidden || ((isDirectory || isSymbolicLink) && skippedDirectoryNames.contains(name)) {
                    if !name.hasPrefix(".") { skippedNames.insert(name) }
                    continue
                }

                // Directories are born with `children: []`, filled in by the assembly pass below (and
                // left empty for the ones beyond the cut, which render as empty expandable folders).
                survivors.append(FileNode(
                    url: standardizedEntry,
                    name: name,
                    isDirectory: isDirectory,
                    children: isDirectory ? [] : nil
                ))
            }

            // Only non-empty verdicts are stored: an absent key reads as "nothing non-dot was skipped
            // here", which is exactly what an empty set would mean, and no other visit writes this
            // directory's own key (each relative path is visited at most once), so there is nothing
            // to clobber.
            if !skippedNames.isEmpty {
                skippedIndex[visit.relativePath] = skippedNames
            }

            // Admission pass: the survivors in their **final sibling order**, so the cut — when it
            // falls mid-directory — is deterministic and takes the alphabetically later entries, not
            // whatever order the volume listed.
            var admitted: [FileNode] = []
            // Capacity is the smaller of the listing and the REMAINING budget (review): reserving
            // the full listing size would allocate survivor-count slots even when the budget admits
            // none of them — a multi-million-entry directory visited with a spent budget would
            // reserve hundreds of MB it never touches.
            admitted.reserveCapacity(min(survivors.count, nodeBudget.map { max(0, $0 - nodeCount) } ?? survivors.count))
            for survivor in sorted(survivors) {
                if let nodeBudget, nodeCount >= nodeBudget {
                    // A classified survivor was refused: that, and only that, is what truncation
                    // means. Everything still on the frontier stays unvisited.
                    truncated = true
                    break
                }
                nodeCount += 1
                admitted.append(survivor)
                if survivor.isDirectory {
                    frontier.append((
                        survivor.url,
                        visit.relativePath.isEmpty ? survivor.name : visit.relativePath + "/" + survivor.name
                    ))
                }
            }
            childrenByPath[visit.relativePath] = admitted

            if truncated || cancelled { break visits }
        }

        // Assembly: every visited directory's children list is final, so the immutable tree is one
        // pure in-memory pass with no filesystem access at all. **Reverse visit order** is what makes
        // it a single pass and needs no recursion: BFS visits a parent strictly before any of its
        // children, so running the visits backwards finalizes every child directory before the parent
        // that has to embed it. A directory with no entry here — admitted but never visited (beyond
        // the cut, or still on the frontier when a cancelled walk unwound), or visited and unreadable
        // — assembles to `children: []`, the same empty-children shape the recursive walk produced
        // for an unreadable directory.
        var assembled: [String: [FileNode]] = [:]
        assembled.reserveCapacity(visitOrder.count)
        for relativePath in visitOrder.reversed() {
            // `removeValue` rather than a subscript read: it hands over the array's only reference, so
            // the `children` writes below mutate it in place instead of copying it.
            guard var children = childrenByPath.removeValue(forKey: relativePath) else { continue }
            for index in children.indices where children[index].isDirectory {
                let childPath = relativePath.isEmpty
                    ? children[index].name
                    : relativePath + "/" + children[index].name
                children[index].children = assembled[childPath] ?? []
            }
            assembled[relativePath] = children
        }

        return ScanOutcome(
            node: FileNode(
                url: standardized,
                name: standardized.lastPathComponent,
                isDirectory: true,
                children: assembled[""] ?? []
            ),
            skippedIndex: skippedIndex,
            unreadableDirs: unreadableDirs,
            budgetReport: TreeBudgetReport(nodeCount: nodeCount, truncated: truncated)
        )
    }

    /// Directories first, then files; each subgroup sorted with `localizedStandardCompare`
    /// (SPEC §5.2), e.g. `file2` before `file10`.
    private static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        let directories = nodes.filter { $0.isDirectory }
        let files = nodes.filter { !$0.isDirectory }
        let byName: (FileNode, FileNode) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return directories.sorted(by: byName) + files.sorted(by: byName)
    }

    /// (root-slash-prefix-match) Whether `path` names the same entry as `rootPath` or anything
    /// beneath it, by string comparison alone — no syscalls, because two callers run per-path
    /// inside FSEvents burst handling (`WorkspaceModel.handleTreeChange` / `isSkippedTreePath`)
    /// under a no-syscall-per-changed-path constraint. Both arguments must be absolute and
    /// consistently canonicalized (standardized, and realpath'd where the caller compares against
    /// FSEvents paths); equality counts as contained, which every call site wants.
    ///
    /// The containment prefix is `rootPath + "/"` — **except** when `rootPath` already ends in
    /// `"/"`, which among standardized absolute paths is exactly the filesystem root `"/"`:
    /// appending another slash there would build `"//"`, which no standardized path starts with,
    /// so a `/` root would contain nothing (the bug this helper exists to fix — previously this
    /// idiom was inlined at four `WorkspaceModel` sites, all wrong for a `/` root, silently).
    static func path(_ path: String, isContainedIn rootPath: String) -> Bool {
        if path == rootPath { return true }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }

    /// Every file under `self`, paired with its path relative to `self` — `self`'s own name is
    /// excluded from every path (callable directly on a root: yields `swift-source/main.swift`,
    /// never `FEdit/swift-source/main.swift`; a root-name leak would corrupt filter matching,
    /// e.g. a query for "fedit" matching every file under a root named FEdit). Depth-first order
    /// preserves the scanner's folders-first sort (filter-query §5.4).
    func filesWithRelativePaths() -> [(path: String, node: FileNode)] {
        var results: [(path: String, node: FileNode)] = []
        for child in children ?? [] {
            child.collect(prefix: "", into: &results)
        }
        return results
    }

    private func collect(prefix: String, into results: inout [(path: String, node: FileNode)]) {
        if isDirectory {
            for child in children ?? [] {
                child.collect(prefix: prefix + name + "/", into: &results)
            }
        } else {
            results.append((prefix + name, self))
        }
    }
}

/// (watcher-scan-skip-parity) What one walk decided to leave out of the tree — the durable half of a
/// `ScanOutcome`, stored per root by `RootScanScheduler` and consulted by `TreeSkipGate` inside
/// FSEvents bursts.
///
/// Lives in `FileNode.swift` rather than beside either consumer because **both** standalone harnesses
/// need it off a different compile line: `scripts/RootScanTests` builds `FileNode.swift` +
/// `RootScanScheduler.swift`, `scripts/TreeSkipGateTests` builds `FileNode.swift` +
/// `TreeSkipGate.swift`. It is produced here, so it is declared here.
///
/// Size is negligible in practice (non-dot hidden entries and unreadable directories are rare), and
/// it is bounded by the same walk the tree is.
struct SkipRecord: Sendable, Equatable {
    /// Directory relative path (`""` = the scanned root) → the names that directory's listing
    /// skipped, **excluding** dot-prefixed names. Keys and names are relative and built from path
    /// components, never from absolute-path arithmetic, so they are comparable against components the
    /// gate derives from an FSEvents path without any standardized-vs-canonical rebase.
    var skippedIndex: [String: Set<String>] = [:]

    /// Relative paths (`""` = the scanned root) of directories whose listing threw — the tree shows
    /// them empty, so nothing beneath them can be surfaced by a rescan until they become readable
    /// again.
    ///
    /// Recorded for **observability**; it is deliberately **not** consulted by `TreeSkipGate`, and —
    /// recorded honestly — still renders nowhere: (tree-node-budget) shipped the narrow
    /// `TreeBudgetReport` its notice actually needs rather than the full per-root scan-outcome
    /// taxonomy, so this half remains produced-but-unconsumed. Gating on it would
    /// be permanent: a probe (2026-08-11) established that a TCC grant fires no filesystem event at
    /// all, and that writing inside a directory never delivers that directory's own path — so no
    /// event can announce that an unreadable directory became readable, and an entry here would turn
    /// its whole subtree (worst case the key `""`, a denied root) into an auto-refresh black hole
    /// that never reopens. Events under an unreadable subtree therefore keep driving damped rescans,
    /// which is what makes recovery automatic. See `TreeSkipGate.isSkipped(belowRootComponents:record:)`.
    var unreadableDirs: Set<String> = []
}

/// (tree-node-budget) What one walk's node budget did: how many nodes it built, and whether it
/// refused any. **One named value carried unchanged through every seam** — `ScanOutcome` →
/// `WalkResult` → `RootScan.lastReport` → the model's landing seam → the sidebar's notice — rather
/// than three shapes for one datum decomposed and recomposed along the way.
///
/// Lives in `FileNode.swift` for the same compile-line reason as `SkipRecord`: it is produced by the
/// walk, and `scripts/RootScanTests` builds `FileNode.swift` + `RootScanScheduler.swift` while
/// `scripts/FileNodeTests` builds `FileNode.swift` alone.
///
/// `Equatable` so the harnesses can assert a report reached a seam **verbatim** rather than
/// field-by-field; `Sendable` because it rides back from the scan queue inside the `ScanOutcome`.
struct TreeBudgetReport: Sendable, Equatable {
    /// Nodes actually built, excluding the root node itself: `min(nodeBudget, total)` for a walk that
    /// ran to completion. This is the number the sidebar's truncation notice shows, carried from the
    /// walk that measured it — never recomputed by counting the delivered tree.
    var nodeCount: Int

    /// Whether the budget **refused** at least one classified survivor. Deliberately not
    /// `nodeCount == nodeBudget`: a tree whose size exactly equals the budget is complete, and an
    /// empty root under a budget of 0 is complete too.
    var truncated: Bool
}

/// (watcher-scan-skip-parity) One walk's full result: the tree plus the verdicts that produced it.
/// `Sendable` for the same reason `FileNode` is — the walk runs on `RootScanScheduler.scanQueue` and
/// this value is handed back to the main actor whole.
struct ScanOutcome: Sendable {
    var node: FileNode
    var skippedIndex: [String: Set<String>]
    var unreadableDirs: Set<String>

    /// (tree-node-budget) What the node budget did to this walk. Deliberately not defaulted: every
    /// construction site must state it, and there is exactly one (the walk itself).
    var budgetReport: TreeBudgetReport

    /// The durable half, for the scheduler to store per root. A plain regrouping of the two fields
    /// above — no recomputation, no second walk.
    var skipRecord: SkipRecord {
        SkipRecord(skippedIndex: skippedIndex, unreadableDirs: unreadableDirs)
    }
}

/// (async-root-scan, Tier 2) The **only** cross-thread mutable state the asynchronous scan
/// introduces: a one-way "stop walking" flag, set on the main actor by
/// `RootScanScheduler.noteRootRemoved` — or, at window teardown, from the scheduler's nonisolated
/// token registry `deinit` (root-scan-consolidation) — and read on the scan queue once per directory
/// entry.
///
/// `NSLock` rather than `os_unfair_lock`/`Synchronization`'s `Atomic` for one concrete reason:
/// `FileNode.swift` must keep compiling against **Foundation alone**, because
/// `scripts/FileNodeTests` (and `scripts/RootScanTests`) build it standalone with `swiftc`. One-way
/// by construction — there is no `uncancel()` — so a walk can never observe cancellation
/// un-happening mid-unwind, and the flag needs no generation of its own (`RootScanScheduler`
/// allocates a fresh token per job).
final class ScanCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
