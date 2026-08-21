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

/// Per-column horizontal alignment declared by a GFM table's delimiter row ((preview-tables)):
/// `---` / `:---` → `.leading`, `---:` → `.trailing`, `:---:` → `.center`. Deliberately NOT
/// `NSTextAlignment`: the block model is pure `Foundation`-shaped data with no AppKit in it, so the
/// mapping to a paragraph style's `alignment` lives in the Tier-3 emitter (`textAlignment(for:)`).
enum MarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

/// The internal block model produced by `MarkdownBlockParser`. Every case carries `line` — the
/// 0-based source line of the block's first line — which becomes the emitted anchor's `sourceLine`
/// unchanged. `marker` on `.listItem` is the *rendered* prefix glyph run (`•`, or `"3."` for
/// ordered items): baking the glyph into the parser is an accepted v1 simplification (a future
/// glyph change touches the parser + tests, not just the emitter).
///
/// `.table` ((preview-tables)) carries the header row's cells, the body rows, and one alignment per
/// column. Its `line` is the **header row's** source line — a table emits exactly ONE anchor no
/// matter how many rows it has (SPEC §8.3), so `line` is neither the delimiter row's nor any body
/// row's. Three invariants hold for every `.table` the parser produces, and the emitter depends on
/// all three: `header.count >= 1`, `alignments.count == header.count` (the delimiter row is
/// normalized to the header's column count at parse time — an un-normalized short delimiter row
/// would index out of range in the emitter and trap on the background render queue), and every
/// element of `rows` has exactly `header.count` cells (short rows padded, long rows' surplus
/// re-joined into the last cell — never truncated). The delimiter row itself is consumed and is not
/// represented here at all.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String, line: Int)
    case paragraph(text: String, line: Int)
    case listItem(marker: String, text: String, line: Int)
    case blockquote(text: String, line: Int)
    case codeBlock(code: String, line: Int)
    case rule(line: Int)
    case table(header: [String], rows: [[String]], alignments: [MarkdownTableAlignment], line: Int)

    /// The 0-based source line of this block's first line (its anchor's `sourceLine`).
    var line: Int {
        switch self {
        case let .heading(_, _, line): return line
        case let .paragraph(_, line): return line
        case let .listItem(_, _, line): return line
        case let .blockquote(_, line): return line
        case let .codeBlock(_, line): return line
        case let .rule(line): return line
        case let .table(_, _, _, line): return line
        }
    }
}

/// The block-level parser for the SPEC §8.2 Markdown subset. Splits the source on `\n` (a trailing
/// `\r` per line is stripped, so CRLF input parses identically), runs a fence state machine, and
/// classifies each line in the fixed precedence order of the plan's criterion 8:
///
///   already-consumed table row → inside-fence state → fence open → blank → heading → horizontal
///   rule → blockquote → list item → pipe table → list-item continuation → paragraph continuation
///
/// Paragraphs merge consecutive non-blank lines with a single space; blockquotes merge consecutive
/// `>` lines joined with `\n`. A list item merges the *indented* lines that follow it — see
/// `isListItemContinuation` for the two-part test and `flushListItem` for the joining rule — which
/// is (preview-bold-spans) cause 1: before it, a wrapped item's second line started a new block and
/// split any `**…**` span across two blocks, so each half held an unpaired `**`. Pure
/// `Foundation`-only code — no AppKit, no shared mutable state.
///
/// The pipe-table step ((preview-tables)) sits at **7.5** — after the list item, ahead of the
/// list-item continuation. That position is a deliberate interaction with (preview-bold-spans), not
/// an accident of ordering: it means an *indented* table directly under a bullet (this repo's own
/// `SPEC.md:123-128`, six rows indented two spaces under `- Token classes and light-theme colors:`)
/// becomes a **table** rather than being merged into the bullet's text. Running it after the list
/// item, in turn, keeps `- a | b` a list item.
enum MarkdownBlockParser {
    static func parse(_ source: String) -> [MarkdownBlock] {
        // Split on `\n` only (project-wide logical-line convention, see `LogicalLine`), stripping a
        // single trailing `\r` per line so CRLF documents parse identically to LF ones.
        let lines = source
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }

        var blocks: [MarkdownBlock] = []

        // Paragraph accumulator (space-joined). Mutually exclusive with the quote and list-item
        // accumulators: starting any one of the three flushes the other two, so at most one is ever
        // active.
        var paragraphLines: [String] = []
        var paragraphStart = 0
        var inParagraph = false

        // Blockquote accumulator (`\n`-joined; a bare `>` contributes an empty line).
        var quoteLines: [String] = []
        var quoteStart = 0
        var inQuote = false

