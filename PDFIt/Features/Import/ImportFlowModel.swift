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
    /// Staged by the Customize sheet; applied to the NEXT conversion.
    @Published var customization = PDFCustomization()
    /// Reorderable image URLs for multi-image imports (Customize sheet).
    @Published var pendingImageOrder: [URL] = []
    @Published var showingCustomize = false

    private var pendingItems: [IncomingItem] = []
    private var conversionTask: Task<Void, Never>?
    private let storage = StorageManager.shared
    /// Owns staged files for the current import. Kept alive while items may
    /// still be read (conversion, retry); cleaned on success, cancellation,
    /// or when a new import starts.
    private var stagingSession: TempFileStore?

    func handlePhotoSelections() {
        let selections = photoSelections
        photoSelections = []
        guard !selections.isEmpty else { return }

        beginNewStagingSession()
        guard let store = stagingSession else { return }
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

        beginNewStagingSession()
        guard let store = stagingSession else { return }
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
        // Multi-image import: expose the order for reordering in Customize.
        let imageItems = items.filter(\.isImage)
        if imageItems.count > 1,
           case .image = items[0].kind {
            pendingImageOrder = imageItems.compactMap { item in
                if case .image(let url) = item.kind { return url }
                return nil
            }
        } else {
            pendingImageOrder = []
        }

        runConversion(items: items)
    }

    /// The actual engine call, split out so Retry and post-Customize
    /// conversion reuse the exact same path.
    private func runConversion(items: [IncomingItem]) {
        pendingItems = items

        var options = ConversionOptions.fromSharedDefaults()
        options.includeSourceURL = options.includeSourceURL || customization.includeSourceURLFooter
        options.includeCreationDate = options.includeCreationDate || customization.includeCreationDateFooter
        let coordinator = ConversionCoordinator()
        isConverting = true
        stage = .analyzing

        // Reordered images replace the original item order.
        let effectiveItems = orderedImageItems(original: items)

        conversionTask = Task { [weak self] in
            coordinator.onStageChange = { stage in
                Task { @MainActor in self?.stage = stage }
            }
            do {
                let document = try await coordinator.convert(items: effectiveItems,
                                                             options: options,
                                                             customization: self?.customization ?? PDFCustomization())
                _ = try? self?.storage.save(document: document)
                // Success: staged files are no longer needed.
                self?.cleanStaging()
                self?.result = document
                self?.isConverting = false
                self?.showingResult = true
                self?.customization = PDFCustomization()
                self?.pendingImageOrder = []
            } catch is CancellationError {
                self?.isConverting = false
            } catch let error as ConversionError where error == .cancelled {
                self?.isConverting = false
            } catch let error as ConversionError {
                self?.failure = error
                self?.isConverting = false
                self?.showingError = true
            } catch {
                self?.failure = .generationFailed
                self?.isConverting = false
                self?.showingError = true
            }
        }
    }

    /// Applies the user's image ordering (if any) to the item list.
    private func orderedImageItems(original: [IncomingItem]) -> [IncomingItem] {
        guard !pendingImageOrder.isEmpty else { return original }
        var result: [IncomingItem] = []
        var usedIndices = Set<Int>()
        for url in pendingImageOrder {
            if let index = original.firstIndex(where: { item in
                if case .image(let itemURL) = item.kind { return itemURL == url }
                return false
            }), !usedIndices.contains(index) {
                result.append(original[index])
                usedIndices.insert(index)
            }
        }
        for (index, item) in original.enumerated() where !usedIndices.contains(index) {
            result.append(item)
        }
        return result
    }

    /// Starts a fresh staging session, releasing whatever a previous import
    /// left behind. Files from a FAILED conversion are kept until this point
    /// so Retry keeps working.
    private func beginNewStagingSession() {
        cleanStaging()
        stagingSession = TempFileStore()
    }

    private func cleanStaging() {
        stagingSession?.cleanUp()
        stagingSession = nil
    }

    func retry() {
        convert(items: pendingItems)
    }

    func cancel() {
        conversionTask?.cancel()
        cleanStaging()
        isConverting = false
    }

    /// Opens the Customize sheet pre-filled for the pending items.
    func prepareCustomization() {
        showingCustomize = true
    }
}

