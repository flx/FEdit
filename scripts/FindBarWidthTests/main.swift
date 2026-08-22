//
//  main.swift
//  FindBarWidthTests
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
//  (find-bar-narrow-column) Regression harness for the find bar's behaviour as
//  the editor column narrows. Build and run:
//
//      swiftc FEdit/Models/FileNode.swift FEdit/Models/FilterQuery.swift \
//          FEdit/Models/FilterRowCache.swift FEdit/Models/GitStatus.swift \
//          FEdit/Models/RootScanScheduler.swift FEdit/Models/TreeSkipGate.swift \
//          FEdit/Models/FileWatcher.swift FEdit/Models/DirectoryTreeWatcher.swift \
//          FEdit/App/WaitMarkers.swift FEdit/Models/WorkspaceSnapshot.swift \
//          FEdit/Models/WorkspaceModel.swift FEdit/Views/FindBar.swift \
//          scripts/FindBarWidthTests/main.swift -o /tmp/fbwtests && /tmp/fbwtests
//
//  Like `GutterRulerTests` and unlike the other harnesses here, this is not pure
//  logic: it hosts the REAL `FindBar` and rasterises it, so it needs AppKit to be
//  able to draw — in practice a logged-in GUI session. It creates no window and
//  never becomes visible.
//
//  Method: render the bar at a known column width, centred in a wider MAGENTA
//  field, and count non-magenta pixels outside the column's band, over EVERY row.
//  SwiftUI's `.frame(width:)` centres an oversized child rather than clipping it,
//  so a bar whose controls cannot compress paints its background and its bottom
//  hairline outside its own frame. Counting every row rather than the bar's mid
//  row matters: a future change in which only the bottom hairline escaped would
//  slip past a single-row probe, and the hairline is half of what makes the spill
//  visible. Every render also counts ink INSIDE the band and fails if there is
//  none, so a render that silently never laid out cannot report "fits".
//
//  Detection is three per-channel thresholds, not a hue test. It is sound here
//  because nothing in the bar is magenta: `windowBackgroundColor` ≈ 0.93 gray,
//  the roundedBorder bezel is white, `separatorColor` is gray, the accent is
//  blue.
//
//  On what "outside its own frame" means in the running app: `ContentView`
//  declares sidebar → divider → editorColumn → divider → preview, and later
//  siblings paint over earlier ones, so the LEFT spill covers the left divider
//  while most of the right spill is repainted by the divider and the preview.
//  Ink-outside-the-frame is still the right invariant to pin — it is the defect —
//  but the visible symptom is asymmetric, and "paints over both dividers" (as the
//  original report put it) overstates the right-hand side.
//
//  MEASURED CONTEXT, so nobody re-derives it:
//
//  * The bar's overflow threshold is `338 + gutterInset` pt of column (measured
//    at 2 pt steps: 338 / 362 / 378 / 444 for insets 0 / 25 / 40 / 107). Before
//    this item it was `398 + inset`.
//  * FEdit's real default editor column is **361.7 pt**, not the 366.7 pt a naive
//    `(1100 − 1100/3)/2` gives: `ContentView` subtracts one
//    `LayoutMetrics.dividerHitWidth` (5 pt) and a second one when a Markdown
//    preview is showing, before halving the remainder.
//  * So at the default window a 2-digit-line-count file (gutter 21 pt) now fits,
//    and a 3-digit one (gutter 25 pt) **still overflows — by about 1 pt**, down
//    from about 61 pt. That residue is real and is filed as its own item; it is
//    NOT asserted away here.
//  * The overflow is reachable far more easily than "a very narrow window": at
//    the 700 pt minimum window with an otherwise default layout the editor column
//    is 161.7 pt, and dragging the editor/preview divider to `editorFractionMin`
//    reaches 108.5 pt. No floor-lowering fixes those; they need the bar to have a
//    narrow-width design.
//

import AppKit
import SwiftUI

