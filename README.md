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

A handful of pure-logic modules (filter query, markdown renderer, git status parsing, file tree scanning, session snapshots, line counting) also have standalone `swiftc`-run regression harnesses under `scripts/*/main.swift`, used in place of an XCTest target.

## License

FEdit is free software, licensed under the [GNU General Public License v3.0](LICENSE) (or, at your option, any later version).

Copyright © 2026 Felix Matschke
