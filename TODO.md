# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (filter-anchors) Anchored filter terms (end/start of path) — filtering for `.swift` currently also matches `foo.swiftdep` (correct as a substring, but there's no way to say "the pattern ends here"). Add regex/fzf-style ANCHOR operators to the filter query language: a trailing `$` anchors a term to the END of the root-relative path (`.swift$` matches `foo.swift` but not `foo.swiftdep`), and a leading `^` anchors to the START (`^src/` matches only paths beginning `src/`). This mirrors fzf (`^prefix`, `suffix$`) and regex, so it reads as standard. A bare `$`/`^` with no other characters, or one appearing mid-term, degrades gracefully (treated literally, per the existing malformed-input policy). Touches `Models/FilterQuery.swift` (tokenizer + matcher: strip a leading `^` / trailing `$` from each term and switch that term from `contains` to `hasPrefix`/`hasSuffix`/both) and the search-field placeholder in `Views/SidebarView.swift`. Update SPEC §5.4/§5.5. Depends on (filter-query).
- [ ] (sidebar-hscroll) Horizontally scrollable sidebar list for long paths — when a subdirectory + filename (tree mode) or a relative path (filter mode) is wider than the sidebar column, the row currently tail-truncates so the actual filename can be unreadable. Make the sidebar list horizontally scrollable so the full name can be read by scrolling right, instead of (or in addition to) truncation. Touches `Views/SidebarView.swift` (wrap the tree/flat list content in a horizontal `ScrollView`, or otherwise let row content exceed the column width and scroll; keep the vertical `List`, the selection highlight, and `OutlineGroup` disclosure working). Consider the interaction with the fixed column width (divider 1) and that the header strip + search field stay put (only the list scrolls). Decide truncation-vs-scroll behavior in /plan. Depends on (folder-sidebar), (filter-query). Spec §5.3/§5.4.

## Bugs
