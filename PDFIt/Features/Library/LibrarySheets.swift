import SwiftUI

/// Reorder sheet before merging: drag the chosen PDFs into the exact page
/// order the merged document should have. Originals are never modified.
struct MergeReorderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var ordered: [StoredPDFRecord]
    let onConfirm: ([StoredPDFRecord]) -> Void
    let onCancel: () -> Void

    init(records: [StoredPDFRecord],
         onConfirm: @escaping ([StoredPDFRecord]) -> Void,
         onCancel: @escaping () -> Void) {
        _ordered = State(initialValue: records)
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(ordered) { record in
                        HStack(spacing: 12) {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(record.displayName)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(String(localized: "plural.pages \(record.pageCount)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { source, destination in
                        ordered.move(fromOffsets: source, toOffset: destination)
                    }
                } header: {
                    Text("Drag to set the order of pages in the merged PDF.")
                } footer: {
                    Text("The originals stay untouched — a new PDF is created.")
                }
            }
            .navigationTitle("Merge PDFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Merge") {
                        onConfirm(ordered)
                        dismiss()
                    }
                    .disabled(ordered.count < 2)
                }
            }
            .environment(\.editMode, .constant(.active))
        }
        .presentationDetents([.medium, .large])
    }
}

/// Choose an existing folder (or root) for the selected documents.
struct MoveToFolderSheet: View {
    @Environment(\.dismiss) private var dismiss
    let records: [StoredPDFRecord]
    let folders: [PDFLibraryFolder]
    let currentFolderID: UUID?
    let onMove: (UUID?) -> Void

    var body: some View {
        NavigationStack {
            List {
                if currentFolderID != nil {
                    Button {
                        onMove(nil)
                        dismiss()
                    } label: {
                        Label("Library Root", systemImage: "tray.full")
                    }
                }
                ForEach(folders) { folder in
                    Button {
                        onMove(folder.id)
                        dismiss()
                    } label: {
                        HStack {
                            Label(folder.name, systemImage: "folder.fill")
                                .foregroundStyle(.primary)
                            Spacer()
                            if folder.id == currentFolderID && records.allSatisfy({ $0.folderID == folder.id }) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Theme.Colors.orangePrimary)
                            }
                        }
                    }
                    .disabled(folder.id == currentFolderID && records.allSatisfy { $0.folderID == folder.id })
                }
                if folders.isEmpty || currentFolderID == nil {
                    // Still allow filing from root when no folder exists yet:
                    // the disabled state communicates why nothing else is listed.
                    Text("Create a folder with + → New Folder first.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Move \(records.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
