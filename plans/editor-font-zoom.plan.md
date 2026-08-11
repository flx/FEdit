# editor-font-zoom

**Risk tier:** elevated (hi) — the change converts the shared `Theme` editor-font API from `static let` constants to size-parametric functions, and that API is consumed by three subsystems at once (the editor `CodeEditorView`, the `SyntaxHighlighter` rule tables + reset pass, and the Markdown preview renderer via `Theme.codeFont`). On top of the wide blast radius it requires **live** `NSTextView` relayout — re-set font, full re-highlight, ruler re-measure — in **every** open window on each setting change, with caret and scroll position preserved across the relayout. No concurrency or algorithmic novelty (it rides the existing main-thread debounce), but the static-font refactor's reach plus the AppKit scroll-anchoring edge cases put it above `standard`.

## Goal

Add application-wide, persisted editor font-size zoom (SPEC §6.1 default 13 pt). New **View** menu commands in `App/FEditApp.swift` — "Increase Font Size" (⌘+ / Cmd-Shift-=), "Decrease Font Size" (⌘−), "Reset Font Size" (⌘0) — notch a single global `@AppStorage(SettingsKey.editorFontSize)` up/down/back, clamped to 8–32 pt in 1-pt steps. Because the setting is one global default (NOT per-window scene state), every open editor updates live on change and the size survives relaunch. Delivering this requires making the editor font size **dynamic**: `Editor/Theme.swift` today hard-codes `editorFont`/`editorBoldFont`/`editorItalic`/`baseAttributes` at 13 pt as `static let`, and `Editor/SyntaxHighlighter.swift` bakes those fonts into its `static let` rule tables — both are refactored to be driven by a size, `Editor/CodeEditorView.swift` applies the current size and re-lays-out + re-highlights on change, and `Editor/LineNumberRulerView.swift` scales its gutter font to match.

## Pinned decisions (the crux)

These four are called out up front because they are the load-bearing design choices; the tiers implement them.

1. **Theme refactor mechanism — size-parametric `static func`s (option a).** `Theme.editorFont`, `editorBoldFont`, `editorItalic`, and `baseAttributes` become **functions of a size**: `Theme.editorFont(size:)`, `Theme.editorBoldFont(size:)`, `Theme.editorItalic(size:)`, `Theme.baseAttributes(fontSize:)`. This is chosen over a mutable `static var Theme.editorFontSize` (option c) and over "keep unsized descriptors, size them at the call site" (option b) because: (i) it preserves `Theme`'s documented contract — "intentionally inert: `static let`/`static func` members only, no reference to `NSTextView`, the highlighter, or any editor state" (Theme.swift header, relied on by syntax-highlighting criterion 10) — a mutable global size var would introduce shared mutable state and a cross-window write-ordering hazard; (ii) it matches the **existing precedent** already in `Theme` — `static func headingFont(level: Int) -> NSFont`; (iii) it keeps everything a pure function of an explicit argument, so no window's highlight pass can read another window's stale global. Size-**independent** members are untouched: all colors, `bodyFont`, `headingFont(level:)`, and the real-italic-vs-synthesized-oblique **decision** (SF Mono has no italic face at any size, so the decision is size-invariant; only the resolved font's point size changes).

2. **How `SyntaxHighlighter` gets the current size — threaded as a parameter, rules built per size, regexes compiled once.** `highlight(_:language:)` becomes `highlight(_ textStorage:, language:, fontSize:)`. The per-language rule tables stop being `static let [HighlightRule]`; they become builders `swiftRules(fontSize:)` / `pythonRules(fontSize:)` / `markdownRules(fontSize:)` that pair **size-independent, compiled-once `static let NSRegularExpression`** constants (the expensive part — extracted so they are never recompiled) with attribute dictionaries built at the requested size (the cheap part — `Theme.editorBoldFont(size:)` etc.). The reset pass uses `Theme.baseAttributes(fontSize:)`; `italicAttributes` becomes `italicAttributes(fontSize:)`. Rebuilding a handful of attribute dictionaries on each debounced pass is negligible (no regex compilation), so **no size cache is required** for v1; a `[size: [HighlightRule]]` memo is noted as an optional optimization only.