        // List-item accumulator ((preview-bold-spans) cause 1): the item's own text from
        // `parseListItem`, followed by the raw text of every indented continuation line. Joined by
        // `flushListItem`.
        //
        // WHY THIS ONE IS DANGEROUS, spelled out because the failure is silent: before this item,
        // step 7 did `blocks.append` INLINE, so `blocks` was in source order by construction. An
        // accumulator emits at FLUSH time instead, so any step that starts a block and forgets to
        // flush this one emits blocks OUT OF SOURCE ORDER — `- a` followed by `> q` with step 6 not
        // flushing yields `[.blockquote(line: 1), .listItem(line: 0)]`. That trips
        // `MarkdownRenderer.assertStrictlyAscending` in debug and, because `assert` compiles out,
        // silently breaks §8.3 scroll sync in release. Steps 2-7, **step 7.5** ((preview-tables), the
        // newest one to inherit the obligation), step 9 and the EOF flush must each call
        // `flushListItem()`; steps 0 and 1 need not — step 0 emits nothing at all, and opening a
        // fence (step 2) already flushed before step 1 could be reached.
        var listItemLines: [String] = []
        var listItemMarker = ""
        var listItemStart = 0
        var inListItem = false

        // Fence accumulator (verbatim, `\n`-joined). While active, every line except a closing
        // fence is taken literally.
        var fenceLines: [String] = []
        var fenceStart = 0
        var inFence = false

        // (preview-tables) Index of the first line NOT yet consumed by a table. `enumerated()`
        // cannot skip, so step 7.5 — which reads a table's whole extent forward in ONE iteration —
        // records where it stopped here and step 0 below drops every line up to it.
        //
        // **This is NOT a fifth accumulator, and that is the whole of this item's answer to the
        // flush-order obligation `adv-review-edge` left open.** It holds no content, emits nothing,
        // and is never "pending": step 7.5 appends its `.table` INLINE, exactly as steps 4/5 append
        // their heading/rule. So the accumulator set is unchanged at four (paragraph, quote, list
        // item, fence), at most one is still ever active, and the existing proof carries over
        // verbatim rather than needing a new one. What step 7.5 DOES inherit is the obligation every
        // inline-appending step already carries: flush the three line-oriented accumulators BEFORE
        // appending, or a table starting at line 5 lands in `blocks` ahead of the list item that
        // started at line 4, `MarkdownRenderer.assertStrictlyAscending` trips in debug, and — since
        // `assert` compiles out — §8.3's binary search silently reads a non-monotonic array in
        // release. The fence accumulator needs no flush here because step 1 `continue`s while
        // `inFence`, so step 7.5 is unreachable with a fence open.
        var skipUntilIndex = 0

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

