import Foundation

/// The Share Extension's flow state machine, extracted from
/// `ShareViewController` so lifecycle regressions can be tested without
/// launching extension UI. UIKit-free by design.
///
/// States: loading → ready(items) → converting → preview / failed.
///
/// Ownership guarantees (the release-blocking invariants):
/// • A `ReadySummary` is only ever built through `ReadySummary.build(for:)`,
///   which refuses empty input — its `items` are the EXACT extracted items,
///   retained until conversion starts, finishes, fails, or the user cancels.
/// • The staging session returned by extraction stays alive while any state
///   may still read staged files (Ready screen, running conversion). It is
///   cleaned up when conversion succeeds, when the flow enters a failed or
///   cancelled terminal path, or when a new extraction starts — never while
///   the user sits on the Ready screen.
/// • Storage failure never discards a successfully created PDF: preview
///   carries `savedURL == nil` and the UI shows a subtle warning while the
///   PDF stays shareable.
@MainActor
final class ShareFlowModel: ObservableObject {

    // MARK: - State

    enum State: Equatable {
        case loading
        case ready(ReadySummary)
        case converting(stage: ConversionStage)
        case preview(PreviewInfo)
        case failed(ConversionError)
    }

    /// What the Ready card shows — and, critically, what Create PDF works on.
    /// `items` is a constant: an empty Ready state cannot be constructed.
    struct ReadySummary: Equatable {
        let items: [IncomingItem]
        let title: String
        let subtitle: String?
        let symbolName: String
        let availableModes: [ConversionMode]
        let paperSizeRelevant: Bool
        let isPDFPassthrough: Bool
        let notice: String?
        let failingURL: URL?

        /// Builds the summary for extracted content. Returns nil for empty
        /// input — callers translate that into `.failed(.noUsableContent)`.
        static func build(for extracted: ExtractedInput) -> ReadySummary? {
            let items = extracted.items
            guard !items.isEmpty else { return nil }

            let imageCount = items.filter(\.isImage).count
            let textCount = items.filter {
                if case .text = $0.kind { return true }
                return false
            }.count
            let pdfCount = items.filter {
                if case .pdf = $0.kind { return true }
                return false
            }.count

            var title = "Content"
            var subtitle: String?
            var symbolName = "doc"
            var availableModes: [ConversionMode] = [.quick]
            var paperSizeRelevant = true
            var isPDFPassthrough = false
            var failingURL: URL?

            if items.count == 1, case .url(let url) = items[0].kind {
                title = "Webpage"
                subtitle = url.host
                symbolName = items[0].source.symbolName
                availableModes = [.quick, .clean, .reader]
                failingURL = url
            } else if items.count == 1, case .html = items[0].kind {
                title = "Web Content"
                subtitle = items[0].sourceURL?.host
                symbolName = "safari"
                availableModes = [.quick, .clean, .reader]
                failingURL = items[0].sourceURL
            } else if imageCount == items.count, imageCount > 0 {
                title = imageCount == 1 ? "1 Image" : "\(imageCount) Images"
                subtitle = imageCount > 1 ? "Order preserved" : nil
                symbolName = "photo.on.rectangle"
            } else if textCount == items.count, textCount > 0 {
                title = textCount == 1 ? "Text" : "\(textCount) Text Items"
                symbolName = "note.text"
            } else if pdfCount == 1, items.count == 1 {
                title = "PDF Ready"
                subtitle = items[0].originalFilename
                symbolName = "doc.richtext"
                isPDFPassthrough = true
                paperSizeRelevant = false
            } else {
                title = "\(items.count) Items"
                subtitle = "Merged into one PDF"
                symbolName = "square.stack.3d.up"
            }

            var notice: String?
            if extracted.skippedCount > 0 {
                notice = extracted.skippedCount == 1
                    ? "1 video or audio item can't be converted"
                    : "\(extracted.skippedCount) video or audio items can't be converted"
            }
            return ReadySummary(items: items,
                                title: title,
                                subtitle: subtitle,
                                symbolName: symbolName,
                                availableModes: availableModes,
                                paperSizeRelevant: paperSizeRelevant,
                                isPDFPassthrough: isPDFPassthrough,
                                notice: notice,
                                failingURL: failingURL)
        }
    }

    struct PreviewInfo: Equatable {
        let document: ConvertedDocument
        let byteCount: Int
        /// Non-nil when the PDF was persisted to the Library. Nil means App
        /// Group storage failed — the PDF itself is fine and remains
        /// shareable; the UI says so instead of reporting full failure.
        let savedURL: URL?

        var savedToLibrary: Bool { savedURL != nil }
    }

    // MARK: - Dependencies (injectable for tests)

    /// Produces extracted input for one share session. The production path
    /// uses an `InputProcessor` against the extension context; tests inject
    /// synthetic providers.
    typealias Extraction = @Sendable () async -> ExtractedInput
    typealias Conversion = ([IncomingItem], ConversionOptions, @escaping (ConversionStage) -> Void) async throws -> ConvertedDocument

    private let performExtraction: Extraction?
    private let processor = InputProcessor()
    private let performConversion: Conversion
    private let storage: StorageManager?

    // MARK: - Observable state

    private(set) var state: State = .loading {
        didSet {
            guard !isFinishing else { return }
            onStateChange?(state)
        }
    }
    /// Authoritative ready snapshot, kept outside the enum so retry paths
    /// don't have to pattern-match UI state.
    private(set) var readySummary: ReadySummary?
    var options = ConversionOptions.fromSharedDefaults()

