# editor-core

**Risk tier:** standard — well-trodden AppKit pattern (explicit TextKit 1 stack + custom NSRulerView); no concurrency, no tricky algorithms; blast radius is two new files plus one wiring point in ContentView and a small additive change to WorkspaceModel.

## Goal

Give the middle column a real code editor: an `NSTextView` built on an explicitly constructed TextKit 1 stack, wrapped in `NSViewRepresentable`, with a logical-line-number gutter, loading whatever file the sidebar selects. Editing is allowed but nothing is saved yet. The editor reports its first visible logical line and cursor position via callbacks so later items ((markdown-preview), (session-restore)) can consume them. Spec §6.1–§6.2, §6.4.

## Acceptance criteria — concrete and testable

1. **Build & placeholder:** `xcodebuild` succeeds. With no file selected, the middle column shows a centered muted "No file open" placeholder (no text view).
2. **File loads on selection:** Clicking a file in the sidebar shows its content in the editor (UTF-8, Latin-1 fallback). Selecting a different file replaces the content. **Clicking the already-open file's row is a no-op** (no reload, no caret/scroll reset). An unreadable file does not crash; the sidebar highlight moves to the clicked row while the editor keeps showing the previous file — this split state is **expected interim behavior** until (open-save) adds selection revert and error alerting.
3. **TextKit 1 stack:** The text view is created via `NSTextView(frame:textContainer:)` over an explicitly built `NSTextStorage` + `NSLayoutManager` + `NSTextContainer` (never the convenience initializers, which would produce TextKit 2). `textView.layoutManager` is non-nil without triggering any compatibility downgrade. **Ownership:** in a hand-assembled stack the strong references run *downward only* (storage → layout manager → container; the text view retains only its container; back-pointers are weak), so the Coordinator holds a strong stored reference to the `NSTextStorage` for the life of the view — otherwise the storage deallocates after `makeNSView` returns (classic crash).
4. **Wrapping, no horizontal scroll:** Long lines wrap at the view width at every window/divider width; the scroll view never shows a horizontal scroller; resizing the window rewraps live.
5. **Editor look & typing behavior:** Monospaced system font 13 pt, white background, near-black text. Typing `"`, `--`, `(c)` produces exactly those characters (all smart quotes/dashes/text replacement/spell-correction/data-and-link detection off).
6. **Undo:** Cmd+Z works while editing one file. After switching files, Cmd+Z does nothing (undo stack cleared); it cannot resurrect the previous file's edits.
7. **Binding flow without feedback loops:** Typing rapidly never causes cursor jumps, duplicated characters, or dropped keystrokes (programmatic `updateNSView` writes are guarded and never round-trip through the delegate back into the binding).
8. **Line numbers — logical lines:** Gutter shows 1-based numbers counting logical lines. A line long enough to wrap shows its number only on its first visual fragment; continuation fragments show none. A trailing empty last line (file ending in `\n`) and the empty document both show a numbered line.
9. **Gutter width adapts:** A 5-line file and a 5,000-line file get different gutter widths; minimum width fits 2 digits; width updates when the line count crosses a digit boundary while typing. Numbers are right-aligned, gutter background light gray with a hairline separator.
10. **Visible-range-only drawing:** fragment enumeration is visible-range-only; line counting is O(document) per draw/scroll and accepted for v1's small-file target (do not cache line counts).
11. **Callbacks:** Scrolling fires `onFirstVisibleLineChange` with the 0-based logical line of the first visible text, throttled/deduplicated (no flood of identical values). Moving the caret fires `onCursorChange` with the selection location (UTF-16 offset). Both verified with a debug `print` consumer in ContentView.
12. **Edge cases (§11):** Empty file, file without trailing newline, single very long line, and CRLF file all open, edit, number, and scroll without crashing.

## Tiers — numbered implementation tiers, each independently buildable and revertible

### Tier 1 — CodeEditorView representable + file loading + ContentView wiring

