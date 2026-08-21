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

    /// Fires with the line-number gutter width whenever it changes, so `ContentView` can indent the
    /// editor column's header strip to align the file name with the text pane.
    var onGutterWidthChange: ((CGFloat) -> Void)? = nil

    /// (editor-font-zoom) The current editor font size (SPEC §6.1), owned as the global
    /// `@AppStorage(SettingsKey.editorFontSize)` by `ContentView` and passed in already clamped to
    /// 8–32. Defaulted so any other call site stays source-compatible. A change reaches
    /// `updateNSView`, whose independent size block re-lays-out this window's editor (re-font,
    /// re-highlight, ruler, gutter) with caret and top line preserved.
    var fontSize: CGFloat = 13

    // MARK: - (editor-find) Find inputs and outputs (SPEC §6.5)
    //
    // Four inputs and two outputs, all defaulted so every other call site stays source-compatible.
    // They are plain values read out of `WorkspaceModel` at the `ContentView` call site rather than
    // a binding to the model, because the editor is a *consumer* of find state: it never decides
    // what is searched, only where the matches are. Find state cannot live on the `Coordinator` —
    // it is destroyed and rebuilt whenever `workspace.isMarkdown` flips (D3).

    /// The literal search text (`WorkspaceModel.findQuery`). An empty query enumerates nothing and
    /// reports an empty count label.
    var findQuery: String = ""

    /// The bar's **Case sensitive** checkbox (`WorkspaceModel.findCaseSensitive`); `false` (the
    /// default) means a case-insensitive search.
    var findCaseSensitive: Bool = false

    /// Whether the find bar is showing (`WorkspaceModel.isFindBarVisible`). Going `false` is what
    /// removes every highlight and — once — leaves the caret at the current match (D9).
    var findIsActive: Bool = false

    /// Find Next's monotonically increasing tick (`WorkspaceModel.findNextTick`), bumped by Return
    /// and Cmd+G. Consumed against `Coordinator.lastConsumedFindTick`, which `makeNSView` seeds from
    /// this very value so a rebuilt editor cannot replay the previous editor's steps (criterion 22).
    var findNextTick: Int = 0

    /// (editor-find-previous) Find Previous's monotonically increasing tick
    /// (`WorkspaceModel.findPreviousTick`), bumped by Cmd+Shift+G — there is no Return-key route to
    /// this one (SwiftUI's `.onSubmit` carries no modifier information, so the bar's query field
    /// cannot tell Return from Shift+Return). Consumed against
    /// `Coordinator.lastConsumedFindPreviousTick`, which `makeNSView` seeds from this very value for
    /// the same reason it seeds `lastConsumedFindTick`: a rebuilt editor must not replay the
    /// previous editor's steps (criterion 22 of (editor-find), criterion 9 of this item).
    var findPreviousTick: Int = 0

    /// Fires with the find bar's count readout (`3 of 17` / `Not found` / `3 of 20000+` / `""`)
    /// whenever it changes. The count flows editor → model → bar, one direction only.
    var onFindCountChange: ((String) -> Void)? = nil

    /// Fires when Esc is pressed **while focus is in the editor text** — the half of criterion 18
    /// that a SwiftUI `.keyboardShortcut(.cancelAction)` on the bar's Done button cannot reach,
    /// because the bar does not have focus then. `ContentView` routes it to `closeFindBar()`.
    var onFindClose: (() -> Void)? = nil

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

        // (editor-find) A `FindableTextView`, not a plain `NSTextView`, for exactly one reason: Esc
        // must close the find bar when focus is in the TEXT rather than in the bar's query field
        // (criterion 18). Everything else about the view is unchanged, and the TextKit 1 stack is
        // still hand-built here — the subclass adds one override and one closure, no storage.
        let textView = FindableTextView(frame: .zero, textContainer: textContainer)
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

        // (editor-find) Esc with focus in the editor text. Returns `false` — i.e. "not handled,
        // fall through to AppKit's own Esc behavior" — unless a find bar is actually open, so this
        // changes nothing about the editor when find is not in use. Runs from a key event, never
        // inside a SwiftUI update pass, so writing model state from here needs no deferral.
        // `[weak coordinator]`, matching `ruler.onThicknessChange` below: this closure is stored on
        // a view the coordinator (indirectly) owns, so a strong capture would be a retain cycle.
        textView.onEscape = { [weak coordinator] in
            guard let coordinator, coordinator.parent.findIsActive else { return false }
            coordinator.parent.onFindClose?()
            return true
        }

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        // (editor-font-zoom): the gutter tracks the editor font size. Set after construction
        // (font was already applied above), so the ruler's number font matches from first paint.
        ruler.editorFontSize = fontSize
        // Report the gutter width up so ContentView can align the editor header strip's file name
        // with the text pane. Dispatched async so the resulting SwiftUI @State write never lands
        // mid-layout. `coordinator.parent` is refreshed at the top of every `updateNSView`.
        ruler.onThicknessChange = { [weak coordinator] width in
            DispatchQueue.main.async { coordinator?.parent.onGutterWidthChange?(width) }
        }
        let initialGutterWidth = ruler.ruleThickness
        DispatchQueue.main.async { [weak coordinator] in
            coordinator?.parent.onGutterWidthChange?(initialGutterWidth)
        }
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
        // (editor-find) Seeded here for exactly the same reason `appliedFontSize` is, and it is the
        // whole of criterion 22: `findNextTick` lives on `WorkspaceModel` and keeps counting for the
        // life of the WINDOW, while this coordinator is destroyed and rebuilt on every
        // Markdown↔non-Markdown file switch. A fresh coordinator that started this at 0 would see
        // the window's accumulated tick (seven Cmd+G presses in the previous file) as a brand-new
        // step and jump the just-opened file to a match on load. Seeding it to the incoming value
        // means a rebuilt editor starts already up to date — this is the house one-shot convention
        // (`hasConsumedCursorRestore`, `pendingNewWindowPicks`, the `CLIOpenToken` issued-id guard).
        coordinator.lastConsumedFindTick = findNextTick
        // (editor-find-previous, criterion 9) The identical seeding for the backwards tick, and it
        // is load-bearing for the identical reason: `findPreviousTick` also lives on
        // `WorkspaceModel` and also keeps counting for the life of the window, so a fresh
        // coordinator starting it at 0 would read the window's accumulated Cmd+Shift+G presses as
        // one brand-new step and jump the just-opened file to a match on load.
        coordinator.lastConsumedFindPreviousTick = findPreviousTick
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
            // (editor-find, finding 3) A character mutation that bypasses `textDidChange` (see the
            // ruler-invalidation comment below), so `textEditGeneration` needs its own explicit bump
            // here — otherwise `isFindSessionCurrent` would keep reporting the PREVIOUS document's
            // session as current until `refreshFind` happens to re-run later in this same pass.
            coordinator.textEditGeneration += 1
            // (editor-find, findings 3 and 6) Marks this pass as a document change for the trailing
            // find block to read once and clear (see `documentChangedThisPass`'s doc comment).
            coordinator.documentChangedThisPass = true
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
            // (external-change-watch, Tier 1) External-change reload applier: the model replaced
            // `openFile.text` with `documentID` unchanged (a clean-buffer reload via
            // `reloadOpenFileFromDisk`), so `updateNSView` lands here rather than the file-switch
            // branch. Preserve the caret (clamped into the new length) and the scroll position (the
            // first-visible line re-pinned after relayout), reusing (editor-font-zoom)'s anchor
            // helpers. Undo is deliberately left untouched — this is not a file switch. Wrapped in
            // `isProgrammaticUpdate` so the swap never round-trips through `textDidChange` to mark
            // the buffer dirty (load-bearing: a reload must leave a clean buffer clean).
            let oldLocation = textView.selectedRange().location
            // Capture the scroll anchor *before* the swap, off the old layout.
            let anchorChar = coordinator.firstVisibleCharIndex(textView)
            coordinator.isProgrammaticUpdate = true
            textView.string = text
            // (editor-find, finding 3) Same reasoning as the file-switch branch above: this is a
            // character mutation `textDidChange` never sees, so `textEditGeneration` needs the
            // explicit bump.
            coordinator.textEditGeneration += 1
            // (editor-find, findings 3 and 6) Same flag the file-switch branch sets, and the same
            // reason — this branch replaces the document's content just as fully.
            coordinator.documentChangedThisPass = true
            let newLength = (text as NSString).length
            let clamped = min(oldLocation, newLength)
            textView.setSelectedRange(NSRange(location: clamped, length: 0))
            coordinator.rulerView?.invalidateLineNumbers()

            // (syntax-highlighting): editor-core has two programmatic-content paths, and both
            // are hooked — this is the second (external-change) path, same cancel-pending +
            // synchronous-highlight treatment as the file-switch branch above.
            coordinator.pendingHighlight?.cancel()
            coordinator.pendingHighlight = nil
            coordinator.highlightNow(textView)

            // Re-pin the previously first-visible line to the viewport top after the swap+relayout
            // (unchanged when the text above the caret is unchanged); same anchor helper the zoom
            // block uses.
            coordinator.scrollCharToTop(textView, characterIndex: anchorChar)
            coordinator.isProgrammaticUpdate = false

            // Report the clamped caret so (session-restore)'s `cursorLocation` can't persist an
            // out-of-range offset after a *truncating* reload. Deferred one runloop pass (the
            // callback writes @State), matching the file-switch branch.
            DispatchQueue.main.async {
                onCursorChange?(clamped)
            }
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
            // (editor-find, criterion 23) The third anchor, captured here with the other two and
            // for the same reason — step 3 below runs a highlight pass, which counts as a settle
            // point, so `isFindSessionCurrent` read *after* it would always be false. What this
            // asks is "does the find session describe the text as it stands right now", which is
            // false when a file switch or an external reload ran earlier in this same pass (both
            // are independent `if`s above): the session then still describes the previous document,
            // and re-scrolling to one of its matches would silently override the caret/top position
            // that branch just established with a plausible-looking wrong offset.
            let findAnchorIsValid = findIsActive
                && coordinator.isFindSessionCurrent
                && coordinator.findSession.currentRange != nil

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
            // (editor-find, criterion 23) While a find session is running, the anchor the user
            // cares about is the CURRENT MATCH, not the first visible line: zooming with `7 of 17`
            // showing must leave that match on screen, and the count must not change. A zoom
            // re-applies attributes and never changes a character, so the session's ranges are
            // still exactly right; the validity captured in step 1 is what rules out the
            // simultaneous file-switch case. Otherwise this falls back to the ordinary top-line
            // anchor, which was captured after any swap and is correct there.
            if findAnchorIsValid {
                coordinator.scrollToCurrentFindMatch(textView)
            } else {
                coordinator.scrollCharToTop(textView, characterIndex: anchorChar)
            }

            coordinator.appliedFontSize = fontSize
            coordinator.isProgrammaticUpdate = false
        }

        // ===== (editor-find) THE ORDERING INVARIANT =====
        //
        // Every line of find work in `updateNSView` lives HERE, after the file-switch branch, the
        // external-reload branch and the font-zoom block have all finished. That placement is not
        // tidiness — it is the fix for the `NSRangeException` class of defect this feature invites.
        // A find range is enumerated against one snapshot of the text and consumed (highlighted,
        // scrolled to, selected) against another; if any of that ran BEFORE the branches above
        // replaced the text, it would hand `addTemporaryAttributes`/`scrollRangeToVisible` a range
        // past the end of the storage, which raises and takes the app down.
        //
        // Two independent guarantees, deliberately belt-and-braces:
        //  1. Position — this block is last, and `highlightNow`'s own find hook is suppressed while
        //     `isProgrammaticUpdate` is set (which is exactly "inside one of those branches").
        //  2. Content — `refreshFind` runs `FindSession.clamp(toLength:)` before it reads, draws or
        //     scrolls to anything, and every range is intersected with the storage's full range at
        //     the point of use. So even a caller that got the order wrong cannot raise.
        coordinator.refreshFind(textView)

        // Find Next (Return / Cmd+G), consumed exactly once per tick. The tick is consumed
        // UNCONDITIONALLY — even with the bar closed, where it does nothing — so a Cmd+G pressed
        // while find was inactive can never be replayed as a surprise jump when the bar next opens.
        // `lastConsumedFindTick` is seeded in `makeNSView`, which is what keeps a *rebuilt*
        // coordinator from replaying the previous editor's ticks (criterion 22).
        if coordinator.lastConsumedFindTick != findNextTick {
            coordinator.lastConsumedFindTick = findNextTick
            if findIsActive {
                coordinator.stepFindNext(textView)
            }
        }

        // (editor-find-previous) Find Previous (Cmd+Shift+G), the exact mirror of the block above
        // and deliberately a SEPARATE tick rather than a direction flag on that one (D1 — the ticks
        // are consumed as levels, which a companion flag would not be covered by). Same shape
        // throughout: consumed UNCONDITIONALLY, so a Cmd+Shift+G pressed while the bar was closed
        // can never be replayed as a surprise jump when it next opens, and stepped only while the
        // bar is showing. `lastConsumedFindPreviousTick` is seeded in `makeNSView` for the same
        // rebuilt-coordinator reason (criterion 9).
        if coordinator.lastConsumedFindPreviousTick != findPreviousTick {
            coordinator.lastConsumedFindPreviousTick = findPreviousTick
            if findIsActive {
                coordinator.stepFindPrevious(textView)
            }
        }
    }

    /// (editor-find, finding 19) Deterministic teardown: SwiftUI calls this when the representable
    /// is removed (a file switch across the Markdown boundary destroys this editor), so pending
    /// debounced work is cancelled at that moment rather than whenever the coordinator happens to be
    /// released. `Coordinator.deinit` still cancels — this is the earlier, deterministic half.
    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.cancelPendingWork()
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

        /// (editor-find, findings 3 and 6) Set by the file-switch and external-reload branches in
        /// `updateNSView` — never anywhere else — and consumed (read once, then cleared) by the
        /// very next `refreshFind`, which the ordering invariant guarantees runs at the end of that
        /// same pass. Two independent readers rely on it meaning exactly "the document itself
        /// changed earlier in the CURRENT `updateNSView` pass": closing the bar must not recompute a
        /// leftover query against a document it was never searching (finding 3) or drop the caret at
        /// a stale-but-in-bounds match belonging to the file that just closed, and the trailing
        /// `scrollToCurrentFindMatch` on a NEW search must not fight the top-of-file/restored-cursor
        /// scroll that branch just set (finding 6).
        var documentChangedThisPass = false

        // MARK: - (editor-find) Derived find state (SPEC §6.5)

        /// The find state machine for this editor. **Derived, never authoritative:** the query, the
        /// case flag and the bar's visibility live on `WorkspaceModel` (D3) and are mirrored in here
        /// on each `refreshFind`, because this coordinator is destroyed and rebuilt whenever
        /// `workspace.isMarkdown` flips — which is exactly the `main.swift` → `notes.md` case find
        /// has to survive (criterion 20). Everything a rebuild loses is recomputed from the model.
        var findSession = FindSession()

        /// The last `findNextTick` this editor acted on. **Seeded in `makeNSView`** from the
        /// incoming tick, exactly as `appliedFontSize` is seeded — so a coordinator rebuilt mid-life
        /// never replays the window's accumulated Find Next presses (criterion 22). `nil` would mean
        /// "never seeded", which `makeNSView` makes unreachable.
        var lastConsumedFindTick: Int?

        /// (editor-find-previous) The last `findPreviousTick` this editor acted on — the backwards
        /// twin of `lastConsumedFindTick`, with the same seeding rule (**seeded in `makeNSView`**
        /// from the incoming tick, so a coordinator rebuilt mid-life never replays the window's
        /// accumulated Find Previous presses) and the same meaning for `nil` ("never seeded", which
        /// `makeNSView` makes unreachable). Independent of `lastConsumedFindTick` on purpose: each
        /// tick is level-compared against its own last-consumed value, which is exactly what a
        /// single tick plus a direction flag could not give (D1).
        var lastConsumedFindPreviousTick: Int?

        /// Counts the points at which the editor's text has *settled*: bumped once per
        /// `highlightNow`, i.e. by the debounced pass and by the three synchronous passes (file
        /// switch, external reload, font zoom). See `highlightNow` for why the bump lives there and
        /// not at those call sites, and for why a plain keystroke deliberately does not bump it.
        /// This is a **perf gate only** — it decides when `refreshFind` pays for a re-enumeration,
        /// not whether the session is safe to act on right now; `isFindSessionCurrent` below is the
        /// correctness gate and deliberately does NOT read this counter (editor-find, finding 3).
        ///
        /// Between a keystroke and its debounce the session's ranges are therefore up to 150 ms
        /// stale — safe to keep *displayed* by construction (every range is clamped and intersected
        /// before use) but NOT safe to act on as if current (placing a caret, scrolling): that is
        /// exactly the gap `textEditGeneration` closes.
        var settledTextGeneration = 0

        /// The `settledTextGeneration` the session was last enumerated against; `nil` before the
        /// first enumeration. Comparing the two is what lets `refreshFind` run on every
        /// `updateNSView` — it must, to stay correct — while *paying* for an enumeration only when
        /// the text has settled somewhere new or the query/case flag changed.
        private var findEnumeratedGeneration: Int?

        /// (editor-find, finding 3) Counts every actual CHARACTER mutation of the storage — bumped
        /// in `textDidChange` (every keystroke, not just settle points) and at the two other places
        /// characters change outside that delegate callback: the file-switch and external-reload
        /// `textView.string = text` assignments in `updateNSView` (a programmatic `string =` never
        /// posts `NSText.didChangeNotification`, so `textDidChange` is never called for it — see the
        /// ruler-invalidation comment at those call sites for the same fact). Deliberately NOT
        /// bumped by attribute-only passes (`highlightNow`'s `SyntaxHighlighter` call, the font-zoom
        /// block): those never move a character, so a range enumerated before one is still exactly
        /// right after it. Not `private`: `updateNSView`'s file-switch and external-reload branches
        /// bump it directly, the same way they already write `isProgrammaticUpdate` and
        /// `pendingHighlight` from outside the type.
        var textEditGeneration = 0

        /// The `textEditGeneration` the session was last enumerated against; `nil` before the first
        /// enumeration. This is what `isFindSessionCurrent` actually compares — see there.
        private var findEnumeratedTextEditGeneration: Int?

        /// The last count label handed out, so an unchanged label never crosses back into the model
        /// (mirrors `lastReportedFirstVisibleLine`). `nil` (not `""`) so the first report always
        /// goes out, including the empty one.
        private var lastReportedFindCountLabel: String?

        /// Whether the session's ranges were enumerated against the text that is in the storage
        /// *now* — literally: has `textEditGeneration` moved since the last enumeration. False in
        /// two overlapping windows: (1) after a settle point (a file switch or an external reload
        /// earlier in this same `updateNSView` pass) and before `refreshFind` has re-run, and (2)
        /// **for the whole ~150 ms debounce window after any keystroke**, because a keystroke bumps
        /// `textEditGeneration` immediately even though re-enumeration waits for the debounce
        /// (finding 3 — an earlier version of this predicate compared `settledTextGeneration`
        /// instead, which is bumped only at settle points, so it stayed `true` through that whole
        /// window and let a stale range be acted on as if current).
        ///
        /// Two call sites in `updateNSView`/`refreshFind` read it, and both are about a
        /// *stale-but-in-bounds* range doing something plausible-looking and wrong rather than
        /// crashing — the failure mode the clamp and the intersections cannot catch, because the
        /// range is perfectly valid, just for text that no longer exists. The font-zoom block must
        /// not re-scroll to a match belonging to the file (or the pre-edit text) that was current a
        /// moment ago, and closing the bar must not drop the caret at one — see `refreshFind`, which
        /// recomputes once before placing the caret when this is false, rather than skipping the
        /// placement outright.
        var isFindSessionCurrent: Bool {
            findEnumeratedTextEditGeneration == textEditGeneration
        }

        /// (editor-find, finding 1) The `settledTextGeneration` as of the last `applyFindHighlights`
        /// call from `refreshFind`'s active branch; `nil` before the first one. See the redraw guard
        /// there for why this — not just `findSession != sessionBefore` — decides whether a repaint
        /// is due.
        private var lastAppliedFindGeneration: Int?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        deinit {
            firstVisibleLineWorkItem?.cancel()
            pendingHighlight?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        /// (editor-find, finding 19) Cancels this coordinator's pending debounced work. Called from
        /// `dismantleNSView` — deterministic teardown, ahead of `deinit` — and kept here rather than
        /// reaching into private members from the representable.
        func cancelPendingWork() {
            firstVisibleLineWorkItem?.cancel()
            firstVisibleLineWorkItem = nil
            pendingHighlight?.cancel()
            pendingHighlight = nil
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView else { return }
            // (editor-find, finding 3) Every keystroke is a character mutation, so this bumps
            // `textEditGeneration` unconditionally and immediately — unlike `settledTextGeneration`,
            // which deliberately waits for the debounce (see that property's doc comment for why
            // the two must NOT be the same counter).
            textEditGeneration += 1
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

            // (editor-find, D8) A settle point, and the counter's exact meaning: "a full pass has
            // just run over whatever is in the storage now". All four callers qualify — the
            // debounced pass, the file-switch branch, the external-reload branch, and the font-zoom
            // block — and putting the bump HERE rather than at those call sites is what closes the
            // gap where one of them *cancels* a pending debounce and runs a pass of its own: a
            // keystroke followed within 150 ms by a zoom would otherwise leave the session
            // enumerated against pre-keystroke text with nothing left to ever re-run it.
            //
            // A plain keystroke deliberately does NOT come through here (it only reschedules the
            // debounce), which is what keeps typing off the enumeration path: an edit publishes
            // through the text binding and lands back in `updateNSView` within the same runloop
            // turn, so bumping per keystroke would mean a full document scan, and up to
            // `FindMetrics.matchLimit` temporary-attribute writes, on every character.
            settledTextGeneration += 1

            SyntaxHighlighter.highlight(textStorage, language: currentLanguage, fontSize: currentFontSize)

            // (editor-find, D8) The find re-enumeration rides this existing debounce — and this is
            // also the seam that makes the named hazard a non-event: the pass above opens with
            // `textStorage.setAttributes(…, range: fullRange)`, which wipes every text-storage
            // attribute, but find highlights are `NSLayoutManager` TEMPORARY attributes and are not
            // in the text storage at all, so they survive it by construction. Re-applying them here
            // is about the text having *changed* (a character edit shifts and truncates them), not
            // about the highlighter having eaten them.
            //
            // Guarded on `!isProgrammaticUpdate`, which is exactly "not inside one of
            // `updateNSView`'s text-mutating branches": the file-switch branch, the external-reload
            // branch and the font-zoom block all call this synchronously with that flag set, and all
            // three are followed by the find block at the end of `updateNSView`, which does this
            // work once, in the right order (see THE ORDERING INVARIANT there). Without the guard,
            // find would run mid-branch — before the caret and document identity for the new file
            // have even been set — which is the ordering the invariant forbids.
            if !isProgrammaticUpdate {
                refreshFind(textView)
            }
        }

        // MARK: - (editor-find) Find (SPEC §6.5)

        /// The single find entry point: clamp, then (only when it must) re-enumerate, then re-draw,
        /// then report the count out. Called from the find block at the end of `updateNSView` and
        /// from the debounced `highlightNow` — never from inside a text-mutating branch.
        ///
        /// **`clamp(toLength:)` runs first, before anything touches a range.** The session may be
        /// holding ranges enumerated against text that no longer exists (a keystroke inside the
        /// debounce window, a file switch, an external reload), and an out-of-range range handed to
        /// `addTemporaryAttributes`/`scrollRangeToVisible`/`setSelectedRange` raises
        /// `NSRangeException` — an app crash, not a glitch. This ordering is the whole reason
        /// `clamp` is a first-class operation on `FindSession` (criteria 9 and 11 pin it headlessly).
        func refreshFind(_ textView: NSTextView) {
            // (editor-find, findings 3 and 6, finding 4 second round) Consumed exactly once per
            // pass, on EVERY return path — including the `textStorage == nil` guard right below —
            // so a document change is never visible to a LATER `updateNSView` pass (e.g. the
            // debounced `highlightNow` firing after this one runs with the flag already stale-true).
            // Placed above the guard rather than after it for exactly that reason: a `defer` below a
            // `return` never runs for that path, which would leak the flag on the one return this
            // function has ahead of the `defer` line.
            defer { documentChangedThisPass = false }
            guard let textStorage = textView.textStorage else { return }
            let length = textStorage.length
            // Compared at the end to decide whether the drawn state is stale. `FindSession` is a
            // value type, so this is a cheap retain of the match array, not a copy of it.
            let sessionBefore = findSession

            // (editor-find, finding 9) Unconditional, on every `updateNSView` pass — including the
            // genuinely idle ones (a caret move, a scroll report, a divider drag) the comment below
            // calls out as paying nothing. That claim depends on `clamp`'s OWN early-out: on an
            // idle pass nothing is out of bounds, so it leaves `matches` as the same array instance
            // rather than allocating a fresh, filtered one — which is also what keeps `sessionBefore`
            // and `findSession` cheaply comparable by `Array`'s identity fast path just below,
            // instead of an up-to-`FindMetrics.matchLimit`-element walk on every single pass.
            findSession.clamp(toLength: length)

            guard parent.findIsActive else {
                // Closing the bar (D9). Stepping deliberately does NOT move the caret — each step
                // would otherwise fire `textViewDidChangeSelection` → `noteCursorMoved` → a
                // `@Published` write → a `JSONEncoder` + `@SceneStorage` snapshot write, per Find
                // Next press. Instead the caret is placed ONCE, here, at the match the user stopped
                // on, which is what "Esc leaves the caret at the match" actually wants.
                //
                // One-shot without a flag of its own: `clear()` empties the session immediately
                // below, so `currentRange` is `nil` on every subsequent inactive pass.
                //
                // `isFindSessionCurrent` is the guard against what the clamp cannot catch: a range
                // that is perfectly valid but describes the wrong text. Two distinct causes,
                // deliberately handled differently:
                //  - Stale by DOCUMENT (`documentChangedThisPass`, finding 6's flag reused here): a
                //    file switch or an external reload ran earlier in this same pass. Nothing worth
                //    recovering — the leftover query describes whatever was being searched for in
                //    the PREVIOUS document, so re-enumerating it against the new one would place the
                //    caret at a coincidental, meaningless match. Skip outright, exactly as before
                //    this finding: dropping the caret there would also silently override the caret
                //    that branch just set (a restored cursor, or the top of the file), and the
                //    user's place in a document that is no longer open is not a place.
                //  - Stale by EDIT only (finding 3): Esc pressed inside the ~150 ms debounce window
                //    after a keystroke, same document throughout. One re-enumeration away from being
                //    exactly right, so it is worth the one-time cost rather than dropping a caret
                //    placement the user is actively expecting.
                if isFindSessionCurrent {
                    if let current = findSession.currentRange {
                        placeCaretAtFindMatch(textView, range: current)
                    }
                } else if !documentChangedThisPass {
                    reenumerateFindSession(textView, textStorage: textStorage, seatOnNearest: true)
                    if let current = findSession.currentRange {
                        placeCaretAtFindMatch(textView, range: current)
                    }
                }
                findSession.clear()
                if findSession != sessionBefore {
                    // Removes every temporary background over the whole storage (criterion 18). The
                    // guard matters: with the bar closed this method still runs on every keystroke,
                    // and an unconditional `removeTemporaryAttribute` would invalidate display for
                    // the entire document each time.
                    applyFindHighlights(textView)
                }
                reportFindCount(findSession.countLabel)
                return
            }

            let inputsChanged = findSession.query != parent.findQuery
                || findSession.caseSensitive != parent.findCaseSensitive
            findSession.query = parent.findQuery
            findSession.caseSensitive = parent.findCaseSensitive

            // Enumerate only when something actually changed — the query/case flag, or the text at a
            // settle point (D8). Every other `updateNSView` pass (a caret move, a scroll report, a
            // divider drag, a keystroke inside the debounce window) reaches here and pays nothing.
            //
            // (editor-find, finding 1, second round) `documentChangedThisPass` gates the seat mode
            // here too, not only the scroll below: a file switch that keeps this coordinator (two
            // files of the same Markdown-ness) leaves `inputsChanged` false, so without this the seat
            // would default to `recomputeNearest(near: <the PREVIOUS document's offset>)` — an
            // offset that names nothing in the file that just opened. A new document must always
            // seat from the caret, never from a location that meant something in a different file.
            if inputsChanged || findEnumeratedGeneration != settledTextGeneration {
                reenumerateFindSession(
                    textView, textStorage: textStorage,
                    seatOnNearest: !inputsChanged && !documentChangedThisPass
                )
            }

            // Re-drawn exactly when the drawn state COULD be stale (editor-find, finding 1) — not
            // only when `findSession != sessionBefore`. The two are different questions: the drawn
            // state lives in the layout manager's TEMPORARY attributes, and those are destroyed by a
            // character replacement regardless of whether the resulting `matches` array happens to
            // compare equal to what it was before (probed directly: `textView.string = "…"` wipes a
            // previously-set temporary attribute; an attribute-only `setAttributes` pass does not).
            // Failing case this fixes: switch from a file with one `hello` match to a different file
            // that also has exactly one `hello` match at the same offset — `findSession` recomputes
            // to the identical value, the old guard skipped the repaint, and the count read `1 of 1`
            // with nothing actually highlighted.
            //
            // `lastAppliedFindGeneration != settledTextGeneration` is the belt: a settle point means
            // "a full pass just ran over whatever is in the storage now" (`highlightNow`'s doc
            // comment), which is true for every character-mutating branch (file switch, external
            // reload) as well as the debounced pass — repainting on any of them is what keeps this
            // correct even for a future settle-point source doing the same wipe. It is cheap because
            // settle points are throttled to ~150 ms or a handful of explicit synchronous passes,
            // never per keystroke — the genuinely idle passes (a caret move, a scroll report, a
            // divider drag) bump neither `settledTextGeneration` nor change `findSession`, so this
            // still skips the full-range temporary-attribute removal and its display invalidation on
            // exactly those passes, which is what keeps the "pays nothing" property.
            if findSession != sessionBefore || lastAppliedFindGeneration != settledTextGeneration {
                applyFindHighlights(textView)
                lastAppliedFindGeneration = settledTextGeneration
            }
            // Scroll only for a NEW search — never on a debounced re-enumeration, which would yank
            // the viewport away from the line the user is typing on. (editor-find, finding 6) NOR
            // when the document itself changed earlier in this same pass: opening a file across the
            // Markdown boundary rebuilds this coordinator, so the fresh `FindSession` has
            // `query == ""` and the very next `updateNSView` reporting the real query makes
            // `inputsChanged` true — which, without this guard, would yank the just-opened file's
            // viewport to a match and override the top-of-file/restored-cursor scroll the file-switch
            // branch just set. Switching between two files that keep the same coordinator hits the
            // opposite bug (no rebuild, so `inputsChanged` stays false and never scrolls at all) —
            // this makes both paths behave identically: opening a file never yanks the viewport,
            // typing a query still does.
            if inputsChanged && !documentChangedThisPass {
                scrollToCurrentFindMatch(textView)
            }
            reportFindCount(findSession.countLabel)
        }

        /// (editor-find, findings 2 and 3) Re-enumerates `findSession` with the seat mode the caller
        /// needs, and records both generations the enumeration ran against — `findEnumeratedGeneration`
        /// (the perf gate) and `findEnumeratedTextEditGeneration` (`isFindSessionCurrent`'s
        /// correctness gate). One shared implementation for both callers: the active-session
        /// re-enumeration in `refreshFind` and finding 3's stale-on-close recompute, which both need
        /// exactly the same seat-mode rule (nearest-to-the-previous-match for a re-run, first-at-or-
        /// after-the-caret otherwise).
        private func reenumerateFindSession(_ textView: NSTextView, textStorage: NSTextStorage, seatOnNearest: Bool) {
            if seatOnNearest, let current = findSession.currentRange {
                findSession.recomputeNearest(text: textStorage.string as NSString, near: current.location)
            } else {
                let caret = textView.selectedRange().location
                findSession.recompute(text: textStorage.string as NSString, caretLocation: caret)
            }
            findEnumeratedGeneration = settledTextGeneration
            findEnumeratedTextEditGeneration = textEditGeneration
        }

        /// Find Next (Return / Cmd+G): advance the seat, redraw, scroll the new current match into
        /// view, report the new count. Never touches the selection (D9).
        func stepFindNext(_ textView: NSTextView) {
            stepFind(textView, backwards: false)
        }

        /// (editor-find-previous) Find Previous (Cmd+Shift+G): retreat the seat, with the identical
        /// redraw, scroll, count report and no-selection rule as Find Next above.
        ///
        /// **There is no Return-key route, and the reason matters more than the absence.**
        /// `FindBar`'s `.onSubmit` carries no modifier information, so the query field cannot
        /// distinguish Shift+Return from Return — which means ⇧↩ in that field is not inert, it is
        /// an ordinary submit that steps **forward**. A user reaching for the Safari/Xcode ⇧↩
        /// Find-Previous reflex therefore gets the opposite of what they wanted, silently. That is a
        /// known, documented limitation (SPEC §6.5 says so explicitly), not an oversight: making ⇧↩
        /// work needs an `NSViewRepresentable` query field or a key monitor, both out of scope here.
        func stepFindPrevious(_ textView: NSTextView) {
            stepFind(textView, backwards: true)
        }

        /// (editor-find-previous, D2) The whole step path, shared by both directions — the only
        /// direction-dependent line in it is the `stepPrevious()`/`stepNext()` call. Extracted
        /// rather than copied because the stale-by-edit re-enumeration guard below is the
        /// (editor-find) finding-3 fix, and a second copy of a guard that subtle is a live drift
        /// risk against exactly the defect it exists to prevent; the recolor pair, the scroll and
        /// the count report are direction-independent for the same reason.
        private func stepFind(_ textView: NSTextView, backwards: Bool) {
            // (editor-find, finding 3, second round) `isFindSessionCurrent`'s doc comment calls the
            // ranges NOT safe to act on as if current while stale-by-edit — and scrolling to the
            // stepped-to match is exactly that. Failing case without this: paste text above the
            // current match, then press Cmd+G inside the ~150 ms debounce window before the pasted
            // characters have been re-enumerated — `refreshFind` already ran this same
            // `updateNSView` pass and skipped re-enumeration (its perf gate compares
            // `settledTextGeneration`, which a keystroke/paste does not bump), so stepping and
            // scrolling here would act on ranges describing the pre-paste text. Re-enumerating
            // nearest-to-the-current-match first (same seat rule `refreshFind`'s stale-on-close path
            // uses) puts the step on current ranges. `documentChangedThisPass` is never true by the
            // time this runs — `refreshFind`'s `defer` already cleared it, and its active branch
            // re-enumerates against any settle point a document change causes — so staleness here is
            // always the edit case, never the document one.
            if !isFindSessionCurrent, let textStorage = textView.textStorage {
                reenumerateFindSession(textView, textStorage: textStorage, seatOnNearest: true)
            }
            // With nothing to step to, `stepNext()`/`stepPrevious()` is a no-op — returning early
            // additionally skips a pointless full-range attribute removal and the redraw it would
            // invalidate.
            guard !findSession.matches.isEmpty else { return }
            let previousRange = findSession.currentRange
            if backwards {
                findSession.stepPrevious()
            } else {
                findSession.stepNext()
            }
            // (editor-find, finding 8) Recolor only the two ranges that actually changed color — the
            // match that WAS current (back to the ordinary match color) and the match that IS now
            // current (to the distinct color) — rather than `applyFindHighlights`'s full
            // remove-over-everything-then-add-per-match pass. Every OTHER match's temporary
            // attribute is untouched and still exactly right, because nothing between here and the
            // last full repaint mutated a character (a step never does). Holding Cmd+G or
            // Cmd+Shift+G on a capped 20,000-match search would otherwise repeat a full-range
            // `removeTemporaryAttribute` plus up to 20,000 `addTemporaryAttributes` calls per press.
            recolorFindMatch(textView, range: previousRange, color: Theme.findMatchBackground)
            recolorFindMatch(textView, range: findSession.currentRange, color: Theme.findCurrentMatchBackground)
            scrollToCurrentFindMatch(textView)
            reportFindCount(findSession.countLabel)
        }

        /// (editor-find, finding 8) Sets exactly one match's temporary background color — the
        /// building block `stepFind` uses instead of a full `applyFindHighlights` repaint.
        /// `range` is `nil` only when there is nothing to recolor (defensive; `stepFind`'s
        /// non-empty-matches guard makes both ranges it passes non-nil in practice, by the same
        /// invariant `FindSession.currentRange` documents). Intersected with the storage's full
        /// range for the same reason `applyFindHighlights` is.
        private func recolorFindMatch(_ textView: NSTextView, range: NSRange?, color: NSColor) {
            guard let range,
                  let layoutManager = textView.layoutManager,
                  let textStorage = textView.textStorage
            else { return }
            let drawable = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
            guard drawable.length > 0 else { return }
            layoutManager.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: drawable)
        }

        /// Paints the match highlights as `NSLayoutManager` **temporary attributes** (D2) — display
        /// -only, owned by the layout manager, and therefore untouched by the highlighter's
        /// `textStorage.setAttributes` reset pass and never in contention with the Markdown
        /// code-span rules that own `.backgroundColor` in the text storage. A temporary attribute
        /// *replaces* the storage's value for its key while drawing rather than compositing with it,
        /// which is exactly why a match inside a code span reads as a match.
        ///
        /// Remove-over-the-full-range then add-per-match, deliberately: it is what makes "no orphan
        /// highlight ever survives" structural rather than a bookkeeping promise — a shrinking match
        /// set, a closed bar and a changed query all land in the same one line.
        func applyFindHighlights(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textStorage = textView.textStorage
            else { return }

            let fullRange = NSRange(location: 0, length: textStorage.length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

            for (index, match) in findSession.matches.enumerated() {
                // Intersected even though `refreshFind` has already clamped: this method is reachable
                // from three call sites, and the cost of being wrong here is an `NSRangeException`.
                let drawable = NSIntersectionRange(match, fullRange)
                guard drawable.length > 0 else { continue }
                let color = index == findSession.currentIndex
                    ? Theme.findCurrentMatchBackground
                    : Theme.findMatchBackground
                layoutManager.addTemporaryAttributes([.backgroundColor: color], forCharacterRange: drawable)
            }
        }

        /// Scrolls the current match into view, if there is one. Intersected with the storage's full
        /// range for the same reason as the highlights above.
        func scrollToCurrentFindMatch(_ textView: NSTextView) {
            guard let textStorage = textView.textStorage,
                  let current = findSession.currentRange
            else { return }
            let visible = NSIntersectionRange(current, NSRange(location: 0, length: textStorage.length))
            guard visible.length > 0 else { return }
            textView.scrollRangeToVisible(visible)
        }

        /// (D9) Places a collapsed caret at `range`'s start when the find bar closes — the one
        /// selection write a whole find session costs. Wrapped in `isProgrammaticUpdate` so the
        /// synchronous `textViewDidChangeSelection` report is suppressed (it would write
        /// `@Published` model state from inside a SwiftUI update pass), and the report is re-issued
        /// deferred instead — the same pattern the file-switch and external-reload branches use.
        private func placeCaretAtFindMatch(_ textView: NSTextView, range: NSRange) {
            guard let textStorage = textView.textStorage else { return }
            let location = min(max(range.location, 0), textStorage.length)
            isProgrammaticUpdate = true
            textView.setSelectedRange(NSRange(location: location, length: 0))
            isProgrammaticUpdate = false
            DispatchQueue.main.async { [weak self] in
                self?.parent.onCursorChange?(location)
            }
        }

        /// Hands the count label out to the model, only when it changed (mirrors
        /// `reportFirstVisibleLineIfChanged`). Deferred one runloop pass because the sink writes
        /// `@Published` state and this can run inside SwiftUI's update pass; `parent` is read at fire
        /// time so the callback is never a stale struct copy's.
        private func reportFindCount(_ label: String) {
            guard label != lastReportedFindCountLabel else { return }
            lastReportedFindCountLabel = label
            DispatchQueue.main.async { [weak self] in
                self?.parent.onFindCountChange?(label)
            }
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

/// (editor-find) The editor's `NSTextView`, subclassed for exactly one behavior: Esc closes the
/// find bar when focus is in the **text** rather than in the bar's query field (criterion 18).
///
/// SwiftUI's `.keyboardShortcut(.cancelAction)` on the bar's Done button only fires while the
/// SwiftUI side owns the key window's focus; once the user clicks into the editor to read around a
/// match, Esc goes down the AppKit responder chain instead and would otherwise do nothing at all.
/// `cancelOperation(_:)` is the responder-chain hook Esc is bound to, so this is the one place that
/// key can be caught without installing a global event monitor.
///
/// It claims Esc **only** when the closure says a find bar is actually open; otherwise it falls
/// through to `super`, so the editor's Esc behavior is unchanged whenever find is not in use.
final class FindableTextView: NSTextView {
    /// Invoked on Esc; returns `true` if it consumed the key. Set once in
    /// `CodeEditorView.makeNSView`, capturing the coordinator weakly.
    var onEscape: (() -> Bool)?

    override func cancelOperation(_ sender: Any?) {
        // (editor-find, finding 6, second round) During IME marked-text composition (e.g. Japanese/
        // Chinese), Esc's job is to cancel the composition, not close the find bar — falling through
        // to `super` unconditionally here would otherwise let the find bar steal that Esc every time
        // the bar happens to be open while the user is mid-composition.
        if !hasMarkedText(), onEscape?() == true { return }
        super.cancelOperation(sender)
    }
}
