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

    /// The syntax-highlighting language for the currently open file (SPEC §6.3), piggybacking on
    /// the same file identity as `documentID`. Defaults to `nil` (treated as `.plain`, i.e. the
    /// highlighter's reset pass runs but no rules apply) so call sites that predate
    /// (syntax-highlighting) keep compiling unchanged.
    var language: SyntaxLanguage? = nil

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

    /// (editor-font-zoom) The current editor font size (SPEC §6.1), owned as the global
    /// `@AppStorage(SettingsKey.editorFontSize)` by `ContentView` and passed in already clamped to
    /// 8–32. Defaulted so any other call site stays source-compatible. A change reaches
    /// `updateNSView`, whose independent size block re-lays-out this window's editor (re-font,
    /// re-highlight, ruler, gutter) with caret and top line preserved.
    var fontSize: CGFloat = 13

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

        // (syntax-highlighting): re-pointed at `Theme` so these defaults and the highlighter's
        // reset pass (`Theme.baseAttributes`) can never drift apart — no visual change from the
        // literals editor-core shipped with.
        textView.font = Theme.editorFont(size: fontSize)
        textView.textColor = Theme.text
        textView.typingAttributes = [.font: Theme.editorFont(size: fontSize), .foregroundColor: Theme.text]
        textView.backgroundColor = Theme.background

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
        // (editor-font-zoom): the gutter tracks the editor font size. Set after construction
        // (font was already applied above), so the ruler's number font matches from first paint.
        ruler.editorFontSize = fontSize
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        coordinator.textView = textView
        coordinator.rulerView = ruler
        // (editor-font-zoom): seed both size fields here so (D2) the size block in the FIRST
        // `updateNSView` — which coincides with file load / session-restore cursor+scroll — sees
        // `appliedFontSize == fontSize` and is skipped, never overriding the deferred
        // restore-scroll. `currentFontSize` is the value `highlightNow` reads on that first pass.
        coordinator.currentFontSize = fontSize
        coordinator.appliedFontSize = fontSize
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

        // (syntax-highlighting) ownership rule: written before the file-switch `highlightNow`
        // below, so a debounced work item scheduled by a *previous* update always reads the
        // language that matches whatever content it actually fires against — never a value
        // captured from a struct copy. Without this ordering, switching from `a.swift` to `b.py`
        // could highlight `b.py`'s content with Swift rules forever (the classic
        // stale-representable bug).
        coordinator.currentLanguage = language ?? .plain

        // (editor-font-zoom) same ownership discipline as `currentLanguage`: written before any
        // `highlightNow` in this pass, so both the file-switch highlight below and any debounced
        // pass scheduled by a previous update run at the *current* size — never a stale
        // struct-copy value (criterion 14: a mid-debounce zoom highlights at the final size).
        coordinator.currentFontSize = fontSize

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

            // (syntax-highlighting): cancel any pending debounced pass carried over from the
            // previous file, then highlight the newly loaded content synchronously — no 150 ms
            // flash of plain/stale-colored text, and no leftover attributes from the previous
            // file ever appear (criterion 6).
            coordinator.pendingHighlight?.cancel()
            coordinator.pendingHighlight = nil
            coordinator.highlightNow(textView)

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

            // (syntax-highlighting): editor-core has two programmatic-content paths, and both
            // are hooked — this is the second (external-change) path, same cancel-pending +
            // synchronous-highlight treatment as the file-switch branch above.
            coordinator.pendingHighlight?.cancel()
            coordinator.pendingHighlight = nil
            coordinator.highlightNow(textView)
        }

        // (editor-font-zoom) Independent of the branches above (an `if`, not `else if`): a
        // simultaneous file-switch + size-change must both resolve, and on a pure zoom neither
        // branch above runs. Guarded by `appliedFontSize != fontSize` (owned solely here — seeded
        // in `makeNSView` so it does not fire on first load, D2) so it is a no-op unless the size
        // actually changed. Wrapped in `isProgrammaticUpdate` so the attribute-only re-apply can
        // never round-trip through `textDidChange` into a highlight reschedule (criterion 12) and
        // so the selection restore does not emit a spurious cursor report.
        if coordinator.appliedFontSize != fontSize {
            coordinator.isProgrammaticUpdate = true

            // 1. Capture anchors: the caret/selection, and the first-visible character (its
            //    logical line is re-pinned to the viewport top after relayout).
            let ranges = textView.selectedRanges
            let anchorChar = coordinator.firstVisibleCharIndex(textView)

            // 2. New typing/caret font. Deliberately NOT `textView.font = …`: the `font` setter
            //    routes through `shouldChangeText`/`didChangeText`, which registers an undo action
            //    and dirties the document (violating criterion 7). The sized font reaches existing
            //    text via the re-highlight in step 3 (raw `NSTextStorage` attribute writes — no
            //    undo, no `didChangeText`) and reaches typed/empty-document text via these typing
            //    attributes (D4).
            textView.typingAttributes = [.font: Theme.editorFont(size: fontSize), .foregroundColor: Theme.text]

            // 3. Re-highlight at the new size (read from `coordinator.currentFontSize`, set above).
            //    The reset pass re-applies `Theme.baseAttributes(fontSize:)` across the whole
            //    storage, so even a `.plain` file re-sizes uniformly (criterion 9). Cancel any
            //    pending debounced pass first so it cannot re-run at a stale size.
            coordinator.pendingHighlight?.cancel()
            coordinator.pendingHighlight = nil
            coordinator.highlightNow(textView)

            // 4. Gutter tracks the new size (recomputes number font + thickness + redraws).
            coordinator.rulerView?.editorFontSize = fontSize

            // 5. Restore selection, then re-pin the captured line to the viewport top once the
            //    resized layout exists (deferred one runloop pass if layout is not yet complete —
            //    the same pattern as the file-switch cursor-restore scroll).
            textView.selectedRanges = ranges
            coordinator.scrollCharToTop(textView, characterIndex: anchorChar)

            coordinator.appliedFontSize = fontSize
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

        /// (syntax-highlighting) ownership rule: the single source of truth a debounced/immediate
        /// highlight pass reads at execution time. Written by `updateNSView` before any
        /// `highlightNow` call in the same pass — never read from a captured `CodeEditorView`
        /// struct copy (see the ownership note at the `updateNSView` call site).
        var currentLanguage: SyntaxLanguage = .plain

        /// (editor-font-zoom) The size a highlight pass reads at execution time — same ownership
        /// discipline as `currentLanguage`. Written by `updateNSView` before any `highlightNow` in
        /// the same pass (and seeded in `makeNSView`), so a debounced pass fires at the current
        /// size even if the size changed mid-debounce (criterion 14).
        var currentFontSize: CGFloat = 13

        /// (editor-font-zoom) The last size for which the live re-apply block in `updateNSView`
        /// ran; owned solely by that block. Seeded in `makeNSView` to the initial size so the
        /// block is skipped on the first update (D2 — must not override session-restore's deferred
        /// cursor scroll).
        var appliedFontSize: CGFloat? = nil

        /// The pending ~150 ms debounced highlight pass (criterion 5), if any. Exposed
        /// (non-private) so `updateNSView`'s two programmatic-content paths can cancel it before
        /// running a synchronous pass of their own (criterion 6).
        var pendingHighlight: DispatchWorkItem?

        private var lastReportedFirstVisibleLine: Int?
        private var firstVisibleLineWorkItem: DispatchWorkItem?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            firstVisibleLineWorkItem?.cancel()
            pendingHighlight?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            parent.text = textView.string
            scheduleHighlight(for: textView)
        }

        /// Debounces a highlight pass ~150 ms after the last keystroke (criterion 5): cancels any
        /// already-pending pass and reschedules, so a burst of characters produces exactly one
        /// pass. `textDidChange(_:)` fires only for character edits — never for the attribute-only
        /// pass this eventually runs — so this can never reschedule itself (criterion 8, no
        /// feedback loop).
        func scheduleHighlight(for textView: NSTextView) {
            pendingHighlight?.cancel()
            let workItem = DispatchWorkItem { [weak self, weak textView] in
                guard let self, let textView else { return }
                self.highlightNow(textView)
            }
            pendingHighlight = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150), execute: workItem)
        }

        /// Runs a full highlight pass immediately, using `currentLanguage` at the moment this is
        /// called (never a value captured earlier). Attribute-only — `SyntaxHighlighter.highlight`
        /// never calls `didChangeText()` or mutates characters — so this cannot itself trigger
        /// `textDidChange(_:)` (criterion 8) and never moves the selection, so there is nothing to
        /// restore here.
        func highlightNow(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            SyntaxHighlighter.highlight(textStorage, language: currentLanguage, fontSize: currentFontSize)
        }

        /// (editor-font-zoom) The UTF-16 index of the first character whose glyph is visible —
        /// the exact computation `reportFirstVisibleLineIfChanged` uses (visible glyph range →
        /// character range → `.location`), reused here as the anchor for scroll preservation
        /// across a zoom relayout. Returns 0 when the layout stack is unavailable.
        func firstVisibleCharIndex(_ textView: NSTextView) -> Int {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return 0 }
            let visibleRect = textView.visibleRect
            let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
            let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)
            return visibleCharRange.location
        }

        /// (editor-font-zoom) Pins the line fragment containing `characterIndex` to the top of the
        /// viewport after a zoom relayout. Anchoring on the logical line (not a pixel offset) keeps
        /// content from drifting when line heights change. Forces layout first; if the anchor's
        /// glyph is not yet laid out, defers exactly one runloop pass and retries once — the same
        /// deferral pattern as the file-switch cursor-restore scroll.
        func scrollCharToTop(_ textView: NSTextView, characterIndex: Int, retry: Bool = true) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer
            else { return }

            let length = (textView.string as NSString).length
            guard length > 0 else {
                // Empty document: nothing to anchor; keep the origin at the top.
                textView.scroll(.zero)
                return
            }

            let clamped = min(max(characterIndex, 0), length - 1)

            // Force layout for the resized text so the fragment rect below is valid.
            layoutManager.ensureLayout(for: textContainer)
            if retry, layoutManager.firstUnlaidCharacterIndex() <= clamped {
                DispatchQueue.main.async { [weak self, weak textView] in
                    guard let self, let textView else { return }
                    self.scrollCharToTop(textView, characterIndex: clamped, retry: false)
                }
                return
            }

            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clamped)
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let containerOrigin = textView.textContainerOrigin
            // `NSView.scroll(_:)` moves the enclosing clip view so this point sits at the top-left
            // of the viewport; `fragmentRect` is in container space, offset into text-view space.
            textView.scroll(NSPoint(x: 0, y: fragmentRect.minY + containerOrigin.y))
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
