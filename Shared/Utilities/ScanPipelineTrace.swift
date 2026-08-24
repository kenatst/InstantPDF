import Foundation
import os
import PDFKit

/// DEBUG-ONLY pipeline trace for the scan persistence path.
///
/// Every stage of CAPTURE → STAGE → CONVERT → SAVE → VERIFY logs hard facts
/// (counts, byte sizes, file existence, reopen success). Release builds
/// compile these calls down to nothing — zero user-visible output, zero cost.
///
/// Purpose: when a real-device report says "scans don't save", the Xcode
/// console proves exactly WHICH stage broke instead of guessing.
enum ScanPipelineTrace {
    private static let logger = Logger(subsystem: AppConfiguration.appBundleID,
                                       category: "scan-pipeline")

    nonisolated static func capture(pages: Int) {
        #if DEBUG
        logger.notice("CAPTURE: VisionKit returned \(self.pageCountText(pages))")
        #endif
    }

    nonisolated static func staged(url: URL, index: Int, bytes: Int) {
        #if DEBUG
        let exists = FileManager.default.fileExists(atPath: url.path)
        logger.notice("STAGE[\(index)]: bytes=\(bytes) exists=\(exists) dir=\(url.deletingLastPathComponent().lastPathComponent)")
        #endif
    }

    nonisolated static func converted(pageCount: Int, bytes: Int) {
        #if DEBUG
        logger.notice("CONVERT: pdfPages=\(pageCount) bytes=\(bytes)")
        #endif
    }

    nonisolated static func saveStart(bytes: Int) {
        #if DEBUG
        logger.notice("SAVE: payload=\(bytes)B backend=\(StorageManager.activeBackendDescription)")
        #endif
    }

    nonisolated static func saved(recordID: UUID, fileURL: URL?, fileSize: Int64) {
        #if DEBUG
        let exists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        let reopens = fileURL.flatMap { PDFDocument(url: $0) } != nil
        logger.notice("SAVED: id=\(recordID.uuidString) fileExists=\(exists) size=\(fileSize) reopens=\(reopens)")
        assert(exists && fileSize > 0, "ScanPipelineTrace: saved file missing or empty!")
        assert(reopens, "ScanPipelineTrace: saved PDF does not reopen via PDFDocument(url:)!")
        #endif
    }

    nonisolated static func verifiedAfterFreshRead(recordID: UUID, found: Bool) {
        #if DEBUG
        logger.notice("VERIFY: fresh StorageManager sees id=\(recordID.uuidString) -> \(found)")
        #endif
    }

    nonisolated static func failure(stage: String, underlying: String) {
        #if DEBUG
        logger.error("FAIL[\(stage)]: \(underlying)")
        #endif
    }
}

#if DEBUG
private extension ScanPipelineTrace {
    static func pageCountText(_ pages: Int) -> String { "\(pages)" }
}
#endif

extension Logger {
    /// `notice` with a plain string keeps interpolation simple and safe.
    func notice(_ message: String) {
        self.log("\(message, privacy: .public)")
    }
    func error(_ message: String) {
        self.fault("\(message, privacy: .public)")
    }
}
