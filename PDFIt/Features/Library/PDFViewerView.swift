import SwiftUI
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Full viewer for a stored PDF: zoom, scroll, share, print, rename, delete,
/// export to Files. Deliberately not an Acrobat clone.
struct PDFViewerView: View {
    @Environment(\.dismiss) private var dismiss

    @State var record: StoredPDFRecord
    @State private var showingRename = false
    @State private var showingDeleteConfirmation = false
    @State private var newName = ""
    @State private var showingExporter = false

    private let storage = StorageManager.shared

    private var fileURL: URL? {
        storage.fileURL(for: record)
    }

    var body: some View {
        Group {
            if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                PDFFileView(url: url)
            } else {
                ContentUnavailableView("PDF missing",
                                       systemImage: "questionmark.folder",
                                       description: Text("This document is no longer on this device."))
            }
        }
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let url = fileURL {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share")
                }

                Menu {
                    Button {
                        newName = record.displayName
                        showingRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        showingExporter = true
                    } label: {
                        Label("Save to Files", systemImage: "folder")
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
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More actions")
            }
        }
        .alert("Rename", isPresented: $showingRename) {
            TextField("Name", text: $newName)
            Button("Save") { performRename() }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this PDF?", isPresented: $showingDeleteConfirmation,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? storage.delete(record)
                dismiss()
            }
        } message: {
            Text(String(localized: "viewer.delete_message \(record.displayName)"))
        }
        .fileExporter(isPresented: $showingExporter,
                      document: fileURL.map { TemporaryPDFFile(url: $0) },
                      contentType: .pdf,
                      defaultFilename: record.filename) { _ in }
    }

    private func performRename() {
        if let updated = try? storage.rename(record, to: newName) {
            record = updated
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

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(url: url)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
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
