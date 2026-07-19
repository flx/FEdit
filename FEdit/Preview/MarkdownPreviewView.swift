//
//  MarkdownPreviewView.swift
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

/// The read-only Markdown preview column (SPEC §8, §4): an `NSTextView`, backed by an explicit
/// TextKit 1 stack, showing `MarkdownRenderer`'s output for the open Markdown file. Mounted by
/// `ContentView` iff `WorkspaceModel.isMarkdown`.
struct MarkdownPreviewView: NSViewRepresentable {
    /// The live editor buffer for the open Markdown file.
    let text: String

    /// Identity of the currently open file; a change is treated as a file switch — render
    /// immediately (off-main from Tier 2 onward) and reset the preview's scroll to the top.
    let fileURL: URL?

    /// The editor's 0-based first-visible logical line (editor-core's throttled report, same
    /// line base as `MarkdownAnchor.sourceLine`), driving the one-way editor→preview scroll sync
    /// (SPEC §8.3, Tier 3).
    let firstVisibleLine: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        // Explicit TextKit 1 stack, wired storage → layout manager → container in the required
        // order (mirrors `CodeEditorView`; never the `NSTextView(frame:)` convenience
        // initializer, which hands back a TextKit 2 stack instead). `textStorage` is a strong
        // stored property on the coordinator for the same reason as `CodeEditorView`'s: without a
        // strong owner outside this method, the storage would deallocate the moment `makeNSView`
        // returns.
        let textStorage = coordinator.textStorage
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalRuler = false
        scrollView.rulersVisible = false

        // Seeded from the scroll view's own content size — not a hardcoded zero/infinite width,
        // which would disable wrapping. Height stays unbounded so layout is never truncated.
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

        // Read-only but selectable (criterion 1): the user can select/copy rendered text but
        // never edit it. Link clicks rely on `NSTextView`'s default `.link`-attribute handling —
        // the renderer only ever attaches a Foundation `URL`, which the default open-on-click
        // path handles.
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.backgroundColor = Theme.background
        textView.textContainerInset = NSSize(width: 10, height: 10)

