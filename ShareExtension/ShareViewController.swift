import UIKit
import PDFKit
import UniformTypeIdentifiers

/// The Share Extension — the product's hero surface.
///
/// Thin UI layer over `ShareFlowModel`, which owns the state machine,
/// the extracted items, the staging lifetime and completion semantics.
/// The card is a vertical UIStackView; each state shows and hides arranged
/// sections, so layout can never conflict. No fake progress, no technical
/// failure text inside PDFs, no configuration dashboard.
final class ShareViewController: UIViewController, UIGestureRecognizerDelegate {

    // MARK: - Dependencies

    private var model: ShareFlowModel?
    private let storage = StorageManager.shared

    /// Guarantees extensionContext is completed/cancelled exactly once, no
    /// matter how many paths race to leave (Done, share sheet, background tap).
    private var hasCompletedRequest = false

    /// The temporary export file this controller created for the share
    /// sheet (only when Library persistence failed). Removed after sharing.
    private var tempExportURL: URL?

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
        control.accessibilityLabel = String(localized: "Conversion mode")
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
        label.text = String(localized: "Page")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        return label
    }()

    private let paperSelector: UISegmentedControl = {
        let control = UISegmentedControl(items: PDFPaperSize.allCases.map(\.displayName))
        control.accessibilityLabel = String(localized: "Paper size")
        return control
    }()

    private let createButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Create PDF")
        configuration.cornerStyle = .capsule
        configuration.buttonSize = .large
        configuration.baseBackgroundColor = UIColor(red: 1.0, green: 0.478, blue: 0.102, alpha: 1.0)
        configuration.baseForegroundColor = .white
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = String(localized: "Create PDF")
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
        view.accessibilityLabel = String(localized: "PDF preview")
        return view
    }()

    private let previewInfoLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
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
        // Vertical by design: three localized actions side-by-side clip in
        // DE/FR/IT (real-device bug). One full-width action per row.
        stack.axis = .vertical
        stack.spacing = 10
        stack.distribution = .fill
        return stack
    }()

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startFlow()
    }

    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.45)

        // Dismiss/cancel ONLY for taps outside the card. The delegate
        // rejects touches inside cardView, so every in-card control keeps
        // normal interaction and can never trigger background cancellation.
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.delegate = self
        tap.cancelsTouchesInView = false
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
            self?.model?.createTapped()
        }, for: .touchUpInside)
        createButton.addAction(UIAction { _ in
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }, for: .touchDown)

        modeSelector.addAction(UIAction { [weak self] _ in
            self?.syncModeFromSelector()
        }, for: .valueChanged)

        paperSelector.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.model?.options.paperSize = PDFPaperSize.allCases[self.paperSelector.selectedSegmentIndex]
        }, for: .valueChanged)
    }

    private func startFlow() {
        guard let context = extensionContext else {
            render(.failed(.noUsableContent))
            completeRequest(cancelled: true)
            return
        }

        let flowModel = ShareFlowModel.live(storage: storage)
        model = flowModel
        flowModel.onStateChange = { [weak self] state in
            self?.render(state)
        }
        flowModel.onFinish = { [weak self] success in
            self?.completeRequest(cancelled: !success)
        }
        flowModel.startExtraction(context: context)
    }

    private func syncModeFromSelector() {
        guard let model,
              let summary = model.readySummary,
              summary.availableModes.indices.contains(modeSelector.selectedSegmentIndex) else { return }
        model.options.mode = summary.availableModes[modeSelector.selectedSegmentIndex]
    }

    // MARK: - State rendering

    private func render(_ state: ShareFlowModel.State) {
        UIView.performWithoutAnimation {
            self.renderState(state)
        }
    }

    private func renderState(_ state: ShareFlowModel.State) {
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
            statusLabel.text = String(localized: "Reading shared content…")

        case .ready(let summary):
            contentIconView.image = UIImage(systemName: summary.symbolName)
            contentTitleLabel.text = summary.title
            contentSubtitleLabel.text = summary.subtitle
            contentSubtitleLabel.isHidden = (summary.subtitle == nil)
            noticeLabel.text = summary.notice
            noticeLabel.isHidden = (summary.notice == nil)
            modeSelector.isHidden = summary.availableModes.count <= 1
            paperRow.isHidden = !summary.paperSizeRelevant
            createButton.configuration?.title = summary.isPDFPassthrough ? String(localized: "Share PDF") : String(localized: "Create PDF")
            createButton.accessibilityLabel = summary.isPDFPassthrough ? String(localized: "Share PDF") : String(localized: "Create PDF")
            createButton.isHidden = false

            if let index = summary.availableModes.firstIndex(of: model?.options.mode ?? .quick) {
                modeSelector.selectedSegmentIndex = index
            } else {
                modeSelector.selectedSegmentIndex = 0
            }
            if let index = PDFPaperSize.allCases.firstIndex(of: model?.options.paperSize ?? .automatic) {
                paperSelector.selectedSegmentIndex = index
            }
            [contentIconView, contentTitleLabel].forEach { $0.isHidden = false }

        case .converting(let stage):
            activityRow.isHidden = false
            activityIndicator.startAnimating()
            statusLabel.text = Self.statusText(for: stage)
            actionStack.isHidden = false
            setActions([
                (String(localized: "Cancel"), .secondary, { [weak self] in
                    self?.model?.cancelConversion()
                }),
            ])

        case .preview(let info):
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            pdfPreview.isHidden = false
            pdfPreview.document = PDFDocument(data: info.document.data)

            let sizeText = ByteCountFormatter.string(fromByteCount: Int64(info.byteCount), countStyle: .file)
            let pages = info.document.pageCount
            let pagesAndSize = String(localized: "preview.pages_and_size \(pages) \(sizeText)")
            if info.savedToLibrary {
                previewInfoLabel.text = pagesAndSize
            } else {
                // Storage failed but the PDF exists: say so plainly instead
                // of pretending everything saved, without calling it failure.
                let warning = String(localized: "PDF created, but it couldn't be added to Library.")
                previewInfoLabel.text = "\(pagesAndSize)\n\(warning)"
            }
            previewInfoLabel.isHidden = false
            actionStack.isHidden = false
            setActions([
                (String(localized: "Done"), .secondary, { [weak self] in
                    self?.model?.complete()
                }),
                (String(localized: "Share"), .primary, { [weak self] in
                    self?.sharePreviewedPDF(info)
                }),
            ])

        case .failed(let error):
            errorIconView.image = UIImage(systemName: Self.symbol(for: error))
            errorTitleLabel.text = error.headline
            errorMessageLabel.text = error.message
            [errorIconView, errorTitleLabel, errorMessageLabel, actionStack].forEach { $0.isHidden = false }

            var actions: [(String, ActionStyle, () -> Void)] = []
            if model?.readySummary?.failingURL != nil {
                actions.append((String(localized: "Retry"), .primary, { [weak self] in
                    self?.model?.retryFailedWebConversion()
                }))
                // Shared text exists: never dead-end — convert it instead.
                if ShareFlowModel.textFallbackItems(from: model?.readySummary) != nil {
                    actions.append((String(localized: "Create PDF from Shared Text"), .secondary, { [weak self] in
                        self?.model?.convertSharedTextFallback()
                    }))
                } else {
                    actions.append((String(localized: "Save Link as PDF"), .secondary, { [weak self] in
                        self?.model?.saveLinkAsText()
                    }))
                }
            } else {
                actions.append((String(localized: "Try Again"), .primary, { [weak self] in
                    guard let self, let model = self.model, let context = self.extensionContext else { return }
                    model.startExtraction(context: context)
                }))
            }
            actions.append((String(localized: "Cancel"), .secondary, { [weak self] in
                self?.model?.cancelConversion()
            }))
            setActions(actions)
        }
    }

    private static func statusText(for stage: ConversionStage) -> String {
        switch stage {
        case .analyzing: return String(localized: "Reading shared content…")
        case .loadingWebPage(let host):
            if let host {
                return String(localized: "loading.host \(host)")
            } else {
                return String(localized: "Loading webpage…")
            }
        case .optimizingImages: return String(localized: "Optimizing images…")
        case .creatingPDF: return String(localized: "Creating PDF…")
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

    // MARK: - Sharing

    private func sharePreviewedPDF(_ info: ShareFlowModel.PreviewInfo) {
        let url: URL
        if let saved = info.savedURL, FileManager.default.fileExists(atPath: saved.path) {
            // Prefer the persisted Library copy; it must NEVER be deleted.
            url = saved
        } else {
            // Storage failed earlier: still share the generated PDF via a
            // throwaway export copy, removed once sharing completes.
            let temporary = TempFileStore.exportURL(named: FilenameGenerator.fileName(for: info.document))
            try? info.document.data.write(to: temporary, options: .atomic)
            url = temporary
            tempExportURL = temporary
        }

        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            if let tempExport = self?.tempExportURL {
                try? FileManager.default.removeItem(at: tempExport)
                self?.tempExportURL = nil
            }
            self?.model?.complete()
        }
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = cardView
            popover.sourceRect = cardView.bounds
        }
        present(activityVC, animated: true)
    }

    // MARK: - Extension lifecycle (exactly-once)

    private func completeRequest(cancelled: Bool) {
        guard !hasCompletedRequest else { return }
        hasCompletedRequest = true
        if cancelled {
            extensionContext?.cancelRequest(withError: NSError(domain: "com.kenatst.pdfit.share",
                                                               code: NSUserCancelledError))
        } else {
            extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// Only taps genuinely outside the card may cancel the flow. Decisions
    /// delegate to `CardTapPolicy` so the shipped rule is unit-tested.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        CardTapPolicy.cancels(locationInCard: touch.location(in: cardView),
                              cardBounds: cardView.bounds)
    }

    @objc private func backgroundTapped() {
        model?.cancelConversion()
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
                configuration.baseBackgroundColor = UIColor(red: 1.0, green: 0.478, blue: 0.102, alpha: 1.0)
                configuration.baseForegroundColor = .white
            case .secondary:
                configuration = .gray()
            }
            configuration.cornerStyle = .capsule
            let button = UIButton(configuration: configuration)
            // Title wraps instead of clipping — long DE/FR/IT strings stay
            // fully readable at every Dynamic Type size.
            button.setTitle(spec.title, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            NSLayoutConstraint.activate([
                button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46),
            ])
            button.accessibilityLabel = spec.title
            button.addAction(UIAction { _ in spec.handler() }, for: .touchUpInside)
            actionStack.addArrangedSubview(button)
        }
    }
}
