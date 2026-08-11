# xcode-scaffold

**Risk tier:** standard — no algorithms or concurrency; the only delicate part is a hand-written `project.pbxproj`, and any mistake fails loudly at `xcodebuild` time with zero blast radius (no other code exists yet).

## Goal

Create the buildable foundation for FEdit per SPEC §2–§3: a hand-written `FEdit.xcodeproj` (objectVersion 77, file-system-synchronized `FEdit/` group, macOS 26.0 target, Swift 5 language mode, no sandbox/entitlements, ad-hoc signing, `GENERATE_INFOPLIST_FILE`), a SwiftUI app entry point (`WindowGroup`, 1100×700 default, 700×400 minimum, light-only appearance), and a placeholder `ContentView`. SPEC §3's 1100×700 / 700×400 are interpreted as **content size** — the natural reading for SwiftUI `.defaultSize` / `.frame(minWidth:minHeight:)`. This item also establishes the GPL-3.0-or-later header boilerplate that every future source file will carry.

## Acceptance criteria — concrete and testable

1. **Headless build succeeds:**
   `xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Debug -derivedDataPath build build`
   exits 0 and produces `build/Build/Products/Debug/FEdit.app`. No checked-in scheme file is needed — xcodebuild auto-synthesizes scheme "FEdit" from the target. (`-target` with `-derivedDataPath` is rejected by xcodebuild; `-derivedDataPath` requires `-scheme`.) This command is the **project-wide build convention** for all future items.
2. **Project format:** `FEdit.xcodeproj/project.pbxproj` has `objectVersion = 77` and contains a `PBXFileSystemSynchronizedRootGroup` for `FEdit/` referenced by the target's `fileSystemSynchronizedGroups`; there is **no** `PBXBuildFile`/`PBXFileReference` entry for any `.swift` source (future files are picked up automatically from disk).
3. **Build settings verifiable in the built product:**
   - `codesign -dv build/Build/Products/Debug/FEdit.app` reports ad-hoc signing (`Signature=adhoc`).
   - No `.entitlements` file exists in the repo; `codesign -d --entitlements - …` output must not contain `com.apple.security.app-sandbox`. A `com.apple.security.get-task-allow` entry **is expected** in Debug builds (injected by ad-hoc signing via `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`) and is not a violation.
   - `plutil -p build/Build/Products/Debug/FEdit.app/Contents/Info.plist` shows `LSMinimumSystemVersion` = 26.0 and `CFBundlePackageType` = APPL (Info.plist generated, none checked in).
   - `SWIFT_VERSION = 5.0` in the pbxproj (Swift 5 language mode, not Swift 6).
4. **Launch:** running `build/Build/Products/Debug/FEdit.app/Contents/MacOS/FEdit` in the background keeps a live process for ≥3 s (no immediate crash); launching via `open` shows one window, white/light content, at 1100×700. On first launch, or after `rm -rf ~/Library/Saved\ Application\ State/<bundle-id>.savedState/`, the window opens at 1100×700 (content size; verify via AppleScript `bounds of front window` or screenshot).
5. **Light-only:** with macOS set to dark mode, the window still renders in light appearance (aqua forced app-wide).
6. **Multi-window:** Cmd+N (stock File → New Window from `WindowGroup`) opens additional independent windows. (Manual check.)
7. **Min size:** the window cannot be resized below 700×400. (Manual check.)
8. **Headers:** both `.swift` files start with the GPL header boilerplate defined below (file name, project, `Copyright © 2026 Felix Matschke`, GPLv3-or-later notice).

## Tiers

### Tier 1 — Buildable project skeleton

*Independently buildable: yes (this tier alone satisfies acceptance criteria 1–3, 8).*

**Create `FEdit/App/FEditApp.swift`** — GPL header (template below), then a minimal `@main struct FEditApp: App` with `WindowGroup { ContentView() }`. No sizing/appearance yet.

**Create `FEdit/Views/ContentView.swift`** — GPL header, then a placeholder `struct ContentView: View` whose body is a `Text("FEdit")` (or similar) on a white background filling the window. Explicitly a stub; replaced wholesale by the `(split-layout)` item.

**Create `FEdit.xcodeproj/project.pbxproj`** — hand-written OpenStep plist, one file only (no workspace/scheme files; Xcode regenerates `project.xcworkspace` on open, and `xcodebuild -scheme FEdit` works because xcodebuild synthesizes a scheme from the target). CLI builds regenerate an empty `FEdit.xcodeproj/project.xcworkspace/`; if Xcode later writes `contents.xcworkspacedata`, commit it — `xcuserdata/` is already gitignored. Structure:

- Header `// !$*UTF8*$!`, `archiveVersion = 1`, `objectVersion = 77`.
- Fixed hand-assigned 24-hex UUIDs (e.g. prefix `FED17000000000000000xxxx` — hex-only) for every object so the file is deterministic and diffable.
- Objects:
  - `PBXProject` — attributes `BuildIndependentTargetsInParallel = 1`, `LastUpgradeCheck = 2660` (matches the actual DTXcode of Xcode 26.6, avoiding the GUI upgrade-check nag), `preferredProjectObjectVersion = 77`, `minimizedProjectReferenceProxies = 1`; no `compatibilityVersion` key (superseded at objectVersion 77); `mainGroup`, `productRefGroup`, one target.
  - Main `PBXGroup` containing the synchronized group and the Products group; `PBXGroup` "Products" with the `FEdit.app` `PBXFileReference` (`explicitFileType = wrapper.application`, `sourceTree = BUILT_PRODUCTS_DIR`).
  - `PBXFileSystemSynchronizedRootGroup` — `path = FEdit; sourceTree = "<group>";` no exceptions/explicit file types.
  - `PBXNativeTarget` "FEdit" — `productType = "com.apple.product-type.application"`, `fileSystemSynchronizedGroups = (<the sync group>)`, build phases: empty `PBXSourcesBuildPhase`, `PBXFrameworksBuildPhase`, `PBXResourcesBuildPhase` (sources flow in via the synchronized group).
  - Two `XCConfigurationList`s (project, target) with Debug/Release `XCBuildConfiguration`s.
- Project-level build settings (both configs unless noted): `SDKROOT = macosx`, `MACOSX_DEPLOYMENT_TARGET = 26.0`, `SWIFT_VERSION = 5.0`, `ALWAYS_SEARCH_USER_PATHS = NO`. Debug: `ONLY_ACTIVE_ARCH = YES`, `SWIFT_OPTIMIZATION_LEVEL = "-Onone"`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG`, `DEBUG_INFORMATION_FORMAT = dwarf`, `GCC_OPTIMIZATION_LEVEL = 0`, `ENABLE_TESTABILITY = YES`. Release: `SWIFT_OPTIMIZATION_LEVEL = "-O"`, `DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"`.
- Target-level build settings: `PRODUCT_NAME = "$(TARGET_NAME)"`, `PRODUCT_BUNDLE_IDENTIFIER = com.felixmatschke.FEdit`, `GENERATE_INFOPLIST_FILE = YES`, `INFOPLIST_KEY_NSPrincipalClass = NSApplication`, `CODE_SIGN_STYLE = Automatic`, `CODE_SIGN_IDENTITY = "-"` (ad-hoc; no `DEVELOPMENT_TEAM`, no `CODE_SIGN_ENTITLEMENTS`, no `ENABLE_APP_SANDBOX`), `ENABLE_HARDENED_RUNTIME = NO`, `LD_RUNPATH_SEARCH_PATHS = "@executable_path/../Frameworks"`, `COMBINE_HIDPI_IMAGES = YES`, `CURRENT_PROJECT_VERSION = 1`, `MARKETING_VERSION = 1.0`.

**GPL header boilerplate** (contract for all future sources; `<FileName>.swift` substituted per file):

```
//
//  <FileName>.swift
//  FEdit
//
//  Copyright © 2026 Felix Matschke
//
//  This file is part of FEdit.
//
//  FEdit is free software: you can redistribute it and/or modify it under
//  the terms of the GNU General Public License as published by the Free
//  Software Foundation, either version 3 of the License, or (at your
//  option) any later version.
//
//  FEdit is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
//  for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with FEdit. If not, see <https://www.gnu.org/licenses/>.
//
```

**Verify tier 1:** the `xcodebuild` command from acceptance criterion 1; `codesign -dv`; `plutil -p` on the generated Info.plist; run the binary in the background for a liveness check.

**Revert:** delete `FEdit.xcodeproj/`, `FEdit/`, `build/`.

### Tier 2 — Window sizing and light-only appearance

*Independently buildable: yes (builds on tier 1; touches only the two Swift files).*

**Modify `FEdit/App/FEditApp.swift`:**
- `init()` sets `NSApplication.shared.appearance = NSAppearance(named: .aqua)` — forces light appearance for every window and all AppKit chrome regardless of the system setting (SPEC §3). Requires `import AppKit` (or `import SwiftUI` + `import AppKit`).
- `WindowGroup { ContentView().frame(minWidth: 700, minHeight: 400) }` — SwiftUI derives the window's minimum size from the root view's minimum frame.
- `.defaultSize(width: 1100, height: 700)` on the `WindowGroup` — first-launch size; subsequent frames come from system window restoration (SPEC §3), which needs no code.
- Nothing else: no custom `.commands` (Cmd+N New Window is stock `WindowGroup` behavior), no per-window state yet.

**Modify `FEdit/Views/ContentView.swift`** only if needed to keep the placeholder filling the window with a white background (`.background(Color.white)` / `frame(maxWidth: .infinity, maxHeight: .infinity)`).

**Verify tier 2:** rebuild headlessly; then `open build/Build/Products/Debug/FEdit.app` and manually check criteria 4–7 (1100×700 light window in dark mode, min-size clamp, Cmd+N).

**Revert:** `git checkout` of the two Swift files (restores their tier-1 versions); the pbxproj is untouched.

## Interface between tiers