**New file `FEdit/Editor/CodeEditorView.swift`** (GPL header per project convention):
- `struct CodeEditorView: NSViewRepresentable`. Inputs: `@Binding var text: String`, `let documentID: URL?` (identity of the open file; drives undo reset), `var cursorToRestore: Int? = nil` (defaulted — (session-restore)'s hook; all other call sites unchanged), plus callback properties added in Tier 3 (absent for now).
- `makeNSView` builds the stack explicitly with the wiring order spelled out: `NSTextStorage()` → `NSLayoutManager()` → `textStorage.addLayoutManager(layoutManager)` → `NSTextContainer(size:)` seeded from `scrollView.contentSize` (not zero/infinite width) with `widthTracksTextView = true` → `layoutManager.addTextContainer(textContainer)`; then `NSTextView(frame: .zero, textContainer:)`; wrapped in an `NSScrollView` (`hasVerticalScroller = true`, `hasHorizontalScroller = false`, `documentView = textView`). Text view config: `isVerticallyResizable = true`, `isHorizontallyResizable = false`, `autoresizingMask = [.width]`, `maxSize` unbounded vertically; `allowsUndo = true`; `isRichText = false`; font `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)` set on view and `typingAttributes`; `backgroundColor = .white`, `textColor` near-black (e.g. `NSColor(white: 0.1, alpha: 1)`); all of `isAutomaticQuoteSubstitutionEnabled`, `isAutomaticDashSubstitutionEnabled`, `isAutomaticTextReplacementEnabled`, `isAutomaticSpellingCorrectionEnabled`, `isAutomaticDataDetectionEnabled`, `isAutomaticLinkDetectionEnabled`, `isContinuousSpellCheckingEnabled`, `isGrammarCheckingEnabled`, `smartInsertDeleteEnabled` = false. Delegate = coordinator.
- `class Coordinator: NSObject, NSTextViewDelegate` holding `parent`, **`let textStorage: NSTextStorage` (strong — keeps the hand-assembled TextKit 1 stack alive; see acceptance criterion 3)**, `weak var textView`, `var currentDocumentID: URL?`, and `var isProgrammaticUpdate = false`. `textDidChange(_:)`: if `!isProgrammaticUpdate`, push `textView.string` into `parent.text`.
- `updateNSView`: first line is always `context.coordinator.parent = self` (stale-closure hygiene — load-bearing later for (syntax-highlighting)'s language updates). Then: if `documentID != coordinator.currentDocumentID` → file switch: set `isProgrammaticUpdate = true`, replace full string (`textView.string = text`), `textView.undoManager?.removeAllActions()` — note in a comment that this is the **window's shared NSUndoManager**, so it clears the whole window's undo stack; accepted explicitly for v1. Then apply the selection: if `cursorToRestore` is non-nil and not yet consumed for this `documentID`, clamp it to the text length, set the selection to that offset **synchronously**, defer `scrollRangeToVisible` to the next runloop pass (initial layout isn't complete inside the first `updateNSView`), and fire `onCursorChange(clampedValue)`; the restore is consumed **one-shot per documentID change**. Otherwise move insertion point to 0, scroll to top, and fire one explicit `onCursorChange(0)` so consumers ((session-restore)) never hold a stale previous-file offset — invariant: **callbacks always reflect the current document**. Because a programmatic `string =` does not post `NSText.didChangeNotification`, `updateNSView` also explicitly invalidates the ruler: recompute `ruleThickness` and set the ruler's `needsDisplay` (do not rely on frame-change side effects). Finally update `currentDocumentID`, clear the flag. Else if `textView.string != text` → external-change full replace: **kept but speculative — no shipped item triggers it yet**; caret goes to `min(old location, new length)`, undo is **not** cleared. Never write the binding from `updateNSView`.

**Modify `FEdit/Models/WorkspaceModel.swift`** (additive, minimal — (open-save) will supersede):
- `@Published var openFileURL: URL?` and `@Published var editorText: String = ""`.
- `func loadSelectedFile(_ url: URL)`: starts with an explicit same-URL guard — `guard url != openFileURL else { return }` — then read via `String(contentsOf:encoding: .utf8)`, fallback `.isoLatin1`; on success set both properties; on failure leave state unchanged (no alert yet).
- **Selection→load hook (DECISION, project-wide):** `ContentView` uses `.onChange(of: workspace.selectedFileURL)` to call `loadSelectedFile(url)`. There is **no model-side `didSet` observer** — writing the selection property must have **zero side effects at the model layer**. This invariant is load-bearing for (open-save)'s Cancel-revert: a surviving `didSet` would silently reload from disk and destroy the dirty buffer.

**Modify `FEdit/Views/ContentView.swift`** middle-column slot:
- `if let url = workspace.openFileURL { CodeEditorView(text: $workspace.editorText via model binding, documentID: url) } else { placeholder }` — placeholder: `Text("No file open")` in `.secondary` color, centered, white background.
- `.onChange(of: workspace.selectedFileURL)` → `loadSelectedFile(url)` (the hook decided above).
- **Stub-Toggle relocation (DECISION):** the (split-layout) stub `isMarkdown` Toggle currently lives in the editor placeholder column that Tier 1 replaces. Tier 1 relocates it to a slim temporary debug bar at the top of the middle column (above the editor / placeholder), clearly marked `// TODO(open-save): remove`; (open-save) deletes the bar. Three-column mode must stay testable in the interim.

Revert = delete `CodeEditorView.swift`, drop the two model properties + loader, restore the ContentView slot.

### Tier 2 — LineNumberRulerView

**New file `FEdit/Editor/LineNumberRulerView.swift`:**
- `final class LineNumberRulerView: NSRulerView`, init with `scrollView` and orientation `.verticalRuler`, `clientView = textView`.
- Observes: `NSText.didChangeNotification` (text view), `NSView.frameDidChangeNotification` (text view), `NSView.boundsDidChangeNotification` (clip view, `postsBoundsChangedNotifications = true`) → `needsDisplay = true` and recompute thickness.
- `ruleThickness`: width of the widest expected label = digit count of total logical line count (minimum 2 digits) rendered in a secondary-label-gray monospaced font ~10–11 pt, plus horizontal padding (~4 pt each side). Recomputed on text change; only reassigned when it actually changes (assignment retiles the scroll view).
- `drawHashMarksAndLabels(in:)`: fill gutter light gray (`NSColor(white: 0.95, alpha: 1)`) + 1 px separator at the trailing edge. Then:
  1. `visibleRect` of the text view → `layoutManager.glyphRange(forBoundingRect:in:)` → `characterRange(forGlyphRange:)` = visible character range.
  2. Count `\n` characters before `visibleRange.location` via the **shared line-counting helper** to get the starting line number — this is the only whole-prefix work and it is O(offset) on a small file; do **not** enumerate fragments from index 0. **One line-counting definition (project-wide):** logical lines are separated by `\n` ONLY (per SPEC §11) — **not** `NSString.lineRange` semantics, which also break on `\r`, U+0085, and U+2028 and would make the ruler's prefix count and line walk disagree on classic-Mac files. One shared helper implements it, used by the ruler's starting-number prefix count, the ruler's visible-range walk, and Tier 3's first-visible-line computation.
  3. Walk logical lines using the same `\n`-only helper (next line starts after the next `\n`) from the visible range's line start; for each, convert the line-start character index to a glyph index via `glyphIndexForCharacter(at:)` **before** calling `lineFragmentRect(forGlyphAt:effectiveRange:)` — that gives the **first fragment** rect — draw the right-aligned number at that fragment's y (converted via `convert(_:from: textView)` plus `textContainerOrigin`); skip continuation fragments implicitly by jumping to the next logical line. Stop once past `visibleRect.maxY`.
  4. If `layoutManager.extraLineFragmentTextContainer != nil` (empty doc or trailing `\n`) and the extra fragment intersects the visible rect, draw the final line number at `extraLineFragmentRect`.

**Modify `FEdit/Editor/CodeEditorView.swift`** (`makeNSView`): create the ruler, `scrollView.verticalRulerView = ruler`, `scrollView.hasVerticalRuler = true`, `scrollView.rulersVisible = true`.

Revert = delete the ruler file and the four installer lines.

### Tier 3 — scroll and cursor reporting

**Modify `FEdit/Editor/CodeEditorView.swift`:**
- Add `var onFirstVisibleLineChange: ((Int) -> Void)? = nil` and `var onCursorChange: ((Int) -> Void)? = nil` to the representable (trailing optional parameters — Tier 1/2 call sites unaffected).
- Coordinator subscribes to the clip view's `boundsDidChangeNotification`, and Tier 3 sets `clipView.postsBoundsChangedNotifications = true` itself (idempotent — otherwise only Tier 2's ruler sets it, and reverting Tier 2 would silently break Tier 3). Handler computes first visible logical line: visible glyph range → character range → count `\n` characters before its location (the **same shared `\n`-only helper as the ruler**; factor into a shared free function or small extension in this file). Fire the callback only when the value differs from the last reported one, coalesced through a ~100 ms `Timer`/`DispatchWorkItem` throttle (§6.4 "throttled").
- `textViewDidChangeSelection(_:)` in the coordinator reports `textView.selectedRange().location` through `onCursorChange` (skipped while `isProgrammaticUpdate`).

