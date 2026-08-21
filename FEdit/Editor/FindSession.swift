//
//  FindSession.swift
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

/// (editor-find) The find state machine (SPEC §6.5): which matches exist, which one is *current*,
/// and what the count label says. Everything about stepping, wrapping, re-seating and — most
/// importantly — **clamping stale ranges** lives here rather than in `CodeEditorView.Coordinator`,
/// so all of it is a pure value type that `scripts/FindMatchTests` can assert against without a
/// window (the plan's finding 6). Foundation-only, for the same reason.
///
/// Ownership: this struct is *derived* state. The inputs — the query, the case flag, whether the
/// bar is open — live on `WorkspaceModel` (D3), because the editor coordinator is destroyed and
/// rebuilt whenever `workspace.isMarkdown` flips (`ContentView`'s `_ConditionalContent` around
/// `editorColumn`). The coordinator holds one of these and rebuilds it from those inputs; nothing
/// here is persisted (SPEC §9's snapshot is unchanged).
///
/// **The invariant every mutating member preserves:** `currentIndex` is non-`nil` exactly when
/// `matches` is non-empty, and when non-`nil` it is a valid index into `matches`. `currentRange` is
/// therefore either `nil` or a range inside whatever length was last `clamp`ed to — which is the
/// property that keeps `addTemporaryAttributes`/`scrollRangeToVisible` from ever seeing an
/// out-of-bounds range (criteria 9 and 11; an `NSRangeException` is an app crash, not a glitch).
struct FindSession: Equatable {
    /// The literal search text. Mirrored from `WorkspaceModel.findQuery` by the coordinator before
    /// each `recompute`; an empty query means "no search running" (`countLabel` is `""`).
    var query = ""

    /// The visible **Case sensitive** checkbox, unchecked by default (SPEC §6.5), so the default
    /// search is case-insensitive. Mirrored from `WorkspaceModel.findCaseSensitive`.
    var caseSensitive = false

    /// Every non-overlapping match of `query`, ascending, as of the last `recompute` minus whatever
    /// the last `clamp(toLength:)` dropped. `private(set)`: only the four mutating members below may
    /// write it, which is what makes the clamp invariant checkable.
    private(set) var matches: [NSRange] = []

    /// Whether the last enumeration stopped at `FindMetrics.matchLimit` with more matches left in
    /// the text — the `+` in `3 of 20000+`.
    private(set) var didTruncate = false

    /// Index into `matches` of the *current* match (the one drawn in the distinct colour and
    /// scrolled into view), or `nil` when there are no matches.
    private(set) var currentIndex: Int?

