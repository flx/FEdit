# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (session-restore) Session persistence and multi-window polish — `Models/WorkspaceModel.swift`: Codable snapshot (root paths, open file path, filter text, cursor) exposed as JSON; `Views/ContentView.swift`: @SceneStorage save/restore per window (missing folders silently dropped, missing file not opened, cursor restored and scrolled visible, content always re-read from disk); verify frames restore via system window restoration and that all menu commands target the focused window. Depends on (open-save), (filter-query). Spec §3, §9.

## Bugs

- [ ] (md-link-scan-quadratic) MarkdownRenderer inline link parsing is O(n²) on bracket-heavy input — `Preview/MarkdownRenderer.swift`: each unmatched `[` re-scans to EOF for `]`/`)`, so a document with thousands of unmatched brackets (e.g. `[`×40000 ≈ 6 s) degrades quadratically. Correct and terminating, but a live-preview cliff. Fix with a single-pass scan or a monotonic "no closing bracket/paren after position p" watermark. Interim mitigation lives in (markdown-preview): render off the main thread / on the debounce. Found in markdown-renderer adversarial review.
