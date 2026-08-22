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
//  (find-bar-narrow-column, find-bar-narrow-redesign) Regression harness for the
//  find bar's behaviour as the editor column narrows. Build and run:
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
//  so a bar whose controls cannot compress paints outside its own frame. Counting
//  every row rather than the mid row matters: a spill confined to the bottom
//  hairline would slip past a single-row probe. Every render also counts ink
//  INSIDE the band and fails if there is none, so a render that silently never
//  laid out cannot report "fits" — the null-result trap post-mortemed in 679b698.
//
//  Detection is three per-channel thresholds, not a hue test. Sound here because
//  nothing in the bar is magenta: `windowBackgroundColor` ≈ 0.93 gray, the
//  roundedBorder bezel is white, `separatorColor` is gray, the accent is blue.
//
//  WHAT THE BAR NOW DOES, and what each number below means:
//
//  * Above `FindBar.singleRowMinimumWidth + gutterInset` it lays out as ONE row,
//    exactly as it always has — verified pixel-identical to the pre-change build
//    at 430, 500 and 600 pt.
//  * Below that it lays out as TWO rows: query field + checkbox, then the count
//    readout + Done. One row is 31 pt tall, two are 56 pt.
//  * That drops the width at which it overflows from `338 + inset` to
//    `184 + inset` — measured at 2 pt steps: 184 / 208 / 224 / 290 for insets
//    0 / 25 / 40 / 107.
//
//  THE RESIDUE, stated rather than asserted away: row-wrapping bottoms out at
//  about `161.5 + inset`, because the count readout (90 pt) and Done (47.5 pt)
//  plus a gap and the bar's padding is itself that wide, and splitting THOSE two
//  apart would be a fourth row. FEdit's real default editor column is 361.7 pt
//  (`ContentView` subtracts BOTH `dividerHitWidth`s before halving), so the
//  default window now has ~153 pt of headroom. But the 700 pt minimum window with
//  an otherwise default layout gives a 161.7 pt column, and dragging the
//  editor/preview divider to `editorFractionMin` gives 108.5 pt — both still
//  overflow, and no row-wrapping arrangement reaches them. Closing those needs a
//  control to change (a narrower count readout, or an unlabelled checkbox), which
//  is a product decision that was explicitly made the other way.
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
let outerHeight: CGFloat = 90

/// `(1100 − 1100/3 − 5 − 5) / 2`, i.e. `ContentView`'s own arithmetic with both
/// divider hit widths subtracted, for a default window showing a Markdown file.
let defaultEditorColumn: CGFloat = (1100 - 1100.0 / 3.0 - 5 - 5) / 2   // ≈ 361.7

/// A typical live gutter width: `ceil(3 digits × 10 pt monospaced) + 2 × 4`.
let typicalInset: CGFloat = 25

struct Probe: View {
    @ObservedObject var workspace: WorkspaceModel
    @FocusState private var focused: Bool
    let columnWidth: CGFloat
    let inset: CGFloat

    var body: some View {
        ZStack {
            Color(red: 1, green: 0, blue: 1)
            FindBar(workspace: workspace, isQueryFieldFocused: $focused,
                    leadingInset: inset, availableWidth: columnWidth)
                .frame(width: columnWidth)
        }
        .frame(width: outerWidth, height: outerHeight)
    }
}

struct Measurement {
    let outside: Int
    let inside: Int
}

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
    return Measurement(outside: nonMagenta(0..<leftEdge) + nonMagenta(rightEdge..<rep.pixelsWide),
                       inside: nonMagenta(leftEdge..<rightEdge))
}

/// The bar's natural height at a given column width. One row is 31 pt and two are
/// 56 pt, so this is how the harness tells which layout was chosen — and how it
/// catches the checkbox label wrapping, which would produce neither figure.
@MainActor
func naturalHeight(columnWidth: CGFloat, inset: CGFloat) -> CGFloat {
    struct Bare: View {
        @ObservedObject var workspace: WorkspaceModel
        @FocusState private var focused: Bool
        let columnWidth: CGFloat
        let inset: CGFloat
        var body: some View {
            FindBar(workspace: workspace, isQueryFieldFocused: $focused,
                    leadingInset: inset, availableWidth: columnWidth)
                .frame(width: columnWidth)
        }
    }
    let hosting = NSHostingView(rootView: Bare(workspace: WorkspaceModel(),
                                               columnWidth: columnWidth, inset: inset))
    hosting.frame = NSRect(x: 0, y: 0, width: columnWidth, height: 200)
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    return hosting.fittingSize.height
}

