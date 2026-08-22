import Foundation
import PDFKit
import UIKit

/// Local-first library storage, shared between the app and the Share
/// Extension through the App Group container.
///
/// Cross-process contract (app and extension are DIFFERENT processes):
/// • There is no long-lived in-memory index. Every operation reads the
///   current `metadata.json` from disk first, so records written by the
///   other process are always visible.
/// • Read-modify-write cycles run inside one `NSFileCoordinator` coordinated
///   writing block, which gives inter-process mutual exclusion — the two
///   processes can save/read/delete concurrently without losing updates.
/// • A per-process serial queue prevents races inside one process.
/// • All writes are atomic; filename collisions are resolved against fresh
///   disk state, never against a cached list.
final class StorageManager {

    static let shared = StorageManager(appGroupID: AppConfiguration.appGroupIdentifier)

    private let containerURL: URL?
    private let queue = DispatchQueue(label: "com.kenatst.pdfit.storage")
    private let fileAccessQueue = DispatchQueue(label: "com.kenatst.pdfit.storage.filecoordination")
    private let coordinator = NSFileCoordinator(filePresenter: nil)

    private var containerDirectory: URL? { containerURL }
    private var documentsDirectory: URL? {
        containerURL?.appendingPathComponent("Documents/PDFs", isDirectory: true)
    }
    private var thumbnailsDirectory: URL? {
        containerURL?.appendingPathComponent("Thumbnails", isDirectory: true)
    }
    private var metadataFileURL: URL? {
        containerURL?.appendingPathComponent("Library/metadata.json")
    }

    /// Production initializer: uses the real App Group container. A nil
    /// container (misconfigured entitlement/group) is a hard, surfaced
    /// error — operations throw `containerUnavailable` instead of silently
    /// writing somewhere the other process can't see.
    convenience init(appGroupID: String) {
        let url = AppConfiguration.appGroupContainerURL
        if url == nil {
            assertionFailure("PDF It: StorageManager initialized without a reachable App Group (\(appGroupID)).")
        }
        self.init(containerURL: url)
    }

    /// Designated initializer — injectable for tests.
    init(containerURL: URL?) {
        self.containerURL = containerURL
    }

    // MARK: - Saving

