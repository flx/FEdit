//
//  main.swift
//  MarkdownRendererTests
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
//  Standalone assertion harness for `MarkdownRenderer` (markdown-renderer Tiers 1-3). Not part of
//  the app target — compiled and run manually:
//
//      swiftc FEdit/Preview/MarkdownRenderer.swift FEdit/Editor/Theme.swift scripts/MarkdownRendererTests/main.swift -o /tmp/mdtests && /tmp/mdtests
//
//  Named `main.swift` because Swift only allows top-level statements in a file with that exact
//  name when compiling multiple files together. Multi-file `swiftc` yields one module, so the
//  internal types (`MarkdownBlockParser`, `MarkdownBlock`, `InlineNode`, `MarkdownInlineParser`,
//  `MarkdownRenderer`) are directly testable without `@testable` or an XCTest target.
//

import AppKit

// MARK: - Tiny test harness

var failureCount = 0

func check(_ condition: Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
    if condition {
        print("  PASS: \(message)")
    } else {
        failureCount += 1
        print("  FAIL: \(message) (\(file):\(line))")
    }
}

func section(_ title: String) {
    print("\n== \(title) ==")
}

// MARK: - Criterion 1: ATX headings

section("Criterion 1: ATX headings")
check(
    MarkdownBlockParser.parse("# Title") == [.heading(level: 1, text: "Title", line: 0)],
    "\"# Title\" -> level-1 heading \"Title\""
)
check(
    MarkdownBlockParser.parse("###### Deep") == [.heading(level: 6, text: "Deep", line: 0)],
    "\"###### Deep\" -> level-6 heading"
)
check(
    MarkdownBlockParser.parse("##   Title") == [.heading(level: 2, text: "Title", line: 0)],
    "\"##   Title\" strips ALL leading whitespace -> \"Title\""
)
check(
    MarkdownBlockParser.parse("##  Trailing   \t") == [.heading(level: 2, text: "Trailing", line: 0)],
    "heading strips ALL trailing whitespace"
)
check(
    MarkdownBlockParser.parse("#unspaced") == [.paragraph(text: "#unspaced", line: 0)],
    "\"#unspaced\" (no space) is a paragraph, not a heading"
)
check(
    MarkdownBlockParser.parse("####### seven") == [.paragraph(text: "####### seven", line: 0)],
    "\"####### seven\" (7 hashes) is a paragraph, not a heading"
)
check(
    MarkdownBlockParser.parse("# ") == [.heading(level: 1, text: "", line: 0)],
    "bare \"# \" is a legal heading with empty text"
)

// MARK: - Criterion 2: Paragraphs

section("Criterion 2: Paragraphs")
check(
    MarkdownBlockParser.parse("a\nb\n\nc") == [
        .paragraph(text: "a b", line: 0),
        .paragraph(text: "c", line: 3),
    ],
    "\"a\\nb\\n\\nc\" -> two paragraphs \"a b\" and \"c\""
)
check(
    MarkdownBlockParser.parse("only one line") == [.paragraph(text: "only one line", line: 0)],
    "single line -> one paragraph"
)
check(
    MarkdownBlockParser.parse("a\n   \nb") == [
        .paragraph(text: "a", line: 0),
        .paragraph(text: "b", line: 2),
    ],
    "a whitespace-only line terminates a paragraph"
)

// MARK: - Criterion 3: Unordered lists

section("Criterion 3: Unordered lists")
check(
    MarkdownBlockParser.parse("- one\n- two") == [
        .listItem(marker: "•", text: "one", line: 0),
        .listItem(marker: "•", text: "two", line: 1),
    ],
    "consecutive `-` items are one anchor each"
)
check(
    MarkdownBlockParser.parse("* a") == [.listItem(marker: "•", text: "a", line: 0)],
    "`*` bullet -> `•` marker"
)
check(
    MarkdownBlockParser.parse("+ a") == [.listItem(marker: "•", text: "a", line: 0)],
    "`+` bullet -> `•` marker"
)
check(
    MarkdownBlockParser.parse("-   spaced") == [.listItem(marker: "•", text: "spaced", line: 0)],
    "extra whitespace after the bullet is consumed"
)
check(
    MarkdownBlockParser.parse("-notitem") == [.paragraph(text: "-notitem", line: 0)],
    "`-` without a following space is not a list item"
)

// MARK: - Criterion 4: Ordered lists

section("Criterion 4: Ordered lists")
check(
    MarkdownBlockParser.parse("3. third") == [.listItem(marker: "3.", text: "third", line: 0)],
    "\"3. third\" -> marker \"3.\""
)
check(
    MarkdownBlockParser.parse("2) second") == [.listItem(marker: "2.", text: "second", line: 0)],
    "\"2) second\" -> rendered marker \"2.\""
)
check(
    MarkdownBlockParser.parse("42. answer") == [.listItem(marker: "42.", text: "answer", line: 0)],
    "multi-digit ordered marker preserved"
)
check(
    MarkdownBlockParser.parse("1.") == [.paragraph(text: "1.", line: 0)],
    "\"1.\" with no following whitespace is a paragraph, not a list item"
)

// MARK: - Criterion 5: Blockquotes

section("Criterion 5: Blockquotes")
check(
    MarkdownBlockParser.parse("> a\n>\n> b") == [.blockquote(text: "a\n\nb", line: 0)],
    "\"> a\\n>\\n> b\" -> one blockquote with text \"a\\n\\nb\" (bare `>` = empty line)"
)
check(
    MarkdownBlockParser.parse("> q1\n> q2") == [.blockquote(text: "q1\nq2", line: 0)],
    "consecutive `>` lines join with `\\n`"
)
check(
    MarkdownBlockParser.parse(">no space") == [.blockquote(text: "no space", line: 0)],
    "`>` with no following space still strips only the marker"
)
check(
    MarkdownBlockParser.parse("> q\ntext") == [
        .blockquote(text: "q", line: 0),
        .paragraph(text: "text", line: 1),
    ],
    "a non-`>` line ends the quote and starts a paragraph"
)

// MARK: - Criterion 6: Fenced code blocks

section("Criterion 6: Fenced code blocks")
check(
    MarkdownBlockParser.parse("```swift\ncode\n# not a heading\n```") == [
        .codeBlock(code: "code\n# not a heading", line: 0),
    ],
    "info string ignored; contents verbatim, `# not a heading` stays literal"
)
check(
    MarkdownBlockParser.parse("```\nx\ny") == [.codeBlock(code: "x\ny", line: 0)],
    "unterminated fence renders its collected content (no crash)"
)
check(
    MarkdownBlockParser.parse("    ```") == [.paragraph(text: "    ```", line: 0)],
    "an indented ``` is NOT a fence (falls through to paragraph text)"
)
check(
    MarkdownBlockParser.parse("```\n```") == [.codeBlock(code: "", line: 0)],
    "immediately closed fence is a legal empty code block"
)
check(
    MarkdownBlockParser.parse("````\ntext\n````") == [.codeBlock(code: "text", line: 0)],
    "four-backtick fence opens and closes"
)

// MARK: - Criterion 7: Horizontal rules

section("Criterion 7: Horizontal rules")
check(MarkdownBlockParser.parse("---") == [.rule(line: 0)], "\"---\" is a rule")
check(MarkdownBlockParser.parse("***") == [.rule(line: 0)], "\"***\" is a rule")
check(MarkdownBlockParser.parse("-----") == [.rule(line: 0)], "\"-----\" (5 dashes) is a rule")
check(MarkdownBlockParser.parse("***   ") == [.rule(line: 0)], "trailing whitespace on a rule is allowed")
check(
    MarkdownBlockParser.parse("--") == [.paragraph(text: "--", line: 0)],
    "\"--\" (only two dashes) is not a rule"
)
check(
    MarkdownBlockParser.parse("- item") == [.listItem(marker: "•", text: "item", line: 0)],
    "\"- item\" is a list item (rule check runs before list, but this is not all-dashes)"
)
check(
    MarkdownBlockParser.parse("* item") == [.listItem(marker: "•", text: "item", line: 0)],
    "\"* item\" is a list item, not a rule"
)

// MARK: - Criterion 8: Block precedence & termination (no blank line required)