3. **Preview scope — decoupled; editor zoom does NOT scale the preview.** Today `Theme.codeFont == Theme.editorFont` (a `static let` alias), and the preview renderer consumes `Theme.codeFont` for inline `` `code` `` and fenced blocks. Zoom is scoped to the **editor** (TODO wording: "text editor"), so `codeFont` is **decoupled** into its own fixed `static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)`. Justification, adversarial: (i) the preview's *body* font (`Theme.bodyFont`, system 13) is **not** the editor font and does not scale — scaling only code spans while body text stays 13 pt would be visually incoherent; (ii) the renderer's inline-style caches (`bodyStyle`/`listStyle`/`quoteStyle`) and `PreviewFont.bodyBold`/`bodyItalic` are `static let`, baked at first access, so they would not reliably reflect a live size even if `codeFont` were dynamic; (iii) the preview has its own render / debounce / anchor-based scroll-sync machinery — pulling zoom into it widens the blast radius and risks anchor/scroll regressions for no in-scope benefit. Preview zoom, if ever wanted, is a separate future item. This decoupling also **preserves the current preview appearance exactly** (still 13 pt).

4. **Live cross-window propagation + cursor/scroll preservation — global `@AppStorage`, applied in `updateNSView`, anchored on the first visible logical line.** One global `@AppStorage(SettingsKey.editorFontSize)` backed by `UserDefaults` means a write from the menu invalidates **every** `View` observing that key across **all** windows, so each window's `ContentView` re-evaluates and calls the editor's `updateNSView`. `CodeEditorView` receives the (clamped) size as a plain `let fontSize: CGFloat` from `ContentView` (mirroring how `sidebarWidth`/`editorFraction` are owned as `@AppStorage` in `ContentView` and clamped at the read site). On a size change, `updateNSView`: captures `selectedRanges` and the **first-visible character index**, updates `typingAttributes`, runs the full re-highlight at the new size (which re-applies the sized font across the whole storage, attribute-only, no undo pollution, no `didChangeText`), tells the ruler the new size, restores the selection, and re-pins the captured character to the top of the viewport after relayout. Anchoring on the first visible logical line (not the pixel offset) is correct because taller/shorter lines otherwise make the content appear to drift — and the editor already computes exactly this quantity for its `onFirstVisibleLineChange` reporting.

## Acceptance criteria — concrete and testable

Verified manually in the running app (this is a manual-test project; temporary `print`/`os_log` instrumentation is acceptable, then removed) unless noted.

