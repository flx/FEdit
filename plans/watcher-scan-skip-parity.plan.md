# watcher-scan-skip-parity — plan (Revision 2)

**Risk tier: hi.** Touches the scanner's classification core (`FileNode.scanChildren`, pinned by
a gate harness), the scheduler's walk seam (`WalkLauncher` payload — every `RootScanTests`
fake), and the FSEvents gate; parity between two subsystems is the whole point, so a subtle
divergence IS the failure mode. Full plan, plan review, both code reviewers.

*Revision 2 — full re-cut after the adversarial plan review (2 Critical, 6 High, 6 Medium,
3 Low/Nit, 3 tensions; all accepted, none rejected — see Decisions). The load-bearing changes:
the recorded index is consulted for INTERMEDIATE path components only (Rev 1's final-component
consult made a stale skip self-perpetuating — a regression Rev 1 mis-sold as "damping is the
safety net"; damping never manufactures a request the gate dropped); index keys are RELATIVE to
the root (kills the standardized-vs-canonical rebase, the `//` fifth-site hazard, and the
temp-dir dependence of harness assertions); the gate gets the `(canonicalRootPath, rootURL)`
pair plumbing Rev 1 wrongly claimed it wouldn't need; the scanner's new entry point gets its own
name (a return-type-only overload doesn't compile) with the old signatures as THIN WRAPPERS over
the single implementation; unreadable directories are recorded too (the TCC storm class);
criterion 2's undecidable biconditional is replaced by an enumerated case table; the SPEC/doc
targets and gate baselines are corrected.*

## The defect (filed from async-root-scan; mechanism CONFIRMED by experiment 2026-08-11)

`FileNode.scanChildren` delegates hidden-ness to Foundation (`.skipsHiddenFiles` — dot-prefixed
names **and** `UF_HIDDEN` entries; `~/Library` is the latter). The FSEvents gate
`WorkspaceModel.isSkippedTreePath` re-implements the rule as a dot-prefix test plus the name
set. Divergences, both directions:

- **`UF_HIDDEN`, no dot** (`~/Library/**` under a `$HOME` root): passes the gate → drives
  damped full rescans forever that can never surface anything.
- **A plain file named `node_modules`**: the scanner keeps it, the gate drops any component
  with that name → a genuine change to that file never auto-refreshes.
- **(surfaced by this review) Unreadable / TCC-denied directories**: the scanner shows them
  empty and records nothing; every event under them passes the gate and re-walks — the same
  storm shape as `~/Library`, e.g. `~/Documents` under a `$HOME` root with TCC denied.

Hard constraints: the gate runs per-path inside FSEvents bursts under a **no-syscall-per-path**
rule (and, added this revision, an allocation budget — see Gate); the scanner has no
hidden-predicate to hoist. Arch-review direction: one owned skip predicate the scanner *asks*
rather than delegates, so parity is structural.

## Design

### Scanner (`FileNode.swift` — stays Foundation-only)

- **Single implementation, new name** (a return-type-only overload is ambiguous at the existing
  call sites): `scanRecordingSkips(directory:cancellation:) -> ScanOutcome` where
  `struct ScanOutcome: Sendable { var node: FileNode; var skippedIndex: [String: Set<String>];
  var unreadableDirs: Set<String> }`. The existing `scan(directory:)` /
  `scan(directory:cancellation:)` become **thin wrappers that discard the record** — one
  implementation, so FileNodeTests' existing assertions keep pinning the production scanner
  (Rev 1 would have left them pinning dead code).
- Enumeration drops `.skipsHiddenFiles`; `.isHiddenKey` joins the existing per-entry
  `resourceValues` call (zero added syscalls per kept entry — verified: one call regardless of
  key count). The owned predicate:
  `let hidden = (rv?.isHidden ?? false) || name.hasPrefix(".")` — the dot term is deliberate
  belt, making "dot ⟹ skipped" true **by construction** (SPEC §5.2 states dotfiles are skipped;
  the gate's static dot rule then matches the scanner unconditionally, on any volume), then
  `if hidden || ((isDirectory || isSymbolicLink) && skippedDirectoryNames.contains(name))`.
  A non-dot entry whose `resourceValues` fails reads as not hidden → kept (T3: a tree-fidelity
  change vs Foundation in that rare failure case; favors showing over silently hiding).
- **Recording, relative keys**: `skippedIndex[parentDirRelPath] = skipped child names not
  starting with "."` (dot skips are name-decidable at event time; recording them would bloat
  the index for zero information). `parentDirRelPath` is the directory's path **relative to the
  scanned root** (`""` for the root itself). `unreadableDirs` = relative paths of directories
  whose `contentsOfDirectory` threw (recorded by the caller of the throwing enumeration —
  `scanChildren` returns the error signal upward or records directly; implementer's choice,
  pinned by tests).
- Cost note (T2, accepted): hidden entries in descended directories now surface to the loop and
  pay one `resourceValues` each before being skipped; hidden *subtrees* are still never
  descended. This slightly lengthens measured walk durations, which feed the proportional
  damping term — second-order, accepted.

### Scheduler (`RootScanScheduler.swift`)

- `RootScan` gains `var skipRecord: SkipRecord?` (`SkipRecord` = the index + unreadable set;
  `nil` until a landing applies — Optional per the house rule; absence = "no verdicts yet").
- `WalkCompletion` payload becomes `WalkResult: Sendable` (node, skipRecord, changed, duration).
  Default launcher calls `scanRecordingSkips`; fakes updated mechanically.
- `applyScan`: store the record on the **applied** branch (unchanged-but-applied landings
  included — fresher verdicts, no publish; verified: `scans` is not `@Published`, the scheduler
  is not an ObservableObject). Discarded landings store nothing (short-circuit verified).
  `noteRootRemoved` nils it with the other fields; entry GC already covers it.
- RootScanTests: mechanical fake updates + new cases — record lands; record survives an
  unchanged landing; record gone after removal; **a cancelled/superseded walk's partial record
  is discarded** (this assertion lives HERE, not FileNodeTests — the discard is the
  scheduler's generation check).

### Gate (`TreeSkipGate.swift`, new Foundation-only file; own harness)

Pure function over `(belowRootComponents, skipRecord?)` — the caller (the model) resolves the
root and produces the relative components, so the gate itself never sees absolute paths:

1. *(caller)* longest containing root by canonical path (existing `FileNode.path(_:isContainedIn:)`
   helper); outside-all-roots → skip, as today. The caller carries `(canonicalRootPath, rootURL)`
   **pairs** — Rev 1's "keeps its signature" was impossible: `rootPaths` as built today is a
   `map` that destroys the path↔URL association, and `scans` is keyed by the standardized URL.
   `handleTreeChange` builds the pairs once per batch; `isSkippedTreePath`'s signature changes
   accordingly (private, one caller — verified).
2. any component starting with "." → skip. Exact vs the scanner **by construction** (the
   scanner's dot belt above), not by a volume-behavior assumption.
3. any **intermediate** component in `skippedDirectoryNames` → skip (intermediates are provably
   directories). Final components fall through — the plain-file fix.
4. any **intermediate** component recorded as skipped in `skippedIndex` at its position, or any
   **proper ancestor** prefix in `unreadableDirs` → skip. **Intermediate/ancestor only, by the
   same argument as step 3** (the Critical from review): a final component's *current* state is
   unknowable at event time, and a stale index hit on a final component would drop the very
   event (the `chflags nohidden`, the delete-and-recreate, the `chmod +r`) whose rescan would
   refresh the index — a self-perpetuating skip. With the final component always falling
   through, the toggle event on the entry itself triggers the rescan that un-sticks everything
   beneath it. Residual (recorded): if that single toggle event is lost (FSEvents coalescing or
   overflow), staleness persists until the next event naming that entry, an explicit Refresh,
   or relaunch — strictly narrower than Rev 1's indefinite window, and the un-damped storm the
   item fixes cannot recur from it.
5. else: not skipped (rescan).

**Allocation budget (review finding, now load-bearing):** steps 2–3 run first, on `Substring`
components with zero heap allocation — they drop the overwhelming mass of real bursts (`.git`
paths at step 2, `node_modules`/`DerivedData` interiors at step 3). Step 4 runs only for
survivors, and only when the record is non-empty (early-out on `nil`/empty). Its per-survivor
cost is at most depth-many prefix `String` builds. This ordering is a stated invariant, not an
implementation detail.

### What each divergence becomes

- `~/Library/**` deep events: `Library` is intermediate → recorded → dropped, **no rescan**.
  Events naming `Library` itself (rare: attribute toggles) → one rescan → unchanged → damped.
- Plain file `node_modules`: final component falls through step 3, in the tree, not recorded →
  rescans correctly.
- TCC-denied `~/Documents/**`: recorded unreadable → deep events dropped; `chmod`/grant fires
  an event on the dir itself → rescan → record refreshed.
- `mkdir node_modules` / Xcode recreating `DerivedData` (T1, the accepted price): the event
  names the dir itself (final) → falls through → **one full rescan where today's name test
  dropped it free**; structure unchanged (scanner skips it) → diff-guard absorbs, damping backs
  off, the new record covers its interior. Bounded like today's `~/Library` case; far rarer.

## Acceptance criteria

1. **Scanner behavior unchanged for every existing case**: FileNodeTests' current **34**
   assertions pass unmodified (they exercise the wrapper entry points, which now delegate to
   the single new implementation — so they pin production code, not a twin). NEW FileNodeTests
   assertions: `chflags hidden` fixtures (new — Rev 1 wrongly claimed they existed; the fixture
   must assert `chflags` returned 0 so a flag-less volume can't make the cases vacuous):
   UF_HIDDEN dir excluded from the tree and recorded (relative key); UF_HIDDEN non-dot file
   recorded; dotfiles skipped but NOT recorded; plain `node_modules` file kept and not
   recorded; skip-named dir recorded; unreadable dir in the tree (empty) and in
   `unreadableDirs`; **the A1 differential as a standing assertion** — a harness-local ~10-line
   `.skipsHiddenFiles` reference walk compared against the production scanner over the mixed
   fixture (scoped here deliberately; it exists to pin the equivalence on future OS versions).
2. **Gate case table** (TreeSkipGateTests, new harness: FileNode.swift + TreeSkipGate.swift —
   its own compile line, so FileNodeTests' documented command is untouched and tiers stay
   independent). Enumerated, each direction asserted (replaces Rev 1's undecidable
   biconditional): dot component anywhere → skip; skip-name intermediate → skip; skip-name
   final → NOT skip; recorded-index intermediate → skip; recorded-index FINAL → NOT skip (the
   un-stick rule); unreadable ancestor → skip; unreadable dir itself as final → NOT skip;
   nil/empty record → statics only; `/`-root shapes (components produced by the caller — gate
   sees only components, so the `//` class is structurally excluded, asserted anyway via the
   caller-side helper); empty-components (event on the root itself) → NOT skip.
3. **Plumbing pinned in RootScanTests**: record lands / survives unchanged landings / drained
   on removal / discarded with a superseded generation. Fakes updated.
4. **Storm case**: traced in review (`handleTreeChange` → pairs → gate → no `requestScan` for a
   recorded-intermediate batch) — honestly: no harness reaches `handleTreeChange` (AppKit
   imports), so this is review-traced plus the gate-level table above. The FSEvents path-form
   premise is A5, recorded below, with its runtime check owed to the standing GUI pass.
5. **Docs**: SPEC §5.2's "Hidden files (dotfiles) are skipped" line (SPEC.md:65 — the actually
   inaccurate, actually existing line; Rev 1 cited a nonexistent §11 paragraph) becomes
   normative for the owned predicate: dotfiles AND system-hidden (`UF_HIDDEN`) entries skipped,
   skip-names for directories/symlinks. `WorkspaceModel.isSkippedTreePath`'s "known divergence"
   doc block (its real home) is replaced by the parity story. SPEC §13 rows + README harness
   sentence for the new file/harness. Gate baselines for the unchanged harnesses, measured this
   session: MarkdownRenderer 147, FilterQuery 90, GitStatus 11, OpenRequest 49, Snapshot 20,
   LogicalLine 28, FilterRowCache 105, FeditShim 51; FileNodeTests grows from 34, RootScanTests
   from 133. (DONE.md's older cli-open counts are historical; the measured values govern.)
6. Build green; all 11 harnesses green (10 existing + TreeSkipGateTests).

## Load-bearing assumptions

- **A1** `isHidden`-based classification ≡ `.skipsHiddenFiles` (dot ∪ UF_HIDDEN).
  **Probe-CONFIRMED this session** (mixed fixture incl. `chflags hidden` file+dir: identical
  kept-sets). The dot belt additionally makes the dot half true by construction; the standing
  differential in criterion 1 keeps the UF_HIDDEN half pinned. Residual (review finding 9,
  accepted): exotic volumes (`/.hidden` legacy, SMB/FAT) may classify differently — the belt
  covers dots there too; UF_HIDDEN doesn't exist on such volumes, so the divergence class is
  empty on them.
- **A2** The gate caller may read `scanScheduler.scans` (main-actor, `private(set)` — verified).
- **A3** *(replaces Rev 1's rebase)* Below-root relative components are identical whether the
  absolute path arrived in standardized or canonical form — guaranteed by construction now:
  the caller derives components from the canonical event path against the canonical root path,
  and the scanner derives keys relative to its own root URL; neither crosses forms. Rev 1's
  symlink reasoning ("target outside the root → dropped") was wrong in the common
  same-root-target case (review finding 17) — with relative keys the question doesn't arise:
  FSEvents delivers target-form paths, the scanner also keys the target dir (the link is a
  leaf), and both resolve below the same root.
- **A4** Record size is negligible (non-dot hidden entries + unreadable dirs are rare). Memory
  not correctness; `tree-node-budget` bounds the walk anyway.
- **A5** *(new — review finding 13)* FSEvents delivers `~/Library/**`-class paths in a form
  that resolves inside the watched root under `canonicalPath` (the firmlink-preserving realpath
  form, per external-change-watch's Fix 3 record). Never directly measured for `$HOME`; if
  false, today's gate already drops those events as outside-all-roots — meaning the storm
  arrives (if at all) via the form the fix handles, and the fix's other three divergence
  classes are unaffected. Runtime confirmation owed with the standing manual GUI pass.

## Tiers

**Tier 1 — scanner owns the predicate + records (pays off alone: recording semantics pinned
first).** `FileNode.swift` (`ScanOutcome`, `scanRecordingSkips`, wrappers, dot belt) +
FileNodeTests additions incl. the standing differential. Revert: restore `.skipsHiddenFiles`,
delete the new entry point.

**Tier 2 — plumb the record.** `WalkResult`, `RootScan.skipRecord`, launcher + fakes,
RootScanTests cases (incl. the discard case). Revert: independent single-commit revert.

**Tier 3 — the gate.** `TreeSkipGate.swift` + `TreeSkipGateTests` (own compile line) +
`handleTreeChange`/`isSkippedTreePath` pair-plumbing and delegation + docs (criterion 5).
Revert: restore the old dot-prefix body and drop the harness.

Tier 1 is behavior-neutral **conditional on A1** (probed; the belt narrows the exposure to the
UF_HIDDEN-≢-isHidden case, which the standing differential would catch) — stated, per review,
rather than claimed unconditionally.

## Out of scope

- Bounding the tree; per-root scan outcome records (tree-node-budget).
- Damping changes — and, corrected from Rev 1: damping is NOT a safety net for gate drops (it
  defers requests; it cannot manufacture one the gate never made). The staleness residual is
  handled by the final-component fall-through, not by damping.
- Cross-window record sharing.
- Watcher delivery-form instrumentation (A5's runtime check — owed to the GUI pass).

## Decisions taken

*(2026-08-11, planning — Rev 1)*

- **Record-what-was-skipped over per-event stat or batch-memoized stat caches** — the
  no-syscall rule is absolute; the record is computed where the syscalls already happen and
  consulted where none are allowed.
- **Dot-prefixed names excluded from the record** — name-decidable at event time; recording
  them swells the index for zero information.
- **The record updates on unchanged-but-applied landings** — fresher verdicts, no publish.

*(2026-08-11, plan review fold-in — Revision 2; all 18 findings + 3 tensions accepted)*

- **Index consulted for intermediates only** (Critical 1): Rev 1's final-component consult made
  stale skips self-perpetuating — the same unknowable-type argument Rev 1 itself made for
  skip-names, applied consistently. The un-stick path is the toggle event's own fall-through.
- **Relative keys** (Critical 2 + findings 4, 8, 17): kills the standardized/canonical rebase,
  the `//` fifth site, and the fixture's temp-dir form-dependence; the key shape is decided in
  Tier 1 where it is produced, not discovered in Tier 3.
- **Pair plumbing `(canonicalRootPath, rootURL)`** (Critical 2): `isSkippedTreePath` cannot
  keep its signature — Rev 1's claim traced as impossible.
- **`scanRecordingSkips` + thin wrappers** (findings 5, 6): return-type-only overloads don't
  compile; wrappers keep the 34 pinned assertions pointed at production code.
- **`unreadableDirs` recorded** (finding 7): the TCC storm is the same shape; an absent index
  key must not read as "scanner kept everything".
- **Enumerated case table over the biconditional** (finding 3): the biconditional was false for
  every kept file and undecidable across event kinds.
- **Statics-first allocation ordering as a stated invariant** (finding 14).
- **Criterion/doc corrections** (findings 10, 11, 12, 16): cancelled-record assertion moved to
  RootScanTests; SPEC target is §5.2:65 + the WorkspaceModel doc block; chflags fixtures are
  NEW (with a chflags-success guard); measured gate baselines listed, including the 430-not-434
  arithmetic slip in the previous DONE entry (corrected there this session).
- **T1 accepted and priced**: `mkdir node_modules`-class events now cost one rescan (today:
  free drop) — the unavoidable dual of fixing the plain-file divergence; damped thereafter.
- **T2/T3 accepted**: slight walk lengthening feeds the damping term; failed-stat non-dot
  entries now surface (favor showing).

*(2026-08-11, implementation + code review — hi tier, both reviewers, blind/parallel)*

- **Implementer deviations accepted** (all reported, all verified): `SkipRecord`/`ScanOutcome`
  both land in `FileNode.swift` in Tier 1 (forced by the two harness compile lines — the plan's
  implied Tier-2 arrival would have broken TreeSkipGateTests' documented command);
  `belowRootComponents` lives in `TreeSkipGate.swift` so the harness can reach the caller-side
  derivation; the gate keeps `hasPrefix(".")` over a `utf8.first` micro-optimization
  (probe: a combining-mark name diverges between the two — parity beat the allocation);
  `minRescanGap`'s falsified doc block rewritten (scope flagged, accepted). Implementer
  mutation-tested 14 mutants — 13 killed initially, and it caught its own vacuity gap (bare-name
  vs relative index keys coincide at depth 1; deep-key fixtures added, mutant then killed).
- **Both reviewers: gate semantics and the skippedIndex un-stick property CONFIRMED exact**
  (the edge reviewer probe-verified that `chflags` toggles deliver an event naming the entry —
  the un-stick premise HOLDS for the index). **Accepted, HIGH (both reviewers converged): the
  `unreadableDirs` gate consult is removed entirely.** The un-stick premise is empirically
  FALSE for readability: a live FSEvents probe showed interior churn never delivers the parent
  directory's own path, and a TCC grant fires no event at all — so a recorded-unreadable dir
  (worst case: the `""` root key for a TCC-denied root, the item's own motivating bullet) was a
  PERMANENT auto-refresh black hole that self-healed before this item. Unreadable subtrees now
  stay rescan-on-event (damped, bounded — the pre-item behavior) and recover automatically; the
  recording stays as advisory data for tree-node-budget's outcome record. Rev 2's criterion-2
  "unreadable ancestor → skip" table rows are flipped to pin the new contract.
- **Accepted, Medium (edge)**: the caller evaluated the record lookup eagerly per path
  (Swift argument evaluation), defeating the statics-first invariant — records now resolved
  once per batch into the `rootPairs`. Plus: A1 differential gains the symlink triple
  (`chflags -h` for the link itself — plain `chflags` follows links, probed), a vacuous
  final-position assertion moved to intermediate position, message/doc precision fixes
  (SPEC §5.2 describes Foundation's `isHidden`, not bare `UF_HIDDEN`; longest-root equivalence
  argument narrowed; "tree-only readers" dead-code claim removed).
- **Rejected**: nothing. **No third review round**: the only control-flow change is a rule
  REMOVAL both reviewers prescribed (plus the per-batch record resolution they suggested);
  verified by orchestrator trace + the flipped, non-vacuity-checked harness cases + full gate.