    /// Re-enumerates `query` over `text` and seats the current match on a NEW search.
    ///
    /// Seating rule (criterion 7, and what Xcode does): the first match whose `location` is at or
    /// after `caretLocation`, wrapping to the first match when every match is *before* it. This is
    /// what makes a fresh Cmd+F search start at `1 of N` in a top-of-file editor and at the match
    /// after the caret otherwise.
    ///
    /// **(editor-find, finding 2) Not for re-running an unchanged query against changed text** —
    /// that is `recomputeNearest(text:near:)` below. This method's caller-supplied `caretLocation`
    /// is meant to be the real, current caret; feeding it a stale pre-edit offset from a previous
    /// match would silently skip forward past the intended match whenever a deletion above it
    /// shrank every later offset (the exact bug finding 2 fixed).
    mutating func recompute(text: NSString, caretLocation: Int) {
        let result = FindMatcher.matches(in: text, query: query, caseSensitive: caseSensitive)
        matches = result.ranges
        didTruncate = result.didTruncate

        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }
        // `matches` is strictly ascending, so the first match at/after the caret is the first one
        // whose location qualifies; `?? 0` is the wrap.
        currentIndex = matches.firstIndex { $0.location >= caretLocation } ?? 0
    }

    /// (editor-find, finding 2) Re-enumerates `query` over `text` and re-seats the current match for
    /// a debounced re-run of an UNCHANGED query against changed text (criteria 16, 23).
    ///
    /// **(editor-find, finding 2, second round) Ordinal-first, distance-as-fallback.** When the
    /// match COUNT is unchanged across the re-enumeration, the current match is kept by ORDINAL
    /// (`currentIndex` unchanged) rather than re-derived from `location` — an edit that neither adds
    /// nor removes a match cannot have changed which match the user was on, so the ordinal is
    /// exactly right, and nearest-by-distance is not: distance seats on `argmin |matches[i].location
    /// - location|`, where `location` is the match's PRE-EDIT offset, and identity only survives
    /// that when the edit is smaller than half the inter-match gap. Failing case the first round's
    /// distance-only fix did not remove, only moved the threshold on: matches at 100/200/300, seated
    /// on 200 (index 1, `2 of 3`). Delete a 60-character span above 200 — matches become
    /// 100/140/240, count still 3, and 240 is nearer to the stale hint 200 than 140 is, so
    /// distance-only re-seats on index 2 and the count silently flips to `3 of 3`. Keeping the
    /// ordinal instead lands back on index 1 (140), exactly the match the user was on.
    ///
    /// Nearest-by-distance is used only when the count DID change (a match was added or removed by
    /// the edit), where the ordinal no longer names the same match and a location-based proxy is the
    /// best available answer — ties favor the earlier match (`<`, not `<=`, never replaces the
    /// first-seen minimum with a later match at the same distance).
    mutating func recomputeNearest(text: NSString, near location: Int) {
        let previousIndex = currentIndex
        let previousCount = matches.count

        let result = FindMatcher.matches(in: text, query: query, caseSensitive: caseSensitive)
        matches = result.ranges
        didTruncate = result.didTruncate

        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }

        if let previousIndex, previousCount == matches.count, matches.indices.contains(previousIndex) {
            currentIndex = previousIndex
            return
        }

        // Fallback: the match count changed, so the ordinal no longer names the same match.
        var bestIndex = 0
        var bestDistance = abs(matches[0].location - location)
        for index in matches.indices.dropFirst() {
            let distance = abs(matches[index].location - location)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        currentIndex = bestIndex
    }

    /// Find Next (Return, Cmd+G): advance to the next match, wrapping past the last one back to the
    /// first (SPEC §6.5). A no-op with no matches — it must not invent a seat, which is what the
    /// `nil` currentIndex means (criterion 8).
    mutating func stepNext() {
        guard !matches.isEmpty else { return }
        // `?? -1` makes an unseated-but-non-empty session (unreachable while the invariant holds)
        // step to 0 rather than crash or stay unseated.
        currentIndex = ((currentIndex ?? -1) + 1) % matches.count
    }

    /// **The anti-`NSRangeException` operation.** Drops every match that does not fit entirely
    /// inside a text of `length` UTF-16 units and re-seats `currentIndex` into what survives.
    ///
    /// This is what a caller runs *before* it touches any range — before highlighting, before
    /// scrolling, before placing the caret — whenever the text may have changed under the session
    /// (a keystroke inside the debounce window, a file switch, an external reload). Ranges are
    /// enumerated against one snapshot of the text and consumed against another; without this,
    /// `addTemporaryAttributes`/`scrollRangeToVisible` would raise on a range past the end and take
    /// the app down (criterion 9).
    ///
    /// Re-seating prefers **identity**: if the previously current range survived, it stays current
    /// (its index may have moved). Otherwise the seat lands on the last surviving match, so a
    /// session whose tail was deleted keeps a valid current match instead of silently unseating.
    mutating func clamp(toLength length: Int) {
        // (editor-find, finding 9) Early-out when nothing is out of bounds. `matches` is strictly
        // ascending (`FindMatcher` enumerates left to right), so the LAST match is the one furthest
        // from the start — if even it fits inside `length`, every match does, and there is nothing
        // to drop. Returning here leaves `matches` completely untouched: no fresh array allocation
        // (`matches.filter` below always allocates one, even when it drops nothing), and — because
        // the array is literally the same buffer — the identity fast path in `Array`'s `==` keeps a
        // caller's subsequent `findSession != sessionBefore` comparison O(1) instead of an
        // up-to-`FindMetrics.matchLimit`-element walk. This is the common case: nearly every
        // `updateNSView` pass (a caret move, a scroll report, a divider drag) calls this with
        // `length` unchanged since the last clamp.
        guard let lastMatch = matches.last, NSMaxRange(lastMatch) > length else { return }

        let previousCurrent = currentRange
        let countBefore = matches.count
        matches = matches.filter { $0.location >= 0 && $0.length >= 0 && NSMaxRange($0) <= length }

        // (editor-find, finding 4) `matches` is strictly ascending and non-overlapping, so a clamp
        // only ever drops a trailing suffix — never an interior match — which means whatever
        // survives is the exact, complete set for `length`. `didTruncate` (the "+" in "3 of
        // 20000+") describes the ORIGINAL enumeration having stopped early with more text left
        // unscanned; once a clamp has dropped anything, that claim no longer holds for the
        // surviving set and must be cleared here, or a shrunk document (e.g. most of a 2.7 MB file
        // deleted) would keep reporting a fabricated "+" on an exact count.
        if matches.count < countBefore {
            didTruncate = false
        }

        guard !matches.isEmpty else {
            currentIndex = nil
            return
        }
        if let previousCurrent, let survivingIndex = matches.firstIndex(of: previousCurrent) {
            currentIndex = survivingIndex
        } else {
            currentIndex = min(currentIndex ?? 0, matches.count - 1)
        }
    }

    /// Resets to the initial value — `self == FindSession()` afterwards. Run when the find bar
    /// closes: it drops the matches (so the editor's remove-then-add highlight pass leaves nothing
    /// behind, criterion 18) and empties the query (so `countLabel` reports `""` rather than a stale
    /// `Not found`). The query the *user* typed is not lost by this — it lives on `WorkspaceModel`
    /// and is mirrored back in on the next `recompute` (criterion 19).
    mutating func clear() {
        query = ""
        caseSensitive = false
        matches = []
        didTruncate = false
        currentIndex = nil
    }

    /// The current match, or `nil` when there is none. Guaranteed in-bounds of the last
    /// `clamp(toLength:)` — the single range the editor is allowed to scroll to or draw as current.
    var currentRange: NSRange? {
        guard let currentIndex, matches.indices.contains(currentIndex) else { return nil }
        return matches[currentIndex]
    }

    /// The find bar's count readout (SPEC §6.5): `""` while no query is entered, `Not found` when a
    /// query matches nothing, `3 of 17` normally, and `3 of 20000+` when the enumeration was capped
    /// (criterion 10).
    var countLabel: String {
        guard !query.isEmpty else { return "" }
        guard !matches.isEmpty else { return "Not found" }
        guard let currentIndex else {
            // Unreachable while the type's invariant holds (matches present ⇒ seated), and pinned
            // by criterion 11's randomized run. If it were ever reached, reporting the count with
            // no position is the honest answer — `1 of N` here would be a fabricated position.
            return "\(matches.count) matches"
        }
        let total = didTruncate ? "\(matches.count)+" : "\(matches.count)"
        return "\(currentIndex + 1) of \(total)"
    }
}