1. **Zoom in.** With a file open, ⌘+ (the menu item titled "Increase Font Size", shortcut shown as ⌘+, matching Cmd-Shift-=) increases the editor font by 1 pt; repeated presses step up to 32.
2. **Zoom out.** ⌘− decreases by 1 pt down to 8.
3. **Reset.** ⌘0 sets the size back to 13 (SPEC §6.1 default) from any value.
4. **Clamp + enablement.** The stored value never leaves 8…32. At 32, "Increase Font Size" is a no-op **and** the menu item is disabled; at 8, "Decrease Font Size" is a no-op and disabled; "Reset Font Size" is disabled when the size is already 13. A bogus persisted value (`defaults write …editorFontSize 900`) renders clamped, not at 900 (clamped at the `ContentView` read site).
5. **Persistence across relaunch.** Set the size to 20, quit, relaunch → the editor opens at 20 pt (read from `@AppStorage`/`UserDefaults`).
6. **App-wide across windows.** With two editor windows open, changing the size in one updates the **other** window's editor live (same global default; no per-window divergence).
7. **Live update, cursor + scroll preserved.** Changing the size re-lays-out the open editor immediately — no file reload, no plain-text flash — and (a) the caret/selection range is preserved, (b) the logical line that was at the top of the viewport stays at the top. The document is **not** marked dirty and the window undo stack is **not** disturbed (zoom is not an undoable edit and does not resurrect/clear edits).
8. **Highlight rebuilds at the new size.** In a `.swift`/`.py`/`.md` file, after a zoom the bold keywords/headings, italic (real or synthesized-oblique) spans, and string/comment/number tokens all render at the **new** size with bold/italic/oblique traits intact — never a mix of old-size bold with new-size regular. Switching files at a non-default size highlights the new file at that size (no 13-pt flash).
9. **Plain files scale uniformly.** A `.txt` (`.plain`) file scales to the new size via the highlighter's reset pass (`baseAttributes(fontSize:)`), even though no rules run.
10. **Gutter tracks.** The line-number gutter font scales with the editor size (preserving the current 10-pt gutter at the 13-pt default) and its width re-measures (still min 2 digits) at the new gutter-font size; numbers stay vertically centered on the now-taller/shorter line fragments; a wrapped logical line still shows its number only once, on its first fragment.
11. **Preview scope (pinned).** The Markdown preview's body, headings, **and** code font stay fixed at their current sizes when the editor is zoomed — editor zoom does not change the preview (criterion enforces decision 3).
12. **Typing after zoom.** Text typed after a zoom uses the new size (`typingAttributes` updated); no highlight feedback loop (the size re-apply is attribute-only and never re-triggers `textDidChange`).
13. **Build & revert.** `xcodebuild` succeeds; reverting any single tier (outer-to-inner) leaves a compiling, runnable app.
14. **Edge — bursts and mid-debounce change.** A rapid ⌘+/⌘− burst does not corrupt layout or desync the ruler; changing the size while a keystroke-debounce highlight is pending results in a highlight at the **final** size (the debounced pass reads the coordinator's current size at execution time).

## Tiers — each independently buildable and revertible, files named

### Tier 1 — `Theme` size-parametric fonts + `SyntaxHighlighter` size threading (no behavior change)

Make the whole font pipeline size-capable while everything still renders at 13 pt. Zero visual change.

**Modify `FEdit/Editor/Theme.swift`:**
- Convert `editorFont`, `editorBoldFont`, `editorItalic` from `static let` to `static func editorFont(size: CGFloat) -> NSFont` (= `NSFont.monospacedSystemFont(ofSize: size, weight: .regular)`), `static func editorBoldFont(size:)` (`.bold`), `static func editorItalic(size:)` (the existing descriptor-then-`symbolicTraits.contains(.italic)`-else-`NSFontManager.convert` logic, using `size` throughout instead of the literal `editorFont.pointSize`).
- Convert `baseAttributes` from a `static var` to `static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any]` = `[.font: editorFont(size: fontSize), .foregroundColor: text]`.
- **Decouple `codeFont`:** replace `static let codeFont = editorFont` with `static let codeFont = NSFont.monospacedSystemFont(ofSize: EditorMetrics.previewCodeFontSize, weight: .regular)` (preview-only, fixed 13 — decision 3). `bodyFont`, `headingFont(level:)`, and all colors are unchanged.

**Modify `FEdit/Editor/SyntaxHighlighter.swift`:**
- Extract every rule's `NSRegularExpression` into a size-independent `private static let` constant (compiled once; the exact patterns/options are unchanged from today).
- Replace `static let swiftRules`/`pythonRules`/`markdownRules` with `private static func swiftRules(fontSize:)`/`pythonRules(fontSize:)`/`markdownRules(fontSize:)`, each returning `[HighlightRule]` that pairs the extracted regex constants with attribute dictionaries built at `fontSize` (`Theme.editorBoldFont(size: fontSize)` for keyword/heading/bold, `Theme.editorFont(size: fontSize)` for string/comment/inline-code/fence resets). Replace `static let italicAttributes` with `private static func italicAttributes(fontSize:)` (same real-italic-vs-`.obliqueness: 0.2` branch, using `Theme.editorItalic(size:)`).
- `ruleArray(for:)` → `ruleArray(for: language, fontSize:)`.
- `highlight(_ textStorage:, language:)` → `highlight(_ textStorage:, language:, fontSize:)`: reset pass uses `Theme.baseAttributes(fontSize: fontSize)`; rules from `ruleArray(for:fontSize:)`. Attribute-only invariants (no `didChangeText`, no character mutation) unchanged.

**Modify `FEdit/App/FEditApp.swift` (constants only, no menu yet):**
- Add `static let editorFontSize = "editorFontSize"` to `SettingsKey`.
- Add `enum EditorMetrics { static let defaultFontSize: Double = 13 /* SPEC §6.1 */; static let minFontSize: Double = 8; static let maxFontSize: Double = 32; static let fontSizeStep: Double = 1; static let previewCodeFontSize: CGFloat = 13 }` alongside `LayoutMetrics`.

**Minimal wiring so Tier 1 builds alone — `FEdit/Editor/CodeEditorView.swift`:** the two current references to the now-removed constants must compile. Change `makeNSView`'s `textView.font = Theme.editorFont` / `typingAttributes = [.font: Theme.editorFont, …]` to `Theme.editorFont(size: CGFloat(EditorMetrics.defaultFontSize))`, and change the single `highlightNow` call `SyntaxHighlighter.highlight(textStorage, language: currentLanguage)` to pass `fontSize: CGFloat(EditorMetrics.defaultFontSize)`. **Net effect: identical 13-pt rendering, but every font now flows from a size argument.** Tier 2 replaces the hard-coded default with the live value.

Revert = restore the `static let` fonts / rule tables and the two 13-pt call sites.

### Tier 2 — dynamic size in the editor + live propagation + gutter scaling

Wire the global setting into the editor and make the whole stack respond live.

**Modify `FEdit/Views/ContentView.swift`:**
- Add `@AppStorage(SettingsKey.editorFontSize) private var editorFontSize: Double = EditorMetrics.defaultFontSize`.
- Add `private func clampFontSize(_ v: Double) -> Double` mirroring `clampSidebar`/`clampFraction`: `guard v.isFinite else { return EditorMetrics.defaultFontSize }; return min(max(v, EditorMetrics.minFontSize), EditorMetrics.maxFontSize)`.
- In `editorColumn`, pass `fontSize: CGFloat(clampFontSize(editorFontSize))` to `CodeEditorView(...)`. The **preview column receives nothing new** (decision 3).

**Modify `FEdit/Editor/CodeEditorView.swift`:**
- Add `var fontSize: CGFloat = 13` to the representable (defaulted so any other call site stays source-compatible; `ContentView` always passes the clamped value).
- `makeNSView`: apply the initial size — `textView.font = Theme.editorFont(size: fontSize)`, `typingAttributes = [.font: Theme.editorFont(size: fontSize), .foregroundColor: Theme.text]`, and after the ruler is created, `ruler.editorFontSize = fontSize` (see ruler change). Order is already correct: font is set before the ruler is constructed.
- `Coordinator`: add `var currentFontSize: CGFloat = 13` (the value `highlightNow` reads — the same ownership discipline as `currentLanguage`) and `var appliedFontSize: CGFloat? = nil` (last size for which the live re-apply ran; **owned solely by the size block below**).
- `highlightNow`: call `SyntaxHighlighter.highlight(textStorage, language: currentLanguage, fontSize: currentFontSize)`.
- `updateNSView`: at the top, right after `coordinator.currentLanguage = language ?? .plain`, add `coordinator.currentFontSize = fontSize` — written **before** any `highlightNow` in this pass, so both the file-switch highlight and any debounced pass use the current size (mirrors the existing `currentLanguage` ownership note; prevents a stale-struct-copy size).
- Add an **independent** size block **after** the `documentID`/external-change branches (not `else if` — so a simultaneous file-switch + size-change both resolve correctly):
  ```
  if coordinator.appliedFontSize != fontSize {
      coordinator.isProgrammaticUpdate = true
      // 1. capture anchors
      let ranges = textView.selectedRanges
      let anchorChar = firstVisibleCharIndex(textView)   // glyphRange(forBoundingRect: visibleRect) → characterRange → .location
      // 2. new typing/default font (attribute-level; not an undoable text edit)
      textView.typingAttributes = [.font: Theme.editorFont(size: fontSize), .foregroundColor: Theme.text]
      textView.font = Theme.editorFont(size: fontSize)
      // 3. re-highlight at the new size — full reset+rules pass re-applies the sized font
      //    across the whole storage, attribute-only, no didChangeText, no undo registration.
      coordinator.pendingHighlight?.cancel(); coordinator.pendingHighlight = nil
      coordinator.highlightNow(textView)
      // 4. gutter
      coordinator.rulerView?.editorFontSize = fontSize   // recomputes numberFont + thickness + redraw
      // 5. restore selection; re-pin the top line after relayout
      textView.selectedRanges = ranges
      textView.layoutManager?.ensureLayout(for: textView.textContainer!)
      scrollCharToTop(textView, anchorChar)               // deferred one runloop if layout not yet complete
      coordinator.appliedFontSize = fontSize
      coordinator.isProgrammaticUpdate = false
  }
  ```
  - `firstVisibleCharIndex` reuses the exact computation already in `reportFirstVisibleLineIfChanged` (visible glyph range → character range → `.location`).
  - `scrollCharToTop`: `glyphIndexForCharacter(at: anchorChar)` → `lineFragmentRect(forGlyphAt:effectiveRange:)`, offset by `textContainerOrigin`, then scroll so that fragment's top aligns to the viewport top (`textView.scroll(_:)` / set the clip view bounds origin). Defer one runloop pass if `layoutManager` reports layout incomplete (same pattern as the `cursorToRestore` scroll in the file-switch branch).
  - `isProgrammaticUpdate` wraps the block so the (attribute-only) changes cannot round-trip through `textDidChange` into a highlight reschedule (criterion 12). It is not a character edit, so the document is not dirtied and undo is untouched (criterion 7). **Implementation note:** if profiling shows `textView.font =` registers an undo action, drop step 2's `textView.font =` and rely on the storage font applied by `highlightNow` (step 3) plus `typingAttributes` — the ruler no longer depends on `textView.font` because it takes an explicit `editorFontSize` (below).

**Modify `FEdit/Editor/LineNumberRulerView.swift`:**
- Replace `private let numberFont = …10pt…` with a stored `var editorFontSize: CGFloat = 13 { didSet { guard editorFontSize != oldValue else { return }; updateThickness(); needsDisplay = true } }` and a computed `private var numberFont: NSFont { NSFont.monospacedSystemFont(ofSize: max(8, editorFontSize - 3), weight: .regular) }`. The `-3` offset reproduces the current 10-pt gutter at the 13-pt default; the floor keeps it legible at the 8-pt minimum. (Ratio is a tunable, recorded here.) `updateThickness()` and `draw(lineNumber:in:)` already read `numberFont`, so they pick up the new size automatically; the vertical positions come from the layout manager's fragment rects, which already reflect the editor font, so numbers re-center for free.

At the end of Tier 2 zoom works app-wide and live, driven only through `UserDefaults` (there is no menu yet). To exercise it before Tier 3: `defaults write <bundleid> editorFontSize 22` (KVO updates a running app) or relaunch — acknowledged as a Tier-2-only test path.

Revert = drop the `fontSize` parameter + size block + coordinator vars, restore the ruler's fixed `numberFont`, drop the `ContentView` `@AppStorage`/clamp/argument.

### Tier 3 — the View menu commands

**Modify `FEdit/App/FEditApp.swift`:**
- Add `struct ViewCommands: Commands` with `@AppStorage(SettingsKey.editorFontSize) private var editorFontSize: Double = EditorMetrics.defaultFontSize`, exposing a `CommandMenu("View")` (there is no existing View menu; `CommandMenu` inserts one). Three buttons, all **app-level** (no `.disabled(workspace == nil)` — the setting is global and must work with no window focused, like the existing "Open Folder…"):
  - "Increase Font Size" — action `editorFontSize = min(editorFontSize + EditorMetrics.fontSizeStep, EditorMetrics.maxFontSize)`, `.keyboardShortcut("+", modifiers: .command)` (displays ⌘+, matches Cmd-Shift-=), `.disabled(editorFontSize >= EditorMetrics.maxFontSize)`.
  - "Decrease Font Size" — action `editorFontSize = max(editorFontSize - EditorMetrics.fontSizeStep, EditorMetrics.minFontSize)`, `.keyboardShortcut("-", modifiers: .command)`, `.disabled(editorFontSize <= EditorMetrics.minFontSize)`.
  - "Reset Font Size" — action `editorFontSize = EditorMetrics.defaultFontSize`, `.keyboardShortcut("0", modifiers: .command)`, `.disabled(editorFontSize == EditorMetrics.defaultFontSize)`.
  - The clamp inside each action is the correctness guarantee; `.disabled(...)` is UX polish (a `Commands` body re-evaluates when its `@AppStorage` changes, so the disabled state stays live). Both are present intentionally (belt-and-braces). No shortcut collision: Cmd-N/⌘⇧O/Cmd-S/Cmd-W/Cmd-Q are the only existing chords.
  - **Ergonomic note (optional):** to also accept bare Cmd-= (no Shift) for zoom-in, a second hidden/duplicate "Increase" button with `.keyboardShortcut("=", modifiers: .command)` may be added; the primary shortcut stays "+". Not required by any criterion.
- Add `ViewCommands()` to the `WindowGroup`'s `.commands { … }` block alongside `FileCommands()`.

Revert = delete `ViewCommands` and its one line in `.commands`.

## Interface between tiers

- **Tier 1 → Tier 2/3:** `Theme.editorFont(size:)`, `editorBoldFont(size:)`, `editorItalic(size:)`, `baseAttributes(fontSize:)`; `SyntaxHighlighter.highlight(_:language:fontSize:)`; `SettingsKey.editorFontSize`; `EditorMetrics.{defaultFontSize,minFontSize,maxFontSize,fontSizeStep,previewCodeFontSize}`; the decoupled `Theme.codeFont`.
- **Tier 2 → Tier 3:** the single source of truth is the `UserDefaults` value behind `SettingsKey.editorFontSize`. Tier 3's menu **writes** it; Tier 2's `ContentView` **reads** it (clamped) and passes it to `CodeEditorView`. Neither holds a second copy — both `@AppStorage` wrappers are live views onto the same key (identical to how `FileCommands`' autosave `@AppStorage` mirrors the model's key today).
- **Within Tier 2:** `CodeEditorView` → `LineNumberRulerView` gains exactly one new symbol, the settable `editorFontSize` property. `CodeEditorView` → `SyntaxHighlighter` uses only the new `fontSize:` parameter.

## Load-bearing assumptions (real symbols; verify at implementation start)

1. `Editor/Theme.swift` — `editorFont`/`editorBoldFont`/`editorItalic`/`baseAttributes` are the `static let`/`static var` members refactored here; `codeFont` is currently `= editorFont` (confirmed) and `bodyFont`/`headingFont(level:)`/all colors are size-independent and untouched.
2. `Editor/SyntaxHighlighter.swift` — `highlight(_:language:)`, `ruleArray(for:)`, the three `static let` rule arrays, and `static let italicAttributes` exist as described; the reset pass calls `Theme.baseAttributes`; the rule dictionaries reference `Theme.editorBoldFont`/`editorFont`/`editorItalic` (confirmed). Its **only** caller is `CodeEditorView.Coordinator.highlightNow` (confirmed by grep — no other call site to update).
3. `Editor/CodeEditorView.swift` — the `Coordinator` has `currentLanguage`, `highlightNow(_:)`, `pendingHighlight`, `isProgrammaticUpdate`, `rulerView`, and the visible-char computation in `reportFirstVisibleLineIfChanged`; `updateNSView` sets `coordinator.currentLanguage` at the top before any `highlightNow`, has a `documentID`-change branch (undo reset, sync highlight, `invalidateLineNumbers`) and a speculative external-change branch. The new `currentFontSize` write and size block slot into this exact structure.
4. `Editor/LineNumberRulerView.swift` — holds `weak var textView`, a `private let numberFont` (10 pt), `updateThickness()`, `invalidateLineNumbers()`, and a `draw(lineNumber:in:)` that reads `numberFont` (confirmed). The min-2-digit width logic and visible-range-only walk are unchanged; only the font's size becomes dynamic.
5. `Views/ContentView.swift` — owns `sidebarWidth`/`editorFraction` as `@AppStorage` clamped at the read site (`clampSidebar`/`clampFraction`), and constructs `CodeEditorView(text:documentID:language:cursorToRestore:onFirstVisibleLineChange:onCursorChange:)` in `editorColumn` (confirmed). Adding a clamped `fontSize:` argument follows the identical pattern.
6. `App/FEditApp.swift` — `SettingsKey` is the single home for `UserDefaults` keys; `LayoutMetrics` is the sibling constants enum; the `WindowGroup` already has a `.commands { FileCommands() }` block, and `FileCommands` already demonstrates an app-level command plus an `@AppStorage`-as-menu-view pattern (confirmed). Adding `EditorMetrics`, the new key, and `ViewCommands()` follows suit.
7. **Platform / SwiftUI behavior:** a global `@AppStorage` write invalidates all `View`s observing that key across all scenes (standard `UserDefaults` KVO), so every window's `ContentView` re-evaluates and calls `updateNSView` — this is what makes zoom app-wide/live without any per-window messaging. `@AppStorage`/`let` inputs of an `NSViewRepresentable` are tracked like any `View`'s, so a changed `fontSize` reliably reaches `updateNSView`.
8. `Preview/MarkdownRenderer.swift` — consumes `Theme.codeFont` (inline code + fenced blocks) and `Theme.bodyFont`/`headingFont`; its inline-style and `PreviewFont` faces are `static let` (confirmed). Decoupling `codeFont` to a fixed 13-pt `static let` keeps the preview visually identical and outside the zoom blast radius.

## Out of scope

- **Preview zoom** — the Markdown preview (`bodyFont`/`headingFont`/decoupled `codeFont`) stays fixed; a separate future item could add it (decision 3).
- **Per-window / per-document font size** — the setting is one global default (SPEC's "application-wide"); no scene-scoped override.
- **Scaling `bodyFont`/`headingFont(level:)`** or introducing proportional body bold/italic scaling — only the monospaced editor font (and its bold/italic/oblique variants) and the gutter font scale.
- **User-configurable step, min/max, or gutter-font ratio** — the 1-pt step, 8–32 clamp, and `editorFontSize − 3` gutter ratio are fixed constants for v1.
- **A Settings/Preferences window, a "Font…" panel, or `NSFontManager` font-family selection** — zoom only changes point size of the fixed monospaced system font (SPEC §6.1).
- **Dark mode / theming** (SPEC §3 light-only) — unaffected; `Theme` stays one light palette.
- **Any file outside** `Editor/Theme.swift`, `Editor/SyntaxHighlighter.swift`, `Editor/CodeEditorView.swift`, `Editor/LineNumberRulerView.swift`, `Views/ContentView.swift`, `App/FEditApp.swift`.
