# Architecture review — 2026-08-11

Run per `~/.claude/commands/arch-review.md` by a fresh-context agent (opus), deep-dive theme:
**concurrency**, triggered by the async-root-scan batch (80609b5..259a1b7) in place of a
`/code-review ultra` pass. Gate at review time: BUILD SUCCEEDED + 8/8 harnesses (422 assertions).
The reviewer additionally built with `SWIFT_STRICT_CONCURRENCY=complete` to *measure* the Swift 6
migration rather than estimate it. Findings filed into TODO.md are marked ⇒ below.

---

# PHASE 1 — The architecture as actually enforced

1. **Decomposition:** one `PBXNativeTarget` (`FEdit`), `fileSystemSynchronizedGroups` (whole dir auto-included), no SPM packages, no frameworks, no XCTest target. 30 Swift files / 8,738 lines. `SWIFT_VERSION = 5.0`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, both configs. *Verified from pbxproj.*
2. **The only enforced dependency rule in the repo is the gate script:** 7 files (`FileNode`, `LogicalLine`, `OpenRequest`, `FilterQuery`, `GitStatus`, `WorkspaceSnapshot`, `MarkdownRenderer`+`Theme`) must compile standalone under `swiftc`, which pins them import-minimal. Break it and the gate goes red. *Verified.*
3. **Import graph, no cycles at file level:** Foundation-only leaves (FileNode, FilterQuery, LogicalLine, OpenRequest, WorkspaceSnapshot, FileWatcher, GitStatus[+CoreServices for DirectoryTreeWatcher]) → AppKit-only (Theme, SyntaxHighlighter, MarkdownRenderer, LineNumberRulerView) → AppKit+SwiftUI (WorkspaceModel, ContentView, CodeEditorView, MarkdownPreviewView, SidebarView, WindowCloseGuard). There *is* a type-level knot: `LaunchCoordinator.bringWindowToFront(for: WorkspaceModel)` reaches through `WindowCloseGuardProxy.model`, closing WorkspaceModel ↔ ContentView ↔ LaunchCoordinator. *Verified.*
4. **Layer model: there isn't one.** Folder names are labels. `Models/WorkspaceModel.swift` imports AppKit+SwiftUI and runs `NSAlert.runModal()` ×3 and `NSOpenPanel.runModal()` ×2. The real division is "7 pure harness-compilable value files | one 1,431-line main-actor blob | thin views".
5. **State:** per-window truth = `WorkspaceModel` (@MainActor, ObservableObject, 9 `@Published`). Derived state is mostly computed (`isMarkdown`, `canSave`, `currentSnapshot`) — good. Global truth: `@AppStorage` ×3 + `LaunchCoordinator.shared`. Per-scene: `@SceneStorage` JSON + SwiftUI's own `WindowGroup(for: CLIOpenToken.self)` value archive.
6. **Routing: two mechanisms.** An `Int` mailbox (`pendingNewWindowPicks`, any pristine editor window may drain it) for Cmd+O, and a typed per-window value (`CLIOpenToken` + `issuedTokenIDs` + 3 guard layers) for external opens. The code explicitly contrasts them; the second was not retrofitted onto the first.
7. **DI: five stories** — `@StateObject`, init-param `@ObservedObject`, `@FocusedObject`/`.focusedSceneObject`, singleton, `@AppStorage`/`@SceneStorage`. Idiomatic SwiftUI; not one story.
8. **Concurrency topology (deep dive), full inventory:** isolation = `@MainActor` on exactly 2 types (WorkspaceModel, LaunchCoordinator) + SwiftUI bodies. **Zero actors.** 6 queues: `gitQueue` (per-instance serial), `scanQueue` (static concurrent, userInitiated, no width cap), `FileWatcher.queue` (per-instance serial), `DirectoryTreeWatcher.queue` (per-instance serial + FSEvents dispatch target), `renderQueue` (static serial, utility), `DispatchQueue.global()` (git watchdog). 2 `NSLock` (ScanCancellationToken; GitStatus's local `timedOut`). 3 `@unchecked Sendable` classes. 2 unstructured `Task`s, both unowned, both pure `withCheckedContinuation` wrappers around `queue.async`, **neither ever cancelled**. 9 `MainActor.assumeIsolated` sites — the app's *only* entry into main-actor state from non-isolated code.
9. **Coalescing/cancellation are 8 and 4 separate mechanisms respectively.** Debounce: `DispatchWorkItem`+`asyncAfter` ×6 (autosave 750ms, damped-rescan variable, highlight 150ms, first-visible-line 100ms, preview render 220ms, opener retry 100ms), `Task.sleep(200ms)` ×1, FileWatcher's own queue debounce 150ms, FSEvents latency 300ms, plus flag-pair (`isRecomputing`/`recomputeAgain`) and set-based (`rescanRequested`/`forcedRescans`). Cancellation: `ScanCancellationToken` (NSLock bool), `DispatchWorkItem.cancel()`, generation counters (`scanGeneration`, `renderGeneration`), and deliberate no-cancel for git. **Swift `Task` cancellation is used nowhere.**
10. **Persistence: 3 stores, 1 migration story.** `WorkspaceSnapshot` has real tolerant optional-with-defaults decoding; `@AppStorage` is clamped at read sites; `CLIOpenToken` is archived *by the system* and has no versioning discipline at all. Domain and persistence types are genuinely separated (`WorkspaceSnapshot` ≠ model, `CLIOpenToken` ≠ `OpenRequest`, `FileSignature` ≠ file state), each conversion explicit and reasoned.

### DRIFT (intent vs. enforced)

- **D1** — `Models/` is not a model layer: 5 modal AppKit presentations live inside `WorkspaceModel` (`presentUnsavedCloseEscape`, `presentReadErrorAlert`, `presentSaveErrorAlert`, `presentOpenPanel`, `presentNewWindowFolderPanel`).
- **D2** — SPEC §13's per-file table reads as a layered design; the enforced structure is "7 pure files + 1 blob". The folder split is documentation, not a boundary.
- **D3** — SPEC §11 promises the window stays interactive during a scan and "the filter field types". True for I/O now; **false for the filter itself** — `SidebarView.flatRows` is still a full-tree main-thread walk per render. The async fix moved the syscalls, not the last O(N) main-thread pass. (Finding 1.)
- **D4** — `gitQueue`'s doc claims it bounds the app to one git process *per window*; that's honest, but `scanQueue` is app-wide static while `gitQueue` is per-instance. Two "dedicated blocking queue" decisions with opposite scoping, no stated policy.
- **D5** — `FileWatcher.isActive` is documented as sharing "the main queue's single serialization domain". Safe, but the write is a deferred `main.async` from the private queue, so every main-actor read is of a value that lags reality by one hop.
- **D6** — `FileNode.swift`'s claim that `requestScan` is the sole app-target scan call site **holds**. Verified.
- **D7** — SPEC §1's <100 MB goal vs. an unbounded tree. This drift is *declared* in SPEC §11's parenthetical and filed as `tree-node-budget`, so it's honest debt, not hidden drift.

---

# FINDINGS

## DEFECTS

**[Critical] — The main-thread full-tree walk survived the async-scan fix, and the fix made it reachable —** `FEdit/Views/SidebarView.swift:90–99`, `FEdit/Models/FileNode.swift:141–157`, `FEdit/Models/WorkspaceModel.swift:131`, `:325–334` ⇒ filed `(filter-walk-main-thread)`

`flatRows(for:query:)` calls `root.filesWithRelativePaths()` — a full DFS allocating one `(String, FileNode)` tuple per file with per-file string concatenation — **inside `body`, per root, per render, with no memoization**. The doc comment says "Computed inline per render … no caching layer". The amplifier is the invalidation graph: `SidebarView` holds `@ObservedObject var workspace`, so *any* `@Published` write re-runs its body. Two of those fire constantly: `editorText`'s setter assigns `openFile` (`@Published`) on **every keystroke**, and `noteCursorMoved` assigns `cursorLocation` (`@Published`) on **every caret movement** — even though `cursorLocation`'s only consumer is `currentSnapshot`, never a view. So with a filter active on a home-scale root, typing one character in the *editor* re-walks the entire tree on the main thread. *Mechanism verified from code; user-visible freeze inferred.* This is the same defect class `async-root-scan` just fixed, one layer up, and it was previously masked because a root that large would freeze at scan time before you ever got to filter it. SPEC §11 explicitly promises the filter field types during a scan.

**Tradeoff:** inline computation is genuinely simpler and was correct when trees were small; the async scan changed the reachable input size without changing this. **Direction:** the flat filtered list is derived state — it should be produced once per (root-generation × query) and cached, and `cursorLocation` should not be `@Published` on the object every sidebar row observes (it is snapshot input, not view state). Design this together with `tree-node-budget`: a bounded tree makes the walk bounded and the two decisions interact. **Cost: M.**

**[High] — The scan-skip predicate exists twice, in two languages, with no shared definition —** `FEdit/Models/FileNode.swift:80–115` vs `FEdit/Models/WorkspaceModel.swift:840–850` — already filed `(watcher-scan-skip-parity)`

`FileNode.scanChildren` delegates hidden-ness to Foundation (`options: [.skipsHiddenFiles]`) plus `skippedDirectoryNames`; `WorkspaceModel.isSkippedTreePath` reimplements it as a dot-prefix string test plus the same name set. The divergence is **measured, not suspected** and documented, filed as `watcher-scan-skip-parity`. The structural cost is what's striking: the *entire damping subsystem* — 3 tuning constants, 4 dictionaries, a trailing-edge timer, a proportional-duty-cycle argument spanning 30 lines of comment, and a SPEC §11 paragraph — exists to bound the cost of this one missing abstraction. **Direction:** one owned skip predicate that the scanner *asks* rather than delegates, so parity is structural. Fold in the `path + "/"` idiom below while you're there. **Cost: M–L.**

**[Medium] — `path + "/"` containment is inlined at 4 sites and is wrong for a `/` root —** `WorkspaceModel.swift:457`, `:805`, `:841`, `:1332` — already filed `(root-slash-prefix-match)`

The structural point beyond the bug: "is this path inside this root" is a domain predicate that got copy-pasted four times, which is *why* it is four bugs rather than one. **Direction:** one `path(_:isContainedIn:)`, extracted alongside the skip predicate above. **Cost: S.**

**[Medium] — `deinit` reads main-actor state; a hard Swift 6 error, in the newest code —** `WorkspaceModel.swift:356`, `:357`, `:367` ⇒ folded into `(root-scan-consolidation)`

Measured, not estimated: `cannot access property 'pendingAutosave'/'resignActiveObserver'/'pendingDampedRescans' … from nonisolated deinit; this is an error in the Swift 6 language mode`. These are the *only* three strict-concurrency rejections in the entire 1,431-line file, and two of the three are the teardown lines `async-root-scan` just added. **Direction:** teardown of queue-backed resources belongs to an explicitly-owned lifecycle object (the scan subsystem extraction), not to `deinit`. **Cost: S.**

## TENSIONS / RISKS

**[High] — Nine parallel per-root dictionaries, with drain invariants maintained by hand and prose —** `WorkspaceModel.swift` ⇒ filed `(root-scan-consolidation)`

`scanningRootURLs`, `rescanRequested`, `forcedRescans`, `scanGeneration`, `scanTokens`, `lastScanFinish`, `lastScanDuration`, `rescanBackoff`, `pendingDampedRescans`, plus `initialScanRootURLs`. `removeRoot` drains 8 by hand, `applyScan` touches 6, `requestScan` touches 7, `deinit` 2. Each has a comment explaining *which* of the four sites must and must not clear it, and at least one (`scanningRootURLs`) is deliberately excluded from `removeRoot` for a reason that only a comment records.

**Tradeoff:** the machine is correct today — the reviewer could not find a hole — but its correctness is carried entirely by prose. Every future per-root attribute (`tree-node-budget`'s truncation flag, `watcher-scan-skip-parity`'s memoized skip set, a per-root filter index) adds a tenth map *and a fourth place to forget it*. **Direction:** one `RootScan` value keyed by URL, so "drain a root" is a single removal and the invariant is a type property. The highest-leverage refactor in the repo: fixes the drain fragility, shrinks the god module's worst region, unblocks both open scan TODOs. **Cost: M.**

**[High] — Two concurrency vocabularies; Swift Concurrency is used only as glue and its best feature is discarded —** `WorkspaceModel.swift:596–621`, `:739–762` — Watch

Both `Task`s exist solely to wrap `withCheckedContinuation` around a `queue.async` — they buy nothing over `queue.async { … DispatchQueue.main.async { … } }` and cost a continuation plus an unowned, uncancellable task. Meanwhile the one place Swift Concurrency's cancellation is the natural tool — the `try? await Task.sleep(for: .milliseconds(200))` git debounce — **discards cancellation with `try?`, because nobody holds the Task to cancel it.** A window closed during that sleep still launches `git status`. The result: 4 unrelated cancellation mechanisms, 8+ debounce mechanisms, 0 actors, 9 `assumeIsolated` bridges, and `Task.cancel()` never called anywhere in the app.

**Tradeoff:** the GCD choices are each individually well-reasoned (blocking syscalls genuinely must not park cooperative workers). The problem is that Swift Concurrency was adopted *halfway*, so a reader must hold both vocabularies and neither is complete. **Direction:** pick one, before the next async feature. **Cost: M.** *Partly preference; the fragmented cancellation story is not.*

**[Medium] — `MainActor.assumeIsolated` ×9 is the app's only isolation bridge, and it's a runtime trap rather than a type —** Watch. Every one is correct *because* the corresponding wrapper hops to `.main` itself — a fact carried only in doc comments. A watcher refactor that ever delivered on its own queue would **crash**. **Direction:** make "delivers on main" a type-level property (a `@MainActor` callback type, or watchers vending an `AsyncStream`). **Cost: M.**

**[Medium] — Three "dedicated blocking queue" decisions, three different scopes, no policy —** `gitQueue` per-instance serial; `scanQueue` static concurrent uncapped; `renderQueue` static serial — Watch. 8 CLI-opened windows on one repo → up to 8 concurrent `git status` processes. Each in-flight walk holds a full private tree in memory — against SPEC §1 and compounding `tree-node-budget`. `renderQueue` serializes markdown renders across all windows for no stated reason. **Direction:** one stated policy for "blocking work off the cooperative pool", scope and width chosen per kind. **Cost: S–M.**

**[Medium] — Swift 6 migration cost, measured —** ~70 diagnostics via `SWIFT_STRICT_CONCURRENCY=complete`. Distribution: leaves 0; `WorkspaceModel` 4 (3 deinit + one `@preconcurrency Dispatch`); **39 in the two `NSViewRepresentable.Coordinator`s** (mechanical: mark `@MainActor`); ~14 non-Sendable AppKit style globals (`Theme`, `MarkdownRenderer`). One genuine design decision: `MarkdownRenderer`'s style globals are read from `renderQueue` — the off-main render is a real cross-domain read of lazily-initialized AppKit objects. **Direction:** renderer takes its style as an explicit `Sendable` parameter. **Cost: M overall, S for the mechanical 39.** — Watch

**[Medium] — `WorkspaceModel` is the god module —** 1,431 lines. Owns scan scheduling, damping policy, autosave, save, file load, git badge, FSEvents gate, canonicalization, name validation, snapshot codec, and 5 modal AppKit presentations. All five roadmap changes touch it. **Direction:** extract the per-root scan/damping subsystem (same work as `(root-scan-consolidation)`); do *not* attempt a general layer split. **Cost: M.**

**[Medium] — Failure architecture is "degrade to nil/empty, say nothing", with one log line in the entire app —** `GitStatus.swift:159` is the only log call. `try?` swallows at 4 sites; `GitStatus` returns `[]` for five indistinguishable failures; `FileNode.scanChildren` returns `[]` for unreadable dirs. Defensible when everything was synchronous; the hot path is now a minutes-long background walk behind five coalescing gates, and "the sidebar shows nothing" has ~eight indistinguishable causes. **Direction:** a small structured per-root scan outcome on the model (landed / cancelled / superseded / failed, duration, node count) — which is also what `tree-node-budget`'s truncation notice needs. **Cost: S–M.** — Watch (pairs with tree-node-budget)

**[Medium] — `FileWatcher.isActive` is stale-by-one-hop at every read site —** Watch. Safe today because both readers only gate an idempotent re-arm; it is the single acknowledged hole in the `@unchecked Sendable` queue-confinement argument. **Direction:** fold into an idempotent queue-confined `ensureWatching(url)`. **Cost: S.**

**[Medium] — Two routing mechanisms for "which window gets this", one known-weak —** Watch. The Cmd+O `Int` mailbox coexists with the token design that was built precisely because mailboxes race. The open `zero-window-session-relaunch` bug lives in this code. **Direction:** unify Cmd+O onto the token mechanism when that bug is fixed; do not add a third path. **Cost: S.**

**[Medium] — The single-document assumption is the deepest load-bearing invariant —** `openFile: OpenFile?` is singular, and so is everything keyed to it (watcher, signature, autosave, cursor, snapshot schema, editor mount). Tabs or a second document type restructures all of it. **Direction:** none needed now; stays a decision, not a discovery. **Cost: L if it lands.** — Accept

**[Low] — `CLIOpenToken` has no tolerant decode and the system owns its read path —** ⇒ filed `(clitoken-tolerant-decode)`. A field change fails scene restore silently. **Direction:** same optional-with-defaults treatment as `WorkspaceSnapshot`. **Cost: S.**

## STRENGTHS

- **The async scan bridge is correct by construction, and the compiler independently agrees**: strict-concurrency-complete produces zero diagnostics for `FileNode`, `DirectoryTreeWatcher`, `GitStatus`, and only the three `deinit` lines for `WorkspaceModel`. The `Sendable` conformance is load-bearing and documented with its exact failure mode. The deep `Equatable` diff deliberately moved off-main.
- **The scan path separates four distinct staleness concerns correctly** (generation = discard result; token = stop work; gate set = don't start a second; request set = don't lose the ask), and `applyScan`'s unconditional job-local teardown is the non-obvious correct choice, with the reason stated.
- **The pure-value leaves + `swiftc` harness discipline is a real, enforced boundary** — the only dependency rule in the repo that is enforced rather than described.
- **Domain/persistence separation is deliberate and clean** (three explicit conversions, each reasoned — including `CLIOpenToken` storing `String` over `URL` for Codable-stability).
- **Syntax highlighting flexes exactly where the roadmap needs it** — adding a language is one file, no other site.
- **The FSEvents gate is the cheapest correct place for the filter and knows exactly what it costs** — the no-`realpath`-per-event constraint is right for `npm install` bursts, and its accepted divergence is documented with the experiment that measured it.
- *Caveat:* the extraordinary comment density is currently doing load-bearing work that types should do (the per-root maps, the assumeIsolated contracts, the isActive staleness). Survivable today; not as the file grows.

---

# CHANGE-COST RUN-THROUGH

| Change | Blast radius | Cost |
|---|---|---|
| (a) tree-node-budget | FileNode + WorkspaceModel (a 10th per-root map) + SidebarView + SPEC + harness; wants co-design with the filter-walk fix | M, inflated by the filed findings |
| (b) watcher-scan-skip-parity | Blocked on the missing shared predicate. As filed: L. With the predicate owned first: S | L → S |
| (c) more languages | One file | S |
| (d) second doc type / tabs | ~everything keyed to singular `openFile` + snapshot schema + external-change-watch design | L |
| (e) Swift 6 strict concurrency | ~70 diagnostics measured; 39+14 mechanical, 3 genuine design decisions | M |

---

# VERDICT

**A small, unusually well-reasoned single-target SwiftUI app whose concurrency *correctness* is genuinely strong and now compiler-verifiable, but whose concurrency *vocabulary* has accreted into 6 queues / 8 debounce idioms / 4 cancellation mechanisms / 10 hand-drained per-root maps — and the async-scan fix, by making home-scale roots reachable, exposed the one main-thread O(N) walk it did not move.**

### Fix now (ROI order)
1. `(filter-walk-main-thread)` — the live regression-in-waiting created by the batch; defeats a SPEC §11 promise. M
2. `(root-scan-consolidation)` — collapse the 10 per-root maps; unblocks (a)/(b), fixes drain fragility + the Swift 6 deinit errors. M
3. `(watcher-scan-skip-parity)` + `(root-slash-prefix-match)` — one owned skip predicate + one containment helper, extracted together. M
### Watch
Concurrency vocabulary (decide before the next async feature) · assumeIsolated-as-contract · queue scoping policy · Swift 6 (mechanical 39 opportunistically) · per-root scan observability (pairs with tree-node-budget) · `FileWatcher.isActive` · routing unification (on the `zero-window-session-relaunch` fix) · `(clitoken-tolerant-decode)`
### Accept
`WorkspaceModel`'s size as such (extract the scan subsystem only) · the single-document invariant (stated decision) · model-layer AppKit alerts (preference at this size) · five-way DI plurality (idiomatic SwiftUI) · no XCTest target (harnesses are an enforced substitute) · unbounded tree (declared debt, filed)