    var onStateChange: ((State) -> Void)?
    /// Fired exactly once when the flow reaches its end. `true` means the
    /// user completed intentionally (Done / share finished); `false` means
    /// cancellation or abandonment.
    var onFinish: ((Bool) -> Void)?

    private var conversionTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private var finished = false
    private var isFinishing = false

    /// Staging files for THIS share session. Alive from extraction until a
    /// terminal transition; never cleaned while Ready/converting.
    private var staging: TempFileStore?

    // MARK: - Init

    /// Production wiring: real coordinator, shared storage, real processor
    /// driven by the extension context at start time.
    static func live(storage: StorageManager? = .shared) -> ShareFlowModel {
        ShareFlowModel(convert: { items, options, onStage in
            let coordinator = ConversionCoordinator()
            coordinator.onStageChange = onStage
            return try await coordinator.convert(items: items, options: options)
        }, storage: storage)
    }

    init(extraction: Extraction? = nil,
         convert: @escaping Conversion,
         storage: StorageManager?) {
        self.performExtraction = extraction
        self.performConversion = convert
        self.storage = storage
    }

    // MARK: - Extraction

    func startExtraction(context: NSExtensionContext) {
        startExtraction(using: { [processor] in
            await processor.extract(from: context)
        })
    }

    /// Testable extraction entry: takes an explicit provider closure.
    func startExtraction(using extractor: @escaping () async -> ExtractedInput) {
        guard !finished else { return }
        // Any previous session's staged files are dead from here on.
        cleanStaging()
        state = .loading
        extractionTask = Task { [weak self] in
            let extracted = await extractor()
            await MainActor.run { self?.handle(extracted: extracted) }
        }
    }

    func handle(extracted: ExtractedInput) {
        guard !finished else { return }
        guard let summary = ReadySummary.build(for: extracted) else {
            // Nothing usable: release anything staged and surface the
            // failure card (Try Again restarts extraction; Cancel leaves).
            extracted.staging?.cleanUp()
            state = .failed(.noUsableContent)
            return
        }
        // The staging session now belongs to this flow until a terminal
        // transition cleans it up. Ready holds the exact extracted items.
        staging = extracted.staging
        readySummary = summary
        if !summary.availableModes.contains(options.mode) {
            options.mode = summary.availableModes[0]
        }
        state = .ready(summary)
    }

    // MARK: - Conversion

    func createTapped() {
        guard let summary = readySummary else { return }
        runConversion(items: summary.items)
    }

    /// Retry after a web failure — reuses the SAME retained items. Web items
    /// carry URLs/HTML, never staged files, so this is safe even though
    /// failures clean staging.
    func retryFailedWebConversion() {
        guard readySummary?.failingURL != nil,
              let items = readySummary?.items, !items.isEmpty else { return }
        runConversion(items: items)
    }

    func saveLinkAsText() {
        guard let url = readySummary?.failingURL else { return }
        let item = IncomingItem(kind: .text(url.absoluteString),
                                title: "Saved Link",
                                sourceURL: url,
                                source: .website)
        runConversion(items: [item])
    }

    private func runConversion(items: [IncomingItem]) {
        guard !finished else { return }
        let options = self.options
        state = .converting(stage: .analyzing)

        conversionTask = Task { [weak self] in
            guard let self, !self.finished else { return }
            do {
                let document = try await self.performConversion(items, options) { stage in
                    Task { @MainActor [weak self] in
                        guard let self, !self.finished else { return }
                        self.state = .converting(stage: stage)
                    }
                }
                guard !self.finished else { return }

                // Success: staged files are no longer needed — the document
                // data is fully in memory.
                self.cleanStaging()

                let savedURL = self.saveToLibrary(document)
                self.state = .preview(PreviewInfo(document: document,
                                                  byteCount: document.data.count,
                                                  savedURL: savedURL))
            } catch is CancellationError {
                guard !self.finished else { return }
                // User cancelled: propagate as cancellation, never as a
                // misleading fallback conversion or generic failure.
                self.handleCancellation()
            } catch let error as ConversionError where error == .cancelled {
                // A raced NSURLErrorCancelled can surface as .cancelled —
                // same treatment: it IS a cancellation.
                guard !self.finished else { return }
                self.handleCancellation()
            } catch let error as ConversionError {
                guard !self.finished else { return }
                self.enterFailure(error)
            } catch {
                guard !self.finished else { return }
                self.enterFailure(.generationFailed)
            }
        }
    }

    private func handleCancellation() {
        cleanStaging()
        finish(success: false, notifyHost: true)
    }

    private func saveToLibrary(_ document: ConvertedDocument) -> URL? {
        guard let storage else { return nil }
        do {
            let record = try storage.save(document: document)
            return storage.fileURL(for: record)
        } catch {
            // Storage failure must not discard the generated PDF.
            return nil
        }
    }

    // MARK: - Cancellation & completion

    /// Cancel button during conversion, background tap.
    func cancelConversion() {
        conversionTask?.cancel()
        cleanStaging()
        finish(success: false, notifyHost: true)
    }

    /// Done button or completed share/export.
    func complete() {
        finish(success: true, notifyHost: true)
    }

    private func enterFailure(_ error: ConversionError) {
        // Safe even for retryable web failures: web items reference URLs,
        // not staged files, and non-web failures restart via re-extraction.
        cleanStaging()
        state = .failed(error)
    }

    private func finish(success: Bool, notifyHost: Bool) {
        guard !finished else { return }
        finished = true
        isFinishing = true
        conversionTask?.cancel()
        extractionTask?.cancel()
        cleanStaging()
        if notifyHost { onFinish?(success) }
    }

    // MARK: - Staging lifetime

    private func cleanStaging() {
        staging?.cleanUp()
        staging = nil
    }
}
