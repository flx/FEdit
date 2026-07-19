//
//  WorkspaceSnapshot.swift
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

/// The per-window persisted state (SPEC §3, §9): open top-level folders, open file path, filter
/// text, and cursor position, round-tripped through `@SceneStorage` as JSON. Foundation-only (no
/// AppKit) so it stays compilable by the `scripts/SnapshotTests` swiftc-script harness alongside
/// `WorkspaceModel.swift`, which imports AppKit.
struct WorkspaceSnapshot: Codable, Equatable {
    /// Absolute paths of the window's top-level sidebar roots (SPEC §5.1).
    var rootPaths: [String]

    /// Absolute path of the open editor file, or `nil` when nothing is open.
    var openFilePath: String?

    /// The sidebar filter query text (SPEC §5.4–§5.5).
    var filterText: String

    /// UTF-16 offset into the open document (`NSRange.location` of a zero-length selection), or
    /// `nil` when there is no meaningful cursor to restore.
    var cursorLocation: Int?

    init(rootPaths: [String], openFilePath: String?, filterText: String, cursorLocation: Int?) {
        self.rootPaths = rootPaths
        self.openFilePath = openFilePath
        self.filterText = filterText
        self.cursorLocation = cursorLocation
    }

    private enum CodingKeys: String, CodingKey {
        case rootPaths, openFilePath, filterText, cursorLocation
    }

    /// Tolerant decoding: every key is optional-with-a-default, so a snapshot written by an
    /// earlier or partially-corrupt schema (missing keys) decodes to sane defaults instead of
    /// failing the whole restore. This makes the "all fields optional-with-defaults" contract
    /// real, not aspirational — additive fields later need no version bump (see the plan's
    /// interface note on schema stability).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPaths = try container.decodeIfPresent([String].self, forKey: .rootPaths) ?? []
        openFilePath = try container.decodeIfPresent(String.self, forKey: .openFilePath)
        filterText = try container.decodeIfPresent(String.self, forKey: .filterText) ?? ""
        cursorLocation = try container.decodeIfPresent(Int.self, forKey: .cursorLocation)
    }
}
