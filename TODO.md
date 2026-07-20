# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features


## Bugs

- [ ] (memory-use-audit) Investigate steady-state memory use (80–190 MB with only tiny files open) — profile with Instruments (Allocations + Leaks), don't guess. GOAL is GENUINE reductions only: the user explicitly rejects lazy-offload-then-reload tradeoffs (e.g. do NOT unload the markdown preview/highlighter and reload on demand). Prime suspects, worst-first: (1) **Leak hunt** — does a CLOSED window fully release its per-window `WorkspaceModel` + BOTH TextKit 1 stacks (editor `CodeEditorView` + markdown `MarkdownPreviewView`, each NSTextStorage/NSLayoutManager/NSTextContainer/NSTextView) + the line-number ruler? Add temporary `deinit` logging to `WorkspaceModel` and the two coordinators, open/close N windows, confirm dealloc and flat "persistent" bytes — growth here is the real bug. (2) **Retain cycles** around `WindowCloseGuard`'s NSWindowDelegate proxy (`retainedProxies` NSMapTable weak→strong; confirm `windowWillClose` uninstall actually runs) and the debounce/background closures in `CodeEditorView`/`MarkdownPreviewView` (both use `[weak self, weak textView]` — verify). (3) **Churn** (likely explains the 80↔190 swing, not a true leak): the `@SceneStorage` save path runs `snapshotJSON()` (a full JSONEncoder) on EVERY `ContentView` body eval — dedupe to only-on-actual-change; the per-keystroke full-document re-highlight and off-main re-render allocate transient attribute runs. (4) `FileNode` tree size for large opened folders (one node per file/dir). Expectation to validate/communicate: a large share of the baseline is irreducible SwiftUI/AppKit/TextKit/CoreAnimation framework memory that can't be cut without the rejected offload tradeoffs — so the likely deliverable is "confirm no window/buffer leak + trim the snapshotJSON churn," or a concrete leak fix. Touches (potentially) `App/WindowCloseGuard.swift`, `Editor/CodeEditorView.swift`, `Preview/MarkdownPreviewView.swift`, `Views/ContentView.swift`, `Models/WorkspaceModel.swift`. Investigation first — no code change without a confirmed cause.
