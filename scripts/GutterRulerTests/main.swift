//
//  main.swift
//  GutterRulerTests
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
//  (gutter-top-overflow) Regression harness for `LineNumberRulerView` keeping
//  its drawing INSIDE the editor pane. Build and run:
//
//      swiftc FEdit/Editor/LogicalLine.swift FEdit/Editor/LineNumberRulerView.swift \
//          scripts/GutterRulerTests/main.swift -o /tmp/gutrtests && /tmp/gutrtests
//
//  Named `main.swift` because Swift only allows top-level statements in a file
//  with that exact name — the same reason every other harness here is.
//
//  UNLIKE every other harness in this directory, this one is not pure logic: it
//  hosts a real SwiftUI view containing a real `NSViewRepresentable` editor and
//  rasterises the result. It needs a window-server connection, so it wants a
//  logged-in GUI session; it never becomes visible (activation policy
//  `.prohibited`, an offscreen `NSWindow` that is never ordered front). A future
//  headless CI would have to skip this one harness. That cost is paid on purpose,
//  because nothing cheaper can see this bug:
//
//  **The SwiftUI hosting context is load-bearing, not incidental scaffolding.**
//  This was established the hard way. `NSView.clipsToBounds` has defaulted to
//  `false` since macOS 14, and `drawHashMarksAndLabels` centres the topmost
//  number in a fragment that, once scrolled, begins ABOVE the viewport — so the
//  ruler does ask to draw outside itself. But in a plain AppKit hierarchy (the
//  scroll view added straight to a backing `NSView`) AppKit clips that drawing at
//  the ruler's bounds anyway and the bug does NOT appear: an earlier version of
//  this harness built exactly that and could not reproduce the reported defect
//  even with the fix reverted. Put the same scroll view inside an `NSHostingView`
//  — which is what `CodeEditorView` actually is — and the label escapes. A
//  harness that skipped SwiftUI would have passed forever while the shipped app
//  stayed broken.
//
//  Measured on the shipped build before the fix (2026-08-22), from
//  `plans/gutter-top-overflow-repro.png`: the gutter's own background
//  (`NSColor(white: 0.95)` = 242) begins at device row 124, `ColumnHeaderBar`'s
//  bottom hairline sits at 122-123, and the `137` label's ink runs 117-129 —
//  **7 device px above the first row the ruler fills**, i.e. across the hairline
//  and into the header strip. This harness reproduces a 7-device-row overhang
//  from the same geometry, which is what ties the reproduction to the report.
//

import AppKit
import SwiftUI

// MARK: - Harness plumbing (same shape as the other scripts/*/main.swift)

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
// Light appearance, pinned — exactly what `FEditApp` does for the real app
// (SPEC §3: light only, regardless of the system setting). Without this the
// harness inherits the machine's appearance, and under dark mode the header
// strip's `windowBackgroundColor` fill is itself dark: `darkCount` then counts
// the CHROME as gutter ink and the suite reports 4 spurious failures (measured:
// 2,464 "dark subpixels above the pane" on a scene with none). Pinning it also
// makes the thresholds below mean the same thing on every machine.
app.appearance = NSAppearance(named: .aqua)

/// `LayoutMetrics.columnHeaderHeight`. Duplicated rather than imported: the real
/// one lives in `App/FEditApp.swift`, which would drag the whole app target into
/// a harness that needs only the ruler. It is the number the repro was calibrated
/// against — the screenshot's header strip measured exactly 28 pt.
let headerHeight: CGFloat = 28
let paneWidth: CGFloat = 320
let totalHeight: CGFloat = 200

// MARK: - A real SwiftUI editor column

/// Smuggles the AppKit objects back out of `makeNSView`, the only place they
/// exist. `@unchecked Sendable` because everything here runs on the main thread
/// and none of it escapes.
final class Box: @unchecked Sendable {
    var scrollView: NSScrollView?
    var ruler: LineNumberRulerView?
    var textView: NSTextView?
    var layoutManager: NSLayoutManager?
    var textContainer: NSTextContainer?
    var storage: NSTextStorage?
}

/// The same TextKit 1 assembly order `CodeEditorView.makeNSView` uses, reduced to
/// what the ruler needs: storage → layout manager → container → text view, with
/// the strong references running downward only and the storage retained by `Box`
/// so it cannot deallocate when this method returns.
struct EditorRep: NSViewRepresentable {
    let box: Box
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage(string: text)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        let textContainer = NSTextContainer(
            size: NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .black
        textView.backgroundColor = .white
        scrollView.documentView = textView

        let ruler = LineNumberRulerView(textView: textView, scrollView: scrollView)
        ruler.editorFontSize = 13
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        box.scrollView = scrollView
        box.ruler = ruler
        box.textView = textView
        box.layoutManager = layoutManager
        box.textContainer = textContainer
        box.storage = storage
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// `ContentView.editorColumn`'s shape: a fixed-height title strip with a bottom
/// hairline, then the editor. The strip is the region nothing in the gutter is
/// allowed to paint into.
struct EditorColumn: View {
    let box: Box
    let text: String

    var body: some View {
        VStack(spacing: 0) {
            Text("DESIGN.md")
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 35)
                .frame(height: headerHeight)
                .background(Color(nsColor: .windowBackgroundColor))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(height: 1)
                }
            EditorRep(box: box, text: text)
        }
    }
}