        func flushListItem() {
            guard inListItem else { return }
            // (preview-bold-spans) joining rule, criteria 2/3/9. A SINGLE-line item keeps
            // `parseListItem`'s text byte-for-byte, so `- a ` still yields `"a "`: an item that was
            // never continued must not silently lose a trailing space it has always kept. A
            // CONTINUED item trims every segment on both sides, drops the empty ones, and joins with
            // exactly one space. The trim is what strips the continuation line's leading indent (the
            // repro's `"  fires]**"`); joining trimmed segments — rather than joining raw ones — is
            // what stops a segment that already ends in a space from producing a double space (the
            // repro's `"(shipped   2026-08-21"`); and dropping empties is what makes `- \n  foo`
            // yield `"foo"` rather than `" foo"`. Paragraph joining above is deliberately unchanged.
            let text: String
            if listItemLines.count == 1 {
                text = listItemLines[0]
            } else {
                // `.lazy` is load-bearing for MEMORY, not style (adv-review-edge finding 2). Without
                // it, `.map` materialises a second N-element `[String]` and `.filter` a third before
                // `joined` ever runs — three allocations where `flushParagraph` above does one.
                // Measured with `/usr/bin/time -l` on a pathological but reachable source (one
                // bullet followed by 400,000 indented lines, ~30 MB): parse-attributable peak RSS
                // was 145.2 MB eager vs 89.9 MB at HEAD — **1.62x**, +55 MB — and adding `.lazy`
                // brings it back to 88.5 MB, i.e. HEAD's footprint, with byte-identical output. The
                // preview renders the whole buffer with no size cap and SPEC §7's open cap is
                // 100 MB, so the eager form's transient scales to ~185 MB against a documented
                // steady-state band of 80-190 MB that SPEC §1 says to add nothing to.
                text = listItemLines
                    .lazy
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            blocks.append(.listItem(marker: listItemMarker, text: text, line: listItemStart))
            listItemLines.removeAll()
            inListItem = false
        }

        for (index, line) in lines.enumerated() {
            // 0. (preview-tables) A line already consumed as a table row. Placed ahead of the fence
            //    state deliberately, and it is safe there: a table is only ever recognized while
            //    `inFence` is false, and step 7.5's consumption stops at any line that opens a fence
            //    (a `|`-leading line cannot be a fence open, since `isFenceOpen` counts backticks at
            //    column 0), so skipped lines can never carry fence state past this point.
            if index < skipUntilIndex {
                continue
            }

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
                flushListItem()
                fenceStart = index
                inFence = true
                continue
            }

            // 3. Blank line — terminates a pending paragraph, blockquote or list item; emits nothing
            //    itself. Running before the continuation step is what keeps a whitespace-only line
            //    out of `isListItemContinuation` (which would otherwise accept it: it is indented,
            //    and `""` starts no block) — but only for `isBlank`'s notion of blank, which is
            //    `CharacterSet.whitespaces`. That set excludes VT (U+000B), FF (U+000C), CR
            //    (U+000D), NEL (U+0085) and LSEP (U+2028), so a line of space-then-form-feed looks
            //    blank to a human, is NOT blank here, and is absorbed into an open item with the
            //    control character carried into its text (adv-review-edge finding 4). Left as-is
            //    deliberately: matching a human's idea of "blank" would mean changing `isBlank`,
            //    which every block type consults, for input a Markdown file realistically never
            //    contains. Recorded rather than fixed so the gap is known and not re-derived.
            if isBlank(line) {
                flushParagraph()
                flushQuote()
                flushListItem()
                continue
            }

            // 4. ATX heading.
            if let heading = parseHeading(line) {
                flushParagraph()
                flushQuote()
                flushListItem()
                blocks.append(.heading(level: heading.level, text: heading.text, line: index))
                continue
            }

            // 5. Horizontal rule — checked before the list item so `---`/`***` are rules while
            //    `- item`/`* item` remain list items.
            if isRule(line) {
                flushParagraph()
                flushQuote()
                flushListItem()
                blocks.append(.rule(line: index))
                continue
            }

            // 6. Blockquote — a `>` line ends a paragraph or list item but continues/starts a quote
            //    block.
            if line.first == ">" {
                flushParagraph()
                flushListItem()
                if !inQuote {
                    inQuote = true
                    quoteStart = index
                }
                quoteLines.append(stripQuoteMarker(line))
                continue
            }

            // 7. List item (unordered `- * +` or ordered `N.`/`N)`). Starts the accumulator instead
            //    of appending directly, so the indented lines step 8 collects can still join it.
            //    Flushing first is what makes a run of `- a\n- b` two items rather than one.
            if let item = parseListItem(line) {
                flushParagraph()
                flushQuote()
                flushListItem()
                listItemMarker = item.marker
                listItemStart = index
                listItemLines = [item.text]
                inListItem = true
                continue
            }

            // 7.5. (preview-tables) A GFM pipe table: this line contains a `|` AND the next line is
            //      a delimiter row. The delimiter row's own `|` requirement is enforced inside
            //      `tableDelimiterAlignments` and is load-bearing — without it a bare `---` splits
            //      into the single cell `["---"]`, matches `-+`, qualifies, and a horizontal rule
            //      following any line that happens to contain a pipe silently disappears into a
            //      one-column table.
            //
            //      The whole table is read forward HERE, in one iteration, and appended inline —
            //      see `skipUntilIndex` above for why that is what keeps this item from adding a
            //      fifth accumulator. The three flushes below are what keep `blocks` in source
            //      order; dropping any one of them puts this table ahead of a block that started on
            //      an earlier line.
            if line.contains("|"),
               index + 1 < lines.count,
               let delimiterAlignments = tableDelimiterAlignments(lines[index + 1]),
               // (preview-tables, adv-review-edge finding 1) THE CELL BUDGET, and it is a
               // correctness guard, not a nicety. The header alone fixes the column count, and a
               // body row as short as a single `|` is padded to full width — so the produced cell
               // count is `columns x (rows + 1)` while the SOURCE is only `O(columns + rows)`
               // bytes. The emitter allocates an `NSTextTableBlock` and an
               // `NSMutableParagraphStyle` per cell, so the blow-up is quadratic in both memory
               // and time. Measured: 1001 columns over 1000 single-`|` rows is a **3,009-byte**
               // document that produces 1,001,000 cells, 2.66 s of render and **944.6 MB** peak
               // RSS; one more octave (a 12 KB file) extrapolates to ~15 GB, i.e. an OOM kill.
               // Nothing stops such a file being opened — SPEC §7's cap is 100 MB — and it need
               // not be adversarial: a CSV export with a wide header and trailing empty fields
               // dropped has exactly this shape. Over budget the construct is simply NOT a table
               // and falls through to paragraph continuation, which is byte-for-byte what HEAD did
               // with it, so the worst case is "no better than before", never a hang. The budget is
               // checked BEFORE any row is split, so the guard itself allocates nothing per cell.
               tableFitsCellBudget(lines: lines, headerIndex: index) {
                flushParagraph()
                flushQuote()
                flushListItem()

                // The HEADER fixes the column count — the only honest source for it, since widening
                // to the widest row would invent columns the document never declared. It always
                // yields at least one cell (`splitTableCells` never returns an empty array), so
                // `columnCount >= 1` and the emitter's per-column indexing is total.
                let header = splitTableCells(line).map { $0.trimmingCharacters(in: .whitespaces) }
                let columnCount = header.count

                // Normalized to the header's column count in BOTH directions. Padding is the
                // critical half — a short delimiter row (`| a | b | c |` over `| --- |`) is
                // deliberately accepted, and leaving `alignments` short would index out of range in
                // the emitter, i.e. a trap on `MarkdownPreviewView`'s background render queue rather
                // than a glitch. Truncation of a LONG delimiter row loses no document text (an
                // alignment is not content), so unlike a long body row it is simply dropped.
                var alignments = delimiterAlignments
                if alignments.count > columnCount {
                    alignments.removeLast(alignments.count - columnCount)
                } else if alignments.count < columnCount {
                    alignments.append(
                        contentsOf: repeatElement(.leading, count: columnCount - alignments.count)
                    )
                }

                var rows: [[String]] = []
                var rowIndex = index + 2 // the first line after the delimiter row
                while rowIndex < lines.count, continuesTable(lines[rowIndex]) {
                    rows.append(normalizedTableRow(splitTableCells(lines[rowIndex]), columnCount: columnCount))
                    rowIndex += 1
                }

                blocks.append(.table(header: header, rows: rows, alignments: alignments, line: index))
                // Header, delimiter row and every consumed body row are now spoken for. `rowIndex`
                // is always >= index + 2, so this always advances past at least the delimiter row
                // and the loop can never re-enter step 7.5 on the same header.
                skipUntilIndex = rowIndex
                continue
            }

            // 8. Continuation of an open list item — an indented line whose trimmed form starts no
            //    block of its own. Placed after step 7 so an UNINDENTED sibling item still starts a
            //    new item, and before step 9 so a wrapped item's tail no longer becomes a paragraph.
            if inListItem, isListItemContinuation(line) {
                listItemLines.append(line)
                continue
            }

            // 9. Paragraph continuation — a non-`>` text line ends a quote or list item and
            //    extends/starts a paragraph.
            flushQuote()
            flushListItem()
            if !inParagraph {
                inParagraph = true
                paragraphStart = index
            }
            paragraphLines.append(line)
        }

