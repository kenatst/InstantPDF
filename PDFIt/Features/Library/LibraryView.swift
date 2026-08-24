import SwiftUI

/// Library information architecture (V1):
///
///   Toolbar: [Select] [filter menu / + menu]
///   Folder rail (horizontal cards)  →  All PDFs grid
///
/// Selection mode replaces navigation with selection circles and offers
/// Share / Move / Merge / Delete over the exact chosen set. The floating
/// add button was removed deliberately — creation/import lives in the toolbar.
struct LibraryView: View {
    var embedded = false

    @State private var records: [StoredPDFRecord] = []
    @State private var folders: [PDFLibraryFolder] = []
    @State private var folderCounts: [UUID: Int] = [:]
    @State private var searchText = ""
    @State private var selectedFilter: FilterCategory = .all
    @State private var activeFolderID: UUID?
    @State private var renamingRecord: StoredPDFRecord?
    @State private var newName = ""
    @State private var showingImporter = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.pdfItLanguage) private var languageOverride

    // Selection state
    @State private var selectionMode = false
    @State private var selectedIDs: Set<UUID> = []

    // Sheets & dialogs
    @State private var showingCreateFolder = false
    @State private var newFolderName = ""
    @State private var renamingFolder: PDFLibraryFolder?
    @State private var renamedFolderName = ""
    @State private var deleteCandidate: PDFLibraryFolder?
    @State private var showingMergeReorder = false
    @State private var moveSheetRecords: [StoredPDFRecord] = []

    private let storage = StorageManager.shared

    enum FilterCategory: String, CaseIterable, Identifiable {
        case all = "All"
        case web = "Web"
        case photos = "Photos"
        case text = "Text"
        case files = "Files"

        var id: String { rawValue }
    }

    private var visibleRecords: [StoredPDFRecord] {
        var result = records
        if let activeFolderID {
            result = result.filter { $0.folderID == activeFolderID }
        } else {
            // Root shows only unfiled documents; folders carry their own.
            result = result.filter { $0.folderID == nil }
        }
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

    /// Documents eligible for batch operations in the current context.
    private var selectedRecords: [StoredPDFRecord] {
        records.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !records.isEmpty || !folders.isEmpty {
                    filterPillBar
                }

                if !selectionMode {
                    folderRail
                }

                if records.isEmpty && folders.isEmpty {
                    emptyState
                } else if visibleRecords.isEmpty {
                    emptyFolderOrNoResults
                } else {
                    documentGrid
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .themeBackground()
        .navigationTitle(embedded ? "Recent" : "Library")
        .searchable(text: $searchText, prompt: "Search PDFs")
        .toolbar { toolbarContent }
        .onAppear(perform: reload)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reload() }
        }
        .onChange(of: languageOverride) { _, _ in reload() }
        .alert("Rename", isPresented: Binding(get: { renamingRecord != nil },
                                               set: { if !$0 { renamingRecord = nil } })) {
            TextField("Name", text: $newName)
            Button("Save") { performRename() }
            Button("Cancel", role: .cancel) { renamingRecord = nil }
        }
        .alert("New Folder", isPresented: $showingCreateFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { performCreateFolder() }
            Button("Cancel", role: .cancel) { newFolderName = "" }
        }
        .alert("Rename Folder", isPresented: Binding(get: { renamingFolder != nil },
                                                     set: { if !$0 { renamingFolder = nil } })) {
            TextField("Name", text: $renamedFolderName)
            Button("Save") { performRenameFolder() }
            Button("Cancel", role: .cancel) { renamingFolder = nil }
        }
        .sheet(isPresented: $showingMergeReorder) {
            if let ordered = orderedSelectionForMerge() {
                MergeReorderSheet(records: ordered) { mergedOrder in
                    showingMergeReorder = false
                    performMerge(mergedOrder)
                } onCancel: {
                    showingMergeReorder = false
                }
            }
        }
        .sheet(isPresented: Binding(get: { !moveSheetRecords.isEmpty },
                                    set: { if !$0 { moveSheetRecords = [] } })) {
            MoveToFolderSheet(records: moveSheetRecords,
                              folders: folders,
                              currentFolderID: activeFolderID) { destination in
                performMove(moveSheetRecords, to: destination)
                moveSheetRecords = []
            }
        }
        .navigationDestination(for: LibraryRoute.self) { route in
            switch route {
            case .library:
                LibraryView(embedded: true)
            case .viewer(let recordID):
                PDFViewerView(recordID: recordID)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if selectionMode {
                Button("Select All") { toggleSelectAll() }
                Menu {
                    Button {
                        moveSheetRecords = selectedRecords
                    } label: {
                        Label("Move", systemImage: "folder")
                    }
                    .disabled(selectedIDs.isEmpty)

                    Button {
                        showingMergeReorder = true
                    } label: {
                        Label("Merge into One PDF", systemImage: "square.on.square")
                    }
                    .disabled(selectedIDs.count < 2)

                    ShareLink(items: selectedRecords.compactMap { storage.fileURL(for: $0) }) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .disabled(selectedIDs.isEmpty)

                    Button(role: .destructive) {
                        performBatchDelete()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(selectedIDs.isEmpty)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                Button("Done") { exitSelectionMode() }
            } else {
                Menu {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("Import PDF", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        newFolderName = ""
                        showingCreateFolder = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
                Button("Select") { enterSelectionMode() }
            }
        }
    }

    // MARK: - Filter pills

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

    // MARK: - Folder rail

    @ViewBuilder
    private var folderRail: some View {
        if !folders.isEmpty || activeFolderID != nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    folderCard(title: String(localized: "All PDFs"),
                               count: records.filter { $0.folderID == nil }.count,
                               symbol: "tray.full",
                               selected: activeFolderID == nil,
                               isRoot: true)

                    ForEach(folders) { folder in
                        folderCard(title: folder.name,
                                   count: folderCounts[folder.id] ?? 0,
                                   symbol: "folder.fill",
                                   selected: activeFolderID == folder.id,
                                   isRoot: false,
                                   folder: folder)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
    }

    private func folderCard(title: String,
                            count: Int,
                            symbol: String,
                            selected: Bool,
                            isRoot: Bool,
                            folder: PDFLibraryFolder? = nil) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                activeFolderID = isRoot ? nil : folder?.id
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(String(localized: "plural.docs \(count)"))
                        .font(.caption2)
                        .opacity(0.65)
                }
                if let folder {
                    Menu {
                        Button {
                            renamedFolderName = folder.name
                            renamingFolder = folder
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            deleteCandidate = folder
                        } label: {
                            Label("Delete Folder", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.caption2.weight(.bold))
                            .padding(6)
                            .contentShape(Circle())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(selected ? Color.white : (colorScheme == .dark ? Color.white.opacity(0.85) : Color(hex: "3A3C43")))
            .background(
                Capsule()
                    .fill(selected ? AnyShapeStyle(Theme.Colors.orangeGradient) : AnyShapeStyle(colorScheme == .dark ? Theme.Colors.darkCard : Color.white))
                    .shadow(color: colorScheme == .dark ? .black.opacity(0.2) : .black.opacity(0.04), radius: 5, y: 2)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Document grid

    private var documentGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            ForEach(visibleRecords) { record in
                Group {
                    if selectionMode {
                        Button {
                            toggleSelection(record)
                        } label: {
                            SelectableLibraryCard(record: record,
                                                  isSelected: selectedIDs.contains(record.id))
                        }
                        .buttonStyle(.plain)
                    } else {
                        NavigationLink(value: LibraryRoute.viewer(recordID: record.id)) {
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
                            Button {
                                moveSheetRecords = [record]
                            } label: {
                                Label("Move to Folder", systemImage: "folder")
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
        }
    }

    // MARK: - Empty states

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 60)
            MascotView(type: .hero, size: 140)
            VStack(spacing: 6) {
                Text("Your PDFs will appear here.")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                Text("Share a webpage, photo, or document from any app and choose PDF It.")
                    .font(.subheadline)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var emptyFolderOrNoResults: some View {
        let isEmptyFolder = searchText.isEmpty
            && selectedFilter == .all
            && activeFolderID != nil
        VStack(spacing: 12) {
            Spacer(minLength: 70)
            if isEmptyFolder {
                MascotView(type: .hero, size: 92, enableFloatingAnimation: false)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.secondary)
            }
            Text(isEmptyFolder ? "This folder is empty." : "No Matching PDFs")
                .font(.headline)
            Text(isEmptyFolder ? "Move PDFs here with Select, or keep creating." :
                                    "Try searching with a different filename.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Actions

    private func reload() {
        records = storage.fetchRecords()
        folders = storage.fetchFolders()
        folderCounts = storage.folderCounts()
        // A folder deleted by the other process must not stay selected.
        if let activeFolderID, !folders.contains(where: { $0.id == activeFolderID }) {
            self.activeFolderID = nil
        }
    }

    private func performRename() {
        guard let record = renamingRecord else { return }
        _ = try? storage.rename(record, to: newName)
        renamingRecord = nil
        reload()
    }

    private func performCreateFolder() {
        _ = try? storage.createFolder(named: newFolderName)
        newFolderName = ""
        reload()
    }

    private func performRenameFolder() {
        guard let folder = renamingFolder else { return }
        _ = try? storage.renameFolder(folder, to: renamedFolderName)
        renamingFolder = nil
        reload()
    }

    // MARK: - Selection

    private func enterSelectionMode() {
        selectionMode = true
        selectedIDs = []
    }

    private func exitSelectionMode() {
        selectionMode = false
        selectedIDs = []
    }

    private func toggleSelection(_ record: StoredPDFRecord) {
        if selectedIDs.contains(record.id) {
            selectedIDs.remove(record.id)
        } else {
            selectedIDs.insert(record.id)
        }
    }

    private func toggleSelectAll() {
        let visible = Set(visibleRecords.map(\.id))
        if visible.isSubset(of: selectedIDs) {
            selectedIDs.subtract(visible)
        } else {
            selectedIDs.formUnion(visible)
        }
    }

    private func performBatchDelete() {
        for record in selectedRecords {
            try? storage.delete(record)
        }
        selectedIDs.removeAll()
        reload()
    }

    private func performMove(_ targets: [StoredPDFRecord], to folderID: UUID?) {
        try? storage.move(records: targets, toFolder: folderID)
        exitSelectionMode()
        reload()
    }

    /// Selection order preserved for merge; nil until the sheet can open.
    private func orderedSelectionForMerge() -> [StoredPDFRecord]? {
        let chosen = selectedRecords
        guard chosen.count >= 2 else { return nil }
        return chosen.sorted { $0.createdAt > $1.createdAt }
    }

    private func performMerge(_ ordered: [StoredPDFRecord]) {
        let chunks = ordered.compactMap { record -> Data? in
            guard let url = storage.fileURL(for: record),
                  let data = try? Data(contentsOf: url) else { return nil }
            return data
        }
        guard chunks.count >= 2,
              let merged = try? PDFAssembly.merge(chunks) else { return }
        let title = String(localized: "Merged PDF")
        let stamped = PersonalizationApplier.applyingMetadata(to: merged,
                                                              title: title,
                                                              author: nil,
                                                              sourceURL: nil,
                                                              keepExistingTitleWhenEmpty: false)
        let document = ConvertedDocument(data: stamped,
                                         pageCount: PDFAssembly.pageCount(of: stamped),
                                         suggestedTitle: title,
                                         sourceURL: nil,
                                         source: ordered[0].contentSource == ordered[1].contentSource
                                            ? ordered[0].contentSource
                                            : .mixed)
        _ = try? storage.save(document: document)
        exitSelectionMode()
        reload()
    }
}

// MARK: - Selectable card

private struct SelectableLibraryCard: View {
    let record: StoredPDFRecord
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LibraryGridCard(record: record, showBadge: false)
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Theme.Colors.orangePrimary : Color.white.opacity(colorScheme == .dark ? 0.25 : 0.9))
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.black))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(colorScheme == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.15), lineWidth: 1))
                .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Colors.orangePrimary : .clear, lineWidth: 2)
            )
    }
}
