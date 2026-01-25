import UIKit
import PDFKit
import WebKit
import ImageIO
import AVFoundation

class PDFRenderer: NSObject, WKNavigationDelegate {
    
    private var webView: WKWebView?
    private var webCompletion: ((Data?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    
    private let pageRect = CGRect(x: 0, y: 0, width: 595.2, height: 841.8) // A4
    private let margin: CGFloat = 50.0
    
    // MARK: - Merging Logic
    
    func renderMergedPDF(from items: [ShareItem], completion: @escaping (Data?) -> Void) {
        let pdfData = NSMutableData()
        UIGraphicsBeginPDFContextToData(pdfData, pageRect, nil)
        
        func processItem(index: Int) {
            guard index < items.count else {
                UIGraphicsEndPDFContext()
                completion(pdfData as Data)
                return
            }
            
            let item = items[index]
            switch item {
            case .text(let content, let title):
                addPaginatedText(content, title: title)
                processItem(index: index + 1)
                
            case .image(let image):
                addImagePage(image: image, sourceURL: nil)
                processItem(index: index + 1)
                
            case .file(let url):
                handleFileURL(url, index: index, items: items, processNext: processItem)
                
            case .url(let url):
                renderWebPageToPDF(url) { data in
                    if let data = data, let provider = CGDataProvider(data: data as CFData), let pdfDoc = CGPDFDocument(provider) {
                        self.appendPDFDocument(pdfDoc)
                    } else {
                        self.addPaginatedText("Failed to render web page: \(url.absoluteString)", title: "Link Error")
                    }
                    processItem(index: index + 1)
                }
                
            case .pdf(let data):
                if let provider = CGDataProvider(data: data as CFData), let pdfDoc = CGPDFDocument(provider) {
                    self.appendPDFDocument(pdfDoc)
                }
                processItem(index: index + 1)
            }
        }
        
        processItem(index: 0)
    }
    
    private func handleFileURL(_ url: URL, index: Int, items: [ShareItem], processNext: @escaping (Int) -> Void) {
        let ext = url.pathExtension.lowercased()
        
        // 1. Explicit PDF check
        if ext == "pdf" {
            if let pdfDoc = CGPDFDocument(url as CFURL) {
                appendPDFDocument(pdfDoc)
            }
            processNext(index + 1)
            return
        }
        
        // 2. Robust Image Check using ImageIO (Handles mismatched extensions)
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           CGImageSourceGetCount(source) > 0 {
            addImagePage(image: nil, sourceURL: url)
            processNext(index + 1)
            return
        }
        
        // 3. Fallback: Generic File Attachment
        addPaginatedText("File attached: \(url.lastPathComponent)", title: "Attached File")
        processNext(index + 1)
    }
    
    // MARK: - Core Text Pagination
    
    private func addPaginatedText(_ text: String, title: String?) {
        let titleFont = UIFont.boldSystemFont(ofSize: 20)
        let bodyFont = UIFont.systemFont(ofSize: 12)
        let textColor = UIColor.black
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.alignment = .left
        
        let combinedString = NSMutableAttributedString()
        
        if let title = title {
            combinedString.append(NSAttributedString(string: title + "\n\n", attributes: [
                .font: titleFont,
                .foregroundColor: textColor
            ]))
        }
        
        combinedString.append(NSAttributedString(string: text, attributes: [
            .font: bodyFont,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ]))
        
        let framesetter = CTFramesetterCreateWithAttributedString(combinedString as CFAttributedString)
        var currentRange = CFRange(location: 0, length: 0) // Explicit 0 length = calculate internally
        let printableRect = pageRect.insetBy(dx: margin, dy: margin)
        
        repeat {
            UIGraphicsBeginPDFPage()
            guard let context = UIGraphicsGetCurrentContext() else { break }
            
            // Flip context for Core Text
            context.saveGState()
            context.translateBy(x: 0, y: pageRect.height)
            context.scaleBy(x: 1, y: -1)
            
            // Adjust path for margins
            let path = CGPath(rect: CGRect(x: margin, y: margin, width: printableRect.width, height: printableRect.height), transform: nil)
            
            // Create frame for remaining text
            let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
            CTFrameDraw(frame, context)
            
            context.restoreGState()
            
            // Calculate what was actually drawn to advance
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            currentRange.location += visibleRange.length
            currentRange.length = 0 // Reset length to 0 to indicate "as much as fits" for next page
            
        } while (currentRange.location < combinedString.length)
    }
    
    // MARK: - Image Handling (Downsampling focused)
    
    private func addImagePage(image: UIImage?, sourceURL: URL?) {
        UIGraphicsBeginPDFPage()
        
        var finalImage: UIImage?
        
        if let url = sourceURL {
            finalImage = downsample(imageURL: url, to: CGSize(width: 2000, height: 2000))
        } else if let image = image {
            // Fallback: If we only have UIImage, downsample from its data
            if let data = image.jpegData(compressionQuality: 0.8) {
                finalImage = downsample(imageData: data, to: CGSize(width: 2000, height: 2000))
            } else {
                finalImage = image
            }
        }
        
        guard let img = finalImage else { return }
        
        let drawRect = AVMakeRect(aspectRatio: img.size, insideRect: pageRect.insetBy(dx: margin, dy: margin))
        img.draw(in: drawRect)
    }
    
    // MARK: - WKWebView with Content Size Logic
    
    private func renderWebPageToPDF(_ url: URL, completion: @escaping (Data?) -> Void) {
        DispatchQueue.main.async {
            // Use an iPhone-like width for rendering
            let webWidth: CGFloat = 390
            let initialFrame = CGRect(x: 0, y: 0, width: webWidth, height: self.pageRect.height)
            
            let config = WKWebViewConfiguration()
            let webView = WKWebView(frame: initialFrame, configuration: config)
            self.webView = webView
            webView.navigationDelegate = self
            self.webCompletion = completion
            
            let timeout = DispatchWorkItem { [weak self] in
                self?.handleWebFailure(reason: "Loading Timeout")
            }
            self.timeoutWorkItem = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10.0, execute: timeout)
            
            webView.load(URLRequest(url: url))
        }
    }
    
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Robust Height Detection via JS
        // We use Math.max across multiple properties to get the true document height
        let heightScript = "Math.max(document.body.scrollHeight, document.documentElement.scrollHeight, document.body.offsetHeight, document.documentElement.offsetHeight, document.body.clientHeight, document.documentElement.clientHeight)"
        
        webView.evaluateJavaScript(heightScript) { [weak self] (result, error) in
            guard let self = self else { return }
            
            // Robust Casting: result can be NSNumber, Double, or Int
            var scrollHeight: CGFloat = 0
            if let number = result as? NSNumber {
                scrollHeight = CGFloat(truncating: number)
            } else if let double = result as? Double {
                scrollHeight = CGFloat(double)
            } else if let int = result as? Int {
                scrollHeight = CGFloat(int)
            } else {
                scrollHeight = webView.scrollView.contentSize.height
            }
            
            // Safety Clamp: Prevent OOM on infinite scroll pages (Max ~30k points)
            let maxHeight: CGFloat = 30000
            let finalHeight = min(max(scrollHeight, self.pageRect.height), maxHeight)
            
            // Capture with delay for lazy loading
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.captureWebViewPDF(webView, height: finalHeight)
            }
        }
    }
    
    private func captureWebViewPDF(_ webView: WKWebView, height: CGFloat) {
        timeoutWorkItem?.cancel()
        
        if #available(iOS 14.0, *) {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: webView.frame.width, height: height)
            
            webView.createPDF(configuration: config) { [weak self] result in
                switch result {
                case .success(let data):
                    self?.webCompletion?(data)
                case .failure:
                    self?.handleWebFailure(reason: "createPDF failed")
                }
                self?.cleanupWeb()
            }
        } else {
            handleWebFailure(reason: "iOS < 14")
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleWebFailure(reason: error.localizedDescription)
    }
    
    private func handleWebFailure(reason: String) {
        timeoutWorkItem?.cancel()
        webCompletion?(nil)
        cleanupWeb()
    }
    
    private func cleanupWeb() {
        webView = nil
        webCompletion = nil
        timeoutWorkItem = nil
    }
    
    // MARK: - Helpers
    
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
    
    private func downsample(imageURL: URL, to pointSize: CGSize) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, imageSourceOptions) else { return nil }
        return createThumbnail(from: imageSource, to: pointSize)
    }
    
    private func downsample(imageData: Data, to pointSize: CGSize) -> UIImage? {
        let imageSourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, imageSourceOptions) else { return nil }
        return createThumbnail(from: imageSource, to: pointSize)
    }
    
    private func createThumbnail(from source: CGImageSource, to pointSize: CGSize) -> UIImage? {
        let maxDimensionInPixels = max(pointSize.width, pointSize.height) * UIScreen.main.scale
        let downsampleOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimensionInPixels
        ] as CFDictionary
        
        guard let downsampledImage = CGImageSourceCreateThumbnailAtIndex(source, 0, downsampleOptions) else { return nil }
        return UIImage(cgImage: downsampledImage)
    }
}
