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
// (preview-emphasis-commonmark) **CHANGED EXPECTED VALUE — 1 of exactly 3 in this file.** A run of
// four `*` with the start of the block on one side and the end on the other is neither left- nor
// right-flanking, so it can neither open nor close and stays literal. The old `.bold([])` was not
// just a different shape: `emitInline` appends nothing for empty children, so all four characters
// were DELETED from the rendered output. That loss is invisible on THIS input — `isRule` accepts
// three-or-more `*`, so a line of `****` is a horizontal rule and never reaches the inline parser
// (plan R7 corrects Rev 1 on exactly this) — which is why the embedded form is asserted separately
// below, where HEAD really did render `a****b` as `ab`.
check(MarkdownInlineParser.parse("****") == [.text("****")], "**** -> text(\"****\"): a run flanked by neither text nor punctuation can neither open nor close")
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

// MARK: - Criterion 13: Literality + delimiter-run pairing (four adversarial trees)
//
// (preview-emphasis-commonmark) This section used to be titled "closer-selection rule" and existed
// to pin the rule that item REVERSED: the closer was the nearest matching delimiter, chosen with no
// backtracking and no flanking test. Two of its four trees changed as a result, and each is
// justified inline. The other two are unchanged and are asserted here as regression guards for the
// new algorithm, not as leftovers — `**a*b**` in particular is the case where CommonMark's rule of
// three FORBIDS a pair, so ablating that rule trips it (plan R9).

