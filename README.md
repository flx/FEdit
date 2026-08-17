# FEdit

A lightweight, memory-frugal text editor for macOS with Markdown preview and simple syntax highlighting for Swift, Python and Markdown.

The motivation: editing a couple of kB of text should not cost a gigabyte of RAM. FEdit deliberately avoids heavyweight machinery — native AppKit text views instead of a web-based editor, and a native Markdown renderer instead of an embedded browser. In practice it settles at roughly 80–190 MB with small files open, most of which is framework memory an audit found to be irreducible rather than leaked; the point is the order of magnitude, not a race to the bottom.

## Features

- **Three-column window** — folder sidebar, editor, and a Markdown preview column that appears only while a Markdown file is open. Draggable, persisted splits (1/3 · 1/3 · 1/3 by default), each column topped by a fixed header strip (folder name(s), open file name, "Preview"). Windows are independent: each has its own folders, filter, open file and cursor.
- **Folder sidebar** — open multiple top-level folders (each its own section, `~`-abbreviated header, Remove/Refresh menu); expandable tree view, or a flat filtered list driven by a boolean query language (`.py OR .swift`, `AND` binds tighter than `OR`, space = union, `^`/`$` anchor a term to the start/end of the path). Scanning runs off the main thread — the window is usable while a big root fills in behind a `Scanning…` placeholder — and each root's tree is capped at ~50,000 entries, filled breadth-first, with a notice in that section when the cap is hit. Sidebar roots and the open file are watched (FSEvents / vnode) so external adds, removes and edits are reflected automatically. Files whose working-tree content differs from `HEAD` show a read-only "(changed)" badge when the root is a git repo.
- **Editor** — line numbers, soft wrapping, lightweight regex-based syntax highlighting for Swift, Python and Markdown; opens any UTF-8 (Latin-1 fallback) text file; font size zoom (Cmd-+ / Cmd-− / Cmd-0), app-wide and persisted.
- **Markdown preview** — rendered natively (no WKWebView), with approximate scroll sync: the preview follows the first line visible in the editor.
- **Save flow** — explicit save (Cmd+S), plus unconditional, always-on debounced autosave (no toggle) on typing pause, file switch, window close and quit. A clean buffer is reloaded when the file changes underneath you; a dirty one is kept and the window subtitle says "changed on disk" until the next save wins. The only surviving dialog is a minimal "Close Without Saving / Cancel" escape when a close/quit flush fails.
- **File creation** — File → New… (Cmd+N) creates a file via a filename sheet in the current folder.
- **Session restore** — reopens folders, last file, cursor position, splits and windows.
- **Light appearance only**, deliberately — no dark mode, no themes.

### Keyboard

| Shortcut | Action |
|---|---|
| Cmd+N | New… — create a file in the open file's folder (or the first root) |
| Cmd+O | Open Folder… — opens a **new window** and prompts for its sole root |
| Cmd+Shift+O | Add Folder to Window… — add root(s) to the focused window |
| Cmd+S | Save (autosave is always on regardless) |
| Cmd-+ / Cmd-− / Cmd-0 | Increase / decrease / reset the editor font size |

## Status

v1 feature-complete: every planned item has shipped (see [DONE.md](DONE.md); [TODO.md](TODO.md) is empty). [SPEC.md](SPEC.md) is the maintained implementation contract — kept in sync with each shipped change, and the place to look for exact behavior. It also absorbed the original one-page pitch, which used to live in `Specification.md`.

## Requirements

- macOS 26 or later
- Xcode 26 (to build)

## Building

Open `FEdit.xcodeproj` in Xcode and Run. No third-party dependencies.

A handful of pure-logic modules (filter query, filter row caching, markdown renderer, git status parsing, file tree scanning, per-root scan scheduling, watcher skip gating, session snapshots, line counting, command-line path mapping, `--wait` marker claiming) also have standalone `swiftc`-run regression harnesses — ten of them under `scripts/*/main.swift`, used in place of an XCTest target; the `fedit` shim has a shell one at `scripts/FeditShimTests/run.sh`.

Each harness's header comment carries the exact command that builds and runs it, e.g.

```sh
swiftc FEdit/Models/FilterQuery.swift scripts/FilterQueryTests/main.swift -o /tmp/fqtests && /tmp/fqtests
sh scripts/FeditShimTests/run.sh
```

## Installing

`scripts/install.sh` builds the Release configuration (derived data goes to a fixed folder under `$TMPDIR`, outside the repo) and installs `FEdit.app` into `/Applications`, replacing any previous copy. Pass a directory as the single optional argument to install somewhere else. If FEdit is already running, quit and relaunch it to pick up the new build.

```sh
scripts/install.sh
```

