# filter-walk-main-thread — plan (Revision 2)

**Risk tier: standard.** Single-threaded main-actor caching of derived view data; no concurrency,
no persistence-format change. The subtlety is cache invalidation (three sites), which is exactly
where a stale-sidebar bug would hide — so: plan review, then ONE code reviewer
(`adv-review-behavior`; the risk surface is UI/behavior staleness, not numerics/lifetime).

*Revision 2 folds in the adversarial plan review (14 findings, 3 tensions — all accepted; see
Decisions). What changed: the cache API collapsed to one parsed-query key (`FilterQuery` gains
derived `Equatable`) and one `invalidate` operation; the release path is pinned to `filterText`'s
`didSet` with the `FilterQuery.isEmpty` predicate; criteria state honestly what the harness can
and cannot pin; the memory and residual-hitch trades are quantified and recorded.*

## The defect (arch-review 2026-08-11, Critical)

`SidebarView.flatRows` runs `root.filesWithRelativePaths()` — a full DFS allocating one
`(String, FileNode)` tuple per file — **inside `body`, per root, per render, uncached**. Because
`SidebarView` observes the whole model, every-keystroke `openFile` writes and every-caret
`cursorLocation` writes re-render it: with a filter active on a home-scale root, typing in the
*editor* re-walks the tree on the main thread. Same defect class `async-root-scan` fixed, one
layer up, unmasked by it (SPEC §11 promises the filter field types during a scan).

## Goal

Filter mode stops re-walking the tree per render. The flat filtered list becomes cached derived
state, recomputed only when its inputs change: the root's tree (a scan landing that spliced) or
the query. Editor keystrokes and caret moves with an active filter cost a dictionary lookup, not
a DFS.

**Behavior is otherwise identical**: same rows, same DFS folders-first order, same per-section
"No matches", same "Scanning…" interception, same selection/badge behavior (`FileRow` untouched).

**Honest residual (recorded, not hidden):** the DFS itself stays O(N) on the main thread, run
once per *splice* instead of once per *render*. On a home-scale root under active structural
change (a build, `npm install` — `changed` landings reset the damping floor to 1 s) with a filter
active, that is a main-thread hitch at up to ~1 s cadence until `tree-node-budget` bounds N
(SPEC §11 declares the tree unbounded today). This item converts per-render → per-splice; the
size bound is the dependent item's job. Off-main precomputation at landing was considered and
rejected — see Decisions.

## Acceptance criteria

1. **No DFS on unchanged inputs — split by what can actually verify it:**
   - *Type level (harness-pinned):* `FilterRowCache.rows` executes its `provider` closure only
     on a tree miss — never on a hit, never on a query-only change. Pinned by a counting
     provider in the new harness.
   - *Wiring level (review-traced; no UI test infra exists):* the app's only
     `filesWithRelativePaths()` call site is inside the provider closure passed to the cache,
     and the model's `invalidate(url)` call sits **inside the `force || changed` splice branch**
     of the `land` seam — NOT after it — so a structurally-unchanged damped landing (the
     `~/Library` drip) does not invalidate. This exact placement is the item's known
     resurrection hazard; the reviewer must trace it, and the code comments there must name it.
2. **Invalidation is exactly right** (type level harness-pinned, each):
   - `invalidate(url)` drops the entry (used by both the splice and `removeRoot` — one
     operation, deliberately not two names for the same thing);
   - a query change refilters **without** re-running the provider;
   - `releaseAll()` empties everything;
   - wiring level (review-traced): `removeRoot` calls `invalidate`, and `filterText`'s `didSet`
     calls `releaseAll()` when `FilterQuery(newValue).isEmpty` — the SAME predicate
     `SidebarView.body` uses for the mode switch, so an operator-only or whitespace query that
     shows tree mode also releases the memory. (The accessor is NOT a release site: it is only
     reached in filter mode — a release there would never run.)
3. **Row parity**: for the same tree and query, cached output ≡ the inline
   `filesWithRelativePaths().filter { query.matches($0.path) }`, order included. Harness:
   differential comparison over several generated trees × several queries (including
   hit-after-invalidate and refilter-after-query-change sequences), not one fixture —
   non-vacuity per this repo's harness culture.
