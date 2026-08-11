# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (installer-script) Installer script: build Release and install into /Applications — new `scripts/install.sh`: runs `xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Release` (or locates the latest Release build product), then copies/replaces `FEdit.app` in `/Applications` (remove old copy first so the ad-hoc-signed bundle isn't merged). Should fail loudly if the build fails and note that an already-running FEdit must be quit/relaunched to pick up the new version. README gains a short "Installing" section. No app-code changes.
- [ ] (cli-open) `fedit file.md` command-line invocation — running `fedit <path>` from a terminal launches (or activates) FEdit with a window whose sidebar root is the file's containing folder and with that file opened in the editor (Markdown preview appears automatically for `.md` per the existing isMarkdown flow). Two parts: (a) app-side file-open handling — accept a file URL at launch/reopen (Apple Events / `application(_:open:)` or `onOpenURL`), route it through the existing new-window mailbox (`App/LaunchCoordinator.swift`) so a pristine scene gets `parentDir` as its sole root and then `requestOpen`s the file (`App/FEditApp.swift`, `Models/WorkspaceModel.swift`, `Views/ContentView.swift`); (b) a `fedit` CLI shim (new `scripts/fedit`, roughly `open -a FEdit "$(realpath "$1")"`) installed onto PATH — installation of the shim can be folded into (installer-script). Decide behavior for no-argument and nonexistent-path invocations. Depends on (open-folder-new-window), (session-restore); shim install depends on (installer-script). Spec §3, §5.1, §10.

## Bugs
