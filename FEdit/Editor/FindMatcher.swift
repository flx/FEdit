//
//  FindMatcher.swift
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

/// (editor-find) Bounds for the in-editor find (SPEC §6.5). Deliberately **not** in
/// `App/FEditApp.swift` alongside `EditorMetrics`: `FindMatcher`/`FindSession` are compiled
/// standalone by `scripts/FindMatchTests`, so their constants must not reach into the app target
/// (the same standalone-compilation rule `Theme` follows for `codeFont`).
enum FindMetrics {
    /// Hard cap on enumerated matches per pass (D8). Past it `FindMatcher` stops scanning and says
    /// so, and the count label reads `3 of 20000+` — bounding a scan *and announcing the bound* is
    /// the house pattern (the ~50,000-node per-root sidebar budget declares its truncation the same
    /// way). Without it, a one-character query in a multi-megabyte file would build (and then
    /// temporary-attribute) millions of ranges on the main thread.
    static let matchLimit = 20_000
}

/// (editor-find) Literal, non-overlapping substring enumeration over a `UTF-16` haystack (SPEC
/// §6.5) — the whole of the find feature's search algorithm, and nothing else: no state, no UI, no
/// AppKit. Foundation-only so it is verifiable standalone; see `scripts/FindMatchTests/main.swift`.
enum FindMatcher {
    /// Every non-overlapping occurrence of `query` in `haystack`, in strictly ascending order, plus
    /// whether the scan stopped early at `FindMetrics.matchLimit`.
    ///
    /// **Non-overlapping (D5):** the scan resumes at a match's *end*, so `"aaaa"` / `"aa"` yields
    /// two matches (`(0,2)`, `(2,2)`), not three. That is the behaviour Find Next needs — stepping
    /// through overlapping matches of the same text would step over the same characters twice.
    ///
    /// **`.literal`, deliberately (D5):** without it, a search folds canonical equivalents, and a
    /// hit can then have a *different UTF-16 length* than the query (a decomposed "é" is two code
    /// units, the precomposed one is one) — which would hand back ranges the highlighter and the
    /// count label cannot reason about (criterion 4). The cost, accepted and specified: `resume`
    /// does not match `résumé`. `.caseInsensitive` is added only when the caller's checkbox is
    /// unchecked, which is the default (criterion 2).
    ///
    /// **(editor-find, finding 5) `.literal` does not make a match's length equal the query's
    /// length.** `.caseInsensitive` does its own Unicode case folding independently of `.literal`
    /// (`ß` case-folds to `SS`), so on this OS `"ss"` matches inside `"ß"` and `"STRASSE"` matches
    /// `"straße"` with a *shorter* found range than the query. Every returned range is still a
    /// valid, non-empty, non-overlapping subrange of the haystack that compares equal to the query
    /// under the same options — just not necessarily `queryLength` long. Callers must not assume
    /// `range.length == queryLength`.
    ///
    /// All offsets are UTF-16 code-unit offsets, matching `NSTextStorage`/`NSRange` throughout the
    /// editor — so a match after an emoji (a surrogate pair) reports the offset the text view
    /// actually indexes by (criterion 5).
    static func matches(
        in haystack: NSString,
        query: String,
        caseSensitive: Bool
    ) -> (ranges: [NSRange], didTruncate: Bool) {
        let queryLength = (query as NSString).length
        // An empty query is "no search running", not "matches everywhere"; an empty haystack has
        // nothing to search. Both return before any scanning (criterion 1) — and the empty-query
        // case additionally protects the loop below, whose progress depends on a non-zero match
        // length.
        //
        // (editor-find, finding 5) Deliberately NOT `queryLength <= haystack.length`: as the doc
        // comment above explains, a case-insensitive match can be SHORTER than the query that found
        // it (`"ss"` inside `"ß"`), so a query longer than the haystack can still legitimately hit.
        // The only genuinely safe early-outs are the degenerate empty cases.
        guard queryLength > 0, haystack.length > 0 else { return ([], false) }

        var options: NSString.CompareOptions = [.literal]
        if !caseSensitive {
            options.insert(.caseInsensitive)
        }

        var ranges: [NSRange] = []
        var searchStart = 0

        // Bounded on `haystack.length`, not on `queryLength` (see the guard above: a match's length
        // is not always the query's length, so there is no fixed "last possible start" to compute
        // from `queryLength`).
        while searchStart < haystack.length {
            let found = haystack.range(
                of: query,
                options: options,
                range: NSRange(location: searchStart, length: haystack.length - searchStart)
            )
            guard found.location != NSNotFound else { break }

            if ranges.count == FindMetrics.matchLimit {
                // The limit is reached *and* another match exists — so the label's `+` is a
                // measured fact, not an assumption. Probing costs one extra scan step, which buys
                // an exact answer for the "exactly 20,000 matches" case (`didTruncate == false`)
                // instead of over-reporting it.
                return (ranges, true)
            }

            ranges.append(found)
            // Resume at the match's END (D5). (editor-find, finding 5) `found.length` is NOT always
            // `queryLength` (see above), but a Foundation match for a non-empty query is never
            // itself empty in practice; `max(_:1)` remains the belt against a Foundation contract
            // violation — a zero-length hit would otherwise spin this loop on one offset forever.
            searchStart = found.location + max(found.length, 1)
        }

        return (ranges, false)
    }
}