section("Criterion 8: block termination without a blank line")
check(
    MarkdownBlockParser.parse("text\n# H") == [
        .paragraph(text: "text", line: 0),
        .heading(level: 1, text: "H", line: 1),
    ],
    "a heading terminates a preceding paragraph"
)
check(
    MarkdownBlockParser.parse("text\n- item") == [
        .paragraph(text: "text", line: 0),
        .listItem(marker: "•", text: "item", line: 1),
    ],
    "a list item terminates a preceding paragraph"
)
check(
    MarkdownBlockParser.parse("text\n---") == [
        .paragraph(text: "text", line: 0),
        .rule(line: 1),
    ],
    "a rule terminates a preceding paragraph"
)
check(
    MarkdownBlockParser.parse("text\n> q") == [
        .paragraph(text: "text", line: 0),
        .blockquote(text: "q", line: 1),
    ],
    "a quote terminates a preceding paragraph"
)
check(
    MarkdownBlockParser.parse("text\n```\ncode\n```") == [
        .paragraph(text: "text", line: 0),
        .codeBlock(code: "code", line: 1),
    ],
    "a fence terminates a preceding paragraph"
)

// MARK: - Criterion 17 (block-level halves): edge inputs

section("Criterion 17: block-level edge inputs")
check(MarkdownBlockParser.parse("") == [], "empty string -> no blocks")
check(MarkdownBlockParser.parse("   ") == [], "spaces-only -> no blocks")
check(MarkdownBlockParser.parse("  \n\t\n") == [], "whitespace-only multi-line -> no blocks")
check(
    MarkdownBlockParser.parse("# H") == [.heading(level: 1, text: "H", line: 0)],
    "no trailing newline still parses"
)
check(
    MarkdownBlockParser.parse("a\r\nb\r\n\r\nc") == [
        .paragraph(text: "a b", line: 0),
        .paragraph(text: "c", line: 3),
    ],
    "CRLF input parses identically to LF (trailing \\r stripped per line)"
)
check(
    MarkdownBlockParser.parse("```\n```\n```\n```") == [
        .codeBlock(code: "", line: 0),
        .codeBlock(code: "", line: 2),
    ],
    "two-empty-fences doc -> two empty code blocks at lines 0 and 2"
)
do {
    let giant = "```\n" + String(repeating: "line\n", count: 5000)
    let blocks = MarkdownBlockParser.parse(giant)
    check(blocks.count == 1, "one giant unterminated fence -> a single code block (no crash)")
}

// MARK: - Criterion 9: Code spans

section("Criterion 9: code spans")
check(MarkdownInlineParser.parse("`code`") == [.code("code")], "`code` -> .code(\"code\")")
check(
    MarkdownInlineParser.parse("`**x**`") == [.code("**x**")],
    "code span content is literal — `**x**` shows the asterisks"
)
check(MarkdownInlineParser.parse("``") == [.code("")], "empty code span is legal: .code(\"\")")
check(
    MarkdownInlineParser.parse("a `b` c") == [.text("a "), .code("b"), .text(" c")],
    "code span surrounded by text"
)
check(
    MarkdownInlineParser.parse("`unclosed") == [.text("`unclosed")],
    "unclosed backtick is literal"
)

// MARK: - Criterion 10: Links (raw url stored verbatim; validation is the emitter's job)

section("Criterion 10: links")
check(
    MarkdownInlineParser.parse("[title](url)") == [.link(text: "title", url: "url")],
    "[title](url) -> .link node with raw url"
)
check(
    MarkdownInlineParser.parse("[a](http://example.com)") == [.link(text: "a", url: "http://example.com")],
    "url stored verbatim"
)
check(
    MarkdownInlineParser.parse("[t](http://[bad)") == [.link(text: "t", url: "http://[bad")],
    "garbage url kept verbatim in the node (emitter decides link-ness)"
)
check(
    MarkdownInlineParser.parse("[title]") == [.text("[title]")],
    "[title] without (url) renders literally"
)
check(
    MarkdownInlineParser.parse("[t](u") == [.text("[t](u")],
    "unclosed link form renders literally"
)

// MARK: - Criterion 11: Bold

section("Criterion 11: bold")
check(MarkdownInlineParser.parse("**b**") == [.bold([.text("b")])], "**b** -> bold")
check(MarkdownInlineParser.parse("****") == [.bold([])], "**** -> .bold([]) (empty, legal)")
check(MarkdownInlineParser.parse("**b") == [.text("**b")], "unmatched ** renders literally")
check(
    MarkdownInlineParser.parse("**bold *italic* code `x`**")
        == [.bold([.text("bold "), .italic([.text("italic")]), .text(" code "), .code("x")])],
    "bold content nests italic + code recursively"
)

// MARK: - Criterion 12: Italic

section("Criterion 12: italic")
check(MarkdownInlineParser.parse("*i*") == [.italic([.text("i")])], "*i* -> italic")
check(MarkdownInlineParser.parse("*i") == [.text("*i")], "unmatched * renders literally")
check(
    MarkdownInlineParser.parse("*a `c` b*") == [.italic([.text("a "), .code("c"), .text(" b")])],
    "italic content is parsed for code spans"
)

// MARK: - Criterion 13: Literality + closer-selection (four adversarial trees)

section("Criterion 13: closer-selection rule (adversarial cases)")
check(
    MarkdownInlineParser.parse("**a*b**") == [.bold([.text("a*b")])],
    "**a*b** -> bold(\"a*b\") (lone inner * is literal)"
)
check(
    MarkdownInlineParser.parse("***x***") == [.bold([.text("*x")]), .text("*")],
    "***x*** -> bold(\"*x\") + text(\"*\")"
)
check(
    MarkdownInlineParser.parse("**a**b**") == [.bold([.text("a")]), .text("b**")],
    "**a**b** -> bold(\"a\") + text(\"b**\") (final ** literal, coalesced with b)"
)
check(
    MarkdownInlineParser.parse("*a **b** c*")
        == [.italic([.text("a ")]), .italic([.text("b")]), .italic([.text(" c")])],
    "*a **b** c* -> italic(\"a \") + italic(\"b\") + italic(\" c\")"
)

section("Criterion 13: literal coalescing + no character loss")
check(
    MarkdownInlineParser.parse("plain text 123") == [.text("plain text 123")],
    "consecutive literals coalesce into ONE .text node"
)
func flatten(_ nodes: [InlineNode]) -> String {
    nodes.map { node -> String in
        switch node {
        case let .text(value): return value
        case let .code(value): return value
        case let .link(title, _): return title
        case let .bold(children): return flatten(children)
        case let .italic(children): return flatten(children)
        }
    }.joined()
}
for sample in ["hello world", "no delimiters here 42", "a b c d e", "日本語 テスト"] {
    check(
        flatten(MarkdownInlineParser.parse(sample)) == sample,
        "delimiter-free \"\(sample)\" round-trips (no character loss)"
    )
}
do {
    let long = String(repeating: "x", count: 10_000)
    check(MarkdownInlineParser.parse(long) == [.text(long)], "10 000-char delimiter-free line -> one text node")
}

// MARK: - Tier 3 emitter helpers

/// Attribute at a UTF-16 location, or nil if the location is out of range.
func attribute(_ string: NSAttributedString, _ key: NSAttributedString.Key, at location: Int) -> Any? {
    guard location >= 0, location < string.length else { return nil }
    return string.attribute(key, at: location, effectiveRange: nil)
}

// MARK: - Criterion 1 (emitter half): heading bold + strictly decreasing sizes

section("Criterion 1: heading fonts are bold with strictly decreasing sizes")
do {
    let (output, anchors) = MarkdownRenderer.render("# A\n\n## B\n\n### C\n\n#### D\n\n##### E\n\n###### F")
    check(anchors.count == 6, "six heading blocks -> six anchors")
    var sizes: [CGFloat] = []
    for (level, anchor) in anchors.enumerated() {
        let font = attribute(output, .font, at: anchor.location) as? NSFont
        check(font != nil, "heading level \(level + 1) has a font")
        if let font {
            check(font.fontDescriptor.symbolicTraits.contains(.bold), "heading level \(level + 1) is bold")
            check(font == Theme.headingFont(level: level + 1), "heading level \(level + 1) uses Theme.headingFont")
            sizes.append(font.pointSize)
        }
    }
    var strictlyDecreasing = true
    for index in 1..<sizes.count where !(sizes[index] < sizes[index - 1]) {
        strictlyDecreasing = false
    }
    check(strictlyDecreasing, "heading sizes are strictly decreasing across levels 1...6: \(sizes)")
}

// MARK: - Criterion 9/6 (emitter half): code background + font

