# tree-node-budget — plan (Revision 2)

**Risk tier: hi.** Scanner-core restructure (harness-pinned; must stay tree-identical when
unbounded), scheduler seam, land-seam signature, SidebarView, and four SPEC promises. Full plan,
plan review (done — Rev 1 verdict: 1 Critical, 5 High, 6 Medium; all folded here), both code
reviewers on the diff.

*Revision 2 — full re-cut after the plan review. The Critical: Rev 1's DFS-preorder cut deletes
the TOP of the collapsed sidebar (folders-first + full descent makes the root's own files the
LAST preorder nodes — `~/notes.md` would never have a row on a truncated `$HOME`, and whole
top-level directories vanish). The cut is now LEVEL-ORDER. The other load-bearing changes: the
truncated flag becomes model-side `@Published` state through the land seam (Rev 1 stored
render-driving state in the deliberately-unpublished `scans`, and the flag can flip with
`changed == false` — tree at exactly the budget boundary — leaving a stale or missing notice);
counting is pre-order-by-construction under BFS; the ordering pin Rev 1 claimed the 70
assertions provided does not exist and is now explicit new work; a Tiers section exists.*

## Goal

Bound each scanned root's in-memory tree (and every downstream per-node cost: filter flat list,
ForEach diffing) with a per-root node budget enforced during the walk; truncation is
deterministic, LEVEL-ORDER (the collapsed sidebar view stays complete; what's missing is the
deep interior), and visibly declared per root in both sidebar modes. Resolve the SPEC conflicts
by declaration, not silent incompleteness.

## Design

### Scanner: BFS walk with a budget (`FileNode.swift`)

- `scanRecordingSkips` gains `nodeBudget: Int?` (default nil = unbounded; wrappers pass nil —
  the pinned entry points stay behavior-identical **by construction**). Production (the
  scheduler's launcher) passes `FileNode.defaultNodeBudget = 50_000`.
- **The walk becomes breadth-first**: a queue of (directory URL, relative path, depth). Per
  visited directory: enumerate, classify with the owned predicate (unchanged), record skips
  (unchanged — per-directory, same keys), **sort survivors folders-first /
  `localizedStandardCompare`**, then append children nodes in sorted order, counting each node
  as it is created; child directories are enqueued for later visits. Budget exhaustion cuts
  **mid-directory in sorted order** (deterministic) and stops the queue.
- Tree assembly: per-directory children lists collected into a map keyed by relative path,
  assembled into the immutable `FileNode` tree at the end (pure in-memory pass). Unbounded
  output is **tree-identical** to today's recursive walk (same per-directory filter + sort;
  sibling order never depended on recursion order) — pinned by NEW ordered-path assertions,
  not by the old membership checks (the review measured: only one directory's ordering is
  pinned today).
- Semantics at the cut: a directory node created but not yet visited when the budget hits has
  `children: []` — it renders as an empty expandable folder. Accepted and recorded: under BFS
  the beyond-the-cut region is "deep directories show empty", never "the root's own rows are
  missing" (the Rev 1 Critical). The single per-root notice is the signal.