// Stand-in for the real one in App/FEditApp.swift, whose `@main` cannot coexist
// with a `main.swift`. Value copied from source; only `dividerLineWidth` is used.
enum LayoutMetrics {
    static let dividerLineWidth: CGFloat = 1
}

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
    checks += 1
    if condition {
        print("  PASS: \(label)")
    } else {
        failures += 1
        let extra = detail()
        print("  FAIL: \(label)\(extra.isEmpty ? "" : " — \(extra)")")
    }
}

func section(_ title: String) {
    print("")
    print("== \(title) ==")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// Light appearance, pinned — what `FEditApp` does for the real app (SPEC §3) —
// so control metrics are identical on every machine.
app.appearance = NSAppearance(named: .aqua)

let outerWidth: CGFloat = 800
let outerHeight: CGFloat = 60

/// `(1100 − 1100/3 − 5 − 5) / 2`, i.e. `ContentView`'s own arithmetic with both
/// divider hit widths subtracted, for a default window showing a Markdown file.
let defaultEditorColumn: CGFloat = (1100 - 1100.0 / 3.0 - 5 - 5) / 2   // ≈ 361.7

struct Probe: View {
    @ObservedObject var workspace: WorkspaceModel
    @FocusState private var focused: Bool
    let columnWidth: CGFloat
    let inset: CGFloat

    var body: some View {
        ZStack {
            Color(red: 1, green: 0, blue: 1)
            FindBar(workspace: workspace, isQueryFieldFocused: $focused, leadingInset: inset)
                .frame(width: columnWidth)
        }
        .frame(width: outerWidth, height: outerHeight)
    }
}

struct Measurement {
    let outside: Int
    let inside: Int
}

/// Device pixels the bar painted outside its own frame (both sides, every row),
/// plus the ink it painted inside — the latter so a render that never laid out
/// cannot masquerade as "nothing outside".
@MainActor
func measure(columnWidth: CGFloat, inset: CGFloat) -> Measurement {
    let model = WorkspaceModel()
    model.findQuery = "needle"
    model.noteFindCountLabel("3 of 17")
    let hosting = NSHostingView(rootView: Probe(workspace: model, columnWidth: columnWidth, inset: inset))
    hosting.frame = NSRect(x: 0, y: 0, width: outerWidth, height: outerHeight)
    hosting.layoutSubtreeIfNeeded()
    let deadline = Date().addingTimeInterval(5)
    while hosting.subviews.isEmpty && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))

    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
        print("  FATAL: could not create a bitmap rep — can AppKit draw here?")
        exit(2)
    }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let scale = rep.pixelsHigh / Int(outerHeight)
    // Even column widths only, so the band edges land on whole pixels.
    let leftEdge = Int((outerWidth - columnWidth) / 2) * scale
    let rightEdge = Int((outerWidth + columnWidth) / 2) * scale

    func nonMagenta(_ range: Range<Int>) -> Int {
        var n = 0
        for y in 0..<rep.pixelsHigh {
            for x in range.clamped(to: 0..<rep.pixelsWide) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                let magenta = c.redComponent > 0.9 && c.greenComponent < 0.1 && c.blueComponent > 0.9
                if !magenta { n += 1 }
            }
        }
        return n
    }
    return Measurement(
        outside: nonMagenta(0..<leftEdge) + nonMagenta(rightEdge..<rep.pixelsWide),
        inside: nonMagenta(leftEdge..<rightEdge)
    )
}

/// The bar's natural height at a given column width, with no height imposed. If
/// the "Case sensitive" label ever wraps to a second line, this grows — which is
/// how the contents are pinned without OCR.
@MainActor
func naturalHeight(columnWidth: CGFloat, inset: CGFloat) -> CGFloat {
    let model = WorkspaceModel()
    struct Bare: View {
        @ObservedObject var workspace: WorkspaceModel
        @FocusState private var focused: Bool
        let columnWidth: CGFloat
        let inset: CGFloat
        var body: some View {
            FindBar(workspace: workspace, isQueryFieldFocused: $focused, leadingInset: inset)
                .frame(width: columnWidth)
        }
    }
    let hosting = NSHostingView(rootView: Bare(workspace: model, columnWidth: columnWidth, inset: inset))
    hosting.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 200)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    return hosting.fittingSize.height
}

