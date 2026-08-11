# FEdit

A lightweight, memory-frugal text editor for macOS with Markdown preview and simple syntax highlighting for Swift, Python and Markdown.

The motivation: editing a couple of kB of text should not cost a gigabyte of RAM. FEdit deliberately avoids heavyweight machinery — native AppKit text views instead of a web-based editor, and a native Markdown renderer instead of an embedded browser.

## Features

- **Three-column window** — folder sidebar, editor, and a Markdown preview column that appears only while a Markdown file is open. Draggable, persisted splits (1/3 · 1/3 · 1/3 by default), each column topped by a fixed header strip (folder name(s), open file name, "Preview").
- **Folder sidebar** — open multiple top-level folders (each its own section, `~`-abbreviated header, Remove/Refresh menu); expandable tree view, or a flat filtered list driven by a boolean query language (`.py OR .swift`, `AND` binds tighter than `OR`, space = union, `^`/`$` anchor a term to the start/end of the path). Sidebar roots and the open file are watched (FSEvents / vnode) so external adds, removes and edits are reflected automatically. Files whose working-tree content differs from `HEAD` show a read-only "(changed)" badge when the root is a git repo.
- **Editor** — line numbers, soft wrapping, lightweight regex-based syntax highlighting for Swift, Python and Markdown; opens any UTF-8 (Latin-1 fallback) text file; font size zoom (Cmd-+ / Cmd-− / Cmd-0), app-wide and persisted.
- **Markdown preview** — rendered natively (no WKWebView), with approximate scroll sync: the preview follows the first line visible in the editor.
- **Save flow** — explicit save (Cmd+S), plus unconditional, always-on debounced autosave (no toggle) on typing pause, file switch, window close and quit. The only surviving dialog is a minimal "Close Without Saving / Cancel" escape when a close/quit flush fails.
- **File creation** — File → New… (Cmd+N) creates a file via a filename sheet in the current folder.
- **Session restore** — reopens folders, last file, cursor position, splits and windows.

## Status

v1 feature-complete: every planned item has shipped (see [DONE.md](DONE.md); [TODO.md](TODO.md) is empty). [SPEC.md](SPEC.md) is the maintained implementation contract, kept in sync with each shipped change; [Specification.md](Specification.md) is the original high-level pitch, kept as historical context.

## Requirements

- macOS 26 or later
- Xcode 26 (to build)

## Building

Open `FEdit.xcodeproj` in Xcode and Run. No third-party dependencies.

A handful of pure-logic modules (filter query, filter row caching, markdown renderer, git status parsing, file tree scanning, per-root scan scheduling, session snapshots, line counting, command-line path mapping) also have standalone `swiftc`-run regression harnesses under `scripts/*/main.swift`, used in place of an XCTest target; the `fedit` shim has a shell one at `scripts/FeditShimTests/run.sh`.

## Installing

`scripts/install.sh` builds the Release configuration (derived data goes to a fixed folder under `$TMPDIR`, outside the repo) and installs `FEdit.app` into `/Applications`, replacing any previous copy. Pass a directory as the single optional argument to install somewhere else. If FEdit is already running, quit and relaunch it to pick up the new build.

```sh
scripts/install.sh
```

The installer also drops a `fedit` command into the first writable directory among `$FEDIT_BIN_DIR`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin` (created if needed), with its app path pointed at wherever the bundle was installed. It never uses `sudo`, and a shim that cannot be placed is a warning, not a failed install.

## Command line

```sh
fedit notes.md            # opens notes.md, with its folder as the sidebar root
fedit .                   # opens the current directory as a root, no file open
fedit src/a.py docs/b.md  # one window each
fedit                     # just launches or activates FEdit
fedit --help              # usage, on stdout
```

Each path gets its **own new window** — an existing window, full or empty, is never disturbed (the request is delivered as the new window's own value, so it cannot land anywhere else). A file's **containing folder** becomes that window's sole sidebar root, so `fedit ~/notes.md` scans your entire home directory (the same cost as picking `~` in the Open Folder… panel). The scan runs off the main thread: the window appears immediately, showing `Scanning…` in the sidebar while the tree fills in behind it — though the finished tree is still held in memory in full, so a home-scale root is heavy. At most 8 paths per call.

`-h`/`--help` is recognized as the **first argument only** — after that everything is a path, since a file really can be called `--help`.

| Situation | Exit code |
|---|---|
| Success | `open`'s status (normally 0) |
| A path does not exist (nothing is opened, not even the valid paths) | 66 |
| More than 8 paths | 64 |
| `FEdit.app` could not be found | 69 |

Set `FEDIT_APP` to the bundle's path if it is not where the installer put it. If there is no bundle there, the shim falls back to asking LaunchServices for an app *named* FEdit — so a stale `FEDIT_APP` may quietly open a differently-located copy and still exit 0. The 69 row above applies only when neither resolves.

A few details worth knowing:

- **Symlinks are resolved.** The shim canonicalizes every argument with `realpath` (the usual command-line convention), so `fedit link/notes.md` shows the *real* folder in the sidebar, whereas opening the same folder through Cmd+O would show the link's name.
- **A dotfile has no sidebar row.** `fedit ~/.zshrc` opens the file in the editor as expected, but the sidebar skips hidden files, so nothing in the tree is highlighted.
- **A cold `fedit x.md` also restores your previous session.** The new window comes up next to the windows FEdit had when you last quit, not instead of them; it is then an ordinary window and comes back with the next session too.

## License

FEdit is free software, licensed under the [GNU General Public License v3.0](LICENSE) (or, at your option, any later version).

Copyright © 2026 Felix Matschke
