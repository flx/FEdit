//
//  LogicalLine.swift
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

/// The single, project-wide definition of a "logical line" (SPEC §11): text separated by `\n`
/// ONLY — deliberately **not** `NSString.lineRange`/`.paragraphRange` semantics, which also break
/// on `\r`, U+0085 (NEL), and U+2028 (LINE SEPARATOR) and would make the line-number ruler's
/// starting-line prefix count disagree with its own fragment-by-fragment walk on classic-Mac- or
/// NEL-containing files. One shared implementation, used by `LineNumberRulerView` (starting-line
/// prefix count and visible-range walk) and `CodeEditorView`'s first-visible-line scroll
/// callback — never reimplemented independently.
///
/// Foundation-only (no AppKit) so it is verifiable standalone; see
/// `scripts/LogicalLineTests/main.swift`.
enum LogicalLine {
    /// Number of `\n` characters in `string` at UTF-16 offsets strictly before `location`. This
    /// is also the 0-based logical-line index of `location` (whether `location` is exactly a
    /// line's start or somewhere in its middle, the same number of complete lines precede it).
    /// O(location) — deliberately not cached (criterion 10; v1's small-file target).
    static func count(in string: NSString, before location: Int) -> Int {
        guard location > 0 else { return 0 }
        let searchLimit = min(location, string.length)

        var lineCount = 0
        var scanStart = 0
        while scanStart < searchLimit {
            let found = string.range(
                of: "\n",
                options: [],
                range: NSRange(location: scanStart, length: searchLimit - scanStart)
            )
            guard found.location != NSNotFound else { break }
            lineCount += 1
            scanStart = found.location + 1
        }
        return lineCount
    }

    /// UTF-16 offset of the start of the logical line containing `location` — i.e. the index
    /// right after the nearest `\n` at or before `location`, or `0` if there is none. Needed to
    /// resolve a raw offset (which may fall mid-line) to the character index whose first visual
    /// fragment is the line's own, not a wrapped continuation.
    static func lineStart(in string: NSString, containing location: Int) -> Int {
        guard location > 0 else { return 0 }
        let searchLimit = min(location, string.length)
        let found = string.rangeOfCharacter(
            from: CharacterSet(charactersIn: "\n"),
            options: .backwards,
            range: NSRange(location: 0, length: searchLimit)
        )
        guard found.location != NSNotFound else { return 0 }
        return found.location + 1
    }

    /// UTF-16 offset of the start of the logical line after the one starting at `location` — the
    /// index right after the next `\n` at or after `location`. `nil` when there is no further
    /// `\n` (the line at `location` is the document's last logical line).
    static func nextLineStart(in string: NSString, after location: Int) -> Int? {
        guard location < string.length else { return nil }
        let found = string.range(
            of: "\n",
            options: [],
            range: NSRange(location: location, length: string.length - location)
        )
        guard found.location != NSNotFound else { return nil }
        return found.location + 1
    }
}