- **File paths are the contract:** `FEdit/App/FEditApp.swift` and `FEdit/Views/ContentView.swift` exist from tier 1 onward at exactly those paths; tier 2 edits them in place and never touches `project.pbxproj`. The synchronized root group means no project-file edit is ever needed when Swift files are added or changed — this is also the interface this item exports to every later TODO item.
- **Type contract:** `ContentView` is a public-by-visibility (internal) `View` with a parameterless initializer; `FEditApp` is the only `@main`. Tier 2 relies on nothing else from tier 1.
- **GPL header template** (verbatim above) is the cross-item contract for all future sources.

## Load-bearing assumptions

1. **objectVersion 77 + `PBXFileSystemSynchronizedRootGroup`** is parsed by Xcode 26.6's `xcodebuild` (format introduced in Xcode 16; Xcode 26 is later). If parsing fails, the error surfaces immediately on the first build.
2. **`preferredProjectObjectVersion` replaces `compatibilityVersion`** at objectVersion 77; including a stale `compatibilityVersion` key is at best ignored, so it is omitted.
3. **`GENERATE_INFOPLIST_FILE = YES`** synthesizes a complete, launchable Info.plist (CFBundleExecutable, CFBundlePackageType, LSMinimumSystemVersion) for a `@main` SwiftUI macOS app with no checked-in plist, storyboard, or xib. `INFOPLIST_KEY_NSPrincipalClass = NSApplication` is included defensively; if Xcode 26 emits it automatically the setting is redundant, not harmful.
4. **`CODE_SIGN_IDENTITY = "-"` with no team** produces an ad-hoc signature that runs locally without prompts (no sandbox, no hardened runtime, per SPEC §2).
5. **macOS 26 SDK** ships with Xcode 26.6, so `MACOSX_DEPLOYMENT_TARGET = 26.0` resolves against the default `SDKROOT = macosx`.
6. **`NSApplication.shared.appearance = .aqua` set in `App.init()`** runs early enough to affect the first window (App.init executes before any window is created) — the standard non-Info.plist way to force light mode. Fallback if it ever proves flaky: `INFOPLIST_KEY_NSRequiresAquaSystemAppearance` support is *not* assumed, so the fallback would be a checked-in Info.plist snippet — deliberately avoided in this plan.
7. **No checked-in scheme file is required; xcodebuild synthesizes a scheme from the target** — `xcodebuild -scheme FEdit` builds headlessly with no `xcshareddata` scheme in the repo (verified with Xcode 26.6; note `-target` cannot be combined with `-derivedDataPath`).
8. **Min window size via root-view `.frame(minWidth:minHeight:)`** is honored by `WindowGroup` under default `windowResizability` on macOS 26.
9. **Swift 5 mode (`SWIFT_VERSION = 5.0`)** keeps strict-concurrency diagnostics at Swift 5 defaults, per SPEC §2.

## Out of scope

- Three-column layout, dividers, `@AppStorage`/`@SceneStorage` persistence keys — `(split-layout)` and later items.
- Any custom menus/commands (Open Folder…, Save, Autosave toggle) — Cmd+N is stock behavior, nothing added.
- Models, editor, preview, sidebar — all later TODO items.
- App icon / asset catalog, shared xcodebuild scheme, tests or test target, README changes. (The repo is already a git repo with LICENSE and README — verified; no `git init` or LICENSE work exists to exclude.)
- Entitlements of any kind (explicitly none per SPEC §2).
- Window-restoration code (system-provided; only verified not blocked).

## Auto-resolved (plan review)

Findings from an empirical adversarial review (built the planned project with Xcode 26.6) folded in:

- **DEFECT 1 (critical):** the original `-target` + `-derivedDataPath` acceptance command is rejected by xcodebuild; replaced everywhere with `xcodebuild -project FEdit.xcodeproj -scheme FEdit -configuration Debug -derivedDataPath build build` (xcodebuild synthesizes the scheme; now the project-wide build convention), and assumption 7 reworded accordingly.
- **DEFECT 2:** the no-sandbox-entitlement criterion now requires only the absence of `com.apple.security.app-sandbox`, since Debug ad-hoc signing injects `com.apple.security.get-task-allow` via `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`.
- **DEFECT 3:** the UUID prefix example contained a non-hex character (`FED1T000…`); changed to hex-only `FED17000…`, keeping the deterministic/diffable rationale.
- **DEFECT 4:** the window-size criterion now specifies verification on first launch or after clearing `~/Library/Saved Application State/<bundle-id>.savedState/`, measuring 1100×700 content size via AppleScript `bounds of front window` or screenshot.
- **DEFECT 5:** the repo is already a git repo with LICENSE/README, so `git init`/LICENSE were removed from out-of-scope and Tier 2's revert is stated as `git checkout` of the two Swift files.
- **TENSION (a):** SPEC §3's 1100×700 / 700×400 are recorded as content-size dimensions, matching the natural SwiftUI `.defaultSize`/`.frame` reading.
- **TENSION (b):** `LastUpgradeCheck` set to 2660 (the actual DTXcode) to avoid the GUI upgrade nag.
- **TENSION (c):** CLI builds regenerate an empty `project.xcworkspace/`; if Xcode later writes `contents.xcworkspacedata` it gets committed, while `xcuserdata/` stays gitignored.
