//
//  MarkdownRenderer.swift
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

// MARK: - Public anchor API (consumed by the downstream markdown-preview scroll-sync)

/// One block element's position in the rendered output, used by the (markdown-preview) scroll-sync
/// lookup (SPEC §8.3). `sourceLine` is the 0-based index of the block's first line in the source
/// (over `\n`-split lines, CRLF tolerated); `location` is the UTF-16 offset of the block's first
/// character in the rendered `NSAttributedString`. `MarkdownRenderer.render` guarantees both fields
/// are **strictly ascending** across the returned array, so "greatest anchor with
/// `sourceLine ≤ firstVisibleLine`" is a plain binary search. A trailing empty block (empty fence,
/// bare `"# "` heading) yields an anchor with `location == output.length` — a zero-length position
/// at end-of-storage the consumer must tolerate.
struct MarkdownAnchor: Equatable {
    let sourceLine: Int
    let location: Int
}

// MARK: - Block model (Tier 1)

/// The internal block model produced by `MarkdownBlockParser`. Every case carries `line` — the
/// 0-based source line of the block's first line — which becomes the emitted anchor's `sourceLine`
/// unchanged. `marker` on `.listItem` is the *rendered* prefix glyph run (`•`, or `"3."` for
/// ordered items): baking the glyph into the parser is an accepted v1 simplification (a future
/// glyph change touches the parser + tests, not just the emitter).
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String, line: Int)
    case paragraph(text: String, line: Int)
    case listItem(marker: String, text: String, line: Int)
    case blockquote(text: String, line: Int)
    case codeBlock(code: String, line: Int)
    case rule(line: Int)

    /// The 0-based source line of this block's first line (its anchor's `sourceLine`).
    var line: Int {
        switch self {
        case let .heading(_, _, line): return line
        case let .paragraph(_, line): return line
        case let .listItem(_, _, line): return line
        case let .blockquote(_, line): return line
        case let .codeBlock(_, line): return line
        case let .rule(line): return line
        }
    }
}

