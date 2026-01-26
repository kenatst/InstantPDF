import UIKit
import Social
import PDFKit

class ShareViewController: UIViewController {
    
    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Initializing..."
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        return label
    }()
    
    private lazy var activityIndicator: UIActivityIndicatorView = {
        let indicator = UIActivityIndicatorView(style: .medium)
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.hidesWhenStopped = true
        return indicator
    }()
    
    private lazy var containerView: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        view.layer.cornerRadius = 24
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor.separator.cgColor
        view.clipsToBounds = true
        return view
    }()
    
    // UI for Preview
    private lazy var pdfPreview: PDFView = {
        let pdfView = PDFView()
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.isHidden = true
        pdfView.backgroundColor = .secondarySystemBackground
        return pdfView
    }()
    
    private lazy var actionStack: UIStackView = {
        let stack = UIStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 12
        stack.isHidden = true
        return stack
    }()
    
    private let renderer = PDFRenderer()
    private let processor = InputProcessor()
    
    private var pendingFileName: String = "InstantPDF"
    private var generatedPDFData: Data?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startConversion()
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        
        view.addSubview(containerView)
        containerView.addSubview(statusLabel)
        containerView.addSubview(activityIndicator)
        containerView.addSubview(pdfPreview)
        containerView.addSubview(actionStack)
        
        let saveButton = createActionButton(title: "Partager", color: .systemBlue, action: #selector(saveAndShare))
        let cancelButton = createActionButton(title: "Annuler", color: .systemGray2, action: #selector(cancel))
        actionStack.addArrangedSubview(cancelButton)
        actionStack.addArrangedSubview(saveButton)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.85),
            containerView.heightAnchor.constraint(equalTo: view.heightAnchor, multiplier: 0.6),
            
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: containerView.centerYAnchor, constant: -20),
            
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -24),
            
            pdfPreview.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            pdfPreview.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 12),
            pdfPreview.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -12),
            pdfPreview.bottomAnchor.constraint(equalTo: actionStack.topAnchor, constant: -16),
            
            actionStack.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            actionStack.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            actionStack.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20),
            actionStack.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        activityIndicator.startAnimating()
    }
    
    private func createActionButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        button.backgroundColor = color
        button.setTitleColor(.white, for: .normal)
        button.layer.cornerRadius = 12
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    
    private func startConversion() {
        guard let context = extensionContext else {
            fail(with: "Contexte système manquant")
            return
        }
        
        updateStatus("Analyse du contenu...")
        
        processor.extractAllContent(from: context) { [weak self] items in
            guard let self = self else { return }
            
            if items.isEmpty {
                self.fail(with: "Aucun contenu compatible détecté (Vidéos non supportées)")
                return
            }
            
            self.generateFileName(from: items.first)
            self.updateStatus("Génération du PDF...")
            
            self.renderer.renderMergedPDF(from: items) { pdfData in
                guard let data = pdfData else {
                    self.fail(with: "Échec de la génération")
                    return
                }
                self.showPreview(data: data)
            }
        }
    }
    
    private func generateFileName(from item: ShareItem?) {
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let item = item else { 
            pendingFileName = "InstantPDF_\(timestamp)"
            return 
        }
        
        var base = "InstantPDF"
        switch item {
        case .text(_, let title): base = title ?? "Note"
        case .url(let url): base = url.host ?? "Lien"
        case .file(let url): base = url.deletingPathExtension().lastPathComponent
        case .image: base = "Photo"
        case .pdf: base = "Document"
        }
        
        let sanitized = base.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let truncated = String(sanitized.prefix(30))
        pendingFileName = "\(truncated)_\(timestamp)"
    }
    
    private func showPreview(data: Data) {
        DispatchQueue.main.async {
            self.generatedPDFData = data
            self.activityIndicator.stopAnimating()
            self.statusLabel.isHidden = true
            
            self.pdfPreview.document = PDFDocument(data: data)
            self.pdfPreview.isHidden = false
            self.actionStack.isHidden = false
            
            // Haptic feedack for success
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.impactOccurred()
        }
    }
    
    @objc private func saveAndShare() {
        guard let data = generatedPDFData else { return }
        
        // Save to History (Shared Container)
        let savedURL = StorageManager.shared.savePDF(data: data, fileName: "\(pendingFileName).pdf")
        
        // Present original share sheet from the saved file
        let urlToShare = savedURL ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(pendingFileName).pdf")
        
        if savedURL == nil {
            try? data.write(to: urlToShare)
        }
        
        let activityVC = UIActivityViewController(activityItems: [urlToShare], applicationActivities: nil)
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = self.actionStack
            popover.sourceRect = self.actionStack.bounds
        }
        
        self.present(activityVC, animated: true)
    }
    
    @objc private func cancel() {
        self.extensionContext?.cancelRequest(withError: NSError(domain: "InstantPDF", code: -1, userInfo: nil))
    }
    
    private func updateStatus(_ text: String) {
        DispatchQueue.main.async {
            self.statusLabel.text = text
        }
    }
    
    private func fail(with message: String) {
        DispatchQueue.main.async {
            self.activityIndicator.stopAnimating()
            self.statusLabel.text = message
            self.statusLabel.textColor = .systemRed
            
            let alert = UIAlertController(title: "Erreur InstantPDF", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in
                self.cancel()
            })
            self.present(alert, animated: true)
        }
    }
}
