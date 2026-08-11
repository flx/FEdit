# (cli-open) `fedit file.md` command-line invocation — implementation plan

Revision 2 — 2026-08-11. Planned against the code in this worktree, not against the TODO text
(see "Where the item's description is stale" below).

**Revision 2 re-cut (post adversarial review): where the `## Revision 2` section at the end of
this file conflicts with anything above it, Revision 2 governs.** The headline change: D3's
"fill an existing empty window" is REMOVED — a CLI open always creates a new window through the
Cmd+O mailbox pattern, and the claim is applied one runloop turn after the new scene appears.
See `## Decisions taken` for every finding's disposition.

## Risk tier

**standard** — no new algorithms and the whole path is inert unless a file URL is actually
delivered to the app, but it adds a new external entry point (Apple Events) and touches the
shipped bundle's `Info.plist`; the two seams that genuinely carry risk (the generated-plist merge,
and claiming a scene while session-restore is still settling) are isolated into their own tier /
their own gate below.

## Where the item's description is stale (checked against source)

1. **"there is currently no app delegate" — false.** `AppDelegate: NSObject, NSApplicationDelegate`
   already exists at the bottom of `FEdit/App/WindowCloseGuard.swift` and is already adapted in
   `FEditApp` via `@NSApplicationDelegateAdaptor(AppDelegate.self)`. It implements
   `applicationShouldTerminate(_:)`. So the receive site is two thin methods added to an existing
   class — no new adaptor, no new `@main` plumbing.
2. **"route it through the existing new-window mailbox (`LaunchCoordinator.pendingNewWindowPicks`)"
   — not as-is.** `pendingNewWindowPicks` is a bare `Int` counter whose drain (in
   `ContentView.onAppear`) unconditionally presents `WorkspaceModel.presentNewWindowFolderPanel()`.
   It cannot carry a payload, and reusing it would make a CLI-opened window *also* pop an
   `NSOpenPanel`. This plan adds a **second, payload-carrying queue on the same coordinator**
   (`pendingFileOpens`), drained at the same site with the same pristine-scene rule, and makes the
   two mutually exclusive per scene.
3. **The Info.plist IS generated.** `project.pbxproj` sets `GENERATE_INFOPLIST_FILE = YES` in both
   target configs, with `INFOPLIST_KEY_NSPrincipalClass = NSApplication` and **no `INFOPLIST_FILE`**.
   `INFOPLIST_KEY_*` settings can only express scalars — `CFBundleDocumentTypes` is an array of
   dictionaries and cannot be expressed that way. Declaring document types therefore requires a real
   `.plist` file wired via `INFOPLIST_FILE` (Tier 2).
4. **`FEdit/` is a `PBXFileSystemSynchronizedRootGroup`.** New `.swift` files under `FEdit/` are
   picked up by the target with **no `project.pbxproj` edit**. Only Tier 2 (the `INFOPLIST_FILE`
   build setting) touches `project.pbxproj`. Files under `scripts/` are outside the target.
5. **`scripts/install.sh` does not exist yet** in this worktree. (installer-script) is above
   (cli-open) in TODO.md so it should land first; Tier 3 has an explicit contingency if it has not.

## Goal

`fedit <path>` in a terminal launches (or activates) FEdit and puts `<path>` on screen: a window
whose sidebar has the file's containing folder as its **sole** root, with the file open in the
editor (and, for `.md`/`.markdown`, the preview column visible via the existing `isMarkdown` flow).
The app half is generic — it handles *any* file URL LaunchServices hands the app — and the shim is
a thin, testable wrapper around `open -a`.

Non-goal restated up front: this must not disturb any window that already has content, and must not
change what happens on an ordinary (no-file) launch.

## Settled design decisions

**D1 — Receive via `application(_:open:)` on the existing `AppDelegate`, not `.onOpenURL`.**
`func application(_ application: NSApplication, open urls: [URL])` is the AppKit-level odoc sink:
app-scoped, window-independent, and it can fire *before* any scene exists (odoc is delivered
between `applicationWillFinishLaunching` and `applicationDidFinishLaunching` on a cold launch).
`.onOpenURL` is scene-scoped: it is delivered *into an existing window's* view hierarchy — on a
cold launch that is a **restored** window, exactly the window we must not disturb — and its
multi-scene delivery semantics are unspecified (it is observed firing in every scene carrying the
modifier). We need to choose the target window ourselves, so we take the app-level event.

**D2 — Buffer, then dispatch after launch settles.** `application(_:open:)` only *enqueues*.
Dispatch runs either (a) `launchSettleDelay` (0.25 s) after `applicationDidFinishLaunching`, or
(b) immediately, if the app was already running (settled). This makes the two possible orderings of
odoc vs. `didFinishLaunching` both correct, and — the load-bearing part — it means the routing runs
*after* SwiftUI has created and `onAppear`-ed its restored scenes, which is the same condition
under which the shipped Cmd+O flow is safe. (The startup auto-picker in (open-folder-new-window)
was descoped precisely because it fired *during* that window; see DONE.md.)

**D3 — A CLI open only ever lands in a window with nothing in it.** Target selection, in order:
1. a live **pristine** scene (`roots.isEmpty && openFile == nil && workspaceSnapshot.isEmpty`) that
   did not just drain a Cmd+O pick — it claims the request and is brought to the front;
2. otherwise a **new** window via `openWindow(id: "editor")`, whose fresh scene claims it on appear
   (the exact mechanism Cmd+O already uses).

Rule as the user sees it: *"a CLI open never touches a window that has content; it fills an empty
window if there is one, otherwise it makes one."* Case 1 is what stops a cold launch from leaving a
stray blank startup window next to the CLI window. Because the target is always pristine,
`requestOpen` can never hit the dirty-file guard, so **`WorkspaceModel` needs no changes at all**
and no new save/dirty semantics are introduced.

**D4 — No reuse of a window that already shows that folder or file.** Two `fedit` calls on the same
file give two windows. SPEC §11 already allows two windows on one file (last save wins). Matching
by folder would need a policy for what to do with that window's open file and dirty buffer; not
worth it for v1.

