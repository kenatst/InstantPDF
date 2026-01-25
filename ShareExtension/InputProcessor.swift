import Foundation
import UIKit
import UniformTypeIdentifiers

enum ShareItem {
    case text(String, String?)
    case url(URL)
    case image(UIImage)
    case file(URL) // For existing PDFs or documents
}

class InputProcessor {
    
    /// Extracts all supported content from the extension context in order.
    func extractAllContent(from context: NSExtensionContext, completion: @escaping ([ShareItem]) -> Void) {
        guard let items = context.inputItems as? [NSExtensionItem] else {
            completion([])
            return
        }
        
        var extractedItems: [ShareItem] = []
        let group = DispatchGroup()
        
        for item in items {
            guard let attachments = item.attachments else { continue }
            
            for provider in attachments {
                group.enter()
                
                // Priority Check
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { (data, error) in
                        if let url = data as? URL {
                            // Check if it's a file URL or Web URL
                            if url.isFileURL {
                                extractedItems.append(.file(url))
                            } else {
                                extractedItems.append(.url(url))
                            }
                        }
                        group.leave()
                    }
                } 
                else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { (data, error) in
                        if let image = data as? UIImage {
                            extractedItems.append(.image(image))
                        } else if let url = data as? URL, let image = UIImage(contentsOfFile: url.path) {
                            extractedItems.append(.image(image))
                        } else if let imageData = data as? Data, let image = UIImage(data: imageData) {
                            extractedItems.append(.image(image))
                        }
                        group.leave()
                    }
                }
                else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { (data, error) in
                        if let text = data as? String {
                            extractedItems.append(.text(text, item.attributedTitle?.string))
                        }
                        group.leave()
                    }
                }
                else {
                    group.leave()
                }
            }
        }
        
        group.notify(queue: .main) {
            completion(extractedItems)
        }
    }
}
