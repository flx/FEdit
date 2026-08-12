//
//  LaunchCoordinator.swift
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

/// App-level, `@MainActor`-confined coordinator for the two flows that need a **new window** to
/// carry out work the user asked for from outside any window.
///
/// **1. "Open Folder…" (Cmd+O) folder picks** — `pendingNewWindowPicks`, a mailbox. The Cmd+O
/// command (`FileCommands`) increments it immediately before `openWindow(id: "editor")`; the next
/// pristine window drains exactly one on appear (`ContentView`) and presents
/// `WorkspaceModel.presentNewWindowFolderPanel()`. A brand-new `WindowGroup` scene is the only
/// scene guaranteed to be pristine (empty `@SceneStorage`), so this can never disturb a window
/// that already has content.
///
/// **2. (cli-open) External opens** — *not* a mailbox. `AppDelegate.application(_:open:)` turns
/// the incoming file URLs into `OpenRequest`s and parks them in `undispatched`; dispatch wraps
/// each in a `CLIOpenToken` and opens the `"cli-open"` `WindowGroup(for:)` **with that token as
/// the window's value**, so SwiftUI delivers the request to exactly the scene it creates for it
/// (`ContentView(cliToken:)`). Nothing is ever claimed from a shared queue, so no ordering between
/// window creation, session restore and `@SceneStorage` delivery can hand a request to *another*
/// window — the reason this is a typed payload and not a queue the scenes race for. Each token
/// carries a fresh `UUID`, so `openWindow(value:)`'s equal-value dedup can never reuse an existing
/// (or restored) window.
///
/// **The token invariant**: *a token is applied at most once, only by the process that issued it,
/// and only to a scene that is still pristine at apply time.* The system persists a
/// `WindowGroup(for:)` value, so a restored CLI window is handed its **old** token again — and it
/// must not re-run that open on top of the window's own restored state. `issuedTokenIDs` /
/// `wasIssuedThisProcess(_:)` is what makes that structural rather than a timing argument: a token
/// from a previous launch is not in the set, so `ContentView` can never apply it, whatever order
/// the window value, session restore and `@SceneStorage` arrive in. Accepted consequence: a CLI
/// window quit before its first `@SceneStorage` write restores empty rather than re-applying its
/// file.
///
/// Dispatch is held only until `applicationDidFinishLaunching` (`isSettled`), because before that
/// there is no scene machinery to open a window with — not for correctness. The one piece of
/// timing left is `openNewWindow` being nil until some scene has appeared and registered it;
/// requests simply stay in `undispatched` until then and are re-dispatched by the retry timer or
/// by the next `registerWindowOpener`.
///
/// Plain (non-`@Published`) storage, not an `ObservableObject`: `ContentView` mutates/reads these
/// at discrete lifecycle moments, never observes them. A singleton is an accepted trade-off (tiny,
/// `@MainActor`-confined) over plumbing an `@EnvironmentObject` into `Commands` and `AppDelegate`.
@MainActor
final class LaunchCoordinator {
    static let shared = LaunchCoordinator()

    private init() {}

    var pendingNewWindowPicks = 0

    // MARK: - (cli-open) External opens

    /// Per-**incoming batch** cap (one `application(_:open:)` call = one batch). Each request costs
    /// a window plus a recursive synchronous scan of its root, so a Finder multi-select of a
    /// hundred files must not be taken literally. The `fedit` shim enforces the same cap up front,
    /// with a usage error instead of silence.
    private static let maxFileOpensPerEnqueue = 8

    /// Retry budget for a dispatch that finds no window opener registered yet (no scene has
    /// appeared). Refreshed at the start of every dispatch; at most **one** retry chain is ever in
    /// flight (`retryScheduled`), so concurrent dispatches extend that single chain's budget
    /// instead of each spawning a chain that eats from the shared counter. 20 × 100 ms ≈ 2 s.
    private static let openerRetryLimit = 20
    private static let openerRetryDelay: TimeInterval = 0.1

    /// Received from outside, not yet handed to a window of its own.
    private var undispatched: [OpenRequest] = []

    /// (cli-open) The ids of every token **this process** has handed to `openNewWindow`. See the
    /// type comment's token invariant: a token presented to a scene without being in this set was
    /// restored from a previous launch and is inert — `ContentView` drops it and lets the window's
    /// own `@SceneStorage` snapshot decide what it shows. Grows by one `UUID` per external open
    /// (capped at 8 per delivery), so it is not worth pruning.
    private var issuedTokenIDs: Set<UUID> = []

    /// `applicationDidFinishLaunching` has run — i.e. there is a scene machinery to open a window
    /// with. Nothing about routing depends on this: a request dispatched early would still be
    /// delivered to its own window, it just could not create one yet.
    private var isSettled = false

    private var openNewWindow: ((CLIOpenToken) -> Void)?
    private var openerRetriesLeft = 0

