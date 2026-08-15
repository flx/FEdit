# git-editor-wait — `fedit --wait` so fedit can be git's editor

**Revision 2** — re-cut after adv-review-plan's DO NOT BUILD AS SCOPED verdict on
Rev 1. The protocol now carries a creator identity, acknowledges the claim on
disk, and fails bounded on every app-side drop path. See `## Decisions taken`.

**Risk tier: standard.** Cross-process (shim ↔ app) protocol plus a
window-lifecycle hook; every piece small and additive. Rev 2 removed all edits to
`CLIOpenToken`, `LaunchCoordinator`, and the `OpenRequest` struct — the app-side
blast radius is one new Foundation-only helper, one model property, one line in
the token apply, one delegate hook, and one terminate sweep.

## Goal

`fedit --wait <file>` (also `-w`) opens the file in its own FEdit window exactly
like `fedit <file>` does today, then **blocks until that window closes** (or FEdit
quits), then exits 0 — so `git config core.editor "fedit --wait"`, `GIT_EDITOR`,
and `crontab -e` work. Every failure mode is **bounded**: the shim never hangs
unrecoverably on a signal-less open.

## The mechanism: an acknowledged wait-marker spool

The shim cannot pass side-channel arguments through `open -a` to a running app
(odoc carries only paths), and `open -W` waits for whole-app quit. The signal
travels through the filesystem:

- **Spool dir** (protocol constant): `~/Library/Application Support/FEdit/wait/`.
  App is unsandboxed (xcode-scaffold), so both sides see the same path. Shim-side
  test override: `FEDIT_WAIT_DIR`.
- **Marker**: file named by `uuidgen`; content is the shim's PID, a newline, then
  the file's `realpath` output **verbatim** (no trailing newline — paths may
  contain newlines; everything after the first newline is the path). Written to a
  `.tmp` name and `mv`'d into place so the app can never read a half-written
  marker.
- **Claim (the ack)**: when the cli-open window **applies its token**
  (`ContentView.applyCLITokenIfNeeded`, async block — window on screen, model
  alive), it scans the spool for a matching unclaimed marker and claims it by
  **atomic rename** to `<name>.claimed`. The rename is the claim, the ack, and
  the exclusion — no in-memory claimed set, safe against two same-file waits
  (second rename of the same source fails; try the next candidate).
- **GC**: any unclaimed marker whose creator PID is dead (`kill(pid, 0)` →
  `ESRCH`) is deleted during the scan, whatever path it names. Orphans from
  `kill -9`'d or SIGHUP'd shims live only until the next external open.