struct Scene {
    let hosting: NSHostingView<EditorColumn>
    let box: Box
    let window: NSWindow

    var scrollView: NSScrollView { box.scrollView! }
    var ruler: LineNumberRulerView { box.ruler! }
    var textView: NSTextView { box.textView! }
    var layoutManager: NSLayoutManager { box.layoutManager! }
    var textContainer: NSTextContainer { box.textContainer! }
}

func makeScene(text: String) -> Scene {
    let box = Box()
    let hosting = NSHostingView(rootView: EditorColumn(box: box, text: text))
    hosting.frame = NSRect(x: 0, y: 0, width: paneWidth, height: totalHeight)
    let window = NSWindow(
        contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false
    )
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    // SwiftUI instantiates the representable on its own schedule, so wait for the
    // OBSERVABLE condition with a deadline rather than sleeping a fixed interval
    // and hoping. A fixed sleep that is generous on an idle machine is a flake
    // waiting for a loaded one, and the failure would look like a real defect
    // (no ruler, so no ink anywhere) rather than a timeout.
    let deadline = Date().addingTimeInterval(5)
    while box.scrollView == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    guard box.scrollView != nil, box.layoutManager != nil, box.textContainer != nil else {
        print("  FATAL: SwiftUI never instantiated the representable within 5 s — no window server?")
        exit(2)
    }
    // One more pass so the freshly created scroll view is laid out and tiled
    // (the ruler's thickness reaches the scroll view's geometry here).
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    let scene = Scene(hosting: hosting, box: box, window: window)
    scene.layoutManager.ensureLayout(for: scene.textContainer)
    return scene
}

/// Scrolls so document offset `y` sits at the top of the viewport, then lets the
/// ruler see it — in the app that arrives via the bounds-changed notification the
/// ruler subscribes to in its own initialiser.
func scroll(_ scene: Scene, to y: CGFloat) {
    scene.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
    scene.scrollView.reflectScrolledClipView(scene.scrollView.contentView)
    scene.ruler.needsDisplay = true
    scene.textView.needsDisplay = true

    // The clip view clamps a bounds origin it dislikes. Verify the scroll really
    // happened: a clamped scroll leaves the document at the top, where there is
    // no partially visible line and nothing can overflow — every assertion below
    // would then pass for the wrong reason.
    let landed = scene.scrollView.contentView.bounds.origin.y
    check(
        abs(landed - y) < 0.5,
        "the scroll landed where the test asked (\(Int(y)) pt)",
        "asked \(y), clip view is at \(landed) — clamped, so the case below is vacuous"
    )
}

/// How far above the viewport's top edge the label-bearing fragment begins — the
/// quantity that makes the bug possible. `drawHashMarksAndLabels` walks from the
/// logical line containing the first visible CHARACTER and centres its number in
/// that line's FIRST fragment, so a positive value here means the topmost number
/// is placed outside the visible band.
func topFragmentOverhang(_ scene: Scene) -> CGFloat {
    let visible = scene.textView.visibleRect
    let glyphRange = scene.layoutManager.glyphRange(forBoundingRect: visible, in: scene.textContainer)
    let charRange = scene.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    // Mirror `drawHashMarksAndLabels` EXACTLY: it walks to the LOGICAL line start
    // and takes that line's FIRST fragment. Using the first visible character's
    // own fragment instead understates the overhang for a wrapped paragraph —
    // that fragment is a continuation, sitting much closer to the viewport than
    // the paragraph's first one, which is where the label actually goes.
    let nsString = scene.textView.string as NSString
    let lineStart = LogicalLine.lineStart(in: nsString, containing: charRange.location)
    let glyphIndex = scene.layoutManager.glyphIndexForCharacter(at: lineStart)
    let fragment = scene.layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    return visible.minY - (fragment.minY + scene.textView.textContainerOrigin.y)
}

// MARK: - Rasterising

func render(_ scene: Scene) -> (rep: NSBitmapImageRep, scale: Int) {
    guard let rep = scene.hosting.bitmapImageRepForCachingDisplay(in: scene.hosting.bounds) else {
        print("  FATAL: could not create a bitmap rep — is there a window server?")
        exit(2)
    }
    scene.hosting.cacheDisplay(in: scene.hosting.bounds, to: rep)
    return (rep, rep.pixelsHigh / Int(scene.hosting.bounds.height))
}

