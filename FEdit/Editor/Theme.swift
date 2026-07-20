//
//  Theme.swift
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

import AppKit

/// The app's single light-only palette (SPEC §3: no dark mode / theme switching), shared by the
/// editor's syntax highlighter (`SyntaxHighlighter`) and, later, the Markdown preview renderer.
/// `Theme` is intentionally inert: `static let`/`static func` members only, no reference to
/// `NSTextView`, the highlighter, or any editor state (verified by inspection per the
/// (syntax-highlighting) plan's criterion 10) — that is what lets `markdown-renderer` depend on
/// it without pulling in editor machinery.
enum Theme {
    // MARK: - Fonts

    /// The editor's base font (SPEC §6.1): monospaced system, regular weight, at the requested
    /// point size. Size-parametric (editor-font-zoom): the editor's font is now driven by the
    /// live `@AppStorage(SettingsKey.editorFontSize)` (default 13 pt) rather than a fixed literal,
    /// so callers pass the current size and no window's highlight pass can read another window's
    /// stale global. Keeping this a pure `static func` of its argument preserves `Theme`'s
    /// stateless contract (no mutable shared font state).
    static func editorFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Bold variant of `editorFont(size:)`, used for keywords and Markdown headings/bold spans.
    static func editorBoldFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
    }

    /// A visually slanted variant of `editorFont(size:)` for Markdown italic spans.
    ///
    /// `withSymbolicTraits(.italic)` on a monospaced system font does **not** fail by returning
    /// nil — a failure would hand back a non-italic font, so a nil-fallback alone can't be
    /// trusted. Instead this checks `symbolicTraits.contains(.italic)` on the *result*: if the
    /// resolved descriptor actually reports `.italic`, that real italic face is used; otherwise a
    /// synthesized oblique is produced via `NSFontManager.convert(_:toHaveTrait:)`, which reliably
    /// applies a shear even without a dedicated italic face. The acceptance test is "visually
    /// slanted", not "descriptor non-nil". The real-italic-vs-synthesized-oblique *decision* is
    /// size-invariant (SF Mono has no italic face at any size); only the resolved point size
    /// changes with `size`.
    static func editorItalic(size: CGFloat) -> NSFont {
        let base = editorFont(size: size)
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        let candidate = NSFont(descriptor: descriptor, size: size) ?? base
        if candidate.fontDescriptor.symbolicTraits.contains(.italic) {
            return candidate
        }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// Preview-facing body text font (system, 13 pt) — speculative-but-cheap: kept here so
    /// `markdown-renderer` doesn't grow its own palette file.
    static let bodyFont = NSFont.systemFont(ofSize: 13)

    /// Preview-facing code font (SPEC §8.2), for inline `` `code` `` and fenced blocks in the
    /// rendered Markdown preview. Decoupled from the editor font (editor-font-zoom decision 3):
    /// the editor's zoom scopes to the editor only, so this stays fixed at 13 pt and the preview's
    /// appearance is unchanged. Defined with a literal size on purpose — `Theme` is compiled
    /// standalone by the `markdown-renderer` test harness, so this must not reference any symbol
    /// outside `Theme` (e.g. `EditorMetrics` in `App/FEditApp.swift`).
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    /// Preview-facing heading font, bold system sized by heading level (`1`...`6`, clamped).
    static func headingFont(level: Int) -> NSFont {
        let clampedLevel = min(max(level, 1), 6)
        let sizeByLevel: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 17, 5: 15, 6: 13]
        let size = sizeByLevel[clampedLevel] ?? 13
        return NSFont.boldSystemFont(ofSize: size)
    }

    // MARK: - Colors

    /// Base editor/preview text color: near-black.
    static let text = NSColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)

    /// Base editor/preview background: white.
    static let background = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    /// Keyword token color (§6.3): purple.
    static let keyword = NSColor(srgbRed: 0.60, green: 0.15, blue: 0.60, alpha: 1)

    /// String-literal token color (§6.3): red.
    static let string = NSColor(srgbRed: 0.77, green: 0.10, blue: 0.10, alpha: 1)

    /// Comment token color (§6.3): green.
    static let comment = NSColor(srgbRed: 0.0, green: 0.50, blue: 0.0, alpha: 1)

    /// Numeric-literal token color (§6.3): blue.
    static let number = NSColor(srgbRed: 0.10, green: 0.10, blue: 0.80, alpha: 1)

    /// Markdown heading color: blue.
    static let heading = NSColor(srgbRed: 0.05, green: 0.30, blue: 0.70, alpha: 1)

    /// Markdown link color: link blue.
    static let link = NSColor(srgbRed: 0.10, green: 0.40, blue: 0.90, alpha: 1)

    /// Inline-code / fenced-code-block background: light gray.
    static let codeBackground = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.94, alpha: 1)

    /// Muted/secondary text color — blockquotes and the preview's own gutter-like chrome reuse
    /// this later; not consumed by the editor's own gutter (`LineNumberRulerView` keeps its own
    /// colors per the plan's explicit exclusion).
    static let mutedText = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)

    // MARK: - Convenience

    /// The attribute set a full syntax-highlight reset pass applies before any rule runs —
    /// clears stale bold/color left over from a previous language or a previous pass. Built at the
    /// requested editor font size (editor-font-zoom): the reset pass re-applies the sized base font
    /// across the whole storage so even a `.plain` file scales uniformly.
    static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [.font: editorFont(size: fontSize), .foregroundColor: text]
    }
}