    /// A retry tick is already queued, so a re-entering dispatch must not start a second chain.
    private var retryScheduled = false

    /// Registered from **every** `ContentView.onAppear` (idempotent — last writer wins). Re-arming
    /// it on each appear keeps the captured `OpenWindowAction` fresh as windows come and go; only
    /// the "app running with zero windows" case can still hold a stale one. Re-entering dispatch
    /// here is what rescues requests that arrived before any scene existed (the cold-launch
    /// ordering): the first window to appear releases them, without waiting out the retry timer.
    func registerWindowOpener(_ opener: @escaping (CLIOpenToken) -> Void) {
        openNewWindow = opener
        if !undispatched.isEmpty {
            dispatchPendingFileOpens()
        }
    }

    /// Called from `AppDelegate.applicationDidFinishLaunching`. On a cold launch the odoc Apple
    /// Event is delivered *before* this, so whatever arrived meanwhile is dispatched now.
    func noteLaunchFinished() {
        guard !isSettled else { return }
        isSettled = true
        dispatchPendingFileOpens()
        scheduleZeroWindowLaunchNet()
    }

    // MARK: - (zero-window-session-relaunch) The launch net

    /// How long after `applicationDidFinishLaunching` the net checks for a windowless launch.
    /// In the one measured ordering (external-open-stray-window Rev 3, P2/P3 — a single odoc
    /// launch, display locked) restored windows existed before didFinishLaunching, and a cold
    /// launch-by-open settled at its one window quickly. 1.5 s is a deliberately generous guess
    /// built on those observations, NOT a measured latency bound — re-measure before shrinking
    /// it. The net's failure direction on a pathologically slow window is one extra blank window
    /// — visible and recoverable — never a touched or missing one.
    private static let zeroWindowNetDelay: TimeInterval = 1.5

    /// (zero-window-session-relaunch) The app-level "open a blank editor window" action,
    /// registered from `FEditApp.body` (`@Environment(\.openWindow)` resolves there and can
    /// create the process's FIRST window with no scene ever mounted — probe-verified, LB4/LB5).
    /// It opens the same `"editor"` group Cmd+O opens, with no mailbox increment — a plain blank
    /// window, no folder panel. Pure store, idempotent (body re-evaluations re-register the
    /// semantically identical closure); it never dispatches anything from inside body evaluation.
    private var presentBlankEditorWindow: (() -> Void)?

    func registerLaunchFallbackOpener(_ open: @escaping () -> Void) {
        presentBlankEditorWindow = open
    }

    /// (zero-window-session-relaunch) SPEC §3 promises an ordinary launch shows one blank window
    /// even when the saved session recorded zero windows — but a ZERO-window saved session is not
    /// "no session": restore succeeds at restoring nothing, and SwiftUI then creates no default
    /// window either (measured on pre-fix HEAD: close all windows, quit, relaunch → 0 windows,
    /// no scene). This net is **checked once per process**, `zeroWindowNetDelay` after settle,
    /// and presents one blank editor window iff the launch produced no window at all:
    ///
    /// - `liveWindowCount == 0` — nothing restored, nothing created. The predicate counts
    ///   `isVisible || isMiniaturized` (a session restored entirely miniaturized is a live
    ///   session, not a windowless launch — `isVisible` alone is false for miniaturized windows)
    ///   and `canBecomeKey` (excludes invisible torn-down scene husks and panels). Known
    ///   residual, recorded: `isVisible` semantics on a LOCKED screen were the stray-window
    ///   probes' one unresolved doubt; if they read false there, a locked-screen restore launch
    ///   gains one extra blank window — the accepted failure direction, and the human GUI pass
    ///   covers it.
    /// - `undispatched.isEmpty || openNewWindow == nil` — pending external opens will create
    ///   their own windows, so the net must not race them — but ONLY when an opener exists to
    ///   create them with. With no opener registered (a zero-window launch has no scene to
    ///   register one), those requests are stuck: the retry chain exhausts and nothing ever
    ///   appears. Firing the blank window is then exactly their rescue — its `ContentView`
    ///   appears, registers the opener, and `registerWindowOpener` re-dispatches the queue.
    ///   Deliberately NO "was a cli-open window issued" clause either (stray-window Rev 2,
    ///   D-R3): an issued window that never materializes also lands on the fire side.
    ///
    /// A hidden app (login item with Hide, `open -j`) is skipped: all its windows read
    /// `isVisible == false`, indistinguishable from windowless, and opening a window while
    /// hidden would surprise on unhide. The (rare) hidden + zero-window launch therefore keeps
    /// the pre-fix behavior — recorded corner, not silent.
    ///
    /// `NSOpenPanel.runModal` delaying the timer is harmless: by firing time a window exists and
    /// the net no-ops. Dock-reopen with zero windows is a separate surface, deliberately not
    /// re-armed here.
    private var zeroWindowNetChecked = false

