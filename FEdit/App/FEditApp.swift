//
//  FEditApp.swift
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

import SwiftUI

@main
struct FEditApp: App {
    // Routes Cmd+Q through the same per-window dirty-file guard as Cmd+W (SPEC §7); see
    // `WindowCloseGuard.swift`.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // (zero-window-session-relaunch) Resolves at the App level — probe-verified (stray-window
    // Rev 3): LB4 = the registration statement in `body` runs before any scene exists (the
    // action is only STORED there, never invoked — D-R2); LB5 = the stored action, when the
    // launch net later invokes it, can create the process's FIRST window with no scene ever
    // mounted. Handed to `LaunchCoordinator` below as the net's blank-window opener.
    @Environment(\.openWindow) private var openWindow

    init() {
        // Light appearance only (SPEC §3), regardless of the system setting.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        // (zero-window-session-relaunch) A pure store, re-run (idempotently) on every body
        // evaluation so the captured `OpenWindowAction` stays fresh. Registration must never
        // dispatch from inside body evaluation (stray-window Rev 2, D-R2) — and it doesn't: the
        // net fires from its own timer, `LaunchCoordinator` only stores the closure here.
        let _ = LaunchCoordinator.shared.registerLaunchFallbackOpener { [openWindow] in
            openWindow(id: "editor")
        }
        // Value-less `WindowGroup(id:)` + `openWindow(id:)` opens a *new* window per Cmd+N call
        // (no `openWindow(value:)` dedup that would reuse a window / restructure the shipped
        // `@SceneStorage` restore). See LaunchCoordinator / FileCommands for the new-window flow.
        WindowGroup(id: "editor") {
            ContentView()
                .frame(minWidth: 700, minHeight: 400)
        }
        .defaultSize(width: CGFloat(LayoutMetrics.defaultWindowWidth), height: 700)
        .commands {
            // App-global, not scene-specific: one attachment builds the whole menu bar, and the
            // commands below resolve their target through `@FocusedObject`/`openWindow` anyway.
            FileCommands()
            EditCommands()
            ViewCommands()
        }

        // (cli-open) External opens (`fedit`, `open -a FEdit <path>`) get their own window group,
        // presenting a `CLIOpenToken`: SwiftUI hands the token to exactly the scene it creates for
        // it, which is what makes "the request lands in ITS window and disturbs no other" a
        // structural property rather than a timing argument. Every token carries a fresh UUID, so
        // `openWindow(value:)` never dedups onto an existing window. Same chrome as the editor
        // group — it *is* an ordinary editor window, only its first content comes from outside.
        WindowGroup(id: "cli-open", for: CLIOpenToken.self) { $token in
            ContentView(cliToken: $token)
                .frame(minWidth: 700, minHeight: 400)
        }
        .defaultSize(width: CGFloat(LayoutMetrics.defaultWindowWidth), height: 700)
    }
}

/// Edit menu additions (editor-find): Find (Cmd+F) and Find Next (Cmd+G), SPEC §6.5/§10.
///
/// **Why menu commands rather than a key handler in the editor (D4):** a menu key equivalent is
/// dispatched before ordinary in-field text editing, so Cmd+F reaches the editor's find bar even
/// while the *sidebar filter field* has focus — which is exactly the item's "the two searches stay
/// separate" requirement (criterion 13). Focused-window-scoped through the same
/// `@FocusedObject`/`.focusedSceneObject(workspace)` route File → New…/Save already use, so two
/// windows keep independent find state (criterion 21).
///
/// `CommandGroup(after: .textEditing)` places both items in AppKit's auto-installed **Edit** menu,
/// in their own separated group directly after Select All — the conventional location. A
/// `CommandMenu("Edit")` would create a duplicate Edit menu, the same trap `ViewCommands` records.
///
/// **Why "after Select All" and not "inside a pre-existing Find submenu":** SwiftUI's SDK doc
/// comments describe `.textEditing` as already containing a Find submenu (⌘F/⌘G/⇧⌘G) plus Select
/// All in `.pasteboard` — but that population is opt-in, via the separate `TextEditingCommands()`
/// commands builder, which this app never requests (`.commands` below lists only `FileCommands`,
/// `EditCommands`, `ViewCommands`). Without it, `.textEditing` is an empty placement group in this
/// app, Select All lives in the plain default Edit menu, and this `CommandGroup` is the only thing
/// that ever lands there — probed directly on this OS: a bare version of this app's menu bar has no
/// Find submenu, zero ⌘F/⌘G hits, and with these commands registered there is exactly one of each,
/// directly after Select All. Anyone tempted to "fix" this placement from the SDK docs alone should
/// check the actual menu bar first.
///
/// There is deliberately **no Find Previous / Cmd+Shift+G** (the item enumerates Return and Cmd+G
/// and nothing else); the chord is unclaimed, so pressing it does nothing rather than invoking some
/// system behavior. Replace stays a SPEC §12 non-goal.
struct EditCommands: Commands {
    @FocusedObject private var workspace: WorkspaceModel?

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Find") {
                workspace?.presentFindBar()
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(workspace?.openFile == nil)

            // Find Next has no separate model method on purpose: it is a pure "one more step"
            // signal, and the editor — the only thing that knows where the matches are — decides
            // what it means. A tick pressed while the bar is closed is consumed (not queued) by the
            // editor, so it can never fire late.
            Button("Find Next") {
                workspace?.findNextTick += 1
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(workspace?.openFile == nil)
        }
    }
}

