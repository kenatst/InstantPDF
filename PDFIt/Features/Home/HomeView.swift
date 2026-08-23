import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Home: premium branded header, hero with the mascot breaking the card
/// boundary, four mascot source cards, recent work. No giant app-name
/// navigation title — the brand lockup IS the header.
struct HomeView: View {
    @Binding var showingSettings: Bool

    @StateObject private var importer = ImportFlowModel()
    @State private var records: [StoredPDFRecord] = []
    /// Hero tap opens the polished source chooser instead of guessing.
    @State private var showingSourceChooser = false

    private let storage = StorageManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                brandHeader
                    .padding(.top, 8)

                heroCard

                actionGrid

                recentSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .themeBackground()
        .toolbar(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.subheadline)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.8) : Color(hex: "1C1D22"))
                        .padding(8)
                        .background(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), in: Circle())
                }
                .accessibilityLabel("Settings")
            }
        }
        .onAppear { reloadRecords() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { reloadRecords() }
        }
        .onChange(of: importer.photoSelections) { _, _ in
            importer.handlePhotoSelections()
        }
        .fileImporter(isPresented: $importer.showingFileImporter,
                      allowedContentTypes: [.image, .pdf, .text, .plainText, .html, .rtf],
                      allowsMultipleSelection: true) { result in
            importer.handleFileImporter(result: result)
        }
        .sheet(isPresented: $showingSourceChooser) {
            SourceChooserSheet { source in
                showingSourceChooser = false
                switch source {
                case .photos: importer.showingPhotoPicker = true
                case .link: importer.showingLinkEntry = true
                case .text: importer.showingTextEntry = true
                case .files: importer.showingFileImporter = true
                }
            }
        }
        .sheet(isPresented: $importer.showingPhotoPicker) {
            PhotosPickerSheet(selection: $importer.photoSelections)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $importer.showingResult) {
            if let result = importer.result {
                ConversionResultSheet(document: result)
            }
        }
        .sheet(isPresented: $importer.showingError) {
            if let error = importer.failure {
                ConversionErrorSheet(error: error,
                                     onRetry: { importer.retry() },
                                     offerLinkAsPDF: false,
                                     onSaveLinkAsPDF: nil)
            }
        }
        .sheet(isPresented: $importer.showingCustomize) {
            CustomizePDFSheet(customization: $importer.customization,
                              imageOrder: importer.pendingImageOrder.count > 1
                                ? Binding(get: { importer.pendingImageOrder },
                                          set: { importer.pendingImageOrder = $0 })
                                : nil)
        }
        .sheet(isPresented: $importer.showingLinkEntry) {
            LinkEntrySheet { url in
                importer.convert(items: [IncomingItem(kind: .url(url),
                                                      sourceURL: url,
                                                      source: ContentSource.detect(from: url))])
            } onCustomize: { url in
                importer.showingLinkEntry = false
                importer.showingCustomize = true
                _ = url
            }
        }
        .sheet(isPresented: $importer.showingTextEntry) {
            TextEntrySheet { text, title in
                importer.convert(items: [IncomingItem(kind: .text(text),
                                                      title: title,
                                                      source: .textEditor)])
            }
        }
    }

    // MARK: - Compact brand lockup (replaces the giant nav title)

    private var brandHeader: some View {
        HStack(spacing: 10) {
            MascotView(type: .hero, size: 34, enableFloatingAnimation: false)
                .accessibilityHidden(true)
            Text("PDF It")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .kerning(0.2)
                .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Hero card with mascot escaping the boundary

    private var heroCard: some View {
        Button {
            showingSourceChooser = true
        } label: {
            ZStack(alignment: .trailing) {
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Anything → PDF")
                            .font(.system(size: 27, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Text("Photos, webpages, text and files.\nOne beautiful PDF.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineSpacing(2)

                        Text("Create PDF")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Color(hex: "7A2E00"))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Color.white, in: Capsule())
                            .padding(.top, 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .padding(.leading, 22)
                    .padding(.trailing, 108)
                }
                .background(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(Theme.Colors.heroCardGradient)
                        .shadow(color: Theme.Colors.orangePrimary.opacity(0.35), radius: 16, x: 0, y: 7)
                )

                MascotView(type: .hero, size: 138, enableFloatingAnimation: true)
                    .offset(x: 10, y: -26)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create PDF")
        .accessibilityHint("Choose photos, a link, text or files")
    }

    // MARK: - 4 mascot source cards

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            PhotosPicker(selection: $importer.photoSelections, matching: .images) {
                MascotActionCard(category: .photos)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import photos")

            Button {
                importer.showingLinkEntry = true
            } label: {
                MascotActionCard(category: .link)
            }
            .buttonStyle(.plain)

            Button {
                importer.showingTextEntry = true
            } label: {
                MascotActionCard(category: .text)
            }
            .buttonStyle(.plain)

            Button {
                importer.showingFileImporter = true
            } label: {
                MascotActionCard(category: .files)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recent section

    @ViewBuilder
    private var recentSection: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Recent")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    Spacer()
                    NavigationLink(value: LibraryRoute.library) {
                        Text("See All")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                    }
                }
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

                VStack(spacing: 8) {
                    ForEach(records.prefix(5)) { record in
                        NavigationLink(value: LibraryRoute.viewer(record)) {
                            RecentPDFRow(record: record)
                        }
                        .buttonStyle(.plain)
                    }
                }
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
    }

    private func reloadRecords() {
        records = storage.fetchRecords()
    }
}

/// Navigation routes shared by Home and Library.
enum LibraryRoute: Hashable {
    case library
    case viewer(StoredPDFRecord)
}

// MARK: - Source chooser (hero CTA target)

enum ImportSource: String, CaseIterable, Identifiable {
    case photos, link, text, files
    var id: String { rawValue }
}

struct SourceChooserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let onChoose: (ImportSource) -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 20) {
            MascotView(type: .hero, size: 84, enableFloatingAnimation: false)
            VStack(spacing: 4) {
                Text("What are we turning into a PDF?")
                    .font(.headline.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("Pick a source to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(ImportSource.allCases) { source in
                    Button {
                        onChoose(source)
                    } label: {
                        MascotActionCard(category: MascotActionCard.Category(rawValue: source.rawValue) ?? .photos)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
        .themeBackground()
        .presentationDetents([.medium])
    }
}

/// Photos picker as its own sheet so both the card and the chooser can open it.
struct PhotosPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: [PhotosPickerItem]

    var body: some View {
        NavigationStack {
            VStack {
                PhotosPicker(selection: $selection,
                             matching: .images,
                             photoLibrary: .shared()) {
                    Label("Choose Photos", systemImage: "photo.on.rectangle.angled")
                }
                .primaryOrangeButton()
                .padding(20)
                Spacer()
            }
            .themeBackground()
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Mascot source card

struct MascotActionCard: View {
    enum Category: String {
        case photos, link, text, files
    }

    let category: Category
    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        switch category {
        case .photos: return "Photos"
        case .link: return "Link"
        case .text: return "Text"
        case .files: return "Files"
        }
    }

    private var subtitle: String {
        switch category {
        case .photos: return "From Library"
        case .link: return "From URL"
        case .text: return "Write or Paste"
        case .files: return "From Device"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Canonical mascot composed with a native category glyph.
            ZStack(alignment: .bottomTrailing) {
                MascotView(type: .hero, size: 52, enableFloatingAnimation: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                categoryBadge
            }
            .frame(height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.05), lineWidth: 1)
                )
                .shadow(color: colorScheme == .dark ? Color.black.opacity(0.2) : Color.black.opacity(0.03), radius: 6, x: 0, y: 2)
        )
    }

    /// The category glyph sits in a warm tile next to the mascot — one
    /// consistent composition across all four cards.
    private var categoryBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.Colors.orangePrimary.opacity(0.16))
                .frame(width: 34, height: 34)
            Image(systemName: symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.orangePrimary)
        }
    }

    private var symbolName: String {
        switch category {
        case .photos: return "photo.on.rectangle.angled"
        case .link: return "link"
        case .text: return "doc.text"
        case .files: return "folder"
        }
    }
}

// MARK: - Recent PDF Row Component

private struct RecentPDFRow: View {
    let record: StoredPDFRecord
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            if let image = StorageManager.shared.thumbnailImage(for: record) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
                    )
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Theme.Colors.orangePrimary.opacity(0.12))
                        .frame(width: 44, height: 56)
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(record.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(record.createdAt.formatted(date: .abbreviated, time: .omitted))
                    Text("•")
                    Text(String(localized: "plural.pages \(record.pageCount)"))
                    Text("•")
                    Text(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
                }
                .font(.caption2)
                .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Theme.Colors.darkCard : Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.04), lineWidth: 1)
                )
        )
    }
}
