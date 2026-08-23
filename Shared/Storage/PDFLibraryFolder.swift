import Foundation

/// A Library folder — exactly ONE level of hierarchy (V1 contract): folders
/// contain PDFs, never other folders. Persisted in its own JSON file next to
/// the document metadata so the two indexes evolve independently.
struct PDFLibraryFolder: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var name: String
    let createdAt: Date
    var modifiedAt: Date
    /// Manual ordering position (nil = sort by name).
    var sortOrder: Int?
}

enum FolderError: Error, Equatable {
    case notFound
    case invalidName
}
