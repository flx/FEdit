# FEdit — Detailed Specification

Version 1.0 — 2026-07-17. Expands `Specification.md` with the decisions from the design interview. This document is the implementation contract for v1.

## 1. Product overview

FEdit is a lightweight macOS text editor with a strong focus on low memory usage. It provides a three-column window: folder sidebar, text editor with line numbers and syntax highlighting (Swift, Python, Markdown), and a Markdown preview column that appears only for Markdown files.

**Memory goal:** working set well under 100 MB with a few small files open (motivating contrast: VS Code at ~1 GB). This goal drives two architectural choices: no web view for the preview, and plain AppKit text machinery instead of heavyweight editor frameworks.

## 2. Platform & project

- **Target:** macOS 26.0 minimum, Apple Silicon. No backwards compatibility required.
- **Project type:** Xcode project (`FEdit.xcodeproj`), SwiftUI app lifecycle, Swift 5 language mode.
- **Frameworks:** SwiftUI for app structure/chrome, AppKit (`NSTextView`, TextKit 1) for the editor and preview. No third-party dependencies.
- **Sandboxing:** none (personal tool). Files are accessed by plain path; no security-scoped bookmarks. Not App Store distributable in this form — acceptable.
- **Signing:** ad-hoc / sign-to-run-locally.

## 3. Windows

- `WindowGroup`-based: **multiple editor windows** opened via File → Open Folder… (Cmd+N), which opens a new window and prompts for a folder that becomes the new window's sole root (Cancel leaves an empty window).
- Each window owns its own independent state: folder list, filter text, open file, cursor.
- Default window size 1100×700, minimum 700×400.
- Window frames restored by the system's window restoration.
- The app uses **light appearance only**, regardless of the system setting.

## 4. Layout (three columns)

```
+—————————————+—+——————————————————————————————+—+—————————————————+
| sidebar     |║| editor (line nrs + text)     |║| markdown preview|
| (fixed w)   |║| takes remaining space        |║| (only for .md)  |
+—————————————+—+——————————————————————————————+—+—————————————————+
                ^ divider 1                      ^ divider 2
```

- **Default split:** with a Markdown file open (3 columns) the window divides **1/3, 1/3, 1/3**. With a non-Markdown file (2 columns) the sidebar keeps its width (1/3 of the window by default) and the editor takes the remainder (≈ 2/3 by default).
- **Sidebar:** draggable via divider 1; default width = 1/3 of the default window width (≈ 367 pt), clamped to 160–600 pt. Its width never changes when the preview column appears/disappears.
- **Editor:** takes all remaining width when no preview is shown. When the preview exists, the editor gets a draggable fraction of the remaining (non-sidebar) width via divider 2; default fraction 1/2 — yielding the 1/3, 1/3, 1/3 default — clamped to 15 %–85 %.
- **Preview:** exists **iff** the currently open file is Markdown. Takes the rest of the width.
- Both divider positions are **persisted globally** (`UserDefaults`) and restored on next launch; they are shared across windows.
- Dividers: 5 pt hit area, thin visible separator line, `resizeLeftRight` cursor on hover.
- **Column header strips:** each column carries a fixed-height header strip above its content — the sidebar strip shows the open folder name(s) (each root's last path component, comma-separated), the editor strip shows the open file's name, and the preview column (Markdown only) carries a "Preview" strip so its content starts at the same vertical level as the editor. The sidebar and editor strips are hidden (no strip, no gap) when their column has nothing open; the preview strip shows whenever the preview column is present.

## 5. Folder sidebar

### 5.1 Top-level folders
- Added to the focused window via **File → Add Folder to Window…** (Cmd+Shift+O), `NSOpenPanel`, directories only, multi-select allowed.
- Multiple top-level folders can be open at once; each is a section in the sidebar list.
- Section header shows the folder path abbreviated with `~` for the home directory (e.g. `~/Programming/swift/FEdit`), truncated head-first if too long.
- Context menu on a section header: **Remove from Sidebar** (does not touch the disk), **Refresh** (rescans all folders).
- Adding a folder that is already open is a no-op.
- With no folders open, the sidebar shows a placeholder with an "Add Folder to Window…" button (adds a folder to the current window).
- The sidebar column's fixed top strip (§4, a name-only summary — each open root's last path component, comma-separated) is **distinct from and complements** these per-root section headers (full `~`-abbreviated path, head-truncated, Remove/Refresh menu); the section headers are unchanged.