section("Criterion 9: code span / block use codeFont on codeBackground")
do {
    let (output, _) = MarkdownRenderer.render("`inline`")
    check(attribute(output, .backgroundColor, at: 0) as? NSColor == Theme.codeBackground, "code span has codeBackground")
    check(attribute(output, .font, at: 0) as? NSFont == Theme.codeFont, "code span uses codeFont")
}
do {
    let (output, _) = MarkdownRenderer.render("```\nhello\n```")
    check(attribute(output, .backgroundColor, at: 0) as? NSColor == Theme.codeBackground, "code block has codeBackground")
    check(attribute(output, .font, at: 0) as? NSFont == Theme.codeFont, "code block uses codeFont")
}

// MARK: - Criterion 10 (emitter half): .link is a URL only when it parses

section("Criterion 10: .link attribute is a Foundation URL, present only on valid urls")
do {
    let (output, _) = MarkdownRenderer.render("[site](https://example.com)")
    let value = attribute(output, .link, at: 0)
    check(value is URL, "valid url -> .link value is a Foundation URL")
    check((value as? URL) == URL(string: "https://example.com"), "the URL matches the source")
    check(attribute(output, .foregroundColor, at: 0) as? NSColor == Theme.link, "link uses Theme.link color")
    check(attribute(output, .underlineStyle, at: 0) != nil, "link is underlined")
}
do {
    // "http://[bad" fails URL(string:) (verified empirically), so no .link attribute is attached.
    let (output, _) = MarkdownRenderer.render("[t](http://[bad)")
    check(attribute(output, .link, at: 0) == nil, "garbage url -> NO .link attribute")
    check(attribute(output, .foregroundColor, at: 0) as? NSColor == Theme.text, "garbage link renders as body text color")
    check(attribute(output, .underlineStyle, at: 0) == nil, "garbage link is not underlined")
}

// MARK: - Criterion 5 (emitter half): blockquote color

section("Criterion 5: blockquote uses mutedText color")
do {
    let (output, _) = MarkdownRenderer.render("> quoted")
    check(attribute(output, .foregroundColor, at: 0) as? NSColor == Theme.mutedText, "blockquote uses Theme.mutedText")
}

// MARK: - Criterion 3 (emitter half): list hanging indent

section("Criterion 3: list item has a hanging indent")
do {
    let (output, _) = MarkdownRenderer.render("- item")
    let style = attribute(output, .paragraphStyle, at: 0) as? NSParagraphStyle
    check(style != nil, "list item has a paragraph style")
    check((style?.headIndent ?? 0) > 0, "list item paragraph style has a positive hanging indent")
}

// MARK: - Criterion 14-16: anchor coverage + strict double ordering

section("Criterion 14-16: one anchor per block, strictly ascending sourceLine and location")
do {
    let document = "# H\n\npara text\n\n- item1\n- item2\n\n> quote\n\n```\ncode\n```\n\n---"
    let (output, anchors) = MarkdownRenderer.render(document)
    // Blocks: heading@0, paragraph@2, listItem@4, listItem@5, blockquote@7, codeBlock@9, rule@13.
    check(anchors.count == 7, "mixed document -> exactly 7 anchors (one per block)")
    check(anchors.map { $0.sourceLine } == [0, 2, 4, 5, 7, 9, 13], "sourceLines match each block's first line")
    var sourceAscending = true
    var locationAscending = true
    for index in 1..<anchors.count {
        if !(anchors[index].sourceLine > anchors[index - 1].sourceLine) { sourceAscending = false }
        if !(anchors[index].location > anchors[index - 1].location) { locationAscending = false }
    }
    check(sourceAscending, "anchors strictly ascending in sourceLine")
    check(locationAscending, "anchors strictly ascending in location")
    check(anchors.allSatisfy { (0...output.length).contains($0.location) }, "every location lies in 0...output.length")
}

// MARK: - Criterion 16: empty blocks still yield strictly ascending locations

section("Criterion 16: two-empty-fences + trailing empty blocks")
do {
    let (output, anchors) = MarkdownRenderer.render("```\n```\n```\n```")
    check(anchors.count == 2, "two empty code blocks -> two anchors")
    check(anchors.map { $0.sourceLine } == [0, 2], "empty-fence sourceLines are 0 and 2")
    check(anchors[0].location < anchors[1].location, "empty blocks still yield strictly ascending locations")
    check(output.length == 1, "output is exactly the single load-bearing separator (length 1)")
}
do {
    // A bare "# " heading emits zero characters; being the only (final) block, its anchor sits at
    // location == output.length (a zero-length end-of-storage position the consumer must tolerate).
    let (output, anchors) = MarkdownRenderer.render("# ")
    check(anchors.count == 1, "bare heading -> one anchor")
    check(output.length == 0, "bare heading emits zero characters")
    check(anchors[0].location == output.length, "trailing empty block anchor sits at output.length")
}
do {
    let (output, anchors) = MarkdownRenderer.render("hello\n\n```\n```")
    check(anchors.count == 2, "paragraph + trailing empty fence -> two anchors")
    check(anchors[1].location == output.length, "trailing empty fence anchor sits at output.length")
}

// MARK: - Criterion 17 (emitter half): edge inputs render without crashing

section("Criterion 17: edge inputs render without crashing")
do {
    let (output, anchors) = MarkdownRenderer.render("")
    check(output.length == 0 && anchors.isEmpty, "empty string -> empty output, no anchors")
}
do {
    let (_, anchors) = MarkdownRenderer.render("   \n\t\n   ")
    check(anchors.isEmpty, "whitespace-only input -> no anchors")
}
do {
    let (_, anchors) = MarkdownRenderer.render("no trailing newline")
    check(anchors.count == 1, "no-trailing-newline input renders")
}
do {
    let (_, anchors) = MarkdownRenderer.render("a\r\nb\r\n\r\nc")
    check(anchors.count == 2, "CRLF input renders (\\r stripped per line)")
}
do {
    let (output, anchors) = MarkdownRenderer.render(String(repeating: "x", count: 10_000))
    check(anchors.count == 1 && output.length == 10_000, "single 10 000-char line renders")
}
do {
    let giant = "```\n" + String(repeating: "line\n", count: 5000)
    let (_, anchors) = MarkdownRenderer.render(giant)
    check(anchors.count == 1, "one giant unterminated fence renders as a single block")
}
check(true, "all edge inputs rendered without crashing (reached this line)")

// MARK: - Criterion 17: determinism

section("Criterion 17: determinism (same input -> equal output + anchors)")
do {
    let document = "# H\n\npara **bold** and *italic* and `code`\n\n- a\n- b\n\n> q\n\n```\nfenced\n```\n\n[x](https://a.b)\n\n---"
    let first = MarkdownRenderer.render(document)
    let second = MarkdownRenderer.render(document)
    check(first.output.isEqual(to: second.output), "output (string + attributes) is identical across runs")
    check(first.anchors == second.anchors, "anchors are identical across runs")
}

// MARK: - Criterion 18: purity (render returns a value; no shared-state side effect observable)

section("Criterion 18: render is a pure static function")
do {
    // Interleaving two renders must not let one affect the other.
    let a1 = MarkdownRenderer.render("# One")
    let b1 = MarkdownRenderer.render("# Two")
    let a2 = MarkdownRenderer.render("# One")
    check(a1.output.isEqual(to: a2.output), "render is independent of prior calls (no shared mutable state)")
    check(!a1.output.isEqual(to: b1.output), "distinct inputs produce distinct output")
}

// MARK: - md-link-scan-quadratic: bracket-heavy output equivalence
//
// Locks byte-identical trees for the three pathological families the plan derives (all `[`
// unmatched; a `]`/`(` exists but the link form still fails; a real link followed by trailing
// unmatched brackets; nearest-closer semantics with a bracket inside the title; code-span/bold
// interaction) against the fixed, memoized `parseLink`. N kept small (5-8) so expected trees are
// written out explicitly.

