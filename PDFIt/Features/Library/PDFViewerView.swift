import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// The tool a user activated from the Viewer. Identifiable so
/// `.sheet(item:)` presentation carries stable context.
enum PDFToolKind: String, CaseIterable, Identifiable {
    case tools
    case compress
    case sign
    case extract
    case recognizeText

    var id: String { rawValue }
}

/// Refined dark-chrome PDF Viewer with floating action bar and native document controls.
/// Identity contract: constructed with a persistent record ID, the viewer
/// re-resolves the CURRENT record from storage — rename/move elsewhere can
/// never make this screen show a different document than the one tapped.
struct PDFViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Persistent identity of the document to display.
    let recordID: UUID
    @State private var record: StoredPDFRecord?
    @State private var resolved = false
    @State private var showingRename = false
    @State private var showingDeleteConfirmation = false
    @State private var newName = ""
    @State private var showingExporter = false
    @State private var activeTool: PDFToolKind?
    /// A tool just produced a new document — navigate straight to it.
    @State private var outputID: UUID?

    private let storage = StorageManager.shared

    init(recordID: UUID) {
        self.recordID = recordID
        // Eagerly resolve so first frame already has content when possible.
        _record = State(initialValue: StorageManager.shared.record(withID: recordID))
    }

    private var fileURL: URL? {
        guard let record else { return nil }
        return storage.fileURL(for: record)
    }

    /// True when the resolved record's file exists on disk.
    private var fileIsAvailable: Bool {
        guard let url = fileURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    @ViewBuilder
    private var documentArea: some View {
        if let url = fileURL, fileIsAvailable {
            PDFFileView(url: url)
                .ignoresSafeArea(edges: .bottom)
        } else if resolved {
            ContentUnavailableView("PDF missing",
                                   systemImage: "questionmark.folder",
                                   description: Text("This document is no longer on this device."))
        } else {
            ProgressView()
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            documentArea

            // Bottom Floating Action Capsule
            if fileIsAvailable, record != nil {
                actionCapsule
            }
        }
        .navigationTitle(record?.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .onAppear { resolve() }
        .sheet(item: $activeTool) { tool in
            PDFToolsHostView(recordID: recordID) { createdID in
                // The tool's output IS the next screen — no back-back-Library.
                activeTool = nil
                outputID = createdID
            }
        }
        .navigationDestination(item: $outputID) { id in
            PDFViewerView(recordID: id)
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("Name", text: $newName)
            Button("Save") { performRename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this PDF?", isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let record {
                    try? storage.delete(record)
                }
                dismiss()
            }
        } message: {
            if let record {
                Text(String(localized: "viewer.delete_message \(record.displayName)", bundle: LanguageManager.bundle))
            }
        }
        .fileExporter(isPresented: $showingExporter,
                      document: fileURL.map { TemporaryPDFFile(url: $0) },
                      contentType: .pdf,
                      defaultFilename: record?.filename ?? "Document.pdf") { _ in }
    }

    /// The bottom toolbar capsule, extracted to keep body type-checkable.
    private var actionCapsule: some View {
        HStack(spacing: 24) {
            ShareLink(item: fileURL!) {
                VStack(spacing: 4) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 18, weight: .semibold))
                    Text("Share")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(Theme.Colors.orangePrimary)
            }

            toolButton(symbol: "slider.horizontal.3", title: "PDF Tools") {
                activeTool = .tools
            }

            toolButton(symbol: "folder", title: "Save") {
                showingExporter = true
            }

            Menu {
                Button {
                    newName = record?.displayName ?? ""
                    showingRename = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    printDocument()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                Button(role: .destructive) {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 18, weight: .semibold))
                    Text("More")
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: "111215"))
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
        .background(
            Capsule()
                .fill(colorScheme == .dark ? Theme.Colors.darkCard.opacity(0.95) : Color.white.opacity(0.95))
                .overlay(
                    Capsule()
                        .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: colorScheme == .dark ? Color.black.opacity(0.4) : Color.black.opacity(0.1), radius: 14, x: 0, y: 6)
        )
        .padding(.bottom, 20)
    }

    private func toolButton(symbol: String, title: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.medium))
            }
            .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: "111215"))
        }
        .accessibilityLabel(title)
    }

    /// Re-resolves the record from storage by persistent ID.
    private func resolve() {
        record = storage.record(withID: recordID)
        resolved = true
    }

    private func performRename() {
        guard let record else { return }
        if let updated = try? storage.rename(record, to: newName) {
            self.record = updated
        }
    }

    private func printDocument() {
        guard let url = fileURL, let document = PDFDocument(url: url) else { return }
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = document
        controller.present(animated: true)
    }
}

/// A PDFView bound to a file URL (keeps memory behavior identical to
/// PDFKit's own document loading).
struct PDFFileView: UIViewRepresentable {
    let url: URL
    @Environment(\.colorScheme) private var colorScheme

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = colorScheme == .dark ? UIColor(Color(hex: "0D0E12")) : UIColor(Color(hex: "EFEFF4"))
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        view.backgroundColor = colorScheme == .dark ? UIColor(Color(hex: "0D0E12")) : UIColor(Color(hex: "EFEFF4"))
    }
}

/// Bridges a stored file into SwiftUI's fileExporter.
struct TemporaryPDFFile: FileDocument {
    static var readableContentTypes: [UTType] = [.pdf]

    private let data: Data

    init(url: URL) {
        self.data = (try? Data(contentsOf: url)) ?? Data()
    }

    init(configuration: ReadConfiguration) throws {
        self.data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