4. Build green; all 9 existing harnesses green with unchanged counts (422 + 133); new
   `scripts/FilterRowCacheTests` harness green (target ≥ 20 assertions).
5. Doc truth: `SidebarView.flatRows`'s "Computed inline per render … no caching layer" comment
   rewritten; SPEC §13 gains a `Models/FilterRowCache.swift` row and `FilterRowCacheTests` in
   the harness list; README's harness sentence gains "filter row caching" in its module-kind
   enumeration. SPEC §11 needs no change (its promise becomes more true).

## Design

### `FilterQuery` gains derived `Equatable`

`MatchTerm` is already `Equatable`; `FilterQuery` (a pure parse of the text, verified) derives
it. The cache keys on the **parsed value**, killing the two-argument
`(query, queryText)` invariant a text key would carry (a mismatched pair would cache rows under
the wrong key). Comparing `[[MatchTerm]]` per lookup is trivially cheap next to a filter pass.

### New Foundation-only type: `FEdit/Models/FilterRowCache.swift`

The model's per-root maps were just consolidated (root-scan-consolidation); this feature's state
arrives as ONE model property owning its own per-root storage, harness-testable standalone (the
model itself imports AppKit and cannot be):

```swift
/// Per-root cache of filter mode's derived rows. Main-actor-confined by its owner; plain struct.
struct FilterRowCache {
    struct Match: Equatable { let path: String; let node: FileNode }  // Equatable for parity tests
    /// The single read path. Contract: `provider` must not touch this cache (it is executed
    /// during a `mutating` access — a re-entrant read would trap on exclusivity).
    ///   hit  (entry present, same query)   -> cached rows, provider NOT called
    ///   tree miss (no entry)               -> provider() builds flat, filter, store
    ///   query miss (entry, other query)    -> refilter cached flat, provider NOT called
    mutating func rows(for url: URL, query: FilterQuery,
                       provider: () -> [Match]) -> [Match]
    mutating func invalidate(_ url: URL)   // splice landed / root removed — same operation:
                                           // full entry drop (no partial clear to get wrong)
    mutating func releaseAll()             // filter left — drop the retained memory
}
```

Internals: `[URL: Entry]`, `Entry = (flat: [Match], filteredFor: FilterQuery, filtered: [Match])`.
Two-level on purpose: the flat list is query-independent (one DFS per tree change, however the
user edits the query), and refiltering N cached rows is a string-match pass with no allocation
of paths — the expensive half (DFS + per-file path concatenation) is what the entry guards.
`invalidate` is a whole-entry drop by design: there is no staleness bit, so there is no partial
clear to implement wrongly (a reset-flat-keep-filtered bug would serve pre-splice rows).

**Memory, quantified:** an entry retains the flat list **and** the current filtered subset —
order ~100 B per file (a heap path `String` + a `FileNode` value), so a 500k-file `$HOME` root
holds tens of MB **while a filter is active in that window** — a real bite of SPEC §1's <100 MB
target, where the old inline walk allocated the same array transiently per render. That is the
trade: resident-while-filtering versus reallocated-per-keystroke. `releaseAll()` on leaving
filter mode bounds the exposure to filter-mode duration; `tree-node-budget` will bound N itself.
Priced in Decisions.

### Wiring (`WorkspaceModel` + `SidebarView`)

- Model: `private var filterRowCache = FilterRowCache()` plus
  `func filteredMatches(for root: FileNode, query: FilterQuery) -> [FilterRowCache.Match]`
  (provider = `{ root.filesWithRelativePaths() … }`). The **view passes its single per-render
  parse down** — `SidebarView.body` already builds `let query = FilterQuery(workspace.filterText)`
  once; the accessor does not re-parse (1 parse per render total, exactly as today). Mutating a
  **non-published** property from a view's body pass is sound (no publish, no invalidation loop,
  idempotent across speculative body passes).
- Invalidation sites:
  - in the `land` seam, **inside** the `force || changed` splice branch (criterion 1's traced
    placement): `filterRowCache.invalidate(url)`;
  - in `removeRoot`, next to `initialScanRootURLs.remove`: `filterRowCache.invalidate(root.url)`;
  - `filterText` gains a `didSet`: `if FilterQuery(filterText).isEmpty { filterRowCache.releaseAll() }`
    (fires for both writers — the TextField binding and `restore(fromJSON:)`'s direct assignment;
    verified both route through the setter). The parse-per-keystroke in `didSet` is the price of
    predicate agreement with the mode switch; it is one small parse, not a filter pass.