section("md-link-scan-quadratic: bracket-heavy output equivalence")
do {
    let input = String(repeating: "[", count: 6)
    check(
        MarkdownInlineParser.parse(input) == [.text(input)],
        "family 1: `[`×6 with no `]` anywhere -> all literal, coalesced into one .text node"
    )
}
do {
    let input = String(repeating: "[a](b", count: 5)
    check(
        MarkdownInlineParser.parse(input) == [.text(input)],
        "family 2: `[a](b`×5 with no `)` anywhere -> all literal, coalesced into one .text node"
    )
}
do {
    let input = String(repeating: "[", count: 6) + "]"
    check(
        MarkdownInlineParser.parse(input) == [.text(input)],
        "family 3: `[`×6 + \"]\" -> the `]` exists but no `(` follows it, still all literal"
    )
}
do {
    let input = String(repeating: "[", count: 6) + "]("
    check(
        MarkdownInlineParser.parse(input) == [.text(input)],
        "family 3: `[`×6 + \"](\" -> `]` and `(` exist but no `)` follows, still all literal"
    )
}
do {
    let input = "[a](b)" + String(repeating: "[", count: 5)
    check(
        MarkdownInlineParser.parse(input) == [.link(text: "a", url: "b"), .text(String(repeating: "[", count: 5))],
        "a real link followed by trailing unmatched brackets: link parses, trailing `[`s stay literal"
    )
}
check(
    MarkdownInlineParser.parse("[[x](y)") == [.link(text: "[x", url: "y")],
    "nearest-`]` semantics: a `[` inside the title is literal title content, not a nested opener"
)
check(
    MarkdownInlineParser.parse("[[[[[x](y)") == [.link(text: "[[[[x", url: "y")],
    "nearest-`]` semantics holds with 5 leading brackets: title absorbs the extra 4 `[`"
)
check(
    MarkdownInlineParser.parse("`[a](b)`") == [.code("[a](b)")],
    "code span precedence: a link shape inside backticks never reaches parseLink"
)
check(
    MarkdownInlineParser.parse("**[[[**") == [.bold([.text("[[[")])],
    "bold body with unmatched brackets: the per-invocation memo is rebuilt correctly on the recursive slice"
)

// MARK: - (preview-bold-spans): indented list-item continuation
//
// Cause 1 of that item. A wrapped list item's second line used to match none of the classification
// steps and fall through to paragraph continuation, so it started a NEW block — which split any
// `**…**` span across two blocks, left an unpaired `**` in each, and turned the orphaned closer into
// an opener that bolded a long arbitrary run further down the document.
//
// The continuation rule is deliberately NOT CommonMark's lazy one. It requires the line to be
// indented AND its trimmed form to start no block of its own; criteria 4-6 below are the regression
// guards for exactly those two reversals, and criterion 5 is the one that protects `SPEC.md:68-70`'s
// indented sub-bullets from being swallowed into their parent bullet.

section("(preview-bold-spans) criterion 1: the reported three-line wrapped list item")
do {
    // The reporter's source verbatim (`plans/preview-bold-repro.md`). Written as an array join
    // rather than a `"""` literal so the two-space indents that make lines 1-2 continuations are
    // impossible to misread and cannot be silently re-indented by a formatter.
    let source = [
        "- [ ] (snapshot-solve-merge) **[hi · TRIGGERED — do not schedule until it",
        "  fires]** The structural half of `(solve-blocks-main-actor)` (shipped",
        "  2026-08-21). Direction: snapshot-solve-merge, not a finer lock.",
    ].joined(separator: "\n")
    let expectedText = "[ ] (snapshot-solve-merge) **[hi · TRIGGERED — do not schedule until it fires]** The structural half of `(solve-blocks-main-actor)` (shipped 2026-08-21). Direction: snapshot-solve-merge, not a finer lock."

    let blocks = MarkdownBlockParser.parse(source)
    check(blocks.count == 1, "the reported three-line source parses to exactly ONE block (was 1 item + 2 paragraphs)")
    var itemText = ""
    if case let .listItem(marker, text, line)? = blocks.first {
        itemText = text
        check(marker == "•" && line == 0, "that block is a `•` list item anchored at source line 0")
    } else {
        check(false, "that block is a `•` list item anchored at source line 0")
    }
    check(itemText == expectedText, "its text joins all three lines: indents stripped, single-spaced, `(shipped 2026-08-21)` not double-spaced")
    check(itemText.contains("fires]**"), "its text carries `fires]**` — the closer that used to be stranded in the next block")

    // The whole point of the item: with the span no longer split, the `**…**` pairs with its own
    // closer. Asserted as a tree so "and nothing after it is bold" is pinned structurally, not by a
    // spot check — a stray `.bold` anywhere after would change this array.
    check(
        MarkdownInlineParser.parse(itemText) == [
            .text("[ ] (snapshot-solve-merge) "),
            .bold([.text("[hi · TRIGGERED — do not schedule until it fires]")]),
            .text(" The structural half of "),
            .code("(solve-blocks-main-actor)"),
            .text(" (shipped 2026-08-21). Direction: snapshot-solve-merge, not a finer lock."),
        ],
        "the rejoined item inline-parses to exactly one bold span over `[hi · … fires]`, nothing after it bold"
    )

    // ...and the same claim at the RENDER level, where the bug was actually visible. The bold face
    // is `PreviewFont.bodyBold` (private), so it is identified by "not `Theme.bodyFont`, and carries
    // the .bold trait"; asking for the LONGEST effective range is what makes this fail if the bold
    // run were one character longer or shorter than the intended span.
    let (output, _) = MarkdownRenderer.render(source)
    let rendered = output.string as NSString
    let boldRange = rendered.range(of: "[hi · TRIGGERED — do not schedule until it fires]")
    check(boldRange.location != NSNotFound, "the rendered output contains the span, with its `**` delimiters consumed")
    if boldRange.location != NSNotFound {
        var effective = NSRange(location: 0, length: 0)
        let font = output.attribute(
            .font,
            at: boldRange.location,
            longestEffectiveRange: &effective,
            in: NSRange(location: 0, length: output.length)
        ) as? NSFont
        check(font != nil && font != Theme.bodyFont, "the span renders in a face other than the plain body font")
        check(font?.fontDescriptor.symbolicTraits.contains(.bold) == true, "that face carries the .bold symbolic trait")
        check(effective == boldRange, "the bold run covers EXACTLY the span — not one character more or less")
        let after = boldRange.location + boldRange.length
        check(after < output.length, "there is rendered text after the span (so the next check is not vacuous)")
        check(
            attribute(output, .font, at: after) as? NSFont == Theme.bodyFont,
            "the text immediately after the span is plain body font — the wrong-run bolding is gone"
        )
    }
}

section("(preview-bold-spans) criteria 2-3, 9: the joining rule")
check(
    MarkdownBlockParser.parse("- a\n  b") == [.listItem(marker: "•", text: "a b", line: 0)],
    "\"- a\\n  b\" -> ONE list item \"a b\" at line 0 (the continuation's indent is stripped)"
)
check(
    MarkdownBlockParser.parse("- a \n  b") == [.listItem(marker: "•", text: "a b", line: 0)],
    "\"- a \\n  b\" -> \"a b\", not \"a  b\" — segments are trimmed before joining"
)
check(
    MarkdownBlockParser.parse("- a ") == [.listItem(marker: "•", text: "a ", line: 0)],
    "\"- a \" with NO continuation keeps its trailing space verbatim — a single-line item is never re-joined"
)
check(
    MarkdownBlockParser.parse("- \n  foo") == [.listItem(marker: "•", text: "foo", line: 0)],
    "\"- \\n  foo\" -> \"foo\", not \" foo\" — empty segments are dropped, not joined"
)
check(
    MarkdownBlockParser.parse("- a\n  b\n  c") == [.listItem(marker: "•", text: "a b c", line: 0)],
    "three-line wrap joins into one item (the join is not limited to a single continuation)"
)
check(
    MarkdownBlockParser.parse("3. a\n  b") == [.listItem(marker: "3.", text: "a b", line: 0)],
    "an ORDERED item continues too, keeping its rendered marker"
)
check(
    MarkdownBlockParser.parse("- a\n\tb") == [.listItem(marker: "•", text: "a b", line: 0)],
    "a TAB-indented continuation counts as indented"
)

section("(preview-bold-spans) criterion 4: unindented lines are NOT continuations")
check(
    MarkdownBlockParser.parse("- a\nb") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "b", line: 1),
    ],
    "\"- a\\nb\" stays item + paragraph — CommonMark's LAZY continuation is deliberately NOT adopted"
)

