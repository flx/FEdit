# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features

- [ ] (git-editor-wait) `fedit --wait` so fedit can be git's editor — git (and `crontab -e`, `GIT_EDITOR`, etc.) runs the editor command and blocks until it exits, but `scripts/fedit` is a thin `open -a` wrapper that returns immediately. Add a `--wait`/`-w` flag that keeps the CLI alive until the opened file's window closes (needs an app-side signal on window close, not `open -W`, which waits for the whole app to quit). Then `git config core.editor "fedit --wait"` works. Touches scripts/fedit, FEdit/App/OpenRequest.swift, FEdit/App/LaunchCoordinator.swift, FEdit/App/WindowCloseGuard.swift.

## Bugs

