import SwiftUI

/// Every PDF the user has made. Documents are kept until explicitly
/// deleted — the list can get long, so search is first-class.
struct LibraryView: View {
    var embedded = false

    @State private var records: [StoredPDFRecord] = []
    @State private var searchText = ""
    @State private var renamingRecord: StoredPDFRecord?
    @State private var newName = ""

    private let storage = StorageManager.shared

    private var filteredRecords: [StoredPDFRecord] {
        guard !searchText.isEmpty else { return records }
        return records.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .navigationTitle(embedded ? "Recent" : "Library")
        .onAppear { reload() }
        .searchable(text: $searchText, prompt: "Search PDFs")
        .alert("Rename", isPresented: Binding(get: { renamingRecord != nil },
                                               set: { if !$0 { renamingRecord = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { performRename() }
            Button("Cancel", role: .cancel) { renamingRecord = nil }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No PDFs yet", systemImage: "doc.text")
        } description: {
            Text("Share something from any app and choose PDF It.")
        }
    }

    private var list: some View {
        List {
            ForEach(filteredRecords) { record in
                NavigationLink(value: LibraryRoute.viewer(record)) {
                    LibraryRow(record: record)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        try? storage.delete(record)
                        reload()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        _ = try? storage.duplicate(record)
                        reload()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                }
                .contextMenu {
                    if let url = storage.fileURL(for: record) {
                        ShareLink(item: url) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button {
                        newName = record.displayName
                        renamingRecord = record
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        _ = try? storage.duplicate(record)
                        reload()
                    } label: {
                        Label("Duplicate", systemImage: "plus.square.on.square")
                    }
                    Button(role: .destructive) {
                        try? storage.delete(record)
                        reload()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .library:
                LibraryView(embedded: true)
            case .viewer(let record):
                PDFViewerView(record: record)
            }
        }
    }

    private func performRename() {
        guard let record = renamingRecord else { return }
        _ = try? storage.rename(record, to: newName)
        renamingRecord = nil
        reload()
    }

    private func reload() {
        records = storage.fetchRecords()
    }
}

/// One library row: thumbnail, name, and the metadata people actually
/// ask for — when, how many pages, how big.
struct LibraryRow: View {
    let record: StoredPDFRecord
    private let storage = StorageManager.shared

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 44, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Image(systemName: record.contentSource.symbolName)
                        .font(.caption2)
                    Text(record.createdAt, format: .dateTime.day().month().year())
                    Text("·")
                    Text("\(record.pageCount) pg")
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize,
                                                   countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = storage.thumbnailImage(for: record) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Color(uiColor: .tertiarySystemFill))
                Image(systemName: "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
