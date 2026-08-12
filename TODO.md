# TODO

Open work. Each item: `- [ ] (slug) Title — optional notes`.
The `(slug)` is how you reference the item in `/plan`, `/implement`, `/done`.
Add an explicit slug so it stays stable even if you reword the title.

Items are in ship order; each depends only on items above it (dependencies
called out per item). Spec references are to SPEC.md sections. Notes name the
files an item touches so overlapping items don't get batched in parallel.

## Features


## Bugs

- [ ] (tree-node-budget) Bound the scanned tree's size (memory + per-render cost) — a home-scale root held live in `@Published roots` violates SPEC §1's "working set well under 100 MB" and makes `SidebarView.flatRows`' O(N) per-keystroke filter walk reachable now that (async-root-scan) removed the freeze that used to hide it. Sketched as that plan's Tier 4 (`maxScannedNodes` ≈ 50k, deterministic DFS truncation, truncation note in the sidebar) and cut: the design must first resolve two SPEC conflicts its review surfaced — §1's memory bar needs an explicit large-root carve-out, and truncation silently breaks §5.4's filter-completeness promise (a file that exists reports "No matches") plus §5.2's created-file-appears promise for `createFile` into a truncated root. Arch-review pairing: the per-root scan outcome record (landed/cancelled/failed, duration, node count) belongs in this item's design — it is what the truncation notice needs and the app's only scan observability. `Models/FileNode.swift`, `Models/WorkspaceModel.swift`, `Views/SidebarView.swift`, SPEC §1/§5.2/§5.4/§11, README. Depends on (root-scan-consolidation), (filter-walk-main-thread).
