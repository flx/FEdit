# FEdit — Detailed Specification

Version 1.0 — 2026-07-17. Expands `Specification.md` with the decisions from the design interview. This document is the implementation contract for v1.

## 1. Product overview

FEdit is a lightweight macOS text editor with a strong focus on low memory usage. It provides a three-column window: folder sidebar, text editor with line numbers and syntax highlighting (Swift, Python, Markdown), and a Markdown preview column that appears only for Markdown files.

**Memory goal:** working set well under 100 MB with a few small files open (motivating contrast: VS Code at ~1 GB). This goal drives two architectural choices: no web view for the preview, and plain AppKit text machinery instead of heavyweight editor frameworks.

The sidebar is bounded to match: **each scanned root's tree is capped at ~50,000 nodes** (low tens of MB, and the same cap bounds every derived per-node structure, e.g. filter mode's flat list), and a root that hits the cap declares it in the sidebar rather than showing a silently incomplete tree (§5.2). The cap is per root **per window** — several huge roots, or the same huge root in several windows, still multiply that cost.

## 2. Platform & project

- **Target:** macOS 26.0 minimum, Apple Silicon. No backwards compatibility required.
- **Project type:** Xcode project (`FEdit.xcodeproj`), SwiftUI app lifecycle, Swift 5 language mode.
- **Frameworks:** SwiftUI for app structure/chrome, AppKit (`NSTextView`, TextKit 1) for the editor and preview. No third-party dependencies.
- **Sandboxing:** none (personal tool). Files are accessed by plain path; no security-scoped bookmarks. Not App Store distributable in this form — acceptable.
- **Signing:** ad-hoc / sign-to-run-locally.

## 3. Windows

- `WindowGroup`-based: **multiple editor windows** opened via File → Open Folder… (Cmd+O), which opens a new window and prompts for a folder that becomes the new window's sole root (Cancel leaves an empty window).
- File → New… (Cmd+N) is focused-window-scoped — it creates a file in the key window's target directory (§7) rather than opening a new window.
- A file or folder handed to the app **from outside** (the `fedit` command, `open -a FEdit <path>`) always opens in a **new** window — no existing window, full or empty, is ever disturbed. The file's containing folder becomes that window's sole root and the file is opened in the editor; a folder argument just becomes the root. Several paths in one invocation give one window each (capped at 8 per delivery); a path that no longer exists is ignored. On a cold launch this window comes up **in addition to** the restored session's windows, and it is an ordinary window from then on — it is restored with the next session like any other.
- (git-editor-wait) `fedit --wait <file>` takes **exactly one existing file**, opens it exactly as above, and blocks until that window closes or FEdit quits (either counts as "done editing", so `git config core.editor "fedit --wait"` works). The wait is bounded in every failure direction: an open that produces no window is reported as an error after a timeout rather than waited on forever.
- Two window groups back this: `"editor"` (value-less) for Cmd+O/Cmd+N/restore, and `"cli-open"`, which presents the external open as the new window's **value** — the window a request lands in is the window the system created for it. An external open is applied **at most once, only by the process that issued it, and only to a window still empty at that moment**; a restored window — editor or cli-open alike — always wins with its own saved session state, and never re-runs the open it was originally created for (so a cli-open window quit before its first state save comes back empty). Each external open carries a unique identity, so repeating one gives a second window rather than refocusing the first.
- Each window owns its own independent state: folder list, filter text, open file, cursor.
- An ordinary launch always shows at least one window: the restored session's windows when there are any, otherwise one blank editor window — **including when the previous session ended with zero windows open** (a zero-window saved session must not produce a windowless launch). A launch whose only work is an external open shows that open's window instead. (zero-window-session-relaunch: a once-per-launch net presents the blank window if nothing else appeared; a launch into a hidden app is the recorded exception.)
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
- A root can also arrive without the panel: from Cmd+O's new-window pick, from session restore (§9), or from an external open (§3) — where it is the argument's containing folder (a file argument) or the argument itself (a folder argument), used verbatim, symlinks unresolved.
- With no folders open, the sidebar shows a placeholder with an "Add Folder to Window…" button (adds a folder to the current window).
- The sidebar column's fixed top strip (§4, a name-only summary — each open root's last path component, comma-separated) is **distinct from and complements** these per-root section headers (full `~`-abbreviated path, head-truncated, Remove/Refresh menu); the section headers are unchanged.

