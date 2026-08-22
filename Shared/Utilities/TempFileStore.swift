import Foundation

/// Owns the temporary staging area for one share/import lifecycle.
/// Everything lands in one per-session directory. The owner (share flow or
/// import flow) keeps the store alive for as long as `IncomingItem`s may
/// reference staged files and calls `cleanUp()` when the lifecycle ends —
/// after conversion succeeds/fails, on cancellation, or on dismissal. Files
/// are never deleted while the user sits on a Ready screen.
///
/// `@unchecked Sendable`: the directory is immutable and FileManager calls
/// are thread-safe; staging happens on whichever queue the provider uses.
final class TempFileStore: @unchecked Sendable {
    let directory: URL
    private let lock = NSLock()
    private var cleanedFlag = false

    /// True once `cleanUp()` ran. Staged URLs must be treated as dead after
    /// this point — reading them back is a lifecycle bug.
    var isCleanedUp: Bool {
        lock.lock(); defer { lock.unlock() }
        return cleanedFlag
    }

    init() {
        let parent = FileManager.default.temporaryDirectory
        directory = parent.appendingPathComponent("pdfit-staging-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        cleanUp()
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

    /// Removes the whole staging directory. Safe to call any number of times.
    func cleanUp() {
        lock.lock()
        let alreadyCleaned = cleanedFlag
        cleanedFlag = true
        lock.unlock()
        guard !alreadyCleaned else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - One-off share exports

    /// Prefix marking throwaway PDFs written ONLY so the share sheet has a
    /// file URL (Library persistence failed, or in-app ShareLink export).
    /// Cleanup targets this prefix alone — never App Group documents and
    /// never staging files still owned by a live conversion.
    private static let exportPrefix = "pdfit-export-"

    static func isExportArtifact(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(exportPrefix)
    }

    /// Destination for a temporary export copy in the system tmp directory.
    static func exportURL(named fileName: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(exportPrefix + fileName)
    }

    /// Deletes leftover export artifacts from previous sessions. Only files
    /// carrying the export prefix are touched; everything else — including
    /// anything outside tmp — is ignored.
    static func purgeExportArtifacts() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil)) ?? []
        for item in contents where isExportArtifact(item) {
            try? FileManager.default.removeItem(at: item)
        }
    }
}
