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
    let groups: [[String]]

    /// Tokenizes then parses `text` with a single left-to-right pass implementing the
    /// degradation rules (criterion 6): leading/trailing operators are dropped, and of a run of
    /// consecutive operators only the first is honored (first-operator-wins).
    init(_ text: String) {
        let tokens = FilterQuery.tokenize(text)

        var groups: [[String]] = []
        var current: [String] = []
        // NOT a `pendingAnd: Bool` — a bool cannot implement first-operator-wins for a run of
        // mixed operators (e.g. `.py OR AND .md` would incorrectly collapse to an AND).
        var pendingOp: FilterToken? = nil

        for token in tokens {
            switch token {
            case .term(let term):
                if pendingOp == .and {
                    current.append(term)
                } else {
                    // Adjacency and OR both start a new group (nil or `.or`).
                    if !current.isEmpty {
                        groups.append(current)
                    }
                    current = [term]
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
            group.allSatisfy { relativePath.range(of: $0, options: .caseInsensitive) != nil }
        }
    }
}
