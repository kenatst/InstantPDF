import UIKit
import Social

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
        view.layer.cornerRadius = 20
        view.layer.cornerCurve = .continuous
        // Subtle border for premium feel
        view.layer.borderWidth = 0.5
        view.layer.borderColor = UIColor.separator.cgColor
        return view
    }()
    
    private let renderer = PDFRenderer()
    private let processor = InputProcessor()
    
    private var pendingFileName: String = "InstantPDF"
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startConversion()
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        
        view.addSubview(containerView)
        containerView.addSubview(statusLabel)
        containerView.addSubview(activityIndicator)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 260),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            
            activityIndicator.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 40),
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -24),
            statusLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -24)
        ])
        
        activityIndicator.startAnimating()
    }
    
    private func startConversion() {
        guard let context = extensionContext else {
            fail(with: "System context missing")
            return
        }
        
        updateStatus("Processing content...")
        
        processor.extractAllContent(from: context) { [weak self] items in
            guard let self = self else { return }
            
            if items.isEmpty {
                self.fail(with: "No shareable content detected")
                return
            }
            
            // Intelligence: Try to name the file based on the first item
            self.generateFileName(from: items.first)
            
            self.updateStatus("Generating PDF...")
            
            self.renderer.renderMergedPDF(from: items) { pdfData in
                guard let data = pdfData else {
                    self.fail(with: "PDF Generation failed")
                    return
                }
                self.finalizePDF(data: data)
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
        case .url(let url): base = url.host ?? "Link"
        case .file(let url): base = url.deletingPathExtension().lastPathComponent
        case .image: base = "Photo"
        case .pdf: base = "Document"
        }
        
        // Sanitize and truncate
        let sanitized = base.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
        let truncated = String(sanitized.prefix(30))
        pendingFileName = "\(truncated)_\(timestamp)"
    }
    
    private func finalizePDF(data: Data) {
        updateStatus("Finalizing...")
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(pendingFileName).pdf")
        
        do {
            try data.write(to: url)
            
            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.presentShareSheet(url: url)
            }
        } catch {
            fail(with: "Save error: \(error.localizedDescription)")
        }
    }
    
    private func presentShareSheet(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            // Optimization: Clean up the temporary file immediately
            try? FileManager.default.removeItem(at: url)
            
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = self.containerView
            popover.sourceRect = self.containerView.bounds
        }
        
        self.present(activityVC, animated: true) {
            self.containerView.isHidden = true
        }
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
            
            let alert = UIAlertController(title: "InstantPDF Error", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in
                self.extensionContext?.cancelRequest(withError: NSError(domain: "InstantPDF", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            })
            self.present(alert, animated: true)
        }
    }
}
