//
//  ColumnHeaderBar.swift
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

/// A fixed-height column title strip: a single-line, tail-truncated, leading-aligned title with
/// a subtle background and a bottom hairline separator. Owns no state and no visibility logic —
/// the caller decides whether to render it (mirrors `SplitDivider` owning no state).
struct ColumnHeaderBar: View {
    let title: String
    /// Extra leading inset for the title. The editor strip passes the live line-number gutter
    /// width so the file name aligns with the text pane (starting just past the gutter), instead
    /// of sitting over the gutter. Defaults to 0 (sidebar/preview strips use the standard 8 pt).
    var leadingInset: CGFloat = 0

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, max(leadingInset, 8))
            .padding(.trailing, 8)
            .frame(height: LayoutMetrics.columnHeaderHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: LayoutMetrics.dividerLineWidth)
            }
    }
}