        // EOF: flush whatever is pending. At most one accumulator is active, but flushing all four
        // unconditionally is safe. Flushing the list item here is what makes the commonest real case
        // — a file whose last line is a wrapped bullet — come out as one item (criterion 8). An
        // unterminated fence renders its collected content. There is deliberately nothing to flush
        // for (preview-tables): a table open at EOF was already appended by step 7.5 in the
        // iteration that read its header, so this sequence stays exactly four calls long.
        flushParagraph()
        flushQuote()
        flushListItem()
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

    // MARK: - GFM pipe tables ((preview-tables))

    /// The per-column alignments a GFM delimiter row declares, or nil if `line` is not one.
    ///
    /// **The `contains("|")` guard is the single most load-bearing line in this item**, and its
    /// absence was a critical finding against the plan's first revision. Without it a bare `---`
    /// strips to the one cell `["---"]`, matches `-+`, and qualifies as a delimiter row — so
    ///
    ///     Use the `a | b` syntax.
    ///     ---
    ///     Next section.
    ///
    /// becomes a **one-column** table and **the horizontal rule silently disappears**. (Rev 1 of the
    /// plan described this as "a two-column table with a shredded code span" — that was true when
    /// cells split on raw `|`, and is stale now that `splitTableCells` ignores pipes inside backtick
    /// pairs: the code span survives whole and yields a single cell. Measured against a
    /// guard-removed mutant. The rule-vanishing half, which is the part that matters, is unchanged.)
    /// The same shape swallows YAML front matter (`---` / `title: A | B` / `---`).
    /// With the guard, `---` has no pipe, is rejected here, reaches step 5, and stays a `.rule`.
    ///
    /// Every cell must match `:?-+:?` after trimming (see `delimiterCellAlignment`), so an empty
    /// cell — `| --- | | --- |` — disqualifies the whole row, matching GFM. Cell splitting goes
    /// through `splitTableCells` so the delimiter row is counted with exactly the same rule as the
    /// header; its backtick handling is inert here, because a cell containing a backtick cannot
    /// match `:?-+:?` anyway.
    private static func tableDelimiterAlignments(_ line: String) -> [MarkdownTableAlignment]? {
        guard line.contains("|") else { return nil }
        var alignments: [MarkdownTableAlignment] = []
        for cell in splitTableCells(line) {
            guard let alignment = delimiterCellAlignment(cell) else { return nil }
            alignments.append(alignment)
        }
        // `splitTableCells` never returns an empty array, so this is non-empty whenever every cell
        // matched — but a table with zero columns must be unrepresentable, so it is checked, not
        // assumed.
        return alignments.isEmpty ? nil : alignments
    }

    /// One delimiter cell: `:?-+:?` with surrounding whitespace allowed. `:---` → `.leading`,
    /// `---:` → `.trailing`, `:---:` → `.center`, plain `---` → `.leading` (GFM's default). At
    /// least one `-` is required, so `:`, `::` and `""` are all rejected. A single `-` is accepted
    /// (GFM proper wants three); that is the plan's stated `:?-+:?` and it is deliberately looser.
    private static func delimiterCellAlignment(_ cell: String) -> MarkdownTableAlignment? {
        var body = cell.trimmingCharacters(in: .whitespaces)[...]
        let hasLeadingColon = body.first == ":"
        if hasLeadingColon { body = body.dropFirst() }
        let hasTrailingColon = body.last == ":"
        if hasTrailingColon { body = body.dropLast() }
        guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        switch (hasLeadingColon, hasTrailingColon) {
        case (true, true): return .center
        case (false, true): return .trailing
        case (true, false), (false, false): return .leading
        }
    }

