# (editor-find) — Find in the editor text

**Revision 2** (2026-08-21). Rev 1 was reviewed by `adv-review-plan`, which
returned 22 findings. Two were refuted by probe; the other 20 are folded in
below and the tier seam was **re-cut** around them. See `## Decisions taken`.

**Risk tier: `hi`.** Justification: a new user-visible subsystem (a find bar,
its own focus/keyboard handling, a new Edit menu group) plus a boundary change
(`WorkspaceModel` grows find state, the editor grows a second attribute owner
over the text). It also **reverses a SPEC §12 non-goal**. Nothing here is
algorithmically deep, but the blast radius is wide: `CodeEditorView` is the file
every editor item has touched.

## Goal

Cmd+F opens a find bar over the **editable** `NSTextView` only. Literal
substring search, case-insensitive by default with a visible **Case sensitive**
checkbox. Find Next (Return, Cmd+G) steps and wraps. Esc closes. Every match is
highlighted, the current one is visually distinguished and scrolled into view,
and a count reads `3 of 17` / `Not found`.

The compiled-Markdown preview column is **never** searched. Replace is **not**
built (it stays a non-goal).

## Probes run against HEAD (facts, not assumptions)

1. **Temporary `.backgroundColor` is genuinely DRAWN by TextKit 1.** Rev 1 only
   probed that the API *compiles*, which the reviewer correctly called the wrong
   question. Re-probed properly: a hand-built `NSTextStorage` +
   `NSLayoutManager` + `NSTextContainer` stack, a temporary
   `.backgroundColor` over characters 11..<21, rendered through
   `drawBackground(forGlyphRange:at:)` into an `NSBitmapImageRep`, pixels
   sampled. Result: **1851/2016 sampled pixels red inside the marked run,
   0/2016 outside**. The whole D2 design rests on this and it is now measured,
   not assumed.
2. **Neither Cmd+F nor Cmd+G is claimed by SwiftUI's synthesized menu bar.** A
   bare SwiftUI `App` was compiled and its `NSApp.mainMenu` walked recursively:
   zero Cmd+F hits, zero Cmd+G hits. The reviewer's suspicion of a
   system-provided Find item shadowing ours does not hold on this OS.
3. **`CommandGroup(after: .textEditing)` places items well.** With Find/Find
   Next registered, they appear in **Edit**, in their own separated group
   directly after Select All and *above* Writing Tools / AutoFill / Dictation
   — the conventional location, not loose items at the menu's bottom.
4. **`NSScrollView` publicly conforms to `NSTextFinderBarContainer`** (compiles).
   Recorded for completeness; **Rev 2 no longer uses it** — see D7.
5. **The named highlight hazard is real:** `SyntaxHighlighter.highlight` opens
   every pass with `textStorage.setAttributes(…, range: fullRange)`
   (`Editor/SyntaxHighlighter.swift:88`), and `.backgroundColor` is already
   owned in the text storage by the inline-code rule (`:267`) and the fenced
   rule (`:283`).
6. **The editor coordinator does NOT live as long as the window.**
   `Views/ContentView.swift:115-138` puts `editorColumn` in a
   `_ConditionalContent` on `workspace.isMarkdown` (3 children vs 1), and
   `editorColumn` gates `CodeEditorView` again on `openFile != nil` (`:338`).
   Switching `main.swift` → `notes.md` **destroys and rebuilds the
   `Coordinator`**. This is the single most important correction from the
   review and it dictates where find state lives (D3).
7. **`updateNSView`'s `scrollView` parameter is never referenced in its body**
   (`Editor/CodeEditorView.swift:161`) — checked line by line. Recorded because
   Rev 1 mis-sized a fallback around it; Rev 2 does not need it either way.
8. The sidebar filter is a plain SwiftUI `TextField` bound to
   `workspace.filterText` (`Views/SidebarView.swift:117`) with no key
   equivalent of its own.

## Decisions

**D1 — Custom find bar, not `NSTextFinder`.** The stock find bar ships Replace
UI and hides case-sensitivity in the magnifier popup; those are precisely the
two things the item asks to be different (no replace, a *visible* checkbox). So
the cheap option cannot meet the ask. Unchanged from Rev 1.