- Counting rule (pre-order by construction): every child `FileNode` created counts; the root
  node does not. Exactly `min(nodeBudget, total)` nodes are built. `truncated == true` iff at
  least one classified survivor entry was refused (a budget of 0 over an EMPTY root is not
  truncated). Cancellation checks stay per-entry and win as today (partial discarded by the
  caller's generation check either way).
- `ScanOutcome` gains one named value used at EVERY seam (review finding: three shapes for one
  datum): `struct TreeBudgetReport: Sendable, Equatable { var nodeCount: Int; var truncated: Bool }`.

### Scheduler + land seam

- `WalkResult` carries the `TreeBudgetReport`; `RootScan` does NOT hold the truncated flag as
  render-driving state (the review's finding 4: `scans` is deliberately invisible to the UI).
  `RootScan.lastReport: TreeBudgetReport?` is still stored on applied landings — as
  observability and the notice's node count — but the RENDER signal is:
- **`land` gains `report: TreeBudgetReport`**; the model's seam updates a NEW
  `@Published private(set) var truncatedRootURLs: Set<URL>` with a **membership guard** (the
  `initialScanRootURLs` pattern, in the same seam): insert/remove only on actual change, so
  the notice updates even when the landing did not splice (`changed == false` with the flag
  flipping at the exact budget boundary — the review's traced hole), and a no-op landing
  publishes nothing. `removeRoot` drains it like its siblings.

### UI (`SidebarView`)

Per root section, both modes, iff `truncatedRootURLs` contains the root: a muted notice row.
Tree mode: "Showing the first {nodeCount, formatted} items — deeper folders are incomplete. Add
a subfolder as its own root to see more." Filter mode: "Results may be incomplete — the tree is
truncated." The count interpolates from the scheduler's `lastReport` (no hardcoded 50,000 —
review finding 16). NO "Refresh rescans" copy: truncation is deterministic, Refresh provably
changes nothing (finding 8); the add-a-subfolder-root affordance is the real recovery and each
root gets its own budget.

### SPEC/README resolutions (by declaration)

- **§1**: honest carve-out — *each root's* tree is bounded (~50k nodes, low tens of MB); the
  bound is per root per window, so many huge roots still multiply (finding 9 — no "cannot").
- **§5.2**: created-file row appears for non-truncated roots; on a truncated root the file
  still opens but its row can be beyond the cut — with BFS this affects files in *deep,
  already-cut* directories, NOT the default Cmd+N-into-the-root case (root-level rows are the
  first budgeted — the Rev 1 wording "may fall beyond" was wrong for the default case then,
  right now).
- **§5.4**: filter completeness scoped to the scanned tree + the visible notice.
- **§5.3**: the open file's row highlight — a file can be open with no row on a truncated root
  (deep files only, under BFS); caveat added (finding 13).
- **§11**: the walk on a pathological root is bounded by budget + the directory listings along
  the visited breadth (NOT a hard time cap — classify pays `resourceValues` per entry of every
  VISITED directory, finding 14); the damping note stays true but stops binding for truncated
  walks (T2); the stale "(The tree is not yet bounded…)" parenthetical at §11:193 is deleted
  (finding 11).
- **README**: the Command-line section's "held in memory in full, so a home-scale root is
  heavy" sentence updated (finding 11 located it; the criterion now names it).
- **§13**: no new files; WorkspaceModel/SidebarView lines unchanged in role.

## Acceptance criteria

1. **Unbounded parity, actually pinned**: FileNodeTests' existing 70 assertions pass
   unmodified, PLUS a new **ordered-path-list pin** on a NEW third fixture root (≥2 subdirs and
   ≥2 files at ≥2 levels; the existing two fixtures stay untouched per the harness's own
   comment): the unbounded scan's full preorder relative-path sequence asserted exactly. This
   is the restructure's real evidence (the review measured the old assertions pin ordering in
   exactly one directory).
2. **Budget semantics** (new FileNodeTests cases on the third fixture): budget ≥ total →
   identical tree, `truncated == false`, `nodeCount == total`; budget < total → exactly
   `nodeBudget` nodes, `truncated == true`, kept set = the BFS-order first-N (assert the exact
   kept path set INCLUDING that all root-level entries survive a budget ≥ level-1 size);
   mid-directory cut in sorted order; budget 0 on a non-empty root → no children, truncated;
   budget 0 on an empty root → not truncated; determinism (two runs equal); cancellation still
   wins; skip records only for visited directories.
3. **Plumbing** (RootScanTests): report stored on applied landings, absent for discarded,
   drained on removal; the land fake receives the report (fakes updated mechanically).
4. **The membership-guarded publish** (review-traced + land-seam code comment): truncated flag
   updates through `truncatedRootURLs` even on `changed == false` landings; no publish when
   unchanged; drained in `removeRoot`. No render-driving state in `scans` beyond the count the
   notice reads lazily.
5. **UI** (review-traced; no UI harness): notice in both modes iff truncated; none for
   `Scanning…` placeholders; count interpolated.
6. Docs per the section above. Gate: build + 11 harnesses green (FileNode grows from 70,
   RootScan from 148, others unchanged: 147/90/11/61/20/28/105/51 + TreeSkipGate 67).

## Load-bearing assumptions (fresh ids — "A1" already names the skip-parity differential)

- **B1** BFS collect+assemble yields tree-identical unbounded output (same per-directory
  classify+sort; assembly preserves). Pinned by criterion 1's new ordered pin.
- **B2** 50k is a knob (~10–15 MB/root tree + filter list while filtering), set and recorded,
  changeable in one code line (the notice interpolates; SPEC states the order of magnitude,
  not the constant).
- **B3** The land-seam signature change is mechanical for RootScanTests' fakes (they already
  rebuild `WalkResult` everywhere from the skip-parity item).
- **B4** `createFile`'s open path is tree-independent (verified: `requestOpen` → `loadFile`
  reads disk).

## Tiers

**Tier 1 — scanner BFS + budget + seam payload + harnesses (one commit; the review showed the
scanner and `WalkResult` cannot ship apart — the fakes construct `WalkResult` field-by-field).**
`FileNode.swift` (BFS, budget, `TreeBudgetReport`), `RootScanScheduler.swift` (`WalkResult` +
`RootScan.lastReport` + launcher passes the production budget), FileNodeTests (third fixture,
ordered pin, budget cases), RootScanTests (fakes + report cases). Pays off alone: the budget is
LIVE (walks bounded) even before the notice ships; revert = one commit.

