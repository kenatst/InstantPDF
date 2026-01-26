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
    
    // Removed unused processingQueue
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
                    // CRITICAL FIX: Always interact with indexedResults AND group.leave() on the specific resultQueue
                    // This prevents race conditions and ensures notify() is not called prematurely or while simple writes are pending.
                    self.resultQueue.async {
                        if let result = result {
                            indexedResults[currentIndex] = result
                        }
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
        
        // 0. CHECK FOR UNSUPPORTED TYPES (Videos/Audios)
        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) || 
           provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            completion(nil) // Will be handled as "No shareable content" or could be logged
            return
        }

        // 1. File URL (Priority for local files like PDFs or Documents)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                guard let url = data as? URL else { completion(nil); return }
                
                // Block extremely large files (e.g. > 100MB) to prevent crash
                if let resources = try? url.resourceValues(forKeys: [.fileSizeKey]),
                   let size = resources.fileSize, size > 100 * 1024 * 1024 {
                    completion(nil)
                    return
                }

                // Allow renderer to determine if it's an image or PDF more robustly
                if url.pathExtension.lowercased() == "pdf" {
                    if let pdfData = try? Data(contentsOf: url) {
                        completion(.pdf(pdfData))
                    } else {
                        completion(.file(url))
                    }
                } else if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    completion(.file(url))
                } else {
                    // Fallback for other files: we'll just show the name in the PDF
                    completion(.file(url))
                }
            }
        } 
        // 2. PDF (as Data or direct provider) - Moved UP in priority
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
        // 3. Web URL
        else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (data, error) in
                if let url = data as? URL {
                    completion(.url(url))
                } else {
                    completion(nil)
                }
            }
        }
        // 4. Images (Direct)
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
