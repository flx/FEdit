//
//  SplitDivider.swift
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

/// A draggable column divider: a thin visible separator line inside a wider (5 pt) hit area,
/// with a `resizeLeftRight` hover cursor. Owns no state and no persistence — clamping and
/// storage live entirely in the consuming view (`ContentView`).
struct SplitDivider: View {
    /// Cumulative horizontal translation since the drag gesture started, in points.
    let onDrag: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: LayoutMetrics.dividerLineWidth)
        }
        .frame(width: LayoutMetrics.dividerHitWidth)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { onDrag($0.translation.width) }
                .onEnded { _ in onDragEnded() }
        )
        // Known SwiftUI wart: if the view disappears (or the pointer otherwise leaves the
        // strip) mid-hover, the matching `.pop()` can be missed, leaving the resize cursor
        // stuck until the next hover event elsewhere. Accepted for v1.
        .onHover { inside in
            if inside {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