**D5 — A directory argument is valid**: root = that directory, no file opened (`fedit .` is the
obvious use). A path that is neither a regular file nor a directory, or that has vanished by the
time the app sees it, is **silently ignored** (mirrors SPEC §9's "a last-open file that no longer
exists is simply not opened"); the shim is the layer that reports bad paths to the user.

**D6 — Shim behavior:** no args → `open -a <FEdit.app>` (launch/activate, no document), exit 0 —
the `code`/`subl` convention, and FEdit has a real empty-window state (Cmd+O, sidebar empty-state
button), so it is not a dead end. `-h`/`--help` → usage on stdout, exit 0. A nonexistent path →
`fedit: no such file or directory: <path>` on stderr, **exit 66** (`EX_NOINPUT`), and `open` is
never invoked (validation is all-or-nothing across all arguments, so a typo in the 3rd of 3 paths
opens nothing). More than 8 paths → usage error, exit 64 (`EX_USAGE`) — `fedit *.md` in a large
folder would otherwise ask for one window per file.

**D7 — Cap in the app too.** The dispatcher truncates to `maxFileOpensPerDispatch = 8` per
dispatch and drops the rest silently. Defense in depth against anything else (Finder multi-select)
handing the app a hundred URLs; each window costs a recursive synchronous scan of its parent.

**D8 — Binary / oversized / device-node files:** unchanged. `requestOpen` → `loadText` throws
`binaryFile` / `tooLarge` / `notRegularFile` and shows the existing "Cannot Open File" alert; the
window still opens with the parent folder as root. No new guard.

**D9 — The parent folder is used as the root verbatim.** `fedit ~/notes.md` therefore recursively
scans `~`. This is the *same* hazard as choosing `~` in the Cmd+O panel today, SPEC §11 explicitly
accepts synchronous recursive scanning, and the skip list (`node_modules`, `.build`, `DerivedData`,
dotfiles) removes the worst offenders. Accepted for v1, with a measurement in the acceptance
criteria (A22) and a note in the README so the behavior is not a surprise.

## Acceptance criteria

Each is marked with how it is verified. There is no XCTest target (SPEC §13), so: **[UNIT]** =
standalone `swiftc` harness under `scripts/`; **[SHELL]** = scripted shell harness (no GUI);
**[CLI]** = scripted command + exit-code/`plutil` assertion; **[GUI]** = needs a human at the
screen — no way around it, these are window-lifecycle behaviors.

Setup for the GUI checks: `mkdir -p /tmp/fedit-cli/sub && printf '# Hi\n' > /tmp/fedit-cli/notes.md
&& printf 'x = 1\n' > /tmp/fedit-cli/a.py`.

1. **Cold launch with a file.** FEdit not running, no saved session. `fedit /tmp/fedit-cli/notes.md`
   → exactly **one** window; sidebar has exactly one root, `fedit-cli`; `notes.md` is open, its row
   highlighted, editor strip shows `notes.md`, preview column present. No second blank window. [GUI]
2. **Already running, window has content.** With window A showing some project and `a.py` open:
   `fedit /tmp/fedit-cli/notes.md` → a **new** window B as in (1); A is byte-identical in state
   (same roots, same open file, same caret, same dirty marker). [GUI]
3. **Already running, an empty window exists.** With window A (content) and window B (empty):
   `fedit /tmp/fedit-cli/notes.md` → **B** is filled and brought to the front; **no** third window;
   A untouched. [GUI]
4. **Directory argument.** `fedit /tmp/fedit-cli` → window with `fedit-cli` as sole root, editor
   shows "No file open", no editor header strip, no preview column. [GUI]
5. **Non-Markdown file.** `fedit /tmp/fedit-cli/a.py` → two-column window (no preview), Python
   highlighting present. [GUI]
6. **Ordinary launch is unchanged.** Launch from Finder/Dock with no document → identical to
   today: restored windows and nothing else, no extra window, no panel, no delay perceptible. [GUI]
7. **Session restore is not hijacked.** Save a two-window session (different roots, different open
   files), quit, then `fedit /tmp/fedit-cli/notes.md` from a cold start → **both** restored windows
   return with their own roots/files/cursors, **plus** the CLI window. Repeat 5× — zero occurrences
   of a restored window coming back showing `fedit-cli`. [GUI, repeated]
8. **The CLI window is an ordinary scene.** After (1), quit and relaunch normally → the CLI window
   is restored with root `fedit-cli` and `notes.md` open. [GUI]
9. **Binary file.** `fedit /bin/ls` → "Cannot Open File … appears to be binary" alert; behind it a
   window with `/bin` as root and "No file open". [GUI]
10. **Cmd+O is unaffected.** Cmd+O still opens a new window that presents the folder panel; with
    the panel up, a concurrent `fedit /tmp/fedit-cli/notes.md` does **not** fill the panel's window
    (it gets its own), and Cancel still leaves that window empty. [GUI]
11. **Same file twice.** `fedit /tmp/fedit-cli/notes.md` twice → two windows on the same file; edits
    in one are picked up by the other's external-change watcher (existing behavior). Documented, not
    a defect. [GUI]
12. **Nonexistent path.** `fedit /tmp/does-not-exist.md` → stderr `fedit: no such file or
    directory: /tmp/does-not-exist.md`, exit 66, `open` never invoked (asserted against the stub
    `open` in the shell harness), FEdit not launched. [SHELL]
13. **All-or-nothing validation.** `fedit /tmp/fedit-cli/notes.md /tmp/nope` → exit 66, `open` never
    invoked (so `notes.md` does **not** open either). [SHELL]
14. **No arguments.** `fedit` → invokes `open -a <app>` with **no** file operands, exit 0. [SHELL]
15. **Help.** `fedit --help` and `fedit -h` → usage on **stdout**, exit 0, `open` not invoked. [SHELL]
16. **Path handling.** From `/tmp/fedit-cli`: `fedit ./sub/../notes.md`, `fedit "a b.md"` (a file
    with a space), and `fedit notes.md a.py` each pass **absolute, existing** paths to `open`, in
    argument order, one operand per argument. [SHELL]
17. **Too many paths.** 9 paths → exit 64, usage on stderr, `open` not invoked. [SHELL]
18. **`OpenRequest` mapping.** `scripts/OpenRequestTests` asserts: regular file → `root` = parent,
    `file` = self (both `standardizedFileURL`, so they compare equal to `FileNode` URLs); directory
    → `root` = self, `file` = nil; directory with a trailing slash → same as without; nonexistent
    path → `nil`; non-`file:` URL → `nil`; a `..`-containing path → standardized. [UNIT]
19. **Bundle sanity after the plist change.** `plutil -p "$APP/Contents/Info.plist"` shows *both*
    the generated keys (`CFBundleExecutable`, `CFBundleIdentifier` = `com.felixmatschke.FEdit`,
    `CFBundleName`, `CFBundleShortVersionString`, `LSMinimumSystemVersion` = 26.0,
    `NSPrincipalClass` = `NSApplication`, `CFBundleIconName` = `AppIcon`) **and**
    `CFBundleDocumentTypes`. App launches and shows its icon in the Dock. [CLI + GUI for the icon]
20. **FEdit does not steal file associations.** After installing, double-clicking a `.md` in Finder
    still opens the previous default app; FEdit appears only under "Open With". [GUI]
21. **Installer wires the shim.** After `scripts/install.sh`, `command -v fedit` resolves (or the
    script printed an explicit PATH hint naming the directory it used), and the installed shim is
    mode 0755. [CLI]
22. **Home-directory scan measurement (not a pass/fail gate).** Time `fedit ~/<some file directly in
    home>` from command to window-ready. Record it in DONE.md. If it exceeds ~5 s, that is the
    signal that async scanning (out of scope here) needs its own TODO item. [GUI, timed]

## Tiers

### Tier 1 — App-side receive and route

Everything that turns "a file URL arrived" into "the right window shows it". Independent of how the
URL arrives (Apple Event, Finder, drag) and of the shim.

**New file `FEdit/App/OpenRequest.swift`** (Foundation only, deliberately dependency-free so the
`swiftc` harness can compile it alone):

```swift
/// One "show me this path" request, resolved against the filesystem at construction time.
struct OpenRequest: Equatable {
    let root: URL      // sidebar root: the file's parent, or the directory itself
    let file: URL?     // file to open, nil for a directory request

    /// nil when `url` is not a file URL, or names nothing that exists.
    init?(fileURL url: URL) { … }   // standardizedFileURL on both fields
}
```

**`FEdit/App/LaunchCoordinator.swift`** (gains AppKit; the existing `pendingNewWindowPicks` counter
and its doc comment stay exactly as they are):

```swift
extension Notification.Name {
    static let feditPendingFileOpens = Notification.Name("com.fedit.pendingFileOpens")
}

@MainActor final class LaunchCoordinator {
    // existing:
    var pendingNewWindowPicks = 0

    // new:
    private static let launchSettleDelay: TimeInterval = 0.25
    private static let maxFileOpensPerDispatch = 8
    private var pendingFileOpens: [OpenRequest] = []
    private var isSettled = false
    private var openNewWindow: (() -> Void)?
    private var openerRetriesLeft = 20

    func registerWindowOpener(_ opener: @escaping () -> Void)   // called from ContentView.onAppear
    func noteLaunchFinished()                                    // arms the settle timer, once
    func enqueueFileOpens(_ urls: [URL])                         // odoc sink; dispatches if settled
    func claimPendingFileOpen() -> OpenRequest?                  // FIFO pop; main-actor ⇒ atomic
    func bringWindowToFront(for model: WorkspaceModel)
    private func dispatchPendingFileOpens()
}
```

`dispatchPendingFileOpens()`: truncate to `maxFileOpensPerDispatch`; post
`.feditPendingFileOpens` (existing pristine scenes get first refusal); then, **one runloop turn
later** (`DispatchQueue.main.async`), call `openNewWindow?()` once per still-unclaimed request and
`NSApp.activate()`. If `openNewWindow` is still nil (no scene has ever appeared), retry on a 100 ms
timer, `openerRetriesLeft` times, then give up — the queue is preserved either way.

`bringWindowToFront(for:)` finds the window via `NSApp.windows.first { ($0.delegate as?
WindowCloseGuardProxy)?.model === model }` — the same identification `AppDelegate.
applicationShouldTerminate` already uses — deminiaturizes and `makeKeyAndOrderFront`. No match
(proxy not installed yet on a brand-new window) is a no-op; SwiftUI fronts new windows itself.

**`FEdit/App/WindowCloseGuard.swift`** — two thin forwarders on the existing `AppDelegate`:

```swift
func application(_ application: NSApplication, open urls: [URL]) {
    LaunchCoordinator.shared.enqueueFileOpens(urls)
}
func applicationDidFinishLaunching(_ notification: Notification) {
    LaunchCoordinator.shared.noteLaunchFinished()
}
```
(Both run on the main thread; `MainActor.assumeIsolated`, the idiom already used in this file.)

**`FEdit/Views/ContentView.swift`** — `@Environment(\.openWindow) private var openWindow`, a
`@State private var didDrainFolderPick = false`, and:

* in the existing `.onAppear`, after the restore and after the existing Cmd+O drain (which now sets
  `didDrainFolderPick = true`): `LaunchCoordinator.shared.registerWindowOpener { openWindow(id:
  "editor") }` and then `claimPendingFileOpenIfPristine()`;
* a new `.onReceive(NotificationCenter.default.publisher(for: .feditPendingFileOpens))` calling the
  same `claimPendingFileOpenIfPristine()`;

```swift
private func claimPendingFileOpenIfPristine() {
    guard !didDrainFolderPick,                 // a Cmd+O window owes the user a folder panel
          workspace.roots.isEmpty,
          workspace.openFile == nil,
          workspaceSnapshot.isEmpty,           // a restored scene whose snapshot has arrived is out
          let request = LaunchCoordinator.shared.claimPendingFileOpen() else { return }
    workspace.addFolders([request.root])
    if let file = request.file { workspace.requestOpen(file) }
    LaunchCoordinator.shared.bringWindowToFront(for: workspace)
}
```

`WorkspaceModel` is **not** modified: `addFolders` + `requestOpen` are used exactly as the sidebar
uses them, and the pristine precondition means `requestOpen`'s dirty guard is a no-op.

**New harness `scripts/OpenRequestTests/main.swift`** — the project's existing pattern (top-level
`check(...)`, run via
`swiftc FEdit/App/OpenRequest.swift scripts/OpenRequestTests/main.swift -o /tmp/openreqtests &&
/tmp/openreqtests`), covering A18 against a temp directory it creates and removes.

