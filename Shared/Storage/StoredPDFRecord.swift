import Foundation

/// Rich metadata for one stored PDF. V2 of the original 4-field history
/// item — this is what powers the Library UI.
struct StoredPDFRecord: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var filename: String
    let createdAt: Date
    var relativePath: String
    var pageCount: Int
    var fileSize: Int64
    /// Raw ContentSource value ("x", "photos", …) for icons and grouping.
    var sourceType: String
    var sourceURL: String?
    var thumbnailPath: String?
    /// Folder this document lives in. nil = Library root. Optional in the
    /// Codable sense too — records written before folders existed decode
    /// with folderID == nil, which IS the migration (no rewrite needed).
    var folderID: UUID?

    var displayName: String {
        (filename as NSString).deletingPathExtension
    }

    var contentSource: ContentSource {
        ContentSource(rawValue: sourceType) ?? .unknown
    }
}

/// Errors with human explanations — storage failures are surfaced,
/// never silently swallowed.
enum StorageError: Error, LocalizedError {
    case containerUnavailable
    case writeFailed(underlying: String)

    var errorDescription: String? {
        switch self {
        case .containerUnavailable:
            return String(localized: "Shared storage isn't available on this device.")
        case .writeFailed(let underlying):
            return String(localized: "error.storage.write_failed \(underlying)")
        }
    }
}
