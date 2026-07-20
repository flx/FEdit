//
//  NewFileSheet.swift
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

/// The File → New… sheet (SPEC §7, §10): a filename field (focused on appear), a caption showing
/// the target directory (`~`-abbreviated, like the sidebar header), an inline error line, and
/// Create/Cancel buttons. Presented per window through `WorkspaceModel.isPresentingNewFileSheet`,
/// which ContentView binds to `.sheet(isPresented:)`.
///
/// Create is the **single submission source** — the default action (Return), disabled while the
/// trimmed name is empty — so Return is inert until a name is typed and can never double-submit
/// (there is deliberately no `.onSubmit` on the field). On success the sheet dismisses and
/// ContentView's `onDismiss` opens the new file; on any failure the sheet stays open with the
/// inline error.
struct NewFileSheet: View {
    @ObservedObject var workspace: WorkspaceModel

    @State private var filename = ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New File")
                .font(.headline)

            Text("Create in \(targetDirectoryCaption)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)

            TextField("File name", text: $filename)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    workspace.isPresentingNewFileSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        // Focus-on-appear is a known-flaky macOS pattern (the field may not be in the window
        // hierarchy yet), so this can intermittently fail to take — acceptable for v1.
        .onAppear { fieldFocused = true }
        // Clear a stale validation error as soon as the user edits the name, so a prior error
        // (e.g. from a "/"-containing name) doesn't linger over an empty or corrected field.
        .onChange(of: filename) { errorMessage = nil }
    }

    /// The target directory shown in the caption, `~`-abbreviated (matching the sidebar header
    /// style). Empty only in the unreachable-while-presented no-target case.
    private var targetDirectoryCaption: String {
        (workspace.newFileTargetDirectory?.path as NSString?)?.abbreviatingWithTildeInPath ?? ""
    }

    /// The single submission path (SPEC §7): create the file, then dismiss on success (ContentView's
    /// `onDismiss` opens it), or show the inline error and keep the sheet open on failure.
    private func create() {
        let result = workspace.createFile(named: filename)
        if case .created = result {
            workspace.isPresentingNewFileSheet = false
        } else {
            errorMessage = result.message
        }
    }
}
