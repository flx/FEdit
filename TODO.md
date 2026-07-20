# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (open-folder-new-window) Rework the folder-open menu flow and startup — three menu/UX changes plus a new-window open path. `App/FEditApp.swift`: (a) rename `File → Open Folder…` (Cmd+Shift+O) to `File → Add Folder to Window…`, behavior unchanged (`WorkspaceModel.addFolders` appends a section to the focused window); (b) turn the New Window command into `File → Open Folder…` (Cmd+N) which opens a **new window** and immediately presents the directories-only `NSOpenPanel`, opening the chosen folder as that new window's sole root (Cancel leaves an empty new window). (c) Startup: instead of a blank first window, launch straight into the folder picker so the user chooses a folder to open — **but only when there is no session to restore**: (session-restore)'s `@SceneStorage` restore of a prior window's folders/file must win, so the auto-picker fires only for a pristine scene with an empty snapshot (else two restored folders would each pop a picker). Needs a way to hand the picked folder to a freshly created scene's `WorkspaceModel` (e.g. SwiftUI `openWindow(value:)` with a `WindowGroup(for:)` payload, or a small pending-open queue) — touches `App/FEditApp.swift`, `Models/WorkspaceModel.swift` (add an open-in-new-window / single-root entry point), `Views/ContentView.swift` (startup + empty-state picker trigger). Update SPEC.md §21 (Cmd+N semantics) and §163–§164 (menu table) to match. Depends on (folder-sidebar), (session-restore).
- [ ] (column-header-bars) Column header bars for the folder and editor columns — a top bar over the sidebar (folder) column shows the open folder name(s): the last path component of each root, comma-separated when more than one (e.g. `~/Documents/Programming/swift/FEdit` → `FEdit`; two roots → `FEdit, FlyWheelCADV3`); a top bar over the editor (second) column shows the open file's name (e.g. `TODO.md`), empty/hidden when no file is open. `Views/ContentView.swift` (add the two header bars in the three-column layout), reading `WorkspaceModel.roots` (`url.lastPathComponent`) and `openFileName`; decide whether these bars replace or complement open-save's window `.navigationTitle(openFileName)` / `.navigationSubtitle`. Depends on (folder-sidebar), (open-save). Spec §4.

## Bugs

(none yet)
