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

    init() {
        // Light appearance only (SPEC §3), regardless of the system setting.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        // Value-less `WindowGroup(id:)` + `openWindow(id:)` opens a *new* window per Cmd+N call
        // (no `openWindow(value:)` dedup that would reuse a window / restructure the shipped
        // `@SceneStorage` restore). See LaunchCoordinator / FileCommands for the new-window flow.
        WindowGroup(id: "editor") {
            ContentView()
                .frame(minWidth: 700, minHeight: 400)
        }
        .defaultSize(width: CGFloat(LayoutMetrics.defaultWindowWidth), height: 700)
        .commands {
            FileCommands()
            ViewCommands()
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
