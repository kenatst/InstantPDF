import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Home: the pitch, the fastest path into a conversion, and what you
/// made recently. Nothing else competes for attention.
struct HomeView: View {
    @Binding var showingSettings: Bool

    @StateObject private var importer = ImportFlowModel()

    @State private var records: [StoredPDFRecord] = []

    private let storage = StorageManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                importSection
                recentSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 32)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("PDF It")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .onAppear { reloadRecords() }
        // The Share Extension writes from a separate process: refresh on
        // every activation so its documents appear without a relaunch.
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

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            Text("Anything → PDF")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            Text("Turn photos, webpages, text and files into PDFs instantly.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 12)
    }

    private var importSection: some View {
        VStack(spacing: 14) {
            Button {
                importer.showingFileImporter = true
            } label: {
                Label("Import File", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack(spacing: 12) {
                PhotosPicker(selection: $importer.photoSelections,
                             matching: .images) {
                    Label("Photos", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Import photos")

                Button {
                    importer.showingLinkEntry = true
                } label: {
                    Label("Link", systemImage: "link")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button {
                    importer.showingTextEntry = true
                } label: {
                    Label("Text", systemImage: "note.text")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
            }

            Text("Or share something from any app and choose PDF It.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var recentSection: some View {
        if !records.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Recent PDFs")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    NavigationLink(value: LibraryRoute.library) {
                        Text("See All")
                            .font(.subheadline.weight(.medium))
                    }
                }
                .accessibilityAddTraits(.isHeader)

                VStack(spacing: 0) {
                    ForEach(records.prefix(5)) { record in
                        NavigationLink(value: LibraryRoute.viewer(record)) {
                            LibraryRow(record: record)
                        }
                        .buttonStyle(.plain)
                        if record.id != records.prefix(5).last?.id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