**D2 — Highlights are layout-manager temporary attributes.** Owned by
`NSLayoutManager`, display-only, untouched by `textStorage.setAttributes` — so
probe 5's hazard is dead by construction rather than by re-applying after every
debounced pass, and there is no fight over the `.backgroundColor` key with
`:267`/`:283`. Probe 1 measured that they actually paint.
*Correction from Rev 1 (finding 21):* a temporary attribute **replaces** the
storage value for that key during display; it does not composite. The
behavioural conclusion (a match inside a code span shows the match colour) is
unchanged; the mechanism sentence was wrong.

**D3 — Find state lives on `WorkspaceModel`, not on the editor coordinator.**
Forced by probe 6: the coordinator dies on a Markdown↔non-Markdown switch, which
is exactly the `main.swift` → `notes.md` case D3 exists to serve. `WorkspaceModel`
is `@StateObject` per scene (`ContentView.swift:57`), so it is genuinely
per-window and outlives every editor rebuild. It gains:

```swift
@Published var isFindBarVisible = false
@Published var findQuery = ""
@Published var findCaseSensitive = false
@Published var findFocusTick = 0     // Cmd+F pressed (even while already open)
@Published var findNextTick = 0      // Cmd+G / Return
@Published var findCountLabel = ""   // written by the editor, read by the bar
```

The query and the checkbox survive a file switch and the bar stays open,
re-running against the new file. **Not persisted**: none of these joins
`WorkspaceSnapshot`, so SPEC §9's table is unchanged (the reviewer confirmed
`currentSnapshot`'s four fields are untouched).

**D4 — Cmd+F/Cmd+G are menu commands routed through `@FocusedObject`.** A menu
key equivalent beats ordinary in-field text editing, so Cmd+F reaches the editor
even when the sidebar filter has focus — which *is* the "the two searches stay
separate" requirement. Reuses the `focusedSceneObject(workspace)` route File →
New…/Save already use. Probes 2 and 3 confirm the key equivalents are free and
land in the right menu.

**D5 — Non-overlapping matches, `.literal` comparison.** `"aaaa"` / `"aa"` → 2
matches: the scan resumes at a match's end. `.literal` (plus `.caseInsensitive`
when the box is unchecked) so canonical-equivalence folding can never return a
range whose length differs from the query's. Diacritics are **not** folded:
`resume` does not match `résumé`.

**D6 — Find Next only; no Find Previous.** The item enumerates Return and Cmd+G
and nothing else. Probe 2 additionally shows Cmd+Shift+G is unclaimed, so the
reviewer's worry that users would hit a *system* Find Previous is moot —
pressing it does nothing at all. Filed as a follow-up TODO rather than smuggled
in.

**D7 — The find bar is a SwiftUI view in the editor column, not an AppKit bar
inside the scroll view.** This is the biggest structural change from Rev 1, and
it falls out of D3: once the state must live on `WorkspaceModel`, a SwiftUI bar
bound straight to that model is strictly simpler than an AppKit bar that has to
mirror it. It also deletes four separate Rev 1 problems at once — the
`NSTextFinderBarContainer` layout unknown, the ruler-plus-find-bar tiling
question, the Tier2↔Tier3 count-label cycle, and the SwiftUI→AppKit
first-responder handoff (focus now moves inside SwiftUI's own focus system via
`@FocusState`, never across the boundary). `makeNSView` keeps returning
`NSScrollView` and its signature is untouched.

**D8 — Enumeration is bounded and recompute is debounced.** Editor-text
recomputes ride the **existing 150 ms highlight debounce** (`highlightNow`), so
find costs the same order per debounce as the whole-document regex pass the app
already runs — no new unbounded per-keystroke work. Enumeration additionally
stops at `FindMetrics.matchLimit = 20_000`; past that the label reads
`3 of 20000+`. Bounding a scan and *saying so in the UI* is the house pattern
(the ~50,000-node sidebar budget announces its truncation the same way).

**D9 — Stepping scrolls but does not move the caret; closing moves it.**
Setting the selection on every step would fire `textViewDidChangeSelection` →
`noteCursorMoved` → `@Published cursorLocation` → a `JSONEncoder` +
`@SceneStorage` write **per Find Next press** (`ContentView.swift:255`), plus a
re-entrant `updateNSView`. So a step only calls `scrollRangeToVisible`. On
**close**, the caret is placed at the current match once — which is the
behaviour "Esc leaves the caret at the match" actually wants, at one snapshot
write instead of N.

## Acceptance criteria

