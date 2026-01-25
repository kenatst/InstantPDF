import UIKit
import PDFKit
import WebKit
import ImageIO

class PDFRenderer: NSObject, WKNavigationDelegate {
    
    private var webView: WKWebView?
    private var webCompletion: ((Data?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    
    // A4 Size approx 595 x 842 points
    private let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8)
    private let margin: CGFloat = 40.0
    
    /// Renders a list of items into a single PDF
    func renderMergedPDF(from items: [ShareItem], completion: @escaping (Data?) -> Void) {
        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, pageRect, nil)
        
        let group = DispatchGroup()
        
        // We process items sequentially to maintain order and manage resources
        func processItem(index: Int) {
            guard index < items.count else {
                UIGraphicsEndPDFContext()
                completion(pdfData as Data)
                return
            }
            
            let item = items[index]
            
            switch item {
            case .text(let content, let title):
                addTextPage(content, title: title)
                processItem(index: index + 1)
                
            case .image(let image):
                addImagePage(image)
                processItem(index: index + 1)
                
            case .url(let url):
                renderWebPageToPDF(url) { data in
                    if let data = data, let provider = CGDataProvider(data: data as CFData), let pdfDoc = CGPDFDocument(provider) {
                        self.appendPDFDocument(pdfDoc)
                    } else {
                        self.addTextPage("Failed to render web page: \(url.absoluteString)", title: "Error")
                    }
                    processItem(index: index + 1)
                }
                
            case .file(let url):
                if let pdfDoc = CGPDFDocument(url as CFURL) {
                    self.appendPDFDocument(pdfDoc)
                } else {
                    self.addTextPage("File attached: \(url.lastPathComponent)", title: "File")
                }
                processItem(index: index + 1)
            }
        }
        
        processItem(index: 0)
    }
    
    // MARK: - Page Generators
    
    private func addTextPage(_ text: String, title: String?) {
        UIGraphicsBeginPDFPage()
        
        let titleFont = UIFont.boldSystemFont(ofSize: 22)
        let bodyFont = UIFont.systemFont(ofSize: 14)
        
        let titleAttrs: [NSAttributedString.Key: Any] = [.font: titleFont]
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont]
        
        var currentY: CGFloat = margin
        
        if let title = title {
            let titleSize = title.size(withAttributes: titleAttrs)
            title.draw(at: CGPoint(x: margin, y: currentY), withAttributes: titleAttrs)
            currentY += titleSize.height + 20
        }
        
        let bodyRect = CGRect(x: margin, y: currentY, width: pageRect.width - (margin * 2), height: pageRect.height - currentY - margin)
        text.draw(in: bodyRect, withAttributes: bodyAttrs)
    }
    
    private func addImagePage(_ image: UIImage) {
        UIGraphicsBeginPDFPage()
        
        // Robust Downsampling
        let downsampled = downsample(image: image, to: CGSize(width: 2000, height: 2000)) ?? image
        
        let aspectWidth = pageRect.width - (margin * 2)
        let aspectHeight = pageRect.height - (margin * 2)
        
        let imageRect = AVMakeRect(aspectRatio: downsampled.size, insideRect: CGRect(x: margin, y: margin, width: aspectWidth, height: aspectHeight))
        downsampled.draw(in: imageRect)
    }
    
    private func appendPDFDocument(_ document: CGPDFDocument) {
        for i in 1...document.numberOfPages {
            guard let page = document.page(at: i) else { continue }
            let mediaBox = page.getBoxRect(.mediaBox)
            UIGraphicsBeginPDFPageWithInfo(mediaBox, nil)
            guard let context = UIGraphicsGetCurrentContext() else { continue }
            
            context.saveGState()
            context.translateBy(x: 0, y: mediaBox.size.height)
            context.scaleBy(x: 1, y: -1)
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }
    
    // MARK: - WKWebView PDF Generation
    
    private func renderWebPageToPDF(_ url: URL, completion: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            let config = WKWebViewConfiguration()
            let webView = WKWebView(frame: self.pageRect, configuration: config)
            self.webView = webView
            webView.navigationDelegate = self
            
            self.webCompletion = completion
            
            // Timeout handling
            let timeout = DispatchWorkItem { [weak self] in
                self?.handleWebFailure(reason: "Timeout (10s)")
            }
            self.timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)
            
            webView.load(URLRequest(url: url))
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        timeoutWorkItem?.cancel()
        
        if #available(iOS 14.0, *) {
            let config = WKPDFConfiguration()
            webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    self.webCompletion?(data)
                case .failure:
                    self.handleWebFailure(reason: "createPDF failed")
                }
                self.cleanupWeb()
            }
        } else {
            // Fallback for older iOS or failure
            self.handleWebFailure(reason: "iOS < 14 fallback")
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebFailure(reason: error.localizedDescription)
    }
    
    private func handleWebFailure(reason: String) {
        timeoutWorkItem?.cancel()
        // Provide a simple fallback PDF page in the stream instead of nil if possible,
        // but here we return nil to the callback so the merger can add an error page.
        webCompletion?(nil)
        cleanupWeb()
    }
    
    private func cleanupWeb() {
        webView = nil
        webCompletion = nil
        timeoutWorkItem = nil
    }
    
    // MARK: - Image Helpers
    
    private func downsample(image: UIImage, to pointSize: CGSize) -> UIImage? {
        guard let data = image.jpegData(compressionQuality: 0.8) else { return nil }
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, imageSourceOptions) else { return nil }
        
        let maxDimensionInPixels = max(pointSize.width, pointSize.height)
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary
        
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: downsampledImage)
    }
}

import AVFoundation // For AVMakeRect
