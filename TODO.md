# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (open-save) Open/save/dirty/autosave flow — `Models/WorkspaceModel.swift`: openFile state (URL, text, dirty, language stub), UTF-8-with-Latin-1-fallback read, NUL-byte binary refusal alert, atomic UTF-8 save, requestOpen with unsaved-changes NSAlert (Save / Always Autosave / Don't Save / Cancel; cancel reverts sidebar selection), autosave honored silently, failed autosave aborts the switch; same flow on window close/quit. File menu in `App/FEditApp.swift`: Save (Cmd+S, disabled when clean/none) and "Autosave on File Switch" checkmark toggle (global @AppStorage, default off). Window title = file name, subtitle shows Edited marker. Real `isMarkdown` replaces the (split-layout) stub. Depends on (editor-core). Spec §7, §10.
- [ ] (syntax-highlighting) Regex syntax highlighting for Swift, Python, Markdown — New `Editor/SyntaxHighlighter.swift` (language detection by extension; rule tables per SPEC token classes; application order: numbers/keywords, then strings, then comments, so strings override keywords and comments override both; markdown rules for headings/bold/italic/inline code/fences/links) and new `Editor/Theme.swift` (light palette + fonts, also used by later preview items); wire into `Editor/CodeEditorView.swift` with ~150 ms debounce after last keystroke, full re-highlight on file switch, selection and typing attributes preserved. Depends on (editor-core). Accept: keyword inside a string stays string-colored; unknown extensions stay plain. Spec §6.3.
- [ ] (markdown-renderer) Markdown → NSAttributedString renderer with source-line anchors — New `Preview/MarkdownRenderer.swift`: block parser (ATX headings, paragraph merging with blank-line breaks, `-`/`*`/`+` and `1.`/`1)` lists, `>` blockquotes, fenced code blocks, `---`/`***` rules) + inline parser (`**bold**`, `*italic*`, `` `code` ``, `[title](url)` clickable); emits `(sourceLine → output location)` anchor per block; explicit non-goals per SPEC (no tables/images/nested lists/HTML). Pure model code, no UI — independently buildable and unit-verifiable. Depends only on (xcode-scaffold) + Theme from (syntax-highlighting). Spec §8.1–§8.2.
- [ ] (markdown-preview) Preview column with editor→preview scroll sync — New `Preview/MarkdownPreviewView.swift` (read-only selectable TextKit 1 NSTextView showing renderer output; re-render on edit with scroll position preserved); `Views/ContentView.swift`: mount in third column when open file is markdown, feed editor's throttled first-visible-line into anchor lookup (greatest anchor line ≤ editor top scrolls to top of preview); one-way sync only, approximate but sub-second. Depends on (markdown-renderer), (open-save), (editor-core). Spec §8.3, §4.
- [ ] (session-restore) Session persistence and multi-window polish — `Models/WorkspaceModel.swift`: Codable snapshot (root paths, open file path, filter text, cursor) exposed as JSON; `Views/ContentView.swift`: @SceneStorage save/restore per window (missing folders silently dropped, missing file not opened, cursor restored and scrolled visible, content always re-read from disk); verify frames restore via system window restoration and that all menu commands target the focused window. Depends on (open-save), (filter-query). Spec §3, §9.

## Bugs

(none yet)
