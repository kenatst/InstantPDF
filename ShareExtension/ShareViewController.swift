import UIKit
import PDFKit
import UniformTypeIdentifiers

/// The Share Extension — the product's hero surface.
///
/// Explicit state machine: loading → ready → converting → preview / failed.
/// The card is a vertical UIStackView; each state shows and hides arranged
/// sections, so layout can never conflict. No fake progress, no technical
/// failure text inside PDFs, no configuration dashboard.
final class ShareViewController: UIViewController {

    // MARK: - State

    private enum State {
        case loading
        case ready(ReadySummary)
        case converting(ConversionStage)
        case preview(PreviewInfo)
        case failed(ConversionError)
    }

    private struct ReadySummary {
        var items: [IncomingItem] = []
        var title: String = "Content"
        var subtitle: String?
        var symbolName: String = "doc"
        var availableModes: [ConversionMode] = [.quick]
        var paperSizeRelevant = true
        var isPDFPassthrough = false
        var notice: String?
        var failingURL: URL?
    }

    private struct PreviewInfo {
        let document: ConvertedDocument
        let savedURL: URL?
        let byteCount: Int
    }

    // MARK: - Dependencies

    private let processor = InputProcessor()
    private let storage = StorageManager.shared
    private var conversionTask: Task<Void, Never>?
    private var extractionTask: Task<Void, Never>?
    private var options = ConversionOptions.fromSharedDefaults()
    private var readySummary: ReadySummary?

    // MARK: - UI