**Modify `FEdit/Views/ContentView.swift`:** pass both callbacks; for now store into two `@State` vars (or forward to `WorkspaceModel` stubs) with a `#if DEBUG` print — the real consumers arrive in (markdown-preview) and (session-restore).

Revert = drop the two properties, the observer, and the ContentView arguments.

## Interface between tiers

- Tier 1 → Tier 2: `CodeEditorView.makeNSView` exposes the built `scrollView`/`textView` locals where the ruler is installed; `LineNumberRulerView(textView:scrollView:)` is the only new symbol Tier 2 adds.
- Tier 1 → Tier 3: `Coordinator` (delegate + programmatic-update flag) is where selection reporting and the clip-view observer attach; the representable's initializer grows two defaulted optional closures, so Tier 1/2 code compiles unchanged.
- Tier 2 ↔ Tier 3: both need "logical line index for character offset"; Tier 3 factors the `\n`-only line-counting helper shared with the ruler (private to the Editor files; one definition, see Tier 2 step 2).
- Exported to later items: `CodeEditorView(text:documentID:cursorToRestore:onFirstVisibleLineChange:onCursorChange:)` (`cursorToRestore` defaults to nil — (session-restore)'s one-shot hook), `WorkspaceModel.openFileURL` / `.editorText` (interim, to be replaced by (open-save)'s open-file state).

