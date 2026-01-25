import Foundation
import UIKit
import UniformTypeIdentifiers

enum ShareItem {
    case text(String, String?)
    case url(URL)
    case image(UIImage)
    case file(URL) 
    case pdf(Data)
}

class InputProcessor {
    
    private let processingQueue = DispatchQueue(label: "com.instantpdf.processor", attributes: .concurrent)
    private let resultQueue = DispatchQueue(label: "com.instantpdf.result")

    /// Extracts all supported content from the extension context while strictly preserving order and avoiding data races.
    func extractAllContent(from context: NSExtensionContext, completion: @escaping ([ShareItem]) -> Void) {
        guard let items = context.inputItems as? [NSExtensionItem] else {
            completion([])
            return
        }
        
        // We Use a dictionary to store results by their global index to preserve order
        var indexedResults: [Int: ShareItem] = [:]
        let group = DispatchGroup()
        
        var globalIndex = 0
        
        for item in items {
            guard let attachments = item.attachments else { continue }
            
            for provider in attachments {
                let currentIndex = globalIndex
                globalIndex += 1
                
                group.enter()
                
                processProvider(provider, itemTitle: item.attributedTitle?.string) { result in
                    if let result = result {
                        self.resultQueue.async {
                            indexedResults[currentIndex] = result
                            group.leave()
                        }
                    } else {
                        group.leave()
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            // Sort by index and flatten
            let sortedItems = indexedResults.keys.sorted().compactMap { indexedResults[$0] }
            completion(sortedItems)
        }
    }
    
    private func processProvider(_ provider: NSItemProvider, itemTitle: String?, completion: @escaping (ShareItem?) -> Void) {
        
        // 1. File URL (Priority for local files like PDFs or Documents)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                guard let url = data as? URL else { completion(nil); return }
                
                if url.pathExtension.lowercased() == "pdf" {
                    if let pdfData = try? Data(contentsOf: url) {
                        completion(.pdf(pdfData))
                    } else {
                        completion(.file(url))
                    }
                } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false {
                     // If it's an image file, we return it as an image to allow downsampling in renderer
                     completion(.file(url)) 
                } else {
                    completion(.file(url))
                }
            }
        } 
        // 2. Web URL
        else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (data, error) in
                if let url = data as? URL {
                    completion(.url(url))
                } else {
                    completion(nil)
                }
            }
        }
        // 3. Images (Direct)
        else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (data, error) in
                if let image = data as? UIImage {
                    completion(.image(image))
                } else if let url = data as? URL {
                    completion(.file(url)) // Pass URL to renderer for safer downsampling
                } else if let imageData = data as? Data, let image = UIImage(data: imageData) {
                    completion(.image(image))
                } else {
                    completion(nil)
                }
            }
        }
        // 4. PDF (as Data)
        else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.pdf.identifier, options: nil) { (data, error) in
                if let pdfData = data as? Data {
                    completion(.pdf(pdfData))
                } else if let url = data as? URL, let pdfData = try? Data(contentsOf: url) {
                    completion(.pdf(pdfData))
                } else {
                    completion(nil)
                }
            }
        }
        // 5. Plain Text
        else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (data, error) in
                if let text = data as? String {
                    completion(.text(text, itemTitle))
                } else {
                    completion(nil)
                }
            }
        }
        else {
            completion(nil)
        }
    }
}