The installer also drops a `fedit` command into the first writable directory among `$FEDIT_BIN_DIR`, `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin` (created if needed), with its app path pointed at wherever the bundle was installed. It never uses `sudo`, and a shim that cannot be placed is a warning, not a failed install. Installing to a non-default destination (e.g. a temp directory for testing) skips the shim — it would repoint your real `fedit` at the throwaway copy — unless `FEDIT_BIN_DIR` is set explicitly.

## Command line

```sh
fedit notes.md            # opens notes.md, with its folder as the sidebar root
fedit .                   # opens the current directory as a root, no file open
fedit src/a.py docs/b.md  # one window each
fedit                     # just launches or activates FEdit
fedit --wait notes.md     # opens notes.md and blocks until that window closes
fedit --help              # usage, on stdout
```

Each path gets its **own new window** — an existing window, full or empty, is never disturbed (the request is delivered as the new window's own value, so it cannot land anywhere else). A file's **containing folder** becomes that window's sole sidebar root, so `fedit ~/notes.md` scans your entire home directory (the same cost as picking `~` in the Open Folder… panel). The scan runs off the main thread: the window appears immediately, showing `Scanning…` in the sidebar while the tree fills in behind it, and the ~50,000-entry cap keeps a home-scale root bounded (it loses only its deepest reached level's tail, and says so in its sidebar section). At most 8 paths per call.

`-h`/`--help` and `-w`/`--wait` are recognized as the **first argument only** — after that everything is a path, since a file really can be called `--help`.

| Situation | Exit code |
|---|---|
| Success | `open`'s status (normally 0) |
| A path does not exist (nothing is opened, not even the valid paths) | 66 |
| More than 8 paths, or a `--wait` that is not exactly one existing regular file | 64 |
| `FEdit.app` could not be found | 69 |
| `--wait` misconfigured: neither `HOME` nor `FEDIT_WAIT_DIR` set (no place for its marker), or a non-numeric `FEDIT_WAIT_ACK_TIMEOUT` | 78 |
| `--wait` gave up: the open produced no window within 30 s, or FEdit died holding the file | 1 |
| `--wait` interrupted by Ctrl-C, `kill`, or a closed terminal | 128 + signal |

Set `FEDIT_APP` to the bundle's path if it is not where the installer put it. If there is no bundle there, the shim falls back to asking LaunchServices for an app *named* FEdit — so a stale `FEDIT_APP` may quietly open a differently-located copy and still exit 0. The 69 row above applies only when neither resolves.

A few details worth knowing:

- **Symlinks are resolved.** The shim canonicalizes every argument with `realpath` (the usual command-line convention), so `fedit link/notes.md` shows the *real* folder in the sidebar, whereas opening the same folder through Cmd+O would show the link's name.
- **A dotfile has no sidebar row.** `fedit ~/.zshrc` opens the file in the editor as expected, but the sidebar skips hidden files, so nothing in the tree is highlighted.
- **A cold `fedit x.md` also restores your previous session.** The new window comes up next to the windows FEdit had when you last quit, not instead of them; it is then an ordinary window and comes back with the next session too.

### Using FEdit as your git editor

`fedit --wait <file>` opens one file in its own window and does not return until that window closes, which is the contract `git`, `crontab -e` and friends expect of an editor:

```sh
git config --global core.editor "fedit --wait"
```

`git commit` then opens `COMMIT_EDITMSG` in a FEdit window; write the message, close the window (Cmd+W), and the commit completes.

**How to abort a commit.** FEdit autosaves — there is no "close without saving" — so the way to abort is to **delete the whole message text and then close the window**. Git sees an empty message and aborts. (Simply typing nothing works the same way, since git's template lines are all comments.) Quitting FEdit while the message window is open counts as finishing: git gets whatever was autosaved.

The file opens with its **containing folder** as the sidebar root, so a commit-message window is rooted at the repository's `.git` directory. That is the same rule every other external open follows.

Details: it takes exactly one path, and that path must already exist (`fedit --wait new-file.md` is an error, not a create). It leaves a marker file in `~/Library/Application Support/FEdit/wait` for the duration of the wait — that is how the window tells the command line it has closed — and removes it on every exit path, including Ctrl-C. If the open never produces a window, it gives up after 30 seconds with exit 1 rather than blocking forever. `sudo crontab -e` is **not** supported: the marker would land in root's spool where FEdit never looks, so it gives up after that same 30 seconds. The full marker protocol — claim, acknowledgement, release, and the garbage collection that keeps a killed shim's marker from being claimed by a later wait — is [SPEC.md](SPEC.md) §15.2.

## License

FEdit is free software, licensed under the [GNU General Public License v3.0](LICENSE) (or, at your option, any later version).

Copyright © 2026 Felix Matschke