## Load-bearing assumptions — expected types/APIs from earlier items

1. **(xcode-scaffold):** `FEdit.xcodeproj` uses a file-system-synchronized group, so new files under `FEdit/Editor/` join the target automatically; GPL header boilerplate convention exists to copy; app is light-appearance-only (so hard-coded white/light-gray editor colors are consistent with the rest).
2. **(split-layout):** `Views/ContentView.swift` has a distinct middle-column slot (currently a placeholder view) that this plan replaces; the divider logic is not touched. The stub `isMarkdown` Toggle lives inside that placeholder column, so Tier 1 relocates it to the temporary debug bar (see Tier 1) rather than deleting it — three-column mode stays testable.
3. **(folder-sidebar):** `Models/WorkspaceModel.swift` exists as a per-window `ObservableObject` reachable from `ContentView` (assumed `@StateObject`/`@EnvironmentObject`), with a published `selectedFileURL` property ("Selection just records the URL until (open-save)" per TODO). The hook is pinned (see Tier 1 DECISION): `ContentView` `.onChange(of: workspace.selectedFileURL)` → `loadSelectedFile(url)`; no model-side `didSet`; writing the selection property has zero model-layer side effects. If selection lives only in `SidebarView`, lift it into `WorkspaceModel` as part of Tier 1 (additive).
4. **Platform:** macOS 26 target — explicit-stack `NSTextView(frame:textContainer:)` remains the supported way to get a genuine TextKit 1 view; `NSRulerView`, `NSLayoutManager` fragment APIs available unchanged.
5. **(filter-query)** DOES overlap this plan: it touches `Models/WorkspaceModel.swift` (adds `@Published filterText`) and `Models/FileNode.swift` in addition to `Views/SidebarView.swift`. Since editor-core also modifies `WorkspaceModel.swift`, the two items must be **sequenced, not run in parallel**.

## Out of scope

