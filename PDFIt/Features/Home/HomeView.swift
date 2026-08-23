import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Home: Premium character-led dashboard with overlapping mascot hero and quick action grid.
struct HomeView: View {
    @Binding var showingSettings: Bool

    @StateObject private var importer = ImportFlowModel()
    @State private var records: [StoredPDFRecord] = []

    private let storage = StorageManager.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(spacing: 26) {
                heroCard
                    .padding(.top, 14)

                actionGrid
                recentSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .themeBackground()
        .navigationTitle("PDF It")
        .navigationBarTitleDisplayMode(.large)
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
        .sheet(isPresented: $importer.showingLinkEntry) {
            LinkEntrySheet { url in
                importer.convert(items: [IncomingItem(kind: .url(url),
                                                      sourceURL: url,
                                                      source: ContentSource.detect(from: url))])
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

    // MARK: - Hero Card with Overlapping Living Character

    private var heroCard: some View {
        Button {
            importer.showingFileImporter = true
        } label: {
            ZStack(alignment: .trailing) {
                // Main Gradient Card Background
                HStack(alignment: .center, spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Create PDF")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)

                        Text("Photos, webpages, text and files.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.white.opacity(0.92))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 24)
                    .padding(.leading, 20)
                    .padding(.trailing, 110) // Reserve room for overlapping mascot
                }
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Theme.Colors.heroCardGradient)
                        .shadow(color: Theme.Colors.orangePrimary.opacity(0.35), radius: 14, x: 0, y: 6)
                )

                // Overlapping Mascot protruding from top/right edge
                MascotView(type: .hero, size: 134, enableFloatingAnimation: true)
                    .offset(x: 8, y: -20)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - 4 Action Grid (Photos, Link, Text, Files)

    private var actionGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
            // Photos
            PhotosPicker(selection: $importer.photoSelections, matching: .images) {
                ActionCard(icon: "photo.on.rectangle.angled", title: "Photos", subtitle: "From Library")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Import photos")

            // Link
            Button {
                importer.showingLinkEntry = true
            } label: {
                ActionCard(icon: "link", title: "Link", subtitle: "From URL")
            }
            .buttonStyle(.plain)

            // Text
            Button {
                importer.showingTextEntry = true
            } label: {
                ActionCard(icon: "doc.text", title: "Text", subtitle: "Write or Paste")
            }
            .buttonStyle(.plain)

            // Files
            Button {
                importer.showingFileImporter = true
            } label: {
                ActionCard(icon: "folder", title: "Files", subtitle: "From Device")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Recent Section

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

// MARK: - Action Card Component

private struct ActionCard: View {
    let icon: String
    let title: String
    let subtitle: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.Colors.orangePrimary.opacity(0.15))
                    .frame(width: 38, height: 38)
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
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
}

// MARK: - Recent PDF Row Component

private struct RecentPDFRow: View {
    let record: StoredPDFRecord
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            // Thumbnail / Icon
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

            // PDF Badge
            Text("PDF")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Colors.orangePrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.Colors.orangePrimary.opacity(0.15), in: Capsule())
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

/// Navigation routes shared by Home and Library.
enum LibraryRoute: Hashable {
    case library
    case viewer(StoredPDFRecord)
}
