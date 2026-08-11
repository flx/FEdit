# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features


## Bugs

- [ ] (async-root-scan) Synchronous recursive root scan can wedge the app for minutes — observed during (cli-open) verification: a restored window whose root is home-directory-scale blocked the main thread ~135 s inside `WorkspaceModel.restore → addFolders → FileNode.scan → open()`, freezing launch (and everything queued behind it, including CLI opens). Pre-existing (SPEC §11 accepts synchronous scanning; identical on the pre-cli-open baseline), but `fedit ~/notes.md` makes it one typo away. Move `FileNode.scan` off the main thread (or bound its depth/count) without breaking the selection/refresh/watcher flows. `Models/FileNode.swift`, `Models/WorkspaceModel.swift`. SPEC §11 revision.
- [ ] (external-open-stray-window) An external open that launches the app leaves one stray blank editor window — AppKit/SwiftUI creates the blank startup window before the odoc Apple Event arrives, so `fedit x.md` from a cold start yields the CLI window plus one empty window (baseline-identical; recorded as an accepted residual in plans/cli-open.plan.md Revision 2). Investigate suppressing the initial window when a document open is in flight (or closing it if still pristine once the CLI window appears — carefully: that is a claim-like heuristic, see the Revision 2/3 history before building one). `App/FEditApp.swift`, `App/LaunchCoordinator.swift`, `Views/ContentView.swift`. Depends on (cli-open).