### 5.2 Directory scanning
- Recursive scan at add-time (and on Refresh). No file-system watching in v1 — refresh is manual.
- Hidden files (dotfiles) are skipped. Additionally skipped directory names: `node_modules`, `.build`, `DerivedData`.
- Sort order within a directory: folders first, then files, each alphabetically (`localizedStandardCompare`).

### 5.3 Tree mode (empty filter)
- Expandable/collapsible tree (disclosure triangles), folders with a folder icon, files with a type-appropriate icon.
- Only files are selectable; clicking a file requests opening it (see §7). The open file's row is highlighted.

### 5.4 Filter mode (non-empty filter)
- The search field (standard rounded style, placeholder like `Filter files (e.g. .py OR .swift)`) sits at the top of the sidebar's list content, below the column's folder-name header strip (§4) when one is shown — top-to-bottom order: folder-name strip → search field → list.
- While the filter is non-empty, each section shows a **flat list of matching files as paths relative to that top-level folder** (e.g. `swift-source/main.swift`) — the top folder path is not repeated. A section with no matches shows a muted "No matches".

### 5.5 Filter query language
- Tokens are separated by whitespace. `AND` and `OR` (uppercase, exact) are operators; everything else is a search term.
- A term matches if it is a **case-insensitive substring of the file's relative path** (so `.py` matches extension, `main` matches the name, `src/` matches a folder segment).
- Grammar (AND binds tighter than OR; adjacency = implicit OR):
  ```
  query   := orExpr
  orExpr  := andExpr (("OR" | implicit) andExpr)*
  andExpr := term ("AND" term)*
  ```
- Consequences: `.py .swift` and `.py OR .swift` both show the union; `.py AND .swift` is (almost always) empty; `.swift AND main OR .md` = (`.swift` AND `main`) OR `.md`.
- Malformed input degrades gracefully: leading/trailing/duplicate operators are ignored; an operator with a missing operand keeps the side that exists.

## 6. Editor column

### 6.1 Core
- AppKit `NSTextView` with an explicitly built **TextKit 1** stack (`NSTextStorage` + `NSLayoutManager` + `NSTextContainer`), wrapped in `NSViewRepresentable`.
- Plain text only; all smart substitutions (quotes, dashes, spell correction, text replacement) disabled. Undo enabled, reset when switching files.
- **Line wrapping:** always on (container tracks view width, no horizontal scrolling).
- Font: monospaced system font, default 13 pt. The size is adjustable via View → Increase/Decrease/Reset Font Size (Cmd-+ / Cmd-− / Cmd-0), clamped 8–32 pt; the chosen size is **application-wide** (shared across windows) and persisted across relaunch. Background white, near-black text.
- Exactly **one file open at a time** (per window), always the sidebar-selected file.