section("(preview-bold-spans) criteria 5-6: an indented block starter is not a continuation")
check(
    MarkdownBlockParser.parse("- a\n  - b") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "  - b", line: 1),
    ],
    "\"- a\\n  - b\" -> item + paragraph, byte-identical to before this item — the SPEC.md:68-70 guard"
)
check(
    MarkdownBlockParser.parse("- a\n  ```") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "  ```", line: 1),
    ],
    "an indented fence open is not a continuation (unchanged: an indented ``` is still paragraph text)"
)
check(
    MarkdownBlockParser.parse("- a\n  # h") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "  # h", line: 1),
    ],
    "an indented ATX heading is not a continuation"
)
check(
    MarkdownBlockParser.parse("- a\n  > q") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "  > q", line: 1),
    ],
    "an indented blockquote marker is not a continuation"
)
check(
    MarkdownBlockParser.parse("- a\n  ---") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "  ---", line: 1),
    ],
    "an indented horizontal rule is not a continuation"
)
check(
    MarkdownBlockParser.parse("- a\n  1. b") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "  1. b", line: 1),
    ],
    "an indented ORDERED sub-item is not a continuation either"
)
do {
    // The `SPEC.md:68-70` shape itself: one bullet with two indented sub-bullets. The two sub-bullet
    // lines land in step 9 and merge into ONE space-joined paragraph — that is the PRE-EXISTING
    // paragraph behaviour, unchanged here by design, and it is why the expected value is two blocks
    // and not three. What this guard pins is that the parent item's text is `**Parent:**` and
    // nothing more: under CommonMark lazy continuation both children would instead have been
    // swallowed into it as one run-on line with literal `-` separators.
    let source = "- **Parent:**\n  - **Child one:** text.\n  - **Child two:** text."
    check(
        MarkdownBlockParser.parse(source) == [
            .listItem(marker: "•", text: "**Parent:**", line: 0),
            .paragraph(text: "  - **Child one:** text.   - **Child two:** text.", line: 1),
        ],
        "the SPEC.md:68-70 nested-bullet shape parses exactly as before: the parent item keeps only its own text"
    )
}

// MARK: - (preview-bold-spans, adv-review-behavior finding 1) MARKER-ONLY block starters
//
// The criteria 5-6 cases above all use marker-PLUS-CONTENT lines (`  - b`, `  1. b`, `  # h`), and
// that gap shipped a real defect past the first implementation: `isListItemContinuation` trimmed
// BOTH ends before asking `startsBlock`, but `parseListItem` and `parseHeading` each require a
// space or tab AFTER the marker — so the trailing trim destroyed the exact character they test for.
// `"  - "` became `"-"`, failed `parseListItem`'s `count >= 2` guard, reported "starts no block",
// and was absorbed into the parent item: `- Parent\n  - \n  - Child` rendered as `Parent -`.
//
// These pin the marker-only forms specifically. `>` and rules and fences are deliberately included
// too, as controls: they were never affected (a `>` needs no following character, `isRule` strips
// its own trailing whitespace, `isFenceOpen` only counts leading backticks), so if a future change
// to the trimming breaks THEM, that shows up here as well.
section("(preview-bold-spans, review finding 1) a marker-only indented line is not a continuation")
do {
    // Every one of these, placed under an open `- parent`, must TERMINATE the item rather than be
    // swallowed into it — i.e. the parse must contain more than one block, and the parent item's
    // text must remain exactly "parent".
    let markerOnly = [
        "  - ", "  * ", "  + ",           // unordered markers, no content
        "  1. ", "  1) ", "  12. ",       // ordered markers, no content
        "  # ", "  ## ", "  ###### ",     // ATX headings, no content
        "\t- ", "   \t- ",                // tab indentation, and mixed space+tab
    ]
    var swallowed: [String] = []
    for line in markerOnly {
        let blocks = MarkdownBlockParser.parse("- parent\n" + line)
        // Swallowed shows up two ways: one block instead of several, or a parent whose text grew.
        let parentText: String? = {
            if case let .listItem(_, text, _) = blocks[0] { return text }
            return nil
        }()
        if blocks.count < 2 || parentText != "parent" { swallowed.append(line.debugDescription) }
    }
    check(
        swallowed.isEmpty,
        "all \(markerOnly.count) marker-only indented lines terminate the parent item (swallowed: \(swallowed))"
    )

    // The concrete case from the review, asserted whole rather than by property.
    check(
        MarkdownBlockParser.parse("- Parent\n  - \n  - Child") == [
            .listItem(marker: "•", text: "Parent", line: 0),
            .paragraph(text: "  -    - Child", line: 1),
        ],
        "a nested list caught mid-edit (`- Parent`, `  - `, `  - Child`) keeps the parent's text intact"
    )

    // (adv-review-edge finding 1) UNICODE-INDENTED sub-bullets. The first fix for the marker-only
    // bug above stripped only space and tab, which introduced a NEW defect: `flushListItem` trims
    // each segment with `CharacterSet.whitespaces`, so a line indented with spaces and then a
    // NON-BREAKING space kept its NBSP here (reporting "starts no block", hence a continuation) and
    // then had the NBSP deleted by the flush — collapsing a sub-bullet into its parent as `"a - x"`.
    // Reachable by Option+Space on macOS and by any paste from a web page or Word. The stripper now
    // uses the same `CharacterSet.whitespaces` the flush does; these pin that the two agree.
    var unicodeSwallowed: [String] = []
    for scalar in [0x00A0, 0x1680, 0x2000, 0x2003, 0x2007, 0x200A, 0x200B, 0x202F, 0x205F, 0x3000] {
        let space = String(UnicodeScalar(scalar)!)
        let blocks = MarkdownBlockParser.parse("- a\n  \(space)- x")
        if blocks.count < 2 { unicodeSwallowed.append(String(format: "U+%04X", scalar)) }
    }
    check(
        unicodeSwallowed.isEmpty,
        "a sub-bullet indented with a Unicode space (NBSP et al) still terminates the parent (swallowed: \(unicodeSwallowed))"
    )

    // (adv-review-edge finding 3) A `|` row must not be absorbed either. This repo's own
    // `SPEC.md:122-128` is a six-row table indented under a bullet; absorbing it would turn text
    // that renders as an ugly-but-complete paragraph today into a run-on glued onto a list item.
    // `(preview-tables)` replaces this with real recognition; until then the parse must match HEAD.
    check(
        MarkdownBlockParser.parse("- Token classes:\n  | Class | Color |\n  |---|---|") == [
            .listItem(marker: "•", text: "Token classes:", line: 0),
            .paragraph(text: "  | Class | Color |   |---|---|", line: 1),
        ],
        "an indented pipe-table row is NOT absorbed into the bullet above it (SPEC.md:122-128's own shape)"
    )

    // Controls: the three forms that never needed a following character must still terminate.
    var controlFailures: [String] = []
    for line in ["  > q", "  ---", "  ```"] {
        let blocks = MarkdownBlockParser.parse("- parent\n" + line)
        if blocks.count < 2 { controlFailures.append(line.debugDescription) }
    }
    check(controlFailures.isEmpty, "control: `>`, rule and fence-open still terminate an open item (failed: \(controlFailures))")

    // And the counterpart that must NOT change: a marker-only line with no indentation was never a
    // continuation candidate at all (the test's first half rejects it before `startsBlock` is
    // consulted), so it stays exactly whatever it was before. Both forms are pinned because they
    // differ, and the difference is the same trailing space this whole section is about:
    // `"- "` satisfies `parseListItem` and IS a second list item with empty text, while a bare
    // `"-"` fails its `count >= 2` guard and falls through to paragraph. Probed, not assumed — my
    // first draft of this assertion guessed "paragraph" for both and was wrong about the first.
    check(
        MarkdownBlockParser.parse("- parent\n- ") == [
            .listItem(marker: "•", text: "parent", line: 0),
            .listItem(marker: "•", text: "", line: 1),
        ],
        "an UNINDENTED `- ` is a second (empty) list item, not a continuation"
    )
    check(
        MarkdownBlockParser.parse("- parent\n-") == [
            .listItem(marker: "•", text: "parent", line: 0),
            .paragraph(text: "-", line: 1),
        ],
        "an UNINDENTED bare `-` is a paragraph — no trailing space, so it is not a list item at all"
    )
}

section("(preview-bold-spans) criterion 7: six terminators for an open list item")
check(
    MarkdownBlockParser.parse("- a\n\nb") == [
        .listItem(marker: "•", text: "a", line: 0),
        .paragraph(text: "b", line: 2),
    ],
    "a blank line terminates an open list item"
)
check(
    MarkdownBlockParser.parse("- a\n# H") == [
        .listItem(marker: "•", text: "a", line: 0),
        .heading(level: 1, text: "H", line: 1),
    ],
    "a heading terminates an open list item"
)
check(
    MarkdownBlockParser.parse("- a\n---") == [
        .listItem(marker: "•", text: "a", line: 0),
        .rule(line: 1),
    ],
    "a rule terminates an open list item"
)
check(
    MarkdownBlockParser.parse("- a\n```\ncode\n```") == [
        .listItem(marker: "•", text: "a", line: 0),
        .codeBlock(code: "code", line: 1),
    ],
    "a fence terminates an open list item"
)
check(
    MarkdownBlockParser.parse("- a\n> q") == [
        .listItem(marker: "•", text: "a", line: 0),
        .blockquote(text: "q", line: 1),
    ],
    "a blockquote terminates an open list item"
)
check(
    MarkdownBlockParser.parse("- a\n- b") == [
        .listItem(marker: "•", text: "a", line: 0),
        .listItem(marker: "•", text: "b", line: 1),
    ],
    "a new list item terminates an open list item"
)

