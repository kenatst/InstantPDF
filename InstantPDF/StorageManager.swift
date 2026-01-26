import Foundation

struct PDFHistoryItem: Codable, Identifiable {
    let id: UUID
    let fileName: String
    let date: Date
    let fileURL: String // Relative path within the shared container
    
    var absoluteURL: URL? {
        StorageManager.shared.sharedContainerURL?.appendingPathComponent(fileURL)
    }
}

class StorageManager {
    static let shared = StorageManager()
    
    // REPLACE THIS with your actual app group ID from Xcode (e.g., "group.com.yourname.instantpdf")
    private let appGroupID = "group.com.instantpdf.shared"
    
    private let historyKey = "pdf_generation_history"
    
    var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    
    func savePDF(data: Data, fileName: String) -> URL? {
        guard let container = sharedContainerURL else { return nil }
        
        let pdfFolder = container.appendingPathComponent("PDFs", isDirectory: true)
        try? FileManager.default.createDirectory(at: pdfFolder, withIntermediateDirectories: true)
        
        let relativePath = "PDFs/\(fileName)"
        let fileURL = container.appendingPathComponent(relativePath)
        
        do {
            try data.write(to: fileURL)
            addToHistory(fileName: fileName, relativePath: relativePath)
            return fileURL
        } catch {
            print("Failed to save PDF to shared container: \(error)")
            return nil
        }
    }
    
    private func addToHistory(fileName: String, relativePath: String) {
        var history = fetchHistory()
        let newItem = PDFHistoryItem(id: UUID(), fileName: fileName, date: Date(), fileURL: relativePath)
        history.insert(newItem, at: 0)
        
        // Keep only last 20 items to save space
        if history.count > 20 {
            let removed = history.suffix(from: 20)
            for item in removed {
                if let url = item.absoluteURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            history = Array(history.prefix(20))
        }
        
        if let encoded = try? JSONEncoder().encode(history),
           let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.set(encoded, forKey: historyKey)
        }
    }
    
    func fetchHistory() -> [PDFHistoryItem] {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: historyKey),
              let history = try? JSONDecoder().decode([PDFHistoryItem].self, from: data) else {
            return []
        }
        return history
    }
    
    func deleteItem(_ item: PDFHistoryItem) {
        var history = fetchHistory()
        history.removeAll(where: { $0.id == item.id })
        
        if let url = item.absoluteURL {
            try? FileManager.default.removeItem(at: url)
        }
        
        if let encoded = try? JSONEncoder().encode(history),
           let defaults = UserDefaults(suiteName: appGroupID) {
            defaults.set(encoded, forKey: historyKey)
        }
    }
}
