//
//  FilterQuery.swift
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

/// A single lexical unit of a filter query (SPEC §5.5): either a bare search term or one of the
/// two exact-uppercase operators. Internal (not private) so the verification harness can assert
/// tokenizer behavior directly.
enum FilterToken: Equatable {
    case term(String)
    case and
    case or
}

/// A single filter term with optional fzf/regex-style path anchors (SPEC §5.5): a leading `^`
/// anchors the match to the start of the root-relative path, a trailing `$` to the end. Parsed
/// once from the raw token text; `matches(_:)` uses the stripped `text` plus the two flags to
/// pick a case-insensitive contains/prefix/suffix/both check. Internal (not private) so the
/// harness can assert the parsed fields directly.
struct MatchTerm: Equatable {
    let text: String
    let anchorStart: Bool
    let anchorEnd: Bool

    /// Direct field initializer, used by the harness to build expected values without going
    /// through anchor parsing (avoids circular self-testing).
    init(text: String, anchorStart: Bool, anchorEnd: Bool) {
        self.text = text
        self.anchorStart = anchorStart
        self.anchorEnd = anchorEnd
    }

    /// Parses `raw` into literal text plus anchor flags. Order is left-to-right and each strip
    /// is vetoed if it would leave zero literal characters, so `text` is never empty:
    ///   1. Strip a leading `^` only if `raw` has more than one character.
    ///   2. On what remains, strip a trailing `$` only if that remainder has more than one
    ///      character.
    /// This directly implements the degradation rules: a bare `^` or bare `$` (one-character
    /// term) is left untouched (both flags false, literal text unchanged); an anchor character
    /// that is not the very first/last character is never stripped because `hasPrefix`/
    /// `hasSuffix` only ever look at position 0 / the last position; `^^a` strips exactly one
    /// leading `^` (the count-check applies to the second `^` only via the *remaining* text,
    /// which is `^a`, itself with a literal leading caret that fails the `> 1 char after strip`
    /// re-entry — there is no re-entry, this init runs once); and the corner case `^$` (two
    /// characters, both anchor characters, zero literal content either way) strips only the
    /// leading `^` — stripping it first leaves `$` (1 char), which then fails the "leave > 0
    /// chars" guard for the trailing strip — so `^$` parses to `anchorStart: true, anchorEnd:
    /// false, text: "$"`, never to an empty `text`. (Keeping at least one literal character is
    /// what makes bare `^`/`$` degrade to a *literal* match per SPEC §5.5. Note Foundation's
    /// `range(of: "", options:)` returns `nil`, so an empty `text` would make every branch of
    /// `matches` return `false` — the term would silently match nothing, not "everything"; the
    /// guard exists to preserve literal-degradation semantics, not to avoid a match-all.)
    init(_ raw: String) {
        var remainder = Substring(raw)
        var start = false
        var end = false

        if remainder.count > 1, remainder.hasPrefix("^") {
            start = true
            remainder = remainder.dropFirst()
        }
        if remainder.count > 1, remainder.hasSuffix("$") {
            end = true
            remainder = remainder.dropLast()
        }

        self.text = String(remainder)
        self.anchorStart = start
        self.anchorEnd = end
    }