*Verification / gate:* build, launch the built app, then
`open -a "<DerivedData>/Build/Products/Debug/FEdit.app" /tmp/fedit-cli/notes.md; echo $?`.
Two outcomes, both actionable:
* the window appears as in A1 → LaunchServices delivers odoc without a document-type declaration;
  **Tier 2 is not needed** — record that in the plan's Decisions section and in DONE.md;
* `open` errors, or exits 0 but nothing happens (temporarily instrument `application(_:open:)` with
  an `NSLog` to tell the two apart, and remove it before commit) → **build Tier 2 and re-run.**

*Revert:* delete `OpenRequest.swift` + `OpenRequestTests`, revert the three edited files. Nothing
else references them. Ordinary launches are unaffected either way (an empty queue makes the whole
path a 0.25 s timer that does nothing).

*Pays off alone:* **only if the gate's first outcome holds.** If odoc needs the declaration, Tier 1
is dead code until Tier 2 lands. Assume it does not pay off alone when scheduling.

### Tier 2 — Document-type registration in the bundle (expected to be required)

**New file `FEdit-Info.plist` at the repo root** — deliberately *not* under `FEdit/`, so the
filesystem-synchronized group cannot also copy it into `Contents/Resources`. It contains **only**
the keys the generator cannot produce:

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>            <string>File or Folder</string>
    <key>CFBundleTypeRole</key>            <string>Editor</string>
    <key>LSHandlerRank</key>               <string>None</string>
    <key>LSItemContentTypes</key>
    <array><string>public.data</string><string>public.folder</string></array>
  </dict>
