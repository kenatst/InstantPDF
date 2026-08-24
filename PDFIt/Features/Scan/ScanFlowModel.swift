import SwiftUI
import VisionKit
import PDFKit

/// Coordinates the scan flow: VisionKit camera → staged pages → review →
/// conversion through the EXISTING engine (ImagePDFConverter path).
@MainActor
final class ScanFlowModel: ObservableObject {

    @Published var showingCamera = false
    @Published var showingReview = false
    @Published var session = ScanSessionModel()
    /// Batch is a Pro workflow; default policy allows it until StoreKit
    /// wiring flips the entitlement source (Main integration point).
    @Published var advancedBatchEnabled: Bool
    /// True while a conversion is running — prevents interactive dismissal.
    @Published var isConvertingForUI = false

    /// Staging store for scan captures. Internal so tests can seed files
    /// without launching the camera.
    var staging = TempFileStore()

    init(entitlement: EntitlementReading? = nil) {
        if let entitlement {
            self.advancedBatchEnabled = FeaturePolicy.isUnlocked(.advancedBatch, entitlement: entitlement)
        } else {
            self.advancedBatchEnabled = true
        }
    }

    // MARK: - Capture intake

    /// Receives freshly captured images from VNDocumentCameraViewController.
    func ingest(images: [UIImage]) {
        guard !images.isEmpty else { return }
        for image in images {
            guard let data = normalizedJPEG(image) else { continue }
            let url = staging.appendPathComponent("scan-\(UUID().uuidString).jpg")
            do {
                try data.write(to: url, options: .atomic)
                session.append(page: ScannedPage(id: UUID(), imageURL: url))
            } catch {
                continue
            }
        }
        showingReview = !session.isEmpty
    }

    /// Applies the enhancement preset for one page in place on disk.
    /// Runs synchronously per page — callers dispatch to background.
    nonisolated static func enhance(page: inout ScannedPage, store: TempFileStore) {
        let raw: Data
        do { raw = try Data(contentsOf: page.imageURL) } catch { return }
        autoreleasepool {
            let processed = ScanEnhancement.processData(raw, enhancement: page.enhancement)
            let rotated = Self.rotatedJPEG(processed, quarterTurns: page.rotationQuarterTurns)
            let url = store.appendPathComponent("enh-\(UUID().uuidString).jpg")
            if (try? rotated.write(to: url, options: .atomic)) != nil {
                // Keep the original capture; the enhanced copy becomes the
                // conversion source. Originals are cleaned with the session.
                page.imageURL = url
            }
        }
    }

    /// 90°-step rotation baked into pixels so downstream converters see an
    /// upright image regardless of EXIF quirks.
    nonisolated static func rotatedJPEG(_ data: Data, quarterTurns: Int) -> Data {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0, let cg = UIImage(data: data)?.cgImage else { return data }
        let oriented = UIImage(cgImage: cg)
            .rotated(by: CGFloat(turns) * .pi / 2)
        return oriented.jpegData(compressionQuality: 0.85) ?? data
    }

    private func normalizedJPEG(_ image: UIImage) -> Data? {
        let target: UIImage = {
            guard image.imageOrientation != .up else { return image }
            return image
        }()
        // Cap long edge at ~2400 px: readable A4 scans without absurd sizes.
        let maxEdge: CGFloat = 2400
        let longest = max(target.size.width, target.size.height) * target.scale
        if longest > maxEdge {
            let ratio = maxEdge / longest
            let newSize = CGSize(width: target.size.width * ratio,
                                 height: target.size.height * ratio)
            UIGraphicsBeginImageContextWithOptions(newSize, true, 1)
            defer { UIGraphicsEndImageContext() }
            target.draw(in: CGRect(origin: .zero, size: newSize))
            return UIGraphicsGetImageFromCurrentImageContext()?.jpegData(compressionQuality: 0.82)
        }
        return target.jpegData(compressionQuality: 0.82)
    }

    // MARK: - Conversion (existing engine)

    /// Builds IncomingItems and converts via the shared coordinator.
    func createPDF(for group: ScanGroup?, paperSize: PDFPaperSize) async throws -> ConvertedDocument {
        let selectedPages: [ScannedPage]
        if let group {
            selectedPages = session.pages(in: group)
        } else {
            selectedPages = session.pages
        }
        guard !selectedPages.isEmpty else {
            throw ConversionError.noUsableContent
        }

        var items: [IncomingItem] = []
        items.reserveCapacity(selectedPages.count)
        for (index, page) in selectedPages.enumerated() {
            let item = IncomingItem(kind: .image(page.imageURL),
                                    title: group?.name,
                                    source: .photos,
                                    index: index)
            items.append(item)
        }

        var options = ConversionOptions.fromSharedDefaults()
        options.paperSize = paperSize
        options.mode = .quick

        let coordinator = ConversionCoordinator()
        let document = try await coordinator.convert(items: items, options: options)

        // Conversion success is not persistence success. The review session
        // stays alive until the caller confirms every document was written
        // to the Library; otherwise a failed save would destroy the scans.
        return document
    }

    /// Removes all staged scan files (cancel / after full save-all).
    func cleanUp() {
        staging.cleanUp()
        session = ScanSessionModel()
        showingReview = false
    }
}

extension TempFileStore {
    /// Appends a uniquely-named file URL inside this store's directory.
    fileprivate func appendPathComponent(_ name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}

extension UIImage {
    /// Returns the image rotated by `radians` (pixel content, not EXIF tag).
    /// The output canvas swaps width/height for quarter turns so nothing clips.
    func rotated(by radians: CGFloat) -> UIImage {
        let pixelSize = CGSize(width: size.width * scale, height: size.height * scale)
        let isQuarterTurn = abs(sin(radians)) > 0.5
        let canvas = isQuarterTurn
            ? CGSize(width: pixelSize.height, height: pixelSize.width)
            : pixelSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // pixel-exact output regardless of device scale
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)
        return renderer.image { _ in
            let context = UIGraphicsGetCurrentContext()
            context?.translateBy(x: canvas.width / 2, y: canvas.height / 2)
            context?.rotate(by: radians)
            draw(in: CGRect(x: -pixelSize.width / 2, y: -pixelSize.height / 2,
                            width: pixelSize.width, height: pixelSize.height))
        }
    }
}
