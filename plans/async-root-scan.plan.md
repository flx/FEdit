# (async-root-scan) Move the recursive root scan off the main thread — implementation plan

Revision 1 — 2026-08-11. Planned against the code in this worktree (branch
`worktree-kind-snuggling-storm`, HEAD `80609b5`), not against the TODO text. See
"Where the item's description stands" below.

**Revision 2 — 2026-08-11, post adversarial plan review (verdict REVISE). Where the
`## Revision 2` section at the end of this file conflicts with anything above it, Revision 2
governs.** Headline changes: the scan queue is a shared *concurrent* queue (the review showed the
serial queue head-of-line-blocks every other root and silently regresses `createFile` latency);
rescan damping moves INTO Tier 1 (the storm hypothesis is now experimentally CONFIRMED, so Tier 1
without damping burns a core forever on a `$HOME` root); Tier 3a (skip-predicate parity) and
Tier 4 (node budget) are cut from this item and filed as separate TODO items; per-root generation
counters close the remove-then-re-add splice hole.

## Risk tier

**hi** — this converts the single synchronous producer of `WorkspaceModel.roots` into a
cross-thread producer, and `roots` is read by four independent flows that were all written on the
assumption that a scan is atomic with respect to them (the FSEvents tree watcher's rescan gate, the
git-badge coalescer, session snapshot/restore, and the `(cli-open)` token invariant's
`roots.isEmpty` pristine test). Every one of those is a correctness seam, not a cosmetic one: get
the pristine test wrong and a CLI open can overwrite a restored window — the exact defect
`(cli-open)` needed two adversarial review rounds to close.

## Where the item's description stands (checked against source)

The TODO text is **accurate** on every checkable claim:

- `FileNode.scan(directory:)` is at `FEdit/Models/FileNode.swift:45`, synchronous and recursive,
  with the "Synchronous on the calling thread per SPEC §11" doc comment intact.
- `WorkspaceModel.addFolders` is at `FEdit/Models/WorkspaceModel.swift:270` and calls
  `FileNode.scan` inline at line 283; `restore(fromJSON:)` is at line 988 and calls `addFolders` at
  line 996. The `restore → addFolders → FileNode.scan` chain named in the TODO is real and runs on
  the main actor.