    /// Persists a converted document. The filename is uniquified against the
    /// CURRENT on-disk state (metadata + existing files), so the app and the
    /// extension racing to save "Article.pdf" both end up with distinct names.
    @discardableResult
    func save(document: ConvertedDocument, date: Date = Date()) throws -> StoredPDFRecord {
        guard let documents = documentsDirectory,
              let metadataFile = metadataFileURL,
              let container = containerDirectory else {
            throw StorageError.containerUnavailable
        }
        return try queue.sync {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadataFile.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)

            let desired = FilenameGenerator.fileName(for: document, date: date)

            // Write the PDF itself first. Its name must not collide with any
            // file already on disk, even an orphaned one.
            let uniqueName = try coordinatedReadModifyWrite(metadataFile) { currentRecords in
                let takenNames = Self.existingNames(records: currentRecords, documentsDirectory: documents)
                let name = FilenameGenerator.uniqueFileName(desired, existingNames: takenNames)
                let relativePath = "Documents/PDFs/\(name)"
                let fileURL = container.appendingPathComponent(relativePath)

                do {
                    try document.data.write(to: fileURL, options: .atomic)
                } catch {
                    throw StorageError.writeFailed(underlying: error.localizedDescription)
                }

                let thumbnailPath = self.writeThumbnail(for: document.data)
                let record = StoredPDFRecord(id: UUID(),
                                             filename: name,
                                             createdAt: date,
                                             relativePath: relativePath,
                                             pageCount: document.pageCount,
                                             fileSize: Int64(document.data.count),
                                             sourceType: document.source.rawValue,
                                             sourceURL: document.sourceURL?.absoluteString,
                                             thumbnailPath: thumbnailPath)
                currentRecords.insert(record, at: 0)
                return record
            }
            return uniqueName
        }
    }

    // MARK: - Queries

    /// All records, newest first, freshly read from disk. Reads never touch
    /// the metadata file — they take a shared coordinated read, no write
    /// lock, no rewrite. Records whose backing file vanished are pruned
    /// (data hygiene — not user data deletion); pruning is the ONLY reason
    /// a fetch ever writes, and it happens through one coordinated
    /// read-modify-write so concurrent saves from the other process survive.
    func fetchRecords() -> [StoredPDFRecord] {
        guard let metadataFile = metadataFileURL else { return [] }
        return queue.sync {
            let records = coordinatedRead(metadataFile)
            let hasGhosts = records.contains { !exists($0) }
            guard hasGhosts else {
                return records.sorted { $0.createdAt > $1.createdAt }
            }

            // Ghosts found: prune them. The mutation re-reads current state
            // inside the coordination section, so any records the other
            // process added meanwhile are kept.
            if let pruned = try? coordinatedReadModifyWrite(metadataFile, mutation: { currentRecords in
                let staleIDs = Set(currentRecords.filter { !self.exists($0) }.map(\.id))
                if !staleIDs.isEmpty {
                    currentRecords.removeAll { staleIDs.contains($0.id) }
                }
                return currentRecords.sorted { $0.createdAt > $1.createdAt }
            }) {
                return pruned
            }
            // Pruning couldn't persist — still return what was read.
            return records.sorted { $0.createdAt > $1.createdAt }
        }
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
        try queue.sync {
            if let url = fileURL(for: record) {
                // Missing file is fine here — the record still must go away.
                try? FileManager.default.removeItem(at: url)
            }
            if let thumbnailPath = record.thumbnailPath,
               let thumbURL = containerURL?.appendingPathComponent(thumbnailPath) {
                try? FileManager.default.removeItem(at: thumbURL)
            }
            _ = try coordinatedReadModifyWrite(metadataFile) { currentRecords -> Bool in
                currentRecords.removeAll { $0.id == record.id }
                return true
            }
        }
    }

    func rename(_ record: StoredPDFRecord, to newRawName: String) throws -> StoredPDFRecord {
        guard let metadataFile = metadataFileURL,
              let documents = documentsDirectory,
              let container = containerDirectory else {
            throw StorageError.containerUnavailable
        }
        return try queue.sync {
            guard let oldURL = fileURL(for: record) else {
                throw StorageError.containerUnavailable
            }

            let sanitized = FilenameGenerator.sanitize(newRawName)
            let desired = sanitized.lowercased().hasSuffix(".pdf") ? sanitized : sanitized + ".pdf"

            let updated: StoredPDFRecord = try coordinatedReadModifyWrite(metadataFile) { currentRecords in
                let takenNames = Self.existingNames(records: currentRecords.filter { $0.id != record.id },
                                                    documentsDirectory: documents)
                let newName = FilenameGenerator.uniqueFileName(desired, existingNames: takenNames)
                let newRelativePath = "Documents/PDFs/\(newName)"
                let newURL = container.appendingPathComponent(newRelativePath)

                do {
                    try FileManager.default.moveItem(at: oldURL, to: newURL)
                } catch {
                    throw StorageError.writeFailed(underlying: error.localizedDescription)
                }

                var mutated = record
                mutated.filename = newName
                mutated.relativePath = newRelativePath

                if let index = currentRecords.firstIndex(where: { $0.id == record.id }) {
                    currentRecords[index] = mutated
                }
                return mutated
            }
            return updated
        }
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

    // MARK: - Coordinated persistence core

    /// Shared coordinated read — never writes, never blocks other readers.
    private func coordinatedRead(_ metadataFile: URL) -> [StoredPDFRecord] {
        fileAccessQueue.sync {
            var records: [StoredPDFRecord] = []
            var coordinationError: NSError?
            coordinator.coordinate(readingItemAt: metadataFile,
                                   options: [],
                                   error: &coordinationError) { coordinatedURL in
                records = Self.decodeRecords(from: coordinatedURL)
            }
            return records
        }
    }

    /// The heart of cross-process safety.
    ///
    /// Runs `mutation` against the CURRENT persisted records inside ONE
    /// `NSFileCoordinator` writing section. Reading and writing share the
    /// same coordination lock, so another process cannot slip its own update
    /// in between our read and write — nothing is ever lost or overwritten.
    ///
    /// `mutation` receives the decoded array (empty when the file doesn't
    /// exist or is unreadable), mutates it in place, and returns whatever
    /// value the caller wants back. The merged array is always persisted
    /// atomically before the coordination lock is released.
    private func coordinatedReadModifyWrite<T>(_ metadataFile: URL,
                                               mutation: (inout [StoredPDFRecord]) throws -> T) throws -> T {
        try fileAccessQueue.sync {
            var result: Result<T, Error>!
            var coordinationError: NSError?

            coordinator.coordinate(writingItemAt: metadataFile,
                                   options: [],
                                   error: &coordinationError) { coordinatedURL in
                do {
                    var records = Self.decodeRecords(from: coordinatedURL)
                    let value = try mutation(&records)
                    try Self.encodeRecords(records, to: coordinatedURL)
                    result = .success(value)
                } catch {
                    result = .failure(error)
                }
            }

            if let coordinationError {
                throw StorageError.writeFailed(underlying: coordinationError.localizedDescription)
            }
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            case nil: throw StorageError.writeFailed(underlying: "File coordination did not complete.")
            }
        }
    }

    private static func decodeRecords(from file: URL) -> [StoredPDFRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([StoredPDFRecord].self, from: data)) ?? []
    }

    private static func encodeRecords(_ records: [StoredPDFRecord], to file: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(records)
        try data.write(to: file, options: .atomic)
    }

    /// Names that must be treated as taken: everything the metadata knows
    /// about PLUS anything actually sitting in the documents directory
    /// (covers orphaned files left by a crashed process).
    private static func existingNames(records: [StoredPDFRecord], documentsDirectory: URL) -> Set<String> {
        var names = Set(records.map(\.filename))
        let children = (try? FileManager.default.contentsOfDirectory(at: documentsDirectory,
                                                                     includingPropertiesForKeys: nil)) ?? []
        for child in children where child.pathExtension.lowercased() == "pdf" {
            names.insert(child.lastPathComponent)
        }
        return names
    }
}
