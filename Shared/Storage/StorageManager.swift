import Foundation
import PDFKit
import UIKit

/// Local-first library storage, shared between the app and the Share
/// Extension through the App Group container.
///
/// V2 contract changes:
/// • Rich metadata per document (pages, size, source, thumbnail).
/// • Documents are NEVER auto-deleted — the Library keeps everything until
///   the user explicitly deletes it. History limits are a UI concern only.
/// • Atomic writes and collision-safe filenames; failures throw.
final class StorageManager {

    static let shared = StorageManager(appGroupID: AppConfiguration.appGroupIdentifier)

    private let containerURL: URL?
    private let queue = DispatchQueue(label: "com.kenatst.pdfit.storage")
    private var records: [StoredPDFRecord]

    private var documentsDirectory: URL? {
        containerURL?.appendingPathComponent("Documents/PDFs", isDirectory: true)
    }
    private var thumbnailsDirectory: URL? {
        containerURL?.appendingPathComponent("Thumbnails", isDirectory: true)
    }
    private var metadataFileURL: URL? {
        containerURL?.appendingPathComponent("Library/metadata.json")
    }

    /// Production initializer: uses the real App Group container.
    convenience init(appGroupID: String) {
        let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        self.init(containerURL: url)
    }

    /// Designated initializer — injectable for tests.
    init(containerURL: URL?) {
        self.containerURL = containerURL
        self.records = []
        loadRecordsSync()
    }

    // MARK: - Saving

    /// Persists a converted document. Filename collisions get a numeric
    /// suffix; the write is atomic; a thumbnail is generated best-effort.
    @discardableResult
    func save(document: ConvertedDocument, date: Date = Date()) throws -> StoredPDFRecord {
        guard let documents = documentsDirectory, let metadataFile = metadataFileURL else {
            throw StorageError.containerUnavailable
        }
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadataFile.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        let desired = FilenameGenerator.fileName(for: document, date: date)
        let takenNames = Set(records.map(\.filename))
        let uniqueName = FilenameGenerator.uniqueFileName(desired, existingNames: takenNames)
        let relativePath = "Documents/PDFs/\(uniqueName)"
        let fileURL = containerURL!.appendingPathComponent(relativePath)

        do {
            try document.data.write(to: fileURL, options: .atomic)
        } catch {
            throw StorageError.writeFailed(underlying: error.localizedDescription)
        }

        let thumbnailPath = writeThumbnail(for: document.data)
        let record = StoredPDFRecord(id: UUID(),
                                     filename: uniqueName,
                                     createdAt: date,
                                     relativePath: relativePath,
                                     pageCount: document.pageCount,
                                     fileSize: Int64(document.data.count),
                                     sourceType: document.source.rawValue,
                                     sourceURL: document.sourceURL?.absoluteString,
                                     thumbnailPath: thumbnailPath)

        try queue.sync {
            records.insert(record, at: 0)
            try persistRecords(to: metadataFile)
        }
        return record
    }

    // MARK: - Queries

    /// All records, newest first. Records whose file vanished on disk are
    /// pruned (data hygiene — not user data deletion).
    func fetchRecords() -> [StoredPDFRecord] {
        queue.sync { records }
    }

    func fileURL(for record: StoredPDFRecord) -> URL? {
        containerURL?.appendingPathComponent(record.relativePath)
    }

    func exists(_ record: StoredPDFRecord) -> Bool {
        guard let url = fileURL(for: record) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Mutations

    func delete(_ record: StoredPDFRecord) throws {
        guard let metadataFile = metadataFileURL else {
            throw StorageError.containerUnavailable
        }
        if let url = fileURL(for: record) {
            // Missing file is fine here — the record still must go away.
            try? FileManager.default.removeItem(at: url)
        }
        if let thumbnailPath = record.thumbnailPath, let thumbURL = containerURL?.appendingPathComponent(thumbnailPath) {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        try queue.sync {
            records.removeAll { $0.id == record.id }
            try persistRecords(to: metadataFile)
        }
    }

    func rename(_ record: StoredPDFRecord, to newRawName: String) throws -> StoredPDFRecord {
        guard let metadataFile = metadataFileURL else {
            throw StorageError.containerUnavailable
        }
        var newName = FilenameGenerator.sanitize(newRawName)
        if !(newName.lowercased().hasSuffix(".pdf")) {
            newName += ".pdf"
        }
        let takenNames = Set(records.filter { $0.id != record.id }.map(\.filename))
        newName = FilenameGenerator.uniqueFileName(newName, existingNames: takenNames)

        guard let oldURL = fileURL(for: record) else {
            throw StorageError.containerUnavailable
        }
        let newRelativePath = "Documents/PDFs/\(newName)"
        let newURL = containerURL!.appendingPathComponent(newRelativePath)

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
        } catch {
            throw StorageError.writeFailed(underlying: error.localizedDescription)
        }

        var updated = record
        updated.filename = newName
        updated.relativePath = newRelativePath

        try queue.sync {
            if let index = records.firstIndex(where: { $0.id == record.id }) {
                records[index] = updated
            }
            try persistRecords(to: metadataFile)
        }
        return updated
    }

    func duplicate(_ record: StoredPDFRecord) throws -> StoredPDFRecord? {
        guard let sourceURL = fileURL(for: record),
              let data = try? Data(contentsOf: sourceURL) else {
            return nil
        }
        let copy = ConvertedDocument(data: data,
                                     pageCount: record.pageCount,
                                     suggestedTitle: record.displayName,
                                     sourceURL: record.sourceURL.flatMap(URL.init(string:)),
                                     source: record.contentSource)
        return try save(document: copy, date: record.createdAt)
    }

    // MARK: - Thumbnails

    func thumbnailImage(for record: StoredPDFRecord) -> UIImage? {
        guard let path = record.thumbnailPath,
              let url = containerURL?.appendingPathComponent(path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return UIImage(data: data)
    }

    /// Best-effort first-page thumbnail, ~400 pt wide JPEG.
    private func writeThumbnail(for data: Data) -> String? {
        guard let thumbnails = thumbnailsDirectory else { return nil }
        guard let document = PDFDocument(data: data),
              document.pageCount > 0,
              let page = document.page(at: 0) else {
            return nil
        }
        try? FileManager.default.createDirectory(at: thumbnails, withIntermediateDirectories: true)

        let image = page.thumbnail(of: CGSize(width: 400, height: 560), for: .mediaBox)
        guard let jpeg = image.jpegData(compressionQuality: 0.7) else { return nil }

        let name = "thumb-\(UUID().uuidString).jpg"
        let url = thumbnails.appendingPathComponent(name)
        do {
            try jpeg.write(to: url, options: .atomic)
            return "Thumbnails/\(name)"
        } catch {
            return nil
        }
    }

    // MARK: - Persistence

    private func loadRecordsSync() {
        guard let metadataFile = metadataFileURL,
              let data = try? Data(contentsOf: metadataFile) else {
            records = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode([StoredPDFRecord].self, from: data) else {
            records = []
            return
        }
        // Drop records whose backing file disappeared (e.g. user cleaned the
        // container via Settings). This prunes ghosts; it never deletes PDFs.
        records = decoded.sorted { $0.createdAt > $1.createdAt }
        let staleIDs = Set(records.filter { !exists($0) }.map(\.id))
        if !staleIDs.isEmpty {
            records.removeAll { staleIDs.contains($0.id) }
            try? persistRecords(to: metadataFile)
        }
    }

    private func persistRecords(to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: file, options: .atomic)
    }
}