    /// Splits a table row into its **raw, untrimmed** cell segments: outer whitespace and one
    /// optional leading and trailing `|` are removed, then the remainder is split on every `|` that
    /// lies **outside a backtick pair**. Always returns at least one segment (a row of `"|"` alone
    /// yields `[""]`), which is what makes `header.count >= 1` — and therefore the emitter's
    /// per-column indexing — total.
    ///
    /// **Untrimmed on purpose.** `normalizedTableRow` re-joins a long row's surplus segments with
    /// `|` before trimming, so the surplus comes back byte-for-byte including its interior spacing;
    /// trimming here first would silently reformat text the item promises never to lose.
    ///
    /// **Backtick pairing, and why it is not a naive toggle.** Splitting on raw `|` shreds
    /// `` `a | b` ``, the commonest cell in developer docs. But an *unclosed* backtick must not
    /// protect the rest of the row either, because `MarkdownInlineParser` — which renders the cell —
    /// treats an unclosed backtick as a literal character. The two must agree or the split and the
    /// render disagree about where a code span is. That parser pairs backticks 1-2, 3-4, … and
    /// leaves a final odd one literal, so this counts the backticks in one pass and skips the toggle
    /// on the last one when the count is odd. Equivalent to the parser's rule, O(n), and it needs no
    /// auxiliary index array — which is a modest allocation saving in the spirit of SPEC §1, not a
    /// rule §1 imposes. (§1 states a memory-footprint goal; it does not forbid a data structure. The
    /// earlier wording here claimed it did.)
    ///
    /// This is a deliberate divergence from GFM proper, which splits cells before any inline
    /// parsing and therefore *does* let a pipe inside backticks break a cell; `\|` remains the only
    /// escape GFM offers and this subset supports neither it nor GFM's behaviour here.
    private static func splitTableCells(_ line: String) -> [String] {
        let characters = Array(line.trimmingCharacters(in: .whitespaces))
        var start = 0
        var end = characters.count
        if start < end, characters[start] == "|" { start += 1 }
        if end > start, characters[end - 1] == "|" { end -= 1 }

        var backtickCount = 0
        var index = start
        while index < end {
            if characters[index] == "`" { backtickCount += 1 }
            index += 1
        }
        let lastBacktickIsLiteral = backtickCount % 2 == 1

        // Cells are cut as SLICES of `characters` rather than accumulated into a second character
        // buffer. `cells` itself is of course allocated; what is avoided is a second line-sized
        // *character* array alongside it. Same instinct as `flushListItem`'s `.lazy`, whose comment
        // records that a redundant per-row allocation there measured +55 MB peak RSS — a reason to
        // prefer this shape, not a constraint SPEC §1 imposes.
        var cells: [String] = []
        var cellStart = start
        var seenBacktickCount = 0
        var insideCodeSpan = false
        index = start
        while index < end {
            let character = characters[index]
            if character == "`" {
                seenBacktickCount += 1
                if !(lastBacktickIsLiteral && seenBacktickCount == backtickCount) {
                    insideCodeSpan.toggle()
                }
            } else if character == "|", !insideCodeSpan {
                cells.append(String(characters[cellStart..<index]))
                cellStart = index + 1
            }
            index += 1
        }
        cells.append(String(characters[cellStart..<end]))
        return cells
    }

