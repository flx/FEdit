//
//  FindBar.swift
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

import SwiftUI

/// (editor-find) The find bar (SPEC §6.5): a query field, the visible **Case sensitive** checkbox,
/// the `3 of 17` / `Not found` readout, and Done. Rendered by `ContentView.editorColumn` between
/// the column header strip and the editor, only while `workspace.isFindBarVisible`.
///
/// **A SwiftUI view in the editor column, not an AppKit bar inside the scroll view (D7).** Once the
/// find state has to live on `WorkspaceModel` (D3 — the editor coordinator is destroyed on a
/// Markdown↔non-Markdown switch), a SwiftUI bar bound straight to that model is strictly simpler
/// than an AppKit bar mirroring it, and it keeps the focus handoff *inside SwiftUI's own focus
/// system*: Cmd+F moves focus from the sidebar filter field to this one with a `@FocusState` write,
/// never a `makeFirstResponder` call across the SwiftUI/AppKit boundary. `CodeEditorView.makeNSView`
/// keeps returning a plain `NSScrollView`; its signature is untouched by this feature.
///
/// Owns no state of its own — every control is two-way bound to the model, so Esc/Done writing
/// `isFindBarVisible = false` can never desync a private copy. The one exception is the count
/// label, which flows one way (editor → `workspace.findCountLabel` → here).
///
/// Deliberately **no Replace UI** (SPEC §12 keeps replace a non-goal), and deliberately **no
/// Find Previous button** (D6) — note that this is now a statement about the BAR's controls only,
/// not about the feature: (editor-find-previous) added Find Previous as an Edit-menu item on
/// Cmd+Shift+G, and it needs no surface here for the same reason Find Next does not have a button
/// either. The bar's controls stay query field / Case sensitive / count / Done. There is also no
/// Shift+Return route to it, because `.onSubmit` below carries no modifier information.
struct FindBar: View {
    @ObservedObject var workspace: WorkspaceModel

    /// Owned by `ContentView` (which drives it from `workspace.findFocusTick`) and bound in here,
    /// because focus must be settable from *outside* this view: Cmd+F while the bar is already open
    /// has to pull focus back into the field (criterion 17).
    @FocusState.Binding var isQueryFieldFocused: Bool

    /// (editor-find, finding 7) Drives `TextField`'s `selection:` binding (macOS 15+; this app
    /// targets macOS 26) so Cmd+F can select the field's existing contents on (re)focus — the half
    /// of criterion 17 a bare `@FocusState` write cannot reach on its own. `nil` most of the time
    /// (no explicit selection override); set only in the `isQueryFieldFocused` handler below.
    @State private var querySelection: TextSelection?

    /// (editor-find, finding 5, second round) One-shot: true when the NEXT `false -> true` focus
    /// transition should select the field's contents. Starts `true` because `ContentView` only
    /// renders `FindBar` while `workspace.isFindBarVisible`, so this view is freshly mounted every
    /// time the bar opens — the first focus-in on a fresh mount is always the Cmd+F that opened it.
    /// Re-armed by `workspace.findFocusTick` (a later Cmd+F pulling focus back while the bar is
    /// already open, criterion 17) and consumed — read once, then cleared — by the focus handler
    /// below. Nothing else sets it, so a plain click into an already-open, already-focused-once
    /// field (SwiftUI reports that as the same `false -> true` transition `@FocusState` sees on
    /// Cmd+F) leaves it `false` and the click's own caret placement survives — see the doc comment
    /// on the focus handler for the regression this fixes.
    @State private var selectAllOnNextFocus = true

    var body: some View {
        HStack(spacing: 8) {
            // Return submits one Find Next step (SPEC §6.5). `.onSubmit` — not a hidden default
            // button — so Return keeps stepping while the field holds focus, which is the behaviour
            // the item asks for; Cmd+G is the same signal from the menu.
            TextField("Find", text: $workspace.findQuery, selection: $querySelection)
                .textFieldStyle(.roundedBorder)
                .focused($isQueryFieldFocused)
                .onSubmit { workspace.findNextTick += 1 }
                // (editor-find, finding 5, second round) Re-arms `selectAllOnNextFocus` for a LATER
                // Cmd+F: `findFocusTick` only bumps on Cmd+F (never on a click), so this is the
                // signal that distinguishes "focus is about to move here because of Cmd+F" from
                // every other way this field can gain focus.
                .onChange(of: workspace.findFocusTick) {
                    selectAllOnNextFocus = true
                }
                // (editor-find, finding 7; finding 5 second round) Select the whole query on a
                // transition INTO focus, but ONLY when `selectAllOnNextFocus` says it was Cmd+F that
                // caused it — not an arbitrary focus gain. Without the flag, this fired on EVERY
                // false->true transition, which SwiftUI also reports for a plain click into the
                // field: bar open with `foo` typed, click into the editor, then click into the
                // middle of `foo` to fix a typo — the click's own caret placement was overridden by
                // a full-range selection. Guarded on `isQueryFieldFocused` (not the `false` half of
                // `ContentView`'s two-step) so this never fires on the deliberate false->true
                // bounce's `false` leg.
                .onChange(of: isQueryFieldFocused) {
                    if isQueryFieldFocused && selectAllOnNextFocus {
                        querySelection = TextSelection(range: workspace.findQuery.startIndex..<workspace.findQuery.endIndex)
                        selectAllOnNextFocus = false
                    }
                }
                .frame(minWidth: 120, idealWidth: 220, maxWidth: 260)

            // The visible checkbox the item asks for, unchecked by default — the whole reason this
            // is a custom bar and not `NSTextFinder`'s, which buries case-sensitivity in the
            // magnifier popup (D1). `.checkbox` is stated rather than inherited so the control can
            // never render as a switch under a different `.toggleStyle` in an enclosing view.
            Toggle("Case sensitive", isOn: $workspace.findCaseSensitive)
                .toggleStyle(.checkbox)

            // Fixed leading-aligned width so the controls beside it do not shuffle sideways as the
            // label goes "" → "1 of 17" → "Not found" on every keystroke.
            Text(workspace.findCountLabel)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(minWidth: 90, alignment: .leading)

            Spacer(minLength: 0)

            // Esc closes the bar (SPEC §6.5). `.cancelAction` covers Esc while focus is in the
            // query field; Esc while focus is in the *editor text* is covered on the AppKit side by
            // `FindableTextView.cancelOperation(_:)` — the two together are criterion 18.
            Button("Done") {
                workspace.closeFindBar()
            }
            .keyboardShortcut(.cancelAction)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .windowBackgroundColor))
        // Same hairline the column header strips carry, so the bar reads as chrome above the text
        // rather than as content inside it.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: LayoutMetrics.dividerLineWidth)
        }
    }
}