Criteria 1–12 are asserted headlessly by `scripts/FindMatchTests`; 13–24 are
behavioural, each naming the exact observation that discharges it.

**Pure (`FindMatcher` + `FindSession`) — headless:**

1. `matches` returns `[]` for an empty query, a query longer than the haystack,
   and a zero-length haystack.
2. Case-insensitive is the default: `"Foo"` in `"foo FOO fOo"` → 3 ranges with
   `caseSensitive == false`; `"foo"` → exactly 1 with `caseSensitive == true`.
3. Matches are non-overlapping and strictly ascending: `"aaaa"` / `"aa"` →
   `[(0,2), (2,2)]`.
4. Every returned range is a valid UTF-16 subrange and has
   `length == (query as NSString).length`.
5. Multi-byte content: a haystack with an emoji (surrogate pair) before the
   match reports the correct UTF-16 offset, and an emoji query matches.
6. `matches` stops at `FindMetrics.matchLimit` and reports truncation; a
   haystack with 25,000 occurrences yields exactly 20,000 ranges and
   `didTruncate == true`.
7. `FindSession.recompute(text:caretLocation:)` seats `currentIndex` on the
   first match whose `location >= caretLocation`, and **wraps to 0** when none
   does. With no matches, `currentIndex == nil`.
8. `stepNext()` advances and wraps `16 → 0` for 17 matches; on an empty match
   array it is a no-op and leaves `currentIndex == nil`.
9. `clamp(toLength:)` drops every range extending past the new length and
   re-seats `currentIndex` into the surviving array (or `nil` if none survive).
   **This is the anti-`NSRangeException` invariant** and it is tested directly:
   40,000-character text with matches near the end, clamped to length 200.
10. `countLabel` is `""` when the query is empty, `Not found` when the query is
    non-empty with no matches, `3 of 17` normally, and `3 of 20000+` when
    truncated.
11. `currentRange` is always either `nil` or a range inside the last
    `clamp`ed length — asserted after a randomized sequence of
    recompute/step/clamp operations.
12. Changing `caseSensitive` re-enumerates: the same session over
    `"foo FOO"` reports 2 then 1 as the flag flips.

**Behavioural:**

13. Cmd+F with the **sidebar filter field focused** opens the editor's find bar
    and moves focus into its field; `workspace.filterText` is unchanged.
14. Typing a query highlights all matches, shows `1 of N`, and scrolls the first
    match into view. No matches → `Not found`, nothing highlighted.
15. **The hazard criterion.** With the bar open and matches highlighted, type a
    character in the editor and wait past the 150 ms debounce: highlights are
    still present (recomputed against the new text) and syntax colors correct.
16. Return and Cmd+G each advance; at the last match the next step wraps to the
    first, and the count tracks (`1 of 17` → … → `17 of 17` → `1 of 17`).
17. **Cmd+F while the bar is already open, with focus in the editor text,**
    returns focus to the query field and selects its contents. (This is the
    case a plain `Bool` cannot express — hence `findFocusTick`.)
18. Esc closes the bar and removes every highlight — **both** when focus is in
    the query field **and** when focus is in the editor text.
19. Re-opening with Cmd+F restores the previous query and re-runs it.
20. Opening a **Markdown** file while a **non-Markdown** file's bar is open
    (the coordinator-rebuild case, probe 6) keeps the bar open with the same
    query and re-runs it against the new file.
21. Two windows have independent find state: opening the bar and typing in
    window A leaves window B's bar closed and its query empty.
22. **Cmd+G on a freshly rebuilt editor does not fire a stale step.** Press
    Cmd+G seven times in `a.swift`, then open `notes.md`: the new editor does
    **not** jump to a match on load.
23. **Font zoom keeps the current match visible.** With `7 of 17` showing and
    the match on screen, Cmd-+ leaves that match on screen and the count
    unchanged.
