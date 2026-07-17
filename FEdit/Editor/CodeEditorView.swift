//
//  CodeEditorView.swift
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
import SwiftUI

/// A single-file plain-text code editor (SPEC §6.1), backed by an explicitly constructed
/// TextKit 1 stack (`NSTextStorage` + `NSLayoutManager` + `NSTextContainer`) — never the
/// convenience initializers (`NSTextView(frame:)`/`NSTextView()`), which hand back a TextKit 2
/// stack instead.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String

    /// Identity of the currently open file; changing it resets undo and reloads the full text
    /// (SPEC §6.1: "Undo enabled, reset when switching files").
    let documentID: URL?

    /// One-shot cursor-restore hook for (session-restore); defaults to `nil` so every other call
    /// site is unaffected. Consumed once per `documentID` change: clamped to the text length,
    /// the selection is applied synchronously, and `scrollRangeToVisible` is deferred to the next
    /// runloop pass (initial layout isn't complete inside the first `updateNSView`).
    var cursorToRestore: Int? = nil

    /// Fires with the 0-based logical line first visible after scrolling, throttled (SPEC §6.4).
    var onFirstVisibleLineChange: ((Int) -> Void)? = nil

    /// Fires with the UTF-16 selection location whenever the caret moves, including the
    /// synthetic reports issued right after a programmatic file switch.
    var onCursorChange: ((Int) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // Explicit TextKit 1 stack, wired in the required order: storage → layout manager →
        // container (criterion 3). The Coordinator's `textStorage` is a *strong* stored
        // property — in a hand-assembled stack the strong references run downward only
        // (storage → layout manager → container; the text view retains only its container, and
        // back-pointers are weak), so without a strong owner outside this method the storage
        // would deallocate the moment `makeNSView` returns (classic crash).
        let textStorage = coordinator.textStorage
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        // Seeded from the scroll view's own content size — not a hardcoded zero/infinite width;
        // an infinite width would disable wrapping entirely (criterion 4). Height is kept
        // unbounded so the container never truncates layout (a container height of 0 renders no
        // text at all).
        let textContainer = NSTextContainer(
            size: NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.allowsUndo = true
        textView.isRichText = false

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let textColor = NSColor(white: 0.1, alpha: 1)
        textView.font = font
        textView.textColor = textColor
        textView.typingAttributes = [.font: font, .foregroundColor: textColor]
        textView.backgroundColor = .white

        // Plain text only — every smart substitution, correction, and detector disabled
        // (criterion 5).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.delegate = coordinator

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        coordinator.textView = textView
        coordinator.rulerView = ruler
        coordinator.observeClipViewBounds(scrollView.contentView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        // Stale-closure hygiene: refreshed at the top of every call so the coordinator always
        // sees this update's callbacks/binding, not a captured earlier one (load-bearing later
        // for (syntax-highlighting)'s language updates).
        context.coordinator.parent = self

        let coordinator = context.coordinator
        guard let textView = coordinator.textView else { return }

        if documentID != coordinator.currentDocumentID {
            // File switch: full reload, undo reset, selection to either the restored cursor or
            // the top of the document.
            coordinator.isProgrammaticUpdate = true
            textView.string = text
            // Clears the *window's* shared `NSUndoManager` — not just this view's own actions —
            // so switching files also wipes any other undoable state in the window. Accepted
            // explicitly for v1 (criterion 6: switching files must never resurrect the previous
            // file's edits).
            textView.undoManager?.removeAllActions()

            let fullLength = (textView.string as NSString).length
            if let cursorToRestore, !coordinator.hasConsumedCursorRestore {
                // (session-restore)'s one-shot hook: consumed at most once for the coordinator's
                // entire lifetime, never re-applied on a later document switch.
                let clamped = min(max(cursorToRestore, 0), fullLength)
                textView.setSelectedRange(NSRange(location: clamped, length: 0))
                // Initial layout isn't complete inside this call, so the scroll is deferred one
                // runloop pass.
                DispatchQueue.main.async { [weak textView] in
                    textView?.scrollRangeToVisible(NSRange(location: clamped, length: 0))
                }
                coordinator.hasConsumedCursorRestore = true
                // Deferred: this fires inside SwiftUI's update pass, and the ContentView closure
                // writes @State — must not happen synchronously here.
                DispatchQueue.main.async {
                    onCursorChange?(clamped)
                }
            } else {
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                // Invariant: callbacks always reflect the current document — fired explicitly so
                // consumers ((session-restore)) never hold a stale previous-file offset. Deferred
                // for the same reason as above: not safe to write @State inside this update pass.
                DispatchQueue.main.async {
                    onCursorChange?(0)
                }
            }

            // A programmatic `string =` assignment does not post `NSText.didChangeNotification`,
            // so the ruler (which redraws off that notification) must be invalidated explicitly.
            coordinator.rulerView?.invalidateLineNumbers()

            coordinator.currentDocumentID = documentID
            coordinator.isProgrammaticUpdate = false
        } else if textView.string != text {
            // Speculative external-change path: kept but no shipped item drives this branch yet.
            // Caret is clamped into the new text; undo is deliberately left untouched — this is
            // not a file switch.
            let oldLocation = textView.selectedRange().location
            coordinator.isProgrammaticUpdate = true
            textView.string = text
            let newLength = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(oldLocation, newLength), length: 0))
            coordinator.rulerView?.invalidateLineNumbers()
            coordinator.isProgrammaticUpdate = false
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView

        /// Strong — keeps the hand-assembled TextKit 1 stack alive for the life of the view (see
        /// the ownership note in `makeNSView`).
        let textStorage = NSTextStorage()

        weak var textView: NSTextView?
        weak var rulerView: LineNumberRulerView?
        var currentDocumentID: URL?
        var hasConsumedCursorRestore = false
        var isProgrammaticUpdate = false

        private var lastReportedFirstVisibleLine: Int?
        private var firstVisibleLineWorkItem: DispatchWorkItem?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            firstVisibleLineWorkItem?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            parent.onCursorChange?(textView.selectedRange().location)
        }

        /// Subscribes to the clip view's scroll-position changes (Tier 3's own first-visible-line
        /// reporting). Sets `postsBoundsChangedNotifications` itself, idempotently — Tier 2's
        /// ruler also sets it for its own redraw, but reverting Tier 2 must not silently break
        /// this observer.
        func observeClipViewBounds(_ clipView: NSClipView) {
            clipView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipViewBoundsDidChange),
                name: NSView.boundsDidChangeNotification, object: clipView
            )
        }

        @objc private func clipViewBoundsDidChange(_ notification: Notification) {
            // Coalesced ~100 ms throttle (SPEC §6.4): each scroll event cancels the previous
            // pending report and reschedules, so a flood of scroll events collapses to one.
            firstVisibleLineWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.reportFirstVisibleLineIfChanged()
            }
            firstVisibleLineWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
        }

        private func reportFirstVisibleLineIfChanged() {
            guard let textView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let textStorage = textView.textStorage
            else { return }

            let visibleRect = textView.visibleRect
            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
            let nsString = textStorage.string as NSString
            // Same shared `\n`-only helper as the ruler (LogicalLine.swift) — one definition for
            // "logical line index of a character offset", never reimplemented independently.
            let line = LogicalLine.count(in: nsString, before: visibleCharRange.location)

            guard line != lastReportedFirstVisibleLine else { return }
            lastReportedFirstVisibleLine = line
            parent.onFirstVisibleLineChange?(line)
        }
    }
}
