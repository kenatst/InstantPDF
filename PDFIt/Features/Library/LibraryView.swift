import SwiftUI

/// Visual document gallery with search, filter pills, visual grid, and context actions.
struct LibraryView: View {
    var embedded = false

    @State private var records: [StoredPDFRecord] = []
    @State private var searchText = ""
    @State private var selectedFilter: FilterCategory = .all
    @State private var renamingRecord: StoredPDFRecord?
    @State private var newName = ""
    @State private var showingImporter = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    private let storage = StorageManager.shared

    enum FilterCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case web = "Web"
        case photos = "Photos"
        case text = "Text"
        case files = "Files"

        var id: String { rawValue }
    }

    private var filteredRecords: [StoredPDFRecord] {
        var result = records
        if !searchText.isEmpty {
            result = result.filter { $0.displayName.localizedCaseInsensitiveContains(searchText) }
        }
        switch selectedFilter {
        case .all:
            break
        case .web:
            result = result.filter { $0.contentSource == .website || $0.contentSource == .wikipedia || $0.contentSource == .medium || $0.contentSource == .substack || $0.contentSource == .x || $0.contentSource == .reddit || $0.contentSource == .github }
        case .photos:
            result = result.filter { $0.contentSource == .photos }
        case .text:
            result = result.filter { $0.contentSource == .textEditor }
        case .files:
            result = result.filter { $0.contentSource == .files }
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                VStack(spacing: 20) {
                    if !records.isEmpty {
                        filterPillBar
                    }

                    if records.isEmpty {
                        emptyState
                    } else if filteredRecords.isEmpty {
                        noSearchResultsState
                    } else {
                        documentGrid
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 80)
            }

            // Floating Orange Add Button
            Button {
                showingImporter = true
            } label: {
                Image(systemName: "plus")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        Circle()
                            .fill(Theme.Colors.orangeGradient)
                            .shadow(color: Theme.Colors.orangePrimary.opacity(0.4), radius: 10, x: 0, y: 5)
                    )
            }
            .padding(.trailing, 20)
            .padding(.bottom, 24)
            .accessibilityLabel("Create PDF")
        }
        .themeBackground()
        .navigationTitle(embedded ? "Recent" : "Library")
        .searchable(text: $searchText, prompt: "Search PDFs")
        .onAppear { reload() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .alert("Rename", isPresented: Binding(get: { renamingRecord != nil },
                                               set: { if !$0 { renamingRecord = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { performRename() }
            Button("Cancel", role: .cancel) { renamingRecord = nil }
        }
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .library:
                LibraryView(embedded: true)
            case .viewer(let record):
                PDFViewerView(record: record)
            }
        }
    }

    // MARK: - Filter Pills

    private var filterPillBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FilterCategory.allCases) { category in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = category
                        }
                    } label: {
                        Text(category.rawValue)
                            .font(.subheadline.weight(selectedFilter == category ? .bold : .medium))
                            .foregroundStyle(selectedFilter == category ? .white : (colorScheme == .dark ? Color.white.opacity(0.7) : Color.secondary))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(selectedFilter == category ? AnyShapeStyle(Theme.Colors.orangePrimary) : AnyShapeStyle(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "E8EAF0")))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Document Grid (2 Columns)

    private var documentGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(filteredRecords) { record in
                NavigationLink(value: LibraryRoute.viewer(record)) {
                    LibraryGridCard(record: record)
                }
                .buttonStyle(.plain)
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
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 60)
            MascotView(type: .hero, size: 160)
            Text("No PDFs yet")
                .font(.title2.weight(.bold))
                .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))

            Text("Share a webpage, photo, or document from any app and choose PDF It.")
                .font(.subheadline)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
        }
    }

    private var noSearchResultsState: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 80)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Color.secondary)
            Text("No Matching PDFs")
                .font(.headline)
            Text("Try searching with a different filename.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
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

// MARK: - Library Grid Card

private struct LibraryGridCard: View {
    let record: StoredPDFRecord
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // PDF Preview thumbnail
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "F2F4F7"))

                if let image = StorageManager.shared.thumbnailImage(for: record) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: 150)
                        .clipped()
                        .cornerRadius(12)
                } else {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.Colors.orangePrimary.opacity(0.8))
                }
            }
            .frame(height: 150)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    .lineLimit(1)

                HStack {
                    Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                }
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.04), radius: 6, x: 0, y: 3)
        )
    }
}

/// One library row (kept for fallback lists/table presentations).
struct LibraryRow: View {
    let record: StoredPDFRecord
    private let storage = StorageManager.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            thumbnail
                .frame(width: 44, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(record.displayName)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: record.contentSource.symbolName)
                        .font(.caption2)
                    Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Text("·")
                    Text(String(localized: "plural.pages \(record.pageCount)"))
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                }
                .font(.caption)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = storage.thumbnailImage(for: record) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(Theme.Colors.orangePrimary.opacity(0.15))
                Image(systemName: "doc.richtext")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
        }
    }
}
