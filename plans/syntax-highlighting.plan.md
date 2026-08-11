# syntax-highlighting

**Risk tier:** standard — regex rule tables and attribute application over an `NSTextStorage`; no concurrency beyond a main-queue debounce, no numerics, blast radius confined to `Editor/` plus one new theme file.

## Goal

Regex-based syntax highlighting per SPEC §6.3 for Swift (`.swift`), Python (`.py`), and Markdown (`.md`/`.markdown`), applied as a whole-document pass over the editor's `NSTextStorage`, debounced ~150 ms after the last keystroke and run immediately (full pass) on file switch. All other extensions stay plain text. Colors and fonts live in a new editor-agnostic `Editor/Theme.swift` (light palette only, per §3 the app is light-only) that later preview items (`markdown-renderer`, `markdown-preview`) will also consume.

## Acceptance criteria — concrete and testable

All verified manually in the running app unless noted; files small (§6.3 explicitly trades incrementality for simplicity).

1. **Language detection.** Opening `a.swift` → Swift rules; `a.py` → Python rules; `a.md` and `a.markdown` → Markdown rules; `a.txt`, `a.json`, extensionless `Makefile` → no token coloring, uniform near-black 13 pt monospaced text. Extension match is case-insensitive (`A.SWIFT` highlights as Swift).
2. **Token classes and colors (§6.3 table).** In a Swift file: `func`, `let`, `guard` render purple **bold**; `"hello"` and `"""multi\nline"""` render red; `// x` and `/* x */` (including multi-line) render green; `42`, `3.14`, `0xFF` render blue. In a Python file: `def`, `class`, `None`, `True` purple bold; `'a'`, `"a"`, `'''…'''`, `"""…"""` red; `# x` green; `42`, `3.14`, `0b101`, `1e-3` blue.
3. **Override order (the headline accept from TODO).** `let s = "for while in 42"` — everything between the quotes, including `for`, `while`, `in`, `42`, is string-red, not keyword-purple or number-blue. `// let x = "y" 42` is entirely comment-green. Same for Python (`# def x` all green; `"if else"` all red). EXPECTED behavior, pinned as intended so it isn't re-litigated as a bug: in `let url = "https://example.com"` the `//` inside the string turns the tail comment-green — a direct consequence of the spec-mandated rule order (comments run last).
4. **Markdown rules.** `# Heading` through `###### Heading` → heading color spans the line (inline markup inside a heading may override the bold font); `**bold**`/`__bold__` → bold; `*italic*`/`_italic_` → **visually slanted** (real italic trait or synthesized oblique — the test is visible slant, not a non-nil descriptor); `` `code` `` → gray background in the base text color; a fenced ``` block → gray background over the whole block including fence lines, with no bold/italic/heading styling surviving inside it; `[title](url)` → link-blue. A `# Heading` line is heading-blue, not Python-comment-green (Markdown has no comment rule).
5. **Debounce.** Typing a burst of characters triggers exactly one highlight pass ~150 ms after the last keystroke (verified via temporary instrumentation — print/os_log counter, then removed; accepted approach for a manual-test project); no per-keystroke pass, no visible stutter while typing in a few-hundred-line file.
6. **File switch.** Switching files in the sidebar re-highlights the new content immediately (no 150 ms flash of plain text), cancels any pending debounced pass from the previous file, and leftover attributes from the previous file never appear.
7. **Selection preserved; typing attributes best-effort.** With a selection active mid-document, a highlight pass leaves the selected range and scroll position unchanged. Typed text may transiently inherit adjacent token attributes for ≤ one debounce interval; the next pass always normalizes it. (With `isRichText = false`, `typingAttributes` is a rich-text-only property and cannot deliver a stronger guarantee — the original "typing attributes reset after every pass" mechanism claim is dropped.) Typing at the end of a purple keyword does not *permanently* inherit purple across passes.
8. **No feedback loop.** Attribute-only passes do not mark the document dirty, do not fire the representable's text-changed path, and do not reschedule the debounce (no infinite re-highlight).
9. **Edge cases (§11).** Empty file, file with no trailing newline, unterminated string/comment at EOF, CRLF content: no crash, no out-of-range attribute application (all regex matching and attribute ranges computed on the same `NSString`-UTF-16 axis).
10. **Theme reuse readiness.** `Theme` exposes exactly the cross-plan contract listed under "Interface between tiers" (fonts incl. bold and the synthesized-oblique italic story, body/heading/link/code colors, code background) as `static` properties with no reference to `NSTextView`, the highlighter, or any editor state — verified by code inspection: `Theme.swift` imports only AppKit and contains only `static let`/`static func` members.