MainActor.assumeIsolated {

    section("Every render actually drew something")

    let sanity = measure(columnWidth: 600, inset: typicalInset)
    check(sanity.inside > 1000, "a 600 pt render puts substantial ink inside the band",
          "inside = \(sanity.inside)")

    let oneRowHeight = naturalHeight(columnWidth: 600, inset: typicalInset)
    let twoRowHeight = naturalHeight(columnWidth: 300, inset: typicalInset)
    print("        one row = \(oneRowHeight) pt, two rows = \(twoRowHeight) pt")
    check(oneRowHeight > 10 && twoRowHeight > oneRowHeight,
          "the two layouts have distinguishable heights",
          "\(oneRowHeight) vs \(twoRowHeight)")

    section("The bar switches rows exactly at FindBar.singleRowMinimumWidth")

    // Straddle computed FROM the production constant, not from a copied literal,
    // so changing the constant without re-measuring fails here instead of
    // silently leaving a stale number passing. Project convention: bound a
    // derived value, declare it, and pin both sides of the boundary from it.
    let switchAt = FindBar.singleRowMinimumWidth + typicalInset
    let justAbove = (switchAt / 2).rounded(.up) * 2      // next even width at or above
    let justBelow = justAbove - 4

    let above = measure(columnWidth: justAbove, inset: typicalInset)
    let below = measure(columnWidth: justBelow, inset: typicalInset)
    check(above.inside > 1000 && below.inside > 1000,
          "both straddle renders drew", "\(above.inside) / \(below.inside)")
    check(abs(naturalHeight(columnWidth: justAbove, inset: typicalInset) - oneRowHeight) < 0.5,
          "at \(Int(justAbove)) pt — just above the threshold — the bar is ONE row")
    check(abs(naturalHeight(columnWidth: justBelow, inset: typicalInset) - twoRowHeight) < 0.5,
          "at \(Int(justBelow)) pt — just below it — the bar is TWO rows")
    check(above.outside == 0, "one row at \(Int(justAbove)) pt paints nothing outside its frame",
          "outside = \(above.outside)")
    check(below.outside == 0, "two rows at \(Int(justBelow)) pt paint nothing outside either",
          "outside = \(below.outside)")

    section("Two rows hold down to about 184 pt + gutter inset")

    // The wrapped layout's own floor. Straddled so a regression that widens any
    // control shows up here rather than only in a very narrow window.
    for (inset, clean, spilling) in [(CGFloat(0), CGFloat(190), CGFloat(180)),
                                     (typicalInset, CGFloat(214), CGFloat(204))] {
        let ok = measure(columnWidth: clean, inset: inset)
        let bad = measure(columnWidth: spilling, inset: inset)
        check(ok.inside > 1000 && bad.inside > 1000,
              "inset \(Int(inset)): both floor renders drew", "\(ok.inside) / \(bad.inside)")
        check(ok.outside == 0,
              "inset \(Int(inset)): two rows at \(Int(clean)) pt still fit",
              "outside = \(ok.outside)")
        check(bad.outside > 0,
              "inset \(Int(inset)): at \(Int(spilling)) pt even two rows overflow — the floor has not moved",
              "outside = \(bad.outside)")
    }

    section("The default editor column fits, with room to spare")

    // This is what the item was for. 360 is the real default (361.7) rounded down
    // to an even width, which makes the check strictly harder than reality.
    let atDefault = measure(columnWidth: 360, inset: typicalInset)
    check(atDefault.outside == 0 && atDefault.inside > 1000,
          "at the default editor column with a 3-digit gutter, nothing paints outside the frame",
          "outside = \(atDefault.outside) (it was ~60 device px before this item, and ~4560 before its predecessor)")
    print("        default column \(String(format: "%.1f", defaultEditorColumn)) pt vs a floor of about \(184 + Int(typicalInset)) pt")

    section("Roomy columns are untouched")

    for width in [430, 500, 600] as [CGFloat] {
        let m = measure(columnWidth: width, inset: typicalInset)
        check(m.outside == 0 && m.inside > 1000 &&
              abs(naturalHeight(columnWidth: width, inset: typicalInset) - oneRowHeight) < 0.5,
              "a \(Int(width)) pt column is one row and paints nothing outside",
              "outside = \(m.outside)")
    }

    section("The checkbox label never wraps, in either layout")

    // The bar fitting is worthless if it fits by degrading its own contents. The
    // label used to wrap to two lines from about 380 pt down and truncate by
    // 324 pt, taking the bar's height to 38 / 52 / 94 pt — figures that are
    // neither of the two legitimate ones. Anything other than exactly one-row or
    // exactly two-row height means a control wrapped.
    for width in [500, 420, 380, 360, 330, 300, 260, 220] as [CGFloat] {
        let h = naturalHeight(columnWidth: width, inset: typicalInset)
        let legitimate = abs(h - oneRowHeight) < 0.5 || abs(h - twoRowHeight) < 0.5
        check(legitimate,
              "at \(Int(width)) pt the bar is exactly one or two rows tall — no control wrapped",
              "height \(h), expected \(oneRowHeight) or \(twoRowHeight)")
    }

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