- SPEC §11 does explicitly accept it ("scan is recursive and synchronous in v1 — acceptable …
  If it proves slow, move scan off the main thread — behavior otherwise unchanged"), and
  `plans/cli-open.plan.md` D9 accepted it again for `fedit ~/notes.md`.
- The only two `FileNode.scan` call sites in the app target are
  `WorkspaceModel.addFolders:283` and `WorkspaceModel.refreshAll:326`. A third caller,
  `scripts/FileNodeTests/main.swift:126`, is the standalone harness.

Three things the TODO does **not** say that the plan has to account for:

1. **Async alone does not satisfy SPEC §1.** A home-scale root that took 135 s to walk produces a
   tree of hundreds of thousands of `FileNode` values held live in `@Published roots`. SPEC §1's
   headline is "working set well under 100 MB". Moving the walk off-main converts a 135 s freeze
   into a responsive window that then holds a tree far past that budget and hands it to
   `OutlineGroup`. The TODO offers "or bound its depth/count" as an *alternative*; this plan treats
   the bound as a **separate, additionally-needed** tier (Tier 4), not an alternative.
2. **`SidebarView.flatRows` walks the whole tree on the main thread per render**
   (`SidebarView.swift:80`: `root.filesWithRelativePaths().filter { query.matches($0.path) }`,
   computed inline in `body`). Today that cost is invisible because a tree that large can't be
   reached without first sitting through the freeze. After Tier 1 it is reachable, and every
   keystroke in the filter field pays an O(N) walk plus O(N) string building on the main thread.
   Tier 4's node budget bounds it; making it incremental or cached is out of scope (see below).
3. **Suspected watcher/scanner skip-gate divergence.** `FileNode.scanChildren` passes
   `.skipsHiddenFiles` to `contentsOfDirectory` (FileNode.swift:58), which excludes both
   dot-prefixed names *and* entries carrying the `UF_HIDDEN` flag — `~/Library` is hidden by that
   flag, not by a dot. `WorkspaceModel.isSkippedTreePath` (WorkspaceModel.swift:452) mirrors only
   the dot-prefix half, despite its doc claiming it "mirror[s] `FileNode`'s scan skip rules … so
   the watcher's notion of 'interesting' matches exactly what a rescan surfaces." If that reading is
   right, a `$HOME` root means every `~/Library/Caches` write survives the gate and calls
   `refreshAll()`. Today that is a 135 s freeze *per event* — which is very likely part of what the
   `(cli-open)` verification actually observed. After Tier 1 it becomes a permanent background scan
   loop. **This is a hypothesis, not a verified fact** — Tier 3 opens with the measurement that
   decides whether it needs building at all.

## Goal

No user action can block the main thread on a directory walk. Specifically: launching into a
restored home-scale root, `fedit ~/notes.md`, picking `~` in the Open Folder… panel, or a
watcher-driven rescan of a huge root all leave the window interactive — menus open, the filter
field types, the editor scrolls, a CLI open lands — while the tree fills in behind them.

Everything else stays as it is: the same skip rules, the same folders-first
`localizedStandardCompare` order, the same selection/open/dirty/autosave semantics, the same
session snapshot format, the same `(cli-open)` token invariant.

## Threading contract after the change (state this in code comments too)

- **`FileNode` is an immutable value type** — stored properties are `URL`, `String`, `Bool`,
  `[FileNode]?`, all value types, no reference payload, no lazily-computed cache. Tier 1 marks it
  `Sendable` explicitly. Values are freely copyable across threads.
- **The authoritative tree stays main-actor-owned**, exactly as today: `WorkspaceModel.roots` is
  `@Published` on a `@MainActor` class and is the *only* long-lived store of a tree in the app.
  Nothing else retains one.
- **`FileNode.scan(directory:)` is `nonisolated` and pure with respect to app state.** It reads the
  filesystem and returns a fresh value; it has no reference to `WorkspaceModel`, so it can neither
  observe nor mutate main-actor state. A scan in flight owns a private local tree that no other
  thread can see until it is handed back.
- **It runs on `WorkspaceModel.scanQueue`**, a per-window dedicated serial `DispatchQueue(label:
  "com.fedit.tree-scan")` — deliberately **not** the Swift cooperative pool, for the same reason
  `gitQueue` exists (see `GitStatus`'s type doc): `contentsOfDirectory` is a blocking syscall and
  must not park a cooperative worker for minutes. Serial ⇒ at most one directory walk per window at
  a time.
- **The bridge is `Task { … await withCheckedContinuation { scanQueue.async { … } } }` started on
  the main actor** — the identical shape `scheduleGitRefresh` already uses
  (WorkspaceModel.swift:362–372), including capturing the queue strongly so a deallocated window
  can never strand an unresumed continuation, and `[weak self]` so a closed window's model is
  neither kept alive nor written.
- **The only cross-thread mutable state introduced** is Tier 2's cancellation token: a `final
  class` with an `NSLock`-guarded `Bool`, written on the main actor, read on the scan queue. Tier 1
  introduces none at all.

### How in-flight scans interact with the other flows

| Event during an in-flight scan of root `U` | Behavior |
|---|---|
| `removeRoot(U)` | Returns immediately. `roots` loses `U` at once. When the scan lands, the splice does `roots.firstIndex(where: { $0.url == U })`, finds nothing, and **drops the result**. The section never reappears. Tier 2 additionally cancels the walk. |
| `refreshAll()` / `refreshAll(force:)` | `U` is already in `scanningRootURLs`, so no second job is enqueued; `rescanRequested.insert(U)` and the running job re-runs **exactly once** on completion. Mirrors `isRecomputing`/`recomputeAgain`. |
| FSEvents batch survives `handleTreeChange`'s gate | Same path as `refreshAll()` — collapses into the single pending re-run. FSEvents' own 0.3 s latency batching is upstream of this and unchanged. |
| `addFolders([U])` again | Unchanged no-op: the resolved-path duplicate check (WorkspaceModel.swift:271–281) runs *before* the placeholder append, so a duplicate never reaches the scan path. |
| `addFolders([V])`, a different root | Independent per-root job. Because `scanQueue` is serial, `V` waits behind `U`'s walk; Tier 2's cancellation is what keeps that from being a multi-minute stall after a `removeRoot(U)`. |
| `scheduleGitRefresh()` | Untouched. It reads `roots.map(\.url)` only, and the placeholder carries the correct URL from the moment `addFolders` returns. |
| Window closes / `WorkspaceModel` deinit | `[weak self]` in the `Task`; the continuation captures `scanQueue` strongly. The walk finishes (Tier 1) or is cancelled (Tier 2) and its result is discarded. |

### Selection, opens, and CLI opens while a scan is pending

None of them depend on the tree, and Tier 1 must not make them depend on it:

- `selectedFileURL` is a record with zero side effects at the model layer (its own doc comment is
  explicit about this). Setting it while a scan is pending is inert.
- `requestOpen` → `resolveDirtyFile` → `loadFile` → `loadText(from:)` reads the file straight from
  disk and **never consults `roots`**. Sidebar taps, `openPendingNewFileIfNeeded()`, `restore`'s
  `silentlyLoadFile`, and `ContentView.applyCLITokenIfNeeded`'s `requestOpen(file)` are therefore
  all unaffected: the editor shows the file immediately, whether or not the sidebar has finished.
- The only visible consequence: the file's **row** — and therefore its selection highlight
  (`FileRow.isSelected`, keyed on `node.url == workspace.selectedFileURL`) — appears when the scan
  lands, not before. That is the intended, documented behavior, and it is what A4 measures.
- `removeRoot`'s selection-clearing branch compares `selectedFileURL.path` against `root.url.path`
  as strings, not against the tree, so it is correct on a placeholder root.
- The vnode `fileWatcher`, `lastWriteSignature`, autosave, and the dirty guard never touch `roots`
  and are not modified by any tier here.

## Acceptance criteria

There is no XCTest target (SPEC §13), so: **[UNIT]** = standalone `swiftc` harness under
`scripts/`; **[CLI]** = scripted command + assertion on its output; **[GUI]** = a human at the
screen; **[GUI, timed]** = stopwatch on a stated wall-clock bound.

Fixtures: `SMALL=/tmp/fedit-scan-small` (≈200 files, 3 levels, made by a shell loop);
`BIG=$HOME` (the real thing — the 135 s case). `printf '# Hi\n' > $HOME/fedit-async-probe.md`.

1. **Home-scale root does not block launch.** Save a session whose sole root is `$HOME`, quit,
   relaunch. Within **2 s** the window is on screen, its section header shows `~`, and the sidebar
   body shows `Scanning…`. While it is still scanning: the File menu opens, typing into the filter
   field echoes with no perceptible lag, and Cmd+O opens a second window. [GUI, timed]
2. **The main thread is provably not scanning.** During (1), run
   `sample FEdit 5 -file /tmp/fedit-scan.sample`. Assert: the thread block whose header contains
   `com.apple.main-thread` contains **no** `scanChildren`, `FileNode.scan`, or
   `contentsOfDirectory` frame; and some thread block whose header contains
   `com.fedit.tree-scan` **does**. [CLI]
3. **Baseline was reproducible.** Before Tier 1, run (2) on the current build and record the
   opposite result (main thread *in* `scanChildren`) plus the wall-clock freeze duration, in
   DONE.md. Without this the fix has no before/after. [CLI, run first]
4. **CLI open is not blocked by a pending scan.** With FEdit not running,
   `fedit $HOME/fedit-async-probe.md`. The editor shows the file's text within **3 s** while the
   sidebar still reads `Scanning…`; the preview column is present (it is `.md`). When the scan
   completes, the `fedit-async-probe.md` row appears and is highlighted. [GUI, timed]
5. **The pure scanner is byte-for-byte unchanged in behavior.** `swiftc FEdit/Models/FileNode.swift
   scripts/FileNodeTests/main.swift -o /tmp/fntests && /tmp/fntests` → the existing assertions pass
   unmodified (skip rules, symlink-as-leaf, unreadable-directory, folders-first
   `localizedStandardCompare` order, `children` optionality). No assertion is edited or deleted in
   Tier 1. [UNIT]
6. **Small roots show no regression.** Add `$SMALL` via Add Folder to Window…. The full tree is on
   screen within **300 ms**; the `Scanning…` state is either not observed or gone within that
   bound. Sidebar contents, order, and skip behavior match a screenshot taken from the pre-change
   build of the same fixture. [GUI, timed]
7. **`removeRoot` during a scan is immediate and final.** Add `$HOME`, then immediately
   Remove from Sidebar. The section disappears at once (< 100 ms). Wait 180 s: the section does
   **not** reappear, and no other root's contents change. Repeat 3×. [GUI]
8. **Refresh storm does not stack jobs.** With `$HOME` scanning, hit the header context menu's
   Refresh 10× in 5 s. `sample FEdit 5` shows **at most one** thread block labelled
   `com.fedit.tree-scan`. The tree updates once, and correctly, at the end. [GUI + CLI]
9. **Watcher storm does not stack jobs.** With `$SMALL` as a root, run
   `for i in $(seq 1 300); do touch $SMALL/f$i; done`. Same `sample` assertion as (8); afterwards
   the sidebar lists all 300 new files. [GUI + CLI]
10. **Selection and dirty-switch semantics are unchanged with a scan pending.** With `$HOME`
    scanning and `$SMALL` also open: click a `$SMALL` file, type into it (subtitle reads `Edited`),
    click a different `$SMALL` file → the first is autosaved and the switch proceeds, exactly as
    today. [GUI]
11. **Session snapshot is correct mid-scan.** Quit while `$HOME` is still scanning; relaunch. The
    same root(s) and open file return. (`currentSnapshot` reads only `roots.map { $0.url.path }`,
    so the placeholder must round-trip identically to a scanned root.) [GUI]
12. **File → New… still works during a scan.** With `$SMALL` open and `$HOME` scanning, File → New…
    → `newfile.txt`. The file is created and opens in the editor **immediately**; its row appears in
    `$SMALL` within 1 s. [GUI, timed]
13. **`(cli-open)`'s token invariant is intact.** Re-run `plans/cli-open.plan.md` A7 verbatim: save
    a two-window session with different roots and files, quit, then `fedit $SMALL/a.md` from cold.
    Both restored windows return with their own roots/files/cursors, plus the CLI window. **Repeat
    5×, zero occurrences** of a restored window showing `$SMALL`. This is the criterion the
    placeholder-root decision (L3) exists to protect. [GUI, repeated]
14. **(Tier 2) A cancelled scan actually stops.** After (7)'s Remove from Sidebar, wait 5 s then run
    `sample FEdit 5`. No thread block contains a `scanChildren` frame. [CLI]
15. **(Tier 2) Cancellation does not corrupt a surviving root.** With `$HOME` and `$SMALL` both
    open and both scanning, remove `$HOME`. `$SMALL`'s tree completes and is correct (spot-check 10
    known paths incl. one nested three levels deep). [GUI]
16. **(Tier 3, gate) Idle home root does not rescan.** With `$HOME` as the sole root and the app
    idle and unfocused for 10 minutes, run `sample FEdit 10` three times at 3-minute intervals. No
    `scanChildren` frames in any of them. **If the pre-Tier-3 measurement shows frames, Tier 3 is
    required; if it does not, Tier 3's hidden-flag half is descoped** and only the debounce ships.
    [CLI]
17. **(Tier 3) Skip predicate parity is unit-tested.** The hoisted `FileNode`-owned skip predicate
    is asserted in `scripts/FileNodeTests` against a fixture containing: a dot-prefixed dir, a
    `chflags hidden` dir, `node_modules`, `DerivedData`, a root that itself lives under a hidden
    ancestor (must not be filtered out wholesale), and a plain file named `node_modules`. Every
    case must give the same answer as an actual `FileNode.scan` of the same fixture. [UNIT]
18. **(Tier 4) The tree is bounded.** With `$HOME` as root, after the scan settles: Activity
    Monitor's memory for FEdit is **under 250 MB** (a stated, checkable number, not "well under
    100 MB" — a home root will not hit SPEC §1's ideal, and Tier 4's job is to make it bounded and
    survivable, not ideal). The sidebar shows a truncation note on that root's section. [GUI]
19. **(Tier 4) Truncation is deterministic.** Scan the same unchanged big root twice (Refresh). The
    two trees are identical — i.e. the second Refresh does **not** republish under the non-`force`
    diff-guard, verified by the sidebar's scroll position not resetting. [GUI]
20. **(Tier 4) Truncation does not affect ordinary roots.** `$SMALL` and the FEdit repo itself show
    no truncation note and complete trees; `scripts/FileNodeTests` passes with the budget-taking
    overload as well as without. [UNIT + GUI]
21. **Build is clean.** `xcodebuild` Debug build produces no new warnings — in particular no
    `Sendable`/actor-isolation warnings from the new queue hop. (Run by the orchestrator, not by
    the implementer.) [CLI]
22. **All harnesses still pass.** The eight existing `scripts/` harnesses run green with zero
    failures (430 assertions at HEAD per DONE.md), plus whatever Tier 3/4 add. [UNIT]

## Implementation tiers

**The single seam across all four tiers is `WorkspaceModel.requestScan(of:)` plus `FileNode.scan`'s
parameter list.** Tier 1 must ensure `FileNode.scan` is called from exactly one place in the app
target (`requestScan`), so Tiers 2 and 4 each have one call site to change and Tier 3 touches none.

### Tier 1 — Move the scan off the main thread (the fix)

**`FEdit/Models/FileNode.swift`** — minimal: add `Sendable` to the declaration, and rewrite the
`scan` doc comment's "Synchronous on the calling thread per SPEC §11" paragraph to state the new
contract (pure, `nonisolated`, called only from `WorkspaceModel.requestScan` on `scanQueue`; still
synchronous *within* its own thread). The scan body itself does not change — that is what keeps
criterion 5 meaningful.

**`FEdit/Models/WorkspaceModel.swift`** — the whole of the work:

```swift
/// Dedicated serial queue — the ONLY place the blocking recursive directory walk runs. Serial ⇒
/// one walk per window at a time. NOT the Swift cooperative pool, for the same reason `gitQueue`
/// isn't: `contentsOfDirectory` is a blocking syscall and must not park a cooperative worker.
private let scanQueue = DispatchQueue(label: "com.fedit.tree-scan")

/// Roots with a walk in flight. Drives SidebarView's "Scanning…" state AND the coalescing gate.
@Published private(set) var scanningRootURLs: Set<URL> = []

/// Roots superseded while in flight — re-run exactly once on completion. Mirrors
/// `isRecomputing`/`recomputeAgain`, deliberately: a walk cannot be interrupted in Tier 1, so
/// cancellation-based coalescing is not used.
private var rescanRequested: Set<URL> = []

/// The one entry point. Every scan in the app goes through here.
private func requestScan(of url: URL, force: Bool = false)
```

`requestScan(of:force:)`, in order: if `scanningRootURLs.contains(url)` → `rescanRequested.insert(url)`
(carrying `force` forward as a separate `forcedRescans: Set<URL>` if `force` was set) and return;
otherwise insert into `scanningRootURLs`, capture `let old = roots.first { $0.url == url }`, and
start the `Task`/`withCheckedContinuation`/`scanQueue.async` chain. The background block computes
`let new = FileNode.scan(directory: url)` **and** `let changed = (new != old)` — the deep
`Equatable` walk moves off-main with the scan, which matters: today `refreshAll`'s
`rescanned != roots` compare is itself an O(N) main-thread cost on every watcher event. On the main
actor afterwards: remove from `scanningRootURLs`; `guard let idx = roots.firstIndex(where: { $0.url
== url })` (a `removeRoot` mid-flight drops the result here); `if force || changed { roots[idx] =
new }`; then `scheduleGitRefresh()`; then, if `rescanRequested.remove(url) != nil`,
`requestScan(of: url, force: <carried>)` once.

Capturing `old` at job start is sound because `roots[idx]`'s *children* can only change through a
scan apply, and the `scanningRootURLs` gate guarantees at most one in flight per root.

`addFolders(_:)` — everything up to and including the duplicate check is unchanged. Line 283
becomes: append a **placeholder** `FileNode(url: standardized, name: standardized.lastPathComponent,
isDirectory: true, children: [])` and record the URL for a `requestScan` after the loop. The
`treeWatcher.watch(roots:)` re-point and `scheduleGitRefresh()` at the end are unchanged and now run
with correct URLs immediately.

`refreshAll(force:)` — becomes `for root in roots { requestScan(of: root.url, force: force) }`
followed by the existing unconditional `scheduleGitRefresh()`. Its doc comment's "Republishes
`roots` only when the rescanned structure actually differs" contract is preserved, moved into
`requestScan`. Callers (`handleTreeChange:443`, `SidebarView:116`, `createFile:934`) are unchanged
at their call sites; the doc comment must gain an explicit "returns before the rescan completes"
sentence.

`removeRoot(_:)` — unchanged code; gains a comment stating that an in-flight scan's result is
dropped by the index lookup in `requestScan`'s apply block.

`deinit` — no new cleanup needed in Tier 1 (`[weak self]` + strongly-captured queue).

**`FEdit/Views/SidebarView.swift`** — the `Scanning…` affordance, in both modes:

- tree mode (line 47): when `workspace.scanningRootURLs.contains(root.url)` **and**
  `(root.children ?? []).isEmpty`, render `Text("Scanning…").foregroundStyle(.secondary)` instead of
  the `OutlineGroup`. The `&& isEmpty` is what stops a *refresh* of an already-populated root from
  blanking it.
- filter mode (`flatRows`, line 79–89): when the root is scanning, show `Scanning…` rather than
  `No matches`, so an incomplete tree is never misreported as "this file doesn't exist".

**`SPEC.md`** — §11's "Folder with thousands of files" bullet is rewritten: the scan is recursive
and runs off the main thread on a dedicated per-window serial queue; the window is interactive while
it runs; a root being scanned shows a `Scanning…` placeholder; adding, removing, refreshing and
opening files are all available during a scan; an in-flight scan for a removed root is discarded.
§5.2's "Recursive scan at add-time and on Refresh" bullet gains "…asynchronously; the sidebar shows
`Scanning…` until it lands".

*Verification:* criteria 1–13, 21, 22. Criterion 3 (the baseline `sample`) must be captured
**before** any edit.

*Revert:* `git revert` the tier's single commit. `FileNode.swift` returns to its current text
(only a conformance and a doc paragraph changed), `WorkspaceModel`'s two call sites return to
inline `FileNode.scan`, `SidebarView` loses two branches, SPEC.md reverts. Nothing persisted
changes format, no file is added or deleted, no other component's contract moves.

*Pays off alone:* **yes** — this alone removes the 135 s main-thread block, which is the filed
defect. Tiers 2–4 are bounding and hygiene on top of it.

*Interface handed to later tiers:* `requestScan(of:force:)` as the sole `FileNode.scan` call site;
`scanningRootURLs` as the sole published scan-state.

### Tier 2 — Cooperative cancellation of superseded and removed-root scans

**`FEdit/Models/FileNode.swift`** — a small `final class ScanCancellationToken` (an `NSLock`-guarded
`Bool` — `NSLock` rather than `os`/`Synchronization` so the standalone `swiftc` harness still
compiles the file with Foundation alone), and a `scan(directory:cancellation:)` overload whose
`scanChildren` loop checks `cancellation?.isCancelled == true` once per directory entry (cheap
relative to the existing per-entry `resourceValues` syscall) and unwinds by returning what it has.
The existing no-argument `scan(directory:)` remains and is the harness's entry point, so criterion 5
is untouched.

**`FEdit/Models/WorkspaceModel.swift`** — `private var scanTokens: [URL: ScanCancellationToken]`
beside the Tier 1 bookkeeping. `requestScan` creates and stores a token per job and clears it on
apply; `removeRoot` cancels the removed root's token; `deinit` cancels all of them. A cancelled
scan's partial result is discarded by the same index/`scanningRootURLs` checks Tier 1 already has —
cancellation never needs to produce a usable tree.

*Verification:* criteria 14, 15, plus a re-run of 5 and 22.

*Revert:* delete the token type and the overload, drop the `scanTokens` dictionary and its three
call sites. Tier 1's "run to completion, drop the result" behavior returns.

*Pays off alone:* **partially.** Without it, correctness is already fine (results are dropped), but a
removed home-scale root keeps a background thread walking for minutes and — because `scanQueue` is
serial — delays every subsequent scan in that window behind it. Worth building, not worth blocking
Tier 1 on.

*Interface:* touches only `requestScan`'s body and `removeRoot`/`deinit`. Adds one optional
parameter to `FileNode.scan`.

### Tier 3 — Stop the rescan storm (gated on a measurement)

**Gate first.** On the Tier-1 build, run criterion 16's measurement with `$HOME` as the sole root.
If the app is genuinely idle (no `scanChildren` frames over 10 minutes), **skip 3a and build only
3b**; record the negative result in the plan and DONE.md.

**3a — skip-predicate parity.** Hoist the skip rule out of `WorkspaceModel.isSkippedTreePath` into
`FileNode` as a static, so scanner and watcher gate share one definition (today they are two
hand-synced copies whose divergence is exactly the suspected bug). The hoisted predicate must cover
the `UF_HIDDEN` half as well as the dot-prefix half; because the gate must not `realpath`/`stat`
thousands of FSEvents paths (`handleTreeChange`'s comment is explicit and correct about that), the
hidden check is applied only to the **directory components between the containing root and the
leaf**, memoized in a `[String: Bool]` dictionary scoped to a single batch — so a 5000-path
`npm install` batch costs a handful of `resourceValues(forKeys: [.isHiddenKey])` calls, not 5000.

**3b — rescan damping.** A minimum interval between watcher-driven rescans of the same root (Tier
1's coalescing already collapses a burst; this bounds a *sustained* drip), with exponential backoff
when consecutive rescans come back structurally unchanged (1 s → 30 s), reset by any real structural
change or by an explicit `refreshAll(force: true)`. Explicit user Refresh is never damped.

*Verification:* criteria 16, 17, 9, 22.

*Revert:* 3a — restore `isSkippedTreePath`'s body and delete the `FileNode` static (and its harness
assertions). 3b — delete the interval/backoff fields and the guard in front of `requestScan`.
Independent of each other and of Tiers 2/4.

*Pays off alone:* **only on top of Tier 1.** On the current synchronous build, 3a would already be a
real improvement (it removes 135 s freezes triggered by `~/Library` churn), so if Tier 1 slips, 3a
is the highest-value thing to land alone.

*Interface:* 3a touches `FileNode` (new static) and `WorkspaceModel.isSkippedTreePath` only.
3b sits entirely in front of `requestScan` and touches nothing else.

### Tier 4 — Bound the tree (memory and per-render cost)

**`FEdit/Models/FileNode.swift`** — `static let maxScannedNodes = 50_000` (a starting number; tune
against a `footprint FEdit` measurement of bytes-per-node on the `$HOME` fixture) and a
`scan(directory:limit:)` overload carrying a shared descending counter through the DFS. When the
budget is exhausted the walk stops adding and reports truncation; because the walk is depth-first
over a `contentsOfDirectory` listing that is then sorted deterministically, the truncated tree is a
deterministic function of the directory state (criterion 19 checks this). No depth cap — depth is
not the failure mode here, and the existing symlink-as-leaf rule already prevents cycles.

**`FEdit/Models/WorkspaceModel.swift`** — `@Published private(set) var truncatedRootURLs: Set<URL>`,
set in `requestScan`'s apply block.

**`FEdit/Views/SidebarView.swift`** — a muted note in the affected section, e.g.
`Showing the first 50,000 items — this folder is too large to list in full`, so a missing file is
explained rather than mysterious.

**`SPEC.md` §5.2 + §11, `README.md`** — document the cap and its number. README's line 52 (the
`fedit ~/notes.md` scans-your-home-directory paragraph) is rewritten: the scan is off-main and
capped, so the invocation is no longer a freeze — replacing text that Tier 1 has already made
partly false.

*Verification:* criteria 18, 19, 20, 22.

*Revert:* delete the `limit:` overload, the constant, the published set and the sidebar note; revert
the two doc files. Tier 1–3 behavior is unaffected.

*Pays off alone:* **yes, as a partial mitigation, but at a behavioral cost.** A 50k budget alone
would cut the current synchronous freeze to roughly a second — but it does so by silently showing an
incomplete tree, which is a worse trade than Tier 1's. Build it as the memory/CPU guard it is, on
top of Tier 1, not as a substitute.

*Interface:* one optional parameter on `FileNode.scan`, one published set read by `SidebarView`.

## Load-bearing assumptions

**L1 — `FileNode` is a pure immutable value type with no reference payload, so a tree built off-main
can be handed to the main actor by value.** Verified in this worktree: stored properties are `URL`,
`String`, `Bool`, `[FileNode]?`. *If false* (someone adds a class-typed field or a lazily-populated
cache): the splice becomes a data race that strict concurrency will not catch under Swift 5 minimal
checking. *Rewrite:* small — make the payload `Sendable` or deep-copy at the hop. But the failure
mode is a silent intermittent crash, so this is the assumption to re-check on every future
`FileNode` field addition; say so in the type's doc comment.

**L2 — `WorkspaceModel.roots` is the only long-lived store of a tree, and no caller needs the tree
to be complete before it returns.** Verified by grep: readers are `SidebarView` (tree + filter),
`ContentView`'s header strip (root last-path-components), `currentSnapshot` (root *paths* only),
`newFileTargetDirectory` (`roots.first?.url`), `scheduleGitRefresh` (root URLs), `removeRoot`,
`handleTreeChange` (root URLs). *If false* — some path assumes a complete tree synchronously — that
path needs a completion callback or a "scan settled" published flag. *Rewrite:* small and localized,
one call site.

**L3 — Appending the root as a placeholder *synchronously* keeps every existing "is this window
pristine?" test meaning what it means today.** There are five such tests, all reading
`workspace.roots.isEmpty`: `restore(fromJSON:)`'s own guard (WorkspaceModel.swift:989), the Cmd+O
mailbox drain (ContentView.swift:217), the late-`@SceneStorage` recovery (ContentView.swift:239),
and `applyCLITokenIfNeeded`'s two checks (ContentView.swift:288 and :294 — deliberately duplicated
across the `DispatchQueue.main.async` boundary). *If false* — i.e. if `addFolders` is made fully
async so `roots` stays empty until the walk lands — then a restored window is "pristine" for the
whole duration of its own restore, and a CLI token or a late snapshot can be applied on top of it.
That is precisely the class of defect `plans/cli-open.plan.md` Revisions 2/3 were written to close
(both first verdicts DO NOT SHIP). **This is the plan's single most load-bearing decision.**
*Rewrite if violated:* large — a separate `isSettling`/`hasClaimed` flag on `WorkspaceModel`, and
the `(cli-open)` three-layer token invariant re-argued and re-verified (A13 5×). Do not "simplify"
the placeholder away.

**L4 — A blocking `contentsOfDirectory` walk must not run on the Swift cooperative pool.**
Precedent: `GitStatus`'s type doc and `WorkspaceModel.gitQueue`'s comment, both explicit. *If
false* (the pool would in fact have been fine), the dedicated queue is merely unnecessary — no
rewrite, just slightly more code than needed. Cheap insurance; the asymmetry favors the queue.

**L5 — FSEvents-driven rescans of a home-scale root are not already storming.** *If false* (the
`~/Library` `UF_HIDDEN` divergence described above), Tier 1 alone turns a periodic multi-minute
freeze into a permanent background scan loop: the UI is responsive, but the machine burns a core and
the battery. Tier 3 exists for this and is **gated on criterion 16's measurement** rather than
assumed. *Rewrite if the hypothesis holds and the memoized `isHidden` check proves too slow in a
big batch:* fall back to 3b's backoff alone, ~20 lines, no interface change.

**L6 — `.skipsHiddenFiles` excludes `UF_HIDDEN` entries and not merely dot-prefixed names.** This
is the mechanism behind L5. *If false*, `~/Library` is walked by the scanner too, the gate is
actually consistent, 3a is unnecessary — and the 135 s figure is explained by raw volume rather than
by a rescan loop. Either way Tier 1 is correct; only Tier 3a's justification changes. Verify
cheaply, before building 3a, by checking whether `~/Library` appears in the sidebar under a `$HOME`
root on the current build.

**L7 — `OutlineGroup` tolerates a root whose `children` is `[]` and later becomes populated**,
without crashing or disturbing other roots' disclosure state. *If false:* the placeholder must
instead be rendered from a separate branch in `SidebarView` (the section renders `Scanning…` and the
`OutlineGroup` is not constructed at all until children arrive) — which the Tier 1 design already
does when `children` is empty, so the fallback is to make that branch unconditional on scan state.
*Rewrite:* small, `SidebarView` only.

**L8 — `refreshAll(force:)`'s synchronous return is not depended on by any caller.** Verified: three
callers. `handleTreeChange:443` is fire-and-forget. `SidebarView:116` is fire-and-forget.
`createFile:934` calls it and then stashes `pendingNewFileURL`; the subsequent open runs through
`requestOpen`, which does not consult the tree — so SPEC §5.2's "appears after the automatic refresh
that creation triggers" still holds, just a beat later. *If false:* that caller needs a completion
handler. *Rewrite:* small, one call site (criterion 12 is the check).

**L9 — Swift 5 language mode with default (minimal) strict-concurrency checking means adding
`Sendable` and a queue hop introduces no new diagnostics elsewhere.** Verified: `SWIFT_VERSION =
5.0` in both target configs, no `SWIFT_STRICT_CONCURRENCY` setting present, `MACOSX_DEPLOYMENT_TARGET
= 26.0`. *If false* (a future flip to Swift 6): `WorkspaceModel`'s four existing
`MainActor.assumeIsolated` sites and both watchers' `@unchecked Sendable` conformances would all
need revisiting — a project-wide migration, out of scope for this item and not made harder by it.

**L10 — `sample(1)` labels each thread with its dispatch queue**, giving the objective "is the main
thread scanning" check that criteria 2, 3, 8, 9, 14 and 16 rest on. *If false:* fall back to Xcode
Instruments' Time Profiler, or temporary `os_signpost` instrumentation removed before commit. No
design impact, only a slower verification loop.

## Out of scope — explicit

- **Incremental / streaming tree population.** The tree still lands as one complete value per root.
  Rendering subtrees as they are discovered is a different design and a different item.
- **Lazy on-expand scanning** (walk a directory only when its disclosure triangle opens). Probably
  the right long-term shape, but it changes `filesWithRelativePaths()` and therefore SPEC §5.4's
  filter semantics wholesale — flat filter mode would only be able to match what has been expanded.
- **Making `SidebarView.flatRows` / `filesWithRelativePaths()` / `FilterQuery` matching off-main,
  cached, or incremental.** Named as a finding above; Tier 4's node budget is the only mitigation
  this item ships. If a bounded tree still makes filter typing laggy, file a separate TODO.
- **Any change to the skip list contents, the symlink-as-leaf rule, the folders-first
  `localizedStandardCompare` sort, or `FileNode`'s `children` optionality** (whose doc comment
  already warns against "simplifying" it).
- **The editor, autosave, dirty-file guard, the vnode `FileWatcher`, `FileSignature`, the git badge,
  `GitStatus`, and the `WorkspaceSnapshot` JSON format.** All untouched.
- **`(external-open-stray-window)`** — the other open TODO item, a separate concern in
  `FEditApp.swift`/`LaunchCoordinator.swift`.
- **Persisting scan results or an on-disk tree cache** across launches.
- **`FSEventStreamCreate`'s latency, flags, or the `kFSEventStreamEventIdSinceNow` choice** in
  `DirectoryTreeWatcher`.
- **The `fedit` shim, its 8-path cap, `install.sh`, or anything in `scripts/` other than
  `FileNodeTests`.**
- **Migrating the project to Swift 6 language mode / strict concurrency** (L9).

## Files touched

| File | Tier(s) | What |
|---|---|---|
| `FEdit/Models/FileNode.swift` | 1, 2, 3a, 4 | `Sendable`; doc-comment threading contract; cancellation token + `cancellation:` overload; hoisted skip predicate; `limit:` overload + `maxScannedNodes` |
| `FEdit/Models/WorkspaceModel.swift` | 1, 2, 3, 4 | `scanQueue`, `scanningRootURLs`, `rescanRequested`, `requestScan(of:force:)`; `addFolders` placeholder; `refreshAll` async; `removeRoot`/`deinit` cancellation; `isSkippedTreePath` parity; rescan damping; `truncatedRootURLs` |
| `FEdit/Views/SidebarView.swift` | 1, 4 | `Scanning…` in tree and filter modes; truncation note |
| `SPEC.md` | 1, 4 | §11 "folder with thousands of files" rewritten (the item's mandated revision); §5.2 scan bullet; §5.2/§11 node cap |
| `README.md` | 4 | line 52's "scans your entire home directory … recursive and synchronous" rewritten |
| `scripts/FileNodeTests/main.swift` | 3a, 4 | skip-predicate parity fixture + assertions; budget/truncation assertions. **Not edited in Tier 1** — criterion 5 depends on it running unmodified |
| `FEdit/Views/ContentView.swift` | 1 (possible) | only if the scanning indicator is also surfaced in the window subtitle or the sidebar header strip; not planned, listed for overlap safety |
| `FEdit/Models/DirectoryTreeWatcher.swift` | 3b (unlikely) | only if the rescan damping is placed in the watcher instead of in `WorkspaceModel`; the plan puts it in `WorkspaceModel` |
| `TODO.md`, `DONE.md` | — | bookkeeping at `/done` time, plus criterion 3's baseline number and criterion 16's gate result |

---

# Revision 2 (2026-08-11) — post-review re-cut

Adversarial plan review verdict: REVISE. Every finding was re-verified against source before
folding (orchestrator, not the reviewer's word): the `force: true` Refresh path
(SidebarView.swift:113-117), the watch-arming-before-walk ordering (WorkspaceModel.swift:290),
and the UF_HIDDEN mechanism — the last settled by experiment, see below. This section supersedes
the conflicting parts of Revision 1. Everything not named here stands as written.

## Experimental result: L5/L6 are CONFIRMED, not suspected

Run 2026-08-11 by the orchestrator: `ls -lOd ~/Library` → `hidden` (UF_HIDDEN, no dot prefix);
a fixture directory with `chflags hidden` was **excluded** by
`contentsOfDirectory(..., options: [.skipsHiddenFiles])` in a standalone Swift check. So the
scanner skips `~/Library` while `isSkippedTreePath` (dot-prefix test only,
WorkspaceModel.swift:456-460) passes `~/Library/**` events through to `refreshAll()`. The rescan
storm on a `$HOME` root is a real mechanism. Consequence: **damping ships inside Tier 1** —
"pays off alone" is only true with it.

## Tier structure after the re-cut

- **Tier 1 — off-main scan + coalescing + damping + placeholder + `Scanning…`** (the fix; ships
  alone safely).
- **Tier 2 — cooperative cancellation** (unchanged in shape; splice hole closed by generations,
  see below).
- **Tier 3a (skip-predicate parity) — CUT from this item**, filed as TODO `(watcher-scan-skip-parity)`.
  The review CONFIRMED its premise false: the scanner has no hidden-predicate to unify —
  hidden-skipping is delegated to Foundation inside `contentsOfDirectory`, and exact parity would
  need a per-path `stat`, which `handleTreeChange`'s no-syscall constraint forbids. A correct
  design needs its own plan; damping (now in Tier 1) bounds the cost meanwhile.
- **Tier 4 (node budget / memory bound) — CUT from this item**, filed as TODO `(tree-node-budget)`.
  The TODO item offered "move off main OR bound its depth/count"; this item ships the former.
  The review additionally showed Tier 4's criteria 18/19 untestable as written and its truncation
  silently breaking SPEC §5.4 filter completeness — that design work belongs to its own item.

## Tier 1 mechanism changes (supersede Revision 1's Tier 1 where they conflict)

**Concurrent shared queue, per-root serialization via the coalescing gate.**
`scanQueue` becomes a `static let` on `WorkspaceModel`:
`DispatchQueue(label: "com.fedit.tree-scan", qos: .userInitiated, attributes: .concurrent)`.
Per-root serialization is enforced by `scanningRootURLs` (a root already in flight never enqueues
a second walk; `rescanRequested` re-runs once on completion) — NOT by queue serialism. This fixes
the review's head-of-line findings: a small root's walk no longer waits behind `$HOME`'s
(criteria 6, 10, 12, 15 are now runnable), and `createFile` → `refreshAll(force: true)` refreshes
its small root promptly regardless of other walks. App-wide concurrency is bounded by the total
root count across windows (small in practice; GCD bounds its own thread pool). Recorded residual:
no explicit width cap — revisit only if a real session shows thread contention.

**Damping (Revision 1's 3b) is part of Tier 1.** Watcher-driven rescans of a root get exponential
backoff when consecutive rescans land structurally unchanged (`changed == false` in the apply
block): min-gap 1 s doubling to 30 s, reset by any structural change. Explicit user Refresh
(`force: true`) and `addFolders` initial scans are never damped. A damped event does not vanish:
it sets `rescanRequested` and the re-run fires when the gap expires (trailing edge), so the tree
is eventually right. Lives entirely in front of `requestScan`; ~20 lines.

**Per-root scan generations close the remove-then-re-add splice.** `private var scanGeneration:
[URL: Int]`. `requestScan` captures the root's current generation at job start; the apply block
drops the result if the generation changed. `removeRoot` bumps the generation (and Tier 2 cancels
the token); `addFolders` bumps it when appending a placeholder. The review's trace — remove `U`
mid-scan, re-add `U` before the walk unwinds, stale partial tree splices into the fresh
placeholder — is closed structurally: the re-add bumped the generation, so the stale result is
dropped and the re-add's own scan lands.

**Per-root state is drained on removal.** `removeRoot` clears `rescanRequested`, `forcedRescans`,
the damping clock, and (Tier 2) the cancellation token for that URL — closing the review's leak
where a root removed mid-scan left a permanent `rescanRequested` entry. The apply block consumes
`forcedRescans.remove(url)` when it fires the pending re-run, so one forced Refresh cannot make
every later rescan forced.

**`Scanning…` is keyed to first scans only.** New `@Published private(set) var
initialScanRootURLs: Set<URL>` — inserted when `addFolders` appends a placeholder, removed when
that root's first scan applies. `SidebarView` renders `Scanning…` (tree mode and filter mode) on
membership in THIS set, not `scanningRootURLs`. This fixes two review findings at once: a
genuinely-empty root no longer flips to `Scanning…` on every watcher rescan, and refresh-driven
scan-state churn no longer publishes through a property the UI observes. `scanningRootURLs`
becomes plain private (not `@Published`) — it is bookkeeping, not UI state. The whole-window
re-render finding is thereby void: refresh scans publish nothing unless the tree actually changed.

**Doc comments falsified by the change are in Tier 1's edit list** (review finding): `restore(fromJSON:)`'s
"Runs synchronously on the main thread" paragraph (WorkspaceModel.swift:986-987), `FileNode`'s
type doc "scanned synchronously and handed straight to `OutlineGroup`" (FileNode.swift:25-26,
which also gains the L1 no-reference-payload warning), and `addFolders`'s doc comment.

## Acceptance criteria amendments

- Criterion 1: "no perceptible lag" → the filter field echoes keystrokes without visible delay
  (subjective GUI observation, recorded as such).
- Criterion 6: bound loosened to **1 s** (stopwatch-resolvable); the pre-change screenshot
  baseline is flagged **[run first]**.
- Criteria 8/9 REPLACED (the review showed them vacuously true under any queue): a temporary
  debug-only `os_log` on walk start (removed before commit) counts walks via `log show
  --predicate`. Criterion 8: 10 Refreshes in 5 s of a scanning root → **≤ 2 walks** for that root
  (one running + one trailing re-run). Criterion 9: 300-file touch storm on `$SMALL` → ≤ 2 walks,
  all 300 files listed afterwards.
- Criterion 12: "immediately" → within 1 s.
- Criterion 15 now runnable (concurrent queue): both roots genuinely scan concurrently.
- Criterion 16 REPLACED by the experimental L6 result above (already run, positive); damping is
  in Tier 1 unconditionally, so no measurement gates it.
- Criteria 17–20 CUT with Tiers 3a/4 (moved to the filed items).
- NEW criterion 23 [GUI]: disclosure state survives a watcher-driven refresh of an expanded,
  populated root — expand a nested dir in `$SMALL`, `touch $SMALL/<expanded-dir>/new.txt`, the
  new row appears and the expansion state of every open triangle is unchanged. (Covers the
  roots[idx] whole-value swap under an unchanged `id`.)
- Criterion 13 (cli-open A7 5×) stands, and explicitly covers the review's SUSPECTED finding that
  Tier 1 widens the late-`@SceneStorage` window: the token-invariant layers
  (`wasIssuedThisProcess` + pristine re-check inside the one-turn hop) are timing-independent by
  construction; the 5× GUI run is the empirical check on top.
- L3's mis-citation fixed: the re-verification criterion is **A7**, not A13.

## Decisions taken (Revision 2)

All dated 2026-08-11, folding the adversarial plan review (verdict REVISE). Findings were
re-verified against source; the storm hypothesis was settled by experiment.

- **Concurrent shared queue replaces per-window serial queue** (review: head-of-line blocking made
  four criteria unrunnable and regressed `createFile` latency unacknowledged). Alternative: keep
  serial + accept latency. Rejected: SPEC §5.2's "appears after the automatic refresh" would
  silently become minutes; per-root serialization was always the coalescing gate's job, not the
  queue's.
- **Damping into Tier 1** (review: "pays off alone" contradicted L5; storm now CONFIRMED by
  experiment). Alternative: ship Tier 1 bare and fast-follow. Rejected: a permanent background
  scan loop on the item's own motivating fixture is not shippable.
- **Tier 3a cut and filed as `(watcher-scan-skip-parity)`** (review CONFIRMED the "two hand-synced
  copies" premise false and criterion 17 unsatisfiable under the no-stat constraint). Alternative:
  redesign parity in this item. Rejected: it is a separately-revertible concern with its own
  design space; folding it in couples this item's revert to it.
- **Tier 4 cut and filed as `(tree-node-budget)`** (review: criteria untestable as written —
  force-Refresh defeats the scroll-position observable — SPEC §1/§5.4 conflicts unrecorded).
  Alternative: fix the criteria and keep it. Rejected: the TODO item's own "or" makes the bound an
  alternative, not a requirement; the memory bound deserves a plan that resolves the SPEC
  conflicts explicitly rather than riding along.
- **Generations for splice-safety** (review's remove/re-add trace verified correct). Alternative:
  consult `scanningRootURLs` in `addFolders`' duplicate check. Rejected: that turns a re-add into
  a silent no-op — user-visible wrong behavior; generations keep every path live and drop only
  stale results.
- **`Scanning…` keyed to `initialScanRootURLs`; `scanningRootURLs` de-published** (review: publish
  churn invalidated the whole window per rescan attempt; empty-root Nit). Alternative: keep one
  published set and guard call sites. Rejected: two sets with distinct meanings is smaller than
  one set with call-site caveats.
- **Criteria 8/9 rebuilt on a walk counter** (review: serial-queue `sample` assertion was
  vacuous). The temporary os_log is removed before commit; the criterion is about observed walk
  count, which survives any queue topology.
- **Multi-window width cap NOT built** (review flagged unbounded app-wide concurrency).
  Decision: accept and record — realistic sessions hold a handful of roots; GCD bounds its pool;
  a width cap (semaphore) is ~10 lines if a real session proves contention. The asymmetry favors
  not building speculative throttling.
- **SPEC §1 memory conflict travels with `(tree-node-budget)`**, where it belongs; this item's
  SPEC edits are §11 + §5.2 scan-async wording only. The flatRows O(N) filter cost finding also
  travels with that item (it is bounded only by a bounded tree).