## Tiers

### Tier 1 — `Editor/Theme.swift` + `Editor/SyntaxHighlighter.swift` core (Swift & Python)

Buildable standalone (compiles unused, nothing else modified); revert = delete two files.

**Create `FEdit/Editor/Theme.swift`** (GPL header per scaffold convention). A caseless `enum Theme` with static properties only:

- Fonts: `editorFont` (= `NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)`, §6.1), `editorBoldFont` (mono 13 pt `.bold`), `editorItalic` — caution: `withSymbolicTraits(.italic)` on the monospaced system font does **not** fail by returning nil; it returns a **non-italic** font (SF Mono has no italic face), so a nil-fallback never fires and Markdown italic would silently not render. Instead, check `fontDescriptor.symbolicTraits.contains(.italic)` on the **result**; if the trait is absent (the expected case), use a synthesized oblique — the Markdown italic rule applies `.obliqueness` ≈ 0.2 as an attribute (alternatively `NSFontManager.convert(_:toHaveTrait:)`). The acceptance test is "italic span is visually slanted", not "descriptor non-nil". Plus preview-facing sizes the renderer will want later: `bodyFont` (system 13), `codeFont` (= `editorFont`), and `static func headingFont(level: Int) -> NSFont` (bold system, sized by level). Preview fonts are speculative-but-cheap: they keep Theme the single palette file so `markdown-renderer` doesn't grow its own.
- Colors (light palette, `NSColor` with explicit sRGB components so light-only rendering is deterministic): `text` (near-black), `background` (white), `keyword` (purple), `string` (red), `comment` (green), `number` (blue), `heading` (blue), `link` (link blue), `codeBackground` (light gray), `mutedText` (gray — blockquotes/gutter reuse later).
- Convenience: `static var baseAttributes: [NSAttributedString.Key: Any]` = `[.font: editorFont, .foregroundColor: text]` (used for the reset pass).

**Create `FEdit/Editor/SyntaxHighlighter.swift`** containing:

- `enum SyntaxLanguage: Equatable { case swift, python, markdown, plain }` with `init(fileExtension: String?)` — lowercased compare: `"swift"` → `.swift`, `"py"` → `.python`, `"md"`/`"markdown"` → `.markdown`, anything else/nil → `.plain`.
- `struct HighlightRule { let regex: NSRegularExpression; let attributes: [NSAttributedString.Key: Any] }` — regexes built once as `static let` rule arrays (force-try acceptable for hardcoded patterns, they're compile-time constants in spirit).
- `enum SyntaxHighlighter` with `static func highlight(_ textStorage: NSTextStorage, language: SyntaxLanguage)`:
  1. `beginEditing()`.
  2. Reset pass: `setAttributes(Theme.baseAttributes, range: fullRange)` — clears stale bold/colors (criterion 6/7).
  3. If language ≠ `.plain`: apply that language's rule array **in array order**; later rules overwrite earlier attributes on overlap (`addAttributes` per match range), which is exactly how "strings override keywords, comments override both" is realized.
  4. `endEditing()`.
  Ranges: `fullRange = NSRange(location: 0, length: (textStorage.string as NSString).length)`; all matching runs on the same `string` snapshot (criterion 9).

**Regex rule inventory — Swift** (applied in this order; options noted per pattern):

| # | Class | Pattern | Attributes |
|---|---|---|---|
| 1 | number | `\b(?:0x[0-9A-Fa-f_]+|0b[01_]+|0o[0-7_]+|\d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?)\b` | `.foregroundColor: Theme.number` |
| 2 | keyword | `\b(?:associatedtype|class|deinit|enum|extension|fileprivate|func|import|init|inout|internal|let|open|operator|private|protocol|public|static|struct|subscript|typealias|var|break|case|continue|default|defer|do|else|fallthrough|for|guard|if|in|repeat|return|switch|where|while|as|any|catch|is|nil|rethrows|self|Self|some|super|throw|throws|true|false|try|async|await|actor|lazy|weak|unowned|mutating|override|final|required|convenience|indirect)\b` | `.foregroundColor: Theme.keyword`, `.font: Theme.editorBoldFont` |
| 3 | string | `"""(?s:.*?)"""|"(?:\\.|[^"\\\n])*"` (triple alternative first so it wins the alternation) | `.foregroundColor: Theme.string`, `.font: Theme.editorFont` (un-bolds keywords swallowed by pass 2) |
| 4 | comment | `/\*(?s:.*?)\*/|//[^\n]*` | `.foregroundColor: Theme.comment`, `.font: Theme.editorFont` |

**Regex rule inventory — Python** (same order semantics):

| # | Class | Pattern | Attributes |
|---|---|---|---|
| 1 | number | `\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|0[oO][0-7_]+|\d[\d_]*(?:\.\d*)?(?:[eE][+-]?\d+)?[jJ]?)\b` | number color |
| 2 | keyword | `\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield)\b` | keyword color + bold |
| 3 | string | `(?:(?<!\w)(?i:[rbuf]{1,2}))?(?:'''(?s:.*?)'''|"""(?s:.*?)"""|'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*")` (triples before singles; the string-prefix is an optional group carrying its own `(?<!\w)` guard — a prefix requires a non-identifier boundary before it, so `hub"x"` does not color `b"x"` while a bare quoted string still matches) | string color + regular font |
| 4 | comment | `#[^\n]*` | comment color + regular font |

Known, accepted limitations of the spec-mandated order (record in a header comment, do not "fix"): a `#`/`//` inside a string literal gets comment-colored because comments run last; nested Swift `/* /* */ */` closes at the first `*/`; string-interpolation contents stay string-red. These follow directly from §6.3's rule order and regex-only mandate.

### Tier 2 — Markdown rules in `SyntaxHighlighter.swift`

Modify only `FEdit/Editor/SyntaxHighlighter.swift` (add the `.markdown` rule array). Buildable and revertible independently (revert = drop the array; markdown files fall back to plain).

**Regex rule inventory — Markdown** (editor-side highlighting per §6.3, not the preview renderer; applied in this order — fenced blocks last so they override inline styling inside them, criterion 4; all line-anchored patterns use `.anchorsMatchLines`):

| # | Class | Pattern | Attributes |
|---|---|---|---|
| 1 | heading | `^#{1,6}[ \t][^\n]*$` | `Theme.heading` + `Theme.editorBoldFont` |
| 2 | bold | `\*\*[^*\n]+\*\*|(?<![_\w])__[^_\n]+__(?![_\w])` (the `__…__` alternative gets the same boundary guards as italic, so snake_case identifiers don't trigger it) | `Theme.editorBoldFont` |
| 3 | italic | `(?<![*\w])\*(?!\*)[^*\n]+\*(?![*\w])|(?<![_\w])_(?!_)[^_\n]+_(?![_\w])` | `Theme.editorItalic` if the resolved font carries a real italic trait; otherwise `Theme.editorFont` + `.obliqueness: 0.2` (synthesized oblique — see Theme notes) |
| 4 | link | `\[[^\]\n]*\]\([^)\n]*\)` | `Theme.link` |
| 5 | inline code | `` `[^`\n]+` `` | `Theme.editorFont` + `.foregroundColor: Theme.text` (resets link-blue so it doesn't bleed into `` `[a](b)` ``) + `.backgroundColor: Theme.codeBackground` |
| 6 | fenced block | ``^```[^\n]*\n(?s:.*?)^```[ \t]*$`` (an unterminated trailing fence keeps inline styling, no code background — rules 1–5 have already styled the region; cheapest safe behavior) | `Theme.editorFont`, `Theme.text`, `.backgroundColor: Theme.codeBackground` |

The editor font is already monospaced (§6.1), so "monospaced on gray" for code reduces to background + resetting weight/slant; rule 6 sets font and foreground explicitly to strip heading/bold/italic/link attributes applied by rules 1–5 inside the block.

### Tier 3 — Wire into `Editor/CodeEditorView.swift`

Modify only `FEdit/Editor/CodeEditorView.swift`. Revert = drop the wiring diff; Tiers 1–2 remain dead-but-compiling code.

- **Representable input:** add a language input to the representable — `let language: SyntaxLanguage? = nil`. DECISION: the parameter is **defaulted to `nil`** (treated as `.plain`) so the existing ContentView call site does not break and "modify only CodeEditorView.swift" stays true for compilation; ContentView then passes `SyntaxLanguage(fileExtension: url.pathExtension)` derived from the selected URL — that one-line call-site change is acknowledged as part of this tier's diff. Later, open-save's `WorkspaceModel.openFile` becomes the source and ContentView forwards from there — same enum, single source.
- **Language ownership (stale-representable guard):** the coordinator stores `var currentLanguage: SyntaxLanguage`. `updateNSView` refreshes `context.coordinator.parent = self` at the top (editor-core's plan mandates this refresh at the top of every `updateNSView`) AND writes `coordinator.currentLanguage = language` BEFORE the file-switch `highlightNow`. The debounced work item reads the coordinator's stored value, never a language captured from a struct copy — without this, the classic stale-representable bug highlights `b.py` with Swift rules forever.
- **Coordinator debounce:** `private var pendingHighlight: DispatchWorkItem?` plus `func scheduleHighlight(for textView: NSTextView)` — cancel pending, create a work item that calls `highlightNow(textView)` (reading `self.currentLanguage` at execution time, per the ownership bullet), dispatch on `.main` after `.milliseconds(150)`. Called from the coordinator's existing `textDidChange(_:)` (after the text-binding write-back it already does). `textDidChange` fires only for character edits, not for our attribute-only pass, so no feedback loop (criterion 8); assert this by never calling `didChangeText()`/mutating characters inside the highlight path.
- **`highlightNow`:** capture `selectedRanges`, run `SyntaxHighlighter.highlight(textView.textStorage!, language: currentLanguage)` using the coordinator's stored language, restore `selectedRanges` only if the storage length is unchanged (it always is — attribute-only — the guard is belt-and-braces). No `typingAttributes` reset: with `isRichText = false` that is a rich-text-only property, so typed text may transiently inherit adjacent token attributes until the next pass normalizes it (criterion 7).
- **File switch:** in `updateNSView`, where editor-core already detects the file-identity change (it resets undo there), additionally: `pendingHighlight?.cancel()`, then `highlightNow` synchronously after the new string is set (criterion 6). Any full-string programmatic replace in `updateNSView` (the file-switch branch OR the external-change branch) is followed by cancel-pending + `highlightNow` — editor-core has two content paths and both are hooked. DECISION: no `highlightNow` in `makeNSView` — at makeNSView time the view is empty, and the first `updateNSView` identity change covers the initially restored file. When language changes but content doesn't (rename-ish edge), the plain reset pass inside `highlight` handles clearing.
- **Base attributes unification:** replace editor-core's inline `NSFont.monospacedSystemFont(ofSize: 13, …)` / text-color literals in `CodeEditorView` with `Theme.editorFont` / `Theme.text` / `Theme.background` so the reset pass and the view's defaults can never drift. (Do not touch `LineNumberRulerView` — its gutter colors stay where editor-core put them.)
- `.plain` language still goes through `highlight` (reset pass only) — this is what clears stale coloring when switching from `a.swift` to `notes.txt` in-place and keeps criterion 1 honest.

## Interface between tiers

- Tier 1 → Tier 2: `SyntaxHighlighter`'s private per-language rule arrays share `HighlightRule` and the same application loop; Tier 2 only adds `markdownRules` and switches it in for `.markdown`.
- Tiers 1–2 → Tier 3: exactly two public entry points — `SyntaxLanguage.init(fileExtension:)` and `SyntaxHighlighter.highlight(_:language:)` — plus `Theme.baseAttributes`/`Theme.editorFont`/`Theme.text`/`Theme.background` constants. Tier 3 knows nothing about rules or regexes.
- This item → later items (cross-plan DECISION, exact contract): `Theme` exports exactly — fonts: `editorFont`, `editorBoldFont`, `editorItalic` (synthesized-oblique story per the Tier 1 notes), `bodyFont`, `codeFont`, `headingFont(level:)`; colors: `text`, `background`, `keyword`, `string`, `comment`, `number`, `heading`, `link`, `mutedText`, `codeBackground`; plus `baseAttributes`. `markdown-renderer` WILL consume `headingFont(level:)`, `codeFont`, `codeBackground`, `link`, `mutedText`, `text` (its plan is being updated to commit to this); `PreviewStyle` over there defines only paragraph styles/spacing. So `headingFont(level:)` is not dead API. Nothing in `Theme` may reference editor types.

## Load-bearing assumptions

Expected state from shipped items (xcode-scaffold, split-layout, folder-sidebar, editor-core); verify each at implementation start and adjust the Tier-3 diff if reality differs:

1. `FEdit/Editor/CodeEditorView.swift` exists as an `NSViewRepresentable` whose `Coordinator: NSObject, NSTextViewDelegate` implements `textDidChange(_:)` with a feedback-loop guard, around an explicit TextKit 1 stack (`NSTextStorage` + `NSLayoutManager` + `NSTextContainer`) inside an `NSScrollView`. Tier 3 hooks `textDidChange` and `updateNSView`.
2. `updateNSView` has a detectable file-identity change point (editor-core's accept includes "undo reset on file switch"), i.e. the representable already receives something URL- or identity-shaped per open file — the language input piggybacks on the same identity. If the representable only receives a text binding, Tier 3 adds the `language` (or `fileURL`) property and ContentView passes it; ContentView demonstrably knows the selected URL (folder-sidebar records it, editor-core loads it).
3. The text view uses monospaced system 13 pt and near-black-on-white per §6.1; Tier 3 re-points those literals at `Theme` without visual change.
4. (open-save) is listed before this item in ship order but this item depends only on (editor-core); the plan therefore does not assume `WorkspaceModel.openFile.language` exists — if it does, Tier 3 uses it, otherwise extension detection happens at the ContentView call site.
5. Highlighting runs on the main thread (whole-document, small files per §6.3); no background parsing, no `NSTextStorageDelegate` hooks needed.
6. Project is a file-system-synchronized Xcode group (xcode-scaffold), so the two new files under `FEdit/Editor/` join the target with no project-file edits.

## Out of scope

- Incremental/range-based re-highlighting, background-thread parsing, tree-sitter/LSP anything (§6.3 mandates regex + whole-document; §12).
- Dark mode / theme switching (§3 light-only; §12 "themes" is a non-goal) — `Theme` is one light palette, not a theming system.
- Highlighting inside the Markdown *preview* (explicitly excluded for v1 by §8.2) and the preview renderer itself (`markdown-renderer` item) — this item only guarantees `Theme` is ready for them.
- Fixing the inherent regex-order artifacts (comment markers inside strings winning, nested Swift block comments, interpolation) — the order is spec-fixed.
- `LineNumberRulerView` gutter styling migration into `Theme`.
- Any file outside `FEdit/Editor/` (no `WorkspaceModel`, `ContentView` changes beyond the acknowledged one-line call-site change passing the language value).

## Auto-resolved (plan review)

Findings from adversarial plan review, folded in above; recorded here so they aren't re-litigated.

**Defects fixed:**

1. **(High) `currentLanguage` ownership.** Tier 3 now states explicitly: `updateNSView` refreshes `context.coordinator.parent = self` at the top and writes `coordinator.currentLanguage = language` *before* the file-switch `highlightNow`; the debounced work item reads the coordinator's stored value, never a captured struct. Prevents the stale-representable bug (`b.py` highlighted with Swift rules forever).
2. **(Medium) Italic font.** `withSymbolicTraits(.italic)` on the monospaced system font returns a *non-italic* font (SF Mono has no italic face) rather than nil, so the old nil-fallback never fired. Plan now checks `symbolicTraits.contains(.italic)` on the result and falls back to a synthesized oblique (`.obliqueness` ≈ 0.2 attribute, or `NSFontManager.convert(_:toHaveTrait:)`). Acceptance test changed to "italic span is visually slanted".
3. **(Medium) Typing-attributes criterion weakened.** With `isRichText = false`, `typingAttributes` is rich-text-only and cannot deliver the original guarantee; criterion 7 now allows typed text to transiently inherit adjacent token attributes for ≤ one debounce interval, normalized by the next pass. The `typingAttributes`-reset mechanism claim is dropped.
4. **(Low) Theme contract pinned (cross-plan DECISION).** Exact export list stated under "Interface between tiers": fonts `editorFont`/`editorBoldFont`/`editorItalic`/`bodyFont`/`codeFont`/`headingFont(level:)`; colors `text`/`background`/`keyword`/`string`/`comment`/`number`/`heading`/`link`/`mutedText`/`codeBackground`; plus `baseAttributes`. `markdown-renderer` commits to consuming `headingFont(level:)`, `codeFont`, `codeBackground`, `link`, `mutedText`, `text` — `headingFont(level:)` is not dead API.
5. **(Low) Both content paths hooked.** Any full-string programmatic replace in `updateNSView` (file-switch branch OR external-change branch) is followed by cancel-pending + `highlightNow` — editor-core has two content paths; the plan previously hooked only one.
6. **(Low) `makeNSView` highlight removed (DECISION).** The view is empty at `makeNSView` time; the first `updateNSView` identity change covers the initially restored file.
7. **(Nit) Tier 3 scope (DECISION).** `language` parameter defaults to `nil` so the ContentView call site doesn't break; ContentView passes `SyntaxLanguage(fileExtension: url.pathExtension)` from the selected URL — the one-line call-site change is acknowledged in the tier diff.
8. **(Nit) Fence wording.** "Unterminated trailing fence left unstyled" reworded to "keeps inline styling, no code background" — rules 1–5 have already styled the region.

**Tensions resolved:**

9. `let url = "https://example.com"` turning the tail comment-green is pinned as EXPECTED behavior (spec-mandated rule order; criterion 3), not a bug.
10. Inline-code rule also resets `.foregroundColor` to `Theme.text` so link-blue doesn't bleed into `` `[a](b)` ``; heading criterion softened to "heading color spans the line" (inline markup inside a heading may override the bold font).
11. Boundary guards added: bold `__…__` gets the same `(?<![_\w])`/`(?![_\w])` guards as italic; the Python string-prefix carries its own `(?<!\w)` guard so `hub"x"` doesn't color `b"x"`.
12. Criterion-5 verification uses temporary instrumentation (print, then remove) — accepted for a manual-test project.
