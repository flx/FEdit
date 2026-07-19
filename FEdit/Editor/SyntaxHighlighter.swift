//
//  SyntaxHighlighter.swift
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

import AppKit

/// The language a file's syntax-highlight pass should use, derived from its extension (SPEC
/// §6.3). Case-insensitive; anything unrecognized (including `nil`, e.g. an extensionless file)
/// falls back to `.plain`, which still runs the highlighter's reset pass but applies no rules.
enum SyntaxLanguage: Equatable {
    case swift
    case python
    case markdown
    case plain

    init(fileExtension: String?) {
        switch fileExtension?.lowercased() {
        case "swift":
            self = .swift
        case "py":
            self = .python
        case "md", "markdown":
            self = .markdown
        default:
            self = .plain
        }
    }
}

/// One regex-driven token class: every match of `regex` within the document gets `attributes`
/// added on top of whatever is already there (never a fresh `setAttributes`), so a later rule in
/// the array overwrites an earlier one's attributes on overlap — this is exactly how "strings
/// override keywords, comments override both" (§6.3) is realized (see `SyntaxHighlighter.highlight`).
struct HighlightRule {
    let regex: NSRegularExpression
    let attributes: [NSAttributedString.Key: Any]
}

/// Regex-based, whole-document syntax highlighting (SPEC §6.3) applied directly to an editor's
/// `NSTextStorage`. No incrementality, no background thread — files are small and §6.3 explicitly
/// trades incrementality for simplicity (see the plan's "Out of scope").
///
/// Known, accepted limitations of the spec-mandated rule order (do not "fix" — these follow
/// directly from §6.3's rule order and regex-only mandate):
/// - A `#`/`//` that appears inside a string literal gets comment-colored anyway, because the
///   comment rule always runs last and overwrites the string rule's attributes on that span (the
///   headline example: `let url = "https://example.com"` turns green after the `//`).
/// - A nested Swift block comment `/* /* */ */` closes at the *first* `*/`, not the matching one
///   (no recursive/balanced matching in a regex-only pass).
/// - Swift string-interpolation contents (`"\(expr)"`) stay string-red throughout — the string
///   rule does not parse interpolation boundaries.
enum SyntaxHighlighter {
    /// Runs a full reset-then-apply pass over `textStorage`: clears all attributes to
    /// `Theme.baseAttributes`, then — for any language but `.plain` — applies that language's
    /// rule array in array order, later rules overwriting earlier ones on overlapping ranges.
    /// Attribute-only: never calls `didChangeText()` or mutates characters, so this can never
    /// trigger `NSTextViewDelegate.textDidChange(_:)` and therefore can never re-trigger itself
    /// (criterion 8, no feedback loop).
    static func highlight(_ textStorage: NSTextStorage, language: SyntaxLanguage) {
        let string = textStorage.string
        let nsString = string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        textStorage.beginEditing()

        // Reset pass first — clears stale bold/color left over from a previous pass or a
        // previous (differently-languaged) file before any rule below can run.
        textStorage.setAttributes(Theme.baseAttributes, range: fullRange)

        if let rules = ruleArray(for: language) {
            for rule in rules {
                // Matching runs on the same `string` snapshot used to compute `fullRange`, and
                // every match range it hands back is on that same NSString/UTF-16 axis — so
                // ranges are always valid to apply back onto `textStorage`, even for an empty
                // file, a file with no trailing newline, an unterminated string/comment at EOF,
                // or CRLF content (criterion 9).
                rule.regex.enumerateMatches(in: string, range: fullRange) { match, _, _ in
                    guard let match else { return }
                    textStorage.addAttributes(rule.attributes, range: match.range)
                }
            }
        }

        textStorage.endEditing()
    }

    /// `nil` for `.plain` (reset pass only, no rules applied) — matches the language to its rule
    /// array without exposing either the switch or the arrays outside this file (Tier 3 knows
    /// nothing about rules or regexes; see the plan's "Interface between tiers").
    private static func ruleArray(for language: SyntaxLanguage) -> [HighlightRule]? {
        switch language {
        case .swift:
            return swiftRules
        case .python:
            return pythonRules
        case .markdown:
            return markdownRules
        case .plain:
            return nil
        }
    }

    // MARK: - Swift