    private let cardView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 22
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor.separator.cgColor
        view.clipsToBounds = true
        return view
    }()

    private let contentStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        return stack
    }()

    private let titleLabel: UILabel = {
        let label = UILabel()
        label.text = "PDF It"
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private let contentIconView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.tintColor = .label
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        view.isAccessibilityElement = false
        return view
    }()

    private let contentTitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 21, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        return label
    }()

    private let contentSubtitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    private let noticeLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let modeSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: ConversionMode.allCases.map(\.displayName))
        control.selectedSegmentIndex = 0
        control.accessibilityLabel = "Conversion mode"
        return control
    }()

    private let paperRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        return stack
    }()

    private let paperRowLabel: UILabel = {
        let label = UILabel()
        label.text = "Page"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()

    private let paperSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: PDFPaperSize.allCases.map(\.displayName))
        control.accessibilityLabel = "Paper size"
        return control
    }()

    private let createButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "Create PDF"
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "Create PDF"
        return button
    }()

    private let activityRow: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        return stack
    }()

    private let activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.hidesWhenStopped = true
        return indicator
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()

    private let pdfPreview: PDFView = {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.clipsToBounds = true
        view.heightAnchor.constraint(equalToConstant: 300).isActive = true
        view.isAccessibilityElement = true
        view.accessibilityLabel = "PDF preview"
        return view
    }()

    private let previewInfoLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private let errorIconView: UIImageView = {
        let view = UIImageView(image: UIImage(systemName: "wifi.exclamationmark"))
        view.contentMode = .scaleAspectFit
        view.tintColor = .secondaryLabel
        view.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 32, weight: .regular)
        return view
    }()

    private let errorTitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 18, weight: .bold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let errorMessageLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        return label
    }()

    private let actionStack: UIStackView = {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 10
        stack.distribution = .fillEqually
        return stack
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        apply(.loading)
        startExtraction()
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        view.addGestureRecognizer(tap)

        view.addSubview(cardView)
        cardView.addSubview(contentStack)

        paperRow.addArrangedSubview(paperRowLabel)
        paperRow.addArrangedSubview(paperSelector)

        activityRow.addArrangedSubview(activityIndicator)
        activityRow.addArrangedSubview(statusLabel)

        contentStack.addArrangedSubview(titleLabel)
        contentStack.addArrangedSubview(contentIconView)
        contentStack.addArrangedSubview(contentTitleLabel)
        contentStack.addArrangedSubview(contentSubtitleLabel)
        contentStack.addArrangedSubview(noticeLabel)
        contentStack.addArrangedSubview(modeSelector)
        contentStack.addArrangedSubview(paperRow)
        contentStack.addArrangedSubview(createButton)
        contentStack.addArrangedSubview(activityRow)
        contentStack.addArrangedSubview(pdfPreview)
        contentStack.addArrangedSubview(previewInfoLabel)
        contentStack.addArrangedSubview(errorIconView)
        contentStack.addArrangedSubview(errorTitleLabel)
        contentStack.addArrangedSubview(errorMessageLabel)
        contentStack.addArrangedSubview(actionStack)

        contentIconView.heightAnchor.constraint(equalToConstant: 30).isActive = true
        errorIconView.heightAnchor.constraint(equalToConstant: 34).isActive = true

        NSLayoutConstraint.activate([
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            cardView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.88),
            cardView.heightAnchor.constraint(lessThanOrEqualTo: view.heightAnchor, multiplier: 0.8),

            contentStack.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 14),
            contentStack.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),
        ])

        createButton.addAction(UIAction { [weak self] _ in
            self?.createTapped()
        }, for: .touchUpInside)
        createButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }, for: .touchDown)

        modeSelector.addAction(UIAction { [weak self] _ in
            self?.syncModeFromSelector()
        }, for: .valueChanged)

        paperSelector.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.options.paperSize = PDFPaperSize.allCases[self.paperSelector.selectedSegmentIndex]
        }, for: .valueChanged)
    }

    private func syncModeFromSelector() {
        guard let summary = readySummary,
              summary.availableModes.indices.contains(modeSelector.selectedSegmentIndex) else { return }
        options.mode = summary.availableModes[modeSelector.selectedSegmentIndex]
    }

    // MARK: - Extraction

    private func startExtraction() {
        guard let context = extensionContext else {
            apply(.failed(.noUsableContent))
            return
        }
        extractionTask = Task { [processor] in
            let extracted = await processor.extract(from: context)
            await MainActor.run { self.handle(extracted: extracted) }
        }
    }

    private func handle(extracted: ExtractedInput) {
        guard !Task.isCancelled else { return }
        guard !extracted.items.isEmpty else {
            apply(.failed(.noUsableContent))
            return
        }
        let summary = Self.summary(for: extracted)
        readySummary = summary
        apply(.ready(summary))
    }

    private static func summary(for extracted: ExtractedInput) -> ReadySummary {
        var summary = ReadySummary()
        let items = extracted.items

        let imageCount = items.filter(\.isImage).count
        let textCount = items.filter {
            if case .text = $0.kind { return true }
            return false
        }.count
        let pdfCount = items.filter {
            if case .pdf = $0.kind { return true }
            return false
        }.count

        if items.count == 1, case .url(let url) = items[0].kind {
            summary.title = "Webpage"
            summary.subtitle = url.host
            summary.symbolName = items[0].source.symbolName
            summary.availableModes = [.quick, .clean, .reader]
            summary.failingURL = url
        } else if items.count == 1, case .html = items[0].kind {
            summary.title = "Web Content"
            summary.subtitle = items[0].sourceURL?.host
            summary.symbolName = "safari"
            summary.availableModes = [.quick, .clean, .reader]
            summary.failingURL = items[0].sourceURL
        } else if imageCount == items.count, imageCount > 0 {
            summary.title = imageCount == 1 ? "1 Image" : "\(imageCount) Images"
            summary.subtitle = imageCount > 1 ? "Order preserved" : nil
            summary.symbolName = "photo.on.rectangle"
        } else if textCount == items.count, textCount > 0 {
            summary.title = textCount == 1 ? "Text" : "\(textCount) Text Items"
            summary.symbolName = "note.text"
        } else if pdfCount == 1, items.count == 1 {
            summary.title = "PDF Ready"
            summary.subtitle = items[0].originalFilename
            summary.symbolName = "doc.richtext"
            summary.isPDFPassthrough = true
            summary.paperSizeRelevant = false
        } else {
            summary.title = "\(items.count) Items"
            summary.subtitle = "Merged into one PDF"
            summary.symbolName = "square.stack.3d.up"
        }

        if extracted.skippedCount > 0 {
            summary.notice = extracted.skippedCount == 1
                ? "1 video or audio item can't be converted"
                : "\(extracted.skippedCount) video or audio items can't be converted"
        }
        return summary
    }

    // MARK: - Conversion

    private func createTapped() {
        guard let summary = readySummary else { return }
        runConversion(items: summary.items)
    }

    private func runConversion(items: [IncomingItem]) {
        let options = self.options
        let coordinator = ConversionCoordinator()

        conversionTask = Task { [weak self] in
            await MainActor.run { self?.apply(.converting(.analyzing)) }
            coordinator.onStageChange = { stage in
                DispatchQueue.main.async { self?.apply(.converting(stage)) }
            }
            do {
                let document = try await coordinator.convert(items: items, options: options)
                let savedURL = await MainActor.run { () -> URL? in
                    guard let self else { return nil }
                    if let record = try? self.storage.save(document: document) {
                        return self.storage.fileURL(for: record)
                    }
                    return nil
                }
                await MainActor.run {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    self?.apply(.preview(PreviewInfo(document: document,
                                                     savedURL: savedURL,
                                                     byteCount: document.data.count)))
                }
            } catch let error as ConversionError where error != .cancelled {
                await MainActor.run { self?.apply(.failed(error)) }
            } catch is CancellationError {
                await MainActor.run { self?.cancelExtension() }
            } catch {
                await MainActor.run { self?.apply(.failed(.generationFailed)) }
            }
        }
    }

    // MARK: - State application

    private var currentState: State = .loading

    private func apply(_ state: State) {
        currentState = state
        UIView.performWithoutAnimation {
            self.render(state)
        }
    }

    private func render(_ state: State) {
        // Everything starts hidden; each state reveals its sections.
        [contentIconView, contentTitleLabel, contentSubtitleLabel, noticeLabel,
         modeSelector, paperRow, createButton, activityRow, pdfPreview,
         previewInfoLabel, errorIconView, errorTitleLabel, errorMessageLabel,
         actionStack].forEach { $0.isHidden = true }
        activityIndicator.stopAnimating()

        switch state {
        case .loading:
            activityRow.isHidden = false
            activityIndicator.startAnimating()
            statusLabel.text = "Reading shared content…"

        case .ready(let summary):
            contentIconView.image = UIImage(systemName: summary.symbolName)
            contentTitleLabel.text = summary.title
            contentSubtitleLabel.text = summary.subtitle
            contentSubtitleLabel.isHidden = (summary.subtitle == nil)
            noticeLabel.text = summary.notice
            noticeLabel.isHidden = (summary.notice == nil)
            modeSelector.isHidden = summary.availableModes.count <= 1
            paperRow.isHidden = !summary.paperSizeRelevant
            createButton.configuration?.title = summary.isPDFPassthrough ? "Share PDF" : "Create PDF"
            createButton.accessibilityLabel = summary.isPDFPassthrough ? "Share PDF" : "Create PDF"
            createButton.isHidden = false

            if let index = summary.availableModes.firstIndex(of: options.mode) {
                modeSelector.selectedSegmentIndex = index
            } else {
                modeSelector.selectedSegmentIndex = 0
                options.mode = .quick
            }
            if let index = PDFPaperSize.allCases.firstIndex(of: options.paperSize) {
                paperSelector.selectedSegmentIndex = index
            }
            [contentIconView, contentTitleLabel].forEach { $0.isHidden = false }

        case .converting(let stage):
            activityRow.isHidden = false
            activityIndicator.startAnimating()
            statusLabel.text = Self.statusText(for: stage)
            actionStack.isHidden = false
            setActions([
                ("Cancel", .secondary, { [weak self] in
                    self?.conversionTask?.cancel()
                }),
            ])

        case .preview(let info):
            pdfPreview.isHidden = false
            pdfPreview.document = PDFDocument(data: info.document.data)
            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(info.byteCount), countStyle: .file)
            let pages = info.document.pageCount
            previewInfoLabel.text = "\(pages) page\(pages == 1 ? "" : "s") · \(sizeText)"
            previewInfoLabel.isHidden = false
            actionStack.isHidden = false
            setActions([
                ("Done", .secondary, { [weak self] in
                    self?.completeExtension()
                }),
                ("Share", .primary, { [weak self] in
                    self?.sharePreviewedPDF()
                }),
            ])

        case .failed(let error):
            errorIconView.image = UIImage(systemName: Self.symbol(for: error))
            errorTitleLabel.text = error.headline
            errorMessageLabel.text = error.message
            [errorIconView, errorTitleLabel, errorMessageLabel, actionStack].forEach { $0.isHidden = false }

            var actions: [(String, ActionStyle, () -> Void)] = []
            if let url = readySummary?.failingURL {
                actions.append(("Retry", .primary, { [weak self] in
                    guard let self, let summary = self.readySummary else { return }
                    self.runConversion(items: summary.items)
                }))
                actions.append(("Save Link as PDF", .secondary, { [weak self] in
                    self?.convertLinkAsText(url: url)
                }))
            } else {
                actions.append(("Try Again", .primary, { [weak self] in
                    self?.startExtraction()
                }))
            }
            actions.append(("Cancel", .secondary, { [weak self] in
                self?.cancelExtension()
            }))
            setActions(actions)
        }
    }

    private static func statusText(for stage: ConversionStage) -> String {
        switch stage {
        case .analyzing: return "Reading shared content…"
        case .loadingWebPage(let host): return host.map { "Loading \($0)…" } ?? "Loading webpage…"
        case .optimizingImages: return "Optimizing images…"
        case .creatingPDF: return "Creating PDF…"
        }
    }

    private static func symbol(for error: ConversionError) -> String {
        switch error {
        case .pageUnreachable, .pageTooSlow, .invalidURL, .webProcessTerminated:
            return "wifi.exclamationmark"
        case .fileTooLarge: return "tray.full"
        case .unreadableFile: return "questionmark.folder"
        case .noUsableContent: return "tray"
        default: return "exclamationmark.triangle"
        }
    }

    // MARK: - Recovery

    private func convertLinkAsText(url: URL) {
        let item = IncomingItem(kind: .text(url.absoluteString),
                                title: "Saved Link",
                                sourceURL: url,
                                source: .website)
        runConversion(items: [item])
    }

    // MARK: - Sharing

    private func sharePreviewedPDF() {
        guard case .preview(let info) = currentState else { return }

        let url: URL
        if let saved = info.savedURL {
            url = saved
        } else {
            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent(FilenameGenerator.fileName(for: info.document))
            try? info.document.data.write(to: temporary, options: .atomic)
            url = temporary
        }

        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.completeExtension()
        }
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = cardView
            popover.sourceRect = cardView.bounds
        }
        present(activityVC, animated: true)
    }

    // MARK: - Extension lifecycle

    private func completeExtension() {
        conversionTask?.cancel()
        extractionTask?.cancel()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancelExtension() {
        conversionTask?.cancel()
        extractionTask?.cancel()
        extensionContext?.cancelRequest(withError: NSError(domain: "com.kenatst.pdfit.share",
                                                           code: NSUserCancelledError))
    }

    @objc private func backgroundTapped() {
        cancelExtension()
    }

    // MARK: - Action buttons

    private enum ActionStyle { case primary, secondary }

    private func setActions(_ specs: [(title: String, style: ActionStyle, handler: () -> Void)]) {
        actionStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for spec in specs {
            var configuration: UIButton.Configuration
            switch spec.style {
            case .primary:
                configuration = .filled()
            case .secondary:
                configuration = .gray()
            }
            configuration.cornerStyle = .capsule
            let button = UIButton(configuration: configuration)
            button.setTitle(spec.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            button.heightAnchor.constraint(equalToConstant: 46).isActive = true
            button.accessibilityLabel = spec.title
            button.addAction(UIAction { _ in spec.handler() }, for: .touchUpInside)
            actionStack.addArrangedSubview(button)
        }
    }
}