    /// Case-insensitive match of `text` against `relativePath`, per the anchor flags. Naive
    /// `String.hasPrefix`/`hasSuffix` are case-SENSITIVE, so every branch goes through
    /// `range(of:options:)` instead:
    ///   - no anchors: `.caseInsensitive` (unchanged `contains` behavior).
    ///   - `anchorStart` only: `[.caseInsensitive, .anchored]` — anchors the search to the
    ///     start of `relativePath` (case-insensitive `hasPrefix`).
    ///   - `anchorEnd` only: `[.caseInsensitive, .anchored, .backwards]` — anchors to the end
    ///     (case-insensitive `hasSuffix`). `.backwards` combined with `.anchored` moves the
    ///     anchor from the start of the search range to the end; it is not a right-to-left
    ///     scan here since the range is unconstrained.
    ///   - both: case-insensitive whole-path EQUALITY, expressed with the SAME `range(of:)` engine
    ///     as the other branches (so Unicode folding/normalization is identical): the anchored
    ///     (prefix) occurrence of `text` must span the ENTIRE path. `^X$` matches only when the
    ///     path equals X, mirroring fzf/regex. A prefix-AND-suffix composition is NOT equivalent —
    ///     it also matches any longer path that both starts and ends with X (e.g. `^test$` wrongly
    ///     matching `test/test`, or `^a$` matching `aXa`), so whole-span equality is required.
    ///     Degrades correctly: a term longer than (or otherwise unequal to) the path can't span it
    ///     ⇒ no match, no crash.
    func matches(_ relativePath: String) -> Bool {
        switch (anchorStart, anchorEnd) {
        case (false, false):
            return relativePath.range(of: text, options: [.caseInsensitive]) != nil
        case (true, false):
            return relativePath.range(of: text, options: [.caseInsensitive, .anchored]) != nil
        case (false, true):
            return relativePath.range(of: text, options: [.caseInsensitive, .anchored, .backwards]) != nil
        case (true, true):
            return relativePath.range(of: text, options: [.caseInsensitive, .anchored])
                == relativePath.startIndex..<relativePath.endIndex
        }
    }
}

/// The sidebar filter query language (SPEC §5.5): whitespace-separated terms combined with
/// optional `AND`/`OR` operators, flattened at parse time into OR-of-AND-groups (disjunctive
/// normal form) — no parentheses, no precedence stack. Malformed input degrades gracefully
/// (§5.5 last bullet) rather than erroring.
struct FilterQuery {
    /// Splits `text` into tokens on any whitespace run, dropping empty pieces. `"AND"`/`"OR"`
    /// (exact case) become operators; everything else, including lowercase `"and"`/`"or"`, is an
    /// ordinary term (criterion 5).
    static func tokenize(_ text: String) -> [FilterToken] {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map { word in
                switch word {
                case "AND": return .and
                case "OR": return .or
                default: return .term(word)
                }
            }
    }

    /// The parsed OR-of-AND-groups: `groups.contains { group in group.allSatisfy(...) }` is the
    /// matching rule. Internal so the harness can assert structure directly; the view must not
    /// depend on this — use `matches(_:)` instead.
    let groups: [[MatchTerm]]

    /// Tokenizes then parses `text` with a single left-to-right pass implementing the
    /// degradation rules (criterion 6): leading/trailing operators are dropped, and of a run of
    /// consecutive operators only the first is honored (first-operator-wins).
    init(_ text: String) {
        let tokens = FilterQuery.tokenize(text)

        var groups: [[MatchTerm]] = []
        var current: [MatchTerm] = []
        // NOT a `pendingAnd: Bool` — a bool cannot implement first-operator-wins for a run of
        // mixed operators (e.g. `.py OR AND .md` would incorrectly collapse to an AND).
        var pendingOp: FilterToken? = nil

        for token in tokens {
            switch token {
            case .term(let term):
                if pendingOp == .and {
                    current.append(MatchTerm(term))
                } else {
                    // Adjacency and OR both start a new group (nil or `.or`).
                    if !current.isEmpty {
                        groups.append(current)
                    }
                    current = [MatchTerm(term)]
                }
                pendingOp = nil

            case .and, .or:
                if current.isEmpty {
                    // Leading operator — ignored.
                } else if pendingOp != nil {
                    // Consecutive operators — the first one already recorded wins.
                } else {
                    pendingOp = token
                }
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }
        // A dangling `pendingOp` here is a trailing operator — simply dropped.

        self.groups = groups
    }

    /// `true` for blank, whitespace-only, or operator-only input (zero parsed groups).
    var isEmpty: Bool {
        groups.isEmpty
    }

    /// Case-insensitive substring match against a root-relative path: a path matches if at least
    /// one AND-group has every one of its terms present as a substring. An empty query (zero
    /// groups) matches nothing, per criterion 6.
    func matches(_ relativePath: String) -> Bool {
        groups.contains { group in
            group.allSatisfy { $0.matches(relativePath) }
        }
    }
}
