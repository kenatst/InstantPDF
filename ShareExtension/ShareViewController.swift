import UIKit
import Social

class ShareViewController: UIViewController {
    
    private lazy var statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Initializing..."
        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
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
        view.layer.cornerRadius = 16
        return view
    }()
    
    private let renderer = PDFRenderer()
    private let processor = InputProcessor()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        
        // Start processing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.startConversion()
        }
    }
    
    private func setupUI() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        
        view.addSubview(containerView)
        containerView.addSubview(statusLabel)
        containerView.addSubview(activityIndicator)
        
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            containerView.widthAnchor.constraint(equalToConstant: 240),
            containerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
            
            activityIndicator.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 30),
            activityIndicator.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            
            statusLabel.topAnchor.constraint(equalTo: activityIndicator.bottomAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -20),
            statusLabel.bottomAnchor.constraint(equalTo: containerView.bottomAnchor, constant: -20)
        ])
        
        activityIndicator.startAnimating()
    }
    
    private func startConversion() {
        guard let context = extensionContext else {
            fail(with: "No context found")
            return
        }
        
        updateStatus("Scanning items...")
        
        processor.extractAllContent(from: context) { [weak self] items in
            guard let self = self else { return }
            
            if items.isEmpty {
                self.fail(with: "Nothing shareable found")
                return
            }
            
            self.updateStatus("Generating PDF (\(items.count) items)...")
            
            self.renderer.renderMergedPDF(from: items) { pdfData in
                guard let data = pdfData else {
                    self.fail(with: "Failed to generate PDF")
                    return
                }
                
                self.finalizePDF(data: data)
            }
        }
    }
    
    private func finalizePDF(data: Data) {
        updateStatus("Saving...")
        
        let name = "InstantPDF_\(Int(Date().timeIntervalSince1970)).pdf"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        
        do {
            try data.write(to: url)
            
            DispatchQueue.main.async {
                self.activityIndicator.stopAnimating()
                self.presentShareSheet(url: url)
            }
        } catch {
            fail(with: error.localizedDescription)
        }
    }
    
    private func presentShareSheet(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        
        // Handle completion
        activityVC.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
        
        // Required for iPad
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
            self.statusLabel.text = "Error: \(message)"
            self.statusLabel.textColor = .systemRed
            
            let alert = UIAlertController(title: "Conversion Failed", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Dismiss", style: .cancel) { _ in
                self.extensionContext?.cancelRequest(withError: NSError(domain: "InstantPDF", code: -1, userInfo: [NSLocalizedDescriptionKey: message]))
            })
            self.present(alert, animated: true)
        }
    }
}