/// The block-level parser for the SPEC §8.2 Markdown subset. Splits the source on `\n` (a trailing
/// `\r` per line is stripped, so CRLF input parses identically), runs a fence state machine, and
/// classifies each line in the fixed precedence order of the plan's criterion 8:
///
///   inside-fence state → fence open → blank → heading → horizontal rule → blockquote → list item
///   → paragraph continuation
///
/// Paragraphs merge consecutive non-blank lines with a single space; blockquotes merge consecutive
/// `>` lines joined with `\n`. Pure `Foundation`-only code — no AppKit, no shared mutable state.
enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        // Split on `\n` only (project-wide logical-line convention, see `LogicalLine`), stripping a
        // single trailing `\r` per line so CRLF documents parse identically to LF ones.
        let lines = source
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        var blocks: [MarkdownBlock] = []

        // Paragraph accumulator (space-joined). Mutually exclusive with the quote accumulator:
        // starting either flushes the other, so at most one is ever active.
        var paragraphLines: [String] = []
        var paragraphStart = 0
        var inParagraph = false

        // Blockquote accumulator (`\n`-joined; a bare `>` contributes an empty line).
        var quoteLines: [String] = []
        var quoteStart = 0
        var inQuote = false

        // Fence accumulator (verbatim, `\n`-joined). While active, every line except a closing
        // fence is taken literally.
        var fenceLines: [String] = []
        var fenceStart = 0
        var inFence = false

        func flushParagraph() {
            guard inParagraph else { return }
            blocks.append(.paragraph(text: paragraphLines.joined(separator: " "), line: paragraphStart))
            paragraphLines.removeAll()
            inParagraph = false
        }

        func flushQuote() {
            guard inQuote else { return }
            blocks.append(.blockquote(text: quoteLines.joined(separator: "\n"), line: quoteStart))
            quoteLines.removeAll()
            inQuote = false
        }

        for (index, line) in lines.enumerated() {
            // 1. Inside a fence: only a closing fence line ends it; everything else is verbatim.
            if inFence {
                if isFenceClose(line) {
                    blocks.append(.codeBlock(code: fenceLines.joined(separator: "\n"), line: fenceStart))
                    fenceLines.removeAll()
                    inFence = false
                } else {
                    fenceLines.append(line)
                }
                continue
            }

            // 2. Fence open — column 0 only; any info string after the backticks is ignored.
            if isFenceOpen(line) {
                flushParagraph()
                flushQuote()
                fenceStart = index
                inFence = true
                continue
            }

            // 3. Blank line — terminates a pending paragraph or blockquote; emits nothing itself.
            if isBlank(line) {
                flushParagraph()
                flushQuote()
                continue
            }

            // 4. ATX heading.
            if let heading = parseHeading(line) {
                flushParagraph()
                flushQuote()
                blocks.append(.heading(level: heading.level, text: heading.text, line: index))
                continue
            }

            // 5. Horizontal rule — checked before the list item so `---`/`***` are rules while
            //    `- item`/`* item` remain list items.
            if isRule(line) {
                flushParagraph()
                flushQuote()
                blocks.append(.rule(line: index))
                continue
            }

            // 6. Blockquote — a `>` line ends a paragraph but continues/starts a quote block.
            if line.first == ">" {
                flushParagraph()
                if !inQuote {
                    inQuote = true
                    quoteStart = index
                }
                quoteLines.append(stripQuoteMarker(line))
                continue
            }

            // 7. List item (unordered `- * +` or ordered `N.`/`N)`).
            if let item = parseListItem(line) {
                flushParagraph()
                flushQuote()
                blocks.append(.listItem(marker: item.marker, text: item.text, line: index))
                continue
            }

            // 8. Paragraph continuation — a non-`>` text line ends a quote and extends/starts a
            //    paragraph.
            flushQuote()
            if !inParagraph {
                inParagraph = true
                paragraphStart = index
            }
            paragraphLines.append(line)
        }

        // EOF: flush whatever is pending. At most one accumulator is active, but flushing all three
        // unconditionally is safe. An unterminated fence renders its collected content.
        flushParagraph()
        flushQuote()
        if inFence {
            blocks.append(.codeBlock(code: fenceLines.joined(separator: "\n"), line: fenceStart))
        }

        return blocks
    }

    // MARK: - Line classifiers

    /// Empty or whitespace-only (space/tab). Terminates paragraphs and blockquotes.
    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Count of leading backtick characters at column 0.
    private static func leadingBacktickCount(_ line: String) -> Int {
        var count = 0
        for character in line {
            if character == "`" {
                count += 1
            } else {
                break
            }
        }
        return count
    }

    /// Opens a fence: three-or-more backticks at column 0 (an indented ``` falls through to
    /// paragraph text). Any info string after the backticks is ignored by the caller.
    private static func isFenceOpen(_ line: String) -> Bool {
        leadingBacktickCount(line) >= 3
    }

    /// Closes a fence: three-or-more backticks followed only by optional trailing whitespace (an
    /// info string on the line means it is not a close).
    private static func isFenceClose(_ line: String) -> Bool {
        let count = leadingBacktickCount(line)
        guard count >= 3 else { return false }
        return line.dropFirst(count).allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// An ATX heading: `#{1,6}` at column 0 followed by at least one space/tab. The text is the
    /// remainder after the markers with ALL leading/trailing whitespace stripped (so `"##   Title"`
    /// → `"Title"`, and a bare `"# "` → `""`). `#unspaced` and `####### seven` are not headings.
    private static func parseHeading(_ line: String) -> (level: Int, text: String)? {
        let characters = Array(line)
        var index = 0
        while index < characters.count, characters[index] == "#" {
            index += 1
        }
        let level = index
        guard (1...6).contains(level) else { return nil }
        guard index < characters.count, characters[index] == " " || characters[index] == "\t" else {
            return nil
        }
        let rest = String(characters[index...])
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// A horizontal rule: three-or-more `-` OR three-or-more `*` (no mixing), optionally with
    /// trailing whitespace. Leading whitespace disqualifies it (it would fall through to a
    /// paragraph). Checked before the list item so `- item`/`* item` stay list items.
    private static func isRule(_ line: String) -> Bool {
        var characters = Array(line)
        while let last = characters.last, last == " " || last == "\t" {
            characters.removeLast()
        }
        guard characters.count >= 3 else { return false }
        let first = characters[0]
        guard first == "-" || first == "*" else { return false }
        return characters.allSatisfy { $0 == first }
    }

    /// Strips a blockquote line's leading `>` and one optional following space. A bare `>` yields
    /// an empty string (an empty quoted line).
    private static func stripQuoteMarker(_ line: String) -> String {
        var rest = line.dropFirst() // drop the leading '>'
        if rest.first == " " {
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    /// A list item. Unordered: `- * +` at column 0 followed by at least one space/tab, rendered
    /// with a `•` prefix. Ordered: `[0-9]+` then `.` or `)` then whitespace, rendered with the
    /// source number plus `.` (e.g. `"3."`). Returns the rendered marker and the item's text (the
    /// remainder after the marker and its trailing whitespace run).
    private static func parseListItem(_ line: String) -> (marker: String, text: String)? {
        let characters = Array(line)
        guard let first = characters.first else { return nil }

        // Unordered.
        if first == "-" || first == "*" || first == "+" {
            guard characters.count >= 2, characters[1] == " " || characters[1] == "\t" else {
                return nil
            }
            var index = 1
            while index < characters.count, characters[index] == " " || characters[index] == "\t" {
                index += 1
            }
            return ("•", String(characters[index...]))
        }

        // Ordered.
        var index = 0
        while index < characters.count, ("0"..."9").contains(characters[index]) {
            index += 1
        }
        guard index > 0 else { return nil }
        guard index < characters.count, characters[index] == "." || characters[index] == ")" else {
            return nil
        }
        let number = String(characters[0..<index])
        index += 1 // skip the '.'/')' delimiter
        guard index < characters.count, characters[index] == " " || characters[index] == "\t" else {
            return nil
        }
        while index < characters.count, characters[index] == " " || characters[index] == "\t" {
            index += 1
        }
        return ("\(number).", String(characters[index...]))
    }
}

// MARK: - Inline model (Tier 2)

/// The recursive inline model produced by `MarkdownInlineParser`, mapped to attributes by the
/// Tier-3 emitter. `url` on `.link` is the RAW source string, stored verbatim — URL validation (and
/// the decision to attach a `.link` attribute) happens only in the emitter, per the plan's
/// criterion 10.
enum InlineNode: Equatable {
    case text(String)
    case bold([InlineNode])
    case italic([InlineNode])
    case code(String)
    case link(text: String, url: String)
}

/// The inline parser for the SPEC §8.2 subset. A single left-to-right character scan with recursive
/// descent for emphasis bodies. At each scan position it checks opener patterns in the fixed
/// precedence order code span → link → bold → italic; the FIRST pattern that matches is the
/// committed construct at that position — there is no fall-through to a lower-precedence construct
/// once an opener matches. The closer is the nearest matching closing delimiter after the opener,
/// scanning left to right with NO backtracking; if none exists, the opener's delimiter character(s)
/// emit as literal text and scanning resumes just after them. Consecutive literal characters
/// coalesce into a single `.text` node so `Equatable` trees are deterministic (criteria 9-13).
///
/// This rule pins exactly one parse for every ambiguous input. Note that an italic body can never
/// contain a `*` (the nearest `*` after the opener is always taken as the closer), so running the
/// full recursive parser on an italic body can only ever produce code spans / links / text — never
/// nested emphasis — which is exactly criterion 12's "recursively parsed for code spans and links
/// (not for bold)". Pure `Foundation`-only code.
enum MarkdownInlineParser {
    static func parse(_ text: String) -> [InlineNode] {
        parseNodes(Array(text))
    }

    private static func parseNodes(_ characters: [Character]) -> [InlineNode] {
        var nodes: [InlineNode] = []
        var literal: [Character] = []
        var index = 0
        let count = characters.count

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            nodes.append(.text(String(literal)))
            literal.removeAll()
        }

        // `parseLink`'s two closer scans (`]` then `)`) are the only quadratic-prone construct in
        // this scan (see md-link-scan-quadratic plan): on a failed link the driver advances only ONE
        // character, so the next `[` would otherwise re-scan to EOF. Precompute, in one backward
        // pass, "nearest `]`/`)` at or after i" so `parseLink` becomes O(1) per call. Built ONLY when
        // `characters` contains a `[` — `parseLink` is reached only after the driver sees a `[`, so a
        // bracket-free slice never builds or reads these arrays (zero extra allocation on the hot
        // path). `nextCloseBracket[i]`/`nextCloseParen[i]` equal exactly what
        // `firstIndex(of: "]"/")" , from: i)` return today, with the sentinel `count` standing in for
        // `nil` — this memoization is what keeps the produced tree byte-identical.
        var nextCloseBracket: [Int] = []
        var nextCloseParen: [Int] = []
        if characters.contains("[") {
            nextCloseBracket = [Int](repeating: 0, count: count + 1)
            nextCloseParen = [Int](repeating: 0, count: count + 1)
            nextCloseBracket[count] = count
            nextCloseParen[count] = count
            var i = count - 1
            while i >= 0 {
                nextCloseBracket[i] = (characters[i] == "]") ? i : nextCloseBracket[i + 1]
                nextCloseParen[i] = (characters[i] == ")") ? i : nextCloseParen[i + 1]
                i -= 1
            }
        }

        while index < count {
            let character = characters[index]

            // 1. Code span — matched before any other construct; content is literal.
            if character == "`" {
                if let close = firstIndex(of: "`", in: characters, from: index + 1) {
                    flushLiteral()
                    nodes.append(.code(String(characters[(index + 1)..<close])))
                    index = close + 1
                    continue
                }
                // No closer: the backtick is literal.
                literal.append(character)
                index += 1
                continue
            }

            // 2. Link — `[title](url)`. Title stored verbatim (not inline-parsed); url verbatim.
            if character == "[" {
                if let link = parseLink(characters, from: index, nextCloseBracket: nextCloseBracket, nextCloseParen: nextCloseParen) {
                    flushLiteral()
                    nodes.append(.link(text: link.title, url: link.url))
                    index = link.end
                    continue
                }
                // No valid link form: the `[` is literal.
                literal.append(character)
                index += 1
                continue
            }

            // 3. Bold — `**...**`, checked before italic so `**` is never two italic delimiters.
            if character == "*", index + 1 < count, characters[index + 1] == "*" {
                if let close = firstDoubleIndex(of: "*", in: characters, from: index + 2) {
                    flushLiteral()
                    nodes.append(.bold(parseNodes(Array(characters[(index + 2)..<close]))))
                    index = close + 2
                    continue
                }
                // No closer: the `**` opener emits literally; resume after both characters. It does
                // NOT fall through to be re-read as two italic delimiters.
                literal.append("*")
                literal.append("*")
                index += 2
                continue
            }

            // 4. Italic — `*...*`.
            if character == "*" {
                if let close = firstIndex(of: "*", in: characters, from: index + 1) {
                    flushLiteral()
                    nodes.append(.italic(parseNodes(Array(characters[(index + 1)..<close]))))
                    index = close + 1
                    continue
                }
                // No closer: the `*` is literal.
                literal.append(character)
                index += 1
                continue
            }

            // Ordinary character.
            literal.append(character)
            index += 1
        }

        flushLiteral()
        return nodes
    }

    /// Index of the nearest `character` at or after `from`, else nil.
    private static func firstIndex(of character: Character, in characters: [Character], from: Int) -> Int? {
        var index = from
        while index < characters.count {
            if characters[index] == character {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Index of the nearest pair `character` immediately followed by `character` starting at or
    /// after `from`, else nil.
    private static func firstDoubleIndex(of character: Character, in characters: [Character], from: Int) -> Int? {
        var index = from
        while index + 1 < characters.count {
            if characters[index] == character, characters[index + 1] == character {
                return index
            }
            index += 1
        }
        return nil
    }

    /// Parses `[title](url)` starting at `open` (`characters[open] == "["`). Uses the nearest `]`
    /// after `[`, which must be immediately followed by `(`, then the nearest `)` after that.
    /// Returns the verbatim title, verbatim url, and the index just past the closing `)`; nil if
    /// the full form is not present (the caller then emits `[` literally).
    ///
    /// `nextCloseBracket`/`nextCloseParen` are the per-invocation memo built in `parseNodes`:
    /// `nextCloseBracket[f]`/`nextCloseParen[f]` equal exactly what
    /// `firstIndex(of: "]"/")" , in: characters, from: f)` would return, with the sentinel
    /// `characters.count` standing in for `nil`. Guaranteed built and non-empty here because this
    /// function is only ever called after the driver has seen a `[`.
    private static func parseLink(
        _ characters: [Character],
        from open: Int,
        nextCloseBracket: [Int],
        nextCloseParen: [Int]
    ) -> (title: String, url: String, end: Int)? {
        let closeBracket = nextCloseBracket[open + 1]
        guard closeBracket < characters.count else { return nil }
        let paren = closeBracket + 1
        guard paren < characters.count, characters[paren] == "(" else { return nil }
        let closeParen = nextCloseParen[paren + 1]
        guard closeParen < characters.count else { return nil }
        let title = String(characters[(open + 1)..<closeBracket])
        let url = String(characters[(paren + 1)..<closeParen])
        return (title, url, closeParen + 1)
    }
}

// MARK: - Preview styling (Tier 3)

/// The paragraph styles, spacing constants, and rule attributes the preview needs that `Theme`
/// does not provide. `Theme` owns all fonts/colors (this renderer consumes `Theme.headingFont`,
/// `Theme.codeFont`, `Theme.codeBackground`, `Theme.link`, `Theme.mutedText`, `Theme.text`, and —
/// for regular body text — `Theme.bodyFont`); `PreviewStyle` defines ONLY what `Theme` lacks:
/// block spacing done via `paragraphSpacing` (never via padding blank lines, which would break the
/// anchor `location` invariant), list hanging indent, blockquote indent, and the rule glyph run's
/// attributes.
private enum PreviewStyle {
    /// Vertical gap after a block, in points. Realized via `paragraphSpacing` so it never adds
    /// characters to the output (criterion 16).
    static let blockSpacing: CGFloat = 8

    /// Reduced spacing between consecutive list items so a list reads as visually continuous
    /// (criterion 3) while each item still gets its own anchor.
    static let listItemSpacing: CGFloat = 3

    /// List hanging-indent width (and tab-stop location), in points.
    static let listIndent: CGFloat = 22

    /// Blockquote indent, in points.
    static let quoteIndent: CGFloat = 16

    /// Number of horizontal-bar glyphs a horizontal rule emits. The renderer is width-unaware
    /// (pure model, no view), so a fixed-length gray run stands in for a full-width divider; the
    /// preview view may still visually stretch it.
    static let ruleGlyphCount = 32

    static let bodyParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        return style
    }()

    static let headingParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        return style
    }()

    static let codeParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        return style
    }()

    static let listParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = listItemSpacing
        style.firstLineHeadIndent = 0
        style.headIndent = listIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
        style.defaultTabInterval = listIndent
        return style
    }()

    static let quoteParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        return style
    }()

    static let ruleAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.bodyFont,
        .foregroundColor: Theme.mutedText,
        .paragraphStyle: bodyParagraph,
    ]
}