    private static let swiftRules: [HighlightRule] = [
        // 1. number
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"\b(?:0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b"#
            ),
            attributes: [.foregroundColor: Theme.number]
        ),
        // 2. keyword
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"\b(?:associatedtype|class|deinit|enum|extension|fileprivate|func|import|init|inout|internal|let|open|operator|private|protocol|public|static|struct|subscript|typealias|var|break|case|continue|default|defer|do|else|fallthrough|for|guard|if|in|repeat|return|switch|where|while|as|any|catch|is|nil|rethrows|self|Self|some|super|throw|throws|true|false|try|async|await|actor|lazy|weak|unowned|mutating|override|final|required|convenience|indirect)\b"#
            ),
            attributes: [.foregroundColor: Theme.keyword, .font: Theme.editorBoldFont]
        ),
        // 3. string — triple-quote alternative first so it wins the alternation.
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #""""(?s:.*?)"""|"(?:\\.|[^"\\\n])*""#
            ),
            attributes: [.foregroundColor: Theme.string, .font: Theme.editorFont]
        ),
        // 4. comment — un-bolds/un-purples anything a prior rule colored inside it (runs last).
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"/\*(?s:.*?)\*/|//[^\n]*"#
            ),
            attributes: [.foregroundColor: Theme.comment, .font: Theme.editorFont]
        ),
    ]

    // MARK: - Python

    private static let pythonRules: [HighlightRule] = [
        // 1. number
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d*)?(?:[eE][+-]?\d+)?[jJ]?)\b"#
            ),
            attributes: [.foregroundColor: Theme.number]
        ),
        // 2. keyword
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b"#
            ),
            attributes: [.foregroundColor: Theme.keyword, .font: Theme.editorBoldFont]
        ),
        // 3. string — triples before singles; the optional prefix carries its own `(?<!\w)`
        // guard so `hub"x"` doesn't color `b"x"` while a bare quoted string still matches.
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"(?:(?<!\w)(?i:[rbuf]{1,2}))?(?:'''(?s:.*?)'''|"""(?s:.*?)"""|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*")"#
            ),
            attributes: [.foregroundColor: Theme.string, .font: Theme.editorFont]
        ),
        // 4. comment
        HighlightRule(
            regex: try! NSRegularExpression(pattern: #"#[^\n]*"#),
            attributes: [.foregroundColor: Theme.comment, .font: Theme.editorFont]
        ),
    ]

    // MARK: - Markdown

    /// Editor-side highlighting only (§6.3), not the Markdown *preview* renderer (out of scope
    /// here; see the plan). Order matters: fenced blocks run last so they override any inline
    /// styling (heading/bold/italic/link/inline-code) applied inside them by rules 1–5
    /// (criterion 4). All line-anchored patterns use `.anchorsMatchLines` so `^`/`$` match at
    /// line boundaries rather than only at the start/end of the whole document.
    private static let markdownRules: [HighlightRule] = [
        // 1. heading — color spans the whole line; inline markup inside a heading may still
        // override the bold font (rules below run after this one).
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"^#{1,6}[ \t][^\n]*$"#, options: [.anchorsMatchLines]
            ),
            attributes: [.foregroundColor: Theme.heading, .font: Theme.editorBoldFont]
        ),
        // 2. bold — `__…__` gets the same non-word-boundary guards as italic so snake_case
        // identifiers don't trigger it.
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"\*\*[^*\n]+\*\*|(?<![_\w])__[^_\n]+__(?![_\w])"#
            ),
            attributes: [.font: Theme.editorBoldFont]
        ),
        // 3. italic — visually slanted, either a real italic trait or the synthesized-oblique
        // fallback (see `Theme.editorItalic`'s doc comment).
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"(?<![*\w])\*(?!\*)[^*\n]+\*(?![*\w])|(?<![_\w])_(?!_)[^_\n]+_(?![_\w])"#
            ),
            attributes: italicAttributes
        ),
        // 4. link
        HighlightRule(
            regex: try! NSRegularExpression(pattern: #"\[[^\]\n]*\]\([^)\n]*\)"#),
            attributes: [.foregroundColor: Theme.link]
        ),
        // 5. inline code — resets `.foregroundColor` to `Theme.text` so link-blue from rule 4
        // doesn't bleed into `` `[a](b)` ``. `.obliqueness: 0` overrides any italic slant rule 3
        // already applied inside the span (`addAttributes` merges, it doesn't replace).
        HighlightRule(
            regex: try! NSRegularExpression(pattern: #"`[^`\n]+`"#),
            attributes: [
                .font: Theme.editorFont,
                .foregroundColor: Theme.text,
                .backgroundColor: Theme.codeBackground,
                .obliqueness: 0,
            ]
        ),
        // 6. fenced block — strips heading/bold/italic/link/inline-code styling from rules 1–5
        // inside the block by setting font/foreground explicitly, then applies the code
        // background over the whole block including the fence lines. `.obliqueness: 0` overrides
        // any italic slant rule 3 already applied inside the span (`addAttributes` merges, it
        // doesn't replace). An unterminated trailing fence (no closing ```) simply never matches,
        // so it keeps whatever inline styling rules 1–5 already applied and gets no code
        // background — the cheapest safe behavior.
        HighlightRule(
            regex: try! NSRegularExpression(
                pattern: #"^```[^\n]*\n(?s:.*?)^```[ \t]*$"#, options: [.anchorsMatchLines]
            ),
            attributes: [
                .font: Theme.editorFont,
                .foregroundColor: Theme.text,
                .backgroundColor: Theme.codeBackground,
                .obliqueness: 0,
            ]
        ),
    ]

    /// Markdown italic's attributes: `Theme.editorItalic` when it actually carries a real italic
    /// trait, otherwise `Theme.editorFont` plus a synthesized-oblique `.obliqueness` attribute
    /// (SF Mono has no italic face, so this is the expected branch in practice — see
    /// `Theme.editorItalic`'s doc comment).
    private static let italicAttributes: [NSAttributedString.Key: Any] = {
        if Theme.editorItalic.fontDescriptor.symbolicTraits.contains(.italic) {
            return [.font: Theme.editorItalic]
        }
        return [.font: Theme.editorFont, .obliqueness: 0.2]
    }()
}