</array>
```

`LSHandlerRank = None` is what keeps FEdit out of default-handler ranking (A20) while still
allowing an explicit `open -a`.

**`FEdit.xcodeproj/project.pbxproj`** — add `INFOPLIST_FILE = "FEdit-Info.plist";` to **both**
target configs (`FED17000000000000000000E` Debug and `FED17000000000000000000F` Release), keeping
`GENERATE_INFOPLIST_FILE = YES` so the generated keys merge into it.

*Verification:* A19's `plutil -p` (this is what detects assumption L2 failing) + A20 + a re-run of
Tier 1's gate.

*Fallback if the merge does not happen* (i.e. `plutil -p` shows only `CFBundleDocumentTypes`):
set `GENERATE_INFOPLIST_FILE = NO` and write the full plist. It must then also carry
`CFBundleExecutable = $(EXECUTABLE_NAME)`, `CFBundleIdentifier = $(PRODUCT_BUNDLE_IDENTIFIER)`,
`CFBundleName = $(PRODUCT_NAME)`, `CFBundlePackageType = APPL`, `CFBundleShortVersionString =
$(MARKETING_VERSION)`, `CFBundleVersion = $(CURRENT_PROJECT_VERSION)`, `LSMinimumSystemVersion =
$(MACOSX_DEPLOYMENT_TARGET)`, `NSPrincipalClass = NSApplication`, `NSHighResolutionCapable = YES`,
and — the easy one to forget — **`CFBundleIconName = AppIcon`**, or the app icon shipped in
4405a14 silently disappears.

*Revert:* delete `FEdit-Info.plist`, remove the two build settings. The bundle returns to a fully
generated `Info.plist`.

*Pays off alone:* no. Without Tier 1 the event is delivered and dropped.

### Tier 3 — The `fedit` shim, its install, and the docs

**New file `scripts/fedit`** (`/bin/sh`, committed mode 0755):

```sh
#!/bin/sh
# fedit — open files or folders in FEdit from the command line.
set -eu
APP=${FEDIT_APP:-/Applications/FEdit.app}
MAX_PATHS=8
```
* `-h`/`--help` (first argument only) → usage on stdout, exit 0.
* zero arguments → `open -a "$APP"` (no operands), exit with `open`'s status.
* `$# > MAX_PATHS` → usage on stderr, exit 64.
* validate **every** argument with `[ -e "$arg" ]` before touching `open`; first failure →
  `fedit: no such file or directory: <arg>` on stderr, exit 66.
* absolutize with `/bin/realpath` using the rotate idiom, so paths with spaces/newlines and leading
  `-` survive (an absolute path can never be mistaken for a flag):
  ```sh
  n=$#; i=0
  while [ "$i" -lt "$n" ]; do
      arg=$1; shift
      abs=$(realpath "$arg") || exit 66
      set -- "$@" "$abs"
      i=$((i + 1))
  done
  ```
* dispatch: if `[ -d "$APP" ]` → `exec open -a "$APP" "$@"`; else try `open -a FEdit "$@"` and, on
  failure, print `fedit: FEdit.app not found (looked in <APP> and LaunchServices); set FEDIT_APP`
  and exit 69.

**New harness `scripts/FeditShimTests/run.sh`** — covers A12–A17 with **no GUI and no FEdit**: it
builds a temp `bin/` containing a stub `open` that records `"$@"` to a file, puts it first on
`PATH`, points `FEDIT_APP` at a temp `FEdit.app` directory, runs `scripts/fedit` for each case and
asserts recorded arguments + exit codes. Same PASS/FAIL/`failureCount` reporting shape as the
`swiftc` harnesses.

**`scripts/install.sh`** — append an `install_cli_shim` step after the `.app` copy: pick the first
writable directory among `${FEDIT_BIN_DIR:-}`, `/usr/local/bin`, `$HOME/.local/bin` (creating the
last if needed), `install -m 0755 scripts/fedit "$dir/fedit"`, print the installed path, and warn if
`$dir` is not on `$PATH`. Never `sudo`. **Non-fatal**: if nothing is writable, warn and continue —
a failed shim install must not fail an otherwise-good app install.
*Contingency:* if `scripts/install.sh` has not landed yet, ship `scripts/fedit` + the README's
manual one-liner and leave a `- [ ] (installer-script)`-blocked note; the fold-in is ~15 lines and
can land with that item instead.

**Docs (all doc edits for this item live here):**
* `SPEC.md` §3 — a bullet: a file/folder handed to the app from outside (command line, `open -a`)
  goes to an empty window if one exists, else a new one; a window with content is never disturbed;
  the file's parent becomes that window's sole root.
* `SPEC.md` §5.1 — the root can also come from an external open (the file's containing folder).
* `SPEC.md` §2 — the bundle declares a rank-`None` `public.data`/`public.folder` document type so
  LaunchServices will hand it explicit opens; it is not registered as a default handler.
* `SPEC.md` §13 — add `App/OpenRequest.swift`, `scripts/fedit`, `scripts/FeditShimTests`,
  `scripts/OpenRequestTests`, and the root `FEdit-Info.plist`.
* `README.md` — "Command line" section: `fedit path…`, the no-arg/`--help`/exit-code contract,
  `FEDIT_APP`, and the D9 caveat that the file's *parent folder* becomes the sidebar root (so
  `fedit ~/notes.md` scans your home directory).

*Revert:* delete `scripts/fedit` + `scripts/FeditShimTests`, revert the `install.sh` hunk and the
doc edits. Tiers 1–2 keep working — `open -a FEdit <path>` is the same feature, just typed longer.

*Pays off alone:* no — without Tiers 1–2 the shim just activates FEdit. Conversely Tiers 1–2 pay off
without it, via `open -a`.

## Interfaces between tiers

