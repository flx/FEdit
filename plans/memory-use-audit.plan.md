# memory-use-audit

**Risk tier (per tier):**
- **Tier 0 (static analysis) & Tier 1 (diagnosis):** standard — read-only; temporary, revertible instrumentation only, no shipped behavior change.
- **Tier 2 (snapshotJSON churn dedupe):** standard — a pure allocation-churn optimization with byte-for-byte identical persistence semantics; blast radius confined to `WorkspaceModel.snapshotJSON` and one `ContentView` `.onChange`.
- **Tier 3 (leak fix — CONDITIONAL, only if Tier 1 disproves the static verdict):** hi — touches `WindowCloseGuard`'s `NSWindowDelegate` proxy / retain lifecycle, which is concurrency- and lifetime-subtle; do not open unless runtime evidence contradicts the Tier 0 finding.

This is an **investigation-first** item: "no code change without a confirmed cause." Tier 0 is the static-analysis pass (done during planning, reported below) — **its "no leak / no retain cycle" verdict is itself a deliverable of this run: the investigation report.** Tier 1 is diagnosis (**human-run at Instruments — not executed or committed in this autonomous pass**). Tier 2 ships the one change the static pass already confirms (the churn) — **it is the only committed code change this run**. Tier 3 exists only as a gated contingency (**not opened this pass — static analysis found no confirmed runtime cause**). See `## Auto-resolved (plan review)` for the full scope decision.

## Goal

Determine whether FEdit's 80–190 MB steady-state footprint (with only tiny files open) hides a genuine leak or unnecessary allocation churn, and land **genuine reductions only** — no lazy-offload-then-reload tradeoffs (the markdown preview and highlighter stay resident). The expected deliverable is: confirm there is **no per-window / TextKit-buffer leak**, trim the `snapshotJSON()` per-body-eval churn (the one statically-confirmed safe win), and communicate that the bulk of the baseline is irreducible SwiftUI/AppKit/TextKit/CoreAnimation framework memory.

**Framing (Auto-resolved D2):** the Tier 2 trim is a CPU/allocation-*rate* cleanup — it removes a full `JSONEncoder` run on every `ContentView` body pass. It is **not** a proven reduction of the 80–190 MB steady-state RSS and may not move that number at all. Confirming the baseline is mostly irreducible framework memory requires the human Instruments session (Tier 1), which is **not** run in this autonomous pass.

## Acceptance criteria

Diagnosis (Tier 1) — evidence, not behavior:

