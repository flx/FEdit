# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (column-header-bars) Column header bars for the folder and editor columns — a top bar over the sidebar (folder) column shows the open folder name(s): the last path component of each root, comma-separated when more than one (e.g. `~/Documents/Programming/swift/FEdit` → `FEdit`; two roots → `FEdit, FlyWheelCADV3`); a top bar over the editor (second) column shows the open file's name (e.g. `TODO.md`), empty/hidden when no file is open. `Views/ContentView.swift` (add the two header bars in the three-column layout), reading `WorkspaceModel.roots` (`url.lastPathComponent`) and `openFileName`; decide whether these bars replace or complement open-save's window `.navigationTitle(openFileName)` / `.navigationSubtitle`. Depends on (folder-sidebar), (open-save). Spec §4.

## Bugs

(none yet)