/// Paste-a-link sheet with premium card design.
struct LinkEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var text = ""
    @State private var showClipboardSuggestion = true
    let onConvert: (URL) -> Void
    /// Optional "Customize First" path — opens the Customize sheet with the URL staged.
    var onCustomize: ((URL) -> Void)? = nil

    /// Staged for the customize flow; consumed by HomeView.
    @State private var pendingCustomizeURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Enter Web URL")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))

                    HStack(spacing: 12) {
                        Image(systemName: "link")
                            .font(.system(size: 18))
                            .foregroundStyle(Theme.Colors.orangePrimary)

                        TextField("https://example.com/article", text: $text)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "F2F4F7"))
                    )

                    if detectedHost != nil {
                        Text("Will load from \(detectedHost ?? "")")
                            .font(.caption)
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)
                    }

                    Text("The page loads directly from its source website on your device, then converts to PDF.")
                        .font(.caption)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)
                        .padding(.horizontal, 4)
                        .padding(.top, 4)
                }
                .premiumCard()

                Button {
                    if let url = normalizedURL() {
                        dismiss()
                        onConvert(url)
                    }
                } label: {
                    Text("Create PDF")
                }
                .primaryOrangeButton()
                .disabled(normalizedURL() == nil)

                if let onCustomize {
                    Button {
                        if let url = normalizedURL() {
                            pendingCustomizeURL = url
                            onCustomize(url)
                        }
                    } label: {
                        Text("Customize First…")
                            .font(.subheadline.weight(.semibold))
                    }
                    .secondaryDarkButton()
                    .disabled(normalizedURL() == nil)
                }

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .themeBackground()
            .navigationTitle("Paste Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
            }
            // iOS paste-privacy contract: `hasStrings` never triggers the
            // system paste banner and reads nothing. Only the explicit
            // Paste tap reads the pasteboard.
            .overlay(alignment: .top) {
                if showClipboardSuggestion, text.isEmpty,
                   UIPasteboard.general.hasStrings {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.on.clipboard")
                        Text("Paste copied link?")
                            .font(.footnote.weight(.medium))
                        Spacer()
                        Button("Paste") {
                            let candidate = UIPasteboard.general.string?
                                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            if Self.looksLikeURL(candidate) {
                                text = candidate
                            }
                            showClipboardSuggestion = false
                        }
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Theme.Colors.orangePrimary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "F2F4F7"))
                    )
                    .padding(.horizontal, 20)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private var detectedHost: String? {
        guard let url = normalizedURL() else { return nil }
        return url.host
    }

    static func looksLikeURL(_ candidate: String) -> Bool {
        var value = candidate.lowercased()
        if !value.hasPrefix("http://") && !value.hasPrefix("https://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), url.host != nil else { return false }
        return url.host?.contains(".") == true
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

/// Paste-text sheet with dark editor card.
struct TextEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var title = ""
    @State private var text = ""
    let onConvert: (String, String?) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Title (Optional)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)

                        TextField("Meeting Notes", text: $title)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "F2F4F7"))
                            )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Content")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)

                        TextEditor(text: $text)
                            .frame(minHeight: 160)
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(colorScheme == .dark ? Theme.Colors.darkCardSecondary : Color(hex: "F2F4F7"))
                            )
                    }
                }
                .premiumCard()

                Button {
                    dismiss()
                    onConvert(text, title.isEmpty ? nil : title)
                } label: {
                    Text("Convert to PDF")
                }
                .primaryOrangeButton()
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .themeBackground()
            .navigationTitle("Paste Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
            }
        }
    }
}

/// Celebratory Success sheet featuring the mascot and finished document card.
struct ConversionResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let document: ConvertedDocument

    @State private var shareURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Spacer(minLength: 10)

                // Mascot Celebratory Hero with Particle Sparks
                ZStack {
                    AmberSparkParticles()
                    MascotView(type: .success, size: 145)
                }
                .frame(height: 155)

                VStack(spacing: 6) {
                    Text("PDF Created! 🎉")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))

                    Text("Your PDF is ready and saved to your library.")
                        .font(.subheadline)
                        .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.secondary)
                }

                // Document Metadata Card (slight overlap with mascot)
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Theme.Colors.orangePrimary.opacity(0.15))
                            .frame(width: 48, height: 60)
                        Image(systemName: "doc.text.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(FilenameGenerator.baseName(for: document))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                            .lineLimit(1)

                        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(document.data.count), countStyle: .file)
                        Text(String(localized: "preview.pages_and_size \(document.pageCount) \(sizeText)"))
                            .font(.caption)
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.6) : Color.secondary)
                    }

                    Spacer()
                }
                .premiumCard()

                Spacer()

                // Actions
                VStack(spacing: 12) {
                    if let shareURL {
                        ShareLink(item: shareURL) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text("Share PDF")
                            }
                        }
                        .primaryOrangeButton()
                    }

                    Button("Done") {
                        dismiss()
                    }
                    .secondaryDarkButton()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .themeBackground()
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                TempFileStore.purgeExportArtifacts()
                let url = TempFileStore.exportURL(named: FilenameGenerator.fileName(for: document))
                try? document.data.write(to: url, options: .atomic)
                shareURL = url
            }
        }
    }
}

/// Human error sheet with empathetic mascot and clear recovery paths.
struct ConversionErrorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    let error: ConversionError
    let onRetry: () -> Void
    let offerLinkAsPDF: Bool
    let onSaveLinkAsPDF: (() -> Void)?

    var body: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 10)

            // Empathetic Mascot with no looping motion for error state
            MascotView(type: .error, size: 135, enableFloatingAnimation: false)

            VStack(spacing: 6) {
                Text(error.headline)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    .multilineTextAlignment(.center)

                Text(error.message)
                    .font(.subheadline)
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.7) : Color.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }

            Spacer()

            VStack(spacing: 12) {
                Button("Retry") {
                    dismiss()
                    onRetry()
                }
                .primaryOrangeButton()

                if offerLinkAsPDF, let onSaveLinkAsPDF {
                    Button("Save Link as PDF") {
                        dismiss()
                        onSaveLinkAsPDF()
                    }
                    .secondaryDarkButton()
                }

                Button("Cancel") {
                    dismiss()
                }
                .secondaryDarkButton()
            }
        }
        .padding(24)
        .themeBackground()
        .presentationDetents([.medium, .large])
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
