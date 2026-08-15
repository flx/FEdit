//
//  WorkspaceModel.swift
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

import AppKit
import SwiftUI

/// Per-window state for the folder sidebar (SPEC §5, §10) and the open document (SPEC §7). One
/// instance lives per window (SPEC §3) and is exposed to `Commands` via `.focusedSceneObject` so
/// File → New…/Add Folder to Window…/Save always target the focused window. (Open Folder…/Cmd+O is
/// app-level — it opens a new window — and is not focused-window-scoped.)
@MainActor
final class WorkspaceModel: ObservableObject {
    /// The single file open in this window's editor (SPEC §6.1: exactly one file at a time), or
    /// `nil` when nothing is open.
    struct OpenFile {
        let url: URL
        var text: String
        var isDirty: Bool
    }

    /// A read failure that isn't a generic I/O error — kept distinct so `requestOpen` can pick
    /// the "appears to be binary" wording (criterion 3) instead of a generic read-error one.
    private enum FileLoadError: Error {
        case binaryFile
        case notRegularFile
        case tooLarge
    }

    /// Cap on readable file size (100 MB), guarding against hangs/OOM from clicking a sidebar row
    /// that isn't an ordinary bounded text file (see `loadText(from:)`).
    private static let maxReadableFileSize = 100 * 1024 * 1024

    /// Autosave debounce interval (SPEC §7): the open file is written this long after the last
    /// keystroke. Within the plan's 0.5–1 s band — short enough that the on-disk file tracks the
    /// editor within a second, long enough to coalesce a typing burst into a single write.
    private static let autosaveInterval: TimeInterval = 0.75

    /// Outcome of `resolveDirtyFile(context:)` (SPEC §7): whether the caller (a file switch,
    /// window close, or app quit) may proceed, or must stop where it is.
    enum DirtyResolution {
        case proceed
        case cancel
    }

    /// Which boundary is invoking `resolveDirtyFile(context:)`. The flush is identical; only the
    /// **failure** behavior forks: a file switch aborts and preserves the buffer, while a
    /// close/quit offers the minimal "Close Without Saving / Cancel" escape so a persistently
    /// -failing save can never make the app un-quittable.
    enum DirtyContext {
        case fileSwitch
        case closeOrQuit
    }

    @Published private(set) var roots: [FileNode] = []

    /// (async-root-scan) Roots whose **first** walk has not landed yet — i.e. roots that are still
    /// the empty placeholder `addFolders` appended synchronously. This is the *only* scan state the
    /// UI observes: `SidebarView` shows "Scanning…" for exactly these, in both tree and filter mode.
    ///
    /// (root-scan-consolidation) Deliberately **model-side view state**, kept out of the scheduler's
    /// per-root `RootScan` bookkeeping: this set is the only scan state the UI observes, and folding
    /// it into that dictionary would mean either publishing the whole dictionary — every in-flight
    /// gate insert would re-render the sidebar — or maintaining a derived mirror. Keying the
    /// affordance to first scans means a *refresh* of an already-populated root never blanks it, a
    /// genuinely empty root does not flip to "Scanning…" on every watcher-driven rescan, and —
    /// because the scheduler's scan-state churn publishes nothing — a rescan that finds nothing
    /// changed invalidates no view at all. Written at exactly three sites: inserted on the
    /// placeholder append (`addFolders`), removed by the scheduler's landing seam, removed on
    /// `removeRoot`.
    @Published private(set) var initialScanRootURLs: Set<URL> = []

    /// (tree-node-budget) Roots whose last applied walk hit the per-root node budget
    /// (`FileNode.defaultNodeBudget`), i.e. whose tree is **incomplete in its deep interior** — the
    /// walk is breadth-first, so every shallow level is whole and what is missing is depth. The
    /// sidebar declares this per root in both modes (SPEC §5.2, §5.4, §11); silent truncation was
    /// rejected outright.
    ///
    /// Model-side `@Published` state, deliberately, and **not** a read of the scheduler's
    /// `RootScan.lastReport`: `scans` is invisible to the UI by design (nothing in it publishes), so
    /// a flag stored only there could never invalidate the notice. Written at exactly two sites,
    /// mirroring `initialScanRootURLs`' discipline: the scheduler's landing seam below (membership-
    /// guarded, and **outside** the splice branch — see there for why that is the whole point) and
    /// `removeRoot`. The notice's node count is read lazily from `lastReport` through
    /// `truncatedNodeCount(for:)`, which is sound because the landing writes it in the same
    /// `applyScan` turn as this flag, before any render.
    @Published private(set) var truncatedRootURLs: Set<URL> = []

    /// (tree-node-budget) How many nodes `url`'s last applied walk actually built — the number the
    /// sidebar's truncation notice interpolates, so nothing hardcodes the budget constant outside
    /// `FileNode.defaultNodeBudget`. Carried from the walk that measured it (never a recount of the
    /// delivered tree, which would be an O(N) main-thread pass per render).
    ///
    /// `nil` means no walk of this root has landed — unreachable while `truncatedRootURLs` contains
    /// `url`, since the landing that inserts it stores the report in the same synchronous turn, but
    /// modeled honestly rather than papered over with a fabricated count.
    func truncatedNodeCount(for url: URL) -> Int? {
        scanScheduler.scans[url]?.lastReport?.nodeCount
    }

    /// Record-only until requestOpen. Writing this property has **zero side effects at the model
    /// layer** — no `didSet` — by design: the selection→load hook used to live in ContentView's
    /// `.onChange(of:)` (editor-core); it is now `requestOpen`, called directly from the sidebar
    /// row action. This stays a plain record, load-bearing for (open-save)'s Cancel-revert (a
    /// model-side reload here would silently destroy a dirty buffer).
    @Published var selectedFileURL: URL? = nil

    /// The sidebar's filter query text (SPEC §5.4–§5.5). Lives on the per-window model rather
    /// than view `@State` because SPEC §9 persists filter text per window, and (session-restore)
    /// snapshots from `WorkspaceModel` — parking it here now avoids a later move.
    ///
    /// (filter-walk-main-thread) The `didSet` is the cache's **release** site, and the only one:
    /// leaving filter mode drops the retained flat/filtered lists instead of holding tens of MB for
    /// the rest of the window's life. The predicate is `FilterQuery(...).isEmpty` — deliberately
    /// the SAME predicate `SidebarView.body` uses to pick tree mode — not `filterText.isEmpty`, so
    /// an operator-only or whitespace query (which shows the tree, not "No matches") also releases.
    /// Both writers route through this setter: the `TextField` binding and `restore(fromJSON:)`'s
    /// direct assignment. The accessor below cannot be the release site — it is only ever reached
    /// in filter mode, so a release there would never run. The parse per keystroke is the price of
    /// agreeing with the mode switch; it is one small parse, not a filter pass over the tree.
    @Published var filterText: String = "" {
        didSet {
            if FilterQuery(filterText).isEmpty {
                filterRowCache.releaseAll()
            }
        }
    }

    /// (filter-walk-main-thread) Filter mode's derived rows, cached per root — see `FilterRowCache`
    /// for the design and its memory trade. Deliberately **not** `@Published`: `filteredMatches`
    /// populates it from inside `SidebarView`'s body pass, which is only sound because writing it
    /// publishes nothing (no `objectWillChange`, so no invalidation loop) and because the write is
    /// idempotent across SwiftUI's speculative body passes.
    ///
    /// Invalidated/released at exactly three sites, mirroring `initialScanRootURLs`' discipline:
    /// the `land` seam's splice branch, `removeRoot`, and `filterText`'s `didSet` above (wholesale).
    /// Populated at exactly one: `filteredMatches`, the body-pass read above.
    private var filterRowCache = FilterRowCache()

    /// (new-file) Per-window flag driving ContentView's `.sheet(isPresented:)` for File → New…
    /// (SPEC §7, §10). The app-level menu command reaches the focused window's model and flips this
    /// true; the sheet flips it false on Create/Cancel. This published flag is the seam by which an
    /// app-level `Commands` button presents UI in the key window only.
    @Published var isPresentingNewFileSheet: Bool = false

    /// (new-file) The just-created file's (standardized) URL, stashed by `createFile` and consumed
    /// by `openPendingNewFileIfNeeded()` from the sheet's `onDismiss` — so the open (and any
    /// dirty-switch guard UI `requestOpen` might surface on the outgoing file) runs only after the
    /// sheet is fully gone, never stacked under a live sheet. Nil except in that brief window.
    private var pendingNewFileURL: URL?

    /// The file currently loaded into the editor, or `nil` if none (SPEC §6.1, §7).
    @Published var openFile: OpenFile?

    /// (external-change-watch) Raised when an external write lands on the open file **while the
    /// buffer has unsaved edits** — the in-editor version is kept (no clobber, SPEC §11
    /// last-writer-wins) and this drives Tier 2's "changed on disk" subtitle marker. Set only in
    /// the dirty branch of `fileDidChangeOnDisk`; cleared by `applyLoadedFile` (file switch), by
    /// `reloadOpenFileFromDisk` (clean reload), and by `saveOpenFile`'s success branch (the write
    /// resolves the conflict in-editor's favor). Near-cosmetic under always-on autosave: the
    /// ~0.75 s flush writes the dirty buffer and clears this on its own, so it is reliably visible
    /// only during continuous typing that keeps the buffer dirty across the external write.
    @Published var openFileChangedOnDisk = false

