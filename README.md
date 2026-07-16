# FEdit

A lightweight, memory-frugal text editor for macOS with Markdown preview and simple syntax highlighting for Swift, Python and Markdown.

The motivation: editing a couple of kB of text should not cost a gigabyte of RAM. FEdit deliberately avoids heavyweight machinery — native AppKit text views instead of a web-based editor, and a native Markdown renderer instead of an embedded browser.

## Features (planned for v1)

- **Three-column window** — folder sidebar, editor, and a Markdown preview column that appears only while a Markdown file is open. Draggable, remembered splits (1/3 · 1/3 · 1/3 by default).
- **Folder sidebar** — open multiple top-level folders; expandable tree view, or a flat filtered list driven by a boolean query language (`.py OR .swift`, `AND` binds tighter than `OR`, space = union).
- **Editor** — line numbers, soft wrapping, lightweight regex-based syntax highlighting for Swift, Python and Markdown; opens any text file.
- **Markdown preview** — rendered natively (no WKWebView), with approximate scroll sync: the preview follows the first line visible in the editor.
- **Save flow** — explicit save, or opt-in autosave-on-file-switch (also offered directly from the unsaved-changes dialog).
- **Session restore** — reopens folders, last file, cursor position, splits and windows.

## Status

Specification phase — see [SPEC.md](SPEC.md) for the detailed implementation contract and [Specification.md](Specification.md) for the original high-level idea. Implementation has not started yet.

## Requirements

- macOS 26 or later
- Xcode 26 (to build)

## Building

Once the Xcode project lands: open `FEdit.xcodeproj` in Xcode and Run. No third-party dependencies.

## License

FEdit is free software, licensed under the [GNU General Public License v3.0](LICENSE) (or, at your option, any later version).

Copyright © 2026 Felix Matschke