/// Body-text bold/italic faces derived from `Theme.bodyFont`. `Theme` exposes bold/italic only for
/// the monospaced *editor* font (`editorBoldFont`/`editorItalic`); a proportional body-bold/italic
/// is what `Theme` lacks for the preview, so it is derived here from `Theme.bodyFont`'s descriptor
/// (staying within `NSFont`, no `NSFontManager`). The italic face falls back to the plain body font
/// if the platform reports no real italic trait (a rare case; body emphasis fonts are not part of
/// any asserted criterion).
private enum PreviewFont {
    static let bodyBold: NSFont = {
        let descriptor = Theme.bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: descriptor, size: Theme.bodyFont.pointSize) ?? Theme.bodyFont
    }()

    static let bodyItalic: NSFont = {
        let descriptor = Theme.bodyFont.fontDescriptor.withSymbolicTraits(.italic)
        let candidate = NSFont(descriptor: descriptor, size: Theme.bodyFont.pointSize) ?? Theme.bodyFont
        return candidate.fontDescriptor.symbolicTraits.contains(.italic) ? candidate : Theme.bodyFont
    }()
}

// MARK: - Public renderer (Tier 3)

/// The pure, UI-free Markdown renderer (SPEC §8.2, styled from `Editor/Theme.swift`). `render`
/// runs `MarkdownBlockParser`, emits each block's inline runs via `MarkdownInlineParser`, and
/// records one `MarkdownAnchor` per block. It is a `static` function with no `@MainActor`/view
/// dependencies (only `NSAttributedString`/`NSFont`/`NSColor`/`NSParagraphStyle`) and touches no
/// shared mutable state, so it is safe to call off the main thread from a later debounce queue
/// (criterion 18).
enum MarkdownRenderer {
    static func render(_ source: String) -> (output: NSAttributedString, anchors: [MarkdownAnchor]) {
        let blocks = MarkdownBlockParser.parse(source)
        let output = NSMutableAttributedString()
        var anchors: [MarkdownAnchor] = []

        for (index, block) in blocks.enumerated() {
            // Record the anchor BEFORE appending: `location` is where this block's first character
            // will land (or, for an empty block, the zero-length position at that offset).
            anchors.append(MarkdownAnchor(sourceLine: block.line, location: output.length))
            emit(block, into: output)

            // A single `\n` separator follows EVERY non-final block, including empty ones. This —
            // not block non-emptiness — is what guarantees strictly ascending anchor `location`s
            // (criterion 16). It must never be optimized away for empty blocks.
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        assertStrictlyAscending(anchors, outputLength: output.length)
        return (output, anchors)
    }

    /// Debug-only guard that the produced anchors satisfy the ordering contract the downstream
    /// binary-search lookup depends on (criteria 15-16). Compiled out of release builds.
    private static func assertStrictlyAscending(_ anchors: [MarkdownAnchor], outputLength: Int) {
        if anchors.count > 1 {
            for index in 1..<anchors.count {
                assert(
                    anchors[index].sourceLine > anchors[index - 1].sourceLine,
                    "anchors must be strictly ascending in sourceLine"
                )
                assert(
                    anchors[index].location > anchors[index - 1].location,
                    "anchors must be strictly ascending in location"
                )
            }
        }
        if let last = anchors.last {
            assert(last.location <= outputLength, "anchor location must lie in 0...output.length")
        }
    }

    // MARK: - Block emission

    private static func emit(_ block: MarkdownBlock, into output: NSMutableAttributedString) {
        switch block {
        case let .heading(level, text, _):
            emitInline(MarkdownInlineParser.parse(text), style: headingStyle(level: level), into: output)

        case let .paragraph(text, _):
            emitInline(MarkdownInlineParser.parse(text), style: bodyStyle, into: output)

        case let .listItem(marker, text, _):
            // Marker glyph + tab, then the item's inline content — all sharing the hanging-indent
            // paragraph style so wrapped lines align under the text, not the bullet.
            output.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: Theme.bodyFont,
                .foregroundColor: Theme.text,
                .paragraphStyle: PreviewStyle.listParagraph,
            ]))
            emitInline(MarkdownInlineParser.parse(text), style: listStyle, into: output)