        scrollView.documentView = textView
        coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(text: text, fileURL: fileURL, firstVisibleLine: firstVisibleLine)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Unmount safety: a render in flight for a detached view must never fire — otherwise it
        // renders into a view nobody can see and (in the file-switch/generation-guarded paths)
        // wastes the background render for nothing.
        coordinator.cancelPendingRender()
    }

    final class Coordinator {
        /// Strong — keeps the hand-assembled TextKit 1 stack alive for the life of the view (see
        /// the ownership note in `makeNSView`).
        let textStorage = NSTextStorage()

        weak var textView: NSTextView?

        /// One anchor per rendered block (SPEC §8.3), populated by every render; unused until
        /// Tier 3's scroll-sync lookup.
        private(set) var anchors: [MarkdownAnchor] = []

        private var currentFileURL: URL?

        /// The last source line the preview was scrolled to via the editor→preview anchor sync
        /// (Tier 3), or `nil` before any sync has happened for the current file.
        private var lastSyncedLine: Int?

        /// Whether an anchor sync (`syncToLine`) has happened since the previous render
        /// completed (Tier 3 ordering rule, criterion 10). Read by `applyRenderResult`: if set,
        /// a completed render re-applies the anchor for `lastSyncedLine` against the FRESH
        /// anchors instead of restoring the pre-render pixel offset — a sync that landed during
        /// the pending window must never be resolved through stale anchors and then pinned by
        /// the pixel restore.
        private var syncSinceLastRender = false

        /// Redundant-render guard (needed from Tier 1): the text most recently rendered or (from
        /// Tier 2 onward) already scheduled to render. Without it, `updateNSView` would re-render
        /// on every unrelated SwiftUI pass — divider drags, filter typing, cursor-callback
        /// `@State` writes — and, once debounced, would keep re-arming the debounce timer on
        /// every such pass instead of only on genuine text changes.
        private var lastKnownText: String?

        /// The pending ~200–250 ms debounced render (Tier 2), if any. Cancelled and rescheduled
        /// on every genuine text change; cancelled outright on file switch and on unmount.
        private var pendingRenderWorkItem: DispatchWorkItem?

        /// Monotonic counter guarding a background render against staleness: a completed render
        /// is applied only if this still matches the coordinator's current generation (i.e. no
        /// newer render was scheduled, and the file has not switched, since this one started).
        private var renderGeneration = 0

        /// Runs the pure, thread-safe `MarkdownRenderer.render` call off the main thread (the
        /// renderer's own doc comment: "safe to call off the main thread") so a pathological
        /// bracket-heavy document cannot freeze the UI. All AppKit/text-storage/scroll work stays
        /// on the main thread.
        private static let renderQueue = DispatchQueue(label: "FEdit.MarkdownPreview.render", qos: .utility)

        deinit {
            pendingRenderWorkItem?.cancel()
        }

        func update(text: String, fileURL: URL?, firstVisibleLine: Int) {
            if fileURL != currentFileURL {
                switchFile(to: fileURL, text: text, firstVisibleLine: firstVisibleLine)
                return
            }
            if text != lastKnownText {
                scheduleRender(text: text)
            }
            if firstVisibleLine != lastSyncedLine {
                syncToLine(firstVisibleLine)
            }
        }

        /// Cancels any pending debounced render (called from `dismantleNSView`).
        func cancelPendingRender() {
            pendingRenderWorkItem?.cancel()
            pendingRenderWorkItem = nil
        }

        // MARK: - File switch

        private func switchFile(to url: URL?, text: String, firstVisibleLine: Int) {
            pendingRenderWorkItem?.cancel()
            pendingRenderWorkItem = nil

            currentFileURL = url
            lastKnownText = text

            // File-switch fix (plan's High defect #1): consume the incoming (still-stale,
            // previous-file) `firstVisibleLine` value into `lastSyncedLine` instead of resetting
            // to `nil` — a `nil` reset would make ContentView's next throttled report for the
            // *old* file (still in flight for ~100–200 ms after the switch) register as a "new"
            // sync and double-jump the scroll. `syncSinceLastRender` resets to `false`: the
            // file-switch render below always scrolls to top unconditionally, so there is
            // nothing for a later anchor re-apply to resolve.
            lastSyncedLine = firstVisibleLine
            syncSinceLastRender = false

            renderGeneration += 1
            let generation = renderGeneration

            Self.renderQueue.async { [weak self] in
                let rendered = MarkdownRenderer.render(text)
                DispatchQueue.main.async {
                    self?.applyRenderResult(rendered, fileURL: url, generation: generation, resetScrollToTop: true, capturedOrigin: .zero)
                }
            }
        }

        // MARK: - Debounced render

        private func scheduleRender(text: String) {
            lastKnownText = text
            let fileURL = currentFileURL

            renderGeneration += 1
            let generation = renderGeneration

            pendingRenderWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                Self.renderQueue.async {
                    let rendered = MarkdownRenderer.render(text)
                    DispatchQueue.main.async {
                        self?.finishDebouncedRender(rendered, text: text, fileURL: fileURL, generation: generation)
                    }
                }
            }
            pendingRenderWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(220), execute: workItem)
        }

        /// Captures the pre-swap scroll origin on the main thread right before applying a
        /// debounced render's result — the capture must happen here (not at schedule time), per
        /// the Tier 2 scroll-preservation rule.
        private func finishDebouncedRender(
            _ rendered: (output: NSAttributedString, anchors: [MarkdownAnchor]),
            text: String,
            fileURL: URL?,
            generation: Int
        ) {
            guard generation == renderGeneration, fileURL == currentFileURL,
                  let textView, let scrollView = textView.enclosingScrollView
            else { return }
            let origin = scrollView.documentVisibleRect.origin
            applyRenderResult(rendered, fileURL: fileURL, generation: generation, resetScrollToTop: false, capturedOrigin: origin)
        }

        // MARK: - Apply (main thread only)

        private func applyRenderResult(
            _ rendered: (output: NSAttributedString, anchors: [MarkdownAnchor]),
            fileURL: URL?,
            generation: Int,
            resetScrollToTop: Bool,
            capturedOrigin: NSPoint
        ) {
            // Staleness guard: drop this result if a newer render was scheduled, or the file
            // switched, since this one started.
            guard generation == renderGeneration, fileURL == currentFileURL,
                  let textView, let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager, let textContainer = textView.textContainer
            else { return }

            textStorage.setAttributedString(rendered.output)
            anchors = rendered.anchors

            // Layout invariant (Tier 2, restated for Tier 3): every scroll computation is
            // preceded by a full-document `ensureLayout` — `documentHeight`/clamping is only
            // correct once layout is complete.
            layoutManager.ensureLayout(for: textContainer)

            let clipView = scrollView.contentView
            if resetScrollToTop {
                clipView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(clipView)
            } else if syncSinceLastRender, let lastSyncedLine {
                // Tier 3 ordering rule (criterion 10): a sync that occurred since the previous
                // render must be resolved against the FRESH anchors just assigned above — never
                // pinned by the pixel offset captured before this edit.
                scrollToAnchor(forLine: lastSyncedLine)
            } else {
                let maxY = maxScrollY(clipView: clipView, layoutManager: layoutManager, textContainer: textContainer)
                let clampedY = min(max(capturedOrigin.y, 0), maxY)
                clipView.scroll(to: NSPoint(x: capturedOrigin.x, y: clampedY))
                scrollView.reflectScrolledClipView(clipView)
            }
            syncSinceLastRender = false
        }

        // MARK: - Scroll sync (Tier 3)

        /// Called from `update` when the editor's throttled first-visible-line report changes.
        /// No extra debounce — the editor callback is already throttled — so this scrolls
        /// immediately against whatever anchors are currently available (possibly stale, if a
        /// render is pending; the ordering rule above resolves that once the render completes).
        private func syncToLine(_ line: Int) {
            lastSyncedLine = line
            syncSinceLastRender = true
            scrollToAnchor(forLine: line)
        }

        /// Scrolls the clip view so the anchor with the greatest `sourceLine ≤ line` sits at the
        /// viewport top; scrolls to top if there are no anchors or `line` is below the first
        /// anchor's `sourceLine`.
        private func scrollToAnchor(forLine line: Int) {
            guard let textView, let scrollView = textView.enclosingScrollView,
                  let layoutManager = textView.layoutManager, let textContainer = textView.textContainer
            else { return }

            // Layout invariant: `boundingRect(forGlyphRange:in:)` only forces layout up to the
            // anchor, which would understate the clamp's upper bound — full layout first.
            layoutManager.ensureLayout(for: textContainer)
            let clipView = scrollView.contentView

            guard let anchor = anchor(forLine: line) else {
                clipView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(clipView)
                return
            }

            // UTF-16 offset → glyph range. A trailing empty block can anchor at
            // `location == output.length`; `boundingRect(forGlyphRange:in:)` is documented to
            // tolerate a zero-length range (it's the same mechanism used for caret rects at
            // end-of-storage), so no special-casing is needed here.
            let characterRange = NSRange(location: anchor.location, length: 0)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            let targetY = rect.minY + textView.textContainerInset.height

            let maxY = maxScrollY(clipView: clipView, layoutManager: layoutManager, textContainer: textContainer)
            let clampedY = min(max(targetY, 0), maxY)
            clipView.scroll(to: NSPoint(x: 0, y: clampedY))
            scrollView.reflectScrolledClipView(clipView)
        }

        /// Binary search for the greatest anchor with `sourceLine ≤ line` (anchors are strictly
        /// ascending in both fields per the producer contract). `nil` if `anchors` is empty or
        /// every anchor's `sourceLine` exceeds `line`.
        private func anchor(forLine line: Int) -> MarkdownAnchor? {
            guard !anchors.isEmpty else { return nil }
            var low = 0
            var high = anchors.count - 1
            var result: MarkdownAnchor?
            while low <= high {
                let mid = (low + high) / 2
                if anchors[mid].sourceLine <= line {
                    result = anchors[mid]
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return result
        }

        // MARK: - Geometry

        private func maxScrollY(
            clipView: NSClipView,
            layoutManager: NSLayoutManager,
            textContainer: NSTextContainer
        ) -> CGFloat {
            let documentHeight = layoutManager.usedRect(for: textContainer).height
                + (textView?.textContainerInset.height ?? 0) * 2
            return max(0, documentHeight - clipView.bounds.height)
        }
    }
}
