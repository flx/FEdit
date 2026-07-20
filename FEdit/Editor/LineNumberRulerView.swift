//
//  LineNumberRulerView.swift
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

/// A custom vertical `NSRulerView` gutter for `CodeEditorView` (SPEC §6.2): logical line numbers,
/// light-gray background, min 2-digit width that adapts to the document's total line count.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?

    /// (editor-font-zoom) The current editor font size, pushed in by `CodeEditorView` on every
    /// zoom. The gutter number font is `editorFontSize − 3` (floored at 8 pt) — the `−3` offset
    /// reproduces the historical 10-pt gutter at the 13-pt default, and the floor keeps the number
    /// legible at the 8-pt minimum. A change re-measures the gutter width and redraws; the vertical
    /// centering comes from the layout manager's fragment rects, which already reflect the resized
    /// editor font, so numbers re-center for free.
    var editorFontSize: CGFloat = 13 {
        didSet {
            guard editorFontSize != oldValue else { return }
            updateThickness()
            needsDisplay = true
        }
    }

    private var numberFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: max(8, editorFontSize - 3), weight: .regular)
    }

    private let backgroundColor = NSColor(white: 0.95, alpha: 1)
    private let separatorColor = NSColor(white: 0.8, alpha: 1)
    private let numberColor = NSColor.secondaryLabelColor

    private static let horizontalPadding: CGFloat = 4
    private static let minimumDigitCount = 2

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView

        // Tier 2 sets this on its own account (Tier 3 also sets it, idempotently, for its own
        // scroll-position observing — see the DECISION in the plan: reverting either tier must
        // not silently break the other's notification).
        scrollView.contentView.postsBoundsChangedNotifications = true

        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(contentChanged),
            name: NSText.didChangeNotification, object: textView
        )
        center.addObserver(
            self, selector: #selector(contentChanged),
            name: NSView.frameDidChangeNotification, object: textView
        )
        center.addObserver(
            self, selector: #selector(contentChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        updateThickness()
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func contentChanged(_ notification: Notification) {
        updateThickness()
        needsDisplay = true
    }

    /// Called explicitly by `CodeEditorView.updateNSView` after a programmatic file switch — a
    /// programmatic `string =` assignment does not post `NSText.didChangeNotification`, so the
    /// ruler would otherwise not know the document (and its line count) just changed.
    func invalidateLineNumbers() {
        updateThickness()
        needsDisplay = true
    }

    /// Width of the widest expected label: the digit count of the document's total logical line
    /// count (minimum 2 digits), plus horizontal padding on each side. Only reassigned when it
    /// actually changes — assigning `ruleThickness` retiles the whole scroll view.
    private func updateThickness() {
        guard let textView, let textStorage = textView.textStorage else { return }

        let nsString = textStorage.string as NSString
        // Total logical lines = number of `\n` in the whole document + 1 — this also correctly
        // counts the trailing empty line of a file ending in `\n`, and the single line of an
        // empty document (criterion 8).
        let totalLines = LogicalLine.count(in: nsString, before: nsString.length) + 1
        let digitCount = max(Self.minimumDigitCount, String(totalLines).count)

        let template = String(repeating: "8", count: digitCount)
        let templateWidth = (template as NSString).size(withAttributes: [.font: numberFont]).width
        let newThickness = ceil(templateWidth) + Self.horizontalPadding * 2

        if newThickness != ruleThickness {
            ruleThickness = newThickness
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let textStorage = textView.textStorage
        else { return }

        backgroundColor.setFill()
        bounds.fill()
        separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        let nsString = textStorage.string as NSString
        let visibleRect = textView.visibleRect
        let containerOrigin = textView.textContainerOrigin

        // Visible-range-only drawing (criterion 10): the only whole-document work is the O(offset)
        // `\n` prefix count below, never a full fragment enumeration from index 0.
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        var lineStart = LogicalLine.lineStart(in: nsString, containing: visibleCharRange.location)
        var lineNumber = LogicalLine.count(in: nsString, before: lineStart) + 1

        while lineStart < nsString.length {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
            // `glyphIndexForCharacter(at:)` resolved *before* `lineFragmentRect(forGlyphAt:)` —
            // this yields the line's first fragment, never a wrapped continuation, so a wrapped
            // line's number is drawn exactly once (criterion 8).
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)

            // The break check compares text-view-space rects only: `fragmentRect` offset by
            // `textContainerOrigin` and `visibleRect` share that space. Comparing a ruler-space
            // rect against `visibleRect` (mixed spaces) walked hundreds of fragments past the
            // viewport once scrolled — ruler-space conversion now happens only for a rect that is
            // actually drawn.
            let fragmentRectInTextView = fragmentRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
            if fragmentRectInTextView.minY > visibleRect.maxY { break }
            draw(lineNumber: lineNumber, in: convert(fragmentRectInTextView, from: textView))

            guard let next = LogicalLine.nextLineStart(in: nsString, after: lineStart) else { break }
            lineStart = next
            lineNumber += 1
        }

        // The extra line fragment represents the blank line after a document's trailing `\n`, or
        // the single line of an empty document — neither has any real characters, so it is never
        // reached by the walk above and must be handled separately (criterion 8).
        if layoutManager.extraLineFragmentTextContainer != nil {
            let extraRect = layoutManager.extraLineFragmentRect
            // Same text-view-space comparison as the main loop above — a ruler-space rect
            // intersected against `visibleRect` (mixed spaces) produced false positives.
            let extraRectInTextView = extraRect.offsetBy(dx: containerOrigin.x, dy: containerOrigin.y)
            if extraRectInTextView.intersects(visibleRect) {
                draw(lineNumber: lineNumber, in: convert(extraRectInTextView, from: textView))
            }
        }
    }

    private func draw(lineNumber: Int, in fragmentRect: NSRect) {
        let string = String(lineNumber)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]
        let size = (string as NSString).size(withAttributes: attributes)

        let x = bounds.maxX - Self.horizontalPadding - size.width
        let y = fragmentRect.minY + (fragmentRect.height - size.height) / 2
        (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
    }
}