- **Release**: `WindowCloseGuardProxy.windowWillClose` deletes the window's
  `.claimed` file (via its model, **before** forwarding to SwiftUI's delegate, so
  the weak model is still alive); `applicationWillTerminate` sweeps — per-window
  release via the proxies, then best-effort unlink of every `.claimed` entry in
  the spool (single-instance app, so all `.claimed` files are this process's).
- **Shim wait, two phases** after `open` succeeds:
  - *Phase 1 (bounded)*: poll 0.2 s until `<uuid>` disappears; if still present
    after the ack timeout (default 30 s, `FEDIT_WAIT_ACK_TIMEOUT` test override)
    → remove own marker, diagnostic, **exit 1**. Every app-side drop path
    (request dropped, no opener, zero-window stale opener, token dropped) lands
    here instead of hanging.
  - *Phase 2 (unbounded)*: `<uuid>` gone and `<uuid>.claimed` exists → poll until
    `.claimed` disappears → **exit 0**. Liveness latch: once `pgrep -qx FEdit`
    has succeeded, the process disappearing while `.claimed` survives → remove
    it, diagnostic, exit 1 (app died without cleanup). `<uuid>` gone with no
    `.claimed` → exit 0 (released before we looked).

Matching detail (load-bearing): the app compares
`URL(fileURLWithPath: markerPath).standardizedFileURL.path == file.standardizedFileURL.path`
— **both** sides go through the identical standardization, so whatever
`standardizedFileURL` does to `/private` prefixes cancels out (the reviewer
measured `/private/tmp/x` → `/tmp/x`; symmetric application makes that harmless).
The shim realpaths before writing the marker AND before handing the path to
`open`, so both strings originate from the same canonical output.

## Tiers

Tier 1 and Tier 2 are one feature wearing two hats (reviewer T2): neither pays
off alone, they land in this item together, and a revert reverts both. The split
is a review boundary (shell vs Swift), not a landability claim.

### Tier 1 — shim: `--wait` mode (+ FeditShimTests)

`scripts/fedit`:
- `--wait` / `-w` accepted as the **first argument only** (same rule and reason
  as `-h`: after position 1, everything is a path).
- Wait mode requires **exactly one** path naming an existing **regular file**
  (not a directory): otherwise usage error, exit 64. Git/crontab always pass one
  pre-existing file.
- Spool resolution **inside wait mode only** (a HOME-less `launchd`/cron context
  must not regress plain `fedit`, which runs under `set -eu`):
  `WAIT_DIR=${FEDIT_WAIT_DIR:-${HOME:-}/Library/Application Support/FEdit/wait}`
  spelled defensively — if `FEDIT_WAIT_DIR` is unset and `HOME` is unset/empty,
  error out (exit 78, EX_CONFIG) rather than writing to `/Library/...`.
- Marker creation: `mkdir -p` spool; `uuidgen` name; `printf '%s\n%s' "$$" "$abs"`
  to `<uuid>.tmp`, then `mv` to `<uuid>`.
- `open -a` invoked **without `exec`**, status captured `set -e`-safely:
  `status=0; open -a "$APP" "$abs" || status=$?` — on nonzero, remove the marker
  and exit with that status (both the `$APP` branch and the LaunchServices
  fallback branch).
- Two-phase wait loop as specified above. Poll interval 0.2 s.
- Traps: `INT`, `TERM`, **`HUP`** each remove both marker forms and `exit`
  explicitly with 128+signo (a trap that only `rm`s would fall out of the loop
  and exit 0 — measured by the reviewer; and HUP is how a closed terminal
  abandons a wait).
- Usage text: the flag plus a one-line
  `git config --global core.editor "fedit --wait"` example; header comment's
  exit-code table gains the wait rows (64 usage, 66 bad path, 78 no HOME,
  1 timeout/app-death, 128+n signals).

FeditShimTests (stub `open`, `FEDIT_WAIT_DIR` → temp dir; new `run_shim_bg`
helper — background start, PID capture, bounded poll for exit, timeout kill —
the existing `run_shim` is strictly synchronous and cannot express these):
- `--wait` + 0 paths / 2 paths / directory → 64, usage on stderr, spool empty.
- Happy path: marker exists while shim waits; content is `PID\nrealpath`; stub
  `open` received the canonical path; harness renames marker → `.claimed`,
  then deletes it → shim exits 0 promptly (≤ ~1 s).
- Released-before-claim-seen: harness deletes `<uuid>` outright → exit 0.
- No claim within `FEDIT_WAIT_ACK_TIMEOUT=1` → exit 1, spool empty.
- Stub `open` exiting nonzero → shim exits with that status, spool empty.
- SIGINT / SIGTERM / SIGHUP while waiting → marker removed, exit > 128.
- `HOME` unset: plain `fedit file` still works; `--wait` without
  `FEDIT_WAIT_DIR` → 78.
- Default-spool spelling: fake `HOME`, no `FEDIT_WAIT_DIR` → marker lands in
  `$HOME/Library/Application Support/FEdit/wait` (the cross-check for the
  twice-spelled protocol constant — OpenRequestTests asserts the same literal
  from the app side).
- Existing non-wait cases unchanged (regression).

### Tier 2 — app: claim on token apply, release on window close (+ OpenRequestTests)

- **New `FEdit/App/WaitMarkers.swift`** (Foundation-only, standalone-compilable,
  same discipline as `OpenRequest.swift`): `enum WaitMarkers` with
  `static let spoolDirectory: URL` (real-home spelling) and
  `static func claimMarker(for file: URL, in dir: URL) -> URL?`:
  list `dir` (missing dir → nil; cap processing at 512 entries); skip names
  containing `.claimed` or `.tmp`; read each candidate capped at 4 KB; parse
  first line as PID, rest as path (unparsable → skip, don't delete — could be
  foreign junk); dead PID → delete (GC), continue; path match (standardize both
  sides) → atomic `moveItem` to `<name>.claimed` — success returns the claimed
  URL, failure (raced) continues; no match → nil. Pure function of its inputs →
  unit-testable in the OpenRequestTests harness.
- **`WorkspaceModel`**: `waitMarkerURL: URL?` + `releaseWaitMarker()` (delete
  file, nil the property; idempotent).
- **`ContentView.applyCLITokenIfNeeded`**: inside the existing async apply block,
  after `requestOpen`, when `token.file != nil`:
  `workspace.waitMarkerURL = WaitMarkers.claimMarker(for: file, in: WaitMarkers.spoolDirectory)`.
  Claiming here (not at token mint) is what makes the claim an *ack*: it fires
  only when a real window with a live model is showing the file, so every drop
  path upstream simply never acks and the shim's phase-1 timeout reports it.
  The existing three-layer token invariant already keeps restored windows out —
  a restored token is never applied, so no stale claim can happen. Tokens,
  `LaunchCoordinator`, and `OpenRequest` are untouched.
- **`WindowCloseGuardProxy.windowWillClose`**: wrap the body in
  `MainActor.assumeIsolated` (the method has none today — Rev 1 misdescribed it;
  the idiom exists only in `windowShouldClose`) and call
  `model?.releaseWaitMarker()` **before** `wrapped?.windowWillClose?(...)`, so
  the weak model is still alive when the release runs (SwiftUI's teardown runs
  in the forwarded call). Release-on-willClose only — a close cancelled in
  `windowShouldClose` (the save-failure escape hatch; note: with always-on
  autosave there is no routine "unsaved changes" dialog) never gets here, so a
  cancelled close keeps git waiting, which is correct.
- **`AppDelegate.applicationWillTerminate`** (new method): iterate
  `NSApp.windows`, release via each `WindowCloseGuardProxy`'s model; then
  best-effort unlink every `.claimed` entry in the spool (covers a window whose
  proxy never installed, and `.claimed` residue from a previous crashed app run
  — single app instance, so no foreign claims exist). Quit-while-editing reads
  as "done editing": shim exits 0, git proceeds with the autosaved content.

OpenRequestTests additions (harness compiles `OpenRequest.swift` +
`WaitMarkers.swift` + `main.swift`):
- Claim by content; standardization equivalence (`/private/tmp` spelling vs
  `/tmp` spelling matches).
- Dead-PID marker (write a marker with an impossible PID) → deleted and skipped,
  even when its path matches.
- Pre-claimed (`.claimed`) and `.tmp` entries never considered; a claimed marker
  is not claimable again (second call with a second same-path marker claims the
  *other* one).
- Unparsable marker skipped and **not** deleted.
- Missing dir → nil.
- `spoolDirectory` spelling: equals
  `NSHomeDirectory() + "/Library/Application Support/FEdit/wait"` (the app-side
  half of the constant cross-check).

### Tier 3 — docs

- README "Using FEdit as your git editor":
  `git config --global core.editor "fedit --wait"`; note that FEdit autosaves,
  so **the way to abort a commit is to delete the message text and close the
  window** (there is no close-without-saving).
- SPEC §3 external-opens paragraph: one sentence for `--wait` (single existing
  file; blocks until the window closes or the app quits; bounded error if the
  open produces no window).
- SPEC §13 file map: `App/WaitMarkers.swift` row + the harness list mention.

**Revert (all tiers):** revert the edits; no persisted format changes anywhere
(the spool is transient state, tokens unchanged).

## Interface between tiers

The protocol constants, cross-checked by the two harnesses' spelling assertions:
1. Spool dir: `~/Library/Application Support/FEdit/wait` (shim:
   `${FEDIT_WAIT_DIR:-${HOME:-}/Library/Application Support/FEdit/wait}`, wait
   mode only; app: `WaitMarkers.spoolDirectory`).
2. Marker content: `PID` + `\n` + canonical path, verbatim, no trailing newline.
3. Claim = rename to `<name>.claimed`; release = deletion of that file.

## Acceptance criteria (each testable)

1. FeditShimTests: all Tier 1 cases above green, counts quoted from a run I
   execute myself.
2. OpenRequestTests: all Tier 2 matcher cases green in the standalone harness.
3. `xcodebuild` Debug build green; **all** existing harnesses under `scripts/`
   green (no regression), counts quoted.
4. Manual, owed to the human GUI pass (needs the installed app):
   `git -c core.editor="<path>/fedit --wait" commit` in a scratch repo — window
   opens with COMMIT_EDITMSG; writing a message and closing completes the
   commit; clearing the buffer and closing aborts it (empty message; note
   autosave means "type nothing" and "delete everything" are the only abort
   gestures); quitting FEdit mid-edit completes the commit with the autosaved
   text; `fedit --wait` with FEdit already running and with FEdit not running.

## Load-bearing assumptions

- **odoc delivery to a running app** (`open -a` → `application(_:open:)`):
  proven by shipped cli-open. Breaks → whole feature; rewrite = URL-scheme
  protocol (medium).
- **The odoc URL's path equals the shim's realpath output after symmetric
  standardization.** cli-open's gates proved path pass-through; the symmetric
  `standardizedFileURL` comparison absorbs `/private` rewrites. Residual risk is
  an exotic `open` re-spelling; manual criterion 4 exercises the real pipeline
  end-to-end, and the failure direction is a bounded phase-1 exit 1, not a hang.
- **`windowWillClose` reaches the proxy for cli-open windows**: the proxy
  already relies on this selector to uninstall itself on every window. Breaks →
  marker released only at app quit; failure direction bounded (phase 2 +
  liveness), fix small.
- **No sandbox** (xcode-scaffold DONE entry). Sandboxing later moves the spool
  into the container and the shim must follow (protocol constant change).
- **`pgrep -x FEdit`** matches the app process (`PRODUCT_NAME = $(TARGET_NAME)`,
  reviewer-verified). Wrong → liveness net never arms; degrades to
  hang-on-app-crash only (phase 1 still bounds the common failures).

## Out of scope

- `--wait` on multiple files or a folder window (usage error; no invoking tool
  does it).
- Creating a nonexistent file (`code --wait newfile.txt` creates; fedit's
  shipped exit-66 contract is all-or-nothing on existing paths — recorded
  divergence: `EDITOR="fedit --wait"` fails for tools that expect the editor to
  create the file).
- Nonzero exit distinguishing "closed without editing" (git distinguishes by
  content, like `code --wait`).
- `sudo crontab -e` / `sudoedit`: HOME is `/var/root`, marker lands in root's
  spool, app never claims it → **bounded** phase-1 exit 1 after the ack timeout
  (Rev 1 would have hung forever). Recorded limitation, not supported.
- Sandbox support.
- A friendlier sidebar root for `.git/COMMIT_EDITMSG` (see Decisions).

## Decisions taken

2026-08-15 (planning, Rev 1):
- **Spool-dir marker protocol over a `fedit://` URL scheme.** A scheme needs an
  Info.plist surface (project generates its plist from build settings) and would
  let any local app's `fedit://` URL name an arbitrary path for FEdit to delete;
  the spool protocol only deletes files inside FEdit's own spool.
- **Poll at 0.2 s** (~5 `sleep` procs/s while editing; imperceptible latency).
- **`--wait` restricted to exactly one existing regular file.**
- **Marker deletion on app quit = "done editing"** (shim exit 0), matching what
  quitting any editor means to git.

2026-08-15 (Rev 2 re-cut, after adv-review-plan verdict DO NOT BUILD AS SCOPED —
each finding verified against source/measurements before folding):
- **[F1, critical — accepted] Markers carry the creator PID; dead-creator
  markers are GC'd during every scan.** Rev 1's "no GC, a few stray bytes"
  rationale was false: with content-only matching, one orphan (e.g. a SIGHUP'd
  shim from a closed terminal) permanently desyncs every later wait on the same
  fixed path (`.git/COMMIT_EDITMSG`) and can release the wrong shim mid-edit.
  Alternative (marker files with TTL) rejected: a TTL can sever a legitimately
  long wait; PID liveness cannot. Residual: PID reuse can keep one orphan alive
  and re-create the Rev 1 ambiguity for one round — vastly rarer than the
  unconditional version, accepted.
- **[F7, F2 — accepted] Claim moved from token mint to token apply, and made an
  on-disk ack (atomic rename to `.claimed`), with a bounded shim-side phase-1
  timeout.** Every traced drop path (vanished file, exhausted opener retries,
  zero-window stale opener, dropped token) now ends in a clean shim exit 1
  within the ack timeout instead of an unbounded hang. This also deleted the
  Rev 1 `CLIOpenToken`/`LaunchCoordinator` changes entirely (no Codable
  surface, no claimed set — the rename is the exclusion, F10 moot). Residual
  steal window (a plain open of the *same canonical path* landing between
  marker creation and the wait window's apply, a few seconds at worst on a cold
  launch) accepted: the stealing window's close still releases the shim, git
  still reads the file's real content; odoc offers no invocation identity to
  close it completely.
- **[F3, F4, F5 — accepted, reviewer-measured] `set -eu`-safe status capture
  (`|| status=$?`), traps that `exit 128+n` explicitly (a bare-`rm` trap falls
  out of the loop with exit 0), `HUP` added to the trap list, and spool
  resolution confined to wait mode with `${HOME:-}` + explicit EX_CONFIG error**
  (Rev 1's top-level `${FEDIT_WAIT_DIR:-$HOME/...}` would have aborted every
  plain `fedit` in HOME-less contexts under `set -u`).
- **[F6, F14 — accepted] Release before forwarding `windowWillClose`** so the
  weak model is alive; `MainActor.assumeIsolated` added to that method (Rev 1
  wrongly claimed the idiom existed there); the "cancelled close" rationale
  corrected — the only surviving cancel is the save-failure escape, and it
  correctly keeps git waiting.
- **[F8 — accepted] The twice-spelled spool constant is now cross-checked by
  both harnesses asserting the same literal** (shim: fake-HOME default-path
  test; app: `spoolDirectory` spelling test), the pattern install.sh already
  uses for its rewritten constant. `FEDIT_WAIT_DIR` stays (the harness needs
  it); a stray export now fails bounded (phase-1 exit 1), not as a silent hang.
- **[F9 — accepted] Criterion 4 and the README rewritten around always-on
  autosave**: there is no close-without-saving; abort = delete the text and
  close. Rev 1's "closing without saving aborts" was untestable as phrased.
- **[F12 — accepted] FeditShimTests gains `run_shim_bg`** (background + PID +
  bounded wait + timeout kill); the wait cases cannot be expressed with the
  synchronous `run_shim`.
- **[F11 — accepted as recorded residue] The flagship use opens a window rooted
  at `.git`.** Uniform SPEC §3 semantics ("containing folder becomes the root")
  kept: the scan is off-main, bounded by the 50k node budget, watcher damped,
  and the window is transient. Special-casing `.git` roots to the repo parent
  is a user-visible semantics fork — filed as a possible follow-up in the DONE
  entry rather than smuggled in here.
- **[F13 — accepted as bounded]** `sudo crontab -e` lands in root's spool →
  phase-1 exit 1, recorded out of scope.
- **[F15 — accepted]** SPEC §13 file map added to Tier 3.
- **[T1 — accepted] Scan caps** (512 entries, 4 KB reads) and GC keep the
  apply-time scan trivial; it runs per cli-open window apply, not per odoc, and
  in the same async block that already defers heavier work.
- **[T4 — partially rejected] No Tier 0 probes.** The two empirical questions
  Rev 1 left open are gone structurally: release-before-forward removes the
  weak-model timing question, and the symmetric-standardization compare plus
  bounded phase-1 failure make the path-spelling assumption non-catastrophic.
  Manual criterion 4 exercises both on the real pipeline.