section("(preview-bold-spans) criterion 7: terminators emit in SOURCE ORDER")
do {
    // The silent failure mode the fourth accumulator introduces: because a list item now emits at
    // FLUSH time rather than inline, any terminator that forgets to flush it appends its own block
    // FIRST and the item second — `[.blockquote(line: 1), .listItem(line: 0)]`. That trips
    // `assertStrictlyAscending` in debug and, since `assert` compiles out, silently breaks §8.3
    // scroll sync in release. Asserting `.line` is ascending over every terminator is what makes a
    // missed `flushListItem()` fail loudly here instead.
    //
    // (adv-review-behavior finding 4) The first version of this section used exactly the six inputs
    // the six exact-array checks above already assert in full, including their `line` values — so it
    // could not fail unless one of those also failed, while its comment claimed to be THE guard for
    // the reordering failure mode. Two changes earn its place: the inputs below are ones the exact
    // checks do NOT cover (a CONTINUED item before each terminator, so the flush carries a joined
    // multi-line item, plus deeper prefixes), and it now goes through `MarkdownRenderer.render` to
    // check anchor `location` ordering as well — the half `assertStrictlyAscending` cares about and
    // the block-level checks never reach.
    let terminators = ["\n\nb", "\n# H", "\n---", "\n```\ncode\n```", "\n> q", "\n- b"]
    var ascending = true
    var anchorsAscending = true
    var offenders: [String] = []
    for terminator in terminators {
        // A CONTINUED item (two source lines joined) ahead of the terminator, preceded by a heading
        // so the item is not the first block — neither shape appears in the exact checks above.
        let source = "# Doc\n\n- a\n  cont" + terminator
        let blocks = MarkdownBlockParser.parse(source)
        if blocks.count > 2 {
            for index in 1..<blocks.count where !(blocks[index].line > blocks[index - 1].line) {
                ascending = false
                offenders.append(terminator.debugDescription)
            }
        } else {
            ascending = false
            offenders.append(terminator.debugDescription)
        }
        // The item must still be the one at line 2, carrying its joined text — proving the flush
        // emitted the WHOLE accumulated item and not a truncated one.
        if blocks.count > 1, case let .listItem(_, text, line) = blocks[1] {
            if text != "a cont" || line != 2 { ascending = false; offenders.append(terminator.debugDescription) }
        } else {
            ascending = false
            offenders.append(terminator.debugDescription)
        }
        // And the rendered anchors — `location` ordering is what §8.3 binary-searches.
        let (_, anchors) = MarkdownRenderer.render(source)
        if anchors.count > 1 {
            for index in 1..<anchors.count
            where !(anchors[index].sourceLine > anchors[index - 1].sourceLine)
                || !(anchors[index].location > anchors[index - 1].location) {
                anchorsAscending = false
                offenders.append(terminator.debugDescription)
            }
        }
    }
    check(ascending, "every terminator emits the pending (continued) list item BEFORE its own block, whole and in source order (offenders: \(Set(offenders).sorted()))")
    check(anchorsAscending, "and the rendered anchors stay strictly ascending in sourceLine AND location across all six")
}

section("(preview-bold-spans) criterion 8: a list item open at EOF")
check(
    MarkdownBlockParser.parse("# H\n\n- wrapped\n  tail") == [
        .heading(level: 1, text: "H", line: 0),
        .listItem(marker: "•", text: "wrapped tail", line: 2),
    ],
    "a document ENDING on a wrapped bullet flushes at EOF as one item (the commonest real case)"
)
check(
    MarkdownBlockParser.parse("- a\n  b\n") == [.listItem(marker: "•", text: "a b", line: 0)],
    "a trailing newline after a continuation still yields one item (the final empty line is blank, not a continuation)"
)

section("(preview-bold-spans) criterion 13: anchors over a wrapped item")
do {
    // Merging a continuation removes a block, and therefore an anchor. The comparison document is
    // the SAME source with one blank line inserted before the continuation — which breaks the merge
    // — so the expected difference is exactly one anchor. Written as a difference rather than an
    // absolute count so it cannot pass by coincidence with an unrelated block count.
    let wrapped = "# H\n\n- one **span\n  wrapped** tail\n\n- two"
    let split = "# H\n\n- one **span\n\n  wrapped** tail\n\n- two"
    let (_, wrappedAnchors) = MarkdownRenderer.render(wrapped)
    let (_, splitAnchors) = MarkdownRenderer.render(split)
    check(wrappedAnchors.count == splitAnchors.count - 1, "a wrapped item emits exactly ONE FEWER anchor than the same document with the wrap broken by a blank line")
    // (adv-review-behavior finding 5) Guard the count before forming the range: a regression that
    // emitted ZERO anchors would make `1..<0` TRAP with "Range requires lowerBound <= upperBound"
    // rather than report a FAIL, turning a real defect into a crashed harness that says nothing
    // about what broke. Asserting the count first also makes the emptiness itself a failure rather
    // than a vacuous pass.
    check(wrappedAnchors.count == 3, "sanity: the wrapped document emits 3 anchors before the ordering check reads them")
    var ascending = true
    if wrappedAnchors.count > 1 {
        for index in 1..<wrappedAnchors.count {
            if !(wrappedAnchors[index].sourceLine > wrappedAnchors[index - 1].sourceLine) { ascending = false }
            if !(wrappedAnchors[index].location > wrappedAnchors[index - 1].location) { ascending = false }
        }
    }
    check(ascending, "the wrapped document's anchors are strictly ascending in BOTH sourceLine and location")
    check(
        wrappedAnchors.map { $0.sourceLine } == [0, 2, 5],
        "the continuation line contributes no anchor of its own; §8.3 resolves it to its item's anchor at line 2"
    )
}

// MARK: - md-link-scan-quadratic: differential fuzz
//
// A harness-local reference reimplementing the PRE-FIX `MarkdownInlineParser`/`MarkdownRenderer`
// semantics (the naive to-EOF `firstIndex` link scan, unmemoized) diffs against the shipped,
// memoized parser/renderer over a seeded randomized battery of bracket-heavy inputs. This proves
// the memoization is byte-identical to the old algorithm on thousands of inputs the hand-enumerated
// battery above does not cover, catching an off-by-one the enumerated cases might miss.

/// The pre-fix `MarkdownInlineParser`, reimplemented standalone: identical code-span -> link ->
/// bold -> italic scan, but `parseLink`'s closer search is the naive two-to-EOF-scan version that
/// shipped before md-link-scan-quadratic (no memo arrays). This is the differential oracle.
enum ReferenceInlineParser {
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

        while index < count {
            let character = characters[index]

            if character == "`" {
                if let close = firstIndex(of: "`", in: characters, from: index + 1) {
                    flushLiteral()
                    nodes.append(.code(String(characters[(index + 1)..<close])))
                    index = close + 1
                    continue
                }
                literal.append(character)
                index += 1
                continue
            }

            if character == "[" {
                if let link = parseLink(characters, from: index) {
                    flushLiteral()
                    nodes.append(.link(text: link.title, url: link.url))
                    index = link.end
                    continue
                }
                literal.append(character)
                index += 1
                continue
            }

            if character == "*", index + 1 < count, characters[index + 1] == "*" {
                if let close = firstDoubleIndex(of: "*", in: characters, from: index + 2) {
                    flushLiteral()
                    nodes.append(.bold(parseNodes(Array(characters[(index + 2)..<close]))))
                    index = close + 2
                    continue
                }
                literal.append("*")
                literal.append("*")
                index += 2
                continue
            }

            if character == "*" {
                if let close = firstIndex(of: "*", in: characters, from: index + 1) {
                    flushLiteral()
                    nodes.append(.italic(parseNodes(Array(characters[(index + 1)..<close]))))
                    index = close + 1
                    continue
                }
                literal.append(character)
                index += 1
                continue
            }

            literal.append(character)
            index += 1
        }