/// Counts painted pixels darker than the mid-tone within the given device bands.
/// `alphaComponent > 0.5` matters: an unpainted pixel reads back as transparent
/// black and would otherwise count as ink.
func darkCount(_ rep: NSBitmapImageRep, rows: Range<Int>, cols: Range<Int>) -> Int {
    var n = 0
    for y in rows.clamped(to: 0..<rep.pixelsHigh) {
        for x in cols.clamped(to: 0..<rep.pixelsWide) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.alphaComponent > 0.5 && c.brightnessComponent < 0.6 { n += 1 }
        }
    }
    return n
}

/// `rep` row 0 is the TOP row and the `VStack` lays the header strip out first,
/// so the header occupies exactly the first `headerHeight × scale` rows.
func headerRows(scale: Int) -> Range<Int> { 0..<(Int(headerHeight) * scale) }

/// The device columns the gutter occupies, widened by a point so an antialiased
/// edge cannot fall outside the window we inspect.
func gutterCols(_ scene: Scene, scale: Int) -> Range<Int> {
    0..<((Int(scene.ruler.ruleThickness.rounded(.up)) + 1) * scale)
}

/// Renders twice: once as shipped (production sets `clipsToBounds` in the ruler's
/// initialiser) and once with the clip forced off. The forced-off render is what
/// proves the scenario provokes the bug at all — without it, "nothing paints
/// above the pane" would also hold for a scroll that landed on a line boundary,
/// or for a ruler that drew nothing whatsoever.
func renderBothWays(_ scene: Scene) -> (shipped: NSBitmapImageRep, unclipped: NSBitmapImageRep, scale: Int) {
    let shipped = render(scene)
    scene.ruler.clipsToBounds = false
    scene.ruler.needsDisplay = true
    let unclipped = render(scene)
    scene.ruler.clipsToBounds = true
    return (shipped.rep, unclipped.rep, shipped.scale)
}

// MARK: - Case 1: a partially scrolled document

section("A partially scrolled document draws no gutter ink above the editor pane")

let plain = (1...200).map { "line \($0)" }.joined(separator: "\n")
let scene1 = makeScene(text: plain)
// Captured HERE, before any render: `renderBothWays` toggles the property and
// restores it, so reading it later would report the harness's own last write and
// pass even with the fix reverted. Verified: this is the value production sets.
let clipAsConstructed = scene1.ruler.clipsToBounds

// Measured, not assumed, so the offset below still cuts the top line in half if
// the font metrics ever change.
let lineHeight = scene1.layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height
check(lineHeight > 4, "measured a plausible line height", "got \(lineHeight)")

// A whole number of lines plus half a line: the topmost line is half cut off,
// which is the situation in both repro screenshots.
scroll(scene1, to: lineHeight * 4 + lineHeight / 2)
check(
    topFragmentOverhang(scene1) > 1,
    "the top line's fragment really does begin above the viewport",
    "overhang = \(topFragmentOverhang(scene1)) pt"
)

let r1 = renderBothWays(scene1)
let cols1 = gutterCols(scene1, scale: r1.scale)
let headerBand1 = headerRows(scale: r1.scale)

let shippedAbove1 = darkCount(r1.shipped, rows: headerBand1, cols: cols1)
let unclippedAbove1 = darkCount(r1.unclipped, rows: headerBand1, cols: cols1)

check(
    unclippedAbove1 > 0,
    "the scenario provokes the bug: with the clip off, gutter ink lands in the header strip",
    "dark subpixels above the pane = \(unclippedAbove1) (0 would make the next check vacuous)"
)
check(
    shippedAbove1 == 0,
    "as shipped, NO gutter ink lands in the header strip",
    "dark subpixels above the pane = \(shippedAbove1)"
)

// The clip may remove only what was outside. Compared over the FULL width, not
// just the gutter, so a clip that ate into the text would be caught too.
let paneRows1 = (Int(headerHeight) * r1.scale)..<r1.shipped.pixelsHigh
let allCols1 = 0..<r1.shipped.pixelsWide
let shippedInside1 = darkCount(r1.shipped, rows: paneRows1, cols: allCols1)
let unclippedInside1 = darkCount(r1.unclipped, rows: paneRows1, cols: allCols1)
check(
    shippedInside1 == unclippedInside1,
    "the clip removes ONLY the overflow — in-pane ink is identical",
    "shipped \(shippedInside1) vs unclipped \(unclippedInside1)"
)
check(shippedInside1 > 0, "the editor actually drew something in the pane", "\(shippedInside1)")

