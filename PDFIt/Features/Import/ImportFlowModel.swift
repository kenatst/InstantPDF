import Foundation
import SwiftUI
import PDFKit
import PhotosUI
import UniformTypeIdentifiers

/// Drives in-app imports through the SAME conversion engine the Share
/// Extension uses. No duplicated conversion path.
@MainActor
final class ImportFlowModel: ObservableObject {

    private enum BackgroundConversionResult {
        case success(ConvertedDocument, UUID)
        case failure(ConversionError)
        case cancelled
    }

    struct PhotoImportIssue: Equatable {
        let loadedCount: Int
        let failedCount: Int
        let totalCount: Int
    }

    private struct IndexedPhotoSelection {
        let index: Int
        let item: PhotosPickerItem
    }

    private enum PhotoStagingOutcome {
        case success(IncomingItem)
        case failure(IndexedPhotoSelection)
    }

    @Published var showingFileImporter = false
    @Published var showingPhotoPicker = false
    @Published var photoSelections: [PhotosPickerItem] = []
    @Published var showingLinkEntry = false
    @Published var showingTextEntry = false
    @Published var showingResult = false
    @Published var showingError = false
    @Published var isConverting = false
    @Published var isLoadingPhotos = false
    @Published var loadedPhotoCount = 0
    @Published var totalPhotoCount = 0
    @Published var photoImportIssue: PhotoImportIssue?
    @Published var stage: ConversionStage = .analyzing
    @Published var result: ConvertedDocument?
    /// Identity returned by StorageManager for the exact document just saved.
    /// Consumed by the presenting surface after the success sheet closes so
    /// navigation never relies on title matching or library ordering.
    @Published private(set) var savedRecordID: UUID?
    @Published var failure: ConversionError?
    /// Staged by the Customize sheet; applied to the NEXT conversion.
    @Published var customization = PDFCustomization()
    /// Reorderable image URLs for multi-image imports (Customize sheet).
    @Published var pendingImageOrder: [URL] = []
    @Published var showingCustomize = false
    /// Free user tapped a Pro-only conversion (link/web).
    @Published var requiresPro: ProFeature?
    @Published var showingPaywall = false
    /// Staged web conversion from "Customize First": URL + explicit options
    /// survive the Customize transition and are used at creation time.
    @Published var stagedWebConversion: (url: URL, options: ConversionOptions)?

    private var pendingItems: [IncomingItem] = []
    /// Explicit per-conversion options (Link sheet). nil = shared defaults.
    private var optionsOverride: ConversionOptions?
    private var conversionTask: Task<Void, Never>?
    private var photoLoadingTask: Task<Void, Never>?
    private let storage = StorageManager.shared
    /// Owns staged files for the current import. Kept alive while items may
    /// still be read (conversion, retry); cleaned on success, cancellation,
    /// or when a new import starts.
    private var stagingSession: TempFileStore?
    private var stagedPhotoItems: [IncomingItem] = []
    private var failedPhotoSelections: [IndexedPhotoSelection] = []

    func handlePhotoSelections() {
        let selections = photoSelections
        photoSelections = []
        guard !selections.isEmpty else { return }

        photoLoadingTask?.cancel()
        beginNewStagingSession()
        guard let store = stagingSession else { return }
        showingPhotoPicker = false
        isLoadingPhotos = true
        loadedPhotoCount = 0
        totalPhotoCount = selections.count
        photoImportIssue = nil
        stagedPhotoItems = []
        failedPhotoSelections = []

        let indexed = selections.enumerated().map {
            IndexedPhotoSelection(index: $0.offset, item: $0.element)
        }
        photoLoadingTask = Task { [weak self] in
            let outcomes = await Self.stagePhotos(indexed,
                                                  in: store,
                                                  progress: { completed in
                await MainActor.run {
                    self?.loadedPhotoCount = completed
                }
            })
            guard !Task.isCancelled, let self else { return }
            self.finishPhotoStaging(outcomes, totalCount: indexed.count)
        }
    }