- `SidebarView.flatRows` calls `workspace.filteredMatches(for: root, query: query)` instead of
  the inline DFS+filter; everything else in the view (the `query.isEmpty` mode decision,
  "No matches", `FileRow`) is unchanged.

### `cursorLocation` stays `@Published` — the arch-review's sub-direction is REJECTED (narrowly)

Traced this session and independently confirmed by the plan reviewer: snapshot persistence is
`ContentView`'s `.onChange(of: workspace.currentSnapshot)`, which runs only on a body
re-evaluation. Un-publishing `cursorLocation` breaks SPEC §9 cursor restore for the
caret-move-then-quit session **with no intervening scroll, resize, setting change, or edit** —
other body-pass drivers exist (`@State` scroll/gutter writes, `@AppStorage`, resize), so the
breakage window is narrower than "any caret-only session", but it is real and silent.

Recorded honestly rather than as "the cache makes the publish free": keeping the publish keeps
the per-caret-move body re-evaluations AND the per-caret-move snapshot encode +
`@SceneStorage` write that already exist today — this item does not make them worse, and its
cache removes the only O(N)-walk term. The remaining per-caret costs (ForEach diff over the
cached rows, JSON encode) are pre-existing behavior, out of scope here, and the natural target
of a future observation-granularity item (`@Observable`), not of a persistence-breaking
un-publish.

## Tiers

**Tier 1 — `FilterRowCache` + `FilterQuery: Equatable` + harness (pays off alone: the
invalidation contract gets pinned before any UI wiring).** New `FEdit/Models/FilterRowCache.swift`
+ `scripts/FilterRowCacheTests/main.swift` (compile: `swiftc FEdit/Models/FileNode.swift
FEdit/Models/FilterQuery.swift FEdit/Models/FilterRowCache.swift
scripts/FilterRowCacheTests/main.swift -o <tmp>/frctests`). Counting-provider + differential
cases per criteria 1–3. The API above is frozen — the accessor shape (view-supplied parsed
query) is settled here, not re-derived in Tier 2. Revert: delete both files.
(`FilterQuery: Equatable` must not change `FilterQueryTests` output — derived conformance only.)

**Tier 2 — wire model + view (only pays off with Tier 1).** The three wiring sites, the
accessor, the `SidebarView.flatRows` swap, the doc rewrites (criterion 5). Revert:
single-commit revert restores the inline walk.

## Load-bearing assumptions

- **A1** The splice is the only mutation of a present root's tree — verified: `roots[index] =`
  exists only in the `land` seam; `roots.append` (placeholder; "Scanning…" intercepts before
  `flatRows`, so no entry is ever built for an unscanned root) and `roots.removeAll` (drop at
  removal) are the only other `roots` mutations. Reviewer independently traced re-add,
  restore, createFile (nested roots and the empty-`containingRoots` fallback), force-unchanged
  landings, and generation-discarded landings against the three sites: no hole.
- **A2** `FilterQuery(text)` is a pure function of its text — verified (stateless parser), so a
  value-keyed cache can never serve stale rows for equal queries.
- **A3** Mutating a non-published model property during a SwiftUI body pass is legal and
  invisible to SwiftUI's dependency tracking. (No `objectWillChange`, no tracked state write.)
- **A4** `filesWithRelativePaths()` order is deterministic per tree (DFS over already-sorted
  children) — verified; row identity is `FileNode.id == url`, so cached rows diff identically
  in `ForEach`.

## Out of scope

- Bounding the tree/flat-list size — `tree-node-budget` (this cache simply holds fewer rows
  once the tree is bounded; the truncation notice reads scheduler state, not this cache).
- Off-main flat-list precomputation at scan landing — rejected in Decisions.
- Any FilterQuery semantics change (Equatable is derived conformance only).
- The per-caret-move snapshot encode/ForEach costs and the observation-granularity question
  (`@Observable` migration) — pre-existing, unchanged by this item.