1. Temporary `deinit` logging added to `WorkspaceModel`, `CodeEditorView.Coordinator`, `MarkdownPreviewView.Coordinator`, and `LineNumberRulerView`. (`WindowCloseGuardProxy` is deliberately **excluded** — Auto-resolved D3: its `retainedProxies` map is a weak-key→strong-value `NSMapTable` that does not promptly release the proxy value when the weak window key deallocs, so a missing proxy `deinit` is not a reliable leak signal.) Opening N windows (each with a **`.md` file opened** — see the note in Tier 1 on why an empty window doesn't exercise the stacks), then closing all N and **letting the run loop settle** before counting (Auto-resolved T3: the deinit-timing is not a crisp same-frame pass/fail — add a settle step / forced compaction, and treat a single lingering scene as expected SwiftUI caching, not a partial leak), prints **one matching `deinit` line per instance per class**. **Coupled signal (Auto-resolved D1):** read `WorkspaceModel.deinit` and `CodeEditor.Coordinator.deinit` **together** — the editor coordinator holds the model strongly (see Suspect 1), so a pinned coordinator pins the model + both TextKit stacks. If every close eventually yields its full set of deinits and the process's persistent footprint returns to a flat baseline across repeated open/close cycles → **no leak** (the expected outcome).
2. Instruments **Allocations** "persistent bytes" between two mark generations (after warm-up open/close, then after another N open/close cycles) is **flat** (no monotonic growth per cycle). Instruments **Leaks** reports **no leaked `WorkspaceModel` / `NSTextStorage` / `NSTextView` / `WindowCloseGuardProxy` nodes**.
3. If, and only if, criterion 1 or 2 fails (a class's `deinit` never fires, or persistent bytes climb per cycle), the offending retain is identified from the Allocations "reference count / retain-release" history or a Leaks cycle graph, and Tier 3 is opened against that specific finding.

Churn fix (Tier 2) — behavior-preserving:

4. After the dedupe, `WorkspaceModel.snapshotJSON()`'s `JSONEncoder` no longer runs on every `ContentView` body evaluation. Verified by a temporary counter/log in `snapshotJSON()`: during a burst of pure scrolling and a divider drag (which re-evaluate `body` but do **not** change any of the four snapshot fields), the encode count stays **0**; it increments only when roots / open-file / filter / cursor actually change.
5. **Session restore is byte-identical to before:** open folders, open file, filter text, and cursor position all persist across relaunch and across Cmd+N new windows exactly as they did pre-change (the (session-restore) acceptance criteria still pass). The "last edit before quit is not lost" guarantee (the reason `onChange` tracks post-change values, not `objectWillChange`) is preserved.
5a. **Equivalence regression test passes (Auto-resolved T2):** the extended `scripts/SnapshotTests/main.swift` asserts `currentSnapshot` Equatable equality ⟺ `snapshotJSON()` byte-identical string equality across representative values, so a future non-deterministically-encoded field cannot silently start dropping saves. Part of the Tier 2 ship.

## Static-analysis findings (Tier 0 — done during planning)

Verdicts from reading the current source. **This is the highest-value section: it lets the orchestrator ship the Tier 2 churn fix without a full Instruments session, and sets the expectation that suspects 1, 2, 4 are already-mitigated / not-the-cause.**

### Suspect 1 — per-window leak (WorkspaceModel + both TextKit stacks + ruler): ALREADY-MITIGATED in FEdit code; residual risk is SwiftUI scene caching → NEEDS-RUNTIME-CONFIRMATION

Ownership, traced from the code:

- `WorkspaceModel` is owned solely by `@StateObject private var workspace = WorkspaceModel()` (`ContentView.swift:55`) — the only construction site (grep-confirmed). SwiftUI owns the `@StateObject` box for the scene's lifetime. The `WindowCloseGuard` references are weak — `WindowCloseGuard.model` (`WindowCloseGuard.swift:37`) and `WindowCloseGuardProxy.model` (`:109`) are both `weak var` — and `.focusedSceneObject(workspace)` / `@FocusedObject` introduce no strong window→model owner beyond the scene.
- **Correction (Auto-resolved D1): the model is NOT referenced only weakly.** The editor representable holds it **strongly**. `CodeEditorView` receives `text: $workspace.editorText` (`ContentView.swift:205–206`) — a `Binding` that captures `workspace` — plus callback closures capturing `workspace`; and `Coordinator.parent: CodeEditorView` is a **strong** stored property (`CodeEditorView.swift:303`) refreshed at the top of every `updateNSView` (`:165`). Chain: `Coordinator` —strong→ `CodeEditorView` —strong(binding/closure)→ `WorkspaceModel`. There is **no cycle** (the model holds no back-reference to the coordinator), so the **no-leak verdict survives** — but the model's release is **coupled to the editor `Coordinator`'s release**, not independently guaranteed by weakness. Consequence for Tier 1: treat `WorkspaceModel.deinit` and `CodeEditor.Coordinator.deinit` as a **single coupled signal** — a pinned editor coordinator pins the model and both TextKit stacks.
- **Editor TextKit 1 stack:** `CodeEditorView.Coordinator` holds `let textStorage` **strong** (`CodeEditorView.swift:307`); `textView`/`rulerView` are **weak** (`:309–310`). Strong refs run downward only (storage → layoutManager → container), exactly as the makeNSView comment documents (`:71–83`); the `NSScrollView` (returned from `makeNSView`, owned by the view hierarchy) strongly owns its `documentView` (the `NSTextView`) and `verticalRulerView` (the ruler). The coordinator is owned by SwiftUI's representable context for the view's lifetime. `Coordinator.deinit` (`:345–349`) cancels `firstVisibleLineWorkItem` + `pendingHighlight` and removes its NotificationCenter observer. No strong cycle.
- **Markdown TextKit 1 stack:** `MarkdownPreviewView.Coordinator` holds `let textStorage` **strong** (`:109`), `textView` **weak** (`:111`); `pendingRenderWorkItem` and the `renderQueue.async` bodies capture **`[weak self]`** (`:198, :216`); `deinit` (`:153`) and `dismantleNSView` (`:99`) both cancel the pending render. No strong cycle.
- **Ruler:** `LineNumberRulerView` holds `textView` **weak** (`:28`), `onThicknessChange` captures **`[weak coordinator]`** (set at `CodeEditorView.swift:137`), and `deinit` removes its observers (`LineNumberRulerView.swift:89–91`). Owned by the scroll view. No cycle.

Conclusion: **FEdit's own code contains no retain cycle that would pin a closed window's model or TextKit stacks.** The one thing static reading *cannot* settle is whether SwiftUI actually tears the scene down on window close, or **caches/reuses the `WindowGroup` scene** (a known SwiftUI trait on macOS) — in which case the `@StateObject` and everything under it stay resident by framework design, *not* by an FEdit bug. That distinction is the entire point of Tier 1's `deinit` logging. If deinits fire → truly no leak. If they don't and the cause is scene caching → it is irreducible framework behavior, out of scope (see Out of scope), **not** fixable without the rejected offload tradeoffs.

### Suspect 2 — retain cycles around the WindowCloseGuard proxy and the debounce closures: ALREADY-MITIGATED

- `retainedProxies` is `NSMapTable<NSWindow, WindowCloseGuardProxy>.weakToStrongObjects()` (`WindowCloseGuard.swift:77`): **weak key = the window**, strong value = the proxy. The proxy's back-references are **both weak** — `wrapped` (SwiftUI's delegate, `:108`) and `model` (`:109`). So: map ⇒(strong)⇒ proxy ⇒(weak)⇒ {window, model}. The proxy cannot keep the window or the model alive; **there is no cycle**, and the deliberately-weak `wrapped` (documented at `:100–106`) is what prevents the classic "SwiftUI's window controller keeps every closed window alive forever" leak.
- **Does `windowWillClose` actually run the uninstall?** Trace: on a normal close the proxy is the window's delegate, so AppKit calls `windowWillClose(_:)` (`:128`) — it forwards to `wrapped` first, then sets `window.delegate = wrapped` and calls `uninstallProxy(for:)` (`:73–75`), dropping the map's strong ref. `responds(to:)` (`:135`) advertises `windowWillClose` via `super` (the proxy implements it), so AppKit will dispatch it. **Verdict: the uninstall path is correct.** Even in the degenerate case where SwiftUI reasserts its own delegate and `updateNSView` doesn't re-wrap before close (so `windowWillClose` never reaches the proxy), the map key is the window held **weakly**, so the entry self-clears when the window deallocs and the lingering proxy holds only weak refs — no substantive leak either way.
- **Debounce / background closures:** every escaping closure that could capture the stack captures weakly — `CodeEditorView.scheduleHighlight` `[weak self, weak textView]` (`:364`), `clipViewBoundsDidChange` `[weak self]` (`:454`), `scrollCharToTop` `[weak self, weak textView]` (`:418`), the async gutter reports `[weak coordinator]` (`:137, :141`); `MarkdownPreviewView` `[weak self]` throughout (`:198, :216`). Grep-confirmed: no escaping closure captures a strong `self` / `textView` / `model`. **No cycle.**

Runtime confirmation via Instruments **Leaks** is still worth doing, but note (Auto-resolved D3): a `WindowCloseGuardProxy.deinit` is an **unreliable** signal — the weak-key→strong-value `retainedProxies` `NSMapTable` does not promptly release the strong proxy value when the weak window key deallocs (it clears on later access/compaction), so the proxy can fail to deinit on close even with **no** leak (it holds only weak refs). It is therefore **excluded** from the Tier 1 deinit set; rely on `WorkspaceModel` / `NSTextStorage` deinits and the Leaks cycle graph instead (or, if the proxy is ever inspected, force `retainedProxies` compaction — touch `.count` — before reading). Static verdict: **not the bug.**

### Suspect 3 — snapshotJSON churn on every body eval: REAL, statically confirmed. This is the safe win.

`ContentView.swift:184`:
```swift
.onChange(of: workspace.snapshotJSON()) { _, newValue in
    guard didRestore, let newValue else { return }
    workspaceSnapshot = newValue
}
```
`onChange(of:)`'s `value` expression is recomputed on **every** `body` evaluation (SwiftUI needs the current value to diff against the stored previous one). So `snapshotJSON()` — which allocates a `WorkspaceSnapshot`, spins up a fresh `JSONEncoder`, encodes, and does `String(data:encoding:)` (`WorkspaceModel.swift:378–390`) — runs on **every** body pass. `ContentView.body` re-evaluates on: every keystroke (`openFile` republished via the `editorText` setter, `WorkspaceModel.swift:108–116`), every caret move (`cursorLocation` `@Published`, via `noteCursorMoved`), every throttled first-visible-line tick (`editorFirstVisibleLine` `@State`, `:48`), every gutter-width change (`editorGutterWidth` `@State`, `:52`), and every divider-drag frame (`sidebarWidth`/`editorFraction` `@AppStorage`). A full `JSONEncoder` instantiation + encode + string materialization on each of those is **genuine, avoidable transient churn** — a contributor to the transient 80↔190 MB *swing* (the allocation *rate*, **not** the steady-state floor: removing it lowers churn and may not move the resting RSS at all — see the Goal framing and Auto-resolved D2). **Verdict: real; fix in Tier 2.** (The per-keystroke whole-document re-highlight and the off-main markdown re-render also allocate transient attribute runs, but those are SPEC-mandated designs — §6.3 explicitly trades incrementality for simplicity — and reducing them is the rejected-tradeoff territory; see Out of scope.)

### Suspect 4 — FileNode tree size: REAL but NOT the cause of the reported symptom

`WorkspaceModel.roots: [FileNode]` (`:59`) holds the full recursive tree, one value-type `FileNode` per file/dir (`FileNode.swift:27–36`, each carrying a `URL`, `String` name, `Bool`, and a `children` array). For a folder with thousands of entries this is a few MB, but the reported symptom is **"only tiny files open,"** i.e. a small or empty tree — so this cannot explain an 80–190 MB baseline. The skip-list (`node_modules`/`.build`/`DerivedData`, `:41`) already bounds the worst case. **Verdict: real allocation, not the baseline driver; no fix warranted for this symptom.** (If a future symptom is "huge folder blows up memory," that's a separate item — lazy/paged tree scanning — and is out of scope here.)

## Tiers

### Tier 1 — Diagnosis: temporary instrumentation + measurement protocol (DIAGNOSIS-ONLY — HUMAN-RUN AT INSTRUMENTS, NOT SHIPPED THIS PASS)

**Run-scope (User decision):** this tier is **not executed or committed** in the autonomous run. It requires a human at Instruments to exercise (open/close-N windows, read Allocations persistent bytes, inspect Leaks graphs). It is retained here as the diagnosis protocol for that human session; the autonomous deliverable is the Tier 0 report plus the Tier 2 ship.

*Files (temporary edits, all reverted at the end of the tier):* `FEdit/Models/WorkspaceModel.swift`, `FEdit/Editor/CodeEditorView.swift`, `FEdit/Preview/MarkdownPreviewView.swift`, `FEdit/Editor/LineNumberRulerView.swift`, `FEdit/App/WindowCloseGuard.swift`.

**1a. Add `deinit` logging** (temporary; must be reverted before shipping — diagnostic only):
- `WorkspaceModel` — add a `deinit { print("DEINIT WorkspaceModel") }` (the class currently has none).
- `CodeEditorView.Coordinator.deinit` — add `print("DEINIT CodeEditor.Coordinator")` inside the existing deinit.
- `MarkdownPreviewView.Coordinator.deinit` — add `print("DEINIT MarkdownPreview.Coordinator")`.
- `LineNumberRulerView.deinit` — add `print("DEINIT LineNumberRulerView")`.
- **`WindowCloseGuardProxy` — do NOT add a deinit to the leak set** (Auto-resolved D3): its `retainedProxies` map is weak-key→strong-value, so the proxy can fail to deinit on close even with no leak; a missing proxy `deinit` is not a reliable signal. If it is inspected at all, force `retainedProxies` compaction (touch `.count`) before reading.
Use `print` (stderr) — **not** `os_log` (Auto-resolved T4): the automation (1c) greps the process's **stderr**, whereas `os_log` writes to the unified log where the grep won't see it. Keep the marker string greppable.

**1b. Measurement procedure (the open/close-N protocol).** Critical detail from the static read: **an empty window does NOT mount either TextKit stack** — `CodeEditorView` is gated on `openFile != nil` (`ContentView.swift:204`) and `MarkdownPreviewView` on `isMarkdown` (`:98`). So to exercise *both* stacks + the ruler, **each window under test must have a `.md` file opened** before it is closed (a `.md` mounts editor + ruler + preview). Procedure:
  1. Launch the Debug build (see 1c for the exact command).
  2. In each of N windows (N ≥ 5): add a folder containing a small `.md` file, click the `.md` to open it (editor + ruler + preview all mount), optionally type a few characters.
  3. Close all N windows (Cmd+W each).
  4. **Let the run loop settle** (a brief pause / forced compaction — the deinits are not guaranteed same-frame, and SwiftUI may hold one scene), then watch the log: expect **N × {WorkspaceModel, CodeEditor.Coordinator, MarkdownPreview.Coordinator, LineNumberRulerView}** deinit lines (`WindowCloseGuardProxy` is excluded per Auto-resolved D3). Read `WorkspaceModel` and `CodeEditor.Coordinator` as one coupled signal (Auto-resolved D1).
  5. Repeat the whole open/close cycle 2–3× and confirm counts scale 1:1 and nothing is "stuck" (one lingering scene across cycles = expected framework caching, not a partial leak).

  *Interpretation:* all deinits fire on close → **no leak** (expected; matches Tier 0). A class whose deinit never fires → that class (and what it transitively retains) is pinned → open Tier 3 against it. If **only** the SwiftUI-owned objects fail to deinit uniformly (i.e. the whole scene is retained) → suspect SwiftUI `WindowGroup` scene caching = irreducible framework behavior (Out of scope), not an FEdit bug.

**1c. Command-line automation vs. what REQUIRES a human at Instruments.**

Automatable (no Instruments GUI):
```sh
# Build a Debug build with the deinit logging.
xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Debug \
  -derivedDataPath build build
# Launch and capture stderr (deinit prints) to a file.
build/Build/Products/Debug/FEdit.app/Contents/MacOS/FEdit 2>&1 | tee /tmp/fedit-deinit.log
# In another shell, after driving open/close:
grep -c 'DEINIT WorkspaceModel' /tmp/fedit-deinit.log   # expect == N
```
The **launch + log capture + grep** is automatable. **Driving the window open/close is NOT fully automatable**, because Cmd+N presents an `NSOpenPanel` folder picker (a real folder must be chosen) and opening a file requires clicking a sidebar row. A human (or a prepared AppleScript UI script with a fixed test folder) must perform step 1b.2–3. **Mark this as the human-required step.**

Instruments (GUI, **REQUIRES a human** — cannot be scripted headlessly here):
```sh
# Allocations: record while a human drives the open/close-N protocol, then read
# "persistent bytes" between mark generations in the Instruments UI.
xcrun xctrace record --template 'Allocations' \
  --launch build/Build/Products/Debug/FEdit.app --output /tmp/fedit-alloc.trace
# Leaks:
xcrun xctrace record --template 'Leaks' \
  --launch build/Build/Products/Debug/FEdit.app --output /tmp/fedit-leaks.trace
```
`xctrace record --launch` starts the app and the trace, but **a human must interact** (open/close windows) during recording, and then **open the `.trace` in Instruments** to read persistent-bytes-per-generation and inspect Leaks cycle graphs — those readouts are GUI-only. `xctrace export --input … --toc` / `--xpath` can dump some tabular data for spot checks, but the mark-generation persistent-bytes comparison and the leak graph are **human-at-Instruments** steps. **Explicitly flag both as human-required.**

*Buildable/revertible:* the whole tier is temporary instrumentation; reverting the `deinit` prints returns the codebase to its shipped state. The `deinit`s are diagnostic only and must not ship.

**Decision gate out of Tier 1:**
- All deinits fire + flat persistent bytes → **no leak**; do NOT open Tier 3. Ship Tier 2 as the deliverable.
- A specific FEdit-owned class fails to deinit / persistent bytes climb per cycle → open **Tier 3** against that exact finding.
- Whole-scene retention → **do NOT conclude "SwiftUI scene caching, out of scope" from deinit counts alone** (Auto-resolved T1). Deinit counts cannot distinguish an FEdit retain cycle from `WindowGroup` scene caching — both yield zero deinits. **Mandatory before exiting to "out of scope":** the Instruments **Leaks** cycle graph and/or the **Allocations** retain/backtrace must positively attribute the retain to SwiftUI framework machinery (not FEdit code). With that attribution → irreducible framework memory (Out of scope). Without it → open **Tier 3**. Ship Tier 2 regardless.

### Tier 2 — snapshotJSON churn dedupe (SHIPPED THIS PASS — the only committed code change; cause confirmed statically in Tier 0, independent of the Instruments session)

*Files:* `FEdit/Models/WorkspaceModel.swift` (modify), `FEdit/Views/ContentView.swift` (modify), `scripts/SnapshotTests/main.swift` (extend — regression test, see below).

Gate: Suspect 3 is **already confirmed by the static read** — this tier does not need the Instruments run. Per the User decision it is the deliverable code change of this run. **Reframing (Auto-resolved D2):** this is a CPU/allocation-*rate* cleanup, **not** an RSS fix — it may not move the 80–190 MB steady-state number; do not claim it addresses the footprint without measurement.

Concrete design (semantics byte-identical; only the *when* of the JSON encode changes):

1. In `WorkspaceModel`, add a cheap, `JSONEncoder`-free, `Equatable` accessor for the current restorable state, reusing the existing `Equatable` `WorkspaceSnapshot` (`WorkspaceSnapshot.swift:29`):
   ```swift
   /// The current restorable state as a plain value — no JSON encoding. Cheap to build and
   /// `Equatable`, so `ContentView`'s save `.onChange` can diff it on every body pass without
   /// running a `JSONEncoder`; only the (rarer) actual-change branch encodes, via `snapshotJSON()`.
   var currentSnapshot: WorkspaceSnapshot {
       WorkspaceSnapshot(
           rootPaths: roots.map { $0.url.path },
           openFilePath: openFile?.url.path,
           filterText: filterText,
           cursorLocation: cursorLocation
       )
   }
   ```
2. Refactor `snapshotJSON()` to encode `currentSnapshot` (single source of truth; behavior unchanged — still returns `nil` on encode failure so the caller keeps last-good):
   ```swift
   func snapshotJSON() -> String? {
       let encoder = JSONEncoder()
       encoder.outputFormatting = .sortedKeys
       guard let data = try? encoder.encode(currentSnapshot),
             let json = String(data: data, encoding: .utf8) else { return nil }
       return json
   }
   ```
3. In `ContentView`, change the save `.onChange` to diff the cheap value and encode only when it actually changed:
   ```swift
   .onChange(of: workspace.currentSnapshot) { _, _ in
       guard didRestore, let json = workspace.snapshotJSON() else { return }
       workspaceSnapshot = json
   }
   ```

Why this is safe and equivalent:
- `snapshotJSON()` is a deterministic (`.sortedKeys`) function of `currentSnapshot`, so "the JSON string changed" ⟺ "`currentSnapshot` changed." The set of writes to `workspaceSnapshot` is unchanged; only the wasted encodes on body passes that didn't touch the four fields are eliminated.
- The `didRestore` gate, the `nil`-on-encode-failure last-good behavior, and the deliberate use of post-change values (not `objectWillChange`, preserving "don't lose the last edit before quit") are all retained.
- Per-body cost drops from a full `JSONEncoder` + `Data` + `String` to building one `WorkspaceSnapshot` (`roots.map` over the small top-level roots array + a few field copies) and an `Equatable` compare. The dominant allocation — the encoder and its output — moves to only-on-actual-change.
- *(Optional, only if a cheaper key is ever wanted:* the `roots.map { $0.url.path }` still allocates a small array each body; roots is top-level-only (typically 1–3), so this is negligible and not worth a specialized identity key. Left as-is deliberately.)*

**Required regression test (Auto-resolved T2):** the whole equivalence rests on assumption #3 — `currentSnapshot` Equatable equality ⟺ `snapshotJSON()` string equality. It holds today (verified: `snapshotJSON` builds a `WorkspaceSnapshot` from exactly `rootPaths, openFilePath, filterText, cursorLocation`; its synthesized `Equatable` covers exactly those four; `.sortedKeys` over only `String`/`[String]`/`Int?` ⇒ Equatable-equal implies byte-identical JSON). **Extend `scripts/SnapshotTests/main.swift`** with a test asserting this: for representative snapshot values, `a == b` (Equatable) **iff** the two JSON encodings are byte-identical — so a future non-deterministically-encoded field can't silently start dropping saves (an `.onChange(of: currentSnapshot)` that fired *fewer* times than the string diff would miss a write). This test is part of the Tier 2 ship.

*Buildable/revertible:* independently buildable; reverting restores the `.onChange(of: workspace.snapshotJSON())` form (and drops the regression test). Acceptance criteria 4–5 verify the churn is gone and session restore is unchanged.

### Tier 3 — Leak fix (CONDITIONAL CODE CHANGE — NOT OPENED THIS PASS; no confirmed runtime cause)

**Run-scope (User decision):** Tier 3 is **not opened** in this run. Static analysis (Tier 0) confirms no runtime cause, and the item's rule is "no code change without a confirmed cause," so no fix is written. It remains here, gated, only for a future human Tier 1 session that produces contradicting runtime evidence.

*Files (only the one the finding implicates):* most plausibly `FEdit/App/WindowCloseGuard.swift`; possibly `FEdit/Editor/CodeEditorView.swift` or `FEdit/Preview/MarkdownPreviewView.swift`.

Do **not** open this tier unless Tier 1 shows a specific FEdit-owned class failing to `deinit` on window close **and** the Allocations/Leaks evidence attributes the retain to FEdit code (not to SwiftUI scene caching). The fix is written against the exact finding; the static analysis says the most likely (still statically-refuted) candidates are:
- **If `WindowCloseGuardProxy.deinit` never fires after close** (the `retainedProxies` entry outlives the window because `windowWillClose` didn't run the uninstall): fix by making the uninstall independent of the delegate chain — e.g. subscribe once to `NSWindow.willCloseNotification` for that specific window (weakly) and remove the map entry there, so a SwiftUI-reasserted delegate can't strand the proxy. (Static trace at `WindowCloseGuard.swift:128–133` says this already runs; only pursue if runtime contradicts it.)
- **If a `Coordinator` fails to deinit:** inspect whether a captured strong reference escaped (Tier 0 found none); fix the specific capture.

Because this touches the window delegate proxy / retain lifecycle, treat it as **hi risk**: any change must be re-verified with the same Tier 1 open/close-N `deinit` protocol, and must not regress the (open-save) close/quit criteria (16–17b in `open-save.plan.md`) or (session-restore)'s `@SceneStorage` (criterion 17b).

*Buildable/revertible:* independently buildable and revertible; if opened, it lands as its own change gated on its own re-run of the Tier 1 protocol.

## Interface between tiers

- **Tier 1 → all:** the open/close-N `deinit` protocol and its pass/fail readout are the gate that decides whether Tier 3 exists. Tier 1 leaves **no** shipped code (all instrumentation reverted).
- **Tier 2 → later:** `WorkspaceModel.currentSnapshot: WorkspaceSnapshot` becomes the single cheap identity for restorable state; `snapshotJSON()` is redefined to encode it. Any future persistence consumer diffs `currentSnapshot` and encodes via `snapshotJSON()`. The `scripts/SnapshotTests/main.swift` equivalence test (Auto-resolved T2) guards the `currentSnapshot`⟺`snapshotJSON()` contract for future fields. This is the only tier that ships code this pass.
- **Tier 3 → :** adds no new model/public API; a targeted lifecycle fix inside `WindowCloseGuard` (or a coordinator), re-verified by Tier 1's protocol.

## Load-bearing assumptions

1. **SwiftUI's `WindowGroup` may cache/reuse scenes** on macOS; if a closed window's `@StateObject` and TextKit stacks stay resident because of that (not an FEdit retain), it is **irreducible framework memory**, out of scope. If this assumption is wrong and SwiftUI *always* tears scenes down promptly, then any non-deinit found in Tier 1 is unambiguously an FEdit bug → Tier 3. Either way the Tier 1 protocol distinguishes the two.
2. `onChange(of:)` evaluates its `value` argument on **every** `body` pass (the basis for Suspect 3 being real). This is standard SwiftUI behavior; if it were ever changed to lazy/short-circuit evaluation, Tier 2's win would shrink — but the dedupe would still be correct and harmless.
3. `WorkspaceSnapshot`'s `Equatable`/`Codable` conformance and `.sortedKeys` encoding are deterministic, so `currentSnapshot` equality ⟺ `snapshotJSON()` string equality. **Verified true today** (Auto-resolved T2): the struct's four fields are exactly `rootPaths, openFilePath, filterText, cursorLocation` — all `String`/`[String]`/`Int?` — its synthesized `Equatable` covers exactly those, and `.sortedKeys` over those types makes Equatable-equal imply byte-identical JSON; the `currentSnapshot`-based `.onChange` therefore fires a **superset** of the current save triggers (never misses a write). (Confirmed: `WorkspaceSnapshot.swift:29`, `WorkspaceModel.swift:385–386`.) Tier 2 adds a regression test pinning this so a future field that is `Equatable` but non-deterministically encoded cannot silently break the equivalence.
4. Exercising both TextKit stacks + the ruler requires a **`.md` file open** in each test window (editor is gated on `openFile != nil` at `ContentView.swift:204`, preview on `isMarkdown` at `:98`). If Tier 1 is run against empty/placeholder windows, it will not test the stacks and can produce a false "no leak" reading — the protocol must open a `.md`.
5. No sandbox (SPEC §2): the Debug build launched directly from `Contents/MacOS/FEdit` and `xctrace record --launch` need no entitlement/security-scoped setup.

## Out of scope

- **The rejected lazy-offload-then-reload tradeoffs:** do NOT unload/reload the markdown preview or the highlighter on demand, and do NOT tear down and rebuild TextKit stacks to save resident bytes. The user explicitly rejects these.
- **Cutting irreducible framework memory:** SwiftUI, AppKit, TextKit, and CoreAnimation carry a fixed baseline (the SPEC §1 goal is "well under 100 MB with a few small files," acknowledging a framework floor; the 80–190 MB observation is largely that floor plus transient churn). **Expectation to communicate:** a large share of the 80–190 MB baseline is framework memory that cannot be cut without the rejected tradeoffs. The realistic deliverable is "confirm no window/buffer leak + trim the snapshotJSON churn," not a dramatic baseline drop.
- **Reducing the per-keystroke whole-document re-highlight / off-main markdown re-render** allocation churn: these are SPEC §6.3/§8.1 designs (incrementality traded for simplicity); reducing them means incremental parsing — a separate, larger item, not this one.
- **`FileNode` tree paging / lazy scan for huge folders:** a different symptom (large folder) with a different item; not this baseline-with-tiny-files investigation.
- **Any code change to Suspects 1, 2, or 4** unless Tier 1 produces runtime evidence contradicting the Tier 0 static verdict.

## Auto-resolved (plan review)

Findings from adversarial plan review, plus one scope decision, folded in above.

**Defects fixed**

1. *(D1, High)* Suspect 1's claim "every other reference to the model is weak" was **false**. The editor representable holds `WorkspaceModel` **strongly**: `CodeEditorView` receives `text: $workspace.editorText` (a `Binding` capturing `workspace`) plus callback closures capturing `workspace`, and `Coordinator.parent: CodeEditorView` (`CodeEditorView.swift:303`) is a strong stored property refreshed each `updateNSView` (`:165`). Chain: `Coordinator` —strong→ `CodeEditorView` —strong→ `WorkspaceModel`. There is still **no cycle** (the model holds no back-reference to the coordinator), so the no-leak verdict survives — but the model's release is **coupled to the editor `Coordinator`'s release**, not independently guaranteed by weakness. Tier 1 now treats `WorkspaceModel.deinit` and `CodeEditor.Coordinator.deinit` as a **single coupled signal** (a pinned editor coordinator pins the model + both TextKit stacks). (Suspect 1; acceptance criterion 1; Tier 1 steps 1a/1b.)
2. *(D2, High)* Tier 2 reframed as a **churn/CPU-rate** cleanup, **not** an RSS fix: it removes a full `JSONEncoder` run on every `ContentView` body pass but is not claimed to reduce the 80–190 MB steady-state footprint without measurement. (Folded via the User decision below; Goal framing, Suspect 3, Tier 2 header.)
3. *(D3, Medium)* `WindowCloseGuardProxy.deinit` is an **unreliable** leak signal — `retainedProxies` is a weak-key→strong-value `NSMapTable`, which does not promptly release the strong proxy value when the weak window key deallocs (it clears only on later access/compaction), so the proxy can fail to deinit on close even with **no** leak (it holds only weak refs). Dropped `WindowCloseGuardProxy` from the Tier 1 deinit-logging leak set; rely on `WorkspaceModel` / `NSTextStorage` deinits and the Instruments Leaks graph instead (or force `retainedProxies` compaction — touch `.count` — before reading, if the proxy is ever inspected). (Acceptance criterion 1; Suspect 2; Tier 1 steps 1a/1b.)
4. *(Nit)* Corrected the `LineNumberRulerView` `weak var textView` citation to line **28** (was `:29`). (Suspect 1.)

**Tensions recorded**

5. *(T1, Medium)* Deinit counts alone cannot separate an FEdit retain cycle from SwiftUI `WindowGroup` scene caching (both → zero deinits). The Tier 1 decision gate now makes Instruments attribution (a Leaks cycle graph and/or an Allocations retain backtrace) **mandatory** before concluding "framework scene caching, out of scope" — it can no longer exit early to "out of scope" on deinit counts alone. (Tier 1 decision gate.)
6. *(T2, Low)* Tier 2's safety rests entirely on assumption #3 (`currentSnapshot` Equatable equality ⟺ `snapshotJSON()` string equality), **verified true today**: `snapshotJSON` builds a `WorkspaceSnapshot` from exactly `rootPaths, openFilePath, filterText, cursorLocation`; its synthesized `Equatable` covers exactly those four; `.sortedKeys` over only `String`/`[String]`/`Int?` ⇒ Equatable-equal implies byte-identical JSON, so the `currentSnapshot`-based `.onChange` fires a **superset** of the current save triggers (never misses a write). Tier 2 now **requires** a regression test (extend `scripts/SnapshotTests/main.swift`) asserting this equivalence, so a future non-deterministically-encoded field can't silently start dropping saves. (Tier 2 required-test note; acceptance criterion 5a; assumption 3.)
7. *(T3, Low)* Acceptance criterion 1's deinit-timing is not a crisp same-frame pass/fail (SwiftUI may cache one scene); it now adds a settle step / forced compaction before counting and treats a one-scene cache as expected, not a partial leak. (Acceptance criterion 1; Tier 1 step 1b.4–5.)
8. *(T4, Low)* The automation greps **stderr**, so the temporary logging must use `print` (stderr), **not** `os_log` (unified log, which the grep won't see). Tier 1's "print or os_log" wording is corrected to mandate `print`. (Tier 1 step 1a.)

**User decision — "Churn fix + report" (this autonomous run's scope)**

9. **Ship Tier 2 only.** The `snapshotJSON()` per-body-eval churn dedupe is verified semantics-preserving (T2) and lands as a real, committed code change — with the new regression-test requirement. It is the **only** committed code change this pass.
10. **Deliver the Tier 0 static-analysis "no leak / no retain cycle" finding as the investigation report.** The Tier 0 findings (above) are the report deliverable of this run.
11. **Tier 1 is human-run, not shipped this pass.** The temporary `deinit` logging is diagnosis-only and requires a human at Instruments to exercise (open/close-N windows, read Allocations persistent bytes, inspect Leaks graphs). It is not executed or committed in this autonomous run.
12. **Tier 3 is not opened (no confirmed runtime cause).** Static analysis confirms no runtime cause; the item's rule is "no code change without a confirmed cause," so Tier 3 stays closed.
13. **RSS framing.** Tier 2 is a CPU/allocation-*rate* cleanup (it removes a full `JSONEncoder` run on every `ContentView` body pass), **not** a proven reduction of the 80–190 MB steady-state RSS — it may not move the RSS number at all. Confirming that the baseline is mostly irreducible framework memory requires the human Instruments session (Tier 1).
