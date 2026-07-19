//
//  WindowCloseGuard.swift
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

/// Runs `WorkspaceModel.resolveDirtyFile()` before a window is allowed to close (SPEC §7: "same
/// flow applies when closing a window"). Placed invisibly in `ContentView`'s background so it
/// can walk up to `view.window` and install the guard there.
///
/// SwiftUI installs its **own** `NSWindowDelegate` on every `WindowGroup` window — its scene
/// lifecycle and `@SceneStorage` machinery depend on it — so this never replaces `window.delegate`
/// outright. Instead it wraps whatever delegate is already there in a `WindowCloseGuardProxy` that
/// intercepts `windowShouldClose` and `windowWillClose` (to uninstall itself once the window
/// closes) and forwards everything else, re-verifying on every `updateNSView` that the proxy is
/// still installed (SwiftUI can reassert its own delegate across scene updates).
struct WindowCloseGuard: NSViewRepresentable {
    weak var model: WorkspaceModel?

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.onWindowChange = { [weak model] window in
            WindowCloseGuard.installProxyIfNeeded(on: window, model: model)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        WindowCloseGuard.installProxyIfNeeded(on: nsView.window, model: model)
    }

    /// Wraps (or re-wraps) `window`'s delegate in a `WindowCloseGuardProxy`, unless a proxy for
    /// this window is already installed — in which case only its (weak) model reference is
    /// refreshed. `NSWindow.delegate` is `weak`, so the proxy must be retained separately for the
    /// life of the window; `retainedProxies` does that.
    fileprivate static func installProxyIfNeeded(on window: NSWindow?, model: WorkspaceModel?) {
        guard let window else { return }

        if let existingProxy = window.delegate as? WindowCloseGuardProxy {
            existingProxy.model = model
            return
        }

        guard let currentDelegate = window.delegate else { return }
        let proxy = WindowCloseGuardProxy(wrapping: currentDelegate, model: model)
        window.delegate = proxy
        retainedProxies.setObject(proxy, forKey: window)
    }

    /// Removes `window`'s entry so the proxy is no longer retained. Called by the proxy itself
    /// from `windowWillClose(_:)`, once the window's delegate has been restored to the wrapped
    /// (SwiftUI) delegate — otherwise a closed window's map entry (and the proxy, and everything
    /// it transitively retains) would never be released.
    fileprivate static func uninstallProxy(for window: NSWindow) {
        retainedProxies.removeObject(forKey: window)
    }

    private static let retainedProxies = NSMapTable<NSWindow, WindowCloseGuardProxy>.weakToStrongObjects()

    private final class TrackingView: NSView {
        var onWindowChange: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?(window)
        }
    }
}

/// Forwarding `NSWindowDelegate` proxy: wraps SwiftUI's own window delegate and intercepts
/// `windowShouldClose`, running the same dirty-file resolution as Cmd+S / a guarded file switch
/// (SPEC §7), and `windowWillClose`, to uninstall itself once the window is gone. Every other
/// selector forwards to the wrapped delegate.
///
/// `responds(to:)` is overridden to report the **union** of both delegates' selectors —
/// `forwardingTarget(for:)` alone is not enough, because `NSWindow` checks `responds(to:)` before
/// dispatching any optional `NSWindowDelegate` method; a selector this proxy doesn't itself
/// implement (and doesn't claim in `responds(to:)`) would otherwise silently never reach SwiftUI's
/// delegate at all.
///
/// `wrapped` is held **weakly**: SwiftUI's own window controller is `NSWindow`'s real (strong)
/// owner and is itself the wrapped delegate, so a strong reference here would keep it — and the
/// window it retains — alive forever, permanently leaking every closed window (this proxy is kept
/// alive by `WindowCloseGuard.retainedProxies`, whose key is the window itself, so a strong
/// `wrapped` created a retain cycle the weak map table alone couldn't break). `windowWillClose(_:)`
/// forwards to `wrapped` first (SwiftUI needs its teardown), then restores `window.delegate` and
/// uninstalls this proxy, so a closed window is left with no trace of ever having been proxied.
final class WindowCloseGuardProxy: NSObject, NSWindowDelegate {
    private weak var wrapped: NSWindowDelegate?
    weak var model: WorkspaceModel?

    init(wrapping wrapped: NSWindowDelegate, model: WorkspaceModel?) {
        self.wrapped = wrapped
        self.model = model
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // `NSWindowDelegate` methods are always invoked on the main thread by AppKit; this just
        // tells the compiler what's already true at the call site.
        MainActor.assumeIsolated {
            guard let model else {
                return wrapped?.windowShouldClose?(sender) ?? true
            }
            guard model.resolveDirtyFile() == .proceed else { return false }
            return wrapped?.windowShouldClose?(sender) ?? true
        }
    }

    func windowWillClose(_ notification: Notification) {
        wrapped?.windowWillClose?(notification)
        guard let window = notification.object as? NSWindow else { return }
        window.delegate = wrapped
        WindowCloseGuard.uninstallProxy(for: window)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return true
        }
        return super.responds(to: aSelector) || (wrapped?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(NSWindowDelegate.windowShouldClose(_:)) {
            return nil
        }
        return wrapped
    }
}

/// Routes Cmd+Q through the same per-window dirty-file guard (SPEC §7: "v1 may route quit
/// through the same dialog per window"). Iterates `NSApp.windows` in order; a `Cancel` in any
/// window's dialog aborts the whole quit immediately — actions already applied to earlier windows
/// (saves/discards) stand, and no window is closed (criterion 17a).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for window in NSApp.windows {
            guard let proxy = window.delegate as? WindowCloseGuardProxy else { continue }

            // Brings the window forward before its dialog (if any) appears, so two dirty windows
            // with same-named files are distinguishable (criterion 17a). `makeKeyAndOrderFront`
            // alone doesn't restore a miniaturized window, so deminiaturize first.
            if proxy.model?.openFile?.isDirty == true {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }

            if !proxy.windowShouldClose(window) {
                return .terminateCancel
            }
        }
        return .terminateNow
    }
}