/// View menu additions (editor-font-zoom): editor font-size zoom. App-level (global setting) — no
/// `.disabled(workspace == nil)`; like "Open Folder…", zoom must work with no window focused. The
/// items are injected into AppKit's auto-installed "View" menu via `CommandGroup(after:)`; a
/// `CommandMenu("View")` would create a DUPLICATE View menu (D3). Because a `Commands` body
/// re-evaluates when its `@AppStorage` changes, the `.disabled(...)` enablement stays live; the
/// clamp inside each action is the correctness guarantee, the disabling is UX polish (belt-and-braces).
struct ViewCommands: Commands {
    // The single source of truth — the same `UserDefaults` key `ContentView` reads (clamped) to
    // drive the editor. This is the menu's live *writer* onto it, not a second copy.
    @AppStorage(SettingsKey.editorFontSize) private var editorFontSize: Double = EditorMetrics.defaultFontSize

    private func increase() {
        editorFontSize = min(editorFontSize + EditorMetrics.fontSizeStep, EditorMetrics.maxFontSize)
    }

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Increase Font Size", action: increase)
                // Displays ⌘+ (i.e. Cmd-Shift-=).
                .keyboardShortcut("+", modifiers: .command)
                .disabled(editorFontSize >= EditorMetrics.maxFontSize)

            Button("Decrease Font Size") {
                editorFontSize = max(editorFontSize - EditorMetrics.fontSizeStep, EditorMetrics.minFontSize)
            }
            .keyboardShortcut("-", modifiers: .command)
            .disabled(editorFontSize <= EditorMetrics.minFontSize)

            Button("Reset Font Size") {
                editorFontSize = EditorMetrics.defaultFontSize
            }
            .keyboardShortcut("0", modifiers: .command)
            .disabled(editorFontSize == EditorMetrics.defaultFontSize)
        }
    }
}

/// File menu additions (SPEC §10). Acts on the focused window's `WorkspaceModel` via
/// `@FocusedObject`/`.focusedSceneObject`, so adding a folder in one window never affects
/// another, and the command disables itself when no editor window is focused.
struct FileCommands: Commands {
    @FocusedObject private var workspace: WorkspaceModel?

    // Opens a new editor window for the "Open Folder…" (Cmd+O) flow — app-level, so it works
    // with no window focused (e.g. after closing the last window).
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // Replace SwiftUI's default "New Window" (which `.newItem` auto-installs at Cmd+N) with
        // "Open Folder…": creates a fresh empty window and flags intent via the launch mailbox so
        // that window presents the folder picker on appear (drained in ContentView). App-level —
        // no `.disabled` — since creating a window must work with no window focused. The increment
        // runs on the main actor immediately before `openWindow`, so the new window's appear
        // observes it.
        CommandGroup(replacing: .newItem) {
            // (new-file) File → New… (SPEC §7, §10) — first in the group, so the File menu reads
            // New… → Open Folder…. Focused-window-scoped (unlike Open Folder…): `@FocusedObject`
            // resolves the key window's model (reusing Save's focused-model resolution) and flipping
            // its published `isPresentingNewFileSheet` presents ContentView's `.sheet` in that
            // window only. `.disabled` covers both "no window focused" (`workspace == nil`) and
            // "nowhere to create" (`!canCreateNewFile`).
            Button("New…") {
                workspace?.presentNewFileSheet()
            }
            .keyboardShortcut("n", modifiers: [.command])
            .disabled(workspace?.canCreateNewFile != true)

            Button("Open Folder…") {
                LaunchCoordinator.shared.pendingNewWindowPicks += 1
                openWindow(id: "editor")
            }
            .keyboardShortcut("o", modifiers: [.command])
        }

        CommandGroup(after: .newItem) {
            Button("Add Folder to Window…") {
                workspace?.presentOpenPanel()
            }
            // Lowercase "o" plus explicit `.shift` — the uppercase-"O"-plus-explicit-shift
            // spelling is the historically fragile one for this chord.
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(workspace == nil)

            Button("Save") {
                workspace?.saveOpenFile()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(workspace?.canSave != true)
        }
    }
}

/// Single home for all `UserDefaults` keys used across the app (SPEC §13 "settings keys").
enum SettingsKey {
    static let sidebarWidth = "sidebarWidth"
    static let editorFraction = "editorFraction"
    // (editor-font-zoom) One global default (not per-window scene state), so every open editor
    // updates live on change and the size survives relaunch.
    static let editorFontSize = "editorFontSize"
}

/// Editor font-zoom constants (editor-font-zoom). Storage-backed values are `Double` to match the
/// `@AppStorage` boundary without cast noise. The 1-pt step and 8–32 clamp are fixed constants for v1.
enum EditorMetrics {
    static let defaultFontSize: Double = 13 // SPEC §6.1
    static let minFontSize: Double = 8
    static let maxFontSize: Double = 32
    static let fontSizeStep: Double = 1
}

/// Shared layout constants for the three-column window (SPEC §4). Storage-backed values are
/// `Double` to match the `@AppStorage` boundary without cast noise.
enum LayoutMetrics {
    static let defaultWindowWidth: Double = 1100
    static let defaultSidebarWidth: Double = 1100.0 / 3.0
    static let sidebarMin: Double = 160
    static let sidebarMax: Double = 600
    static let defaultEditorFraction: Double = 0.5
    static let editorFractionMin: Double = 0.15
    static let editorFractionMax: Double = 0.85
    static let dividerHitWidth: CGFloat = 5
    static let dividerLineWidth: CGFloat = 1
    static let columnHeaderHeight: CGFloat = 28
}
