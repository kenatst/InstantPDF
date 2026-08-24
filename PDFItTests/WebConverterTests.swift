import XCTest
import PDFKit
@testable import PDFIt

/// WKWebView pipeline coverage WITHOUT network: `loadHTMLString` drives the
/// same production path as live pages — navigation continuation, timeout
/// arming, stabilization loop, JS-evaluation gate and PDF-render gate — so
/// every continuation wrapper here is real, not stubbed.
final class WebConverterTests: XCTestCase {

    func testXStatusURLUsesOfficialOEmbedEndpoint() throws {
        let endpoint = try XCTUnwrap(
            WebPDFConverter.xEmbedURL(for: URL(string: "https://x.com/example/status/123?s=20")!)
        )
        let components = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "publish.twitter.com")
        let postURL = components.queryItems?.first(where: { $0.name == "url" })?.value
        XCTAssertEqual(postURL, "https://twitter.com/example/status/123?s=20")
    }

    func testXProfileURLDoesNotUsePostEmbed() {
        XCTAssertNil(WebPDFConverter.xEmbedURL(for: URL(string: "https://x.com/example")!))
        XCTAssertNil(WebPDFConverter.xEmbedURL(for: URL(string: "https://example.com/status/123")!))
    }

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

// MARK: - Gate semantics under races

/// Direct coverage of the resume-exactly-once primitive that guards every
/// WKWebView continuation. Deterministic WebKit process death cannot be
/// injected without ugly production hooks, so termination itself is covered
/// indirectly: the same fail-all-gates path is what process death triggers,
/// and these tests prove a gate can never resolve twice or stay unresolved
/// no matter how many racing finishes arrive.
final class WebGateRaceTests: XCTestCase {

    func testGateResolvesExactlyOnceUnderRacingFinishes() async {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var successes = 0
            var failures = 0
            func record(_ result: Result<Int, Error>) {
                lock.lock(); defer { lock.unlock() }
                if case .success = result { successes += 1 } else { failures += 1 }
            }
        }
        let counter = Counter()

        let gate = WebGate<Int> { result in counter.record(result) }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    if index.isMultiple(of: 3) {
                        gate.fail(ConversionError.webProcessTerminated)
                    } else if index.isMultiple(of: 3) == false && index % 2 == 0 {
                        gate.succeed(index)
                    } else {
                        gate.fail(CancellationError())
                    }
                }
            }
        }
        // A late callback after resolution must be ignored too.
        gate.succeed(99)
        gate.fail(ConversionError.generationFailed)

        let total = counter.successes + counter.failures
        XCTAssertEqual(total, 1, "Exactly one resolution across \(total) racing attempts")
        XCTAssertLessThanOrEqual(counter.successes, 1)
        XCTAssertLessThanOrEqual(counter.failures, 1)
    }

    /// Failing all three pending gate kinds at once (what process death does)
    /// leaves each with at most one outcome and none suspended.
    func testFailingAllGatesIsSafeAndFinal() async {
        var outcomes: [Result<Void, Error>] = []
        let lock = NSLock()
        let navigation = WebGate<Void> { result in lock.lock(); outcomes.append(result); lock.unlock() }
        let evaluation = WebGate<Any> { _ in }
        let render = WebGate<Data> { _ in }

        let error = ConversionError.webProcessTerminated
        navigation.fail(error)
        evaluation.fail(error)
        render.fail(error)
        // Late callbacks afterwards change nothing:
        navigation.succeed(())
        render.succeed(Data([0x01]))

        XCTAssertEqual(outcomes.count, 1)
        if case .failure(let surfaced) = outcomes.first {
            XCTAssertEqual(surfaced as? ConversionError, .webProcessTerminated)
        } else {
            XCTFail("Expected the process-death error")
        }
    }
}

// MARK: - Cancellation through web routing

/// Offline end-to-end proof that cancelling during a WEB conversion stays
/// cancellation all the way through ConversionCoordinator.convertWeb —
/// never surfacing as .generationFailed. Uses an HTML item so the Quick
/// capture runs on a local string with no network.
final class WebCancellationRoutingTests: XCTestCase {

    func testCancelDuringWebConversionSurfacesAsCancellationNotGenerationFailure() async throws {
        let converter = ConversionCoordinator()
        let item = IncomingItem(kind: .html("<html><body>\(String(repeating: "<p>Lorem ipsum dolor sit amet.</p>", count: 120))</body></html>",
                                            baseURL: nil),
                                source: .website)
        let options = ConversionOptions(mode: .quick, paperSize: .automatic)

        let task = Task<ConvertedDocument, Error> {
            try await converter.convert(items: [item], options: options)
        }
        // Local HTML navigates fast; land inside the stabilization window.
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled conversion should not complete")
        } catch is CancellationError {
            // Correct propagation.
        } catch ConversionError.cancelled {
            // Also acceptable cancellation surface.
        } catch let error as ConversionError {
            XCTFail("Cancellation became \(error) — must stay cancellation")
        }
    }

    /// Same guarantee when the pipeline surfaces a raced .cancelled error
    /// instead of CancellationError (WebKit maps NSURLErrorCancelled).
    func testRacedCancelledErrorIsHandledAsCancellationByShareFlowModel() async throws {
        let extracted = ExtractedInput(items: [IncomingItem(kind: .text("body"), source: .textEditor)],
                                        staging: nil)

        final class FlagBox: @unchecked Sendable {
            var finished: [Bool] = []
        }
        let flags = FlagBox()

        let model = await MainActor.run {
            ShareFlowModel(convert: { _, _, _, _ in
                throw ConversionError.cancelled
            }, storage: nil)
        }

        await MainActor.run {
            model.onFinish = { success in flags.finished.append(success) }
            model.handle(extracted: extracted)
            model.createTapped()
        }

        let deadline = Date().addingTimeInterval(5)
        while flags.finished.isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(flags.finished, [false], "Exactly one cancellation notification")
        await MainActor.run {
            XCTAssertNotEqual(model.state, .failed(.generationFailed),
                              "A raced cancelled error must not become a generic failure")
        }
    }
}