    /// Fits a body row's raw segments to the header's column count, then trims each cell.
    ///
    /// **Short rows are padded; long rows are NEVER truncated.** The plan's first revision said
    /// "padded or truncated", which is real data loss on real input: this repo's own
    /// `plans/syntax-highlighting.plan.md:52` is a four-column row carrying 70 pipes — 68 of them
    /// interior, of which **65 are inside the regex cell** and 3 are the structural separators
    /// (counted, after review flagged the earlier wording as attributing all 68 to the cell) —
    /// giving 69 raw segments, and truncating to four cells would have deleted the Swift keyword list
    /// from the preview — strictly worse than the run-on paragraph this item exists to fix. (With
    /// `splitTableCells`' backtick rule that particular line now yields exactly 4 segments and never
    /// reaches the surplus path at all, but the guarantee has to hold for the unbackticked case too.)
    /// A long row's surplus segments are re-joined into the LAST cell with their `|` separators
    /// restored, **before** trimming, so the rejoined text is byte-identical to the source's
    /// remainder rather than a re-spaced approximation of it.
    private static func normalizedTableRow(_ segments: [String], columnCount: Int) -> [String] {
        var cells = segments
        if cells.count > columnCount {
            // `columnCount >= 1` (the header always yields at least one cell) and
            // `cells.count > columnCount`, so this range is non-empty and in bounds.
            let surplus = cells[(columnCount - 1)...].joined(separator: "|")
            cells.removeSubrange((columnCount - 1)...)
            cells.append(surplus)
        } else if cells.count < columnCount {
            cells.append(contentsOf: repeatElement("", count: columnCount - cells.count))
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Does `line` continue an already-open table? Two tests: it contains a `|`, and it does not
    /// start a block of a **different** kind. (The plan states the rule in three parts — non-blank,
    /// contains a pipe, not a block starter — but a blank line contains no pipe, so `contains`
    /// subsumes the first and it is deliberately not spelled separately.)
    ///
    /// **The `|` exception to `startsBlock` is deliberate, and it is the seam where this item meets
    /// the guard (preview-bold-spans) left behind.** `startsBlock` reports a `|`-leading line as a
    /// block starter, and that clause is KEPT (see its doc comment for why removing it would
    /// regress non-qualifying pipe lines back into the bullet above them). But asking it unmodified
    /// here would make every ordinary `| a | b |` row "start a block" and stop consumption dead: a
    /// table would never be more than its header and delimiter row, and every body row would fall
    /// through to a paragraph — the reported bug, one line later. So a `|`-leading line is answered
    /// here directly as "this is my own next row", and `startsBlock` is consulted only for the rest.
    /// That is exactly the plan's five-way test (fence open / heading / rule / `>` / list item)
    /// without duplicating the predicate, and it is why `> Note: \`|\` is the pipe character.` ends
    /// a table and is reclassified as a blockquote while a row whose first cell happens to hold a
    /// triple backtick stays a table row (a `|`-leading line is not a fence open).
    ///
    /// The argument handed to `startsBlock` has its leading whitespace stripped and its trailing
    /// whitespace preserved, which both of those functions' doc comments record as load-bearing.
    /// (preview-tables, adv-review-edge finding 1) The most cells one table may produce.
    ///
    /// 50,000 — deliberately the **same number SPEC §5.2 already declares** for a scanned root's
    /// tree, because this project's convention is to bound a derived structure and say so rather
    /// than let it grow with the input. It is a budget on `columns x (rows + 1)`, which is the
    /// quantity that actually drives allocation: one `NSTextTableBlock` plus one
    /// `NSMutableParagraphStyle` per cell, measured at ~371 bytes of retained RSS each.
    ///
    /// What it costs, and what it buys. At the cap a table is ~18 MB of retained storage — real,
    /// but bounded, against the 80-190 MB band SPEC §1 says to add nothing to. It comfortably
    /// admits every table anyone actually writes: 10 columns x 5,000 rows, or 5 x 10,000, or
    /// 100 x 500. What it rejects is the degenerate shape where a wide header multiplies against
    /// rows that carry almost no text — the 3 KB / 1,001,000-cell / 945 MB case in
    /// `MarkdownBlockParser.parse`'s step 7.5.
    static let tableCellLimit = 50_000

    /// Would the table starting at `headerIndex` stay inside `tableCellLimit`?
    ///
    /// Counts the rows it *would* consume by walking `continuesTable` forward — line tests only, no
    /// cell splitting, no allocation per cell — then compares against the budget. Splitting first
    /// and measuring afterwards would already have paid the cost the budget exists to avoid.
    ///
    /// The comparison is written as a division rather than `columnCount * (rowCount + 1)` so it
    /// cannot itself overflow on a pathological document: both factors are bounded by the line
    /// count, and their product is not.
    private static func tableFitsCellBudget(lines: [String], headerIndex: Int) -> Bool {
        let columnCount = splitTableCells(lines[headerIndex]).count
        guard columnCount > 0 else { return true }

        var rowIndex = headerIndex + 2
        while rowIndex < lines.count, continuesTable(lines[rowIndex]) {
            rowIndex += 1
        }
        let rowCount = rowIndex - (headerIndex + 2)
        return rowCount + 1 <= tableCellLimit / columnCount
    }

    private static func continuesTable(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let stripped = leadingWhitespaceStripped(line)
        if stripped.first == "|" { return true }
        return !startsBlock(stripped)
    }

    /// Does this **leading-whitespace-stripped** line open a block in its own right — a fence, an
    /// ATX heading, a horizontal rule, a blockquote, or a list item?
    ///
    /// A named helper rather than a test inlined into `isListItemContinuation`, so that
    /// `(preview-tables)`'s table-row continuation test can call it too rather than growing a second
    /// copy of this predicate. It now has **two** callers: `isListItemContinuation` below and
    /// `continuesTable` above.
    ///
    /// **The argument must have its LEADING whitespace stripped, and its TRAILING whitespace left
    /// alone.** Both halves are load-bearing, and the second was a real shipped bug caught in
    /// review. Leading: every classifier consulted here is anchored at column 0
    /// (`parseHeading`/`isRule`/`parseListItem` all read `characters.first`; `isFenceOpen` counts
    /// leading backticks), so a raw indented line answers "starts no block" for `  - b` and the
    /// caller swallows a nested sub-bullet into its parent — the `SPEC.md:68-70` regression
    /// criterion 5 pins. Trailing: `parseListItem` and `parseHeading` both require a space or tab
    /// **after** the marker, so trimming the right-hand end destroys the very character they test
    /// for — a marker-only line like `"  - "` or `"  # "` becomes `"-"` / `"#"`, fails those
    /// classifiers, and is absorbed into the parent item. `isRule` strips its own trailing
    /// whitespace (see its implementation) and `isFenceOpen` only counts leading backticks, so
    /// neither is affected either way; the hole is exactly the two marker-plus-space classifiers.
    ///
    /// See `leadingWhitespaceStripped` for why the caller's notion of whitespace must match
    /// `flushListItem`'s exactly.
    ///
    /// **A `|`-leading line counts as starting a block.** (preview-bold-spans) added this as a
    /// hold-the-line guard: without it, `SPEC.md:123-128`'s own six-row table — indented two spaces
    /// under `- Token classes and light-theme colors:` — would be absorbed into that bullet, turning
    /// a table that then rendered as (ugly but complete) paragraph text into a run-on glued onto a
    /// list item. Measured across this repo at that time: `SPEC.md` would drop 183 to 182 blocks,
    /// `plans/cli-open.plan.md` 297 to 212.
    ///
    /// **(preview-tables) deliberately KEPT it rather than replacing it, reversing the intent this
    /// comment used to record.** Once step 7.5 runs ahead of the continuation branch, a *qualifying*
    /// table — one with a delimiter row under its header — is consumed as a `.table` before this
    /// predicate is ever consulted, so the clause no longer governs those lines at all. What it
    /// still governs is a `|` line that does **not** qualify, and for exactly those the item's
    /// contract is "keeps rendering as it does today". Deleting the clause would send a
    /// non-qualifying pipe line into the bullet above it — a regression this item is not entitled
    /// to ship. The one caller for which the clause is wrong is `continuesTable`, which answers a
    /// `|`-leading line itself before asking; see its doc comment.
    ///
    /// A blank line is deliberately NOT reported as a block starter (`""` opens nothing). That is
    /// only safe because the blank-line step runs ahead of every continuation test and has already
    /// flushed by the time this is reached.
    private static func startsBlock(_ trimmed: String) -> Bool {
        if isFenceOpen(trimmed) { return true }
        if parseHeading(trimmed) != nil { return true }
        if isRule(trimmed) { return true }
        if trimmed.first == ">" { return true }
        if parseListItem(trimmed) != nil { return true }
        // (preview-tables) kept this clause — see the doc comment above. A qualifying table never
        // reaches here (step 7.5 consumed it); this keeps a NON-qualifying pipe row out of the
        // parent bullet so it renders exactly as it did before tables existed.
        if trimmed.first == "|" { return true }
        return false
    }

    /// Does `line` continue an already-open list item? BOTH halves are load-bearing, and both are
    /// deliberate departures from CommonMark recorded in (preview-bold-spans)'s `## Decisions taken`:
    ///
    /// 1. **It must be indented.** CommonMark's *lazy* continuation — any non-blank line continues an
    ///    open item — would turn `- a\nb` from item + paragraph into a single item (criterion 4).
    ///    Requiring indentation confines this change's whole blast radius to genuinely wrapped items.
    /// 2. **Its trimmed form must start no block.** Without this, `  - b` under an open `- a` would
    ///    be swallowed, and `SPEC.md:68-70`'s indented sub-bullets would collapse into one run-on
    ///    line with literal `-` separators. Nested lists being a SPEC §8.2 non-goal licenses not
    ///    rendering them specially; it does not license rendering them worse than before
    ///    (criterion 5).
    ///
    /// Any depth of indentation counts — the parser carries no column model, and the item a
    /// continuation belongs to is simply the one currently open.
    private static func isListItemContinuation(_ line: String) -> Bool {
        guard let first = line.first, first == " " || first == "\t" else { return false }
        return !startsBlock(leadingWhitespaceStripped(line))
    }

    /// Strips the **leading** run of `CharacterSet.whitespaces` and nothing else — the exact
    /// operation `startsBlock` requires, and the reason it is a named function rather than a closure
    /// is that BOTH of its properties were separately gotten wrong and caught in review.
    ///
    /// **Leading, because `startsBlock`'s classifiers are anchored at column 0.** Handing them a raw
    /// indented line answers "starts no block" for `  - b`, and the caller swallows a nested
    /// sub-bullet into its parent.
    ///
    /// **Not trailing, because `parseListItem` and `parseHeading` require a space or tab AFTER the
    /// marker.** Trimming the right-hand end destroys the very character they test for, so `"  - "`
    /// becomes `"-"`, fails their `count >= 2` guard, and is absorbed. That was a shipped defect in
    /// this item's first draft.
    ///
    /// **`CharacterSet.whitespaces`, not just space and tab** — this is the subtle one, and the
    /// naive `{" ", "\t"}` version was the *second* defect, introduced by the fix for the first.
    /// `flushListItem` trims each segment with `CharacterSet.whitespaces`, which contains 17 further
    /// space characters (U+00A0 NBSP, U+1680, U+2000-U+200B, U+202F, U+205F, U+3000). If this
    /// stripper recognised fewer of them than that trim does, `"  \u{00A0}- x"` would keep its NBSP
    /// here, report "starts no block", be accepted as a continuation — and then the flush would
    /// delete the NBSP anyway, collapsing a sub-bullet into its parent as `"a - x"`. Exactly the
    /// regression this predicate exists to prevent, reachable by Option+Space on macOS and by any
    /// paste from a web page or Word. **The two notions of whitespace must agree; the guard is only
    /// ever as strong as the weaker one.**
    private static func leadingWhitespaceStripped(_ line: String) -> String {
        let scalars = line.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex, CharacterSet.whitespaces.contains(scalars[index]) {
            index = scalars.index(after: index)
        }
        return String(String.UnicodeScalarView(scalars[index...]))
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

    /// Table cell border width, in points ((preview-tables)). A table is the one block whose
    /// geometry the renderer does NOT compute: `NSTextTable.automaticLayoutAlgorithm` derives the
    /// column widths from the container, which is what lets a wide table fit the preview's narrow
    /// (~332pt) column by wrapping *inside* a cell instead of overflowing a scroller the preview
    /// does not have (`MarkdownPreviewView` sets `hasHorizontalScroller = false`,
    /// `isHorizontallyResizable = false`, `widthTracksTextView = true`).
    static let tableBorderWidth: CGFloat = 1

    /// Gap between a table cell's border and its text, in points.
    static let tableCellPadding: CGFloat = 4

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

        case let .table(header, rows, alignments, _):
            emitTable(header: header, rows: rows, alignments: alignments, into: output)
        }
    }

    // MARK: - Table emission ((preview-tables))

    /// Emits one `.table` block as a real `NSTextTable` grid: one `NSTextTableBlock` per cell,
    /// carried on that cell's paragraph style, with the header row bold.
    ///
    /// **Internal rather than `private` for exactly one reason**: the assertion harness's
    /// `ReferenceRenderer.emit` is an exhaustive `switch` over `MarkdownBlock` with no `default`, so
    /// adding a case here is a compile error there. It delegates `.table` to this function instead
    /// of growing a second copy. The consequence, stated rather than discovered: the differential
    /// fuzz oracle is **vacuous for tables**. That costs nothing, because both fuzz alphabets are
    /// `["[", "]", "(", ")", "a", "*", "`", " "]` and `["a", "*", " "]` — neither contains a `|` or
    /// a newline, so a table was never inside that oracle's reach in the first place.
    ///
    /// One cell is one paragraph: the cell's inline content followed by a `\n` that carries the same
    /// paragraph style, so an EMPTY cell is still a real cell (a lone styled `\n`) rather than a
    /// missing column. Every cell terminating in `\n` is also what keeps the table self-contained —
    /// the block separator `render` appends after it lands in its own, block-less paragraph and can
    /// never be pulled inside the grid.
    static func emitTable(
        header: [String],
        rows: [[String]],
        alignments: [MarkdownTableAlignment],
        into output: NSMutableAttributedString
    ) {
        let table = NSTextTable()
        table.numberOfColumns = header.count
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.hidesEmptyCells = false
        table.collapsesBorders = true

        emitTableRow(header, rowIndex: 0, isHeader: true, table: table, alignments: alignments, into: output)
        for (offset, row) in rows.enumerated() {
            emitTableRow(row, rowIndex: offset + 1, isHeader: false, table: table, alignments: alignments, into: output)
        }
    }

    private static func emitTableRow(
        _ cells: [String],
        rowIndex: Int,
        isHeader: Bool,
        table: NSTextTable,
        alignments: [MarkdownTableAlignment],
        into output: NSMutableAttributedString
    ) {
        // The header row is BOLD, and that is what makes it distinguishable — the repro's stated
        // expectation. Passing it as `boldFont` too means a `**span**` inside a header cell stays
        // bold rather than silently un-bolding, mirroring how `headingStyle` handles the same case.
        let font = isHeader ? PreviewFont.bodyBold : Theme.bodyFont

        for (column, cell) in cells.enumerated() {
            // `MarkdownBlockParser` guarantees `cells.count == alignments.count` for every row of
            // every `.table` it produces (see the `MarkdownBlock.table` doc comment). The assert is
            // the loud half; the `.leading` fallback exists ONLY so that a hand-built block with
            // mismatched arrays — reachable from a future test, not from the parser — degrades to a
            // left-aligned cell instead of trapping on `MarkdownPreviewView`'s background render
            // queue, which is where an index-out-of-range here would land.
            assert(
                column < alignments.count,
                "a .table row must have exactly as many cells as the block has alignments"
            )
            let alignment = column < alignments.count ? alignments[column] : .leading

            // (adv-review-edge finding 5) `startingColumn` was the one per-column index with no
            // guard: the `.leading` fallback above covers `alignments` only, and
            // `NSTextTableBlock` is not bounded by `table.numberOfColumns`. Unreachable from the
            // parser — which guarantees `cells.count == alignments.count == header.count` — but
            // `emitTable` is `internal` rather than `private` so `ReferenceRenderer` can delegate
            // to it, and a hand-built block whose row is longer than its header would otherwise
            // place a cell outside the declared grid. Clamped for the same reason the alignment is:
            // degrade the layout, never hand AppKit an out-of-grid coordinate on the background
            // render queue.
            let safeColumn = min(column, max(table.numberOfColumns - 1, 0))
            let block = NSTextTableBlock(
                table: table,
                startingRow: rowIndex,
                rowSpan: 1,
                startingColumn: safeColumn,
                columnSpan: 1
            )
            block.setBorderColor(Theme.mutedText)
            block.setWidth(PreviewStyle.tableBorderWidth, type: .absoluteValueType, for: .border)
            block.setWidth(PreviewStyle.tableCellPadding, type: .absoluteValueType, for: .padding)

            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            paragraph.alignment = textAlignment(for: alignment)

            let style = InlineStyle(
                font: font,
                boldFont: PreviewFont.bodyBold,
                italicFont: PreviewFont.bodyItalic,
                color: Theme.text,
                paragraphStyle: paragraph
            )
            emitInline(MarkdownInlineParser.parse(cell), style: style, into: output)
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: font,
                .foregroundColor: Theme.text,
                .paragraphStyle: paragraph,
            ]))
        }
    }

    /// The model → AppKit half of the alignment mapping, kept here so `MarkdownTableAlignment`
    /// itself stays free of AppKit (the block model is pure data; only Tier 3 knows about
    /// `NSTextAlignment`).
    private static func textAlignment(for alignment: MarkdownTableAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: return .left
        case .center: return .center
        case .trailing: return .right
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