section("Criterion 13: delimiter-run pairing (adversarial cases)")
check(
    MarkdownInlineParser.parse("**a*b**") == [.bold([.text("a*b")])],
    "**a*b** -> bold(\"a*b\") (lone inner * is literal)"
)
// (preview-emphasis-commonmark) **CHANGED EXPECTED VALUE — 2 of exactly 3.** The old rule made the
// nearest `**` the closer, which bolded a leading asterisk and stranded a literal `*` at the end.
// The delimiter stack matches the same pair of runs twice: two asterisks from each side build the
// strong node, then the one asterisk left on each side wraps it in emphasis. `<em><strong>x</strong>
// </em>` is what every other renderer produces.
check(
    MarkdownInlineParser.parse("***x***") == [.italic([.bold([.text("x")])])],
    "***x*** -> italic(bold(\"x\")): one run matched twice, 2 asterisks then 1"
)
check(
    MarkdownInlineParser.parse("**a**b**") == [.bold([.text("a")]), .text("b**")],
    "**a**b** -> bold(\"a\") + text(\"b**\") (final ** literal, coalesced with b)"
)
// (preview-emphasis-commonmark) **CHANGED EXPECTED VALUE — 3 of exactly 3, and the one this whole
// item was filed for.** Three sibling italics were *visually* near-correct by accident (adjacent
// italic runs look like one) but the tree was wrong, and no opener-only flanking rule could fix the
// stray-asterisk bug without wrecking it: the third italic opened at index 7, whose next character
// is a space, so "an opener may not be followed by whitespace" turns the tail into a literal
// `text("* c*")`. Only the full algorithm gives the nesting the construct actually means.
check(
    MarkdownInlineParser.parse("*a **b** c*")
        == [.italic([.text("a "), .bold([.text("b")]), .text(" c")])],
    "*a **b** c* -> italic(\"a \", bold(\"b\"), \" c\"): emphasis nests"
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

// MARK: - (preview-emphasis-commonmark): the delimiter-stack algorithm
//
// The item that replaced "nearest closer, no backtracking" with CommonMark 0.30's delimiter-run +
// delimiter-stack algorithm. The three trees it changed are asserted (and justified) in criteria 11
// and 13 above, next to the eight it did not change; everything below is new ground.
//
// Every expected tree here is HAND-WRITTEN from the spec's rules rather than captured from the
// implementation, because the two fuzz oracles at the bottom of this file are property-based: they
// prove no character is invented or lost, not that any particular pairing is the right one. Only
// these pin the pairing.

section("(preview-emphasis-commonmark) criteria 1-3: nesting, partial consumption, no character loss")
check(
    MarkdownInlineParser.parse("***x**") == [.text("*"), .bold([.text("x")])],
    "***x** -> text(\"*\") + bold(\"x\"): leftover OPENER asterisks emit BEFORE the node"
)
check(
    MarkdownInlineParser.parse("**x***") == [.bold([.text("x")]), .text("*")],
    "**x*** -> bold(\"x\") + text(\"*\"): leftover CLOSER asterisks emit AFTER the node"
)
check(
    MarkdownInlineParser.parse("*(*foo*)*") == [.italic([.text("("), .italic([.text("foo")]), .text(")")])],
    "*(*foo*)* -> em(\"(\", em(\"foo\"), \")\"): emphasis nests inside emphasis"
)
check(
    MarkdownInlineParser.parse("**foo*bar*baz**")
        == [.bold([.text("foo"), .italic([.text("bar")]), .text("baz")])],
    "**foo*bar*baz** -> strong containing an em: the inner pair does not steal the outer closer"
)
// (plan R7) The character loss the `****` assertion above cannot show, because a whole line of `*`
// is a horizontal rule. Embedded, HEAD rendered this as "ab" — `emitInline` appends nothing for
// `.bold([])`'s children, so four source characters vanished from the preview.
check(
    MarkdownRenderer.render("a****b").output.string == "a****b",
    "render(\"a****b\") keeps all six characters (HEAD rendered \"ab\" — four deleted)"
)

section("(preview-emphasis-commonmark) criterion 7: the rule of three")
// CommonMark rule 9/10: when either run can both open and close, a pair is forbidden if the sum of
// the two runs' ORIGINAL lengths is a multiple of 3, unless both lengths are multiples of 3.
check(
    MarkdownInlineParser.parse("*foo**bar**baz*")
        == [.italic([.text("foo"), .bold([.text("bar")]), .text("baz")])],
    "*foo**bar**baz* -> em(\"foo\", strong(\"bar\"), \"baz\") — without the rule of three this mis-nests"
)
// The case where the rule FORBIDS a pair, with its expected tree. In `**a*b**` the inner `*` (a run
// of 1, both-flanking because it sits between two letters) is a potential closer for the opening
// `**`; 1 + 2 = 3 and neither length is a multiple of 3, so the pair is refused and the `*` stays
// literal. Ablating the rule of three turns this into `italic([italic("a"), text("b")]), text("*")`
// — i.e. it fails loudly on an assertion this file already had (plan R9).
check(
    MarkdownInlineParser.parse("**a*b**") == [.bold([.text("a*b")])],
    "rule of three FORBIDS the 1+2 pair in **a*b**, so the inner * is literal (tree pinned twice, on purpose)"
)
check(
    MarkdownInlineParser.parse("*foo**bar***") == [.italic([.text("foo"), .bold([.text("bar")])])],
    "*foo**bar*** -> em(\"foo\", strong(\"bar\")): the closing run of 3 pairs with 2 then 1 (sums 5 and 4, neither a multiple of 3)"
)
check(
    MarkdownInlineParser.parse("***foo**bar*") == [.italic([.bold([.text("foo")]), .text("bar")])],
    "***foo**bar* -> em(strong(\"foo\"), \"bar\")"
)
// Opener and closer must be different runs — this falls out of starting the backward scan at
// `closer.previous`, but a self-pairing run would silently produce `bold([])` and delete three
// characters, so it is pinned (plan R8).
check(
    MarkdownInlineParser.parse("a***b") == [.text("a***b")],
    "a***b -> literal: a single run cannot be its own opener and closer"
)

section("(preview-emphasis-commonmark) criterion 8: flanking uses CommonMark's character classes")
// (plan R5) Every input here DISCRIMINATES: it gives a different tree under Foundation's
// `CharacterSet.punctuationCharacters` / `CharacterSet.whitespaces` than under the sets CommonMark
// 0.30 actually defines. Rev 1's proposed cases (NBSP, em-dash, CJK, emoji) all pass on the wrong
// implementation, so they could not fail: NBSP is whitespace and an em-dash is Pd under both
// notions, and neither a CJK ideograph nor an emoji is either. Those three are kept below as
// controls; the emoji is repurposed as a pin on the spec VERSION, where it does discriminate.
//
// Nine ASCII characters are CommonMark punctuation but are NOT in Unicode's P* categories (they are
// Sc/Sk/Sm), so `CharacterSet.punctuationCharacters` misses all nine. With them misclassified, the
// opening `**` here counts as "not followed by punctuation", becomes left-flanking, and bolds the
// symbol.
for symbol in ["$", "+", "<", "=", ">", "^", "`", "|", "~"] {
    // A backtick would start a code span, so it is spelled as an unclosed one: `x**`**y` has a
    // single backtick, which the tokenizer leaves literal, and the flanking question is unchanged.
    let input = "x**\(symbol)**y"
    let expected: [InlineNode] = [.text(input)]
    check(
        MarkdownInlineParser.parse(input) == expected,
        "x**\(symbol)**y stays literal — `\(symbol)` IS CommonMark punctuation (CharacterSet.punctuationCharacters misses it)"
    )
}
check(
    MarkdownInlineParser.parse("x**\u{000C}**y") == [.text("x**\u{000C}**y")],
    "FF (U+000C) IS CommonMark whitespace, so `**` before it cannot open — CharacterSet.whitespaces omits FF"
)
check(
    MarkdownInlineParser.parse("x**\u{200B}**y") == [.text("x"), .bold([.text("\u{200B}")]), .text("y")],
    "ZWSP (U+200B) is NOT CommonMark whitespace, so `**` before it CAN open — CharacterSet.whitespaces contains ZWSP"
)
check(
    MarkdownInlineParser.parse("x**\u{00A0}**y") == [.text("x**\u{00A0}**y")],
    "control: NBSP is Zs, so it IS whitespace on both notions and the run stays literal"
)
check(
    MarkdownInlineParser.parse("x**\u{2014}**y") == [.text("x**\u{2014}**y")],
    "control: an em-dash is Pd, punctuation on both notions, so the run stays literal"
)
check(
    MarkdownInlineParser.parse("x**\u{4E2D}**y") == [.text("x"), .bold([.text("\u{4E2D}")]), .text("y")],
    "control: a CJK ideograph is Lo — neither whitespace nor punctuation — so the run bolds"
)
// **This one pins the spec VERSION.** CommonMark 0.30 counts only P* plus ASCII punctuation, so an
// emoji (So) is neither, the opening `**` is left-flanking, and this bolds. CommonMark 0.31.2 folds
// the Symbol categories into "Unicode punctuation", which would make it literal instead. If this
// assertion ever flips, the parser has silently moved to a different spec revision.
check(
    MarkdownInlineParser.parse("x**\u{1F642}**y") == [.text("x"), .bold([.text("\u{1F642}")]), .text("y")],
    "CommonMark 0.30: an emoji is NOT punctuation, so x**🙂**y bolds (0.31.2 would leave it literal)"
)

section("(preview-emphasis-commonmark) criteria 5-6: the (preview-bold-spans) cause-2 report cases")
// All five inputs from `plans/preview-bold-repro.md` cause 2, with the trees they produce now. The
// mechanism is uniform: a `*` with whitespace on both sides is neither left- nor right-flanking, so
// it can neither open nor close and never joins the delimiter list at all.
check(
    MarkdownInlineParser.parse("2 * 3 and **bold** here")
        == [.text("2 * 3 and "), .bold([.text("bold")]), .text(" here")],
    "report case 1: `2 * 3 and **bold** here` — the stray * is literal and \"bold\" is BOLD, not italic"
)
// The UNSPACED stray, which (preview-bold-spans) recorded as unreachable by its opener-only rule.
// Here `*` sits between two digits, so it is both left- and right-flanking and CAN open and close —
// it fails to match anyway, because the `**` before "bold" is preceded by a space (cannot close) and
// the one after is followed by a space (cannot open), so the only pair available is those two.
check(
    MarkdownInlineParser.parse("2*3 and **bold** here")
        == [.text("2*3 and "), .bold([.text("bold")]), .text(" here")],
    "report case 2: `2*3 and **bold** here` — the UNSPACED stray, unreachable by any opener-only rule"
)
check(
    MarkdownInlineParser.parse("see footnote * and **bold**")
        == [.text("see footnote * and "), .bold([.text("bold")])],
    "report case 3: `see footnote * and **bold**`"
)
check(
    MarkdownInlineParser.parse("a ** b and **bold** c")
        == [.text("a ** b and "), .bold([.text("bold")]), .text(" c")],
    "report case 4: `a ** b and **bold** c` — the space-flanked ** run is inert, so the right run bolds"
)
check(
    MarkdownInlineParser.parse("5 * 4 = 20, 6 * 7 = 42, **bold**")
        == [.text("5 * 4 = 20, 6 * 7 = 42, "), .bold([.text("bold")])],
    "report case 5: `5 * 4 = 20, 6 * 7 = 42, **bold**` — an even count no longer re-syncs by luck"
)
do {
    // The sixth case, and the only one that exercises the block-level line merge: the stray `*` is
    // on a DIFFERENT LINE from the emphasis, and paragraph lines merge with a space before the
    // inline parser ever runs. Rev 1 of the plan counted four report cases; there are five plus this
    // one (plan R11).
    let source = "Rate is 5 * 4 per unit\nand the result is **very important**."
    let blocks = MarkdownBlockParser.parse(source)
    var text = ""
    if case let .paragraph(value, _)? = blocks.first { text = value }
    check(blocks.count == 1 && text == "Rate is 5 * 4 per unit and the result is **very important**.", "report case 6 merges to one paragraph before inline parsing")
    check(
        MarkdownInlineParser.parse(text)
            == [.text("Rate is 5 * 4 per unit and the result is "), .bold([.text("very important")]), .text(".")],
        "report case 6: a stray * on the PREVIOUS LINE no longer re-pairs the paragraph's emphasis"
    )
}
// The repro's "working baseline (must not regress)" list, verbatim. Nothing asserted these before.
check(
    MarkdownInlineParser.parse("**bold** alone") == [.bold([.text("bold")]), .text(" alone")],
    "baseline: `**bold** alone` unchanged"
)
check(
    MarkdownInlineParser.parse("**a * b** tail") == [.bold([.text("a * b")]), .text(" tail")],
    "baseline: `**a * b** tail` unchanged — and its body is ONE coalesced text node across the inert run"
)
check(
    MarkdownInlineParser.parse("*italic* and **bold**")
        == [.italic([.text("italic")]), .text(" and "), .bold([.text("bold")])],
    "baseline: `*italic* and **bold**` unchanged"
)
// Two more shapes the item's TODO entry called out by name, both now literal. The first is the
// mutant tree that motivated this item's oracles (`[.italic([]), .text(" bold"), .italic([])]` would
// delete four asterisks and satisfy a flatten-and-strip property exactly); the second is the case an
// opener-only rule provably could NOT fix, because nothing there rejects a closer preceded by
// whitespace.
check(
    MarkdownInlineParser.parse("** bold**") == [.text("** bold**")],
    "`** bold**` is literal: the opener is followed by whitespace, and no empty emphasis is produced"
)
check(
    MarkdownInlineParser.parse("**bold **") == [.text("**bold **")],
    "`**bold **` is literal: the CLOSER is preceded by whitespace (an opener-only rule left this bold)"
)


section("(preview-emphasis-commonmark, review) the rule of three's OTHER half: original lengths")
// **The four assertions above pin only half the rule, and a reviewer proved it by building the
// mutant.** Evaluating the rule of three on `remaining` instead of `originalLength` — exactly the
// mistake plan R6 exists to prevent — leaves `*foo**bar**baz*`, `**a*b**` and `***x***` all
// UNCHANGED, and the whole hand-written battery green; only the differential fuzz notices, and only
// because `ReferenceInlineParser` kept the correct field. Verified here by compiling that mutant
// against this working tree before writing these three lines.
//
// These are inputs where a run is matched twice, so `remaining` and `originalLength` differ at the
// moment the second match is judged: in `*a***a*` the middle run is 3 long, gives 1 asterisk to the
// opening `*`, and is then judged against the closing `*` with 2 left. Original lengths 3 + 1 = 4,
// not a multiple of 3, so the pair is allowed; the mutant sees 2 + 1 = 3 and refuses it, stranding
// `**a*` as literal text.
check(
    MarkdownInlineParser.parse("*a***a*")
        == [.italic([.text("a")]), .text("*"), .italic([.text("a")])],
    "*a***a* -> em(a) + \"*\" + em(a): the rule of three judges ORIGINAL run lengths, not what is left"
)
check(
    MarkdownInlineParser.parse("*aa***a*")
        == [.italic([.text("aa")]), .text("*"), .italic([.text("a")])],
    "*aa***a* -> em(aa) + \"*\" + em(a) (the mutant gives em(aa) + text(\"**a*\"))"
)
check(
    MarkdownInlineParser.parse("**a***a**")
        == [.bold([.text("a")]), .italic([.text("a")]), .text("*")],
    "**a***a** -> strong(a) + em(a) + \"*\": same discriminator with the strong/em roles swapped"
)

// MARK: - (preview-emphasis-commonmark, review) the emphasis nesting cap
//
// The delimiter stack made emphasis depth unbounded and linear in input length, and every consumer
// of the tree recurses once per level. On `MarkdownPreviewView`'s `.utility` render queue — 512 KB
// of stack, not the main thread's 8 MB — that was a **1,881-character document that killed the
// app** (measured: depth 465 renders, depth 470 SIGBUSes), and it was reachable from ordinary
// prose. `MarkdownInlineParser.emphasisNestingLimit` bounds it; these pin the bound.

/// Deepest chain of `.bold`/`.italic` ancestors in a tree.
func treeDepth(_ nodes: [InlineNode]) -> Int {
    var deepest = 0
    for node in nodes {
        switch node {
        case let .bold(children), let .italic(children):
            deepest = max(deepest, 1 + treeDepth(children))
        case .text, .code, .link:
            continue
        }
    }
    return deepest
}

section("(preview-emphasis-commonmark, review) emphasis nesting is capped, and nothing is lost")
do {
    // Every input here is computed FROM the constant, so changing the constant cannot leave a stale
    // hard-coded number passing. `"*"x2d + "x" + "*"x2d` nests exactly d deep while d is allowed:
    // two runs, matched over and over, two asterisks from each side per level.
    let limit = MarkdownInlineParser.emphasisNestingLimit
    func nested(_ depth: Int) -> String {
        String(repeating: "*", count: 2 * depth) + "x" + String(repeating: "*", count: 2 * depth)
    }

    check(
        treeDepth(MarkdownInlineParser.parse(nested(limit - 1))) == limit - 1,
        "one level below the cap nests fully (\(limit - 1) deep)"
    )
    check(
        treeDepth(MarkdownInlineParser.parse(nested(limit))) == limit,
        "at the cap it still nests fully (\(limit) deep) — the limit is inclusive"
    )
    check(
        treeDepth(MarkdownInlineParser.parse(nested(limit + 1))) == limit,
        "one level past the cap stops at \(limit): pair number \(limit + 1) refuses to form"
    )
    check(
        treeDepth(MarkdownInlineParser.parse(nested(4 * limit))) == limit,
        "and it stays at \(limit) however deep the input goes (\(4 * limit) levels of input)"
    )
    // The refused delimiters are LITERAL, not dropped — the cap must not become a second way to
    // delete characters, which is the failure mode this whole item exists to remove. Two asterisks
    // per side survive at `limit + 1`, and 6 * limit per side at 4 * limit.
    let leftoverOne = String(repeating: "*", count: 2)
    check(
        MarkdownRenderer.render(nested(limit + 1)).output.string == leftoverOne + "x" + leftoverOne,
        "the refused pair renders as literal asterisks: \"**x**\""
    )
    let leftoverMany = String(repeating: "*", count: 2 * (4 * limit) - 2 * limit)
    check(
        MarkdownRenderer.render(nested(4 * limit)).output.string == leftoverMany + "x" + leftoverMany,
        "…and so does every pair past the cap (\(leftoverMany.count) literal asterisks per side)"
    )
}

section("(preview-emphasis-commonmark, review) the reported crash: 13 KB of ordinary prose")
do {
    // The shape that makes this urgent rather than theoretical. Neither line looks like nested
    // emphasis, and neither is; paragraph lines MERGE with a space before the inline parser runs, so
    // 500 unmatched openers meet 500 unmatched closers inside ONE block and nest ~500 deep.
    let limit = MarkdownInlineParser.emphasisNestingLimit
    let prose = (Array(repeating: "see *note", count: 500)
        + Array(repeating: "then note* here", count: 500)).joined(separator: "\n")
    check(prose.count == 12_999, "the reproducer is 12,999 characters of plain-looking prose")
    check(MarkdownBlockParser.parse(prose).count == 1, "…which merges into exactly ONE paragraph block")
    check(
        treeDepth(MarkdownInlineParser.parse(prose)) == limit,
        "…whose emphasis nests to the cap (\(limit)) instead of ~500 deep"
    )

    // **On a real background queue**, because that is where the crash lived: the main thread's 8 MB
    // stack survives to ~8,000 levels, so a main-thread render passes even with the defect present.
    // This is the same 512 KB-stack path `MarkdownPreviewView.renderQueue` uses.
    //
    // Mutation-checked rather than assumed: deleting the cap's two lines from `processEmphasis` and
    // running this harness gives **five FAILs — the four depth/leftover checks above and the depth
    // check below — and then exit 138, SIGBUS, right here**, killing the run. Both halves matter.
    // The assertions name the defect; this line is what proves the fix is real, because a stack
    // overflow cannot be caught and reported, only survived.
    let queue = DispatchQueue(label: "FEdit.MarkdownPreview.render.test", qos: .utility)
    let semaphore = DispatchSemaphore(value: 0)
    var renderedLength = 0
    queue.async {
        renderedLength = MarkdownRenderer.render(prose).output.length
        semaphore.signal()
    }
    semaphore.wait()
    check(
        renderedLength == prose.count - 2 * limit,
        "…and renders on a .utility queue worker, keeping every character but the \(2 * limit) consumed delimiters"
    )
}

// MARK: - (preview-emphasis-commonmark, review) rendered FONT TRAITS, not just trees
//
// Every other assertion in this file checks the tree. That is exactly what hid a real defect:
// `*a **b** c*` produced the right tree while `emitInline` rendered `b` in plain `.SFNS-Bold`,
// dropping the outer italic, because the old `InlineStyle` replaced the face at each level instead
// of composing traits. `***x***` rendered bold-only for the same reason. These go through
// `MarkdownRenderer.render` and read the `.font` attribute that ships.

/// Symbolic traits of the font on the first character of `substring` in the rendered output of
/// `source`, or `nil` if the substring is not in the output at all (which is itself a failure worth
/// reporting rather than trapping on).
func renderedTraits(_ source: String, _ substring: String) -> NSFontDescriptor.SymbolicTraits? {
    let output = MarkdownRenderer.render(source).output
    let range = (output.string as NSString).range(of: substring)
    guard range.location != NSNotFound else { return nil }
    guard let font = output.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont else { return nil }
    return font.fontDescriptor.symbolicTraits
}

section("(preview-emphasis-commonmark, review) nested emphasis composes bold + italic")
check(
    renderedTraits("*a **b** c*", "b") == [.bold, .italic],
    "*a **b** c*: the bold inside the italic renders BOLD+ITALIC (it rendered plain bold, losing the italic)"
)
check(
    renderedTraits("*a **b** c*", "a ")?.contains(.italic) == true
        && renderedTraits("*a **b** c*", "a ")?.contains(.bold) == false,
    "…and the italic either side of it is italic and NOT bold"
)
check(
    renderedTraits("**a *b* c**", "b") == [.bold, .italic],
    "**a *b* c**: the mirror direction composes too (italic inside bold)"
)
check(
    renderedTraits("***x***", "x") == [.bold, .italic],
    "***x***: em(strong(x)) renders bold+italic (it rendered bold only)"
)
check(
    renderedTraits("*(*foo*)*", "foo")?.contains(.italic) == true,
    "*(*foo*)*: em inside em stays italic"
)
// Regression guards for the un-nested cases, which must not have moved.
check(
    renderedTraits("**b**", "b")?.contains(.bold) == true && renderedTraits("**b**", "b")?.contains(.italic) == false,
    "**b** is still bold and not italic"
)
check(
    renderedTraits("*i*", "i")?.contains(.italic) == true && renderedTraits("*i*", "i")?.contains(.bold) == false,
    "*i* is still italic and not bold"
)
check(
    renderedTraits("plain text", "plain") == [],
    "plain text still carries no emphasis traits"
)

section("(preview-emphasis-commonmark) plan R1: code spans and links now scope over the whole block")
// **An intended behaviour change, not a regression.** The old parser recursed into the emphasis
// BODY SLICE, so a backtick's or bracket's closer search was truncated at the emphasis boundary.
// Phase 1 resolves both over the whole block, before any emphasis pairing, so a code span or link
// may now span what used to be an emphasis delimiter. Verified against markdown-it; hand-written
// here because the differential fuzz shares the implementation and cannot see it.
check(
    MarkdownInlineParser.parse("*a`b* c`d") == [.text("*a"), .code("b* c"), .text("d")],
    "R1: *a`b* c`d -> code span across the `*` (was italic(\"a`b\") + text(\" c`d\"))"
)
check(
    MarkdownInlineParser.parse("*a [b* c](d)") == [.text("*a "), .link(text: "b* c", url: "d")],
    "R1: *a [b* c](d) -> a REAL link (was italic(\"a [b\") + text(\" c](d)\")) — text that was plain is now clickable"
)
check(
    MarkdownRenderer.render("*a [b* c](d)").output.attribute(.link, at: 3, effectiveRange: nil) is URL,
    "R1: …and the emitter attaches a live .link attribute to it, since URL(string: \"d\") is non-nil"
)
// **How big is this change, measured rather than characterized.** Over 20,000 bracket-heavy inputs
// (the differential fuzz's own alphabet and generator, run against HEAD and against this tree out of
// tree): **7,342 (36.7%) produce a different inline tree, 3,226 (16.1%) change what is inside a code
// span, 238 (1.19%) gain at least one `.link` node, and 70 (0.35%) lose one.** Both link directions
// are real; the gain is the interesting one, because it turns text that rendered as plain characters
// into something clickable.
//
// A property that follows from it, recorded so it is known rather than discovered: `emitInline`
// attaches `.link` for **anything `URL(string:)` parses**, which includes `javascript:` and `file:`
// destinations. That is pre-existing for genuine `[a](b)` links and is not changed here — but this
// item enlarges the set of source text that becomes a link, so it enlarges that exposure too.
// Filtering schemes is a separate decision and a separate item; this comment is the handoff.
check(
    MarkdownInlineParser.parse("*a `c b*") == [.italic([.text("a `c b")])],
    "R1 control: *a `c b* is UNCHANGED — an unclosed backtick is literal at block scope too"
)

section("(preview-emphasis-commonmark) plan R11: the text each block type hands the inline parser")
// **What these five pin, stated honestly, because an earlier wording overclaimed it.** Each one
// takes a block's text out of `MarkdownBlockParser` and inline-parses it directly; none of them goes
// through `MarkdownRenderer.render`, so none of them would notice if `emit` stopped calling the
// inline parser for that block type at all. They pin the PARSE, on the exact string each block type
// produces — which is worth pinning, because that string differs per block type (a heading strips
// its `#`, a list item its marker, a blockquote its `>`, a table cell its pipes and padding, and a
// paragraph merges lines) and each one is a distinct opportunity to hand emphasis something it
// cannot pair.
//
// The section below this one is the half that was missing: the same five constructs through
// `render`, checking the attributes that actually ship. That gap is not hypothetical — it is what
// let the composed-font defect through review.
do {
    let blocks = MarkdownBlockParser.parse("## *heading **b** c*")
    var text = ""
    if case let .heading(_, value, _)? = blocks.first { text = value }
    check(
        MarkdownInlineParser.parse(text) == [.italic([.text("heading "), .bold([.text("b")]), .text(" c")])],
        "heading: `## *heading **b** c*` hands the parser `*heading **b** c*`, which nests"
    )
}
do {
    let blocks = MarkdownBlockParser.parse("- *item **b** c*")
    var text = ""
    if case let .listItem(_, value, _)? = blocks.first { text = value }
    check(
        MarkdownInlineParser.parse(text) == [.italic([.text("item "), .bold([.text("b")]), .text(" c")])],
        "list item: the marker is stripped before the parser sees the text, and the rest nests"
    )
}
do {
    let blocks = MarkdownBlockParser.parse("> *quoted **b** c*")
    var text = ""
    if case let .blockquote(value, _)? = blocks.first { text = value }
    check(
        MarkdownInlineParser.parse(text) == [.italic([.text("quoted "), .bold([.text("b")]), .text(" c")])],
        "blockquote: `> ` is stripped before the parser sees the text, and the rest nests"
    )
}
do {
    // The paragraph case is the one that MERGES lines, so the emphasis here spans a line break in the
    // source and only exists at all because the block parser joined them with a space.
    let blocks = MarkdownBlockParser.parse("para *a **b**\nc* tail")
    var text = ""
    if case let .paragraph(value, _)? = blocks.first { text = value }
    check(
        MarkdownInlineParser.parse(text)
            == [.text("para "), .italic([.text("a "), .bold([.text("b")]), .text(" c")]), .text(" tail")],
        "paragraph: two source lines merge into one block, and the emphasis pairs across the join"
    )
}
do {
    // Table cells are inline-parsed too ((preview-tables)), so the change reaches them.
    let blocks = MarkdownBlockParser.parse("| h |\n| --- |\n| *cell **b** c* |")
    var cell = ""
    if case let .table(_, rows, _, _)? = blocks.first, let first = rows.first?.first { cell = first }
    check(
        MarkdownInlineParser.parse(cell) == [.italic([.text("cell "), .bold([.text("b")]), .text(" c")])],
        "table cell: pipes and padding are stripped before the parser sees the text, and the rest nests"
    )
    // `splitTableCells` documents a hard dependency on this parser's backtick pairing (1-2, 3-4, …,
    // final odd one literal). The rewrite keeps that rule and now applies it in ONE pass over the
    // whole block instead of restarting inside each emphasis body, so the split and the render agree
    // strictly more often than before, never less (plan R11).
    let spanned = MarkdownBlockParser.parse("| h |\n| --- |\n| `a | b` and *c* |")
    var spannedCells: [String] = []
    if case let .table(_, rows, _, _)? = spanned.first, let first = rows.first { spannedCells = first }
    check(
        spannedCells == ["`a | b` and *c*"],
        "a pipe inside a backtick pair still does not split a cell, and the cell's emphasis still parses"
    )
    check(
        MarkdownInlineParser.parse(spannedCells.first ?? "")
            == [.code("a | b"), .text(" and "), .italic([.text("c")])],
        "…and that cell inline-parses to code(\"a | b\") + em(\"c\")"
    )
}

section("(preview-emphasis-commonmark, review) …and the same five constructs through render")
// The missing half. Each of these renders the whole document and checks the shipped attributes: the
// delimiters are gone from the output, and the nested run carries BOTH traits. A heading is the
// exception and is asserted as such — `headingStyle` passes the heading face for all four slots, so
// nesting is deliberately invisible there, which is precisely why the tree-level check above exists.
do {
    let (heading, _) = MarkdownRenderer.render("## *heading **b** c*")
    check(heading.string == "heading b c", "heading: renders with every delimiter consumed")
    let headingFont = attribute(heading, .font, at: 0) as? NSFont
    let nestedFont = attribute(heading, .font, at: (heading.string as NSString).range(of: "b").location) as? NSFont
    check(
        headingFont != nil && headingFont == nestedFont && headingFont == Theme.headingFont(level: 2),
        "heading: the nested bold keeps the level-2 heading face — nesting is invisible here BY DESIGN"
    )
}
check(
    MarkdownRenderer.render("- *item **b** c*").output.string == "•\titem b c",
    "list item: renders through the marker with every delimiter consumed"
)
check(
    renderedTraits("- *item **b** c*", "b") == [.bold, .italic],
    "list item: …and the nested run composes bold+italic in list style"
)
check(
    MarkdownRenderer.render("> *quoted **b** c*").output.string == "quoted b c",
    "blockquote: renders with every delimiter consumed"
)
check(
    renderedTraits("> *quoted **b** c*", "b") == [.bold, .italic],
    "blockquote: …and the nested run composes bold+italic in quote style"
)
check(
    renderedTraits("para *a **b**\nc* tail", "b") == [.bold, .italic],
    "paragraph: …and it composes across the line merge too"
)
do {
    let (table, _) = MarkdownRenderer.render("| h |\n| --- |\n| *cell **b** c* |")
    check(
        renderedTraits("| h |\n| --- |\n| *cell **b** c* |", "b") == [.bold, .italic],
        "table cell: the nested run composes bold+italic inside the grid"
    )
    let cellRange = (table.string as NSString).range(of: "cell ")
    check(
        cellRange.location != NSNotFound
            && (attribute(table, .paragraphStyle, at: cellRange.location) as? NSParagraphStyle)?
                .textBlocks.first is NSTextTableBlock,
        "…and the emphasized run is still inside the table's grid (its paragraph style keeps the cell block)"
    )
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
    // `SPEC.md:123-128` is a six-row table indented under a bullet; absorbing it would turn text
    // into a run-on glued onto a list item.
    //
    // **(preview-tables) CHANGED THIS EXPECTED VALUE, and it is the only pre-existing assertion in
    // this file that it changed.** Before that item the second block was
    // `.paragraph(text: "  | Class | Color |   |---|---|", line: 1)` — HEAD's ugly-but-complete
    // rendering. Now the two indented lines are a header row plus a qualifying delimiter row, so
    // step 7.5 (which runs AHEAD of the list-item continuation branch) consumes them as a real
    // `.table`. That is the plan's explicitly recorded interaction between the two items, and the
    // better outcome. What has NOT changed, and is what this assertion still guards, is the parent
    // bullet: its text is `"Token classes:"` and nothing more — the pipe lines are a separate block
    // either way, never absorbed into the item.
    check(
        MarkdownBlockParser.parse("- Token classes:\n  | Class | Color |\n  |---|---|") == [
            .listItem(marker: "•", text: "Token classes:", line: 0),
            .table(header: ["Class", "Color"], rows: [], alignments: [.leading, .leading], line: 1),
        ],
        "an indented QUALIFYING pipe table under a bullet becomes a .table, not part of the bullet (SPEC.md:123-128's own shape)"
    )
    // …and the non-qualifying half, which is what keeps `startsBlock`'s `|` clause alive. With no
    // delimiter row under it the pipe line is not a table, and it must still land in its own
    // paragraph rather than being swallowed by the bullet. Deleting that clause turns this into
    // ONE list item reading "a | b | c |".
    check(
        MarkdownBlockParser.parse("- a\n  | b | c |") == [
            .listItem(marker: "•", text: "a", line: 0),
            .paragraph(text: "  | b | c |", line: 1),
        ],
        "an indented NON-qualifying pipe line (no delimiter row) is still not absorbed into the bullet — byte-identical to HEAD"
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

// MARK: - (preview-tables): GFM pipe tables
//
// A `|…|` row used to match none of the classification steps and fall through to paragraph
// continuation, so an entire table — plus any prose touching it — collapsed into ONE space-joined
// paragraph and even the source's line structure was lost. `MarkdownBlock` now has a `.table` case,
// recognized at step 7.5 (after the list item, ahead of the list-item continuation) and rendered as
// a real `NSTextTable` grid.
//
// Four of the checks below exist because the obvious implementation is subtly broken in ways that
// were caught only by review, and each is a regression guard for a specific defect: the delimiter
// row must itself contain a `|` (or a horizontal rule silently vanishes); a long row's surplus is
// re-joined, never truncated (truncating deleted 65 of 69 cells from a real line in this repo);
// `alignments` is normalized to the header's column count (or the emitter indexes out of range and
// TRAPS on the background render queue); and cells split on `|` outside backtick pairs (or
// `` `a | b` `` shreds).

/// Every table cell in `string`, recovered the way the plan's criterion 7 specifies — by iterating
/// `.paragraphStyle` runs and reading the `NSTextTableBlock` each one carries. One cell is one
/// paragraph (its content plus a `\n` sharing the same style object), and two cells' styles are
/// never equal because their `textBlocks` hold distinct objects, so the runs land exactly one per
/// cell in document order. Paragraphs with no text block — ordinary body/heading/list text, and the
/// separator `\n` `render` puts between blocks — are skipped, which is also what makes "the
/// delimiter row produces no cell" observable.
func tableCells(_ string: NSAttributedString) -> [(row: Int, column: Int, range: NSRange, style: NSParagraphStyle)] {
    var cells: [(row: Int, column: Int, range: NSRange, style: NSParagraphStyle)] = []
    string.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: string.length)) { value, range, _ in
        guard let style = value as? NSParagraphStyle,
              let block = style.textBlocks.first as? NSTextTableBlock else { return }
        cells.append((block.startingRow, block.startingColumn, range, style))
    }
    return cells
}

section("(preview-tables) criteria 1-2: the reporter's exact seven-line source")
do {
    // `plans/preview-tables-repro.md:8-14`, verbatim. Written as an array join rather than a `"""`
    // literal so the ragged interior spacing — which is the whole point of the report — cannot be
    // silently reflowed by a formatter. Header: 6 pipes -> 5 cells. Last row: 5 pipes -> 4 cells.
    let source = [
        "| skill #100 | skill #99     |   skill #98 | skill #75 | skill #50 |",
        "| ---------- | ------------- | ----------- | --------- | --------- |",
        "| gama radar | 99luftbaloons | pickpocket  | railgun   |cheeky     |",
        "|shoot gases | float away &  | steal a     | explosion | cheeky    |",
        "|that KILL   | ESCAPE!!!     | ROLE!!!     | EXPLODE   | ALL items in |",
        "|taggers!!!  |               |             | the map!!!| all roles!!! |",
        "|20,000$     |   17,500$     |  10,000$    |  16,450$       17,450$ |",
    ].joined(separator: "\n")

    let blocks = MarkdownBlockParser.parse(source)
    check(blocks.count == 1, "the reported seven-line source parses to exactly ONE block (was one run-on paragraph)")
    check(
        blocks == [.table(
            header: ["skill #100", "skill #99", "skill #98", "skill #75", "skill #50"],
            rows: [
                ["gama radar", "99luftbaloons", "pickpocket", "railgun", "cheeky"],
                ["shoot gases", "float away &", "steal a", "explosion", "cheeky"],
                ["that KILL", "ESCAPE!!!", "ROLE!!!", "EXPLODE", "ALL items in"],
                ["taggers!!!", "", "", "the map!!!", "all roles!!!"],
                // Criterion 2: the ragged last row's 4 cells PADDED to 5 — the fifth is empty, and
                // `16,450$       17,450$` (the two amounts that share a cell in the source) stays
                // one cell with its interior spacing intact rather than being split or dropped.
                ["20,000$", "17,500$", "10,000$", "16,450$       17,450$", ""],
            ],
            alignments: [.leading, .leading, .leading, .leading, .leading],
            line: 0
        )],
        "it is one 5-column .table at line 0 whose delimiter row is consumed and whose ragged last row is padded to 5 cells"
    )

    // Criterion 2's second half, asserted separately so a trap could not hide behind the tree
    // comparison: rendering the ragged source must not trap. (`emitTableRow` indexes `alignments`
    // per column; an un-normalized delimiter row is exactly how that goes out of range.)
    let (output, anchors) = MarkdownRenderer.render(source)
    check(output.length > 0 && anchors.count == 1, "the ragged source renders (no trap) and emits exactly one anchor")
    // Guarded before indexing, deliberately: a regression that emitted zero anchors would TRAP on
    // `anchors[0]` and a trapped harness reports nothing about what broke (the standard
    // adv-review-behavior finding 5 set for this file).
    check(
        anchors == [MarkdownAnchor(sourceLine: 0, location: 0)],
        "that anchor sits at the HEADER row's source line, not the delimiter's or a body row's"
    )
    check(tableCells(output).count == 6 * 5, "it renders 6 rows x 5 columns = 30 cells (header + 5 body rows; the delimiter row contributes none)")
}

section("(preview-tables) criterion 3: a long row keeps every character")
do {
    // The real `plans/syntax-highlighting.plan.md:52`, verbatim. **The plan's criterion 3 describes
    // this line as "69 cells against a 4-column header", which was measured under revision 1's RAW
    // pipe split.** Revision 2 splits outside backtick pairs, and this line's 68 interior pipes are
    // all inside the backticked regex — so it yields exactly FOUR cells and never reaches the
    // surplus path at all. The criterion's actual requirement (the keyword list survives into the
    // preview intact) is what is asserted, against the exact cell text.
    let row = "| 2 | keyword | `\\b(?:associatedtype|class|deinit|enum|extension|fileprivate|func|import|init|inout|internal|let|open|operator|private|protocol|public|static|struct|subscript|typealias|var|break|case|continue|default|defer|do|else|fallthrough|for|guard|if|in|repeat|return|switch|where|while|as|any|catch|is|nil|rethrows|self|Self|some|super|throw|throws|true|false|try|async|await|actor|lazy|weak|unowned|mutating|override|final|required|convenience|indirect)\\b` | `.foregroundColor: Theme.keyword`, `.font: Theme.editorBoldFont` |"
    let pattern = "`\\b(?:associatedtype|class|deinit|enum|extension|fileprivate|func|import|init|inout|internal|let|open|operator|private|protocol|public|static|struct|subscript|typealias|var|break|case|continue|default|defer|do|else|fallthrough|for|guard|if|in|repeat|return|switch|where|while|as|any|catch|is|nil|rethrows|self|Self|some|super|throw|throws|true|false|try|async|await|actor|lazy|weak|unowned|mutating|override|final|required|convenience|indirect)\\b`"
    check(row.filter { $0 == "|" }.count == 70, "sanity: the real repo line really does carry 70 pipes")

    let blocks = MarkdownBlockParser.parse("| # | Class | Pattern | Attributes |\n|---|---|---|---|\n" + row)
    var patternCell = ""
    var cellCount = 0
    // Every index below is guarded by the count that precedes it, so a regression FAILs here
    // instead of trapping the whole harness.
    if case let .table(_, rows, _, _)? = blocks.first, let first = rows.first {
        cellCount = first.count
        if cellCount > 2 { patternCell = first[2] }
    }
    check(cellCount == 4, "the backtick rule keeps it at 4 cells (NOT the 69 a raw split produces) — got \(cellCount)")
    check(patternCell == pattern, "its Pattern cell is the complete backticked regex, byte for byte — the whole Swift keyword list survives")

    // And the surplus path itself, which the line above no longer exercises. Same row with its
    // backticks stripped: now the 68 interior pipes DO split, the row is far longer than the
    // 4-column header, and the surplus must be re-joined into the last cell. Revision 1 truncated
    // here and deleted 65 of 69 cells.
    let unbackticked = row.filter { $0 != "`" }
    let strippedBlocks = MarkdownBlockParser.parse("| # | Class | Pattern | Attributes |\n|---|---|---|---|\n" + unbackticked)
    var wideRow: [String] = []
    if case let .table(_, rows, _, _)? = strippedBlocks.first, let first = rows.first { wideRow = first }
    check(wideRow.count == 4, "the de-backticked 69-segment row is fitted to the header's 4 columns (got \(wideRow.count))")
    // The exact no-loss property, and it is not a spot check: re-joining the produced cells with
    // `|` reproduces the source row's interior character-for-character once whitespace (the only
    // thing trimming removes) is discounted. Truncation fails this by thousands of characters.
    let inner = String(unbackticked.dropFirst().dropLast())
    check(
        wideRow.joined(separator: "|").filter { !$0.isWhitespace } == inner.filter { !$0.isWhitespace },
        "NOTHING is deleted: the fitted cells re-join to the source row's interior exactly, modulo trimmed whitespace"
    )
    check(
        wideRow.last?.contains("convenience|indirect)\\b") == true,
        "the tail of the keyword list is present in the LAST cell (the surplus was re-joined, not dropped)"
    )

    // The small, readable form of the same rule.
    check(
        MarkdownBlockParser.parse("| a | b |\n| --- | --- |\n| p | q | r | s |") == [.table(
            header: ["a", "b"],
            rows: [["p", "q | r | s"]],
            alignments: [.leading, .leading],
            line: 0
        )],
        "a 4-cell row against a 2-column header: cells 2-4 re-join into the last cell with their `|` separators restored"
    )
    check(
        MarkdownBlockParser.parse("| a | b | c |\n| --- | --- | --- |\n| p |") == [.table(
            header: ["a", "b", "c"],
            rows: [["p", "", ""]],
            alignments: [.leading, .leading, .leading],
            line: 0
        )],
        "a 1-cell row against a 3-column header is padded with empty cells"
    )
}

section("(preview-tables) criteria 4, 10-11, 18: delimiter row, alignment, optional pipes, degenerate shapes")
check(
    MarkdownBlockParser.parse("| a | b | c |\n| --- |") == [.table(
        header: ["a", "b", "c"],
        rows: [],
        alignments: [.leading, .leading, .leading],
        line: 0
    )],
    "criterion 4: a SHORT delimiter row is padded to the header's column count (an un-normalized one indexes out of range and traps)"
)
do {
    // The trap the normalization prevents is in the EMITTER, not the parser, so the parse check
    // above is only half of criterion 4. This renders it.
    let (output, _) = MarkdownRenderer.render("| a | b | c |\n| --- |\n| x | y | z |")
    check(tableCells(output).count == 6, "criterion 4: and it RENDERS — 2 rows x 3 columns of cells, no out-of-range trap")
}
check(
    MarkdownBlockParser.parse("| a |\n| :--- | ---: | :---: |") == [.table(
        header: ["a"],
        rows: [],
        alignments: [.leading],
        line: 0
    )],
    "a LONG delimiter row is truncated to the header's column count (an alignment is not document text, so dropping one loses nothing)"
)
check(
    MarkdownBlockParser.parse("| l | c | r |\n| :--- | :---: | ---: |") == [.table(
        header: ["l", "c", "r"],
        rows: [],
        alignments: [.leading, .center, .trailing],
        line: 0
    )],
    "criterion 10: `:---` / `:---:` / `---:` parse to leading / center / trailing"
)
do {
    let (output, _) = MarkdownRenderer.render("| l | c | r |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |")
    let cells = tableCells(output)
    check(cells.count == 6, "criterion 10: the aligned table renders 6 cells")
    check(
        cells.map { $0.style.alignment } == [.left, .center, .right, .left, .center, .right],
        "criterion 10: every cell's paragraph style carries .left / .center / .right, body rows included — got \(cells.map { $0.style.alignment.rawValue })"
    )
}
do {
    // Criterion 11: leading/trailing pipes are optional. Asserted as EQUALITY of the two parses
    // rather than by writing the expected tree twice, so the two forms cannot drift apart.
    let bare = MarkdownBlockParser.parse("a | b\n--- | ---\nx | y")
    let piped = MarkdownBlockParser.parse("| a | b |\n| --- | --- |\n| x | y |")
    check(bare == piped, "criterion 11: `a | b` + `--- | ---` gives the IDENTICAL table to the fully-piped form")
    check(
        bare == [.table(header: ["a", "b"], rows: [["x", "y"]], alignments: [.leading, .leading], line: 0)],
        "criterion 11: …and that table is the expected 2-column one (so the equality above is not two identical failures)"
    )
}
check(
    MarkdownBlockParser.parse("| only |\n| --- |\n| one |") == [.table(
        header: ["only"],
        rows: [["one"]],
        alignments: [.leading],
        line: 0
    )],
    "criterion 18: a ONE-column table works"
)
do {
    let (output, _) = MarkdownRenderer.render("| a | b |\n| --- | --- |\n| x |  |")
    let cells = tableCells(output)
    check(cells.count == 4, "criterion 18: a row with an EMPTY cell still renders 4 cells — the empty one is a cell, not a missing column")
    check(
        cells.map { [$0.row, $0.column] } == [[0, 0], [0, 1], [1, 0], [1, 1]],
        "criterion 18: and the empty cell occupies (1,1) — the grid does not collapse"
    )
    check(
        cells.count == 4 && cells[3].range.length == 1,
        "criterion 18: the empty cell is exactly its paragraph terminator (length 1), which is what keeps it addressable"
    )
}

section("(preview-tables) criterion 5: the bare-`---` guard")
do {
    // THE critical one. Without the "a delimiter row must itself contain a `|`" clause, `---`
    // strips to the single cell `["---"]`, matches `-+`, qualifies — and the horizontal rule
    // SILENTLY DISAPPEARS into a one-column table. (The plan called that header "a shredded code
    // span"; that was Rev 1's raw-pipe splitter. Under the shipped backtick-aware `splitTableCells`
    // the span survives intact and there is exactly one cell — measured against a guard-removed
    // mutant. The disappearing rule, which is the point, is unaffected.) The same shape swallows
    // YAML front matter. This parse must be byte-identical to what HEAD produced.
    let source = "Use the `a | b` syntax.\n---\nNext section."
    check(
        MarkdownBlockParser.parse(source) == [
            .paragraph(text: "Use the `a | b` syntax.", line: 0),
            .rule(line: 1),
            .paragraph(text: "Next section.", line: 2),
        ],
        "criterion 5: pipe-bearing prose + `---` + prose stays paragraph / RULE / paragraph — the rule does not vanish"
    )
    let (output, anchors) = MarkdownRenderer.render(source)
    check(anchors.map { $0.sourceLine } == [0, 1, 2], "criterion 5: three anchors, one per line — unchanged from HEAD")
    check(tableCells(output).isEmpty, "criterion 5: NOTHING in that document renders as a table cell")
    check(
        (output.string as NSString).contains(String(repeating: "─", count: 32)),
        "criterion 5: the rule's 32 glyphs are still in the rendered output"
    )
    // The YAML front-matter shape the same defect swallowed.
    check(
        MarkdownBlockParser.parse("---\ntitle: A | B\n---\nbody") == [
            .rule(line: 0),
            .paragraph(text: "title: A | B", line: 1),
            .rule(line: 2),
            .paragraph(text: "body", line: 3),
        ],
        "criterion 5: YAML front matter (`---` / `title: A | B` / `---`) keeps BOTH rules"
    )
}

section("(preview-tables) criterion 6: a pipe inside backticks does not split a cell")
check(
    MarkdownBlockParser.parse("| `a | b` | c |\n| --- | --- |") == [.table(
        header: ["`a | b`", "c"],
        rows: [],
        alignments: [.leading, .leading],
        line: 0
    )],
    "criterion 6: `` `a | b` `` is ONE cell — the code span is not shredded"
)
do {
    let (output, _) = MarkdownRenderer.render("| x | y |\n| --- | --- |\n| `a | b` | c |")
    let cells = tableCells(output)
    check(cells.count == 4, "criterion 6: the backticked cell renders as one cell (4 total, not 5)")
    check(
        (output.string as NSString).range(of: "a | b").location != NSNotFound,
        "criterion 6: the span's text survives with its interior pipe"
    )
    if cells.count == 4 {
        check(
            attribute(output, .font, at: cells[2].range.location) as? NSFont == Theme.codeFont,
            "criterion 6: and it renders as a real code span (codeFont), so the split agrees with MarkdownInlineParser"
        )
    }
}
// The counterpart that keeps the splitter honest with `MarkdownInlineParser`: an UNCLOSED backtick
// is literal to that parser, so it must not protect the rest of the row here either — or the split
// and the render disagree about where a code span is.
//
// **The unclosed backtick must come BEFORE a pipe for this to discriminate**, and getting that
// wrong is how the first version of this assertion shipped vacuous: `| a | b\` c |` puts the lone
// backtick AFTER the only interior pipe, so a naive `insideCodeSpan.toggle()` on every backtick
// splits it identically and the mutant passes (measured: it did). `| a\` b | c |` puts the backtick
// first, so the naive toggle protects the pipe and yields ONE cell where the correct rule yields
// two. Both forms are kept, the discriminating one first.
check(
    MarkdownBlockParser.parse("| a` b | c |\n| --- | --- |") == [.table(
        header: ["a` b", "c"],
        rows: [],
        alignments: [.leading, .leading],
        line: 0
    )],
    "criterion 6: an UNCLOSED backtick AHEAD of a pipe protects nothing — the row still splits into 2 cells"
)
check(
    MarkdownBlockParser.parse("| a | b` c |\n| --- | --- |") == [.table(
        header: ["a", "b` c"],
        rows: [],
        alignments: [.leading, .leading],
        line: 0
    )],
    "criterion 6: a trailing unclosed backtick is ordinary cell text"
)
check(
    // …and the splitter's answer matches `MarkdownInlineParser`'s, which is the actual invariant:
    // the parser treats the unpaired backtick as literal, so the cell it renders is exactly the
    // cell the splitter produced.
    MarkdownInlineParser.parse("a` b") == [.text("a` b")],
    "criterion 6: MarkdownInlineParser agrees — an unpaired backtick is literal text, not a code span"
)

section("(preview-tables) criteria 7-9: the rendered grid")
do {
    // Criterion 7: a 3x3 grid — header + delimiter + two body rows — must expose exactly nine
    // `NSTextTableBlock`s at the expected coordinates, IN ORDER.
    let (output, _) = MarkdownRenderer.render("| a | b | c |\n| --- | --- | --- |\n| d | e | f |\n| g | h | i |")
    let cells = tableCells(output)
    check(cells.count == 9, "criterion 7: a 3x3 table exposes exactly 9 table blocks (got \(cells.count))")
    check(
        cells.map { [$0.row, $0.column] } == [
            [0, 0], [0, 1], [0, 2],
            [1, 0], [1, 1], [1, 2],
            [2, 0], [2, 1], [2, 2],
        ],
        "criterion 7: their (startingRow, startingColumn) are row-major and in document order"
    )
    check(
        cells.allSatisfy { $0.style.textBlocks.count == 1 },
        "criterion 7: each cell paragraph carries exactly ONE text block (no leaked nesting)"
    )
    check(
        Set(cells.compactMap { ($0.style.textBlocks.first as? NSTextTableBlock)?.table }.map { ObjectIdentifier($0) }).count == 1,
        "criterion 7: all nine blocks belong to the SAME NSTextTable instance"
    )

    // Criterion 9: nine cells for a FOUR-line source is already the proof that the delimiter row
    // rendered nothing; this makes it explicit against the output text.
    check(
        !(output.string as NSString).contains("---"),
        "criterion 9: the delimiter row's `---` glyphs appear nowhere in the rendered output"
    )

    // Criterion 8: the header row is bold and body rows are not. Every slice below is behind the
    // `cells.count == 9` guard — a regression that produced fewer cells must FAIL here, not trap.
    if cells.count == 9 {
        let headerFont = attribute(output, .font, at: cells[0].range.location) as? NSFont
        check(headerFont != nil && headerFont != Theme.bodyFont, "criterion 8: a header cell renders in a face other than the plain body font")
        check(headerFont?.fontDescriptor.symbolicTraits.contains(.bold) == true, "criterion 8: that face carries the .bold symbolic trait")
        check(
            cells[0...2].allSatisfy { (attribute(output, .font, at: $0.range.location) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true },
            "criterion 8: ALL THREE header cells are bold, not just the first"
        )
        check(
            cells[3...8].allSatisfy { attribute(output, .font, at: $0.range.location) as? NSFont == Theme.bodyFont },
            "criterion 8: every one of the six body cells is plain Theme.bodyFont"
        )
    } else {
        check(false, "criterion 8: cannot inspect header/body fonts — the 3x3 table did not render 9 cells")
    }

    // Inline spans work inside cells, and the cell's paragraph style survives them — the style is
    // what carries the text block, so a run that dropped it would silently fall out of the grid.
    let (spanned, _) = MarkdownRenderer.render("| h |\n| --- |\n| **b** and [x](https://a.b) |")
    let spannedCells = tableCells(spanned)
    check(spannedCells.count == 2, "inline spans inside a cell do not break the cell into pieces (2 cells)")
    // Located by searching the rendered text rather than by indexing `spannedCells`, so this check
    // survives (and reports) a regression in the cell count instead of trapping on it.
    let bodyRange = (spanned.string as NSString).range(of: "b and x")
    check(bodyRange.location != NSNotFound, "…and their delimiters are consumed: the body cell reads `b and x`")
    if bodyRange.location != NSNotFound {
        check(
            attribute(spanned, .link, at: bodyRange.location + 6) is URL,
            "a link inside a cell keeps its .link attribute"
        )
        check(
            (attribute(spanned, .paragraphStyle, at: bodyRange.location) as? NSParagraphStyle)?.textBlocks.first is NSTextTableBlock,
            "…and the run carrying it is still inside the grid (its paragraph style keeps the cell's text block)"
        )
    }
}

section("(preview-tables) criteria 12-15: what is NOT a table")
check(
    MarkdownBlockParser.parse("| a | b |") == [.paragraph(text: "| a | b |", line: 0)],
    "criterion 12: a `|` line with NO delimiter row after it is still a paragraph — byte-identical to HEAD"
)
check(
    MarkdownBlockParser.parse("| a | b |\n| c | d |") == [.paragraph(text: "| a | b | | c | d |", line: 0)],
    "criterion 12: two `|` lines with no delimiter row still merge into one paragraph, exactly as before"
)
check(
    MarkdownBlockParser.parse("| h |\n| --- |\n| x |\n\n| z |") == [
        .table(header: ["h"], rows: [["x"]], alignments: [.leading], line: 0),
        .paragraph(text: "| z |", line: 4),
    ],
    "criterion 13: a BLANK line ends the table; the pipe line after it is a fresh (non-table) paragraph"
)
check(
    MarkdownBlockParser.parse("| h1 | h2 |\n| --- | --- |\n| a | b |\n> Note: `|` is the pipe character.") == [
        .table(header: ["h1", "h2"], rows: [["a", "b"]], alignments: [.leading, .leading], line: 0),
        .blockquote(text: "Note: `|` is the pipe character.", line: 3),
    ],
    "criterion 13: a BLOCK-STARTER line that contains a pipe ends the table and is reclassified as a blockquote"
)
do {
    // The other four block starters. Each must terminate the table AND be classified as itself.
    //
    // (adv-review-behavior finding 2) The first THREE carry a pipe, so `continuesTable`'s
    // `contains("|")` guard passes and only the `startsBlock` half can stop consumption — those
    // three are genuinely discriminating. The RULE is different and the original comment here
    // claimed otherwise: `--- ` has no pipe, so `continuesTable` returns false at its `contains`
    // guard and `startsBlock`'s `isRule` branch is never reached. That is not a fixable gap in the
    // test — it is a fact about the grammar. `isRule` requires every non-trailing-whitespace
    // character to be `-` or `*`, so **no rule line can ever contain a pipe**, which makes
    // `isRule` unreachable from `continuesTable` by construction. The rule case is kept because a
    // rule must still terminate a table (it does, via the pipe guard), but it is documented here as
    // testing that outcome rather than the `startsBlock` path, so nobody later "strengthens" it by
    // trying to give a rule a pipe.
    let starters: [(line: String, describes: String)] = [
        ("# H | x", "heading"),
        ("- item | x", "list item"),
        ("```swift | x", "fence open"),
        ("--- ", "rule"),
    ]
    var offenders: [String] = []
    for starter in starters {
        let blocks = MarkdownBlockParser.parse("| h |\n| --- |\n| a |\n" + starter.line)
        guard blocks.count == 2, case .table = blocks[0], blocks[1].line == 3 else {
            offenders.append(starter.describes)
            continue
        }
        if case .table = blocks[1] { offenders.append(starter.describes) }
    }
    check(offenders.isEmpty, "criterion 13: heading / list item / fence open / rule all end a table and become their own block (offenders: \(offenders))")
}
check(
    MarkdownBlockParser.parse("```\n| a | b |\n| --- | --- |\n| c | d |\n```") == [
        .codeBlock(code: "| a | b |\n| --- | --- |\n| c | d |", line: 0),
    ],
    "criterion 14: a table INSIDE a fenced code block is verbatim code, not a table"
)
check(
    MarkdownBlockParser.parse("```a|b\n| --- | --- |\ncode\n```") == [
        .codeBlock(code: "| --- | --- |\ncode", line: 0),
    ],
    "criterion 14: a fence-open line containing a `|` is a fence, not a table header (step 2 runs before step 7.5)"
)
check(
    MarkdownBlockParser.parse("| a | b |\n| --- | --- |\n| x | y |") == [.table(
        header: ["a", "b"],
        rows: [["x", "y"]],
        alignments: [.leading, .leading],
        line: 0
    )],
    "criterion 15: a table open at EOF with NO trailing newline is emitted whole"
)
check(
    MarkdownBlockParser.parse("| a | b |\n| --- | --- |") == [.table(
        header: ["a", "b"],
        rows: [],
        alignments: [.leading, .leading],
        line: 0
    )],
    "criterion 15: a header + delimiter row at EOF with no body rows is a legal, empty-bodied table"
)
do {
    let (output, anchors) = MarkdownRenderer.render("| a | b |\n| --- | --- |\n| x | y |")
    check(anchors.count == 1 && tableCells(output).count == 4, "criterion 15: …and it RENDERS (4 cells, 1 anchor) rather than being dropped at EOF")
}

section("(preview-tables) criteria 16-17: anchors and the flush protocol")
do {
    // Criterion 16. A four-line table (header, delimiter, two body rows) inside a mixed document
    // emits exactly ONE anchor, at its header line.
    let document = "# H\n\npara\n\n| a | b |\n| --- | --- |\n| c | d |\n| e | f |\n\n> after"
    let (_, anchors) = MarkdownRenderer.render(document)
    check(anchors.map { $0.sourceLine } == [0, 2, 4, 9], "criterion 16: a mixed document emits 4 anchors — heading@0, paragraph@2, TABLE@4 (its header line), quote@9")
    // Count-guarded before forming the range: a regression down to zero anchors would make
    // `1..<0` trap rather than FAIL (adv-review-behavior finding 5), and it would also make the
    // ordering check below vacuously true.
    check(anchors.count == 4, "criterion 16: sanity — four anchors exist before the ordering check reads them")
    var ascending = anchors.count == 4
    if anchors.count > 1 {
        for index in 1..<anchors.count {
            if !(anchors[index].sourceLine > anchors[index - 1].sourceLine) { ascending = false }
            if !(anchors[index].location > anchors[index - 1].location) { ascending = false }
        }
    }
    check(ascending, "criterion 16: those anchors are strictly ascending in BOTH sourceLine and location")
    // Stated as the negative too, because "exactly one anchor" is precisely the claim that lines
    // 5-7 get none. A per-row anchor would give sourceLines [0, 2, 4, 6, 7, 9] and still be
    // strictly ascending, so the ordering check above cannot catch it — this can.
    check(
        !anchors.contains { [5, 6, 7].contains($0.sourceLine) },
        "criterion 16: neither the delimiter row (line 5) nor either body row (6, 7) gets an anchor of its own"
    )
    // …and it does not creep back at scale. This is the SPEC §8.3 trade the item records: a 20-row
    // table is ONE anchor, so scrolling through it moves the preview zero pixels — the same trade
    // fenced code blocks already make.
    let long = (["| a | b |", "| --- | --- |"] + (0..<20).map { "| r\($0) | v\($0) |" }).joined(separator: "\n")
    let (longOutput, longAnchors) = MarkdownRenderer.render(long)
    check(longAnchors == [MarkdownAnchor(sourceLine: 0, location: 0)], "criterion 16: a 20-row table emits exactly ONE anchor, at line 0")
    check(tableCells(longOutput).count == 42, "criterion 16: …while still rendering all 21 rows x 2 columns = 42 cells")
}
do {
    // **Criterion 17 — the flush-protocol guard, and the re-proof `adv-review-edge` demanded.**
    //
    // That review proved the "at most one accumulator is ever active" invariant for the FOUR
    // accumulators that existed, and said explicitly that (preview-tables) adding a fifth would
    // require re-proving it rather than assuming it. **The re-proof is that this item adds no fifth
    // accumulator at all**: step 7.5 reads a table's whole extent forward inside a single loop
    // iteration and appends the `.table` INLINE (`skipUntilIndex` only suppresses re-classifying
    // lines already consumed — it holds no content and emits nothing), so the accumulator set is
    // still exactly {paragraph, quote, list item, fence} and the earlier proof carries over
    // unchanged.
    //
    // What step 7.5 DOES inherit is the obligation every inline-appending step already has: flush
    // the three line-oriented accumulators BEFORE appending. Drop `flushListItem()` and `- a`
    // followed by a table yields `[.table(line: 1), .listItem(line: 0)]` — out of source order,
    // which trips `assertStrictlyAscending` in debug and, because `assert` compiles out, silently
    // corrupts §8.3's binary search in release. The block-level `.line` check runs FIRST below, on
    // purpose: `render` would TRAP on out-of-order blocks and a trapped harness reports nothing.
    //
    // Each input below leaves a DIFFERENT accumulator pending across the table, which is what makes
    // this non-vacuous for all three flushes rather than just the one that happens to be commonest.
    // Verified by mutation: removing any single flush from step 7.5 makes this section FAIL.
    let pending: [(source: String, describes: String)] = [
        ("- a\n| x | y |\n| --- | --- |", "an open LIST ITEM"),
        ("- a\n  cont\n| x | y |\n| --- | --- |", "a CONTINUED list item"),
        ("para\n| x | y |\n| --- | --- |", "an open PARAGRAPH"),
        ("> q\n| x | y |\n| --- | --- |", "an open BLOCKQUOTE"),
    ]
    var blockOrderOffenders: [String] = []
    var anchorOffenders: [String] = []
    for case_ in pending {
        let blocks = MarkdownBlockParser.parse(case_.source)
        guard blocks.count >= 2 else {
            blockOrderOffenders.append(case_.describes)
            continue
        }
        for index in 1..<blocks.count where !(blocks[index].line > blocks[index - 1].line) {
            blockOrderOffenders.append(case_.describes)
        }
        // The table must be LAST, i.e. the pending block was flushed ahead of it.
        if case .table = blocks[blocks.count - 1] {} else { blockOrderOffenders.append(case_.describes) }
    }
    check(
        blockOrderOffenders.isEmpty,
        "criterion 17: step 7.5 flushes every pending accumulator BEFORE appending its table, so blocks stay in source order (offenders: \(Set(blockOrderOffenders).sorted()))"
    )
    // Only once the block order is known good is it safe to render (out-of-order blocks trap).
    if blockOrderOffenders.isEmpty {
        for case_ in pending {
            let (_, anchors) = MarkdownRenderer.render(case_.source)
            guard anchors.count > 1 else {
                anchorOffenders.append(case_.describes)
                continue
            }
            for index in 1..<anchors.count
            where !(anchors[index].sourceLine > anchors[index - 1].sourceLine)
                || !(anchors[index].location > anchors[index - 1].location) {
                anchorOffenders.append(case_.describes)
            }
        }
    }
    check(
        anchorOffenders.isEmpty,
        "criterion 17: and the rendered anchors stay strictly ascending in sourceLine AND location for all four (offenders: \(Set(anchorOffenders).sorted()))"
    )
    // The exact array the criterion names, so the property checks above cannot pass on a
    // structurally different-but-still-ordered parse.
    check(
        MarkdownBlockParser.parse("- a\n| x | y |\n| --- | --- |") == [
            .listItem(marker: "•", text: "a", line: 0),
            .table(header: ["x", "y"], rows: [], alignments: [.leading, .leading], line: 1),
        ],
        "criterion 17: `- a` immediately followed by a table emits [.listItem(line: 0), .table(line: 1)] — in that order"
    )
    // A table is also unreachable while a fence is open, which is why step 7.5 needs no fence
    // flush. Stated as an assertion rather than left to the step-1 `continue`.
    check(
        MarkdownBlockParser.parse("```\n| x | y |\n| --- | --- |") == [
            .codeBlock(code: "| x | y |\n| --- | --- |", line: 0),
        ],
        "criterion 17: step 7.5 is unreachable with a fence open, so it needs no fence flush"
    )
}

// MARK: - (preview-tables, adv-review-edge finding 1) the cell budget
//
// The quadratic blow-up this bounds, restated because the numbers are the argument: the header
// alone fixes the column count and a body row as short as a single `|` is padded to full width, so
// cells grow as `columns x (rows + 1)` from `O(columns + rows)` bytes of source. Measured before
// the budget existed: 1001 columns over 1000 single-`|` rows is a **3,009-byte** document that
// produced 1,001,000 cells, 2.66 s of render and **944.6 MB** peak RSS — and one more octave, a
// 12 KB file, extrapolated to roughly 15 GB. Over budget the construct is not a table at all and
// falls through to paragraph, which is exactly what HEAD did with it.
section("(preview-tables) the cell budget bounds the quadratic blow-up")
do {
    // Well under the cap: an ordinary table is completely unaffected.
    let smallColumns = 10
    let smallRows = 100 // 10 * 101 = 1,010 cells
    var small = "|" + String(repeating: " h |", count: smallColumns) + "\n"
    small += "|" + String(repeating: " --- |", count: smallColumns) + "\n"
    small += String(repeating: "|" + String(repeating: " c |", count: smallColumns) + "\n", count: smallRows)
    let smallBlocks = MarkdownBlockParser.parse(small)
    check(
        smallBlocks.count == 1 && { if case .table = smallBlocks[0] { return true } else { return false } }(),
        "a 10x100 table (1,010 cells) is far under the budget and parses as one table"
    )

    // The exact pathological shape from the review, scaled down so the test stays fast: a wide
    // header multiplied against rows carrying almost no text. Without the budget this is where the
    // cell count explodes; with it, the construct must NOT become a table.
    let wideColumns = 400
    let wideRows = 400 // 400 * 401 = 160,400 cells — over the 50,000 budget
    var wide = String(repeating: "|", count: wideColumns + 1) + "\n"
    wide += "| --- |\n"
    wide += String(repeating: "|\n", count: wideRows)
    let wideBlocks = MarkdownBlockParser.parse(wide)
    var producedTable = false
    for block in wideBlocks where { if case .table = block { return true } else { return false } }() {
        producedTable = true
    }
    check(
        !producedTable,
        "a 400-column header over 400 single-pipe rows (160,400 cells) exceeds the budget and is NOT a table"
    )

    // And the degradation is the RIGHT one: it renders, bounded, exactly as it did before tables
    // existed — not an error, not an empty block, not a hang.
    let started = Date()
    let (wideOutput, wideAnchors) = MarkdownRenderer.render(wide)
    let elapsed = Date().timeIntervalSince(started)
    check(wideOutput.length > 0, "the over-budget document still renders as ordinary paragraph text")
    check(!wideAnchors.isEmpty, "the over-budget document still emits anchors")
    check(elapsed < 1.0, "the over-budget document renders in under 1s (advisory; got \(elapsed)s)")

    // The boundary itself, computed from the constant rather than hard-coded, so changing the
    // budget cannot silently invalidate this pair. One column means `rows + 1` cells exactly.
    let atCap = "|a|\n| --- |\n" + String(repeating: "|x|\n", count: MarkdownBlockParser.tableCellLimit - 1)
    let atCapBlocks = MarkdownBlockParser.parse(atCap)
    check(
        atCapBlocks.count == 1 && { if case .table = atCapBlocks[0] { return true } else { return false } }(),
        "a single-column table of exactly tableCellLimit cells is admitted (the boundary is inclusive)"
    )
    let overCap = "|a|\n| --- |\n" + String(repeating: "|x|\n", count: MarkdownBlockParser.tableCellLimit)
    let overCapBlocks = MarkdownBlockParser.parse(overCap)
    var overProducedTable = false
    for block in overCapBlocks where { if case .table = block { return true } else { return false } }() {
        overProducedTable = true
    }
    check(!overProducedTable, "one cell past tableCellLimit is rejected — the boundary is exact, not approximate")
}

// MARK: - md-link-scan-quadratic: differential fuzz
//
// A harness-local reference reimplementing `MarkdownInlineParser`/`MarkdownRenderer` with the naive
// to-EOF `firstIndex` link scan (unmemoized) diffs against the shipped, memoized parser/renderer
// over a seeded randomized battery of bracket-heavy inputs. This proves the memoization is
// byte-identical to the unmemoized algorithm on thousands of inputs the hand-enumerated battery
// above does not cover, catching an off-by-one the enumerated cases might miss.
//
// (preview-emphasis-commonmark) **This reference had to receive the delimiter-stack algorithm too**,
// or every input containing a `*` would mismatch and the oracle would be red for a reason that has
// nothing to do with `parseLink`. The plan's R10 states the consequence: once both sides share the
// algorithm this oracle cannot judge whether that algorithm is RIGHT — it goes on proving exactly
// what it was built to prove (memoized link scan == unmemoized link scan). It is not quite vacuous,
// as R10 has it: because the two copies are separate code, it still catches a one-sided edit, and it
// was measured doing so (deleting `removeDelimitersBetween` from the production copy fails both
// assertions below). What it cannot catch is a rule that is wrong in both copies, which is what the
// ~50 hand-written expected trees above, the reconstruction property fuzz further down, and the
// standalone HEAD-vs-working-tree differ run out of tree are for.

/// `MarkdownInlineParser` with the PRE-FIX link scan: identical phase 1 / phase 2 / phase 3
/// structure, but `parseLink`'s closer search is the naive two-to-EOF-scan version that shipped
/// before md-link-scan-quadratic (no memo arrays). This is the differential oracle.
///
/// **What is shared and what is duplicated** (plan R10). Shared with production, deliberately:
/// `InlineToken`, `InlineDelimiterRun`, `InlineTokenStream` (including its list surgery and its
/// fold), and `MarkdownInlineParser.asteriskRunFlanking` with the two character-class predicates
/// underneath it. A second, hand-rolled copy of the flanking rule or of the list plumbing would
/// make any divergence show up as an unattributable fuzz mismatch; sharing them means a slip is a
/// compile error instead. Duplicated on purpose: `tokenize` (which is where the link scan differs,
/// i.e. the whole point of this oracle) and `processEmphasis` (transcribed rule for rule, so a
/// misreading of the algorithm in one copy is at least visible as a mismatch in the other).
enum ReferenceInlineParser {
    static func parse(_ text: String) -> [InlineNode] {
        var stream = tokenize(Array(text))
        processEmphasis(&stream)
        return stream.foldTokens(from: stream.head, until: InlineTokenStream.nilIndex)
    }

    /// Phase 1, with the unmemoized `parseLink`.
    private static func tokenize(_ characters: [Character]) -> InlineTokenStream {
        var stream = InlineTokenStream(characters)
        var index = 0
        let count = characters.count
        var literalStart = InlineTokenStream.nilIndex

        func takeLiteral() {
            if literalStart == InlineTokenStream.nilIndex {
                literalStart = index
            }
            index += 1
        }

        func flushLiteral() {
            guard literalStart != InlineTokenStream.nilIndex else { return }
            stream.appendText(from: literalStart, to: index)
            literalStart = InlineTokenStream.nilIndex
        }

        while index < count {
            let character = characters[index]

            if character == "`" {
                if let close = firstIndex(of: "`", in: characters, from: index + 1) {
                    flushLiteral()
                    stream.appendNode(InlineNode.code(String(characters[(index + 1)..<close])))
                    index = close + 1
                    continue
                }
                takeLiteral()
                continue
            }

            if character == "[" {
                if let link = parseLink(characters, from: index) {
                    flushLiteral()
                    stream.appendNode(InlineNode.link(text: link.title, url: link.url))
                    index = link.end
                    continue
                }
                takeLiteral()
                continue
            }

            if character == "*" {
                var end = index
                while end < count, characters[end] == "*" {
                    end += 1
                }
                flushLiteral()
                let flanking = MarkdownInlineParser.asteriskRunFlanking(
                    before: index > 0 ? characters[index - 1] : nil,
                    after: end < count ? characters[end] : nil
                )
                stream.appendDelimiterRun(length: end - index, canOpen: flanking.canOpen, canClose: flanking.canClose)
                index = end
                continue
            }

            takeLiteral()
        }

        flushLiteral()
        return stream
    }

    /// Phase 2, transcribed from CommonMark 0.30's `process_emphasis`.
    private static func processEmphasis(_ stream: inout InlineTokenStream) {
        var openersBottom = [Int](repeating: InlineTokenStream.nilIndex, count: 6)
        var closer = stream.firstDelimiter

        while closer != InlineTokenStream.nilIndex {
            guard stream.delimiters[closer].canClose else {
                closer = stream.delimiters[closer].next
                continue
            }

            let key = openersBottomKey(stream.delimiters[closer])

            var opener = stream.delimiters[closer].previous
            var openerFound = false
            var spanMaxDepth = 0
            while opener != InlineTokenStream.nilIndex, opener != openersBottom[key] {
                spanMaxDepth = max(spanMaxDepth, stream.delimiters[opener].spanMaxDepth)
                if spanMaxDepth >= MarkdownInlineParser.emphasisNestingLimit {
                    break
                }
                if stream.delimiters[opener].canOpen,
                   !ruleOfThreeForbids(opener: stream.delimiters[opener], closer: stream.delimiters[closer]) {
                    openerFound = true
                    break
                }
                opener = stream.delimiters[opener].previous
            }

            let oldCloser = closer

            if openerFound {
                let use = (stream.delimiters[opener].remaining >= 2 && stream.delimiters[closer].remaining >= 2) ? 2 : 1
                stream.delimiters[opener].remaining -= use
                stream.delimiters[closer].remaining -= use

                let openerToken = stream.delimiters[opener].token
                let closerToken = stream.delimiters[closer].token
                let children = stream.foldTokens(from: stream.tokens[openerToken].next, until: closerToken)
                let node = stream.appendDetachedNode(use == 2 ? .bold(children) : .italic(children))
                stream.spliceToken(node, between: openerToken, and: closerToken)
                stream.removeDelimitersBetween(opener: opener, closer: closer)
                stream.delimiters[opener].spanMaxDepth = spanMaxDepth + 1

                if stream.delimiters[opener].remaining == 0 {
                    stream.unlinkToken(openerToken)
                    stream.removeDelimiter(opener)
                }
                if stream.delimiters[closer].remaining == 0 {
                    stream.unlinkToken(closerToken)
                    let resume = stream.delimiters[closer].next
                    stream.removeDelimiter(closer)
                    closer = resume
                }
            } else {
                closer = stream.delimiters[closer].next
                openersBottom[key] = stream.delimiters[oldCloser].previous
                if !stream.delimiters[oldCloser].canOpen {
                    stream.removeDelimiter(oldCloser)
                }
            }
        }
    }

    private static func openersBottomKey(_ closer: InlineDelimiterRun) -> Int {
        (closer.canOpen ? 3 : 0) + closer.originalLength % 3
    }

    private static func ruleOfThreeForbids(opener: InlineDelimiterRun, closer: InlineDelimiterRun) -> Bool {
        guard closer.canOpen || opener.canClose else { return false }
        guard (opener.originalLength + closer.originalLength) % 3 == 0 else { return false }
        return !(opener.originalLength % 3 == 0 && closer.originalLength % 3 == 0)
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

    // (preview-emphasis-commonmark) Mirrors `PreviewFont.bodyBoldItalic`, including its
    // fall-back-to-bold rule. The differential fuzz below compares rendered ATTRIBUTES byte for
    // byte, so a face this reference does not have is a mismatch, not a cosmetic difference.
    private static let bodyBoldItalic: NSFont = {
        let descriptor = Theme.bodyFont.fontDescriptor.withSymbolicTraits([.bold, .italic])
        let candidate = NSFont(descriptor: descriptor, size: Theme.bodyFont.pointSize) ?? bodyBold
        let traits = candidate.fontDescriptor.symbolicTraits
        return traits.contains(.italic) && traits.contains(.bold) ? candidate : bodyBold
    }()

    private struct InlineStyle {
        let regularFont: NSFont
        let boldFont: NSFont
        let italicFont: NSFont
        let boldItalicFont: NSFont
        let isBold: Bool
        let isItalic: Bool
        let color: NSColor
        let paragraphStyle: NSParagraphStyle

        var font: NSFont {
            switch (isBold, isItalic) {
            case (false, false): return regularFont
            case (true, false): return boldFont
            case (false, true): return italicFont
            case (true, true): return boldItalicFont
            }
        }

        func adding(bold addBold: Bool = false, italic addItalic: Bool = false) -> InlineStyle {
            InlineStyle(
                regularFont: regularFont,
                boldFont: boldFont,
                italicFont: italicFont,
                boldItalicFont: boldItalicFont,
                isBold: isBold || addBold,
                isItalic: isItalic || addItalic,
                color: color,
                paragraphStyle: paragraphStyle
            )
        }
    }

    private static let bodyStyle = InlineStyle(
        regularFont: Theme.bodyFont, boldFont: bodyBold, italicFont: bodyItalic,
        boldItalicFont: bodyBoldItalic, isBold: false, isItalic: false,
        color: Theme.text, paragraphStyle: bodyParagraph
    )
    private static let listStyle = InlineStyle(
        regularFont: Theme.bodyFont, boldFont: bodyBold, italicFont: bodyItalic,
        boldItalicFont: bodyBoldItalic, isBold: false, isItalic: false,
        color: Theme.text, paragraphStyle: listParagraph
    )
    private static let quoteStyle = InlineStyle(
        regularFont: Theme.bodyFont, boldFont: bodyBold, italicFont: bodyItalic,
        boldItalicFont: bodyBoldItalic, isBold: false, isItalic: false,
        color: Theme.mutedText, paragraphStyle: quoteParagraph
    )

    private static func headingStyle(level: Int) -> InlineStyle {
        let font = Theme.headingFont(level: level)
        return InlineStyle(
            regularFont: font, boldFont: font, italicFont: font, boldItalicFont: font,
            isBold: false, isItalic: false, color: Theme.text, paragraphStyle: headingParagraph
        )
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

        case let .table(header, rows, alignments, _):
            // (preview-tables) This `switch` is exhaustive with NO `default`, so a seventh
            // `MarkdownBlock` case is a compile error here — which is why `MarkdownRenderer.emitTable`
            // is internal rather than private. Delegating to the production emitter (rather than
            // copying it, as every case above does) makes the differential oracle **vacuous for
            // tables**: the two renderers cannot disagree about a construct they share code for.
            // That is accepted and costs nothing, because neither fuzz alphabet below contains a
            // `|` or a newline, so no fuzz input can ever produce a `.table` at all. The oracle
            // that DOES cover this item is the standalone HEAD-vs-working-tree differ described in
            // the (preview-tables) sections above, which generates real multi-line documents.
            MarkdownRenderer.emitTable(header: header, rows: rows, alignments: alignments, into: output)
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
                emitInline(children, style: style.adding(bold: true), into: output)

            case let .italic(children):
                emitInline(children, style: style.adding(italic: true), into: output)

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
//
// (preview-emphasis-commonmark) That gap is now closed by the section below, which adds two stronger
// properties over the same shape of corpus: byte-exact delimiter RECONSTRUCTION (which also pins how
// many asterisks each node consumed, not just which characters survived) and a structural
// "no empty .bold/.italic anywhere" guard (which is the one that actually catches the mutant quoted
// above — reconstruction is blind to it too, for the reason recorded there). This fuzz is kept
// unchanged rather than folded in: it is a different property with a different seed, it is cheap,
// and it was the oracle the previous item shipped on.

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

// MARK: - (preview-emphasis-commonmark): delimiter reconstruction property fuzz
//
// The oracle plan R2 designed to be the independent one for the delimiter-stack change (R2/R10) —
// and it is independent in the sense that matters structurally: the differential fuzz above compares
// two copies of one algorithm, while this one is checked against the INPUT. How much that buys is
// measured further down, and it is less than R2 claims. The property is:
//
//     reconstruct(parse(s)) == s          — byte for byte
//
// where `reconstruct` walks the tree re-emitting the delimiters each node claims to have consumed:
// `**` around a `.bold`, `*` around an `.italic`, backticks around a `.code`, `[…](…)` around a
// `.link`, literals verbatim. It is a pure function of the tree — unlike the property Rev 1 of the
// plan proposed ("re-insert the delimiters of UNMATCHED runs"), which is not computable from
// `[InlineNode]` at all, since "unmatched" is internal `processEmphasis` state.
//
// What it proves: every character of the input is accounted for exactly once, in order, and every
// emphasis node consumed exactly as many asterisks as its type says it did. A parser that drops a
// character, duplicates one, reorders two nodes, or builds a `.bold` out of one asterisk fails it.
//
// **What it does NOT prove, measured rather than assumed.** Plan R2 states that this property
// "gives `"**** bold****"` ≠ `"** bold**"` for the mutant", meaning the character-swallowing tree
// `[.italic([]), .text(" bold"), .italic([])]` that `(preview-bold-spans)` measured as invisible to
// the older flatten-and-strip property. **That is wrong, and the plan is wrong about it**: that
// mutant is built from `.italic` nodes, so reconstruction re-emits one asterisk per side per node —
// `"*" + "" + "*"` twice — which is exactly the four asterisks of the input. It reconstructs to
// `"** bold**"` and scores zero violations, the identical blind spot. R2's arithmetic works only for
// the `.bold` sibling of that mutant, which is checked below.
//
// The consequence was measured, not reasoned about: this property was run against **HEAD's**
// parser — the one this item replaces, which loses characters and mis-pairs delimiters — over these
// exact two corpora, and scored **0 violations on both**. It is a conservation law that the old
// algorithm satisfies too (it also only ever consumed the delimiters it emitted), so it is a guard
// against future breakage rather than evidence that this change is an improvement. Plan R2 calls it
// "**the** independent oracle for the emphasis change"; on the evidence it is not, and the hand
// written trees above are.
//
// It is emphatically not vacuous, though, and that was measured too: deleting the single
// `removeDelimitersBetween` call from `processEmphasis` — the rule plan R8 adds, whose absence lets
// a later closer match an opener already nested inside a finished node — makes this property fail on
// **both** corpora (and the differential fuzz fail as well). No hand-written tree in this file
// catches that mutation; this fuzz is what stands between it and a green run.
//
// So the blind spot is closed by a SECOND property rather than papered over: **no `.bold`/`.italic`
// node in any parse may have empty children.** Balanced empty emphasis is precisely the shape both
// character-conservation properties are blind to, and it is the shape that deletes text from the
// preview, because `emitInline` appends nothing for empty children. Under the delimiter-stack
// algorithm it is structurally unreachable — an emphasis node's children come from the tokens
// strictly between two DIFFERENT delimiter runs, and two `*` runs can never be adjacent because
// runs are maximal — so this fuzz pins a property the design guarantees rather than hoping for one.
//
// **This is the one that discriminates, and it was measured against HEAD too**: HEAD's parser
// scores **421 violations on the emphasis-only corpus and 10 on the second** (first hit:
// `"   ****"` → `[.text("   "), .bold([])]`, four deleted characters), against 0 here. So of the
// two properties in this section, the cheap structural one is the one carrying the evidence.
//
// **The oracle that beats both, and it is external.** Neither property says the PAIRING is right —
// only these do, and they were run out of tree because the harness has no npm dependency and must
// not grow one:
//
//     swiftc <this tree's renderer> + a driver that prints one HTML rendering per input
//     node -e "require('markdown-it')('commonmark').renderInline(input)"
//
// over **every string of length <= 8 from `{a, *, space}` — all 9,840 of them — with 0 mismatches**,
// byte for byte on rendered HTML. That covers flanking, the rule of three, `openers_bottom`, partial
// consumption and nesting against a real CommonMark implementation rather than against a second copy
// of this one. The same sweep over `{a, *, space, U+0301}` (<= 5 scalars, 1,364 inputs) differs on
// 83, every one of them containing the combining mark — the documented grapheme-vs-scalar limit
// recorded on `asteriskRunFlanking` and in SPEC §8.2, and nothing else.
//
// Left out of the sweep deliberately: backticks and brackets, where this subset differs from
// CommonMark BY DESIGN (backticks pair 1-2, 3-4 rather than by run length; link parsing is the
// documented `[title](url)` form only), so a mismatch there would mean nothing.

/// Re-emits the delimiters the tree says it consumed. See the section comment above.
func reconstruct(_ nodes: [InlineNode]) -> String {
    nodes.map { node -> String in
        switch node {
        case let .text(value): return value
        case let .code(value): return "`" + value + "`"
        case let .link(title, url): return "[" + title + "](" + url + ")"
        case let .bold(children): return "**" + reconstruct(children) + "**"
        case let .italic(children): return "*" + reconstruct(children) + "*"
        }
    }.joined()
}

/// Whether any `.bold`/`.italic` node anywhere in the tree has empty children.
func containsEmptyEmphasis(_ nodes: [InlineNode]) -> Bool {
    for node in nodes {
        switch node {
        case let .bold(children), let .italic(children):
            if children.isEmpty || containsEmptyEmphasis(children) { return true }
        case .text, .code, .link:
            continue
        }
    }
    return false
}

section("(preview-emphasis-commonmark) criterion 9: the two properties can fail")
// Neither property is worth anything unless a wrong tree trips it, so each is run against
// hand-written wrong trees BEFORE being run against the parser. Without these six assertions the
// "0 violations" results below would be indistinguishable from an oracle that always returns true.
check(
    reconstruct([.bold([]), .text(" bold"), .bold([])]) != "** bold**",
    "non-vacuity: reconstruction REJECTS the delimiter-doubling mutant (it re-emits \"**** bold****\")"
)
check(
    reconstruct([.italic([.text("a")]), .text("b")]) != "*a*b*",
    "non-vacuity: reconstruction REJECTS a tree that silently swallowed a trailing delimiter"
)
check(
    reconstruct([.bold([.text("a")])]) != "*a*",
    "non-vacuity: reconstruction REJECTS an italic parsed as bold (delimiter COUNT is part of the property)"
)
check(
    containsEmptyEmphasis([.italic([]), .text(" bold"), .italic([])]),
    "non-vacuity: the empty-emphasis guard FIRES on the exact mutant reconstruction is blind to"
)
check(
    containsEmptyEmphasis([.text("a"), .bold([.text("b"), .italic([])])]),
    "non-vacuity: the empty-emphasis guard reaches nested children, not just the top level"
)
check(
    !containsEmptyEmphasis([.text("a"), .bold([.italic([.text("b")])]), .code("")]),
    "…and does not fire on a legitimately nested tree, or on an empty CODE span, which is legal"
)

section("(preview-emphasis-commonmark) criterion 9: reconstruction + no-empty-emphasis over fuzz")
do {
    // A third seed, visibly unlike the two above it (`0x5EED_1234_ABCD_9876`,
    // `0xB01D_5EED_2026_0821`). `SeededLCG` is deterministic, so reusing either would replay the
    // identical stream of lengths and character indices and this fuzz would add far less than its
    // name claims.
    var rng = SeededLCG(seed: 0xA57E_9153_C0DE_0030)
    let fuzzCount = 5000

    // Two corpora. The first is emphasis-only, so every draw is delimiter arithmetic and nothing
    // dilutes it. The second adds backticks and brackets, which is where plan R1's change lives:
    // code spans and links now resolve over the whole block, so an input like `*a`b* c`d` produces a
    // code span that spans a `*` — a shape the first alphabet cannot generate at all.
    let corpora: [(name: String, alphabet: [Character])] = [
        ("emphasis-only", ["a", "*", " "]),
        ("with code spans and links", ["a", "*", " ", "`", "[", "]", "(", ")"]),
    ]

    for corpus in corpora {
        var reconstructionViolations = 0
        var emptyEmphasisViolations = 0
        var distinctInputs = Set<String>()

        for _ in 0..<fuzzCount {
            let length = rng.nextInt(upperBound: 48)
            var chars: [Character] = []
            chars.reserveCapacity(length)
            for _ in 0..<length {
                chars.append(corpus.alphabet[rng.nextInt(upperBound: corpus.alphabet.count)])
            }
            let input = String(chars)
            distinctInputs.insert(input)

            let tree = MarkdownInlineParser.parse(input)
            let rebuilt = reconstruct(tree)
            if rebuilt != input {
                reconstructionViolations += 1
                if reconstructionViolations <= 5 {
                    print("  RECONSTRUCTION VIOLATION on \(input.debugDescription): rebuilt \(rebuilt.debugDescription) from \(tree)")
                }
            }
            if containsEmptyEmphasis(tree) {
                emptyEmphasisViolations += 1
                if emptyEmphasisViolations <= 5 {
                    print("  EMPTY EMPHASIS on \(input.debugDescription): \(tree)")
                }
            }
        }

        // The corpus guard both fuzzes above carry, for the same reason: "0 violations over 5000
        // inputs" is satisfiable by a degenerate corpus, which is exactly the defect
        // (fuzz-rng-low-bits) found. Threshold 4000 of 5000, matching them; measured today is **4570**
        // for the 3-character alphabet and **4704** for the 8-character one (short draws collide by
        // birthday paradox, and `length == 0` alone recurs ~1/48 of the time).
        check(
            distinctInputs.count > 4_000,
            "\(corpus.name): \(fuzzCount) inputs are genuinely distinct (\(distinctInputs.count) unique) — the corpus is not degenerate"
        )
        check(
            reconstructionViolations == 0,
            "\(corpus.name): re-emitting each node's delimiters reproduces the input BYTE FOR BYTE (0 violations in \(fuzzCount))"
        )
        check(
            emptyEmphasisViolations == 0,
            "\(corpus.name): no parse contains an empty .bold/.italic — the shape that deletes text from the preview (0 in \(fuzzCount))"
        )
    }
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

// (preview-emphasis-commonmark) criterion 12 — the DELIMITER-dense shapes. The plan (R3) names two
// of the three below and attributes the risk to `openers_bottom`; **the attribution is wrong for the
// implementation the plan itself specifies**, and the numbers here are measured by instrumenting a
// copy of the shipped parser with a backward-step counter, not taken from the plan:
//
// **Counting convention, because two instrumentations of the same loop disagree by exactly the
// number of successful matches**: a "step" below is one ITERATION of the backward `while` loop,
// including the iteration that finds the opener and breaks. Counting only the candidates walked
// PAST (the `opener = previous` executions) gives 3,999 and 39,999 for the last two rows instead of
// 5,999 and 59,999 — the same measurement, minus the 2,000/20,000 matches. Both numbers come from
// the shipped loop with a counter added; neither changes the conclusion.
//
//     input                  steps WITH openers_bottom   steps WITHOUT
//     "*"×40000                            0                    0     (Rev 1's criterion)
//     "*a "×20000                          0                    0     (Rev 1's named input)
//     "a** * "×2000                        0                    0     (R3's replacement input)
//     "a* "×10000                          0                    0     (R3's replacement input)
//     "a*a **"×4000                    5,999            2,003,000
//     "a*a **"×40000                  59,999          200,030,000     (0.054 s vs 0.784 s)
//
// R3 measured `"a** * "`×2000 at 1,999 steps with and 1,999,000 without. It is **0 and 0** here,
// because R3's other fix removes it: a closer that cannot also open leaves the delimiter list as
// soon as it fails, so the 2,000 closers in that input never accumulate for anyone to scan past.
// R3's two inputs therefore test the removal rule, which is worth testing, but they cannot fail if
// `openers_bottom` is deleted. The third input below is the one that can: its `**` closers CAN also
// open (they sit between two letters), so they stay on the list, and every one of them is refused by
// the rule of three against every `*` before it (1 + 2 = 3) — a scan that is exactly quadratic
// without the bound, and 1.5 steps per repetition with it.
//
// The `"a* "` case guards something else entirely, and is kept for it: if the backward scan walked
// the TOKEN array instead of the delimiter list, `openers_bottom` would not bound it at all, and an
// array-based implementation measured **1.235 s** on this input (30 KB) and 5.05 s at double the
// size — 4× input for 16× time, past this ceiling, with zero backward *delimiter* steps taken. The
// cost was pure token traversal, invisible to reading and to any step counter.
measureRender("a** * ×2000 (failed closers leave the list)", ceiling: 1.0, String(repeating: "a** * ", count: 2_000))
measureRender("a* ×10000 (30 KB of failed closers)", ceiling: 1.0, String(repeating: "a* ", count: 10_000))
measureRender("a*a **×4000 (24 KB, the shape openers_bottom bounds)", ceiling: 1.0, String(repeating: "a*a **", count: 4_000))

// MARK: - Summary

print("\n==================================")
if failureCount == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failureCount) TEST(S) FAILED")
    exit(1)
}
