# markdown-preview

**Risk tier:** standard — glue between an existing pure renderer and AppKit scrolling; the only subtle part (scroll-offset preservation vs. anchor sync) is contained in one coordinator, no wide blast radius, no heavy algorithms.

## Goal

Mount the Markdown preview column (SPEC §8, §4): a read-only, selectable TextKit 1 `NSTextView` in the third column of `ContentView`, shown iff the open file is Markdown, displaying `MarkdownRenderer` output. Re-render on edit (debounced) with the preview's scroll position preserved. One-way editor→preview scroll sync (SPEC §8.3): on the editor's throttled first-visible-line report, scroll the preview so the block anchor with the greatest source line ≤ the editor's first visible line sits at the top of the preview viewport. Approximate, sub-second, never syncing back.

## Acceptance criteria

Column lifecycle:
1. Open an `.md` file → preview column appears (per §4 the split-layout column logic already exists; this item fills it) showing the rendered document, styled per §8.2, links clickable, text selectable but not editable.
2. Switch to a `.swift`/`.py`/plain file → preview column disappears; switch back to the `.md` file → it reappears, rendered fresh from the current buffer text (reflects the last saved state — after open-save's dialog flow the buffer *is* disk content by construction, so "not stale disk content" was untestable as worded).
3. Switching between two different `.md` files resets the preview scroll to the top and shows the new file's content (no carried-over offset from the previous file).

Re-render with scroll preservation:
4. With the preview scrolled mid-document, typing in the editor updates the preview within ~0.5 s (debounce ≤ 300 ms + render + full-document `ensureLayout` — the layout pass is inside this budget) and the preview's vertical scroll offset is visually unchanged (clamped only if the document shrank below the old offset). Note: pixel-offset preservation is **not content-relative** — typing above the viewport shifts content under the fixed pixel offset. This is the SPEC-sanctioned reading; testers should not file that drift as a bug. Correction rule: if an anchor sync occurred while the render was pending, the completed render re-applies the anchor for the last synced line against the fresh anchors instead of restoring the pixel offset (see Tier 3 ordering rule).
5. Continuous typing does not render on every keystroke (debounce coalesces; at most one render per quiet period).
6. Empty file, file that fits entirely in the viewport, and a file with no block anchors (e.g. all blank lines) render without crash and without scroll jumps.

Scroll sync (one-way, editor → preview):
7. Scrolling the editor (with no render pending) so that logical line N is the first visible line scrolls the preview so the output position of the anchor with the greatest `sourceLine ≤ N` is at the top of the preview viewport, within sub-second latency (throttle from editor-core + immediate anchor scroll — no additional debounce on the preview side). A sync arriving while a render is pending is resolved by the post-render anchor re-apply (criterion 10).
8. Editor at top of document → preview at top. Editor scrolled past the last anchor's source line → preview shows the last block at top (clamped to max scroll; short documents simply pin to bottom-most valid offset).
9. Scrolling the preview never moves the editor, and does not get "corrected" until the next editor scroll event arrives.
10. Sync and re-render do not fight: an edit-triggered re-render restores the pre-render pixel offset **only when no anchor sync intervened since the previous render**; if a sync did occur during the pending window, the completed render re-applies the anchor for `lastSyncedLine` against the fresh anchors (never pinning a position computed from stale anchors). Otherwise, only a subsequent editor scroll event re-applies anchor positioning.

## Tiers

### Tier 1 — Preview view mounted in the third column (static render)

**Create `FEdit/Preview/MarkdownPreviewView.swift`:**
- `struct MarkdownPreviewView: NSViewRepresentable` (makes an `NSScrollView`). Inputs for this tier: `text: String` (the live editor buffer for the open Markdown file), `fileURL: URL?` (identity key for file switches).
- `final class Coordinator`: owns the AppKit stack and the last-rendered anchors.
- `makeNSView`: build an explicit TextKit 1 stack — `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` — wired into an `NSTextView` inside an `NSScrollView`. Configuration: `isEditable = false`, `isSelectable = true`, white background, container tracks text-view width (wrapping, no horizontal scroller), vertical scroller only, sensible `textContainerInset` (~8–12 pt). No ruler. Link clicks use `NSTextView`'s default behavior for `.link` attributes — the producer contract commits to emitting `.link` values as Foundation `URL`s (unparseable URLs get no attribute at all), which the default open-on-click handles; the String-value contingency is closed by that contract.
- Rendering: call `MarkdownRenderer` on the input text, `textStorage.setAttributedString(_:)` the result, store the anchors on the coordinator (unused until Tier 3).
- `updateNSView` (this tier): if `fileURL` changed → render immediately and scroll to top; else if `text` changed → render immediately (debounce comes in Tier 2).
- Redundant-render guard (needed from Tier 1, not Tier 2): track the last-rendered source string (or a cheap hash) so an `updateNSView` pass with unchanged text/file is a no-op. Without it, Tier 1 re-renders on every unrelated SwiftUI pass — divider drags, filter typing, cursor-callback `@State` writes — and is not implementable as described.

**Modify `FEdit/Views/ContentView.swift`:**
- Replace the preview-column stub content (from split-layout) with `MarkdownPreviewView(text:fileURL:)` fed from `WorkspaceModel`'s open file. Column visibility condition stays exactly the existing `isMarkdown` gate — no divider/layout changes.

Buildable/revertible: yes — a working static preview; reverting restores the stub column. Covers criteria 1–3.

### Tier 2 — Debounced re-render with scroll preservation

**Modify `FEdit/Preview/MarkdownPreviewView.swift` (coordinator only):**
- Debounce: keep a `DispatchWorkItem` (~200–250 ms) scheduled from `updateNSView` on text change; cancel-and-reschedule on each change; render on main queue when it fires. File switch (`fileURL` change) cancels any pending work item and renders immediately with scroll reset to top.
- Scroll preservation: before `setAttributedString`, capture `scrollView.documentVisibleRect.origin`; after the swap, `layoutManager.ensureLayout(for:)` the container, then restore the captured origin clamped to the new document height via `clipView.scroll(to:)` + `scrollView.reflectScrolledClipView(_:)`.
- **Layout invariant** (stated once, applies to all three scroll paths — debounced render, file-switch render, and Tier 3's anchor scroll): any scroll computation (pixel restore or anchor scroll) is preceded by `layoutManager.ensureLayout(for: textContainer)`. `documentHeight` is only correct after full layout, and `boundingRect(forGlyphRange:)` only forces layout up to the anchor, so without this the clamp's upper bound can be understated right after a file switch or width change. The O(document) cost per invocation is accepted per the small-files stance (and is included in criterion 4's ~0.5 s budget).
- Unmount safety: cancel the pending debounce `DispatchWorkItem` in `dismantleNSView` — otherwise an unmount with a render in flight renders into a detached view.
- (The redundant-render guard — last-rendered source string/hash — lives in Tier 1; it is a prerequisite for Tier 1's `updateNSView` logic, not a Tier 2 addition.)

No other files change. Buildable/revertible: yes — reverting degrades to Tier 1's immediate re-render. Covers criteria 4–6.

### Tier 3 — Editor→preview scroll sync

**Modify `FEdit/Views/ContentView.swift`:**
- Hold `@State private var editorFirstVisibleLine: Int = 0`, assigned from `CodeEditorView`'s existing throttled first-visible-line callback (editor-core). Pass it into `MarkdownPreviewView(text:fileURL:firstVisibleLine:)`.
- Reset `editorFirstVisibleLine` to 0 via `.onChange(of: <open file URL>)` — the `@State` otherwise holds the *previous* file's line for ~100–200 ms after a switch (until the editor's throttled report for the new file arrives), and that stale value must not drive the new file's preview.
- Cost note (accepted knowingly): routing sync through `@State` re-evaluates ContentView's body once per throttled tick (~10 Hz while the editor scrolls). The direct coordinator-to-coordinator alternative is rejected to keep the two-file blast radius.

**Modify `FEdit/Preview/MarkdownPreviewView.swift`:**
- Add `firstVisibleLine: Int` input. Coordinator tracks `lastSyncedLine: Int?`; in `updateNSView`, if `firstVisibleLine` differs from `lastSyncedLine`, perform the anchor scroll (no extra debounce — the editor callback is already throttled).
- Anchor lookup: binary search the ascending anchor array for the greatest `sourceLine ≤ firstVisibleLine`. No anchors or `firstVisibleLine` below the first anchor → scroll to top.
- Scroll-to-anchor: convert the anchor's `.location` (UTF-16 offset) to a glyph range, `layoutManager.boundingRect(forGlyphRange:in:)`, then scroll the clip view so `rect.minY` (plus the text container inset) is at the viewport top, clamped to `[0, documentHeight − viewportHeight]` (preceded by `ensureLayout` per the Tier 2 layout invariant). The lookup must tolerate a zero-length range at end-of-storage: the producer warns a trailing empty block can anchor at `location == output.length`.
- Ordering rule (criterion 10): the coordinator tracks whether an anchor sync occurred since the previous render (a `syncSinceLastRender` flag or render generation counter). On render completion: if set → re-apply the anchor for `lastSyncedLine` against the FRESH anchors (a sync during the pending window must never be resolved through pre-edit anchors and then pinned by the pixel restore); if not set → restore the captured pixel offset. Anchor positioning otherwise happens only on a changed `firstVisibleLine`. This rule also covers typing that pushes the caret past the editor viewport (a first-visible-line change landing during the debounce window): the post-render re-apply positions it correctly, so the criterion-4/criterion-7 collision dissolves.
- File-switch handling (both ends must be fixed; a bare "reset `lastSyncedLine` to nil" would *guarantee* a spurious anchor jump — ContentView's `@State` still holds the old file's line until the new file's first throttled report, and a nil reset makes that stale value count as the first report, double-jumping on every switch from a scrolled file): (a) ContentView resets `editorFirstVisibleLine` to 0 on file switch (see above); (b) the coordinator's file-switch branch sets `lastSyncedLine = <the current incoming firstVisibleLine value>` — consuming the stale value — instead of nil, and/or carries the file identity alongside the line so reports belonging to the previous URL are discarded.
- Line-base check at implementation time: the editor's reported line index and the renderer's `sourceLine` must use the same base (assumed 0-based below); if they differ, adjust at the lookup site with a one-line offset.

Buildable/revertible: yes — reverting yields Tier 2 (preview without sync). Covers criteria 7–10.

## Interface between tiers

- Tier 1 → Tier 2: `MarkdownPreviewView(text:fileURL:)` signature is unchanged; Tier 2 is purely internal to the coordinator (debounce + offset capture/restore).
- Tier 2 → Tier 3: the initializer gains `firstVisibleLine: Int` (Tier 3's only cross-file surface, matched by the `@State` + callback wiring in `ContentView`). The coordinator's stored anchor array — populated since Tier 1 on every render — is the data handoff consumed by Tier 3's lookup.
- Nothing outside `Preview/MarkdownPreviewView.swift` and `Views/ContentView.swift` is touched in any tier.

## Load-bearing assumptions

Expected state from earlier TODO items (verify each at implementation start; deviations get absorbed at the call site, not by redesigning):

1. **(markdown-renderer)** `FEdit/Preview/MarkdownRenderer.swift` exposes a pure render function, `String → (NSAttributedString, anchors)`. Producer contract, verbatim: `struct MarkdownAnchor { let sourceLine: Int; let location: Int }` — a struct with `.location` = UTF-16 offset into the attributed string (not a tuple named `outputLocation`), both fields strictly ascending; one anchor per block element; `sourceLine` counts logical source lines. Assumed 0-based (see Tier 3 line-base check). Producer warning: a trailing empty block can anchor at `location == output.length`, so the `boundingRect` lookup must tolerate a zero-length range at end-of-storage.
2. **(editor-core)** `FEdit/Editor/CodeEditorView.swift` exposes a throttled callback reporting the first visible logical line (SPEC §6.4), pluggable from `ContentView` (e.g. a closure parameter). Same line-numbering base as the renderer's `sourceLine`.
3. **(open-save)** `Models/WorkspaceModel.swift` exposes the open file's URL, its live text (readable from `ContentView` — direct property or binding), and a real `isMarkdown` flag.
4. **(split-layout)** `Views/ContentView.swift` already lays out the third column iff `isMarkdown` (divider 2, clamping, persistence all done) with a placeholder body this item replaces; no divider logic is modified here.
5. **(syntax-highlighting)** `Editor/Theme.swift` provides fonts/colors; the renderer already consumes it, so this item needs no direct Theme dependency beyond possibly the preview background color.
6. **(xcode-scaffold)** file-system-synchronized Xcode group: adding `Preview/MarkdownPreviewView.swift` on disk requires no project-file edits; GPL header boilerplate convention applies to the new file.

## Out of scope

- Preview→editor scroll sync (explicit v1 non-goal, SPEC §12).
- Any change to the renderer itself (block/inline parsing, anchor emission) — bugs found there are filed against (markdown-renderer).
- Syntax highlighting inside fenced code blocks in the preview (SPEC §8.2: not in v1).
- Divider/layout/persistence changes; preview scroll position persistence across relaunch.
- Preserving the preview's text selection across re-renders (selection may collapse on re-render; only scroll offset is preserved).
- Tables, images, nested lists, HTML passthrough, dark mode (v1 non-goals).

## Auto-resolved (plan review)

Findings from adversarial plan review, folded into the sections above:

**Defects fixed:**
1. **(High) Stale first-visible-line at file switch.** The original "reset `lastSyncedLine` to nil on file switch" guaranteed a spurious anchor jump: ContentView's `@State` holds the old file's line for ~100–200 ms until the editor's throttled report arrives, and the nil reset made that stale value count as the first report (double-jump on every switch from a scrolled file). Fixed at both ends: ContentView resets `editorFirstVisibleLine` to 0 via `.onChange(of: <open file URL>)`, and the coordinator's file-switch branch consumes the stale value (`lastSyncedLine = current incoming value`) and/or carries file identity to discard reports for the previous URL. (Tier 3.)
2. **(High) Edit-then-scroll window.** A sync landing while a render is pending mapped new line numbers through old anchors, and the old ordering rule (pixel restore + "do not re-apply anchor") pinned the wrong position forever. Amended: track `syncSinceLastRender` (flag or render generation counter); on render completion, re-apply the anchor for `lastSyncedLine` against the fresh anchors if set, restore the pixel offset only if not. Criterion 7 scoped with "(with no render pending)"; correction rule stated in criteria 4 and 10. (Tier 3 ordering rule.)
3. **(Medium) Layout completeness.** Invariant stated once in Tier 2: every scroll computation (pixel restore or anchor scroll) is preceded by `ensureLayout(for: textContainer)`, across all three paths (debounced render, file-switch render, anchor scroll) — `documentHeight` is only correct after full layout; `boundingRect` only forces layout up to the anchor, understating the clamp's upper bound after a switch or width change. O(document) cost accepted per the small-files stance.
4. **(Low) Producer contract quoted verbatim** in load-bearing assumption 1: `struct MarkdownAnchor { let sourceLine: Int; let location: Int }`, `.location` = UTF-16 offset, both strictly ascending — not a tuple named `outputLocation`. Trailing-empty-block warning added: `location == output.length` is legal; the `boundingRect` lookup tolerates a zero-length range at end-of-storage.
5. **(Low) Redundant-render guard moved Tier 2 → Tier 1.** Without it Tier 1 re-renders on every unrelated SwiftUI pass (divider drags, filter typing, cursor-callback `@State` writes) and is not implementable as described.
6. **(Low) Link values closed by producer contract.** The renderer emits `.link` as Foundation `URL` values (unparseable URLs get no attribute); NSTextView's default open-on-click handles them. String-value contingency dropped.
7. **(Low) Unmount safety.** Tier 2 cancels the pending debounce `DispatchWorkItem` in `dismantleNSView` — an unmount with a render in flight would otherwise render into a detached view.

**Tensions resolved (recorded as accepted trade-offs):**
8. Pixel-offset preservation is not content-relative: typing above the viewport shifts content under the fixed offset — SPEC-sanctioned reading, stated in criterion 4 so testers don't file the drift as a bug.
9. Typing that pushes the caret past the editor viewport fires a first-visible-line change; with fix 2 the post-render anchor re-apply handles it correctly — the criterion-4/criterion-7 collision dissolves (recorded in the Tier 3 ordering rule).
10. Full-document `ensureLayout` on every debounced render: accepted; criterion 4's ~0.5 s budget includes it (small files).
11. Routing sync through `@State` costs a ContentView body re-eval per throttled tick (~10 Hz): accepted knowingly; the direct coordinator-to-coordinator alternative is rejected to keep the two-file blast radius.
12. Criterion 2's "(not stale disk content)" reworded to "reflects the last saved state" — after open-save's dialog the buffer *is* disk content by construction; the original wording was untestable.