24. **Opening/closing the bar does not scroll the preview.** With a Markdown
    file open, note the preview's top block, press Cmd+F, then Esc: the preview
    has not moved. (Stepping to a match *may* move the preview — that is
    intended and is criterion 16's business, not a defect.)

**Structural invariants** (not criteria — they cannot fail by construction, and
saying so is the point):

- The preview is never searched: `MarkdownPreviewView` builds its **own**
  `NSTextStorage`/`NSLayoutManager`/`NSTextContainer` (`:50-73`) that the find
  code holds no reference to. Rev 1 listed this as a criterion; the reviewer
  correctly noted it is untestable-because-impossible.
- `Editor/SyntaxHighlighter.swift` is **deliberately not modified**. The TODO
  lists it as an affected file; D2 is precisely the decision that makes editing
  it unnecessary. Recorded so its absence reads as a choice, not an oversight.

## Tiers

### Tier 1 — pure find core + harness

`FEdit/Editor/FindMatcher.swift` — enumeration only:

```swift
enum FindMetrics { static let matchLimit = 20_000 }

enum FindMatcher {
    static func matches(in haystack: NSString, query: String, caseSensitive: Bool)
        -> (ranges: [NSRange], didTruncate: Bool)
}
```

`FEdit/Editor/FindSession.swift` — the state machine that Rev 1 wrongly left
inside the coordinator (finding 6):

```swift
struct FindSession: Equatable {
    var query = ""
    var caseSensitive = false
    private(set) var matches: [NSRange] = []
    private(set) var didTruncate = false
    private(set) var currentIndex: Int?

    mutating func recompute(text: NSString, caretLocation: Int)
    mutating func stepNext()
    mutating func clamp(toLength length: Int)
    mutating func clear()
    var currentRange: NSRange? { get }
    var countLabel: String { get }
}
```

Both Foundation-only. `scripts/FindMatchTests/main.swift` covers criteria 1–12,
following the ten existing harnesses exactly (GPL header, the `swiftc … -o
/tmp/findtests && /tmp/findtests` line in the header comment, an assertion
counter, `ALL TESTS PASSED`), plus one advisory timing assertion in the style of
`MarkdownRendererTests`'s `measureRender`.

Revert: delete three files. **Pays off alone?** No — it is the test surface, and
now it genuinely is one: re-seating, wrapping, truncation and the clamp
invariant are all here rather than stranded in the coordinator.

### Tier 2 — model state + menu commands

- `WorkspaceModel`: the six published members of D3, plus
  `presentFindBar()` (`isFindBarVisible = true; findFocusTick += 1`) and
  `closeFindBar()`.
- `App/FEditApp.swift`: `EditCommands` with `CommandGroup(after: .textEditing)`
  → **Find** (Cmd+F) and **Find Next** (Cmd+G), both
  `.disabled(workspace?.openFile == nil)`.

Revert: drop `EditCommands` from `body` and the members from the model.
**Pays off alone?** No — nothing renders yet.

### Tier 3 — the SwiftUI find bar

`FEdit/Views/FindBar.swift`: an `HStack` of a `TextField` bound to
`workspace.findQuery`, a `Toggle("Case sensitive")` bound to
`workspace.findCaseSensitive`, a `Text(workspace.findCountLabel)`, and a Done
button. Placed in `ContentView.editorColumn` between the `ColumnHeaderBar` and
`CodeEditorView`, rendered only when `workspace.isFindBarVisible`.

Keyboard: `.onSubmit { workspace.findNextTick += 1 }` for Return; a Done button
carrying `.keyboardShortcut(.cancelAction)` for Esc; `@FocusState` in
`ContentView` driven by `.onChange(of: workspace.findFocusTick)`.

Revert: delete the file and the two call sites.

### Tier 4 — the editor side

`CodeEditorView` gains four inputs (`findQuery`, `findCaseSensitive`,
`findIsActive`, `findNextTick`), one output (`onFindCountChange: ((String) ->
Void)?`), and a coordinator that owns a `FindSession` plus:

- `refreshFind(_ textView:)` — `clamp(toLength:)` **first**, then recompute,
  then re-apply temporary attributes, then report the label out.
- `applyFindHighlights(_ textView:)` — remove `.backgroundColor` temporary
  attributes over the full range, then add them per match, current match in a
  distinct colour. Every range is intersected with the storage's full range
  before use.
- Ordering invariant, written into the code as a comment because finding 3 is
  entirely about it: **no find work ever runs before the text-mutating branches
  of `updateNSView` have finished.** Find is handled in a block *after* the
  file-switch branch, the external-reload branch and the font-zoom block, and
  `refreshFind` always clamps before it touches a range.
- `lastConsumedFindTick` seeded in `makeNSView` from the incoming
  `findNextTick`, exactly as `appliedFontSize` is seeded — so a rebuilt
  coordinator never replays the old editor's ticks (criterion 22, finding 10).
  This is the house one-shot convention (`hasConsumedCursorRestore`,
  `pendingNewWindowPicks`, the `CLIOpenToken` guard).
- Editor-text recompute is hooked inside `highlightNow`, i.e. on the existing
  debounce (D8).
- The font-zoom block re-scrolls to `currentRange` instead of the first-visible
  anchor when find is active (criterion 23, finding 20).
- A tiny `FindableTextView: NSTextView` overriding `cancelOperation(_:)` so Esc
  closes the bar when focus is in the **text**, not the field (criterion 18,
  finding 15).
- Closures capture `[weak coordinator]`, matching the existing
  `ruler.onThicknessChange` idiom; a `dismantleNSView` cancels pending work
  (finding 19).

Revert: delete the find block and the four inputs.

**This is the first tier at which the feature is usable.** Tiers 1–3 are a build
order, not a ship order — the reviewer was right that Rev 1 oversold "each tier
independently revertible" as if each were shippable.

### Tier 5 — docs

- SPEC: new **§6.5 Find**; Cmd+F / Cmd+G rows in the §10 table; §12 narrowed
  from "find/replace" to "**replace**" pointing at §6.5; **§13** gains
  `Editor/FindMatcher.swift`, `Editor/FindSession.swift`, `Views/FindBar.swift`
  and `scripts/FindMatchTests` in its alphabetical roster; **§14**'s "TODO.md is
  currently empty" line corrected (finding 14 — it is already false at HEAD).
- README: both shortcut rows, and the harness count updated from ten to eleven.

## Load-bearing assumptions

1. **`.keyboardShortcut(.cancelAction)` fires on Esc while a sibling SwiftUI
   `TextField` has focus.** *If false:* the Done button still works by click,
   and `FindableTextView.cancelOperation` still covers editor focus; the gap
   would be Esc-while-in-the-query-field, closed by an `NSViewRepresentable`
   key-monitor of ~15 lines. Contained to Tier 3.
2. **A `@FocusState` write moves focus out of the sidebar `TextField`.** Both
   fields are SwiftUI, so this is within one focus system. *If false:*
   criterion 13 needs an explicit `.defaultFocus` or a deferred write; Tier 3
   only.
3. **Shrinking the editor's height by the bar does not change the first
   *visible* line.** `NSScrollView` preserves the scroll origin, and
   `reportFirstVisibleLineIfChanged` reads `visibleCharRange.location` (the
   first, not the last, visible char) — so the reported line should not move.
   Criterion 24 is exactly this assumption's test. *If false:* the preview
   nudges once on open/close; the fix is to suppress one report, ~5 lines.
4. **`.literal` search keeps `range.length == query.length`.** Criterion 4. If a
   locale broke it, the highlight ranges would still be valid (they come from
   the search itself); only the criterion would be wrong.

## Out of scope, deliberately

- **Replace** — stays a SPEC §12 non-goal.
- **Regex and whole-word** — the item says literal only.
- **Find Previous / Cmd+Shift+G** (D6) and Cmd+E "use selection for find".
- **Persisting find state across relaunch** (D3).
- The `- [ ]` task-list and table gaps in the preview — other items.

## Decisions taken

*2026-08-21, folding in `adv-review-plan` Rev 1 findings. 22 findings: 20
accepted, 2 refuted by probe.*

- **Refuted finding 4 (temp `.backgroundColor` may not paint).** The reviewer
  was right that Rev 1 probed the wrong thing, and this was the single largest
  rewrite risk in the plan, so I probed it properly rather than reasoning about
  it: pixel-sampled render, 1851/2016 red inside the marked run, 0/2016
  outside. D2 stands and assumption 2 of Rev 1 is now probe 1, a fact.
  *Alternative:* redesign onto custom rect drawing in an `NSTextView` subclass.
  *Why not:* measurement says it is unnecessary.
- **Refuted finding 7 (SwiftUI may already claim Cmd+F).** Walked a bare
  SwiftUI app's `NSApp.mainMenu`: no Cmd+F, no Cmd+G. Also refuted its
  secondary claim — `CommandGroup(after: .textEditing)` lands the items in Edit
  directly after Select All, not loose at the bottom. D4 stands unchanged.
- **Accepted finding 1 (critical) — coordinator lifetime.** Verified myself at
  `ContentView.swift:115-138`. Find state moved from the coordinator to
  `WorkspaceModel` (D3). *Alternative:* hoist only the query. *Why not:* the
  tick counters and the count label have the same lifetime problem.
- **Accepted finding 2 (critical) — `Bool` cannot express "Cmd+F again", and
  Esc desyncs the model.** Resolved by D7 (a SwiftUI bar bound two-way to the
  model, so Esc writes back) plus a separate `findFocusTick` for the
  already-open case (criterion 17).
- **Accepted finding 3 (critical) — stale ranges / `NSRangeException`.**
  Resolved by making `clamp(toLength:)` a first-class, headlessly-tested
  operation (criteria 9, 11) and by writing the ordering invariant into Tier 4
  explicitly. *Alternative:* defensive `try`/bounds checks at each call site.
  *Why not:* it is a state-machine property, so it belongs in the state machine
  where it can be tested without a UI.
- **Accepted finding 5 — `indexOfMatch` contradicted criteria 8/12.** Resolved
  in favour of the caret-relative seat (now criterion 7) and **against** Rev 1's
  "always resets to the first match": seating at the caret is what Xcode does
  and it keeps the pure function meaningful instead of dead code. Criterion 14
  reworded to `1 of N` only for the caret-at-top case.
- **Accepted finding 6 — Tier 1 tested the least risky part.** Resolved by
  extracting `FindSession` so re-seating, wrapping, truncation and clamping are
  all pure and headless (criteria 7–12). This is the change that most improves
  the plan.
- **Accepted finding 8 — preview scroll-sync coupling was unmentioned.** Split
  deliberately: a *step* moving the preview to the match is **intended**
  behaviour; the bar *opening* moving it is **not**, and is now criterion 24
  with assumption 3 behind it.
- **Accepted finding 9 — assumption 1's fallback was mis-sized.** Made moot by
  D7: there is no AppKit bar to host, so the `NSScrollView` return type never
  changes. (Probe 7 recorded the parameter is unused anyway, which is what
  made Rev 1's error easy to miss.)
- **Accepted finding 10 — tick replay across a coordinator rebuild.** Seeded
  `lastConsumedFindTick` in `makeNSView`, matching `appliedFontSize`; criterion
  22 tests it.
- **Accepted finding 11 — per-step selection writes.** Resolved by D9: step
  scrolls, close moves the caret once. *Alternative:* wrap each step in
  `isProgrammaticUpdate`. *Why not:* that silently stops persisting the caret,
  trading a visible cost for an invisible one.
- **Accepted finding 12 — Tier2↔Tier3 cycle.** Made moot by D7: the count flows
  editor → `workspace.findCountLabel` → bar, one direction only.
- **Accepted finding 13 — Tier 3 had no visibility gate.** The bar now renders
  under `if workspace.isFindBarVisible`, and Tier 2 (which defines it) precedes
  Tier 3. Revert claims for Tiers 2 and 4 corrected.
- **Accepted finding 14 — SPEC §13/§14 omitted.** Added to Tier 5, including
  the already-false "TODO.md is currently empty" line.
- **Accepted finding 15 — Esc only worked with the field focused.** Added
  `FindableTextView.cancelOperation(_:)`; criterion 18 now names both focus
  states.
- **Accepted finding 16 — unbounded per-keystroke scan.** Resolved by D8
  (ride the existing 150 ms debounce; hard cap at 20,000 with a visible `+`).
- **Accepted finding 17 — focus handoff mechanism unstated.** Made moot by D7:
  both fields are SwiftUI, so `@FocusState` handles it inside one focus system
  instead of calling `makeFirstResponder` across the boundary.
- **Accepted finding 18 — criterion 14 was a tautology.** Demoted to a
  structural invariant with the reason stated.
- **Accepted findings 19–22** — weak captures + `dismantleNSView`; font-zoom
  re-scroll (criterion 23); the "composited over" wording corrected in D2; and
  `SyntaxHighlighter.swift`'s deliberate non-modification recorded as an
  invariant.
- **Tension 1 (no Find Previous) held**, and probe 2 removes its stated cost:
  Cmd+Shift+G is unclaimed, so pressing it does nothing rather than invoking a
  system behaviour.
- **Tension 3 held and the prose fixed**: tiers are a build order, not a ship
  order, and Tier 4 is the first usable point. Rev 1's "each tier independently
  revertible" oversold that.
