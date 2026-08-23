import SwiftUI
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Refined dark-chrome PDF Viewer with floating action bar and native document controls.
struct PDFViewerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

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
        ZStack(alignment: .bottom) {
            Group {
                if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                    PDFFileView(url: url)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView("PDF missing",
                                           systemImage: "questionmark.folder",
                                           description: Text("This document is no longer on this device."))
                }
            }

            // Bottom Floating Action Capsule
            if let url = fileURL, FileManager.default.fileExists(atPath: url.path) {
                HStack(spacing: 24) {
                    ShareLink(item: url) {
                        VStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Share")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(Theme.Colors.orangePrimary)
                    }

                    Button {
                        showingExporter = true
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Save")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: "111215"))
                    }

                    Button {
                        printDocument()
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "printer")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Print")
                                .font(.caption2.weight(.medium))
                        }
                        .foregroundStyle(colorScheme == .dark ? Color.white : Color(hex: "111215"))
                    }

                    Menu {
                        Button {
                            newName = record.displayName
                            showingRename = true
                        } label: {
                            Label("Rename", systemImage: "pencil")
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
        }
        .navigationTitle(record.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
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