// The topmost partially visible line's number must still be DRAWN, clipped at
// the pane's edge — not skipped, not re-centred. Its surviving sliver lives in
// the first few device rows below the boundary.
let topSliver1 = (Int(headerHeight) * r1.scale)..<(Int(headerHeight) * r1.scale + 3 * r1.scale)
check(
    darkCount(r1.shipped, rows: topSliver1, cols: cols1) > 0,
    "the top line's number survives as a clipped sliver rather than disappearing",
    "dark subpixels in the top 3 pt of the gutter = \(darkCount(r1.shipped, rows: topSliver1, cols: cols1))"
)

// MARK: - Case 2: scrolled into the middle of a wrapped paragraph

section("A wrapped paragraph cannot fling its number far above the pane")

// The walk starts at the LOGICAL line start of the first visible character, so
// scrolling into the middle of a paragraph that wraps to many fragments puts the
// label at that paragraph's FIRST fragment — rows above the viewport, not a hair
// over the boundary. This is the case that would paint a number over the header
// strip's title rather than merely over its hairline.
let longParagraph = String(repeating: "wrapped paragraph text ", count: 60)
let scene2 = makeScene(text: "first line\n" + longParagraph + "\nlast line")

let usedHeight2 = scene2.layoutManager.usedRect(for: scene2.textContainer).height
check(
    usedHeight2 > totalHeight * 2,
    "the paragraph really does wrap well past one viewport",
    "used height \(usedHeight2)"
)

// Scroll a CONTROLLED distance into the paragraph rather than to its middle.
// The overhang grows with how far in you scroll, and at half the document it is
// hundreds of points — which puts the escaped label above this scene's bitmap
// entirely, where no assertion can see it (the first attempt at this case
// measured 0 ink above the pane for exactly that reason, not because the bug was
// absent). 24 pt is deliberately MORE than one 16 pt line height, so it still
// demonstrates the property that matters — the overflow is not bounded by a
// single line — while landing inside the header strip this harness can inspect.
let paragraphStart = ("first line\n" as NSString).length
let paragraphGlyph = scene2.layoutManager.glyphIndexForCharacter(at: paragraphStart)
let paragraphTop = scene2.layoutManager.lineFragmentRect(forGlyphAt: paragraphGlyph, effectiveRange: nil).minY
scroll(scene2, to: paragraphTop + 24)
check(
    topFragmentOverhang(scene2) > lineHeight,
    "mid-paragraph, the label-bearing fragment begins MORE than one line above the viewport",
    "overhang = \(topFragmentOverhang(scene2)) pt vs line height \(lineHeight)"
)

let r2 = renderBothWays(scene2)
let cols2 = gutterCols(scene2, scale: r2.scale)
let headerBand2 = headerRows(scale: r2.scale)

check(
    darkCount(r2.unclipped, rows: headerBand2, cols: cols2) > 0,
    "mid-paragraph, the clip-off render puts gutter ink in the header strip",
    "dark subpixels above the pane = \(darkCount(r2.unclipped, rows: headerBand2, cols: cols2))"
)
check(
    darkCount(r2.shipped, rows: headerBand2, cols: cols2) == 0,
    "as shipped, mid-paragraph draws no gutter ink in the header strip",
    "dark subpixels above the pane = \(darkCount(r2.shipped, rows: headerBand2, cols: cols2))"
)

let paneRows2 = (Int(headerHeight) * r2.scale)..<r2.shipped.pixelsHigh
let allCols2 = 0..<r2.shipped.pixelsWide
check(
    darkCount(r2.shipped, rows: paneRows2, cols: allCols2)
        == darkCount(r2.unclipped, rows: paneRows2, cols: allCols2),
    "mid-paragraph, in-pane ink is identical with and without the clip"
)

// MARK: - Case 3: the property, and the unscrolled base case

section("The clip is on, and an unscrolled document is unaffected")

check(clipAsConstructed, "the ruler clips to its bounds as CONSTRUCTED, before any test touched it")

let scene3 = makeScene(text: plain)
scroll(scene3, to: 0)
let r3 = renderBothWays(scene3)
let cols3 = gutterCols(scene3, scale: r3.scale)
let headerBand3 = headerRows(scale: r3.scale)
check(
    darkCount(r3.shipped, rows: headerBand3, cols: cols3) == 0,
    "an unscrolled document paints nothing above the pane either"
)
check(
    darkCount(r3.shipped, rows: headerBand3, cols: cols3)
        == darkCount(r3.unclipped, rows: headerBand3, cols: cols3),
    "at scroll offset 0 the clip is a no-op — line 1's number was never outside"
)

// MARK: - Result

print("")
print("==================================")
if failures == 0 {
    print("ALL TESTS PASSED")
    exit(0)
} else {
    print("\(failures) of \(checks) CHECKS FAILED")
    exit(1)
}
