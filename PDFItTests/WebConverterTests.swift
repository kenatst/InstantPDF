import XCTest
import PDFKit
@testable import PDFIt

/// WKWebView pipeline coverage WITHOUT network: `loadHTMLString` drives the
/// same production path as live pages — navigation continuation, timeout
/// arming, stabilization loop, JS-evaluation gate and PDF-render gate — so
/// every continuation wrapper here is real, not stubbed.
final class WebConverterTests: XCTestCase {

    private func tallHTML(sections: Int = 40) -> String {
        var body = ""
        for index in 0..<sections {
            body += "<h2>Section \(index)</h2><p>Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore.</p>"
        }
        return "<html><head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\"></head><body><h1>Offline fixture</h1>\(body)</body></html>"
    }

    /// Full happy path through every gate: load → didFinish → stabilize →
    /// evaluateJavaScript → createPDF. Fails if any continuation hangs,
    /// double-resumes or throws spuriously.
    func testCaptureLocalHTMLProducesValidSlicedPDF() async throws {
        let converter = await WebPDFConverter()
        let options = ConversionOptions(paperSize: .a4)

        let capture = try await converter.captureHTML(tallHTML(), baseURL: nil, options: options)

        XCTAssertFalse(capture.data.isEmpty)
        let pdf = try XCTUnwrap(PDFDocument(data: capture.data))
        XCTAssertGreaterThan(pdf.pageCount, 1, "Tall content slices into multiple A4 pages")
    }

    func testCaptureAutoPaperKeepsSingleTallPage() async throws {
        let converter = await WebPDFConverter()
        let options = ConversionOptions(paperSize: .automatic)

        let capture = try await converter.captureHTML(tallHTML(sections: 25), baseURL: nil, options: options)

        let pdf = try XCTUnwrap(PDFDocument(data: capture.data))
        XCTAssertEqual(pdf.pageCount, 1, "Auto paper keeps one full-height page")
        let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
        XCTAssertGreaterThan(bounds.height, 1500, "Captured height is preserved")
    }

    func testCaptureTinyHTMLYieldsSingleSmallPage() async throws {
        let converter = await WebPDFConverter()
        let capture = try await converter.captureHTML("<html><body><p>Tiny</p></body></html>",
                                                       baseURL: nil,
                                                       options: ConversionOptions(paperSize: .automatic))
        let pdf = try XCTUnwrap(PDFDocument(data: capture.data))
        XCTAssertEqual(pdf.pageCount, 1)
    }

    /// THE cancellation regression for the WebView lane: cancelling during
    /// stabilization must surface CancellationError promptly through the
    /// gates. A broken continuation would hang here until the 20 s
    /// navigation timeout instead of failing within seconds.
    func testCancelDuringStabilizationFailsPromptlyAsCancellation() async throws {
        let converter = await WebPDFConverter()
        let options = ConversionOptions(paperSize: .automatic)

        let task = Task {
            try await converter.captureHTML(tallHTML(sections: 80), baseURL: nil, options: options)
        }
        // Local HTML navigates fast; 250 ms reliably lands inside the
        // stabilization loop (first poll happens after a 400 ms sleep).
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()

        let started = Date()
        do {
            _ = try await task.value
            XCTFail("Cancelled capture should not complete successfully")
        } catch is CancellationError {
            // Expected propagation path.
        } catch let error as ConversionError {
            XCTAssertEqual(error, .cancelled, "Cancellation must not masquerade as failure")
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10,
                          "Resume must come from cancellation, never the 20 s timeout")
    }
}
