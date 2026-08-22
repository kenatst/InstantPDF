import Foundation
import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

/// Drives in-app imports through the SAME conversion engine the Share
/// Extension uses. No duplicated conversion path.
@MainActor
final class ImportFlowModel: ObservableObject {

    @Published var showingFileImporter = false
    @Published var showingPhotoPicker = false
    @Published var photoSelections: [PhotosPickerItem] = []
    @Published var showingLinkEntry = false
    @Published var showingTextEntry = false
    @Published var showingResult = false
    @Published var showingError = false
    @Published var isConverting = false
    @Published var stage: ConversionStage = .analyzing
    @Published var result: ConvertedDocument?
    @Published var failure: ConversionError?

    private var pendingItems: [IncomingItem] = []
    private var conversionTask: Task<Void, Never>?
    private let storage = StorageManager.shared

    func handlePhotoSelections() {
        let selections = photoSelections
        photoSelections = []
        guard !selections.isEmpty else { return }

        let store = TempFileStore()
        Task { [weak self] in
            var items: [IncomingItem] = []
            for (index, selection) in selections.enumerated() {
                guard let data = try? await selection.loadTransferable(type: Data.self),
                      let url = try? store.stage(data: data, fileExtension: "img") else {
                    continue
                }
                items.append(IncomingItem(kind: .image(url),
                                          originalFilename: nil,
                                          source: .photos,
                                          index: index))
            }
            await MainActor.run { self?.convert(items: items) }
        }
    }

    func handleFileImporter(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, !urls.isEmpty else { return }

        let store = TempFileStore()
        var items: [IncomingItem] = []
        for (index, url) in urls.enumerated() {
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }

            guard let staged = try? store.stage(url) else { continue }
            let fileClass = InputClassification.classify(fileURL: staged)
            switch fileClass {
            case .pdf:
                items.append(IncomingItem(kind: .pdf(staged),
                                          originalFilename: staged.lastPathComponent,
                                          source: .files,
                                          index: index))
            case .image:
                items.append(IncomingItem(kind: .image(staged),
                                          originalFilename: staged.lastPathComponent,
                                          source: .photos,
                                          index: index))
            case .other:
                if let text = try? String(contentsOf: staged, encoding: .utf8),
                   !text.isEmpty,
                   isTextLike(url) {
                    items.append(IncomingItem(kind: .text(text),
                                              title: staged.deletingPathExtension().lastPathComponent,
                                              originalFilename: staged.lastPathComponent,
                                              source: .files,
                                              index: index))
                } else {
                    items.append(IncomingItem(kind: .file(staged),
                                              originalFilename: staged.lastPathComponent,
                                              source: .files,
                                              index: index))
                }
            }
        }
        convert(items: items)
    }

    private func isTextLike(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .plainText)
    }

    func convert(items: [IncomingItem]) {
        guard !items.isEmpty else {
            failure = .noUsableContent
            showingError = true
            return
        }
        pendingItems = items

        let options = ConversionOptions.fromSharedDefaults()
        let coordinator = ConversionCoordinator()
        isConverting = true
        stage = .analyzing

        conversionTask = Task { [weak self] in
            coordinator.onStageChange = { stage in
                Task { @MainActor in self?.stage = stage }
            }
            do {
                let document = try await coordinator.convert(items: items, options: options)
                _ = try? self?.storage.save(document: document)
                self?.result = document
                self?.isConverting = false
                self?.showingResult = true
            } catch let error as ConversionError where error != .cancelled {
                self?.failure = error
                self?.isConverting = false
                self?.showingError = true
            } catch is CancellationError {
                self?.isConverting = false
            } catch {
                self?.failure = .generationFailed
                self?.isConverting = false
                self?.showingError = true
            }
        }
    }

    func retry() {
        convert(items: pendingItems)
    }

    func cancel() {
        conversionTask?.cancel()
        isConverting = false
    }
}

/// Paste-a-link sheet.
struct LinkEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    let onConvert: (URL) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://example.com/article", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("The page loads on your device, then becomes a PDF.")
                }
            }
            .navigationTitle("Paste Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Convert") {
                        if let url = normalizedURL() {
                            dismiss()
                            onConvert(url)
                        }
                    }
                    .disabled(normalizedURL() == nil)
                }
            }
        }
    }

    private func normalizedURL() -> URL? {
        var candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.hasPrefix("http://") && !candidate.hasPrefix("https://") {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }
}

/// Paste-text sheet.
struct TextEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    let onConvert: (String, String?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Title (optional)") {
                    TextField("Notes", text: $title)
                }
                Section("Text") {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                }
            }
            .navigationTitle("Paste Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Convert") {
                        dismiss()
                        onConvert(text, title.isEmpty ? nil : title)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

/// Success sheet after an in-app conversion: preview, share, done.
struct ConversionResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    let document: ConvertedDocument

    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                PDFKitView(data: document.data)
                let sizeText = ByteCountFormatter.string(fromByteCount: Int64(document.data.count),
                                                         countStyle: .file)
                Text("\(document.pageCount) page\(document.pageCount == 1 ? "" : "s") · \(sizeText)")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
            .navigationTitle(FilenameGenerator.baseName(for: document))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share PDF")
                    }
                }
            }
            .onAppear {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(FilenameGenerator.fileName(for: document))
                try? document.data.write(to: url, options: .atomic)
                shareURL = url
            }
        }
    }
}

/// Human error sheet with optional recovery actions.
struct ConversionErrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let error: ConversionError
    let onRetry: () -> Void
    let offerLinkAsPDF: Bool
    let onSaveLinkAsPDF: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(error.headline)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(error.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button("Retry") {
                    dismiss()
                    onRetry()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if offerLinkAsPDF, let onSaveLinkAsPDF {
                    Button("Save Link as PDF") {
                        dismiss()
                        onSaveLinkAsPDF()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.top, 6)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}

/// PDFKit wrapper used across the app.
struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = PDFDocument(data: data)
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .secondarySystemBackground
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data {
            view.document = PDFDocument(data: data)
        }
    }
}