        flushLiteral()
        return nodes
    }

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

    /// The pre-fix `parseLink`: two to-EOF `firstIndex` scans — exactly the quadratic behavior
    /// the fix removes, kept here unmemoized on purpose as the differential oracle.
    private static func parseLink(_ characters: [Character], from open: Int) -> (title: String, url: String, end: Int)? {
        guard let closeBracket = firstIndex(of: "]", in: characters, from: open + 1) else { return nil }
        let paren = closeBracket + 1
        guard paren < characters.count, characters[paren] == "(" else { return nil }
        guard let closeParen = firstIndex(of: ")", in: characters, from: paren + 1) else { return nil }
        let title = String(characters[(open + 1)..<closeBracket])
        let url = String(characters[(paren + 1)..<closeParen])
        return (title, url, closeParen + 1)
    }
}

/// Harness-local reference renderer: identical block parsing + Tier-3 emission logic to
/// `MarkdownRenderer.render` (block parsing is reused directly from the unmodified, production
/// `MarkdownBlockParser` since this fix never touches it), but inline nodes come from
/// `ReferenceInlineParser` (the naive pre-fix scan) instead of `MarkdownInlineParser`. Any
/// output/anchor divergence from `MarkdownRenderer.render` pinpoints a behavioral change in the
/// memoized `parseLink`.
enum ReferenceRenderer {
    private static let blockSpacing: CGFloat = 8
    private static let listItemSpacing: CGFloat = 3
    private static let listIndent: CGFloat = 22
    private static let quoteIndent: CGFloat = 16
    private static let ruleGlyphCount = 32

    private static let bodyParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        return style
    }()

    private static let headingParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        return style
    }()

    private static let codeParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        return style
    }()

    private static let listParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = listItemSpacing
        style.firstLineHeadIndent = 0
        style.headIndent = listIndent
        style.tabStops = [NSTextTab(textAlignment: .left, location: listIndent)]
        style.defaultTabInterval = listIndent
        return style
    }()

    private static let quoteParagraph: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = blockSpacing
        style.firstLineHeadIndent = quoteIndent
        style.headIndent = quoteIndent
        return style
    }()

    private static let ruleAttributes: [NSAttributedString.Key: Any] = [
        .font: Theme.bodyFont,
        .foregroundColor: Theme.mutedText,
        .paragraphStyle: bodyParagraph,
    ]

    private static let bodyBold: NSFont = {
        let descriptor = Theme.bodyFont.fontDescriptor.withSymbolicTraits(.bold)
        return NSFont(descriptor: descriptor, size: Theme.bodyFont.pointSize) ?? Theme.bodyFont
    }()

    private static let bodyItalic: NSFont = {
        let descriptor = Theme.bodyFont.fontDescriptor.withSymbolicTraits(.italic)
        let candidate = NSFont(descriptor: descriptor, size: Theme.bodyFont.pointSize) ?? Theme.bodyFont
        return candidate.fontDescriptor.symbolicTraits.contains(.italic) ? candidate : Theme.bodyFont
    }()

    private struct InlineStyle {
        let font: NSFont
        let boldFont: NSFont
        let italicFont: NSFont
        let color: NSColor
        let paragraphStyle: NSParagraphStyle
    }

    private static let bodyStyle = InlineStyle(
        font: Theme.bodyFont, boldFont: bodyBold, italicFont: bodyItalic,
        color: Theme.text, paragraphStyle: bodyParagraph
    )
    private static let listStyle = InlineStyle(
        font: Theme.bodyFont, boldFont: bodyBold, italicFont: bodyItalic,
        color: Theme.text, paragraphStyle: listParagraph
    )
    private static let quoteStyle = InlineStyle(
        font: Theme.bodyFont, boldFont: bodyBold, italicFont: bodyItalic,
        color: Theme.mutedText, paragraphStyle: quoteParagraph
    )

    private static func headingStyle(level: Int) -> InlineStyle {
        let font = Theme.headingFont(level: level)
        return InlineStyle(font: font, boldFont: font, italicFont: font, color: Theme.text, paragraphStyle: headingParagraph)
    }

    static func render(_ source: String) -> (output: NSAttributedString, anchors: [MarkdownAnchor]) {
        let blocks = MarkdownBlockParser.parse(source)
        let output = NSMutableAttributedString()
        var anchors: [MarkdownAnchor] = []

        for (index, block) in blocks.enumerated() {
            anchors.append(MarkdownAnchor(sourceLine: block.line, location: output.length))
            emit(block, into: output)
            if index < blocks.count - 1 {
                output.append(NSAttributedString(string: "\n"))
            }
        }

        return (output, anchors)
    }

    private static func emit(_ block: MarkdownBlock, into output: NSMutableAttributedString) {
        switch block {
        case let .heading(level, text, _):
            emitInline(ReferenceInlineParser.parse(text), style: headingStyle(level: level), into: output)

        case let .paragraph(text, _):
            emitInline(ReferenceInlineParser.parse(text), style: bodyStyle, into: output)

        case let .listItem(marker, text, _):
            output.append(NSAttributedString(string: marker + "\t", attributes: [
                .font: Theme.bodyFont,
                .foregroundColor: Theme.text,
                .paragraphStyle: listParagraph,
            ]))
            emitInline(ReferenceInlineParser.parse(text), style: listStyle, into: output)

        case let .blockquote(text, _):
            emitInline(ReferenceInlineParser.parse(text), style: quoteStyle, into: output)

        case let .codeBlock(code, _):
            output.append(NSAttributedString(string: code, attributes: [
                .font: Theme.codeFont,
                .foregroundColor: Theme.text,
                .backgroundColor: Theme.codeBackground,
                .paragraphStyle: codeParagraph,
            ]))

        case .rule:
            output.append(NSAttributedString(
                string: String(repeating: "─", count: ruleGlyphCount),
                attributes: ruleAttributes
            ))
        }
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
                    font: style.boldFont, boldFont: style.boldFont, italicFont: style.italicFont,
                    color: style.color, paragraphStyle: style.paragraphStyle
                )
                emitInline(children, style: boldStyle, into: output)

            case let .italic(children):
                let italicStyle = InlineStyle(
                    font: style.italicFont, boldFont: style.boldFont, italicFont: style.italicFont,
                    color: style.color, paragraphStyle: style.paragraphStyle
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

/// A tiny deterministic LCG (Numerical Recipes constants), seeded by a fixed constant so the fuzz
/// below is fully reproducible run to run (no `Date`/system-entropy seeding).
struct SeededLCG {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = 6_364_136_223_846_793_005 &* state &+ 1_442_695_040_888_963_407
        return state
    }

    /// (fuzz-rng-low-bits) **Reduce the HIGH bits, never the low ones.** This is the whole of that
    /// item, and the trap it fixes is silent and total rather than a matter of degree.
    ///
    /// A linear congruential generator with a power-of-two modulus — and `&*`/`&+` on `UInt64` is
    /// exactly modulus 2^64 — has a catastrophically short period in its low bits: bit *k* of the
    /// state has period at most 2^(k+1), because the low *k* bits of the recurrence depend only on
    /// the low *k* bits of the previous state. They form their own little LCG mod 2^k, sealed off
    /// from everything above them. So `next() % 8` — three low bits — cycles with period **8**, no
    /// matter how good the generator looks in aggregate.
    ///
    /// That is not hypothetical here. The differential fuzz below draws its characters with
    /// `nextInt(upperBound: alphabet.count)`, and the alphabet has exactly **8** entries. Measured
    /// against the shipped constants and seed `0x5EED_1234_ABCD_9876`, the old `next() % 8` emitted
    /// the index stream `[5, 0, 7, 2, 1, 4, 3, 6]` repeating forever, which collapsed the fuzz's
    /// nominal 5000 random inputs into **6 distinct strings** — every one of them a prefix or
    /// rotation of the same repeating sequence. The `md-link-scan-quadratic` differential oracle had
    /// therefore been proving roughly one input, not thousands, for its whole life. With the shift
    /// below the same 5000 draws produce **4740 distinct inputs**, which is what the fuzz always
    /// claimed to be doing. (Both numbers are measured, not estimated; the guard assertion in the
    /// fuzz section pins the property so a future reduction cannot quietly undo it.)
    ///
    /// `>> 33` keeps 31 bits — far more than the largest `upperBound` here (48) needs — and is the
    /// specific shift the item probe-confirmed. The modulo bias that remains (31 bits reduced by a
    /// non-power-of-two) is on the order of 2^-26 and is irrelevant for a test corpus.
    ///
    /// **Anything else that adds a fuzz to this file must call this, not `next() % n`.**
    mutating func nextInt(upperBound: Int) -> Int {
        Int((next() >> 33) % UInt64(upperBound))
    }
}