    /// Retries only the assets Photos could not deliver (commonly iCloud
    /// downloads), while keeping already-staged files and their original
    /// selection indices intact.
    func retryFailedPhotos() {
        guard !failedPhotoSelections.isEmpty,
              let store = stagingSession else { return }
        let retrySelections = failedPhotoSelections
        photoImportIssue = nil
        isLoadingPhotos = true
        loadedPhotoCount = 0
        totalPhotoCount = retrySelections.count

        photoLoadingTask?.cancel()
        photoLoadingTask = Task { [weak self] in
            let outcomes = await Self.stagePhotos(retrySelections,
                                                  in: store,
                                                  progress: { completed in
                await MainActor.run { self?.loadedPhotoCount = completed }
            })
            guard !Task.isCancelled, let self else { return }
            self.finishPhotoStaging(outcomes,
                                    totalCount: self.stagedPhotoItems.count + retrySelections.count,
                                    appending: true)
        }
    }

    func continueWithLoadedPhotos() {
        guard !stagedPhotoItems.isEmpty else { return }
        photoImportIssue = nil
        failedPhotoSelections = []
        convert(items: stagedPhotoItems.sorted { $0.index < $1.index })
    }

    func cancelPhotoImport() {
        photoLoadingTask?.cancel()
        photoLoadingTask = nil
        isLoadingPhotos = false
        photoImportIssue = nil
        stagedPhotoItems = []
        failedPhotoSelections = []
        cleanStaging()
    }

    private func finishPhotoStaging(_ outcomes: [PhotoStagingOutcome],
                                    totalCount: Int,
                                    appending: Bool = false) {
        let loaded = outcomes.compactMap { outcome -> IncomingItem? in
            if case .success(let item) = outcome { return item }
            return nil
        }
        let failed = outcomes.compactMap { outcome -> IndexedPhotoSelection? in
            if case .failure(let selection) = outcome { return selection }
            return nil
        }

        if appending {
            stagedPhotoItems.append(contentsOf: loaded)
        } else {
            stagedPhotoItems = loaded
        }
        stagedPhotoItems.sort { $0.index < $1.index }
        failedPhotoSelections = failed.sorted { $0.index < $1.index }
        isLoadingPhotos = false

        if failed.isEmpty {
            let items = stagedPhotoItems
            stagedPhotoItems = []
            convert(items: items)
        } else {
            photoImportIssue = PhotoImportIssue(loadedCount: stagedPhotoItems.count,
                                                failedCount: failed.count,
                                                totalCount: max(totalCount, stagedPhotoItems.count + failed.count))
        }
    }

    /// Loads at most three full-resolution assets at once. Each Data value is
    /// immediately staged to disk inside the worker task, so SwiftUI state
    /// never retains decoded UIImages or a collection of camera-sized blobs.
    nonisolated private static func stagePhotos(
        _ selections: [IndexedPhotoSelection],
        in store: TempFileStore,
        progress: @escaping @Sendable (Int) async -> Void
    ) async -> [PhotoStagingOutcome] {
        guard !selections.isEmpty else { return [] }
        let concurrencyLimit = min(3, selections.count)

        return await withTaskGroup(of: PhotoStagingOutcome.self,
                                   returning: [PhotoStagingOutcome].self) { group in
            var next = 0
            for _ in 0..<concurrencyLimit {
                let selection = selections[next]
                next += 1
                group.addTask { await stagePhoto(selection, in: store) }
            }

            var outcomes: [PhotoStagingOutcome] = []
            outcomes.reserveCapacity(selections.count)
            var completed = 0

            while let outcome = await group.next() {
                outcomes.append(outcome)
                completed += 1
                await progress(completed)

                if next < selections.count {
                    let selection = selections[next]
                    next += 1
                    group.addTask { await stagePhoto(selection, in: store) }
                }
            }
            return outcomes
        }
    }

    nonisolated private static func stagePhoto(
        _ selection: IndexedPhotoSelection,
        in store: TempFileStore
    ) async -> PhotoStagingOutcome {
        do {
            try Task.checkCancellation()
            guard let data = try await selection.item.loadTransferable(type: Data.self),
                  !data.isEmpty else {
                return .failure(selection)
            }
            try Task.checkCancellation()
            let fileExtension = preferredFileExtension(for: selection.item)
            let url = try store.stage(data: data, fileExtension: fileExtension)
            return .success(IncomingItem(kind: .image(url),
                                         originalFilename: nil,
                                         source: .photos,
                                         index: selection.index))
        } catch {
            return .failure(selection)
        }
    }