* **Tier 2 → Tier 1:** no code coupling. Tier 2's contract is only *"LaunchServices will deliver an
  odoc Apple Event for arbitrary files and folders to this bundle"*. Tier 1's contract is the dual:
  *"any `file:` URL delivered to `application(_:open:)`, from any source, is routed by D3/D5"* —
  which is why Tier 1 never looks at where the URL came from.
* **Tier 3 → Tiers 1–2:** the shim encodes **no** FEdit-specific protocol. Its entire contract is
  *"hand `open` the app bundle and zero or more existing absolute paths"*. It can therefore be
  written and fully tested (stub `open`) before Tier 1 exists, and Tier 1 can be tested by typing
  `open -a` by hand without the shim.
* **Inside Tier 1:** `OpenRequest` is the seam — a pure, filesystem-resolving value type with no
  AppKit/SwiftUI dependency (that is what makes it unit-testable); `LaunchCoordinator` owns queuing
  and window creation; `ContentView` owns the pristine test (it is the only place that can see the
  scene's `@SceneStorage`) and the application to the model.

## Load-bearing assumptions

**L1 — LaunchServices delivers an odoc Apple Event to a non-document SwiftUI app for
`open -a FEdit <path>`, and `@NSApplicationDelegateAdaptor`'s delegate receives
`application(_:open:)`** (with the Tier 2 declaration if needed).
*If false:* there is no Apple-Event path at all. Fallback: a custom URL scheme — `CFBundleURLTypes`
in the same `FEdit-Info.plist` and a shim that calls `open "fedit:///abs/path"`, received via the
same delegate's `application(_:open:)` (URL schemes arrive there too). *Rewrite size:* the receive
site plus URL decoding, ~25 lines in Tier 1 and ~5 in the shim; routing, `OpenRequest`, tiering and
all GUI criteria are unchanged. This is the single assumption with the widest consequence and it is
gated first — see Tier 1's gate.

**L2 — `GENERATE_INFOPLIST_FILE = YES` merges the generated keys into an `INFOPLIST_FILE` rather
than being ignored/overridden.**
*If false:* the shipped bundle loses `CFBundleExecutable`/`CFBundleIconName`/… and either fails to
launch or loses its icon. *Detected by:* A19's `plutil -p`, before anything ships. *Rewrite size:*
one file — write the full plist and set `GENERATE_INFOPLIST_FILE = NO` (~20 lines; contents listed
in Tier 2's fallback).

**L3 — A scene created by `openWindow(id: "editor")` is pristine (empty `@SceneStorage`) and runs
`.onAppear` shortly after.**
*If false:* the shipped Cmd+O flow is already broken; this item adds no new exposure. *Rewrite:*
none attributable here.

**L4 — An `OpenWindowAction` captured from one window's environment stays valid after that window
closes.**
*If false:* only the "app running with zero windows" case breaks (nothing happens). *Fallback:*
re-register from `FileCommands` (whose `Commands` body outlives every window) or from an
`@Environment(\.openWindow)` on `FEditApp` itself. *Rewrite:* ~10 lines, Tier 1 only.

**L5 — By `applicationDidFinishLaunching` + 0.25 s, every restored scene has appeared, and any scene
that is still going to restore has a non-empty `workspaceSnapshot` by the time it is offered a
claim.**
*If false:* a restored window can be claimed by a CLI open — it comes back showing the CLI file's
folder instead of its own, and its stored snapshot is then overwritten by the normal save path.
Bounded: **window session state only, no file on disk is touched**, and it needs a CLI invocation
racing a slow restore. *Mitigations already in the design:* the settle delay, the
`workspaceSnapshot.isEmpty` guard, and the fact that the existing `.onAppear` restores *before* the
claim is offered. *If it shows up in A7's five repeats:* raise `launchSettleDelay` to 0.5 s first;
if that is not enough, hand the late snapshot to a fresh window (a second mailbox entry consumed by
the new scene's `onAppear` instead of its own empty storage, ~15 lines) — deliberately not built
now.

**L6 — `NSApp.windows` + `(window.delegate as? WindowCloseGuardProxy)?.model` identifies a scene's
window.** Already relied on by `AppDelegate.applicationShouldTerminate`.
*If false:* only the "bring the claimed window to the front" nicety is lost (A3's front-most part).
*Rewrite:* delete the call, ~5 lines.

**L7 — `/bin/realpath` exists on macOS 26.** Verified present on this machine (Darwin 25.5).
*If false:* replace with `cd -- "$(dirname -- "$arg")" && printf '%s/%s\n' "$(pwd -P)"
"$(basename -- "$arg")"`. *Rewrite:* 4 lines in the shim.

**L8 — `scripts/install.sh` exists by the time Tier 3 is built.** *If false:* Tier 3's contingency
above (ship the shim, defer the install hunk).

## Out of scope

* Reusing a window that already shows the same folder/file, or de-duplicating repeated `fedit` calls
  on one file (D4).
* Line/column arguments (`fedit file.md:42`), `--wait`/`-W` blocking, reading from stdin, `--new`.
* One window with several roots from one invocation — `fedit dirA dirB` gives one window each.
* Finder double-click, drag-onto-Dock, "Open With", and becoming a default handler. The Tier 2
  declaration may make some of these work incidentally; none is a criterion and none is tested
  beyond A20 (which asserts FEdit does *not* take over `.md`).
* Moving the recursive scan off the main thread (D9 / A22) — if A22 says it is needed, it is its own
  TODO item, and it is a pre-existing Cmd+O issue too.
* Recovering a restored window's late-arriving snapshot after a CLI claim (L5's second fallback).
* Extracting `AppDelegate` out of `WindowCloseGuard.swift` into its own file — tempting while
  touching it, but pure churn; it stays where it is.
* Sandboxing / security-scoped bookmarks — SPEC §2 keeps the app unsandboxed, and a CLI-supplied
  path is read by plain path like every other path in FEdit.
* Any change to `WorkspaceModel`, the save/dirty/autosave paths, or the editor.

## Verification summary

| Criteria | How |
|---|---|
| A18 | `swiftc FEdit/App/OpenRequest.swift scripts/OpenRequestTests/main.swift -o /tmp/openreqtests && /tmp/openreqtests` |
| A12–A17 | `sh scripts/FeditShimTests/run.sh` (stub `open` on `PATH`; no GUI, no FEdit needed) |
| A19, A21 | `plutil -p "<app>/Contents/Info.plist"`, `command -v fedit`, `ls -l` on the installed shim |
| A1–A11, A20, A22 | **Human GUI pass**, from the built `.app` (not the Xcode-run process, so `open -a` targets a stable bundle path). A7 and A10 are the two that matter most — they are the session-restore and Cmd+O interaction seams. |

Nothing here can be covered by an automated app-level test: there is no XCTest target, and every
window-lifecycle criterion needs a real launch. The split above is deliberate — all the *pure* logic
(path→request mapping, shim argument handling) is pushed into the two automated harnesses so the
human pass is only about window behavior.

---

# Revision 2 (2026-08-11) — post-review re-cut

Adversarial plan review verdict: BUILD WITH FIXES (18 findings, 4 tensions). This section
supersedes the conflicting parts of Revision 1: D2, D3, D6 (exit codes), D7 (cap semantics),
the whole Tier 1 mechanism sketch, the Tier 3 install fold-in, and the criteria amendments below.
Everything not named here stands as written in Revision 1.

## Tier 1 mechanism (replaces Revision 1's Tier 1 sketch)

**Rule as the user sees it (replaces D3):** *a CLI open ALWAYS opens a new window; no existing
window — full, empty, restoring, or mid-panel — is ever touched.* This mirrors Cmd+O exactly and
structurally removes the claim-vs-session-restore race (review defect 1), the false "fills an
empty window" promise (defect 2), and the double-count race (defect 4).

`OpenRequest` stays exactly as Revision 1 specifies (it checked out clean in review).

`LaunchCoordinator` (class comment REWRITTEN — the Revision 1 claim that it "stays exactly as it
is" was wrong twice over: the existing comment already mis-names the shortcut as Cmd+N, and this
item makes it a two-mailbox coordinator; fix both while touching it):

```swift
@MainActor final class LaunchCoordinator {
    var pendingNewWindowPicks = 0                       // existing, untouched semantics

    // (cli-open)
    private static let launchSettleDelay: TimeInterval = 0.25
    private static let maxFileOpensPerEnqueue = 8       // caps each INCOMING BATCH (defect 13)
    private var undispatched: [OpenRequest] = []        // odoc'd, not yet assigned to a window
    private var assignments: [OpenRequest] = []         // one entry == one openWindow() issued
    private var isSettled = false
    private var openNewWindow: (() -> Void)?

    func registerWindowOpener(_ opener: @escaping () -> Void)  // idempotent, EVERY scene .onAppear
    func noteLaunchFinished()          // arms the settle timer once; on fire: isSettled = true + dispatch
    func enqueueFileOpens(_ urls: [URL])   // truncate batch to 8, append; if isSettled, dispatch now
    func claimFileOpenAssignment() -> OpenRequest?   // FIFO pop off `assignments`
    func bringWindowToFront(for model: WorkspaceModel)  // unchanged from Revision 1
    private func dispatchPendingFileOpens() {
        // moves each request undispatched -> assignments and calls openNewWindow?() once per
        // request, at move time. No "still-unclaimed" re-issue logic exists (defect 4): a
        // request is issued exactly one window, ever. If openNewWindow is nil, retry on a
        // 100 ms timer up to 20 times PER DISPATCH (counter reset each dispatch, defect 14),
        // leaving requests in `undispatched` so a later dispatch can pick them up.
    }
}
```

`isSettled` starts false; already-running delivery (app settled long ago) dispatches synchronously
from `enqueueFileOpens` — but "dispatch" only appends an assignment and calls `openWindow(id:)`;
ALL heavy work (scan, watcher, git, possible modal alert) happens in the new scene, one turn after
its `.onAppear` (defect 3). Nothing heavier than an array append + `openWindow` runs inside
`application(_:open:)`.

`AppDelegate` forwarders: as Revision 1 (unchanged).

`ContentView`:

```swift
// in .onAppear, BEFORE the didRestore guard (so every scene re-registers; keeps the opener
// fresh across window closes — defect 6):
LaunchCoordinator.shared.registerWindowOpener { openWindow(id: "editor") }
// in the existing pristine-scene section, AFTER the Cmd+O drain, mutually exclusive with it:
} else if workspace.roots.isEmpty && workspace.openFile == nil && workspaceSnapshot.isEmpty,
          let request = LaunchCoordinator.shared.claimFileOpenAssignment() {
    // One-turn hop: window on screen first; scan/watcher/git/alert run in an ordinary
    // context, mirroring the folder-panel idiom directly above this line (defect 3).
    DispatchQueue.main.async {
        workspace.addFolders([request.root])
        if let file = request.file { workspace.requestOpen(file) }
        LaunchCoordinator.shared.bringWindowToFront(for: workspace)
    }
}
```

Restored scenes cannot claim: their `.onAppear` runs at t≈0, and `assignments` is only ever
populated at dispatch time (≥ settle, or post-settle enqueue) immediately before `openWindow` —
by which point every restored scene's one-shot `.onAppear` has already run and nothing re-offers
the claim to it (no notification path exists in Revision 2). The pristine guard set is kept as
belt-and-braces on top of that ordering, not as the primary defense.

**Known, accepted residuals (recorded, not fixed):**
- Cold launch with no saved session: SwiftUI may create its blank startup window next to the CLI
  window (one stray empty window, cosmetic). If review defect 5's other branch holds instead
  (SwiftUI suppresses the startup window on odoc launch), no scene ever registers the opener and
  the retry loop exhausts; the recorded contingency is moving the opener registration to
  app/Commands level (L4 fallback, ~25 lines). The Tier 1 gate below distinguishes the branches.
- App running with zero windows: the opener was captured from a now-closed window's environment;
  if `OpenWindowAction` goes inert when its source window closes (L4), the CLI open does nothing.
  New criterion A24 covers it; same contingency.
- A dotfile argument (`fedit ~/.zshrc`) opens the file with its parent as root but no sidebar row
  to highlight (the scanner skips hidden files) — documented limitation, README notes it.
- Two rapid invocations racing window creation get FIFO assignment; requests can land in the
  "other" invocation's window only in the sense that both windows are identical pristine scenes —
  indistinguishable to the user.

**Tier 1 gate (replaces Revision 1's):** build via `scripts/install.sh /tmp/fedit-gate-dest`
(Release, stable registered path — resolves defect 17's three-paths ambiguity), then
`open -a /tmp/fedit-gate-dest/FEdit.app /tmp/fedit-cli/notes.md`. Instrument BOTH ends
temporarily (NSLog in `application(_:open:)` AND in `dispatchPendingFileOpens`), so the outcomes
separate cleanly: no odoc log → Tier 2 needed; odoc logged but no window → defect-5 branch →
apply the opener contingency, NOT Tier 2. Remove instrumentation before commit.

## Tier 3 amendments

- Exit-code contract, pinned (defect 8): no-arg → `exec open -a "$APP"`, exit with open's status
  (D6's "exit 0" is retracted); "FEdit.app not found" → exit 69 on BOTH the no-arg and
  with-operands branches; new criterion A23 asserts 69.
- realpath failure prints the shim's own message format (`fedit: no such file or directory: <arg>`,
  stderr, exit 66) — never realpath's raw error (defect 16). Trailing-newline filenames are
  accepted as broken (command substitution strips them; degenerate case, recorded).
- Symlink resolution IS part of the shim contract (tension 1, chosen knowingly): `realpath`
  canonicalizes (`/tmp` → `/private/tmp`, symlinked dirs resolved), so the sidebar may show the
  resolved name where Cmd+O on the same symlink would show the link name. CLI convention wins;
  divergence documented in README. A16 asserts the CANONICALIZED paths.
- `install_cli_shim` (defect 10): bin-dir search order becomes `${FEDIT_BIN_DIR:-}`,
  `/opt/homebrew/bin`, `/usr/local/bin`, `$HOME/.local/bin` (Apple Silicon reality). The installed
  copy gets its `APP=` default rewritten to the actual install destination
  (`sed` the `APP=${FEDIT_APP:-...}` line to `${FEDIT_APP:-$INSTALLED_APP}`), so a non-default
  destination still yields a working shim; the committed `scripts/fedit` keeps the
  `/Applications/FEdit.app` default. Still non-fatal on failure.
- Docs move INTO the tier they document (defect 7): Tier 1 carries the SPEC §3/§5.1 bullets, the
  §13 entries for `OpenRequest.swift`/`OpenRequestTests`, AND the correction of §13's existing
  `LaunchCoordinator.swift` line (now a two-mailbox coordinator); Tier 2 carries the SPEC §2
  bullet + §13 `FEdit-Info.plist` entry; Tier 3 carries the README "Command line" section and §13
  entries for `fedit`/`FeditShimTests`. Revision 1's "all doc edits live in Tier 3" is retracted.

## Acceptance criteria amendments

- A2: drop "byte-identical"; assert the human-checkable list (roots, open file, caret, dirty marker).
- A3: REPLACED (fill-empty-window removed): with windows A (content) and B (empty, made via
  Cmd+O→Cancel): `fedit notes.md` → a NEW window C; A and B both untouched.
- A6: drop "no delay perceptible" (untestable); assert only: no extra window, no panel.
- A7: keep, with the note that 5 warm repeats is a weak detector for the (now structurally
  removed) restore race; it remains as a regression tripwire.
- A9: the alert appears AFTER the window is on screen (the one-turn hop makes this assertable).
- A14: no-arg exits with open's status (normally 0).
- A16: asserts canonicalized (`/private/...`) absolute paths, one operand per argument, in order.
- A19: fallback-plist check adds CFBundlePackageType and CFBundleVersion.
- A20: acknowledged best-effort only (defect 11): passes vacuously when a prior user binding
  exists; the load-bearing control is the declarative LSHandlerRank=None. Checked, not proven.
- NEW A23 [SHELL]: FEDIT_APP pointing at a nonexistent bundle → exit 69, message on stderr, for
  both `fedit` and `fedit <existing-path>`.
- NEW A24 [GUI]: app running with zero windows → `fedit notes.md` opens a window (defect 6/L4).
- NEW A25 [SHELL+GUI]: `fedit a.md b.md` (one invocation, two operands) → operands recorded in
  order [SHELL]; against the real app: two windows, one per file [GUI].
- NEW A26 [GUI]: `fedit a.md; fedit b.md` back-to-back → exactly two new windows, zero stray
  empty windows (defect 4 regression).
- NEW A27 [UNIT]: OpenRequestTests: a symlink argument is kept as the symlink path
  (standardizedFileURL does NOT resolve symlinks — only the shim canonicalizes; assert the
  app-side non-resolution so tension 1's boundary is pinned in a test).

## Decisions taken

All dated 2026-08-11, folding the adversarial plan review (verdict BUILD WITH FIXES).

- **Always-new-window replaces fill-empty-window** (defects 1, 2, 3, 4, 12 at the root).
  Alternative: keep claim-by-existing-pristine-scene and patch each race individually (settle-gate
  the pop, transient didDrainFolderPick, per-dispatch bookkeeping). Rejected: the review showed the
  guard set both under-matches (excludes every user-producible empty window — Cmd+O→Cancel,
  remove-all-roots) and over-matches (claims a restoring scene whose snapshot is late, silently
  destroying the saved session — the same race that descoped (open-folder-new-window)'s
  auto-picker). Always-new-window is the Cmd+O precedent, needs no new guard theory, and its only
  cost is a possible stray blank window on cold no-session launch (cosmetic, recorded).
- **Heavy work hops one runloop turn after the new scene appears** (defect 3). Alternative: run
  addFolders/requestOpen inline in .onAppear. Rejected: puts a recursive scan, FSEvents arming, a
  git shell-out and potentially NSAlert.runModal inside the odoc/appear stack; the shipped
  folder-panel code already documents the one-turn idiom as the safe shape.
- **Defect 5 is gated, not pre-built.** The blank-startup-window-suppression branch would move
  opener registration to app level; building that now is speculative plumbing. The re-cut gate
  distinguishes "no odoc" from "odoc, no window" via two-point instrumentation, so the fix (Tier 2
  vs opener contingency) cannot be misattributed (review's concern).
- **Opener registration is idempotent per scene-appear** (defect 6), shrinking staleness to the
  zero-windows case, which gets criterion A24 + a recorded contingency instead of speculative code.
- **Docs redistributed to their tiers; LaunchCoordinator class comment and SPEC §13 line
  corrected in Tier 1** (defect 7). The Revision 1 claim that the coordinator's doc "stays exactly
  as it is" was factually wrong (the comment says Cmd+N; the shortcut is Cmd+O since (open-cmd-o)).
- **Exit codes pinned** (defect 8): no-arg propagates open's status; 69 for missing app in all
  branches; criterion added. Alternative (always exit 0 on no-arg) hides a broken install.
- **Shim canonicalizes via realpath, knowingly diverging from the app's no-symlink-resolution
  stance** (defect 9 / tension 1); the app side stays non-resolving, pinned by new unit A27.
- **install_cli_shim rewrites the installed shim's APP default to the actual destination and
  searches /opt/homebrew/bin first-after-override** (defect 10).
- **Batch cap = per-enqueue, retry counter = per-dispatch** (defects 13, 14) — pinned.
- **Dotfile argument = open with no highlighted row** (defect 15): accepted, documented. The
  alternative (special-case showing hidden files for a CLI-opened root) leaks a per-window scanner
  mode into FileNode for a marginal case.
- **Trailing-newline filenames mangled by the shim** (defect 16a): accepted; embedded
  spaces/newlines survive, trailing newlines are a shell-substitution limitation not worth a
  NUL-delimited workaround in a /bin/sh shim.
- **Gate bundle unified on the install.sh-built Release app in a temp destination** (defect 17).
- **Tension 2 (public.data/public.folder in every Open With menu) accepted IF Tier 2 proves
  necessary**; Tier 1's gate runs first precisely so an unnecessary declaration is never added.
  URL-scheme fallback remains recorded (L1) if odoc needs a declaration AND the clutter is deemed
  unacceptable later — not built now.
- **Tensions 3, 4 (verbatim parent scan; A22 measurement-not-gate) accepted as Revision 1 stated
  them**; both are pre-existing Cmd+O-equivalent hazards, and A22's number lands in DONE.md.

---

# Revision 3 (2026-08-11) — post code-review re-cut of the window-targeting mechanism

The adversarial behavior review of the Revision 2 implementation returned DO NOT SHIP with a
CONFIRMED critical: the pristine-guard claim is blind to a restored scene whose `@SceneStorage`
snapshot arrives late (the repo's own late-arrival recovery in ContentView proves late snapshots
are real), so the "a CLI open can never touch a restoring window" criterion was only made
improbable by the 0.25 s settle timer — a restored root's synchronous scan blocking the main
thread past the timer, or an odoc delivered after settle, defeats the ordering argument. A missed
claim additionally poisoned the FIFO `assignments` queue permanently.

## Replacement mechanism (supersedes Revision 2's Tier 1 claim design)

**Typed window payload.** A second scene `WindowGroup(id: "cli-open", for: CLIOpenToken.self)`
presents `ContentView` with an optional token binding. `CLIOpenToken` is `Codable & Hashable`
(UUID + root path + optional file path); dispatch wraps each `OpenRequest` in a fresh-UUID token
and calls `openWindow(id: "cli-open", value: token)`. SwiftUI delivers the value to exactly the
window it creates for that call — there is NO claim step, no assignments queue, no settle timer.
A restored "editor"-group scene cannot receive a token by construction; the UUID makes every
token unequal so value-dedup can never focus or reuse an old (or restored) window. The token is
applied only to a pristine scene (a restored cli-open window has a snapshot, which wins), one
runloop turn after appear (unchanged from Revision 2). The existing `WindowGroup(id: "editor")`
is byte-identical — its scene identity, and therefore session restore, is untouched.

## Finding dispositions (review verdict DO NOT SHIP → fixed and re-gated)

- #1 claim-guard blindness (Critical) + #2 FIFO poisoning (High): ACCEPTED — root-fixed by the
  token design above; both failure classes are structurally impossible now.
- #3 retry exhaustion strands requests (Medium): ACCEPTED — `registerWindowOpener` re-enters
  dispatch when requests are pending, so a late-appearing scene drains the queue.
- #4 stale OpenWindowAction on zero windows (Medium, SUSPECTED): REJECTED with evidence — the
  implementer's scripted A24 run showed the real app going 0 → 1 windows on a live `fedit`
  invocation; L4 holds on this platform.
- #5 --help hard-codes /Applications (Low): ACCEPTED — uses `$APP`.
- #6 sed-rewrite verification is textual (Low): ACCEPTED — the installed shim's `APP=` line is
  now verified by evaluating it in a clean shell and comparing the resolved path.
- #7 mislabeled shim test / missing fallback-success case (Low): ACCEPTED — test fixed + real
  fallback-success test added.
- #8 tautological OpenRequest assertions (Low): ACCEPTED — replaced; token Codable/inequality
  assertions added.
- #9 docs overclaim (Low): ACCEPTED — "never disturbed" is now structurally true and stays;
  added the LaunchServices-fallback caveat, the cold-launch restored-windows-plus-one note, and
  --help's first-argument-only rule.
- #10 CLI open during a modal folder panel nests the scan/alert in the modal session (SUSPECTED):
  DEFERRED, recorded residual — no existing window is mutated; modal-nesting is a pre-existing
  hazard class in this app; revisit only if it shows in the human GUI pass.
- #11 cap-before-filter (Nit): ACCEPTED — filter, then cap.

## Revision 3.1 — second review round on the token implementation

The focused re-review of the token implementation returned DO NOT SHIP once more: the late-
snapshot race had RELOCATED onto restored cli-open windows (a persisted token re-presented at
restore races that scene's own late @SceneStorage arrival — Revision 3's "structurally
impossible" was an overclaim; the claim held only for editor-group scenes). Dispositions:

- #1 relocated race (Critical): ACCEPTED, fixed with a stronger invariant than the reviewer's
  suggestion — LaunchCoordinator records the UUIDs of tokens issued IN THIS PROCESS and a token
  is applied only if (a) its UUID is in that set, (b) the scene passes the pristine check at
  onAppear AND re-passes it inside the one-turn-later apply block, and (c) the binding is cleared
  after any handling. A restored token (previous process) is inert by construction — no timing
  assumption anywhere. Accepted edge: a CLI window quit before its first snapshot write restores
  empty rather than re-opening its file.
- #2 cli-open scene can steal a pending Cmd+O pick (High): ACCEPTED — the folder-pick drain is
  gated on the scene NOT being a cli-open scene (binding-presence discriminator).
- #3 opener closure strongly captures the view's WorkspaceModel into the singleton (Medium):
  ACCEPTED — capture list narrows it to the OpenWindowAction.
- #4 no failure path when openWindow no-ops / late token delivery dropped (Medium): PARTIAL — an
  onChange observer (same guards, idempotent) now catches late delivery; window-creation-failure
  reconciliation DEFERRED as a recorded residual; the zero-windows check remains owed to the
  human GUI pass (pre-redesign evidence showed 0→1 works; mechanism unchanged).
- #5 shared retry budget across chains (Low): ACCEPTED — one chain at a time.
- #6 SPEC "no timing assumptions" overclaim (Low): ACCEPTED — replaced with the actual invariant.
- #7 non-falsifiable token assertions (Nit): ACCEPTED — hasDirectoryPath assertions + UUID
  round-trip.

If the verify pass after this round still finds the race, that is AUTONOMY hard stop 4
(same finding surviving two fixer rounds) and the item stops there.