**Tier 2 — the visible half.** `land` signature + `truncatedRootURLs` + SidebarView notice +
SPEC/README edits. Revert independently (Tier 1's flag then has no consumer — safe).

## Out of scope

- Paging/lazy loading of truncated subtrees; cross-root global budgets (per-root recorded
  honestly in §1); filter-list budget (bounded by the tree budget).
- The full landed/cancelled/superseded/failed taxonomy — deliberately deferred until something
  consumes it; recorded with the review's T4 caveat that absence-of-record conflates several
  states and `unreadableDirs` renders nowhere (both true; the notice needs neither).

## Decisions taken

*(2026-08-11, planning Rev 1)* Budget in the scanner (bounds time-ish and memory, not post-hoc
prune); wrappers stay unbounded (pinned entry points identical by construction); SPEC conflicts
resolved by visible declaration (silent truncation rejected).

*(2026-08-11, plan review fold-in — Revision 2; all 16 findings + 4 tensions accepted, none
rejected)*

- **Level-order cut replaces preorder** (Critical 1 + High 2): preorder deletes the collapsed
  view's own rows (root files are LAST in preorder; `Cmd+N` into a truncated root could never
  show its row — the review proved Rev 1's §5.2 wording wrong for the default case). BFS keeps
  every shallow level complete before any deeper node; beyond-the-cut is "deep dirs show
  empty" (accepted, T3-analogue, recorded).
- **Truncated flag is model-side `@Published`, membership-guarded, updated in the land seam**
  (High 3 + High 4): the flag CAN flip with `changed == false` (tree at exactly the boundary),
  and `scans` is deliberately unpublished — Rev 1's notice went stale/missing exactly there.
- **Pre-order counting by construction; budget-0-empty-root not truncated** (High 5).
- **The ordering pin is new, explicit work on a new fixture** (High 6): the "70 assertions pin
  it" claim was measured false — one directory's ordering is pinned today.
- **Tiers defined with the WalkResult coupling respected** (Medium 7).
- **Notice copy: no Refresh advice (provably a no-op); add-a-subfolder-root named as the real
  recovery; count interpolated** (Medium 8, Nit 16).
- **§1 without "cannot"; §5.3 added; §11:193 + README command-line sentence scheduled; the
  false snapshot-O(N) example dropped; fresh assumption ids** (Medium 9, Low 11–13, Nit 15).
- **One `TreeBudgetReport` at every seam** (Medium 10) — the TODO's fuller taxonomy remains
  deliberately unbuilt (recorded above with T4's caveat, flagged as a deviation from the TODO's
  letter: duration lives in the pre-existing `lastDuration`; the record is scoped to consumers
  that exist).
- **T1 traced and accepted** (the skip-record gap beyond the cut: statics still kill dot/named
  interiors; only the non-dot UF_HIDDEN class beyond the cut re-rescans, damped to ~1 bounded
  walk/30 s steady state — better than today's ratio); **T2** (proportional damping vestigial,
  harmless — §11 wording updated); **T3** (partial dirs read as complete — the notice is the
  signal).

*(2026-08-11, implementation + code review — hi tier, both reviewers, blind/parallel)*

- **Implementer deviations accepted** (all reported): the `Landing` signature change proved
  un-tierable (Tier-1 build failed with exactly the predicted arity error — evidence recorded,
  shipped as one staged unit); the refusal-detection frontier drain (needed for the honest
  "truncated iff a survivor was refused" semantics); BFS parity additionally proven by a
  byte-identical old-vs-new differential over real trees incl. a 229k-node root (the one
  divergence on a 926k-node root reproduced in an old-vs-old self-diff — fixture churn);
  mutation table incl. the Rev 1 Critical's mutant reproducing its exact failure.
- **Both reviewers: scanner, seam, and view CORRECT — no behavior defect.** Accepted and fixed
  by the orchestrator (all small, none control-flow beyond two one-liners): `nodeBudget` loses
  its silent `= nil` default (the single production budgeted line was the only thing making the
  app bounded, and a dropped argument would have un-bounded it with every harness green — the
  edge reviewer's Medium); `reserveCapacity` sized to the remaining budget, not the listing
  (pathological directory could reserve ~200 MB untouched); SPEC §5.2's filter-notice sentence
  scoped to what ships (count+recovery are tree-mode; filter mode's line is shorter — the
  behavior reviewer's Medium), "loses depth never breadth"/"always whole" corrected to the
  precise level-order guarantee, the "two events" enumeration gains its third class; README
  matched; drain-cost comment labeled a node-count bound; the unicode-canonical key-collision
  limitation documented (SUSPECTED-exotic, non-APFS volumes only); the fake-seam assertion
  message stops claiming to pin the model; SidebarView's "exactly like" nit.
- **Deliberately NOT done** (Lows, recorded): the two extra harness cases the edge reviewer
  sketched (drain-visit contributing skip verdicts; beyond-cut unreadable dir) — the suite's
  budget-4/6 cases already discriminate the mechanisms per the reviewer's own analysis; the
  probabilistic mid-directory sort pin stands (anchored by the three ordered-path pins).
  The moved stack-overflow point (walk → downstream diff, ~same depth threshold) recorded as
  informational. Plan's "RootScan from 148" baseline was PASS-line count (incl. loop
  iterations); the reviewer's 143 counts call sites — both true, metric named now.
- **No third review round**: fixes are doc/SPEC text plus the two reviewer-prescribed
  one-liners; full gate re-run green.