### 5.2 Directory scanning
- Recursive scan at add-time and on Refresh, run **asynchronously** off the main thread (§11): the folder appears in the sidebar immediately and its section shows a `Scanning…` placeholder until its tree lands. A root already in the sidebar keeps showing its current tree while a refresh rescan runs.
- **File-system watching (automatic refresh):**
  - **Open file:** watched with a precise vnode `DispatchSource`. An external change is reflected automatically, no manual Refresh. If the buffer is **clean**, it is reloaded from disk (caret preserved at its UTF-16 offset, clamped into the new length; scroll position — the first visible line — preserved). If the buffer is **dirty**, the in-editor version is kept (no clobber; SPEC §11 last-writer-wins) and a subtle **"changed on disk"** marker is shown in the window subtitle ("Edited — changed on disk"); the next save (or, under always-on autosave, the ~0.75 s flush) writes the buffer over the external version and clears the marker. FEdit's own writes (Cmd+S and every autosave, all through the single save path) are recognized by an `(inode, size, mtime)` signature and never mistaken for an external change. The reload reads the whole file synchronously (bounded by the 100 MB open cap). Delete/recreate does not blank the editor — the buffer is retained (a later save recreates the file). Promptness/timing is specified for local APFS/HFS+ volumes; on coarse-mtime volumes (SMB/NFS/FAT/exFAT) a same-size in-place external write within one mtime tick of FEdit's own write can be missed (accepted, last-writer-wins).
  - **Sidebar roots:** each root is watched recursively with FSEvents; an external add/remove (including in subdirectories) is reflected in the tree without manual Refresh, debounced so a burst of changes coalesces into a single rescan. After a rescan that found nothing changed, further watcher-driven rescans of that root are damped (§11) — so a change arriving during sustained no-op churn can be deferred by the current damping gap (up to 3× the root's own walk time) before it is reflected; it is deferred, never dropped, a change on a quiet root is not deferred beyond the 1 s floor, and manual Refresh is never damped. Removing a root stops watching it. Manual Refresh remains.
- Hidden entries are skipped: **dot-prefixed names** (any name starting with `.`), unconditionally, **and every entry Foundation reports as hidden** (`URLResourceKey.isHiddenKey`) — which on macOS covers the BSD `UF_HIDDEN` flag (e.g. `~/Library`, whose name contains no dot) and the other invisibility sources Foundation folds into that key (the Finder "invisible" bit, a legacy `/.hidden` listing). For a **symlink** the link's own flag decides, not its target's. Additionally skipped, for **directories and symlinks** only (a plain file of the same name is kept and shown): `node_modules`, `.build`, `DerivedData`. This is one owned predicate in the scanner, not a delegation to Foundation's `.skipsHiddenFiles`, and the automatic-refresh watcher gate above consults the scanner's own recorded verdicts rather than re-deriving the rule — so events *inside* a skipped subtree no longer drive rescans that can surface nothing, and a change to a plain file named `node_modules` still refreshes. Some events still do reach a rescan by design: any event while the root's first scan is still pending (no verdicts recorded yet); an event naming a skipped entry **itself** — that is what makes un-hiding it (`chflags nohidden`) refresh the tree automatically; and events under directories beyond a truncated root's cut (see "Bounded tree" below). Directories the scan could not read (permissions/TCC) are shown empty; events under them keep driving (damped) rescans deliberately, because nothing announces a permission grant, so recovery is automatic once access is restored.
- Sort order within a directory: folders first, then files, each alphabetically (`localizedStandardCompare`).
- **Bounded tree, per root:** a walk stops building nodes once it has built ~50,000 of them (§1). The walk is **breadth-first**: every level is complete before any node of the next one is built, so the loss always sits at the deepest level reached — the collapsed sidebar view is whole whenever the root's own listing fits the budget (only a root whose first level alone exceeds it can lose top-level rows), and a directory beyond the cut appears as an empty expandable folder. The cut is deterministic — the sort order above decides it, so it takes the sorted-later siblings at the level where the budget runs out (that level is the one incomplete level), and a Refresh of an unchanged tree cuts in exactly the same place. A truncated root **declares itself** with a muted notice row in its own section in both modes — tree mode names the count it built and the recovery (add the subfolder you actually want as its own root, which gets its own budget); filter mode shows a shorter "results may be incomplete" line. Directories beyond the cut are not visited at all, so they contribute no skip verdicts to the watcher gate above (which falls back to its static rules for them) — a third event class that reaches a rescan by design, joining the two above.
- A file created via File → New… (§7) appears in the tree after the automatic refresh that creation triggers; its row is visible when its containing folder is expanded (a file created into a collapsed nested folder still opens, but its row is revealed only on expand). On a **truncated** root a file created into a directory that lies beyond the cut still opens in the editor but gets no row at all; the default New… targets are unaffected, since root-level entries are the first nodes the budget spends (only a root whose own listing alone exceeds the budget could lose them).

### 5.3 Tree mode (empty filter)
- Expandable/collapsible tree (disclosure triangles), folders with a folder icon, files with a type-appropriate icon.
- Only files are selectable; clicking a file requests opening it (see §7). The open file's row is highlighted — with one caveat on a **truncated** root (§5.2): a file lying beyond the cut opens and edits normally but has no row to highlight (only files in already-cut *deep* directories can be in this state, never root-level ones).
- A file or folder row whose name is wider than the sidebar column **wraps to multiple lines** (rather than truncating); the row grows to fit so the full name is readable.

### 5.4 Filter mode (non-empty filter)
- The search field (standard rounded style, placeholder like `Filter files (e.g. .swift$ OR ^src/)`) sits at the top of the sidebar's list content, below the column's folder-name header strip (§4) when one is shown — top-to-bottom order: folder-name strip → search field → list.
- While the filter is non-empty, each section shows a **flat list of matching files as paths relative to that top-level folder** (e.g. `swift-source/main.swift`) — the top folder path is not repeated. A section with no matches shows a muted "No matches". Matching is complete **for the scanned tree**: on a truncated root (§5.2) files beyond the cut are not in the tree and so cannot match, which is exactly what that section's notice row declares — filter mode shows it too, so an incomplete result is never read as "this file does not exist".
- A flat-mode row's relative path likewise wraps to multiple lines when wider than the column, so the full relative path (including the trailing filename) stays readable.

### 5.5 Filter query language
- Tokens are separated by whitespace. `AND` and `OR` (uppercase, exact) are operators; everything else is a search term.
- A term matches if it is a **case-insensitive substring of the file's relative path** (so `.py` matches extension, `main` matches the name, `src/` matches a folder segment).
- A term may be **anchored** to the root-relative path, mirroring fzf/regex: a leading `^` anchors the match to the **start** of the path (`^src/` matches `src/a.swift`, not `lib/src/a.swift`); a trailing `$` anchors to the **end** (`.swift$` matches `foo.swift`, not `foo.swiftdep`); both together (`^main.swift$`) require the whole path to **equal** the anchored text (case-insensitively) — `^main.swift$` matches only the path `main.swift`, not `src/main.swift` and not a longer path that repeats it at both ends like `main.swift/main.swift`; a term longer than the path never matches. Anchored matching is still case-insensitive. Anchoring is a per-term property, independent of `AND`/`OR` grouping (`^src/ AND .swift$` is a valid AND-group of two anchored terms).
- Grammar (AND binds tighter than OR; adjacency = implicit OR):
  ```
  query   := orExpr
  orExpr  := andExpr (("OR" | implicit) andExpr)*
  andExpr := term ("AND" term)*
  ```
- Consequences: `.py .swift` and `.py OR .swift` both show the union; `.py AND .swift` is (almost always) empty; `.swift AND main OR .md` = (`.swift` AND `main`) OR `.md`.
- Malformed input degrades gracefully: leading/trailing/duplicate operators are ignored; an operator with a missing operand keeps the side that exists; a term that is only `^` or only `$` with no other characters, or has a `^`/`$` appearing anywhere other than the very first/last character, is matched literally rather than treated as an anchor (only one leading `^` and one trailing `$` per term are ever consumed as anchors).

### 5.6 File status (git)
- When an opened top-level root **directly contains `.git`** (it is itself the root of a git repository), each **file** row whose working-tree content differs from `HEAD` — modified, staged, untracked, or the **new** side of a rename — shows a small right-aligned **"(changed)"** badge. Directories are **never** badged, even when they contain changed files. A long file name wraps to multiple lines; the badge stays at the trailing edge of the row (aligned to the first line) and is never clipped or truncated.
- The changed-set is computed by shelling out to `git status --porcelain=v1 -z -uall` (permitted since the app is unsandboxed, §2) **off the main thread on a dedicated serial queue with a bounded 5 s watchdog timeout** — a hung or pathologically slow git is terminated and the window simply shows no badges (it never blocks or crashes). Results are cached per window as a set of absolute file URLs and refreshed on **save**, **manual Refresh**, **app activation** (the HEAD-move signal — no polling, no `.git` watch), and — via the §5.2 file-system watcher — external-change events.
- Reconcile scope: save and activation recompute only the changed-*set* against the **already-present** tree rows; they reconcile *modification* badges on files that still have a row but do not rescan the tree. Externally **created** or **deleted** files (which have no row / a stale row) are picked up automatically by the §5.2 file-system watcher — which rescans the tree and recomputes badges — or by a manual **Refresh**.
- Non-git roots, nested repos (only the top-level root's own `.git` is detected), and `.gitignore`'d files show **no** badge. The badge is uniform (no change-type or color coding) and read-only — it never modifies repository or file state.

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
- **Creating a file:** File → New… (Cmd+N) presents a per-window sheet with a filename field. On confirm it writes an **empty** file at the target directory — the open file's parent, or the first top-level root when nothing is open — then refreshes the sidebar so the new row appears (subject to §5.2's disclosure caveat) and opens the file through the same dirty-switch guard as a sidebar-row tap. Validation keeps the sheet open with an inline error on failure: the name must be non-empty, contain no `/` or `:`, and not start with a dot (a dotfile would be hidden from the sidebar, §5.2). A name collision shows an "already exists" error and **never overwrites** the existing file; other write failures show an inline error. Cancel closes the sheet with no change. New… is disabled when there is neither an open file nor any root.
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
| File → New… | Cmd+N | create a new file in the open file's folder, or the first root; disabled when neither exists (§7) |
| File → Open Folder… | Cmd+O | opens a new window and prompts for a folder (its sole root); Cancel leaves an empty window |
| File → Add Folder to Window… | Cmd+Shift+O | add top-level folder(s) to the focused window |
| File → Save | Cmd+S | save open file (disabled when none/clean; autosave is unconditional, §7) |

Commands act on the focused window's state (`focusedSceneObject`), except **Open Folder… (Cmd+O)**, which is app-level — it creates a new window and is not focused-window-scoped. **New… (Cmd+N)** is focused-window-scoped: it presents its sheet in the key window and creates in that window's target directory only.

## 11. Error handling & edge cases

- Binary or unreadable file selected → alert, selection stays on the previous file.
- File deleted/renamed externally while open → the buffer is retained (not blanked) and a save recreates it at the old path; the tree is watched (§5.2) and refreshes automatically, while after an external delete the open-file watcher goes dormant and auto-detection re-establishes when the file reappears (or on the next save/switch), and manual Refresh still updates the tree.
- Empty file, file without trailing newline, very long single line (wraps), CRLF content (opened as-is) — must not crash; line numbering counts `\n`.
- Folder with thousands of files: the scan is recursive and runs **off the main thread**, on a dedicated queue shared by all windows, one walk per root per window. The window stays interactive throughout — menus open, the filter field types, the editor scrolls, files open, a `fedit <path>` invocation lands — while the tree fills in behind it; a root whose first scan is still running shows `Scanning…` in place of its contents. Adding, removing, refreshing, and opening files are all available during a scan; an in-flight scan whose root is removed is cancelled and its result discarded, and the section never reappears. Repeat automatic (watcher-driven) rescans of the same root are damped: the minimum gap before the next walk doubles from 1 s up to 30 s for each consecutive rescan that finds nothing structurally changed — and once a rescan has come back unchanged (the signature of no-op churn), the gap is additionally never less than 3× the previous walk's own duration, so a sustained drip under a huge root is bounded to roughly a quarter of one core (per dripping root, per window) rather than running back-to-back. A lone change on a quiet root is not subject to the 3× term and reflects after at most the 1 s floor. A real structural change or an explicit **Refresh** resets the doubling, and an explicit Refresh is never damped. A damped event is deferred, not dropped. The skip-list still keeps the worst offenders out, and the per-root node budget (§5.2) bounds the rest: a walk stops building nodes at ~50,000, so its work is bounded by that budget plus the listings of the directories along the breadth it visited — one `resourceValues` per entry of every *visited* directory. That is a bound on **size, not a hard time cap**: a single pathological directory with millions of entries is still listed and classified in full, and a slow or stalled volume is still slow. On a root large enough to be truncated the damping's proportional (3× last walk) term is largely vestigial — the budget already caps what a walk costs — but it stays as the bound for roots that are large yet complete.
- Two windows editing the same file: allowed, last save wins; no coordination in v1.

## 12. Non-goals (v1)

Tabs, split editors, find/replace, file **rename/delete** and sidebar-driven file create (file **create** is supported via File → New… (§7) — creating from a sidebar context menu, and rename/delete, remain non-goals), git integration **beyond the single read-only "(changed)" file-status badge of §5.6** (no branch/ahead-behind/staging UI, no diff, no commit — the §5.6 badge is the one sanctioned exception to this non-goal), LSP/completion, themes/dark mode, printing, preview→editor scroll sync, encodings beyond UTF-8/Latin-1 fallback. (File-system watching of the open file and sidebar roots is now in v1 — see §5.2 — and no longer a non-goal.)

## 13. Project structure

```
FEdit.xcodeproj
FEdit/
  App/FEditApp.swift            app entry, commands (menus), settings keys
  App/LaunchCoordinator.swift   Cmd+O's pending-folder-pick mailbox, the external-open (§3)
                                dispatcher that opens one "cli-open" window per request, and the
                                zero-window launch net (§3: a windowless launch gets one blank window)
  App/OpenRequest.swift         external-open path → (sidebar root, file to open), resolved on
                                disk; plus CLIOpenToken, the window's presented value
  App/WaitMarkers.swift         `fedit --wait` marker spool: the claim-on-apply scan, its dead-
                                creator GC, and the spool path both sides spell (§3)
  App/WindowCloseGuard.swift    NSWindowDelegate proxy: flush-on-close/quit, Close-Without-Saving
                                escape, wait-marker release; app delegate's external-open (odoc)
                                sink and quit-time marker sweep
  Models/WorkspaceModel.swift   per-window state: roots, open file, dirty/save/autosave logic
  Models/FileNode.swift         tree node + breadth-first scanner (owns the skip predicate and the
                                per-root node budget; records what it skipped, per root, for the
                                watcher gate)
  Models/RootScanScheduler.swift  per-root scan state machine: coalescing gates, damping,
                                generations, cancellation tokens (owns the scan teardown)
  Models/TreeSkipGate.swift     FSEvents skip gate: would a rescan ignore this changed path?
                                (static rules + the scanner's recorded verdicts; no syscalls)
  Models/FilterQuery.swift      boolean filter parser/evaluator (terms, AND/OR, ^/$ anchors)
  Models/FilterRowCache.swift   per-root cache of filter mode's flat rows (invalidated per splice)
  Models/FileWatcher.swift      open-file vnode watcher + FileSignature (self-write key)
  Models/DirectoryTreeWatcher.swift  recursive FSEvents watcher for sidebar roots
  Models/GitStatus.swift        off-main `git status --porcelain=v1 -z` shell-out + parse for §5.6
  Models/WorkspaceSnapshot.swift  Codable per-window session snapshot (roots, open file, cursor, filter)
  Views/ContentView.swift       three-column layout, dividers, persistence wiring
  Views/SidebarView.swift       search field, tree mode, filtered flat mode
  Views/ColumnHeaderBar.swift    fixed-height column header strip (§4)
  Views/SplitDivider.swift      draggable divider (hit area, cursor, persistence hookup)
  Views/NewFileSheet.swift      File → New… filename sheet (§7)
  Editor/CodeEditorView.swift   NSTextView wrapper (representable + coordinator)
  Editor/LineNumberRulerView.swift
  Editor/LogicalLine.swift      logical-line counting/lookup shared by the ruler and cursor restore
  Editor/SyntaxHighlighter.swift  languages, rules, light theme colors
  Editor/Theme.swift             shared light-theme fonts/colors (editor + preview)
  Preview/MarkdownRenderer.swift  markdown → NSAttributedString + line anchors
  Preview/MarkdownPreviewView.swift  read-only text view + scroll-to-anchor
scripts/
  install.sh                    Release build + install of FEdit.app and the fedit shim
  fedit                         /bin/sh command-line shim around `open -a` (§3 external opens),
                                plus the --wait marker protocol
  FileNodeTests, FilterQueryTests, FilterRowCacheTests, GitStatusTests,
  LogicalLineTests, MarkdownRendererTests, OpenRequestTests, RootScanTests,
  SnapshotTests, TreeSkipGateTests
                                standalone swiftc-run regression harnesses (no XCTest target);
                                OpenRequestTests compiles OpenRequest.swift + WaitMarkers.swift
  FeditShimTests                shell harness for scripts/fedit (stub `open`/`pgrep`, no GUI), including
                                the --wait cases (it plays the app's part on the spool by hand)
```

## 14. Implementation order

All items below have shipped, in this order (see [DONE.md](DONE.md) for the detailed record of what each step actually delivered):

1. Xcode project scaffold; empty three-column layout with persisted draggable dividers.
2. Folder sidebar: open/scan/tree, then filter query + flat mode.
3. Editor: text view wrapper, line numbers, open/save/dirty + always-on debounced autosave.
4. Syntax highlighting (Swift, Python, Markdown).
5. Markdown renderer + preview column + scroll sync.
6. Session persistence (scene snapshots, defaults) and multi-window polish.
7. Font-size zoom, column header bars, the Cmd+O-opens-a-new-window rework, file-system watching, always-on autosave, the git "(changed)" badge, the Cmd+N/Cmd+O shortcut swap, File → New…, filter-query anchors, and sidebar row wrapping — each folded its own spec updates into the sections above; see `TODO.md`/`DONE.md` for anything still open.