    private func scheduleZeroWindowLaunchNet() {
        let workItem = DispatchWorkItem {
            // Scheduled on `DispatchQueue.main` below, so this body runs on the main actor;
            // `assumeIsolated` states that to the compiler (the file's standing idiom).
            MainActor.assumeIsolated {
                LaunchCoordinator.shared.fireZeroWindowLaunchNetIfNeeded()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.zeroWindowNetDelay, execute: workItem)
    }

    private func fireZeroWindowLaunchNetIfNeeded() {
        guard !zeroWindowNetChecked else { return }
        zeroWindowNetChecked = true

        guard !NSApp.isHidden else { return }
        let liveWindowCount = NSApp.windows.count { ($0.isVisible || $0.isMiniaturized) && $0.canBecomeKey }
        guard liveWindowCount == 0, undispatched.isEmpty || openNewWindow == nil else { return }

        guard let presentBlankEditorWindow else {
            // LB4/LB5 say `App.body` runs before any of this, so a nil opener should be
            // unreachable — but if it ever happens, the bug this net fixes would silently
            // return. Make that diagnosable rather than a plausible-looking success.
            NSLog("FEdit: zero-window launch net fired with no registered opener — windowless launch not rescued")
            return
        }
        presentBlankEditorWindow()
    }

    /// The external-open sink (`AppDelegate.application(_:open:)`). Does nothing heavier than
    /// resolving each URL against the filesystem and appending: every scan, watcher, git shell-out
    /// and possible alert happens later, inside the new scene. Resolution comes **before** the cap
    /// so that paths that no longer exist cannot use up the budget of paths that do.
    func enqueueFileOpens(_ urls: [URL]) {
        let requests = urls.compactMap(OpenRequest.init(fileURL:)).prefix(Self.maxFileOpensPerEnqueue)
        guard !requests.isEmpty else { return }

        undispatched.append(contentsOf: requests)
        if isSettled {
            dispatchPendingFileOpens()
        }
    }

    /// (cli-open) Did *this* process issue `token`? The first of the token invariant's three
    /// layers (see the type comment): `false` for a token the system restored with its window from
    /// a previous launch, which is exactly the token that must never be applied again.
    func wasIssuedThisProcess(_ token: CLIOpenToken) -> Bool {
        issuedTokenIDs.contains(token.id)
    }

    /// Brings the window hosting `model` forward, matching it through the close-guard proxy — the
    /// same identification `AppDelegate.applicationShouldTerminate` uses. A brand-new window whose
    /// proxy is not installed yet simply finds no match; SwiftUI fronts new windows itself, so this
    /// is a nicety, not the mechanism. `makeKeyAndOrderFront` alone doesn't restore a miniaturized
    /// window, so deminiaturize first.
    func bringWindowToFront(for model: WorkspaceModel) {
        guard let window = NSApp.windows.first(where: {
            ($0.delegate as? WindowCloseGuardProxy)?.model === model
        }) else { return }

        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Issues one new window per pending request. Called on settle, on every post-settle enqueue,
    /// and whenever a scene registers an opener while requests are waiting; refreshes the retry
    /// budget each time.
    private func dispatchPendingFileOpens() {
        openerRetriesLeft = Self.openerRetryLimit
        issueWindowsForPendingFileOpens()
    }

    /// The dispatch body, re-entered by the retry timer without refreshing the budget. Requests
    /// leave `undispatched` at the same moment their window is asked for, and the token handed to
    /// `openNewWindow` *is* the window's value, so a request is delivered to exactly one window,
    /// once. If no opener has been registered yet, they stay in `undispatched` and a later
    /// dispatch (or retry) picks them up — extending the one live retry chain rather than starting
    /// a competing one, so `openerRetryLimit` really is a per-chain budget.
    private func issueWindowsForPendingFileOpens() {
        guard !undispatched.isEmpty else { return }

        guard let openNewWindow else {
            guard !retryScheduled, openerRetriesLeft > 0 else { return }
            openerRetriesLeft -= 1
            retryScheduled = true
            let workItem = DispatchWorkItem {
                // Scheduled on `DispatchQueue.main` below, so this body runs on the main actor;
                // `assumeIsolated` states that to the compiler (the same idiom as
                // `WorkspaceModel.scheduleAutosave` and `WindowCloseGuardProxy`).
                MainActor.assumeIsolated {
                    LaunchCoordinator.shared.retryScheduled = false
                    LaunchCoordinator.shared.issueWindowsForPendingFileOpens()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openerRetryDelay, execute: workItem)
            return
        }

        let batch = undispatched
        undispatched.removeAll()
        for request in batch {
            let token = CLIOpenToken(request: request)
            // Before the window is asked for: this is the record that makes the token applicable
            // at all (`wasIssuedThisProcess`), and it must exist by the time the scene appears.
            issuedTokenIDs.insert(token.id)
            openNewWindow(token)
        }
        NSApp.activate()
    }
}