    /// (git-changed-badge) The per-window cache of changed file URLs, read by `FileRow` to show the
    /// "(changed)" badge (SPEC §5.6). A single flattened union across **all** repo-root roots in
    /// this window; membership is O(1). Non-git roots contribute nothing, so a row under a non-git
    /// root is simply never present (no per-row repo check needed). Recomputed off-main by
    /// `scheduleGitRefresh()`; empty whenever the window has no git roots or every recompute failed.
    @Published private(set) var changedFileURLs: Set<URL> = []

    /// The editor's last-reported caret offset (UTF-16, `NSRange.location`), sunk here by
    /// (session-restore) via `noteCursorMoved(_:)`. Drives `snapshotJSON()`'s `cursorLocation`.
    @Published private(set) var cursorLocation: Int = 0

    /// One-shot cursor value for (session-restore)'s consumer, `CodeEditorView`'s
    /// `cursorToRestore` parameter — stashed by `restore(fromJSON:)`, cleared by the next
    /// `noteCursorMoved(_:)` call (the editor's restore-consume reports back through the cursor
    /// callback, which fires `noteCursorMoved` and clears this).
    private(set) var pendingCursorRestore: Int?

    /// The in-flight debounced autosave write, cancel-and-rescheduled on every edit (mirrors
    /// `CodeEditorView`'s `pendingHighlight` idiom). Nil when nothing is pending. Cancelled by
    /// `cancelPendingAutosave()` on a file switch / explicit save, and its work item re-checks
    /// dirtiness at fire time so a straggler that outlives a switch or reload is a no-op.
    private var pendingAutosave: DispatchWorkItem?

    /// (external-change-watch, Tier 1) The vnode watcher on the one open file. Its `onChange` is
    /// delivered on the main queue, so `MainActor.assumeIsolated` (the same idiom as the
    /// resign-active observer and `WindowCloseGuardProxy`) can hop straight into the `@MainActor`
    /// flush consumer. `lazy` because the callback captures `self`, which a stored-property default
    /// initializer cannot reference; it is assigned exactly once on first file open. Cleans up via
    /// its own `deinit` (its source uses `[weak self]`, so it never keeps this model alive).
    private lazy var fileWatcher = FileWatcher(onChange: { [weak self] in
        // Delivered on the main queue by the wrapper, so this runs on the main actor.
        MainActor.assumeIsolated { self?.fileDidChangeOnDisk() }
    })

    /// (external-change-watch, Tier 1) The signature of the content FEdit itself last put on disk
    /// (via `saveOpenFile`) or last loaded (via `applyLoadedFile`). It is the self-write suppression
    /// key: a vnode event whose current signature equals this is an echo of FEdit's own write and is
    /// ignored; an unequal signature is a genuine external change.
    private var lastWriteSignature: FileSignature?

    /// (external-change-watch, Tier 3) The recursive FSEvents watcher on the sidebar roots. Its
    /// `onChange` carries the changed-path batch (delivered on the main queue), which
    /// `handleTreeChange` filters through the tree-skip gate before deciding whether to rescan.
    /// `lazy` for the same reason as `fileWatcher` (the callback captures `self`); (re)pointed from
    /// `addFolders`/`removeRoot`. Cleans up via its own `deinit`.
    private lazy var treeWatcher = DirectoryTreeWatcher(onChange: { [weak self] paths in
        // Delivered on the main queue by the wrapper, so this runs on the main actor.
        MainActor.assumeIsolated { self?.handleTreeChange(paths) }
    })

    /// Token for the `NSApplication.didResignActiveNotification` observer that flushes a dirty
    /// buffer the moment the user leaves FEdit (Tier 3), collapsing the leave-app exposure window
    /// to ~0. (root-scan-consolidation) Held in an `ObservationToken` box whose own `deinit` removes
    /// the observer when this model is released: the removal used to live in `WorkspaceModel.deinit`,
    /// which — being nonisolated — could not legally read this `@MainActor` property at all.
    private var resignActiveObserver: ObservationToken?

    /// (git-changed-badge) A **dedicated serial** GCD queue — the *only* place the blocking git
    /// `Process` runs. Serial ⇒ at most one git job at a time (this alone bounds the app to a single
    /// live git process per window). It is **not** the Swift cooperative pool, so a blocking
    /// `readDataToEndOfFile()` never occupies a cooperative worker thread (see `GitStatus`).
    private let gitQueue = DispatchQueue(label: "com.fedit.git-status")

    /// (git-changed-badge) Burst coalescing without cancellation: `isRecomputing` is set while a git
    /// job is in flight, and any trigger during that window sets `recomputeAgain` so the in-flight
    /// job re-runs **exactly once** when it finishes. A `Task.cancel()` cannot stop an already-
    /// launched git `Process`, so cancellation-based coalescing is deliberately not used.
    private var isRecomputing = false
    private var recomputeAgain = false

    /// (root-scan-consolidation) This window's scan subsystem, and the home of every per-root scan
    /// record: the in-flight gate, the coalesced request and its force bit, the scan generation, the
    /// damping clocks and backoff, the armed trailing-edge timer, and the walks' cancellation tokens.
    /// Nine hand-drained members on this model moved in there: eight became one `[URL: RootScan]`,
    /// and the ninth — the per-root cancellation tokens — became the scheduler's nonisolated
    /// `TokenRegistry` (the only piece that has to be reachable from a `deinit`). Either way "drain a
    /// root" is now a single call (`noteRootRemoved`) instead of four sites that each had to
    /// remember all of it.
    ///
    /// It is also this model's scan **teardown**: releasing the model releases the scheduler, whose
    /// token registry cancels the in-flight walks from its own nonisolated `deinit`. That is why
    /// `WorkspaceModel` has no `deinit` at all any more (see `ObservationToken` for the other half).
    ///
    /// The two closures are the model seams the scheduler calls back through, always on the main
    /// actor: `currentNode` is the `roots` lookup (the diff baseline captured at walk start, and the
    /// entry-collection presence test), `land` is the landing splice. Both capture `self`
    /// **unowned** — the model owns the scheduler, never the other way round, and the scheduler's
    /// landing closure holds it weakly, so neither can outlive this model. **Trap, deliberately
    /// recorded: no teardown path may call these two closures.** `weak` + a guard was rejected as
    /// the alternative: it would silently swallow a landing during teardown instead of failing
    /// loudly on a real ownership bug.
    ///
    /// `lazy` because the closures capture `self`, which a stored-property default initializer
    /// cannot reference (the same reason `fileWatcher`/`treeWatcher` are lazy).
    private lazy var scanScheduler = RootScanScheduler(
        currentNode: { [unowned self] url in
            roots.first { $0.url == url }
        },
        land: { [unowned self] url, scanned, changed, force, report in
            // The generation check is the scheduler's; this seam answers the other half of the old
            // apply block's condition — is the root still in `roots`? — and performs the splice.
            // Everything below it is therefore scoped to a root that still has a section: nothing
            // here may publish state for a root the sidebar cannot show, because only `removeRoot`
            // drains such state and it has already run.
            guard let index = roots.firstIndex(where: { $0.url == url }) else { return false }
            if force || changed {
                roots[index] = scanned
                // (filter-walk-main-thread) **This line must stay INSIDE this branch.** The splice
                // above is the only mutation of a present root's tree, so it is the only event that
                // can stale the filter row cache — and this branch is exactly "a splice happened".
                // Moved one line down, outside the `if`, it would invalidate on every landing
                // including the structurally-unchanged damped ones (the `~/Library` drip under a
                // $HOME root, which lands repeatedly with `changed == false`), re-running the full
                // DFS per landing and resurrecting the main-thread walk this item removed — just at
                // the damping cadence instead of the render cadence. That is this item's known
                // resurrection hazard; it is silent (rows stay correct, only the cost returns), so
                // nothing but this comment guards it.
                filterRowCache.invalidate(url)
            }
            // The first walk of a freshly added root has landed, so the sidebar stops showing
            // "Scanning…" for it — whether or not the tree above republished (a genuinely empty root
            // scans to a value equal to its own placeholder). Guarded on membership because this is
            // an `@Published` set: an unguarded `remove` on a rescan of an already-scanned root
            // would fire `objectWillChange` (and re-render the sidebar) on every damped no-op walk.
            if initialScanRootURLs.contains(url) {
                initialScanRootURLs.remove(url)
            }
            // (tree-node-budget) The truncation flag, updated **outside** the splice branch above —
            // that placement is the whole point, not an oversight. The flag can flip while
            // `changed == false`: a tree sitting exactly at the budget boundary gains a file and
            // loses a node's worth of depth, so the walk refuses something it previously fitted while
            // the *spliced* tree compares equal — and a splice-branch-only update would leave the
            // notice stale (or never show it at all). Membership-guarded for the same reason the
            // `initialScanRootURLs` line above is: this is an `@Published` set, so an unguarded write
            // would fire `objectWillChange` and re-render the sidebar on every damped no-op walk.
            if report.truncated != truncatedRootURLs.contains(url) {
                if report.truncated {
                    truncatedRootURLs.insert(url)
                } else {
                    truncatedRootURLs.remove(url)
                }
            }
            // (git-changed-badge) No refresh here by design: every path that can *trigger* a walk
            // (`addFolders`, `refreshAll`, `removeRoot`, `createFile`) schedules one at trigger time,
            // so a per-landing one is redundant — and would re-run git after every damped no-op walk.
            return true
        }
    )

