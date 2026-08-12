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
- [ ] (zero-window-session-relaunch) Quitting with zero windows leaves the next ordinary launch windowless — measured on HEAD during (external-open-stray-window)'s Tier 0 probes: close every window, Cmd+Q, relaunch → **0 windows**, no scene, nothing (SPEC §3 expects one blank window; the stray-window plan's S11 assumed it too). The probe spike proved the fix shape end-to-end: an app-level opener registered from `App.body` (`@Environment(\.openWindow)` resolves there and can create the process's first window with no scene ever mounted — LB4/LB5 both probe-TRUE) plus a launch decision that presents a blank editor window when nothing else appeared. See plans/external-open-stray-window.plan.md Revision 3 for the probe data and Revision 2 for the reviewed design (D-R1 precedence: scene-registered opener stays primary). Arch-review note: when fixing this, prefer unifying Cmd+O onto the token mechanism over adding a third routing path. `App/FEditApp.swift`, `App/LaunchCoordinator.swift`, `App/WindowCloseGuard.swift`.
