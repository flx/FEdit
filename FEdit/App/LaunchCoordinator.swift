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

import Foundation

/// App-level, `@MainActor`-confined one-item mailbox coordinating the "Open Folder…" (Cmd+N)
/// new-window flow. The Cmd+N command (`FileCommands`) increments `pendingNewWindowPicks`
/// immediately before `openWindow(id: "editor")`; the next pristine window drains exactly one on
/// appear (`ContentView`) and presents `WorkspaceModel.presentNewWindowFolderPanel()`.
///
/// A plain (non-`@Published`) counter, not an `ObservableObject`: `ContentView` mutates/reads it
/// at discrete lifecycle moments, never observes it. The counter is only ever `> 0` as a direct
/// result of a post-launch Cmd+N, so restored and blank-startup windows (counter `== 0`) never
/// pick — today's startup behavior is preserved with no race. A singleton is an accepted
/// trade-off (tiny, `@MainActor`-confined) over plumbing an `@EnvironmentObject` into `Commands`.
@MainActor
final class LaunchCoordinator {
    static let shared = LaunchCoordinator()

    private init() {}

    var pendingNewWindowPicks = 0
}