## Decisions taken

*(2026-08-11, planning)*

- **Cache lives in a dedicated model-owned type, not in `RootScan`** — deviation from the TODO
  sketch. `RootScan` is scan bookkeeping owned by the scheduler: `scans` is `private(set)`, the
  scheduler cannot see a *splice* (its `land` return is true for non-splicing landings too), so
  the TODO's shape would have needed a `contentVersion` plumbed through, and `[Match]` arrays
  in `RootScan` would sit in `RootScanTests`' compile line. **Priced, per review T1:** this
  buys the deviation at the cost of a THIRD per-root drain site in `removeRoot` (scheduler,
  "Scanning…" set, cache) — exactly the accretion the arch-review warned about ("a per-root
  filter index" is its literal example). Accepted knowingly: the drains are one line each, all
  three adjacent, and the alternative pollutes the scan subsystem with view data.
- **`cursorLocation` stays `@Published`** — rejection of the arch-review sub-direction, with
  the narrowed mechanism claim and the honest cost accounting above (the publish's remaining
  per-caret costs are pre-existing and not this item's to fix).
- **Two-level cache (flat per tree-epoch, filtered per parsed query)** — alternative: a single
  level keyed (tree, query), which re-runs the DFS on every filter keystroke; the DFS + path
  allocation is the expensive, query-independent half.
- **Empty query releases the cache; predicate is `FilterQuery.isEmpty`, site is `didSet`** —
  the accessor cannot be the site (never reached in tree mode — review finding 1), and the
  text-empty predicate would leak on operator-only/whitespace queries that show tree mode
  (finding 10). Trade recorded (T2): a clear-then-retype cycle re-pays one DFS per root.
- **Off-main precomputation at landing rejected, symmetrically argued (finding 5):** it would
  pay the retained memory for every window **always** (tree mode included, forever) to save a
  main-thread DFS only filter mode needs; the accepted design pays it only while a filter is
  active, plus `releaseAll` on exit. Both sides carry the ~100 B/file figure above; the
  residual per-splice hitch is recorded in Goal and falls to `tree-node-budget`.

*(2026-08-11, plan review fold-in — Revision 2)*

*(2026-08-11, implementation + code review — standard tier, `adv-review-behavior`)*

- **Implementer deviations accepted:** `Entry` is a private struct rather than the plan's tuple
  sketch (same fields; in-place mutation); no other deviation. Implementer mutation-tested the
  harness against four broken cache variants (24/21/3/34 failures) and probe-verified `didSet`
  fires for both writer shapes including operator-only text.
- **Reviewer verdict: all eight wiring traces clean, no behavior defect** — including the
  criterion-1 placement trace (invalidate inside the splice branch; damped no-op landings do not
  invalidate). Accepted and fixed by the orchestrator directly (all harness/doc, non-material —
  no re-review round per the materiality rule): the multi-root parity check compared `[] == []`
  (tree B has no `.swift` files — switched to a fixture-guarded `.txt` query); the "value keying"
  section couldn't distinguish hit from refilter (direct `FilterQuery ==`/`!=` assertions added);
  two `check(true)` padders became behavioral no-op-then-populate assertions; the "three sites"
  doc contradiction and the low-balled memory figure (~90 MB at 500k files, not "tens of MB")
  corrected. Harness 101 → 105 assertions, green.
- **All 14 findings accepted**, none rejected. Highs: dead accessor release path removed
  (didSet-only, predicate unified); criterion 1 split into what the harness pins vs what review
  must trace, with the splice-branch placement named as the resurrection hazard (the reviewer's
  one-line-position scenario); the `(query, queryText)` two-argument invariant eliminated via
  `FilterQuery: Equatable` value keying; the false "bounded and transient" claim replaced by
  the honest per-splice-hitch residual; memory quantified and the asymmetric rejection
  re-argued. Mediums/Lows: accessor contract settled in Tier 1 (view-supplied parse, resolving
  the Design/Wiring contradiction); `invalidateTree`/`removeRoot` collapsed to one `invalidate`
  (no partial-clear trap); doc targets corrected; parity check made differential; `Match` made
  an `Equatable` struct; provider re-entrancy contract noted.
