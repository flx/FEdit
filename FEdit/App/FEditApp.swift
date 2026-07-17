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
    init() {
        // Light appearance only (SPEC §3), regardless of the system setting.
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 400)
        }
        .defaultSize(width: CGFloat(LayoutMetrics.defaultWindowWidth), height: 700)
    }
}

/// Single home for all `UserDefaults` keys used across the app (SPEC §13 "settings keys").
enum SettingsKey {
    static let sidebarWidth = "sidebarWidth"
    static let editorFraction = "editorFraction"
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
}
