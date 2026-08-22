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
//  UNLIKE the other harnesses in this directory this one is not pure logic: it
//  builds a real TextKit 1 stack and a real `NSScrollView`, and rasterises the
//  result with `cacheDisplay(in:to:)`. It needs AppKit to be able to draw, so it
//  wants a logged-in GUI session; it creates no window and never becomes visible.
//
//  Why it must rasterise: the drawing loop asks to draw outside the ruler
//  IDENTICALLY before and after the fix — instrumented, the topmost label's
//  origin computes to `y = −5.5` against `bounds.minY = 0` either way — and only
//  whether that ask is clipped differs. A pure "where does this label go" oracle
//  would therefore pass in both worlds.
//
//  **The chrome strip must be a SIBLING added BEFORE the scroll view**, and that
//  is the one structural thing not to "simplify" away. Views paint in subview
//  order, so a strip added *after* the scroll view repaints over the escaped
//  label and the harness measures a clean 0 while the app is visibly broken.
//  Adding it first reproduces the app's own order, where the editor's AppKit view
//  draws on top of the SwiftUI-rendered column header. Measured, all three
//  arrangements, same document and scroll offset, clip forced off:
//
//      strip added BEFORE the scroll view   ->  21 stray subpixels above the pane
//      strip added AFTER  the scroll view   ->   0   (the strip repaints over it)
//      no strip, root fills its own bounds  ->  21
//
//  Recorded because an earlier version of this harness reported 0 and that was
//  read as "plain AppKit clips it, so the SwiftUI hosting context is required" —
//  which is FALSE, and briefly shipped in this header, the README and the DONE
//  record before an adversarial review refuted it by building the plain-AppKit
//  reproduction. No `NSHostingView` and no `NSWindow` is needed; both were
//  removed. The real null-result cause was elsewhere in that early harness, which
//  also had a silently clamped scroll (see `scroll(_:to:)`).
//
//  Measured on the shipped build before the fix (2026-08-22), from
//  `plans/gutter-top-overflow-repro.png`: the gutter's own background
//  (`NSColor(white: 0.95)` = 242) begins at device row 124, `ColumnHeaderBar`'s
//  bottom hairline sits at 122-123, and the `137` label's ink runs 117-129 —
//  7 device px above the first row the ruler fills, i.e. across the hairline and
//  into the header strip.
//

import AppKit

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
// (SPEC §3: light only, regardless of the system setting). Without it the
// harness inherits the machine's setting, and under dark mode `secondaryLabelColor`
// becomes near-white over the ruler's hardcoded light-gray background, so the
// numbers are invisible to `darkCount` while dark chrome counts AS ink: measured
// 4 spurious failures with the fix correctly in place. Pinning also makes the
// brightness threshold below mean the same thing on every machine.
app.appearance = NSAppearance(named: .aqua)

/// `LayoutMetrics.columnHeaderHeight`. Duplicated rather than imported: the real
/// one lives in `App/FEditApp.swift`, whose `@main` cannot coexist with a
/// `main.swift`. It is the value the repro was calibrated against — the
/// screenshot's header strip measured exactly 28 pt.
let chromeHeight: CGFloat = 28
let paneWidth: CGFloat = 320
let paneHeight: CGFloat = 170
let totalHeight: CGFloat = chromeHeight + paneHeight

/// A flat fill. Deliberately carries NO text: the strip exists only so that ink
/// landing in it is unambiguously the gutter's overflow. An earlier version drew
/// a title at a hardcoded 35 pt inset, which collides with the inspected gutter
/// band as soon as the document reaches 5 digits (`ruleThickness` 39 > 35) and
/// would have failed for a reason unrelated to the bug.
final class Strip: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
    }
}

struct Scene {
    let root: NSView
    let scrollView: NSScrollView
    let textView: NSTextView
    let layoutManager: NSLayoutManager
    let textContainer: NSTextContainer
    let ruler: LineNumberRulerView
    let storage: NSTextStorage
}