- Saving, dirty tracking, "Edited" subtitle, unsaved-changes dialog, autosave, Cmd+S menu — (open-save).
- Binary/NUL detection and read-error alerts (§7) — this item only does a best-effort silent load; (open-save) replaces `loadSelectedFile` with the full pipeline.
- Syntax highlighting, `Theme.swift` — (syntax-highlighting).
- Markdown preview and consuming the first-visible-line callback for scroll sync — (markdown-preview).
- Cursor persistence/restoration — (session-restore); this item only emits the callback.
- Real `isMarkdown` driving the third column — stays the (split-layout) stub until (open-save).
- Any TextKit 2 migration, find/replace, tabs, dark mode (§12 non-goals).

## Auto-resolved (plan review)

Adversarial-review findings folded into the plan above:

**Defects**
1. (High) TextKit 1 ownership: strong references in a hand-assembled stack run downward only; the Coordinator now holds a strong `let textStorage: NSTextStorage` stored property for the life of the view, preventing the classic dealloc-after-`makeNSView` crash (criterion 3, Tier 1 Coordinator).
2. (High) Selection→load hook pinned as a project-wide DECISION: `ContentView` `.onChange(of: workspace.selectedFileURL)` → `loadSelectedFile(url)` with an explicit `guard url != openFileURL` same-URL guard; no model-side `didSet` (zero side effects on writing the selection — load-bearing for (open-save)'s Cancel-revert). "Clicking the open file's row is a no-op" added to criterion 2; "adapt at implementation time" hedging struck from assumption 3.
3. (Medium) One line-counting definition: logical lines are separated by `\n` only (SPEC §11), not `NSString.lineRange` semantics; one shared helper used by the ruler's prefix count, the ruler's visible-range walk, and Tier 3's first-visible-line computation (Tier 2 steps 2–3, Tier 3, interface section).
4. (Medium) Assumption 5 corrected: (filter-query) touches `WorkspaceModel.swift` (adds `@Published filterText`) and `FileNode.swift`, so it overlaps editor-core in `WorkspaceModel.swift` and the two must be sequenced, not parallel; garbled sentence fixed.
5. (Medium) DECISION: the (split-layout) stub `isMarkdown` Toggle (which lived in the placeholder column Tier 1 replaces) is relocated to a slim temporary debug bar atop the middle column, marked `// TODO(open-save): remove`; (open-save) deletes the bar. Three-column mode stays testable.
6. (Low) Tier 3 sets `postsBoundsChangedNotifications = true` itself (idempotent), so reverting Tier 2 no longer silently breaks scroll reporting.
7. (Low) After a programmatic file switch, `updateNSView` explicitly recomputes ruler thickness and sets `needsDisplay` (programmatic `string =` posts no `NSText.didChangeNotification`).
8. (Low) After a programmatic switch, one explicit `onCursorChange(0)` fires — invariant: callbacks always reflect the current document. Cross-plan cursor seam: `cursorToRestore: Int? = nil` added to `CodeEditorView`; consumed one-shot per `documentID` change — clamped to text length, selection applied synchronously in the doc-switch branch, `scrollRangeToVisible` deferred one runloop pass, and `onCursorChange(clampedValue)` fired instead of 0 when a restore is consumed. This is (session-restore)'s hook; default nil leaves other call sites unchanged.

**Tension resolutions**
9. Criterion 10 reworded: fragment enumeration is visible-range-only; line counting is O(document) per draw/scroll and accepted for v1's small-file target (no caching).
10. Unreadable-file interim state (sidebar highlight moves, editor keeps the old file until (open-save) adds revert) stated as expected interim behavior in criterion 2.
11. The speculative external-change full-replace branch in `updateNSView` is kept but specified: caret to `min(old location, new length)`, undo not cleared, and noted that no shipped item triggers it yet.
12. Undo reset uses the window's shared `NSUndoManager` (clears the whole window's stack) — accepted explicitly via a comment note in Tier 1.
13. Construction nits added: explicit `textStorage.addLayoutManager` / `layoutManager.addTextContainer` wiring order; `NSTextContainer` initial size seeded from `scrollView.contentSize`; explicit `glyphIndexForCharacter(at:)` conversion before `lineFragmentRect(forGlyphAt:)`; `coordinator.parent = self` refreshed at the top of every `updateNSView` (stale-closure hygiene, load-bearing for (syntax-highlighting)'s language updates).