    /// Real language stub (SPEC §6.3's full enum arrives with (syntax-highlighting)): `true` for
    /// a `.md`/`.markdown` extension (case-insensitive), driving the preview column's visibility
    /// (SPEC §8).
    var isMarkdown: Bool {
        guard let url = openFile?.url else { return false }
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    /// The open file's display name for the window title, or `nil` when nothing is open.
    var openFileName: String? {
        openFile?.url.lastPathComponent
    }

    /// Whether File → Save should be enabled (SPEC §10): a file is open and has unsaved edits.
    var canSave: Bool {
        openFile?.isDirty == true
    }

    /// (new-file) The directory a File → New… file is created in (SPEC §7): the open file's parent
    /// when a file is open, else the first top-level root. `nil` only when there is neither an open
    /// file nor any root — the sole case where New… is disabled (`canCreateNewFile`). Because
    /// `removeRoot` leaves `openFile` intact, the open-file branch can still hold with `roots` empty
    /// (target = the open file's parent).
    var newFileTargetDirectory: URL? {
        openFile?.url.deletingLastPathComponent() ?? roots.first?.url
    }

    /// (new-file) Whether File → New… is enabled (SPEC §10): there is a target directory to create
    /// the file in (an open file's parent, or at least one root).
    var canCreateNewFile: Bool {
        newFileTargetDirectory != nil
    }

    /// The editor's full text buffer (SPEC §6.1), backed by `openFile`. The setter only marks
    /// the file dirty when the value actually changed, so programmatic loads — which replace
    /// `openFile` wholesale — never go through here and never mark a freshly opened file dirty.
    /// On a real edit it (re)arms the debounced autosave, so the on-disk file tracks the editor
    /// within `autosaveInterval` of the last keystroke (SPEC §7).
    var editorText: String {
        get { openFile?.text ?? "" }
        set {
            guard var file = openFile, file.text != newValue else { return }
            file.text = newValue
            file.isDirty = true
            openFile = file
            scheduleAutosave()
        }
    }

    init() {
        // Flush a dirty buffer the instant the user leaves FEdit for another app (Tier 3), so an
        // external tool (Terminal, Claude) that then edits the same file starts from the editor's
        // latest text — the leave-app exposure window collapses to ~0. `didResignActiveNotification`
        // is app-wide, so every per-window model observes it and each flushes its own buffer; a
        // clean or unfocused-file buffer is a cheap no-op inside `flushPendingAutosave`. AppKit
        // posts this on the main thread; `assumeIsolated` just states that to the compiler.
        // (root-scan-consolidation) Boxed so the observer is removed when *this model* is released,
        // by the box's own `deinit` — see `ObservationToken`. This class deliberately has no `deinit`
        // of its own: a nonisolated `deinit` cannot legally touch `@MainActor` stored properties, and
        // every job the old one did now belongs to something whose lifetime already ends here, or was
        // a defensive cancel whose work item is a fire-time no-op anyway.
        // - In-flight directory walks: cancelled by the scheduler's token registry (`scanScheduler`).
        // - Armed damped-rescan timers and the pending autosave: **not** cancelled any more. Each
        //   work item re-checks its precondition at fire time against a weakly-held owner — the
        //   autosave item holds this model `[weak self]`, the damped-rescan item holds the
        //   *scheduler* weakly (and the scheduler dies with this model, so the model is one hop
        //   removed) — so a straggler is a no-op; cancelling them only released a closure a little
        //   earlier (≤ 0.75 s for the autosave, ≤ 30 s or 3× the last walk for a damped rescan),
        //   which is not worth the bookkeeping this item exists to delete.
        resignActiveObserver = ObservationToken(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushPendingAutosave() }
        })
    }

    /// Sink for `CodeEditorView`'s `onCursorChange` callback (editor-core), including the
    /// synthetic report the coordinator fires right after consuming a restored cursor. Updates
    /// `cursorLocation` for the next snapshot, and clears `pendingCursorRestore` the first time
    /// this fires after a restore — the editor's one-shot restore-consume reports back through
    /// this same callback, so by the time it does, the seam has been used and must not be
    /// re-applied on a later document switch.
    func noteCursorMoved(_ location: Int) {
        cursorLocation = location
        pendingCursorRestore = nil
    }

    /// Adds each URL as a top-level root, standardizing it and skipping ones already present.
    /// Duplicate comparison resolves symlinks first (`/tmp` vs `/private/tmp` count as the same
    /// root) so it catches more than a plain standardized-path comparison would.
    ///
    /// (async-root-scan) Each accepted root is appended **synchronously, as an empty placeholder**,
    /// and its recursive walk is requested afterwards — so this returns in microseconds even for a
    /// home-scale folder, and `restore(fromJSON:)` no longer blocks launch behind a directory walk.
    ///
    /// The *synchronous* append is load-bearing well beyond the sidebar. Five separate "is this
    /// window pristine?" tests read `roots.isEmpty` — `restore(fromJSON:)`'s own guard, ContentView's
    /// Cmd+O mailbox drain and its late-`@SceneStorage` recovery, and `applyCLITokenIfNeeded`'s two
    /// checks either side of its one-turn hop — and if this were made fully async every one of them
    /// would report a *restoring* window as pristine for the whole duration of its restore, letting
    /// a CLI open or a late snapshot land on top of it. That is exactly the (cli-open) defect class.
    /// Do not "simplify" the placeholder away.
    func addFolders(_ urls: [URL]) {
        var existingResolvedPaths = Set(roots.map { $0.url.resolvingSymlinksInPath().path })
        var addedRootURLs: [URL] = []

        for url in urls {
            let standardized = url.standardizedFileURL

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            let resolvedPath = standardized.resolvingSymlinksInPath().path
            guard !existingResolvedPaths.contains(resolvedPath) else { continue }
            existingResolvedPaths.insert(resolvedPath)

            // (async-root-scan) Placeholder now, walk later. `children: []` (not `nil`) keeps it a
            // directory node for `OutlineGroup`, and the scheduler's generation bump makes a re-add
            // of a root whose previous walk is still unwinding discard that stale tree instead of
            // splicing it in under this fresh placeholder. Told to the scheduler **before** the
            // append, per `noteRootAdded`'s ordering contract.
            scanScheduler.noteRootAdded(standardized)
            roots.append(FileNode(url: standardized, name: standardized.lastPathComponent, isDirectory: true, children: []))
            initialScanRootURLs.insert(standardized)
            addedRootURLs.append(standardized)
        }

        // (external-change-watch, Tier 3) Re-point the recursive watcher at the current root set —
        // one of the two sites (with `removeRoot`) where that set changes. Safe on the
        // session-restore path too: the watcher uses `kFSEventStreamEventIdSinceNow`, so this does
        // not replay historical events into a launch-time rescan.
        treeWatcher.watch(roots: roots.map(\.url))

        // (git-changed-badge) A freshly added git root badges without waiting for activation. The
        // placeholder already carries the correct URL, so this needs nothing from the walk.
        scheduleGitRefresh()

        // (async-root-scan) Requested **after** the watcher is armed, deliberately: an external
        // change that lands mid-walk is then caught by the watcher and folded into the pending
        // re-run, instead of falling into a gap between "the walk read this directory" and "the
        // watcher started". Never damped — an initial scan is what the user just asked for.
        for url in addedRootURLs {
            scanScheduler.requestScan(of: url)
        }
    }

    /// Removes `root` from the sidebar. Disk untouched. Clears `selectedFileURL` if it points
    /// inside the removed root, so a later (open-save) doesn't hold a selection to a folder that
    /// is no longer shown. The selection test compares path *strings*, not tree contents, so it is
    /// correct even on a root that is still an unscanned placeholder.
    ///
    /// (async-root-scan, root-scan-consolidation) Returns immediately even with a walk of `root` in
    /// flight: the section disappears at once, and one `RootScanScheduler.noteRootRemoved` call
    /// drains every per-root scan record — its generation bump makes that walk's landing discard its
    /// result (the section can never reappear), its token stops the walk itself, and the recorded
    /// rescan request, the damping clocks and any armed trailing-edge timer go with it, so nothing
    /// survives to fire against a root that is gone. The in-flight gate is the one thing the drain
    /// leaves standing — it stays set until the walk's own landing clears it, because it is what
    /// keeps a re-add from starting a second concurrent walk of the same root.
    func removeRoot(_ root: FileNode) {
        roots.removeAll { $0.id == root.id }
        if let selectedFileURL,
           FileNode.path(selectedFileURL.path, isContainedIn: root.url.path) {
            self.selectedFileURL = nil
        }

        // (root-scan-consolidation) Drain this root's scan state — one call, **after** the removal
        // above, per `noteRootRemoved`'s ordering contract (its entry collection tests the root's
        // absence from `roots`). The "Scanning…" set is model-side view state, so it is cleared here.
        scanScheduler.noteRootRemoved(root.url)
        initialScanRootURLs.remove(root.url)
        // (filter-walk-main-thread) The third per-root drain, alongside the two above: a removed
        // root's cached filter rows are dead weight (and would be served again on a re-add, before
        // the fresh walk lands, if the entry survived). Same `invalidate` the splice branch calls —
        // one operation, deliberately not two names for the same whole-entry drop.
        filterRowCache.invalidate(root.url)
        // (tree-node-budget) The fourth: a removed root owes no truncation notice, and a re-add must
        // not inherit the previous incarnation's flag while its own first walk runs. The scheduler's
        // `noteRootRemoved` above dropped the report whose node count that notice interpolates.
        truncatedRootURLs.remove(root.url)

        // (external-change-watch, Tier 3) Re-point the watcher at the reduced root set so the
        // removed root is no longer watched (an empty set tears the stream down entirely).
        treeWatcher.watch(roots: roots.map(\.url))

        // (git-changed-badge) Recompute the badge set for the reduced root set, mirroring
        // `addFolders`: a removed git root's file URLs would otherwise linger in `changedFileURLs`.
        // The coalescing re-run this schedules also self-corrects any stale in-flight result.
        scheduleGitRefresh()
    }

    /// Rescans every root in place (SPEC §5.1: Refresh rescans all folders). Republishes a root
    /// **only when its rescanned structure actually differs** (external-change-watch, Tier 3): a
    /// watcher-driven rescan whose surviving event turned out structure-neutral (e.g. an in-place
    /// content write to an unopened file) then does not thrash the sidebar or re-fire
    /// (session-restore)'s snapshot `.onChange`. The root URL set is unchanged, so the tree watcher
    /// needs no re-point here.
    ///
    /// (async-root-scan) **Returns before the rescans complete.** Each root's walk runs on the
    /// scheduler's scan queue and splices itself into `roots` when it lands, so no caller may assume
    /// the tree is up to date on return — and none does: `handleTreeChange` and SidebarView's Refresh
    /// are fire-and-forget, and `createFile` stashes `pendingNewFileURL` for an open that reads the
    /// file straight from disk without consulting the tree (SPEC §5.2's "appears after the automatic
    /// refresh that creation triggers" still holds, just a beat later). The diff-guard contract above
    /// now lives in `RootScanScheduler`'s landing (this model's `land` seam, on `scanScheduler`).
    ///
    /// `force` bypasses the diff-guard and always republishes: the explicit user "Refresh" action
    /// (SidebarView) must feel responsive and re-publish unconditionally, whereas the watcher/tree
    /// paths call it with the default so a structure-neutral event doesn't thrash the sidebar.
    /// `force` also decides damping, and can, because `force == false` is *exactly* the watcher
    /// path: `handleTreeChange` is this function's only non-forced caller, and it is the drip that
    /// has to be damped (see `RootScanScheduler.minRescanGap`). An explicit user Refresh is never
    /// damped.
    func refreshAll(force: Bool = false) {
        for root in roots {
            scanScheduler.requestScan(of: root.url, force: force, damped: !force)
        }
        // (git-changed-badge) The changed-set is a separate `@Published` property, **independent of
        // the structural diff**: a structure-neutral event (an in-place content edit to a tracked
        // file) leaves `roots` unchanged yet still changes git status, so recompute the badge set
        // unconditionally here — and without waiting for the walks, which may be damped or minutes
        // long, so a badge refresh is never held hostage to a tree rescan.
        scheduleGitRefresh()
    }

    /// (filter-walk-main-thread) Filter mode's rows for one root (SPEC §5.4): every file under
    /// `root` whose root-relative path matches `query`, in the scanner's depth-first folders-first
    /// order — the same list `SidebarView.flatRows` used to rebuild inline on every render.
    ///
    /// `query` is **passed in already parsed**, not re-derived from `filterText`: `SidebarView.body`
    /// parses once per render for its tree-vs-filter mode decision and hands that value down, so the
    /// render still costs exactly one parse however many roots are open.
    ///
    /// The `filesWithRelativePaths()` walk lives in the provider closure and therefore runs only on
    /// a cache miss — i.e. once per root per splice, not once per render. It is the **only** call
    /// site of that walk in the app target; adding another would re-open the defect.
    func filteredMatches(for root: FileNode, query: FilterQuery) -> [FilterRowCache.Match] {
        filterRowCache.rows(for: root.url, query: query) {
            root.filesWithRelativePaths().map { FilterRowCache.Match(path: $0.path, node: $0.node) }
        }
    }

    /// (git-changed-badge) The one public trigger for recomputing the changed-file badge set (SPEC
    /// §5.6). Every caller — save, manual Refresh, add-folders, app activation, and the best-effort
    /// external-change hook — funnels here. Runs on the main actor; the blocking git work hops to
    /// the dedicated `gitQueue` and back.
    ///
    /// Coalescing: while a recompute is in flight (`isRecomputing`), further triggers set
    /// `recomputeAgain` and the running job re-runs exactly once when it finishes — so a burst never
    /// spawns concurrent git processes. A 200 ms debounce collapses an event storm before the git
    /// job launches. `repoRoots` is recomputed on each entry, so a roots change mid-flight is
    /// honored by the pending re-run. Capturing `gitQueue` strongly in the continuation means a
    /// deallocated window can never strand an unresumed continuation.
    func scheduleGitRefresh() {
        let repoRoots = roots.map(\.url).filter(GitStatus.isRepositoryRoot)
        guard !repoRoots.isEmpty else {
            // A window with no git roots clears cheaply — no git job spawned. The clear is guarded
            // on non-emptiness because `changedFileURLs` is `@Published`: an unconditional assignment
            // would fire `objectWillChange` on every call (save, activation, refresh) in a window
            // that has no git roots at all, which is the common case for a plain folder window.
            if !changedFileURLs.isEmpty {
                changedFileURLs = []
            }
            recomputeAgain = false
            return
        }
        if isRecomputing {
            recomputeAgain = true
            return
        }
        isRecomputing = true
        let queue = gitQueue
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Set<URL>, Never>) in
                queue.async {
                    var union = Set<URL>()
                    for root in repoRoots {
                        union.formUnion(GitStatus.changedFileURLs(inRepositoryRoot: root))
                    }
                    continuation.resume(returning: union)
                }
            }
            guard let self else { return }
            // (git-changed-badge) If every git root was removed while this job was in flight (e.g.
            // the last git root removed, whose early-return clear this stale non-empty `result`
            // would otherwise overwrite), re-derive repo-root existence on the main actor at
            // assignment time and assign the empty set instead of restaling the cleared one.
            let stillHasRepoRoots = self.roots.map(\.url).contains(where: GitStatus.isRepositoryRoot)
            self.changedFileURLs = stillHasRepoRoots ? result : []
            self.isRecomputing = false
            if self.recomputeAgain {
                self.recomputeAgain = false
                self.scheduleGitRefresh()
            }
        }
    }

    /// (external-change-watch, Tier 3) The tree watcher's main-actor consumer + skip gate. FSEvents
    /// has no self-write suppression, and under always-on autosave the open file is rewritten every
    /// ~0.75 s while typing (with git-status refresh shelling out to `git`, which writes under
    /// `.git`, on save/activation) — so an ungated stream would fire a full recursive rescan of
    /// every root plus a whole-sidebar re-diff on FEdit's own routine writes. (Since
    /// (async-root-scan) that walk is off-main and damped, so it no longer freezes the window — but
    /// it is still a walk of the whole tree, and this gate is still the cheapest place to stop it.)
    /// Filter the batch first:
    /// - drop the open file's own path (its content is handled by the Tier 1 vnode watcher and it
    ///   changes no tree *structure*);
    /// - drop any path the scanner would not surface anyway — `TreeSkipGate`, driven per path by
    ///   `isSkippedTreePath` below: dot components, skip-named intermediates, and (since
    ///   (watcher-scan-skip-parity)) the containing root's own recorded scan verdicts.
    /// Only if a path survives is a rescan worth doing; `refreshAll` then republishes only on a real
    /// structural diff.
    private func handleTreeChange(_ paths: [String]) {
        // Canonicalize the gate's comparison paths (Fix 3) so an event under a firmlink root still
        // matches: FSEvents already delivers realpaths (`/private/tmp/...`), while
        // `resolvingSymlinksInPath()` deliberately keeps the `/tmp`, `/var`, `/etc` firmlinks
        // unresolved — without canonicalizing the roots/open-file side, an event under such a root
        // fails the prefix match and is wrongly treated as outside-all-roots (no rescan ever). Only
        // the roots and the open-file path (a handful) need `realpath(3)`; the FSEvents batch is
        // already canonical, so we do NOT syscall over every changed path — that would pay realpath
        // cost on thousands of paths (npm install, git checkout) the skip gate then discards.
        //
        // (watcher-scan-skip-parity) Built as **pairs**, once per batch: the skip gate needs both
        // halves of each root — the canonical path to test containment and derive below-root
        // components against, and that root's recorded scan verdicts. A bare `[String]` of canonical
        // paths, as this was before, destroys that association irrecoverably.
        //
        // The record is **resolved here**, once per root per batch, not per path: `TreeSkipGate`'s
        // statics-first allocation invariant covers only what happens *inside* the gate, and a
        // `scanScheduler.scans[…]?.skipRecord` written as its argument would be evaluated before the
        // statics ran — a `URL`-keyed dictionary lookup (hashing a URL) plus a `SkipRecord` copy for
        // every `.git` write in the burst, i.e. exactly the per-path cost the gate's rule ordering
        // exists to avoid. Resolving it up front is also free of staleness: this runs on the main
        // actor in one synchronous turn and `scans` is main-actor state, so no landing can interleave
        // between the snapshot and its uses.
        let openURL = openFile?.url
        let openFilePath = openURL.map { canonicalPath($0.resolvingSymlinksInPath().path) }
        let rootPairs = roots.map {
            (
                canonicalPath: canonicalPath($0.url.resolvingSymlinksInPath().path),
                skipRecord: scanScheduler.scans[$0.url]?.skipRecord
            )
        }
        let changedPaths = paths

        // (Fix 1) Recreate-after-delete recovery. An external `rm` of the open file drives the vnode
        // `fileWatcher` dormant (`isActive == false`) once its re-arm retries give up, and nothing
        // else re-arms it — so a later external recreate + edit would go undetected. The tree watcher
        // still covers the open file's parent (when it is under a watched root), so if the open
        // file's own path reappears in this batch while the vnode watcher is dormant, re-establish it
        // and re-run the change consumer (which stats the recreated file and, via the
        // signature/content gate, reloads a clean buffer or raises the indicator on a dirty one).
        // This runs independently of the skip gate below, which drops the open file's own path. An
        // open file outside every current root can't be recovered this way — a documented limitation
        // (SPEC §11), left as-is here rather than crashing. The `isActive == false` guard prevents
        // double-arming an already-active watcher.
        if let openURL, let openFilePath, !fileWatcher.isActive,
           rootPairs.contains(where: { FileNode.path(openFilePath, isContainedIn: $0.canonicalPath) }),
           changedPaths.contains(openFilePath) {
            fileWatcher.watch(openURL.resolvingSymlinksInPath())
            fileDidChangeOnDisk()
        }

        let hasSurvivor = changedPaths.contains { path in
            if let openFilePath, path == openFilePath { return false }
            // (Fix 2) `Data.write(options: .atomic)` drops a sibling temp named
            // `<openFileName>.sb-XXXXXXXX-YYYYYY` next to the open file; it is neither the open-file
            // path nor a skip-dir, so without this every autosave/save would force a full recursive
            // rescan of every root. Scoped to the open file's own temp so genuine external atomic
            // saves of other files still trigger a rescan.
            if let openFilePath, isOwnAtomicWriteTemp(path, openFilePath: openFilePath) { return false }
            return !isSkippedTreePath(path, rootPairs: rootPairs)
        }
        guard hasSurvivor else { return }

        refreshAll()
    }

    /// Whether a rescan would ignore `path`. A path outside every watched root is skipped (nothing a
    /// rescan touches); otherwise the components **below** the longest containing root are handed to
    /// `TreeSkipGate` together with that root's recorded scan verdicts.
    ///
    /// **Parity with the scanner (watcher-scan-skip-parity).** This used to re-implement
    /// `FileNode`'s skip rules as a dot-prefix test plus `FileNode.skippedDirectoryNames`, and the
    /// two drifted in three measured ways: a `UF_HIDDEN` non-dot directory (`~/Library` under a
    /// `$HOME` root) passed this gate although the scanner dropped it, driving damped full rescans
    /// that could never surface anything; a plain **file** named `node_modules` was dropped here
    /// although the scanner keeps it, so a genuine change to it never auto-refreshed; and a
    /// TCC-denied directory showed empty with nothing recorded, giving the `~/Library` storm shape a
    /// second source. Parity is now **structural**: the scanner owns one skip predicate, records what
    /// it decided (`SkipRecord`, on `RootScan.skipRecord`), and this gate asks rather than re-derives.
    /// The no-syscall-per-changed-path constraint is untouched — the record is built where the
    /// syscalls already happen.
    ///
    /// What remains conservative, deliberately, is the **final** component: the gate never drops an
    /// event that names an entry directly, because that event is what un-sticks a stale record (see
    /// `TreeSkipGate.isSkipped(belowRootComponents:record:)` for the full argument and the residual).
    ///
    /// Not assertion-pinned: this function (AppKit in the file), only review-traced. The gate itself
    /// and its component derivation are pinned by `scripts/TreeSkipGateTests`.
    private func isSkippedTreePath(_ path: String, rootPairs: [(canonicalPath: String, skipRecord: SkipRecord?)]) -> Bool {
        // The LONGEST containing root wins (root-slash-prefix-match review): roots can nest — and a
        // "/" root contains everything — so a shorter ancestor root must not shadow a more specific
        // one, or the components *between* the two (say, a dot-directory the specific root
        // deliberately lives under) would be tested here and wrongly skip the event.
        //
        // For the two **static** rules that argument was an exact equivalence: longest-match is the
        // same as "skipped only if skipped under every containing root", because the longest root's
        // relative components are a suffix of every other containing root's, so a static skip seen
        // from the longest root is seen from every other one too, and vice versa.
        //
        // With per-root **records** it is no longer an equivalence, and the direction is worth
        // stating: longest-match can skip where the every-root reading would rescan (the longest
        // root's record names the entry, a shorter root's record is absent or older), never the
        // reverse. That is the harmless direction, because a record's verdicts are properties of the
        // *entry* — its hidden flag, its name, its readability — not of the root it was reached
        // from, so with fresh records every containing root agrees and the two readings coincide.
        // They diverge only when a shorter root's record is stale or has not landed, and then the
        // extra events longest-match drops are ones that root's own rescan would not have surfaced
        // either; what remains is exactly the staleness residual `TreeSkipGate.isSkipped` already
        // records (un-stuck by an event naming the entry itself, by Refresh, or by relaunch).
        let containingRoots = rootPairs.filter { FileNode.path(path, isContainedIn: $0.canonicalPath) }
        guard let root = containingRoots.max(by: { $0.canonicalPath.count < $1.canonicalPath.count }) else {
            return true
        }
        // The record travels in the pair, resolved once per batch by `handleTreeChange` — both
        // because `scans` is keyed by the root's standardized URL rather than the canonical path the
        // containment test needs, and because looking it up here would run per changed path, ahead
        // of the gate's own statics-first rules. `nil` (no walk has landed yet) leaves those two
        // static rules standing, exactly as this function behaved before the record existed.
        return TreeSkipGate.isSkipped(
            belowRootComponents: TreeSkipGate.belowRootComponents(of: path, root: root.canonicalPath),
            record: root.skipRecord
        )
    }

    /// (external-change-watch, Fix 2) Whether `path` is FEdit's own `Data.write(options: .atomic)`
    /// temp for the open file — a sibling in the open file's parent directory whose last component
    /// is `<openFileLastComponent>.sb-…`. Both arguments are already canonicalized by the caller, so
    /// the parent-directory equality is a straight string compare.
    private func isOwnAtomicWriteTemp(_ path: String, openFilePath: String) -> Bool {
        guard (path as NSString).deletingLastPathComponent
            == (openFilePath as NSString).deletingLastPathComponent else { return false }
        let name = (path as NSString).lastPathComponent
        let openName = (openFilePath as NSString).lastPathComponent
        return name.hasPrefix(openName + ".sb-")
    }

    /// (external-change-watch, Fix 3) Fully resolves `path` with `realpath(3)` — including the
    /// `/tmp`, `/var`, `/etc` firmlinks that `resolvingSymlinksInPath()` deliberately leaves
    /// unresolved — so the tree-skip gate compares FSEvents realpaths against consistently
    /// canonicalized root/open-file paths. Idempotent on already-resolved paths; falls back to the
    /// raw path when the target no longer exists (a deleted atomic-write temp, or mid-rename).
    private func canonicalPath(_ path: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        return realpath(path, &buf) != nil ? String(cString: buf) : path
    }

    /// Reads `url`'s contents as text (SPEC §7): NUL bytes anywhere in the data mean the file is
    /// treated as binary and refused; otherwise UTF-8 is tried first, then Latin-1. `.isoLatin1`
    /// decoding of arbitrary bytes always succeeds, so the fallback is total for non-binary data.
    ///
    /// Before touching disk, stats `url` and refuses anything that isn't a bounded regular file:
    /// a sidebar row can point at a FIFO, socket, or device node (an unbounded `read()` on those
    /// can hang forever) or a multi-gigabyte file (which would exhaust memory), neither of which
    /// `Data(contentsOf:)` guards against on its own.
    private func loadText(from url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw FileLoadError.notRegularFile
        }
        if let fileSize = values.fileSize, fileSize > Self.maxReadableFileSize {
            throw FileLoadError.tooLarge
        }

        let data = try Data(contentsOf: url)

        guard !data.contains(0) else {
            throw FileLoadError.binaryFile
        }

        if let utf8Text = String(data: data, encoding: .utf8) {
            return utf8Text
        }

        return String(data: data, encoding: .isoLatin1)!
    }

    /// Shared success-path assignment for both `loadFile` (interactive open) and
    /// (session-restore)'s silent restore-open: replaces `openFile` with a clean (non-dirty)
    /// buffer and syncs `selectedFileURL` to `url`. Factored out so the two routes' success
    /// behavior can never drift apart.
    ///
    /// Cancels any pending autosave **first** (coordination seam): this is the file-switch load
    /// path, so a stale debounced write armed against the previous buffer must never fire and
    /// clobber the file being loaded here. (External reloads do **not** route through this — they
    /// re-arm the watcher — so (external-change-watch) has its own reload path that likewise calls
    /// `cancelPendingAutosave()` first.)
    private func applyLoadedFile(url: URL, text: String) {
        cancelPendingAutosave()
        openFile = OpenFile(url: url, text: text, isDirty: false)
        selectedFileURL = url
        // (external-change-watch, Tier 1) (Re)arm the vnode watcher on the freshly loaded file and
        // baseline the self-write key to the just-loaded content (a change *after* load differs
        // from it). The symlink-resolved path is used for both, matching `saveOpenFile`'s write
        // target so watcher, signature, and writer all track the same inode. A reload does **not**
        // route through here — that would re-arm onto an unchanged fd; see `reloadOpenFileFromDisk`.
        let resolved = url.resolvingSymlinksInPath()
        fileWatcher.watch(resolved)
        lastWriteSignature = FileSignature.of(resolved)
        openFileChangedOnDisk = false
    }

    /// Loads `url` into the editor unconditionally — no dirty check, no no-op-on-already-open
    /// guard; both live in `requestOpen`, the only public entry point for a sidebar selection.
    /// On success: assigns via `applyLoadedFile`. On failure: alerts (binary-refusal wording vs.
    /// a generic read-error wording) and reverts `selectedFileURL` back to whatever was already
    /// open, so the sidebar highlight doesn't follow a selection that failed to load
    /// (criterion 3).
    private func loadFile(_ url: URL) {
        do {
            let text = try loadText(from: url)
            applyLoadedFile(url: url, text: text)
        } catch {
            presentReadErrorAlert(for: url, error: error)
            selectedFileURL = openFile?.url
        }
    }

    /// (session-restore)'s silent, non-interactive counterpart to `loadFile`: reuses the same
    /// `loadText(from:)` core and the same success assignment (`applyLoadedFile`), but on
    /// failure swallows the error with no alert and no `selectedFileURL` revert — SPEC §9's "a
    /// missing file is simply not opened". Never routes through `requestOpen` (no dirty check,
    /// no dialog) — restore only ever runs against a pristine, freshly created model.
    private func silentlyLoadFile(_ url: URL) {
        guard let text = try? loadText(from: url) else { return }
        applyLoadedFile(url: url, text: text)
    }

    /// (external-change-watch, Tier 1) The `fileWatcher` flush consumer, invoked on the main actor
    /// once per coalesced vnode event. Decides between echo-suppress, no-op, clean reload, and
    /// dirty-conflict, in that order:
    ///
    /// 1. Nothing open ⇒ ignore.
    /// 2. `stat` fails ⇒ the file is currently gone (external delete, or mid-rename): retain the
    ///    buffer, do nothing (SPEC §11: a later save recreates it at the old path).
    /// 3. **Self-write gate.** Current signature equals `lastWriteSignature` ⇒ this is the content
    ///    FEdit last wrote or loaded (Cmd+S / autosave / load); ignore. This is what keeps saves and
    ///    autosaves silent even while the buffer runs ahead of disk during active autosaved editing.
    /// 4. Read failure (transient, or the external file is now binary / over the 100 MB cap) ⇒ skip;
    ///    a later event retries.
    /// 5. Disk content byte-identical to the buffer (external touch, or an external write of what we
    ///    already have) ⇒ rebaseline and do nothing. This sits *after* the step-3 gate, so it only
    ///    suppresses a needless reload — it can never recover a change the signature gate dropped.
    /// 6. Genuine external change: clean buffer ⇒ reload (external wins); dirty buffer ⇒ keep the
    ///    in-editor version (no clobber) and raise `openFileChangedOnDisk`, rebaselining the key so
    ///    the same external state does not re-fire the indicator on the next coalesced event.
    func fileDidChangeOnDisk() {
        guard let file = openFile else { return }

        let resolved = file.url.resolvingSymlinksInPath()
        guard let currentSignature = FileSignature.of(resolved) else { return }
        guard currentSignature != lastWriteSignature else { return }
        guard let diskText = try? loadText(from: file.url) else { return }

        if diskText == file.text {
            lastWriteSignature = currentSignature
            openFileChangedOnDisk = false
            return
        }

        if file.isDirty {
            openFileChangedOnDisk = true
            lastWriteSignature = currentSignature
        } else {
            reloadOpenFileFromDisk(text: diskText, signature: currentSignature)
        }

        // (git-changed-badge) Best-effort liveness: a genuine external edit to the open file (from
        // another tool while FEdit stays active) changes working-tree vs HEAD, so recompute the
        // badge set. Reached only past the self-write gate above, so FEdit's own autosave never
        // double-fires here (that write triggers `scheduleGitRefresh()` from `saveOpenFile`). This
        // is a bonus trigger, not a core one — save/Refresh/activation stand on their own.
        scheduleGitRefresh()
    }

    /// (external-change-watch, Tier 1) The clean-buffer reload path. Deliberately does **not** route
    /// through `applyLoadedFile` (which re-arms the watcher onto an unchanged fd) — the fd is fine,
    /// only the buffer changes. Cancels any pending autosave **first**, before replacing `openFile`,
    /// so no straggler debounce survives the reload and later writes stale pre-reload text over the
    /// just-loaded content (the coordination-seam hard requirement). Replaces the buffer in place
    /// with the **same URL** so the editor's `documentID` is unchanged and `CodeEditorView` takes
    /// its external-change branch (caret clamped + scroll preserved), not the file-switch branch.
    /// The just-read on-disk signature becomes the new baseline.
    func reloadOpenFileFromDisk(text: String, signature: FileSignature) {
        cancelPendingAutosave()
        guard let file = openFile else { return }
        openFile = OpenFile(url: file.url, text: text, isDirty: false)
        lastWriteSignature = signature
        openFileChangedOnDisk = false
    }

    /// The sidebar's single entry point for opening a file (both tree rows and filter-query's
    /// flat filtered rows share `FileRow`'s tap action, so both route through here — criterion
    /// 9a). No-op if `url` is already the open file (criterion 18: re-clicking the open file's
    /// own row never reloads or resets the caret). Otherwise runs `resolveDirtyFile(context:)`
    /// with the `.fileSwitch` context: `.proceed` loads `url`; `.cancel` (a failed autosave flush)
    /// reverts the published selection back to the file that's still open — because writing
    /// `selectedFileURL` has zero side effects (see its doc comment), this only moves the sidebar
    /// highlight and cannot itself trigger another load.
    func requestOpen(_ url: URL) {
        guard url != openFile?.url else { return }

        switch resolveDirtyFile(context: .fileSwitch) {
        case .proceed:
            loadFile(url)
        case .cancel:
            selectedFileURL = openFile?.url
        }
    }

    /// The dirty-file guard (SPEC §7): run before a file switch, and — via the `WindowCloseGuard`
    /// proxy — before a window close or app quit. Synchronous and app-modal, so the close/quit
    /// path reuses it unchanged. Autosave is unconditional now, so this is a **silent flush-and-
    /// check**, not the old four-button prompt: a clean or absent buffer proceeds untouched; a
    /// dirty buffer is flushed through `saveOpenFile`.
    ///
    /// Cancels any pending debounced autosave **first** (D3): the flush writes the buffer
    /// synchronously, so a straggler debounce firing behind whatever the caller does next must not
    /// re-write a buffer a discard/close is about to abandon.
    ///
    /// On a flush **failure** the behavior forks on `context`:
    /// - `.fileSwitch` aborts the switch (`.cancel`); `saveOpenFile` has already shown the "Cannot
    ///   Save File" alert and the caller reverts the sidebar selection — no second dialog.
    /// - `.closeOrQuit` shows the sole surviving unsaved-changes dialog — the minimal two-button
    ///   "Close Without Saving / Cancel" escape — so a persistently-unwritable location (read-only
    ///   dir, full or unmounted volume) can never make the app un-quittable.
    func resolveDirtyFile(context: DirtyContext) -> DirtyResolution {
        guard openFile?.isDirty == true else { return .proceed }

        cancelPendingAutosave()
        // `.fileSwitch` wants the "Cannot Save File" alert on a flush failure (criterion 8);
        // `.closeOrQuit` flushes silently so its sole `presentUnsavedCloseEscape()` dialog is the
        // only modal — SPEC's single-escape-dialog rule.
        let alertOnFail = (context == .fileSwitch)
        if saveOpenFile(alertOnFailure: alertOnFail) {
            return .proceed
        }

        switch context {
        case .fileSwitch:
            return .cancel
        case .closeOrQuit:
            return presentUnsavedCloseEscape()
        }
    }

    /// The sole surviving unsaved-changes dialog — shown only when a **close/quit** flush keeps
    /// failing (`resolveDirtyFile(context: .closeOrQuit)`), never on a plain file switch. Minimal
    /// by design: it exists solely so a persistently-failing save can't make the app un-quittable.
    /// "Cancel" (first, the default) keeps the window open / aborts the quit and owns the Return key;
    /// it also gets the Escape key equivalent automatically from AppKit for its title, so both Return
    /// and Escape resolve to the safe action. "Close Without Saving" (last) discards the unsaved
    /// buffer and proceeds.
    private func presentUnsavedCloseEscape() -> DirtyResolution {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't save '\(openFile?.url.lastPathComponent ?? "")'"
        alert.addButton(withTitle: "Cancel")
        let closeButton = alert.addButton(withTitle: "Close Without Saving")
        closeButton.hasDestructiveAction = true

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return .proceed
        default:
            return .cancel
        }
    }

    private func presentReadErrorAlert(for url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot Open File"
        switch error {
        case FileLoadError.binaryFile:
            alert.informativeText = "\"\(url.lastPathComponent)\" appears to be binary and cannot be opened as text."
        case FileLoadError.notRegularFile:
            alert.informativeText = "\"\(url.lastPathComponent)\" is not a readable text file."
        case FileLoadError.tooLarge:
            alert.informativeText = "\"\(url.lastPathComponent)\" is too large to open (over 100 MB)."
        default:
            alert.informativeText = "\"\(url.lastPathComponent)\" could not be read: \(error.localizedDescription)"
        }
        alert.runModal()
    }

    /// Debounces an autosave write `autosaveInterval` after the last edit (mirrors
    /// `CodeEditorView.scheduleHighlight`): cancels any already-pending write and reschedules, so a
    /// typing burst coalesces into a single write ~0.75 s after the last keystroke. The work item
    /// re-checks `openFile?.isDirty` **at fire time** (not schedule time), so a straggler that
    /// outlives a file switch, an explicit save, or an (external-change-watch) reload finds a clean
    /// buffer and is a no-op. Saves silently (`alertOnFailure: false`) — a failing autosave in a
    /// read-only location must not throw a modal every tick; the persistent "Edited" subtitle is
    /// the passive signal, and the failure is surfaced at the next explicit save boundary (Cmd+S or
    /// the `resolveDirtyFile` flush). `[weak self]` so a closed window's model is neither kept
    /// alive nor fired.
    private func scheduleAutosave() {
        pendingAutosave?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            // Dispatched to `DispatchQueue.main` below, so this body runs on the main actor;
            // `assumeIsolated` states that to the compiler (matching the resign-active observer and
            // WindowCloseGuardProxy) so the `@MainActor` `openFile`/`saveOpenFile` access is sound.
            MainActor.assumeIsolated {
                guard let self, self.openFile?.isDirty == true else { return }
                self.saveOpenFile(alertOnFailure: false)
            }
        }
        pendingAutosave = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.autosaveInterval, execute: workItem)
    }

    /// Cancels and clears any pending debounced autosave. **Exposed and required** — part of the
    /// coordination seam: `applyLoadedFile` and `saveOpenFile`'s success branch call it internally
    /// so a stale timer from the previous buffer can never write the current one, and
    /// (external-change-watch) calls it at the top of its own reload path so a straggler autosave
    /// can't clobber a just-applied external reload.
    func cancelPendingAutosave() {
        pendingAutosave?.cancel()
        pendingAutosave = nil
    }

    /// Flushes a dirty buffer immediately, replacing the pending debounce with an eager write —
    /// used when the app resigns active (Tier 3), so leaving FEdit doesn't leave the last edits
    /// exposed for up to `autosaveInterval`. Cancels the debounce first (this write supersedes it),
    /// then writes silently (`alertOnFailure: false`, the same anti-spam rule as the debounce —
    /// resign-active is not an explicit save boundary, so a failure stays passive as "Edited" and
    /// surfaces at the next Cmd+S / switch / close / quit). A clean or absent buffer is a no-op.
    func flushPendingAutosave() {
        cancelPendingAutosave()
        if openFile?.isDirty == true {
            saveOpenFile(alertOnFailure: false)
        }
    }

    /// Writes the open file's text to disk atomically (SPEC §7: Cmd+S, and the always-on autosave
    /// flushes). Recreating a file that was deleted out from under the app needs no special
    /// handling — an atomic write to a path with nothing there just (re)creates it. On success
    /// clears `isDirty`, republishes `openFile`, and cancels any pending debounced write (an
    /// explicit/flush save makes it redundant). On failure alerts **only if `alertOnFailure`**
    /// (the debounced and resign-active autosaves pass `false` to stay silent — see
    /// `scheduleAutosave`) and leaves the file dirty. `false` means "still dirty" for callers that
    /// must abort a switch/close/quit on a failed save. `alertOnFailure` defaults to `true` so
    /// Cmd+S and the `resolveDirtyFile` flush stay source-compatible and always surface a failure.
    @discardableResult
    func saveOpenFile(alertOnFailure: Bool = true) -> Bool {
        guard var file = openFile else { return false }

        do {
            // `Data(String.utf8)` is a direct byte copy of the string's own UTF-8 storage — it
            // cannot fail the way `String.data(using:)`'s optional-returning API can. Atomic
            // write replaces whatever is at the destination path with a new regular file, so
            // writing to `file.url` directly would replace a symlink with a plain file instead
            // of updating its target; resolving symlinks first writes through to the real path.
            let resolved = file.url.resolvingSymlinksInPath()
            try Data(file.text.utf8).write(to: resolved, options: .atomic)
            file.isDirty = false
            openFile = file
            // (external-change-watch, Tier 1) The single shared post-write success branch, reached
            // by Cmd+S, the switch/close/quit flush, **and** the ~0.75 s debounced autosave — so
            // every write rebaselines the self-write key here. Capturing the signature *after* the
            // write accepts a microscopic race (an external write between write and stat is read as
            // the baseline and missed for that one change) per SPEC §11 last-writer-wins. Clear the
            // conflict flag (the write resolves it in-editor's favor), and re-arm the watcher only
            // if it went dormant — e.g. after an external delete this save has just re-created.
            lastWriteSignature = FileSignature.of(resolved)
            openFileChangedOnDisk = false
            if !fileWatcher.isActive {
                fileWatcher.watch(resolved)
            }
            cancelPendingAutosave()
            // (git-changed-badge) A save changes working-tree vs HEAD, so recompute the badge set;
            // the target file's row gains "(changed)" with no manual action (criterion 5a).
            scheduleGitRefresh()
            return true
        } catch {
            if alertOnFailure {
                presentSaveErrorAlert(for: file.url, error: error)
            }
            return false
        }
    }

    private func presentSaveErrorAlert(for url: URL, error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Cannot Save File"
        alert.informativeText = "\"\(url.lastPathComponent)\" could not be saved: \(error.localizedDescription)"
        alert.runModal()
    }

    /// Presents an `NSOpenPanel` restricted to directories, multi-select enabled, and adds the
    /// chosen URLs as roots on OK.
    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true

        if panel.runModal() == .OK {
            addFolders(panel.urls)
        }
    }

    /// Presents an `NSOpenPanel` restricted to directories, **single-select**, for the "Open
    /// Folder…" (Cmd+O) new-window flow: called only on a pristine (empty-`roots`) model when a
    /// Cmd+O-created window drains the launch mailbox on appear, so `addFolders` yields the chosen
    /// folder as this window's sole root. Cancel is a no-op, leaving the new window empty.
    func presentNewWindowFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            addFolders(panel.urls)
        }
    }

    // MARK: - (git-editor-wait) The `fedit --wait` claim

    /// The `<uuid>.claimed` file this window holds on behalf of a blocked `fedit --wait`, or `nil`
    /// (almost always — only a window created by a waiting shim ever has one). Written exactly once,
    /// by `ContentView.applyCLITokenIfNeeded`, at the moment this window is actually showing the
    /// file the shim asked for; deleting it is what unblocks the shim, so it is the window's
    /// promise, not a cache. See `WaitMarkers` for why the claim lives on disk.
    ///
    /// Deliberately **not** `@Published`: no view reads it, and publishing it would invalidate the
    /// whole window's body on an open — for state whose only reader is a window-close callback.
    var waitMarkerURL: URL?

    /// Unblocks the waiting `fedit --wait`, if this window was opened by one. Called from
    /// `WindowCloseGuardProxy.windowWillClose` (before it forwards, while this model is still
    /// alive) and from `AppDelegate.applicationWillTerminate`, which is why it has to be idempotent:
    /// clearing the property first means a second call has nothing to do, and a quit that closes
    /// windows first cannot double-unlink.
    ///
    /// A failed unlink is left as it is on purpose. The shim is not stranded by it — its phase-2
    /// liveness check ends the wait when this process goes away — and there is nothing useful to
    /// report from a window that is in the middle of closing.
    func releaseWaitMarker() {
        guard let marker = waitMarkerURL else { return }
        waitMarkerURL = nil
        try? FileManager.default.removeItem(at: marker)
    }

    // MARK: - New file creation (SPEC §7, §10)

    /// (new-file) The outcome of `createFile(named:)`. `.created` carries no inline message (the
    /// sheet dismisses itself); every failure case supplies the error the sheet shows while staying
    /// open.
    enum NewFileResult {
        case created
        case invalidName
        case duplicateName
        case writeFailed(String)

        /// The inline error to show in the sheet, or `nil` on success.
        var message: String? {
            switch self {
            case .created:
                return nil
            case .invalidName:
                return "Enter a file name that isn't empty, contains no “/” or “:”, and doesn't start with a dot."
            case .duplicateName:
                return "A file with that name already exists."
            case .writeFailed(let message):
                return message
            }
        }
    }

    /// (new-file) Presents the File → New… sheet in this (the focused) window. Defensively guards on
    /// `canCreateNewFile` even though the menu item is already `.disabled` when it is false.
    func presentNewFileSheet() {
        guard canCreateNewFile else { return }
        isPresentingNewFileSheet = true
    }

    /// (new-file) Validates `rawName` and, on success, writes an empty file in
    /// `newFileTargetDirectory` (SPEC §7). Rejects (→ `.invalidName`) an empty/whitespace name, a
    /// name containing `/` or `:`, `.`/`..`, or a leading-dot name — the last because `FileNode.scan`
    /// skips hidden files (SPEC §5.2), so a dotfile would be created but never appear in the sidebar.
    /// A name collision returns `.duplicateName` **without overwriting** (`.withoutOverwriting` also
    /// closes the check→write TOCTOU window); any other write failure returns `.writeFailed`. On
    /// success it rescans the root containing the new file (`force`, so the explicit action always
    /// republishes and the new row appears — subject to the target folder being expanded), stashes
    /// the standardized URL in `pendingNewFileURL` for `openPendingNewFileIfNeeded()`, and returns
    /// `.created`. It does **not** touch `isPresentingNewFileSheet` (the sheet dismisses itself) or
    /// open the file (that runs from the sheet's `onDismiss`).
    func createFile(named rawName: String) -> NewFileResult {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !name.contains("/"),
              !name.contains(":"),
              name != ".", name != "..",
              !name.hasPrefix(".") else {
            return .invalidName
        }

        guard let dir = newFileTargetDirectory else {
            return .writeFailed("No folder is open to create the file in.")
        }

        // Standardized so it compares equal to the sidebar's `FileNode.url` (also standardized) for
        // selection/highlight; the same URL is both the write target and the stashed pending URL.
        let fileURL = dir.appendingPathComponent(name).standardizedFileURL

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return .duplicateName
        }

        do {
            // `.withoutOverwriting` (not `.atomic`): an existing file is never clobbered — closing
            // the TOCTOU window between the check above and this write — and the content is 0 bytes,
            // so atomicity is moot. `.atomic`'s temp-then-rename would clobber an existing file.
            try Data().write(to: fileURL, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            return .duplicateName
        } catch {
            return .writeFailed(error.localizedDescription)
        }

        // (async-root-scan) Rescan **only the roots the new file landed under**, forced so the row
        // appears (SPEC §5.2). Plural, not `first(where:)`: roots may nest (`addFolders` dedupes on
        // exact path equality only), and each containing root renders its own section, so every one
        // of them gains the row. Rescanning the rest would re-walk — and reset the damping backoff
        // of — roots that provably cannot contain the file. The containment test is the shared
        // `FileNode.path(_:isContainedIn:)` helper (root-slash-prefix-match) — the same one
        // `removeRoot` and the tree-skip gate use. The fallback is reachable, not defensive:
        // `newFileTargetDirectory` is the open file's parent, and an open file can sit outside
        // every root (e.g. after its root was removed), in which case no root shows the new file
        // and the full refresh is simply the honest superset.
        let parent = fileURL.deletingLastPathComponent().path
        let containingRoots = roots.filter { FileNode.path(parent, isContainedIn: $0.url.path) }
        if containingRoots.isEmpty {
            refreshAll(force: true)
        } else {
            for root in containingRoots {
                scanScheduler.requestScan(of: root.url, force: true)
            }
            // (git-changed-badge) `refreshAll` would have scheduled this; the scoped path must too —
            // a walk's landing no longer refreshes the badge set (see this model's `land` seam on
            // `scanScheduler`).
            scheduleGitRefresh()
        }
        pendingNewFileURL = fileURL
        return .created
    }

    /// (new-file) Opens the file `createFile` just created, called from ContentView's
    /// `.sheet(onDismiss:)` so it runs only after the sheet is fully dismissed. Routes through
    /// `requestOpen` exactly like a sidebar-row tap — honoring the current dirty-switch behavior on
    /// the outgoing file (SPEC §7); on a `.cancel` outcome the new file stays created and visible but
    /// unopened and selection reverts. A no-op when nothing is pending (e.g. the sheet was
    /// cancelled).
    func openPendingNewFileIfNeeded() {
        guard let url = pendingNewFileURL else { return }
        pendingNewFileURL = nil
        requestOpen(url)
    }

    // MARK: - Session restore (SPEC §3, §9)

    /// The current restorable state as a plain value — no JSON encoding. Cheap to build and
    /// `Equatable`, so `ContentView`'s save `.onChange` can diff it on every body pass without
    /// running a `JSONEncoder`; only the (rarer) actual-change branch encodes, via `snapshotJSON()`.
    /// This is the single source of truth for the four persisted fields — `snapshotJSON()` encodes
    /// exactly this value, so their contents can never drift apart.
    var currentSnapshot: WorkspaceSnapshot {
        WorkspaceSnapshot(
            rootPaths: roots.map { $0.url.path },
            openFilePath: openFile?.url.path,
            filterText: filterText,
            cursorLocation: cursorLocation
        )
    }

    /// Builds the current per-window state as `WorkspaceSnapshot` JSON for `@SceneStorage`
    /// (ContentView, Tier 2). Encodes `currentSnapshot` (the single source of truth). Returns
    /// `nil` — never `""` — on encode failure, so the caller skips the write and keeps whatever
    /// snapshot is already stored; an empty write would erase a valid one. `.sortedKeys` keeps the
    /// byte output deterministic, so a JSON change is exactly a `currentSnapshot` change.
    func snapshotJSON() -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(currentSnapshot),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    /// Restores this window's state from a `WorkspaceSnapshot` JSON string (ContentView, Tier 2's
    /// `.onAppear`/late-arriving-`@SceneStorage` recovery). A no-op if the model already has
    /// roots or an open file — only a pristine, freshly created scene restores, which also means
    /// this never has to contend with an in-progress dirty-file guard. Silent throughout: no
    /// dialogs, no alerts (SPEC §7/§9) — a missing folder is dropped, a missing/unreadable file is
    /// simply not opened, and empty/corrupt JSON leaves the model exactly as it was (an empty
    /// pristine window).
    ///
    /// (async-root-scan) Returns without waiting for the roots to be scanned: `addFolders` appends
    /// each one synchronously as a placeholder and its recursive walk lands later, so a home-scale
    /// restored root no longer blocks launch (it used to freeze it for minutes). What still runs
    /// synchronously here is the one file read, bounded by the 100 MB open cap — SPEC §11. Note the
    /// ordering this preserves: `roots` is non-empty the moment this returns, which is what keeps
    /// the `roots.isEmpty` pristine tests meaningful (see `addFolders`).
    func restore(fromJSON json: String) {
        guard roots.isEmpty, openFile == nil else { return }
        guard let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(WorkspaceSnapshot.self, from: data) else { return }

        // `addFolders` already validates each path with `fileExists(atPath:isDirectory:)` and
        // skips anything that isn't an existing directory, so a deleted root is dropped silently
        // here for free (SPEC §9: "missing folder dropped silently") — no separate filter needed.
        addFolders(snapshot.rootPaths.map { URL(fileURLWithPath: $0) })

        filterText = snapshot.filterText

        if let openFilePath = snapshot.openFilePath {
            silentlyLoadFile(URL(fileURLWithPath: openFilePath))
        }

        // Written to both `pendingCursorRestore` (Tier 2's editor consumes it) and
        // `cursorLocation` directly (criterion 12): if only the stash were set, the immediate
        // post-restore snapshot save — which reads `cursorLocation`, not the pending stash —
        // would clobber the stored cursor with the model's default `0` before the editor ever
        // gets a chance to apply and report it back through `noteCursorMoved`. Gated on `openFile
        // != nil` — when the restored file didn't actually open, no editor mounts to consume and
        // clear `pendingCursorRestore`, so it would otherwise leak onto the next file the user
        // opens and snap its caret to this stale offset.
        if openFile != nil, let cursorLocation = snapshot.cursorLocation {
            pendingCursorRestore = cursorLocation
            self.cursorLocation = cursorLocation
        }
    }
}

/// (root-scan-consolidation) A `NotificationCenter` observer whose **release** removes it. The
/// removal used to be one line of `WorkspaceModel.deinit`; that `deinit` is nonisolated (as every
/// `deinit` of a `@MainActor` class is) and so could not legally read the `@MainActor` stored
/// property holding the token — one of the three strict-concurrency errors this item removed. Boxing
/// the token here moves the removal into a `deinit` that touches nothing isolated, and
/// `removeObserver` is thread-safe, so it is sound wherever the model's last release happens.
///
/// Declared at file scope rather than nested inside `WorkspaceModel`: a type nested in a `@MainActor`
/// type reads as inheriting that isolation, and this one must not.
private final class ObservationToken {
    private let observer: any NSObjectProtocol

    init(_ observer: any NSObjectProtocol) {
        self.observer = observer
    }

    deinit {
        NotificationCenter.default.removeObserver(observer)
    }
}