/// The same TextKit 1 assembly order `CodeEditorView.makeNSView` uses, reduced to
/// what the ruler needs: storage → layout manager → container → text view, the
/// strong references running downward only and the storage retained by `Scene`.
func makeScene(text: String, wrapWidth: CGFloat? = nil) -> Scene {
    let storage = NSTextStorage(string: text)
    let layoutManager = NSLayoutManager()
    storage.addLayoutManager(layoutManager)

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: paneHeight))
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false

    let containerWidth = wrapWidth ?? scrollView.contentSize.width
    let textContainer = NSTextContainer(
        size: NSSize(width: containerWidth, height: CGFloat.greatestFiniteMagnitude)
    )
    textContainer.widthTracksTextView = (wrapWidth == nil)
    layoutManager.addTextContainer(textContainer)

    // A non-zero starting frame, and an explicit final one below: with a `.zero`
    // frame the resizing text view lands at a negative origin inside the clip
    // view and every later `setBoundsOrigin` is clamped straight back to the
    // document's edge — the harness would silently never scroll, and every
    // "nothing painted above the pane" assertion would pass for the wrong reason.
    let textView = NSTextView(
        frame: NSRect(x: 0, y: 0, width: scrollView.contentSize.width, height: 10),
        textContainer: textContainer
    )
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

    // Root is unflipped, so the scroll view at y=0 occupies the BOTTOM and the
    // strip sits above it. The strip is added FIRST — see the header comment;
    // reversing these two lines makes every assertion below pass vacuously.
    let root = NSView(frame: NSRect(x: 0, y: 0, width: paneWidth, height: totalHeight))
    let strip = Strip(frame: NSRect(x: 0, y: paneHeight, width: paneWidth, height: chromeHeight))
    root.addSubview(strip)
    root.addSubview(scrollView)

    layoutManager.ensureLayout(for: textContainer)
    textView.frame = NSRect(
        x: 0, y: 0,
        width: scrollView.contentSize.width,
        height: ceil(layoutManager.usedRect(for: textContainer).height)
    )
    scrollView.tile()

    return Scene(
        root: root, scrollView: scrollView, textView: textView,
        layoutManager: layoutManager, textContainer: textContainer,
        ruler: ruler, storage: storage
    )
}

/// Scrolls so document offset `y` sits at the top of the viewport, then lets the
/// ruler see it — in the app that arrives via the bounds-changed notification the
/// ruler subscribes to in its own initialiser.
func scroll(_ scene: Scene, to y: CGFloat) {
    scene.scrollView.contentView.setBoundsOrigin(NSPoint(x: 0, y: y))
    scene.scrollView.reflectScrolledClipView(scene.scrollView.contentView)
    scene.ruler.needsDisplay = true
    scene.textView.needsDisplay = true

    let landed = scene.scrollView.contentView.bounds.origin.y
    check(
        abs(landed - y) < 0.5,
        "the scroll landed where the test asked (\(Int(y)) pt)",
        "asked \(y), clip view is at \(landed) — clamped, so the case below is vacuous"
    )
}

/// How far above the viewport's top edge the label-bearing fragment begins — the
/// quantity that makes the bug possible. Mirrors `drawHashMarksAndLabels`
/// EXACTLY: it walks to the LOGICAL line start and takes that line's FIRST
/// fragment. Using the first visible character's own fragment instead understates
/// the overhang for a wrapped paragraph, where that fragment is a continuation
/// sitting much closer to the viewport than the one the label is centred in.
func topFragmentOverhang(_ scene: Scene) -> CGFloat {
    let visible = scene.textView.visibleRect
    let glyphRange = scene.layoutManager.glyphRange(forBoundingRect: visible, in: scene.textContainer)
    let charRange = scene.layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
    let nsString = scene.textView.string as NSString
    let lineStart = LogicalLine.lineStart(in: nsString, containing: charRange.location)
    let glyphIndex = scene.layoutManager.glyphIndexForCharacter(at: lineStart)
    let fragment = scene.layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
    return visible.minY - (fragment.minY + scene.textView.textContainerOrigin.y)
}

// MARK: - Rasterising

func render(_ scene: Scene) -> (rep: NSBitmapImageRep, scale: Int) {
    guard let rep = scene.root.bitmapImageRepForCachingDisplay(in: scene.root.bounds) else {
        print("  FATAL: could not create a bitmap rep — can AppKit draw here?")
        exit(2)
    }
    scene.root.cacheDisplay(in: scene.root.bounds, to: rep)
    return (rep, rep.pixelsHigh / Int(scene.root.bounds.height))
}

