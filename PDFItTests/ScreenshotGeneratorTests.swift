import XCTest
import SwiftUI
import PDFKit
import UIKit
@testable import PDFIt

@MainActor
final class ScreenshotGeneratorTests: XCTestCase {

    private let outputDirectory = URL(fileURLWithPath: "/Users/kena/.gemini/antigravity-ide/brain/2212dcf9-be21-43b5-a6b3-30864adda621/screenshots")

    override func setUp() {
        super.setUp()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Snapshot Helpers

    private func snapshotView<V: View>(_ view: V, name: String, width: CGFloat = 393, height: CGFloat = 852) {
        let size = CGSize(width: width, height: height)
        let hosting = UIHostingController(rootView: view)
        hosting.view.frame = CGRect(origin: .zero, size: size)
        hosting.view.backgroundColor = .systemBackground
        
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        hosting.view.layoutIfNeeded()
        
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            hosting.view.layer.render(in: ctx.cgContext)
        }
        
        let fileURL = outputDirectory.appendingPathComponent("\(name).png")
        if let data = image.pngData() {
            try? data.write(to: fileURL)
        }
    }

    private func snapshotViewController(_ vc: UIViewController, name: String, width: CGFloat = 393, height: CGFloat = 852) {
        let size = CGSize(width: width, height: height)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = vc
        window.makeKeyAndVisible()
        vc.view.frame = CGRect(origin: .zero, size: size)
        vc.view.layoutIfNeeded()
        
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            window.layer.render(in: ctx.cgContext)
        }
        
        let fileURL = outputDirectory.appendingPathComponent("\(name).png")
        if let data = image.pngData() {
            try? data.write(to: fileURL)
        }
    }

    // MARK: - Sample PDF Generator

    private func makeSamplePDFData(title: String, pages: Int = 3) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89) // A4
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        return renderer.pdfData { ctx in
            for i in 1...pages {
                ctx.beginPage()
                let titleAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                    .foregroundColor: UIColor.label
                ]
                title.draw(at: CGPoint(x: 50, y: 60), withAttributes: titleAttr)
                
                let subtitleAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                    .foregroundColor: UIColor.secondaryLabel
                ]
                "Page \(i) of \(pages) • PDF It Local Processing".draw(at: CGPoint(x: 50, y: 100), withAttributes: subtitleAttr)
                
                let bodyAttr: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: UIColor.darkGray
                ]
                let sampleText = """
                This is a sample document generated with PDF It.
                
                Features:
                • High-fidelity layout and vector font rendering.
                • Complete privacy: 100% on-device processing.
                • Multi-page merging with preserved aspect ratios.
                • Seamless iOS Share Sheet integration.
                """
                sampleText.draw(in: CGRect(x: 50, y: 140, width: 495, height: 600), withAttributes: bodyAttr)
            }
        }
    }

    // MARK: - Capture Tests

    func testCaptureAllAppScreenshots() throws {
        // 1. Onboarding Pages (1, 2, 3)
        snapshotView(OnboardingView(initialPage: 0), name: "01_onboarding_page1")
        snapshotView(OnboardingView(initialPage: 1), name: "01_onboarding_page2")
        snapshotView(OnboardingView(initialPage: 2), name: "01_onboarding_page3")

        // 2. Settings Screen (Light & Dark)
        snapshotView(NavigationStack { SettingsView() }, name: "05_settings_light")
        snapshotView(NavigationStack { SettingsView() }.preferredColorScheme(.dark), name: "05_settings_dark")

        // 3. Import Sheets
        snapshotView(LinkEntrySheet(onConvert: { _ in }), name: "06_paste_link_sheet")
        snapshotView(TextEntrySheet(onConvert: { _, _ in }), name: "07_paste_text_sheet")
        snapshotView(ConversionErrorSheet(error: .pageUnreachable(reason: "Server returned 404"),
                                          onRetry: {},
                                          offerLinkAsPDF: true,
                                          onSaveLinkAsPDF: {}), name: "09_conversion_error_sheet")

        // 4. Conversion Result Sheet
        let samplePDF = makeSamplePDFData(title: "Safari Web Article — Swift Concurrency", pages: 4)
        let sampleDoc = ConvertedDocument(data: samplePDF,
                                          pageCount: 4,
                                          suggestedTitle: "Safari Web Article — Swift Concurrency",
                                          sourceURL: URL(string: "https://developer.apple.com"),
                                          source: .website)
        snapshotView(ConversionResultSheet(document: sampleDoc), name: "08_conversion_preview_sheet")

        // 5. Empty Library State (Purge all records first to test pristine empty state)
        let storage = StorageManager.shared
        for record in storage.fetchRecords() {
            try? storage.delete(record)
        }
        snapshotView(NavigationStack { LibraryView() }.preferredColorScheme(.dark), name: "03_library_screen_empty_dark")

        // 6. Seed Library with rich realistic documents for Home & Library Views
        let doc1 = ConvertedDocument(data: makeSamplePDFData(title: "Paris Trip Photos", pages: 5),
                                     pageCount: 5,
                                     suggestedTitle: "Paris Trip Photos",
                                     sourceURL: nil,
                                     source: .photos)
        let doc2 = ConvertedDocument(data: makeSamplePDFData(title: "WWDC26 Architecture Guide", pages: 12),
                                     pageCount: 12,
                                     suggestedTitle: "WWDC26 Architecture Guide",
                                     sourceURL: URL(string: "https://apple.com/newsroom"),
                                     source: .website)
        let doc3 = ConvertedDocument(data: makeSamplePDFData(title: "Quarterly Financial Overview", pages: 3),
                                     pageCount: 3,
                                     suggestedTitle: "Quarterly Financial Overview",
                                     sourceURL: nil,
                                     source: .files)
        let doc4 = ConvertedDocument(data: makeSamplePDFData(title: "Meeting Notes & Action Items", pages: 2),
                                     pageCount: 2,
                                     suggestedTitle: "Meeting Notes & Action Items",
                                     sourceURL: nil,
                                     source: .textEditor)

        _ = try? storage.save(document: doc1)
        _ = try? storage.save(document: doc2)
        _ = try? storage.save(document: doc3)
        let record4 = try? storage.save(document: doc4)

        // 7. Home Screen with Recent PDFs (Light & Dark)
        snapshotView(NavigationStack { HomeView(showingSettings: .constant(false)) }, name: "02_home_screen_light")
        snapshotView(NavigationStack { HomeView(showingSettings: .constant(false)) }.preferredColorScheme(.dark), name: "02_home_screen_dark")

        // 8. Library Screen with Documents (Light & Dark)
        snapshotView(NavigationStack { LibraryView() }, name: "03_library_screen_light")
        snapshotView(NavigationStack { LibraryView() }.preferredColorScheme(.dark), name: "03_library_screen_dark")

        // 9. PDF Viewer Screen (Light & Dark)
        if let record = record4 ?? storage.fetchRecords().first {
            snapshotView(NavigationStack { PDFViewerView(record: record) }, name: "04_pdf_viewer_light")
            snapshotView(NavigationStack { PDFViewerView(record: record) }.preferredColorScheme(.dark), name: "04_pdf_viewer_dark")
        }
    }
}