### 6.2 Line numbers
- Custom `NSRulerView` (vertical ruler of the editor's scroll view), light-gray gutter.
- Numbers count **logical lines**; a wrapped line shows its number only on its first visual fragment.
- Gutter width adapts to the digit count (min 2 digits). Draws only the visible range.

### 6.3 Syntax highlighting
- Languages by extension: `.swift` → Swift, `.py` → Python, `.md`/`.markdown` → Markdown. Everything else: plain text (no highlighting).
- Regex-based, whole-document pass over `NSTextStorage`, **debounced ~150 ms** after the last keystroke (files are expected to be small; simplicity over incremental parsing).
- Token classes and light-theme colors:
  | Class | Color | Applies to |
  |---|---|---|
  | keyword | purple, bold | Swift & Python keyword sets |
  | string | red | `"…"`, Swift `"""…"""`, Python `'…'`/`"…"`/triples |
  | comment | green | `//`, `/*…*/`, `#…` |
  | number | blue | int/float literals |
- Markdown highlighting (in the editor): headings (blue, bold), bold/italic spans, inline code and fenced blocks (monospaced on gray), links.
- Rule application order ensures strings override keywords and comments override both.

### 6.4 Scroll reporting
- The editor reports its first visible logical line (throttled) — input for preview scroll sync (§8.3) .

## 7. Open / save / autosave

- **Opening:** any file readable as text (UTF-8, fallback Latin-1). Files containing NUL bytes are treated as binary and refused with an alert. Read errors are alerted.
- **Dirty tracking:** any edit marks the file dirty; the window subtitle shows an "Edited" marker.
- The window `.navigationTitle` is always **"FEdit"** (not the file name — the open file's name is shown in the editor column's fixed top strip, §4). The window `.navigationSubtitle` still carries the "Edited" dirty marker.
- **Save:** Cmd+S, atomic write, UTF-8. Cmd+S is immediate. Write errors are alerted and the file stays dirty.
- **Autosave is unconditional and always-on** (no setting, no toggle): the open file is written on a ~0.75 s debounce after typing stops, and is also flushed silently on file switch, on app focus loss, and on window close / quit. The debounce coalesces a typing burst into a single write. "Dirty" is therefore a transient state, not a mode — the "Edited" subtitle clears on its own within ~1 s of the last keystroke.
- A **failed** save is surfaced (the "Cannot Save File" alert) only at an explicit save boundary — Cmd+S, file switch, close, or quit — not on every debounce tick, so a persistently-unwritable location can't spam a modal; the file simply stays dirty (the persistent "Edited" subtitle is the passive signal).
- **Switching files with unsaved changes:** the buffer is flushed silently, then the switch happens — no dialog. If the flush **fails**, the switch is aborted: the app stays on the current file (still dirty) and the sidebar selection reverts.
- **Closing / quitting with unsaved changes:** the buffer is flushed silently. If the flush **fails**, a single minimal two-button escape dialog appears — "Couldn't save '<name>'" with **Close Without Saving** (discard and close/quit) and **Cancel** (keep the window open / abort the quit; Escape). This is the only surviving unsaved-changes dialog, and it exists solely so a persistently-failing save (read-only dir, full or unmounted volume) can never make the app un-quittable.

> This unconditional-autosave model **supersedes the earlier opt-in design** ((open-save) acceptance criteria 9–16): the four-button "Save changes?" dialog, the "Always Autosave" action, the "Don't Save" discard-on-switch, and the "Autosave on File Switch" toggle/persisted setting no longer exist. The only discard path that survives is the close/quit "Close Without Saving" escape above.

## 8. Markdown preview column

### 8.1 Rendering
- **Native rendering, no WKWebView:** custom lightweight renderer producing an `NSAttributedString`, displayed in a read-only, selectable `NSTextView` (TextKit 1).
- Re-rendered on edit (debounce acceptable); preview scroll position preserved across re-renders.

### 8.2 Supported Markdown subset (v1)
- ATX headings `#`–`######` (sized/bold styles).
- Paragraphs (consecutive non-blank lines merged, blank line = paragraph break).
- Unordered lists (`-`, `*`, `+`) with bullets and indent; ordered lists (`1.`, `1)`).
- Blockquotes (`>`) — indented, gray.
- Fenced code blocks (``` ``` ```) — monospaced on light-gray background, no per-language highlighting inside the preview in v1.
- Horizontal rules (`---`, `***`).
- Inline: `**bold**`, `*italic*`, `` `code` ``, `[title](url)` (styled as link; clickable).
- Not in v1: tables, images, footnotes, HTML passthrough, nested lists beyond one level, setext headings.

### 8.3 Scroll synchronization
- **One-way: editor → preview.** Requirement: the first line visible in the editor ≈ the first content visible in the preview; approximate is fine, should feel quick (sub-second), need not be instantaneous.
- Mechanism: the renderer records an anchor `(source line → position in rendered output)` for every block element. On (throttled) editor scroll, the preview scrolls so the anchor with the greatest source line ≤ the editor's first visible line is at the top.
- No sync back from preview scrolling to the editor.

## 9. Persistence

| What | Scope | Mechanism |
|---|---|---|
| Sidebar width, editor/preview split fraction | global | `UserDefaults` (`@AppStorage`) |
| Open top-level folders | per window | `@SceneStorage` (JSON snapshot) |
| Open file + cursor position | per window | `@SceneStorage` (JSON snapshot) |
| Filter text | per window | `@SceneStorage` (JSON snapshot) |
| Window frames | per window | system window restoration |

- On relaunch: folders that no longer exist on disk are silently dropped; a last-open file that no longer exists is simply not opened.
- Restoring the open file re-opens it from disk (content is never persisted by the app) and restores the cursor location, scrolled into view.

## 10. Menus & shortcuts

| Menu item | Shortcut | Behavior |
|---|---|---|
| File → Open Folder… | Cmd+N | opens a new window and prompts for a folder (its sole root); Cancel leaves an empty window |
| File → Add Folder to Window… | Cmd+Shift+O | add top-level folder(s) to the focused window |
| File → Save | Cmd+S | save open file (disabled when none/clean; autosave is unconditional, §7) |

Commands act on the focused window's state (`focusedSceneObject`), except **Open Folder… (Cmd+N)**, which is app-level — it creates a new window and is not focused-window-scoped.

## 11. Error handling & edge cases

- Binary or unreadable file selected → alert, selection stays on the previous file.
- File deleted/renamed externally while open → save recreates it at the old path (no watching in v1); refresh updates the tree.
- Empty file, file without trailing newline, very long single line (wraps), CRLF content (opened as-is) — must not crash; line numbering counts `\n`.
- Folder with thousands of files: scan is recursive and synchronous in v1 — acceptable; skip-list keeps the worst offenders out. (If it proves slow, move scan off the main thread — behavior otherwise unchanged.)
- Two windows editing the same file: allowed, last save wins; no coordination in v1.

## 12. Non-goals (v1)

Tabs, split editors, find/replace, file create/rename/delete from the sidebar, git integration, LSP/completion, themes/dark mode, printing, preview→editor scroll sync, file-system watching, encodings beyond UTF-8/Latin-1 fallback.

## 13. Planned project structure

```
FEdit.xcodeproj
FEdit/
  App/FEditApp.swift            app entry, commands (menus), settings keys
  Models/WorkspaceModel.swift   per-window state: roots, open file, dirty/save/autosave logic
  Models/FileNode.swift         tree node + recursive scanner
  Models/FilterQuery.swift      boolean filter parser/evaluator
  Views/ContentView.swift       three-column layout, dividers, persistence wiring
  Views/SidebarView.swift       search field, tree mode, filtered flat mode
  Editor/CodeEditorView.swift   NSTextView wrapper (representable + coordinator)
  Editor/LineNumberRulerView.swift
  Editor/SyntaxHighlighter.swift  languages, rules, light theme colors
  Preview/MarkdownRenderer.swift  markdown → NSAttributedString + line anchors
  Preview/MarkdownPreviewView.swift  read-only text view + scroll-to-anchor
```

## 14. Implementation order

1. Xcode project scaffold; empty three-column layout with persisted draggable dividers.
2. Folder sidebar: open/scan/tree, then filter query + flat mode.
3. Editor: text view wrapper, line numbers, open/save/dirty + always-on debounced autosave.
4. Syntax highlighting (Swift, Python, Markdown).
5. Markdown renderer + preview column + scroll sync.
6. Session persistence (scene snapshots, defaults) and multi-window polish.