/// Counts painted pixels darker than the threshold within the given device bands.
/// `alphaComponent > 0.5` matters: an unpainted pixel reads back as transparent
/// black and would otherwise count as ink.
///
/// The 0.75 threshold is derived, not guessed. `secondaryLabelColor` in light
/// aqua is sRGB 0 at α ≈ 0.498 over the ruler's `NSColor(white: 0.95)`, so a
/// fully covered pixel composites to ≈ 0.476 and a pixel of coverage `c` to
/// `0.949 × (1 − 0.498c)`. At the 0.6 threshold an earlier version used, a pixel
/// needed ≈ 74 % coverage to register at all, leaving only ~4 qualifying pixels
/// at 1×; 0.75 admits ≈ 42 % coverage and roughly doubles that margin, while
/// still excluding the white chrome (1.0) and the ruler's own background (0.95).
func darkCount(_ rep: NSBitmapImageRep, rows: Range<Int>, cols: Range<Int>) -> Int {
    var n = 0
    for y in rows.clamped(to: 0..<rep.pixelsHigh) {
        for x in cols.clamped(to: 0..<rep.pixelsWide) {
            guard let c = rep.colorAt(x: x, y: y) else { continue }
            if c.alphaComponent > 0.5 && c.brightnessComponent < 0.75 { n += 1 }
        }
    }
    return n
}

/// True when every pixel in the band is identical between the two renders. A
/// count comparison is weaker — two different images can share a dark-pixel
/// count — and the claim being made is that the clip removes ONLY what was
/// outside, which is a statement about pixels, not totals.
func pixelsIdentical(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, rows: Range<Int>, cols: Range<Int>) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
    for y in rows.clamped(to: 0..<a.pixelsHigh) {
        for x in cols.clamped(to: 0..<a.pixelsWide) {
            if a.colorAt(x: x, y: y) != b.colorAt(x: x, y: y) { return false }
        }
    }
    return true
}

/// `rep` row 0 is the TOP row, and the strip occupies the top `chromeHeight`
/// points of the root, so the chrome is exactly the first `chromeHeight × scale`
/// rows.
func chromeRows(scale: Int) -> Range<Int> { 0..<(Int(chromeHeight) * scale) }

/// The device columns the gutter occupies, widened by a point so an antialiased
/// edge cannot fall outside the window we inspect.
func gutterCols(_ scene: Scene, scale: Int) -> Range<Int> {
    0..<((Int(scene.ruler.ruleThickness.rounded(.up)) + 1) * scale)
}

/// Renders twice: once as shipped (production sets `clipsToBounds` in the ruler's
/// initialiser) and once with the clip forced off. The forced-off render is what
/// proves the scenario provokes the bug at all — without it, "nothing paints in
/// the chrome" would also hold for a scroll that landed on a line boundary, or
/// for a ruler that drew nothing whatsoever.
func renderBothWays(_ scene: Scene) -> (shipped: NSBitmapImageRep, unclipped: NSBitmapImageRep, scale: Int) {
    let shipped = render(scene)
    scene.ruler.clipsToBounds = false
    scene.ruler.needsDisplay = true
    let unclipped = render(scene)
    scene.ruler.clipsToBounds = true
    return (shipped.rep, unclipped.rep, shipped.scale)
}

// MARK: - Case 1: a partially scrolled document

section("A partially scrolled document draws no gutter ink in the chrome above it")

let plain = (1...200).map { "line \($0)" }.joined(separator: "\n")
let scene1 = makeScene(text: plain)
// Captured BEFORE any render: `renderBothWays` toggles the property and restores
// it, so reading it later would report the harness's own last write and pass even
// with the fix reverted.
let clipAsConstructed = scene1.ruler.clipsToBounds

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
let chrome1 = chromeRows(scale: r1.scale)

let shippedAbove1 = darkCount(r1.shipped, rows: chrome1, cols: cols1)
let unclippedAbove1 = darkCount(r1.unclipped, rows: chrome1, cols: cols1)

check(
    unclippedAbove1 > 0,
    "the scenario provokes the bug: with the clip off, gutter ink lands in the chrome",
    "dark subpixels in the chrome = \(unclippedAbove1) (0 would make the next check vacuous)"
)
check(
    shippedAbove1 == 0,
    "as shipped, NO gutter ink lands in the chrome",
    "dark subpixels in the chrome = \(shippedAbove1)"
)

// The clip may remove only what was outside — asserted pixel-for-pixel, over the
// FULL width, so a clip that ate into the text would be caught too.
let paneRows1 = (Int(chromeHeight) * r1.scale)..<r1.shipped.pixelsHigh
let allCols1 = 0..<r1.shipped.pixelsWide
check(
    pixelsIdentical(r1.shipped, r1.unclipped, rows: paneRows1, cols: allCols1),
    "the clip removes ONLY the overflow — in-pane pixels are identical, not merely equal in count"
)
check(
    darkCount(r1.shipped, rows: paneRows1, cols: allCols1) > 0,
    "the editor actually drew something in the pane"
)

