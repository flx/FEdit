# DONE

Shipped items, moved here from TODO.md by `/done`.

## Features

- [x] (xcode-scaffold) Xcode project scaffold and app shell — Create `FEdit.xcodeproj` (file-system-synchronized group, macOS 26 target, Swift 5 mode, no sandbox/entitlements, ad-hoc signing, GENERATE_INFOPLIST_FILE) plus `FEdit/App/FEditApp.swift` (WindowGroup, 1100×700 default / 700×400 min, light-only appearance, GPL header boilerplate for all future sources) and a placeholder `FEdit/Views/ContentView.swift`. Accept: `xcodebuild` succeeds; app launches to an empty light window; Cmd+N opens more windows. Spec §2–§3. (shipped 2026-07-17)
- [x] (split-layout) Three-column layout with persisted draggable dividers — `Views/ContentView.swift`, new `Views/SplitDivider.swift`; `SettingsKey` constants in `App/FEditApp.swift`. Sidebar width via divider 1 (default 1/3 of default window width, clamp 160–600 pt); editor/preview split via divider 2 (default 1/2 of non-sidebar width → 1/3·1/3·1/3, clamp 15–85 %); preview column driven by a stub `isMarkdown` flag until (open-save); both positions in @AppStorage, shared across windows; sidebar width unchanged when preview toggles; resizeLeftRight hover cursor. Accept: drag both dividers, relaunch restores them. Spec §4. (shipped 2026-07-17)
- [x] (folder-sidebar) Folder sidebar with tree view — New `Models/FileNode.swift` (recursive scanner: skips dotfiles, `node_modules`, `.build`, `DerivedData`; folders-first sort), new `Models/WorkspaceModel.swift` (per-window ObservableObject: `roots`, add/remove/refresh, NSOpenPanel), new `Views/SidebarView.swift` (sections per root with `~`-abbreviated header, disclosure tree, file rows selectable with highlight, header context menu Remove/Refresh, empty-state placeholder with Open Folder button), File → Open Folder… (Cmd+Shift+O) via focusedSceneObject in `App/FEditApp.swift`. Selection just records the URL until (open-save). Depends on (split-layout). Spec §5.1–§5.3, §10. (shipped 2026-07-17)

## Bugs
