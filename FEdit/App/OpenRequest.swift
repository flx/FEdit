//
//  OpenRequest.swift
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

/// (cli-open) One "show me this path" request — what an external open (`fedit`, `open -a`, Finder)
/// is reduced to before any window exists to receive it. Resolved against the filesystem **at
/// construction time**, in `AppDelegate.application(_:open:)`, so the routing layer never has to
/// stat anything and a path that has already vanished never reaches a window.
///
/// Deliberately Foundation-only (no AppKit, no SwiftUI): that is what lets it be compiled and
/// asserted on its own by `scripts/OpenRequestTests` (SPEC §13 — there is no XCTest target).
///
/// Both fields are `standardizedFileURL`: `.`/`..` are removed so the values compare equal to the
/// URLs `FileNode`/`WorkspaceModel` hold (they standardize the same way), but symlinks are
/// **not** resolved — a symlinked path stays the path the user named. (The `fedit` shim does
/// canonicalize via `realpath` before handing paths to `open`; that divergence is the shim's,
/// deliberately, and the app side stays non-resolving.)
struct OpenRequest: Equatable {
    /// The window's sole sidebar root: the file's containing folder, or the directory itself.
    let root: URL

    /// The file to open in the editor; `nil` for a directory request (`fedit .`).
    let file: URL?

    /// `nil` when `url` is not a `file:` URL, or names nothing that exists on disk — an external
    /// open of a stale path is simply ignored (SPEC §9's "a last-open file that no longer exists is
    /// simply not opened"); reporting bad paths is the shim's job, not the app's.
    init?(fileURL url: URL) {
        guard url.isFileURL else { return nil }

        let standardized = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            root = standardized
            file = nil
        } else {
            root = standardized.deletingLastPathComponent().standardizedFileURL
            file = standardized
        }
    }
}

/// (cli-open) An `OpenRequest` in the shape SwiftUI can carry: the payload of the `"cli-open"`
/// `WindowGroup(for:)`. Presenting the request *as the new window's value* is what removes the
/// whole class of "which window does this belong to?" races — SwiftUI hands the token to exactly
/// the scene it creates for it, so there is no mailbox, no claim, and no way for a restored scene
/// to take a request that was never meant for it.
///
/// **`id` is why every open gets its own window.** `openWindow(value:)` treats equal values as the
/// *same* window and merely focuses the existing one; a fresh `UUID` per token makes two opens of
/// the same path two distinct values, so `fedit notes.md` twice gives two windows (SPEC §3) and a
/// *restored* CLI window (whose token was persisted with its own id) can never be re-targeted.
///
/// Paths are stored as `String`, not `URL`: `URL`'s `Codable` representation is a bookmark-ish
/// multi-key form, and the value goes through SwiftUI's window-state persistence, so the flat,
/// obvious encoding is the one to use. `root`/`file` rebuild the same URLs `OpenRequest` held —
/// the stored paths come from already-`standardizedFileURL` values, and the directory-ness flags
/// below keep the trailing-slash spelling identical, so the rebuilt URLs still compare equal to
/// the URLs `FileNode`/`WorkspaceModel` hold.
struct CLIOpenToken: Codable, Hashable {
    /// Unique per open, never reused. See the type comment: this is the no-dedup guarantee.
    let id: UUID

    /// The window's sole sidebar root (`OpenRequest.root`).
    let rootPath: String

    /// The file to open, `nil` for a directory request (`OpenRequest.file`).
    let filePath: String?

    init(request: OpenRequest, id: UUID = UUID()) {
        self.id = id
        self.rootPath = request.root.path
        self.filePath = request.file?.path
    }

    /// (clitoken-tolerant-decode) The stable fallback identity for a token whose archived `id` is
    /// missing or corrupt. A *fixed* sentinel, deliberately not a fresh `UUID()`: this type's
    /// `Hashable` is the `"cli-open"` scene's window identity, and the system may decode the same
    /// archive more than once during restore — decode must therefore be **idempotent** (equal bytes
    /// ⟹ equal value). Distinct ids only matter for `openWindow(value:)` no-dedup, and a defaulted
    /// token can never reach `openWindow` (only freshly built tokens do, and those mint real
    /// UUIDs). The sentinel is exactly as inert as any restored id: `issuedTokenIDs` can never
    /// contain it (its sole insertion site is fed by `CLIOpenToken(request:)`'s own `UUID()`).
    private static let fallbackID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// (clitoken-tolerant-decode) Tolerant decoding — optional-with-defaults like
    /// `WorkspaceSnapshot`, but deliberately one notch MORE tolerant: `WorkspaceSnapshot` fails on
    /// a present-but-wrong-typed key (`try decodeIfPresent`); here each key is wrapped in `try?`,
    /// so even a wrong-typed field degrades to its default instead of killing the restore. The
    /// divergence is the read path's ownership: this value is archived by SwiftUI as the
    /// `"cli-open"` `WindowGroup(for:)` window value and decoded by the *system* during scene
    /// restore — there is no error surface and no retry, so any per-field failure must be
    /// absorbed. (A structurally alien archive — not a keyed container at all — still fails
    /// decode, and must: SwiftUI then restores the window valueless, the accepted degrade.)
    ///
    /// - a missing/corrupt `id` becomes `fallbackID` (see above — stable, inert);
    /// - a missing/corrupt `rootPath` becomes `""`. What makes that safe is the restore-inertness
    ///   guard, NOT the path's non-existence: `applyCLITokenIfNeeded` drops every token whose id
    ///   this process did not issue, so a defaulted token is never applied. (An empty path would
    ///   otherwise resolve against the CWD — `ContentView` carries a belt against that.)
    /// - `filePath` was always optional.
    ///
    /// **Versioning note (the discipline this buys):** when adding a field, give it a default
    /// here and keep the old fields' meaning stable; never rename or repurpose a key. A token
    /// written by any past version must decode under any future one — the system owns the write
    /// AND the read timing, so there is no migration hook, only tolerance.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(UUID.self, forKey: .id)) ?? Self.fallbackID
        rootPath = (try? container.decodeIfPresent(String.self, forKey: .rootPath)) ?? ""
        filePath = try? container.decodeIfPresent(String.self, forKey: .filePath)
    }

    var root: URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
    }

    var file: URL? {
        filePath.map { URL(fileURLWithPath: $0, isDirectory: false) }
    }
}