        case let .blockquote(text, _):
            // The quote text may carry embedded `\n`s (multi-line quote); the inline parser treats
            // them as ordinary characters, so they render as in-block line breaks.
            emitInline(MarkdownInlineParser.parse(text), style: quoteStyle, into: output)

        case let .codeBlock(code, _):
            // Verbatim, monospaced, on the code background. Empty code emits zero characters.
            output.append(NSAttributedString(string: code, attributes: [
                .font: Theme.codeFont,
                .foregroundColor: Theme.text,
                .backgroundColor: Theme.codeBackground,
                .paragraphStyle: PreviewStyle.codeParagraph,
            ]))

        case .rule:
            output.append(NSAttributedString(
                string: String(repeating: "─", count: PreviewStyle.ruleGlyphCount),
                attributes: PreviewStyle.ruleAttributes
            ))
        }
    }

    // MARK: - Inline emission

    /// The font/color/paragraph context an inline run is emitted in. Value type so recursive
    /// emphasis emission can hand children a modified copy without shared mutation.
    private struct InlineStyle {
        let font: NSFont
        let boldFont: NSFont
        let italicFont: NSFont
        let color: NSColor
        let paragraphStyle: NSParagraphStyle
    }

    private static let bodyStyle = InlineStyle(
        font: Theme.bodyFont,
        boldFont: PreviewFont.bodyBold,
        italicFont: PreviewFont.bodyItalic,
        color: Theme.text,
        paragraphStyle: PreviewStyle.bodyParagraph
    )

    private static let listStyle = InlineStyle(
        font: Theme.bodyFont,
        boldFont: PreviewFont.bodyBold,
        italicFont: PreviewFont.bodyItalic,
        color: Theme.text,
        paragraphStyle: PreviewStyle.listParagraph
    )

    private static let quoteStyle = InlineStyle(
        font: Theme.bodyFont,
        boldFont: PreviewFont.bodyBold,
        italicFont: PreviewFont.bodyItalic,
        color: Theme.mutedText,
        paragraphStyle: PreviewStyle.quoteParagraph
    )

    private static func headingStyle(level: Int) -> InlineStyle {
        // Headings are already bold (Theme.headingFont returns a bold face); nested emphasis inside
        // a heading keeps the heading font.
        let font = Theme.headingFont(level: level)
        return InlineStyle(
            font: font,
            boldFont: font,
            italicFont: font,
            color: Theme.text,
            paragraphStyle: PreviewStyle.headingParagraph
        )
    }

    private static func emitInline(_ nodes: [InlineNode], style: InlineStyle, into output: NSMutableAttributedString) {
        for node in nodes {
            switch node {
            case let .text(value):
                output.append(NSAttributedString(string: value, attributes: [
                    .font: style.font,
                    .foregroundColor: style.color,
                    .paragraphStyle: style.paragraphStyle,
                ]))

            case let .bold(children):
                let boldStyle = InlineStyle(
                    font: style.boldFont,
                    boldFont: style.boldFont,
                    italicFont: style.italicFont,
                    color: style.color,
                    paragraphStyle: style.paragraphStyle
                )
                emitInline(children, style: boldStyle, into: output)

            case let .italic(children):
                let italicStyle = InlineStyle(
                    font: style.italicFont,
                    boldFont: style.boldFont,
                    italicFont: style.italicFont,
                    color: style.color,
                    paragraphStyle: style.paragraphStyle
                )
                emitInline(children, style: italicStyle, into: output)

            case let .code(value):
                output.append(NSAttributedString(string: value, attributes: [
                    .font: Theme.codeFont,
                    .foregroundColor: Theme.text,
                    .backgroundColor: Theme.codeBackground,
                    .paragraphStyle: style.paragraphStyle,
                ]))

            case let .link(title, url):
                // Attach the `.link` attribute (a Foundation `URL`) ONLY when `URL(string:)`
                // succeeds; a garbage url renders as plain body-styled text with no link
                // attribute/underline, its raw string already discarded here (criterion 10).
                if let parsed = URL(string: url) {
                    output.append(NSAttributedString(string: title, attributes: [
                        .font: style.font,
                        .foregroundColor: Theme.link,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                        .link: parsed,
                        .paragraphStyle: style.paragraphStyle,
                    ]))
                } else {
                    output.append(NSAttributedString(string: title, attributes: [
                        .font: style.font,
                        .foregroundColor: style.color,
                        .paragraphStyle: style.paragraphStyle,
                    ]))
                }
            }
        }
    }
}