// The topmost partially visible line's number must still be DRAWN, clipped at the
// pane's edge — not skipped, not re-centred. This is the ONLY assertion in the
// suite that rules out a "skip any label whose fragment starts above the
// viewport" implementation, so it is load-bearing rather than decorative.
let topSliver1 = (Int(chromeHeight) * r1.scale)..<(Int(chromeHeight) * r1.scale + 3 * r1.scale)
check(
    darkCount(r1.shipped, rows: topSliver1, cols: cols1) > 0,
    "the top line's number survives as a clipped sliver rather than disappearing",
    "dark subpixels in the top 3 pt of the gutter = \(darkCount(r1.shipped, rows: topSliver1, cols: cols1))"
)

// MARK: - Case 2: scrolled into the middle of a wrapped paragraph

section("A wrapped paragraph cannot fling its number into the chrome")

// The walk starts at the LOGICAL line start of the first visible character, so
// scrolling into a paragraph that wraps to many fragments puts the label at that
// paragraph's FIRST fragment — rows above the viewport, not a hair over the
// boundary. This is the case that would paint a number well inside the header
// strip rather than merely over its hairline.
let longParagraph = String(repeating: "wrapped paragraph text ", count: 60)
let scene2 = makeScene(text: "first line\n" + longParagraph + "\nlast line", wrapWidth: 120)

let usedHeight2 = scene2.layoutManager.usedRect(for: scene2.textContainer).height
check(
    usedHeight2 > totalHeight * 2,
    "the paragraph really does wrap well past one viewport",
    "used height \(usedHeight2)"
)

// A CONTROLLED distance into the paragraph, not its middle: the overhang grows
// with how far in you scroll, and at half the document it is hundreds of points,
// which puts the escaped label above the scene's bitmap entirely where no
// assertion can see it. 24 pt is more than one 16 pt line height, so the case
// still shows the overflow is not bounded by a single line, while landing inside
// the strip this harness inspects.
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
let chrome2 = chromeRows(scale: r2.scale)

check(
    darkCount(r2.unclipped, rows: chrome2, cols: cols2) > 0,
    "mid-paragraph, the clip-off render puts gutter ink in the chrome",
    "dark subpixels in the chrome = \(darkCount(r2.unclipped, rows: chrome2, cols: cols2))"
)
check(
    darkCount(r2.shipped, rows: chrome2, cols: cols2) == 0,
    "as shipped, mid-paragraph draws no gutter ink in the chrome",
    "dark subpixels in the chrome = \(darkCount(r2.shipped, rows: chrome2, cols: cols2))"
)

let paneRows2 = (Int(chromeHeight) * r2.scale)..<r2.shipped.pixelsHigh
let allCols2 = 0..<r2.shipped.pixelsWide
check(
    pixelsIdentical(r2.shipped, r2.unclipped, rows: paneRows2, cols: allCols2),
    "mid-paragraph, in-pane pixels are identical with and without the clip"
)

// Stated rather than left to be rediscovered: mid-paragraph the shipped gutter is
// BLANK. The paragraph's only label belongs to its first fragment, which is above
// the viewport and now clipped away, and the next logical line starts below
// `visibleRect.maxY` so the loop breaks before reaching it. That is correct — Xcode
// shows no number beside a wrapped continuation either — but it means this case
// CANNOT distinguish "clipped" from "skipped"; case 1's sliver check is what does.
check(
    darkCount(r2.shipped, rows: paneRows2, cols: cols2) == 0,
    "mid-paragraph the shipped gutter is blank, which is the correct behaviour here",
    "gutter ink in pane = \(darkCount(r2.shipped, rows: paneRows2, cols: cols2))"
)

// MARK: - Case 3: the property, and the unscrolled base case

section("The clip is on, and an unscrolled document is unaffected")

check(clipAsConstructed, "the ruler clips to its bounds as CONSTRUCTED, before any test touched it")

let scene3 = makeScene(text: plain)
scroll(scene3, to: 0)
let r3 = renderBothWays(scene3)
let cols3 = gutterCols(scene3, scale: r3.scale)
let chrome3 = chromeRows(scale: r3.scale)
check(
    darkCount(r3.shipped, rows: chrome3, cols: cols3) == 0,
    "an unscrolled document paints nothing in the chrome either"
)
check(
    darkCount(r3.shipped, rows: chrome3, cols: cols3)
        == darkCount(r3.unclipped, rows: chrome3, cols: cols3),
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