    nonisolated private static func preferredFileExtension(for item: PhotosPickerItem) -> String {
        item.supportedContentTypes
            .first(where: { $0.conforms(to: .image) })?
            .preferredFilenameExtension ?? "img"
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

    /// Converts with an explicit options override (from Link sheet params).
    func convert(items: [IncomingItem], optionsOverride: ConversionOptions? = nil) {
        self.optionsOverride = optionsOverride
        convert(items: items)
    }

    /// Stages a web conversion for the "Customize First" flow.
    func stageWebConversion(url: URL, mode: ConversionMode, paperSize: PDFPaperSize) {
        var options = ConversionOptions.fromSharedDefaults()
        options.mode = mode
        options.paperSize = paperSize
        stagedWebConversion = (url: url, options: options)
        pendingItems = [IncomingItem(kind: .url(url),
                                     sourceURL: url,
                                     source: ContentSource.detect(from: url))]
    }

    /// Creates the PDF for a STAGED "Customize First" conversion. Called by
    /// the Customize sheet's Create button — uses the exact URL/mode/paper
    /// chosen in the Link sheet plus whatever customization was applied.
    func convertStagedWebConversion() {
        guard let staged = stagedWebConversion else { return }
        optionsOverride = staged.options
        let items: [IncomingItem] = [IncomingItem(kind: .url(staged.url),
                                                  sourceURL: staged.url,
                                                  source: ContentSource.detect(from: staged.url))]
        showingCustomize = false
        runConversion(items: items)
    }

    func convert(items: [IncomingItem]) {
        guard !items.isEmpty else {
            failure = .noUsableContent
            showingError = true
            return
        }
        // FREE/PRO GATE: link & webpage conversion is a Pro feature
        // (FeaturePolicy). Free users get the contextual paywall.
        let containsWeb = items.contains { item in
            if case .url = item.kind { return true }
            if case .html = item.kind { return true }
            return false
        }
        if containsWeb && !EntitlementCenter.shared.isPro {
            // Preserve the exact request before replacing the entry sheet
            // with a contextual paywall. Purchase/Demo Mode resumes this URL
            // and these options; the user never has to enter them twice.
            pendingItems = items
            requiresPro = .webConversion
            showingLinkEntry = false
            showingPaywall = true
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

    /// Resumes the precise web request staged at the Pro gate. The entitlement
    /// check prevents this helper from becoming a bypass in production.
    @discardableResult
    func resumePendingProConversion() -> Bool {
        guard EntitlementCenter.shared.isPro, !pendingItems.isEmpty else { return false }
        let items = pendingItems
        requiresPro = nil
        showingPaywall = false
        showingLinkEntry = false
        runConversion(items: items)
        return true
    }

#if DEBUG
    /// Test-only inspection for the pre-launch Demo Mode resumption contract.
    var debugPendingProRequest: (url: URL, options: ConversionOptions)? {
        guard let item = pendingItems.first,
              case .url(let url) = item.kind,
              let optionsOverride else { return nil }
        return (url, optionsOverride)
    }
#endif

    /// The actual engine call, split out so Retry and post-Customize
    /// conversion reuse the exact same path.
    private func runConversion(items: [IncomingItem]) {
        pendingItems = items
        savedRecordID = nil

        var options = optionsOverride ?? ConversionOptions.fromSharedDefaults()
        options.includeSourceURL = options.includeSourceURL || customization.includeSourceURLFooter
        options.includeCreationDate = options.includeCreationDate || customization.includeCreationDateFooter
        isConverting = true
        stage = .analyzing

        // Reordered images replace the original item order.
        let effectiveItems = orderedImageItems(original: items)

        let customization = self.customization
        let storage = self.storage
        conversionTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) { () -> BackgroundConversionResult in
                let coordinator = ConversionCoordinator()
                do {
                    let document = try await coordinator.convert(items: effectiveItems,
                                                                 options: options,
                                                                 customization: customization)
                    let record = try storage.save(document: document)
                    return .success(document, record.id)
                } catch is CancellationError {
                    return .cancelled
                } catch let error as ConversionError where error == .cancelled {
                    return .cancelled
                } catch let error as ConversionError {
                    return .failure(error)
                } catch {
                    return .failure(.generationFailed)
                }
            }

            let outcome = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                worker.cancel()
            })
            guard let self else { return }

            switch outcome {
            case .success(let document, let recordID):
                self.cleanStaging()
                self.result = document
                self.savedRecordID = recordID
                self.isConverting = false
                self.showingResult = true
                self.customization = PDFCustomization()
                self.pendingImageOrder = []
            case .failure(let error):
                self.failure = error
                self.isConverting = false
                self.showingError = true
            case .cancelled:
                self.isConverting = false
            }
        }
    }

    /// Returns and clears the exact saved record identity after the result
    /// sheet has fully dismissed.
    func consumeSavedRecordID() -> UUID? {
        defer { savedRecordID = nil }
        return savedRecordID
    }

    /// Persists bytes already rendered by Document Composer. The success
    /// sheet receives those exact bytes, so preview and output cannot drift.
    func savePreparedDocument(_ document: ConvertedDocument) {
        conversionTask?.cancel()
        savedRecordID = nil
        isConverting = true
        stage = .creatingPDF
        let storage = self.storage

        conversionTask = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                () -> BackgroundConversionResult in
                do {
                    let record = try storage.save(document: document)
                    return .success(document, record.id)
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .failure(.generationFailed)
                }
            }.value
            guard let self else { return }
            switch outcome {
            case .success(let saved, let recordID):
                self.result = saved
                self.savedRecordID = recordID
                self.isConverting = false
                self.showingResult = true
            case .failure(let error):
                self.failure = error
                self.isConverting = false
                self.showingError = true
            case .cancelled:
                self.isConverting = false
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
        photoLoadingTask?.cancel()
        conversionTask?.cancel()
        cleanStaging()
        isLoadingPhotos = false
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
    /// Conversion parameters — restored as first-class options in this sheet.
    @State private var mode: ConversionMode = .quick
    @State private var paperSize: PDFPaperSize = .automatic
    let onConvert: (URL, ConversionMode, PDFPaperSize) -> Void
    /// Optional "Customize First" path — carries URL + current parameters.
    var onCustomize: ((URL, ConversionMode, PDFPaperSize) -> Void)? = nil

    /// Staged for the customize flow; consumed by HomeView.
    @State private var pendingCustomizeURL: URL?

    init(onConvert: @escaping (URL, ConversionMode, PDFPaperSize) -> Void,
         onCustomize: ((URL, ConversionMode, PDFPaperSize) -> Void)? = nil) {
        self.onConvert = onConvert
        self.onCustomize = onCustomize
        let defaults = ConversionOptions.fromSharedDefaults()
        _mode = State(initialValue: defaults.mode)
        _paperSize = State(initialValue: defaults.paperSize)
    }

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

                    // Honest-expectations disclaimer: some sites resist
                    // automated capture. Set BEFORE the user waits.
                    Label {
                        Text("Some sites (login walls, CAPTCHAs, blurred previews) don't allow clean captures. Try Reader mode, or convert the page from your browser instead.")
                            .font(.caption2)
                            .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.5) : Color.secondary)
                    } icon: {
                        Image(systemName: "info.circle")
                            .foregroundStyle(Theme.Colors.orangePrimary)
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
                }
                .premiumCard()

                // CONVERSION PARAMETERS (restored — were missing entirely).
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Mode", selection: $mode) {
                        ForEach(ConversionMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Picker("Page", selection: $paperSize) {
                        ForEach(PDFPaperSize.allCases) { size in
                            Text(size.displayName).tag(size)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .padding(.horizontal, 4)

                Button {
                    if let url = normalizedURL() {
                        dismiss()
                        onConvert(url, mode, paperSize)
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
                            onCustomize(url, mode, paperSize)
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

                MascotView(type: .hero, size: 145, enableFloatingAnimation: false)
                .frame(height: 155)

                VStack(spacing: 6) {
                    Text("PDF Ready")
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
                        Text(String(localized: "preview.pages_and_size \(document.pageCount) \(sizeText)", bundle: LanguageManager.bundle))
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