section("md-link-scan-quadratic: differential fuzz (seeded, vs naive nearest-firstIndex reference)")
do {
    let alphabet: [Character] = ["[", "]", "(", ")", "a", "*", "`", " "]
    var rng = SeededLCG(seed: 0x5EED_1234_ABCD_9876)
    let fuzzCount = 5000
    var treeMismatches = 0
    var renderMismatches = 0
    // (fuzz-rng-low-bits) The corpus itself is now under test. See the guard assertion below for
    // why a comment on `nextInt` was not enough.
    var distinctInputs = Set<String>()

    for _ in 0..<fuzzCount {
        let length = rng.nextInt(upperBound: 48)
        var chars: [Character] = []
        chars.reserveCapacity(length)
        for _ in 0..<length {
            chars.append(alphabet[rng.nextInt(upperBound: alphabet.count)])
        }
        let input = String(chars)
        distinctInputs.insert(input)

        let actualTree = MarkdownInlineParser.parse(input)
        let referenceTree = ReferenceInlineParser.parse(input)
        if actualTree != referenceTree {
            treeMismatches += 1
            print("  FUZZ TREE MISMATCH on \(input.debugDescription): actual=\(actualTree) reference=\(referenceTree)")
        }

        let actualRender = MarkdownRenderer.render(input)
        let referenceRender = ReferenceRenderer.render(input)
        if !actualRender.output.isEqual(to: referenceRender.output) || actualRender.anchors != referenceRender.anchors {
            renderMismatches += 1
            print("  FUZZ RENDER MISMATCH on \(input.debugDescription)")
        }
    }

    // (fuzz-rng-low-bits) **The corpus guard.** The two differential assertions below say nothing
    // about how many DISTINCT inputs they ran on, so before this existed they read as a 5000-case
    // sweep while actually proving 6 strings — the whole of that bug, and it was invisible precisely
    // because everything was green. A prose warning on `nextInt` cannot fail; this can.
    //
    // Threshold: 4000 of 5000. Measured today is 4740 (the remainder is genuine birthday-paradox
    // collision — short draws repeat, and `length == 0` alone recurs ~1/48 of the time), so the
    // floor sits comfortably below the real value while still being ~790x above the 6 the degenerate
    // low-bit reduction produced. Any future change to the reduction, the seed, the alphabet or the
    // length bound that collapses the corpus trips this instead of passing quietly.
    check(
        distinctInputs.count > 4_000,
        "\(fuzzCount) fuzz inputs are genuinely distinct (\(distinctInputs.count) unique) — the corpus is not degenerate"
    )
    check(
        treeMismatches == 0,
        "\(fuzzCount) seeded random bracket-heavy inputs: MarkdownInlineParser.parse matches the naive reference tree (0 mismatches)"
    )
    check(
        renderMismatches == 0,
        "\(fuzzCount) seeded random bracket-heavy inputs: MarkdownRenderer.render output+anchors match the reference renderer (0 mismatches)"
    )
}

// MARK: - (preview-bold-spans): emphasis character-preservation property fuzz
//
// An oracle with NO reference implementation behind it, and that is exactly the point. The
// differential fuzz above proves `MarkdownInlineParser` agrees with `ReferenceInlineParser`; the
// moment a change to the emphasis rule is mirrored into both — which it must be, since the reference
// exists to prove the link memoization is byte-identical and must never be weakened to stay green —
// that oracle goes green regardless of whether the new rule is right. This one cannot go green that
// way, because it checks the parser against a property of the INPUT:
//
//     flatten(parse(s)) with every `*` removed  ==  s with every `*` removed
//
// The emphasis scan may consume `*` characters as delimiters and may leave them behind as literal
// text, but it must never drop, duplicate or reorder anything else. The alphabet is `a`, `*` and
// space, so every draw is emphasis-only: no code spans, links or brackets dilute it.
//
// What this does NOT catch, stated plainly so nobody reads more into it than it proves: a tree that
// accounts for every `*` as a delimiter but renders none of them. For `"** bold**"` the tree
// `[.italic([]), .text(" bold"), .italic([])]` satisfies this property exactly — both sides reduce
// to `" bold"` — even though `emitInline` appends nothing for empty children, so all four asterisks
// would vanish from the rendered output. Only a hand-written expected tree for that specific input
// pins that failure mode; this fuzz is the guard for character loss, not for delimiter visibility.

section("(preview-bold-spans): emphasis character-preservation property fuzz")
do {
    let alphabet: [Character] = ["a", "*", " "]
    // A DIFFERENT seed from the differential fuzz above, deliberately. `SeededLCG` is fully
    // deterministic, so reusing 0x5EED_1234_ABCD_9876 would walk the identical state sequence and
    // this fuzz would draw its lengths and its character indices from the very same stream — adding
    // far less independent coverage than a second fuzz's name claims, even though the alphabet here
    // differs. The constant below is arbitrary except for being visibly not that one.
    var rng = SeededLCG(seed: 0xB01D_5EED_2026_0821)
    let fuzzCount = 5000
    var violations = 0
    // The same corpus guard the differential fuzz carries: "0 violations over 5000 inputs" is
    // satisfiable by a degenerate corpus, and a degenerate corpus is precisely the failure
    // (fuzz-rng-low-bits) found in the fuzz above. Without this the assertion below would be worth
    // whatever the RNG happened to be worth.
    var distinctInputs = Set<String>()

    for _ in 0..<fuzzCount {
        let length = rng.nextInt(upperBound: 48)
        var chars: [Character] = []
        chars.reserveCapacity(length)
        for _ in 0..<length {
            chars.append(alphabet[rng.nextInt(upperBound: alphabet.count)])
        }
        let input = String(chars)
        distinctInputs.insert(input)

        let flattened = flatten(MarkdownInlineParser.parse(input))
        if flattened.filter({ $0 != "*" }) != input.filter({ $0 != "*" }) {
            violations += 1
            print("  FUZZ PROPERTY VIOLATION on \(input.debugDescription): flattened to \(flattened.debugDescription)")
        }
    }

    // Threshold: 4000 of 5000, matching the differential fuzz's floor. Measured today is 4533 — a
    // little below that fuzz's 4740 because this alphabet has 3 entries rather than 8, so short
    // draws collide far more often (`length == 0` alone recurs ~1/48 of the time, and there are only
    // 3 one-character and 9 two-character strings to draw). The floor still sits well under the
    // measured value and hundreds of times above what a low-bit reduction would collapse this to.
    check(
        distinctInputs.count > 4_000,
        "\(fuzzCount) property-fuzz inputs are genuinely distinct (\(distinctInputs.count) unique) — the corpus is not degenerate"
    )
    check(
        violations == 0,
        "\(fuzzCount) seeded random emphasis-only inputs: parsing loses no non-delimiter character (0 violations)"
    )
}

// MARK: - md-link-scan-quadratic: no quadratic cliff (advisory)
//
// ADVISORY tripwire only (plan criterion 5): the ceiling below is deliberately loose (~100x margin
// over expected linear time) to avoid CI flakiness on slow/loaded machines. The real guarantee is
// the O(n) complexity argument in the plan's "Chosen algorithm & why" section, not this wall-clock
// number — a slow-but-still-linear run must never fail this check. Pre-fix, the first case alone
// took ~6s (quadratic); this ceiling sits between comfortably-linear and that cliff.

section("md-link-scan-quadratic: no quadratic cliff (advisory)")
func measureRender(_ label: String, ceiling: TimeInterval, _ source: String) {
    let start = Date()
    _ = MarkdownRenderer.render(source)
    let elapsed = Date().timeIntervalSince(start)
    print("  TIME: \(label) took \(elapsed)s (advisory ceiling \(ceiling)s)")
    check(elapsed < ceiling, "\(label) renders in under \(ceiling)s (advisory; got \(elapsed)s)")
}

measureRender("[×40000 (no ], family 1)", ceiling: 1.0, String(repeating: "[", count: 40_000))
measureRender("[a](b×10000 (no ), family 2)", ceiling: 1.0, String(repeating: "[a](b", count: 10_000))
measureRender("[×40000 + \"]\" (family 3)", ceiling: 1.0, String(repeating: "[", count: 40_000) + "]")

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
