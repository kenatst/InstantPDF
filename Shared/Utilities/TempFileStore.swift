import Foundation

/// Owns the temporary staging area used while an import or conversion is in
/// flight. Everything lands in one per-session directory that is wiped as
/// soon as the operation finishes, so nothing accumulates on disk.
///
/// `@unchecked Sendable`: the directory is immutable and FileManager calls
/// are thread-safe; staging happens on whichever queue the provider uses.
final class TempFileStore: @unchecked Sendable {
    let directory: URL

    init() {
        let parent = FileManager.default.temporaryDirectory
        directory = parent.appendingPathComponent("pdfit-staging-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Copies a provider-delivered file URL (which is only valid inside the
    /// load callback) into our staging directory and returns the stable copy.
    func stage(_ sourceURL: URL) throws -> URL {
        let attributes = try? sourceURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = attributes?.fileSize, size > InputClassification.maxFileSizeBytes {
            throw ConversionError.fileTooLarge(name: sourceURL.lastPathComponent)
        }

        let destination = directory.appendingPathComponent("\(UUID().uuidString)-\(sourceURL.lastPathComponent)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Writes raw data into the staging directory.
    func stage(data: Data, fileExtension: String) throws -> URL {
        if data.count > InputClassification.maxFileSizeBytes {
            throw ConversionError.fileTooLarge(name: nil)
        }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Removes the whole staging directory. Safe to call twice.
    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