@MainActor
func report(_ label: String, _ m: Measurement) {
    print("        \(label): outside = \(m.outside), inside = \(m.inside)")
}

MainActor.assumeIsolated {

    section("Every render actually drew something")

    // Guards the whole suite: if a render silently fails to lay out, `outside`
    // is 0 and every "nothing outside" check below would pass while measuring
    // nothing at all. This project has been bitten by exactly that (see
    // scripts/GutterRulerTests and commit 679b698).
    let sanity = measure(columnWidth: 600, inset: 25)
    check(sanity.inside > 1000, "a 600 pt render puts substantial ink inside the band",
          "inside = \(sanity.inside)")

    section("The overflow threshold sits where this item put it: 338 pt + gutter inset")

    // Straddle checks. These pin the threshold from BOTH sides, so they catch a
    // regression that raises it AND silently notice if it ever improves. A
    // one-sided "does not overflow at width W" check would still pass if the
    // query field's floor crept back up to 100.
    for (inset, clean, spilling) in [(CGFloat(0), CGFloat(342), CGFloat(334)),
                                     (CGFloat(25), CGFloat(366), CGFloat(358))] {
        let ok = measure(columnWidth: clean, inset: inset)
        let bad = measure(columnWidth: spilling, inset: inset)
        report("inset \(Int(inset)) @ \(Int(clean)) pt", ok)
        report("inset \(Int(inset)) @ \(Int(spilling)) pt", bad)
        check(ok.inside > 1000 && bad.inside > 1000,
              "inset \(Int(inset)): both straddle renders drew",
              "inside = \(ok.inside) / \(bad.inside)")
        check(ok.outside == 0,
              "inset \(Int(inset)): a \(Int(clean)) pt column paints nothing outside its frame",
              "outside = \(ok.outside)")
        check(bad.outside > 0,
              "inset \(Int(inset)): a \(Int(spilling)) pt column still DOES overflow — the threshold has not moved",
              "outside = \(bad.outside)")
    }

    section("Roomy columns are unaffected")

    for width in [430, 500, 600] as [CGFloat] {
        let m = measure(columnWidth: width, inset: 25)
        check(m.outside == 0 && m.inside > 1000,
              "a \(Int(width)) pt column paints nothing outside its frame",
              "outside = \(m.outside), inside = \(m.inside)")
    }

    section("The controls survive: the checkbox label never wraps")

    // The bar fitting is worthless if it fits by degrading its own contents. The
    // "Case sensitive" label used to wrap to two lines from about 380 pt down and
    // truncate ("Case / sensi…") by 324 pt, which made the bar taller and
    // eventually unreadable; `.fixedSize` now holds it. Height is the proxy: a
    // wrapped label is a second line.
    let wide = naturalHeight(columnWidth: 600, inset: 25)
    check(wide > 10, "measured a plausible bar height at 600 pt", "got \(wide)")
    for width in [360, 330, 300, 260] as [CGFloat] {
        let h = naturalHeight(columnWidth: width, inset: 25)
        check(abs(h - wide) < 0.5,
              "at \(Int(width)) pt the bar is still one line tall (label not wrapped)",
              "height \(h) vs \(wide) at 600 pt")
    }

    section("Context that is measured, not asserted")

    // Recorded rather than checked, because it is the part this item did NOT
    // fix. Asserting it either way would be dishonest: asserting "no overflow"
    // would fail, and asserting "overflow" would enshrine the defect.
    let atDefault = measure(columnWidth: 360, inset: 25)
    print("        default editor column is \(String(format: "%.1f", defaultEditorColumn)) pt;")
    print("        at 360 pt with a 3-digit gutter the bar still spills \(atDefault.outside) px")
    print("        (it spilled ~61 pt worth before this item; the residue is filed separately)")
    check(sanity.inside > 1000, "…and that measurement drew, so the number above means something")

    print("")
    print("==================================")
    if failures == 0 {
        print("ALL TESTS PASSED")
        exit(0)
    } else {
        print("\(failures) of \(checks) CHECKS FAILED")
        exit(1)
    }
}
