import Foundation
import WebKit

/// Loads a URL (or HTML string) in an offscreen WKWebView and converts it to
/// a paginated PDF. All failures are thrown as `ConversionError`s — a failed
/// load becomes a product error state, never a PDF page full of error text.
///
/// Continuation contract (audited for release):
/// • Every continuation is wrapped in a resume-exactly-once gate, so racing
///   completion/timeout/termination/cancel paths can never double-resume or
///   orphan a suspended task.
/// • Task cancellation resumes pending work immediately (no 20-second
///   zombie waits after the user taps Cancel).
/// • A terminated web process fails the pending navigation — or, if it dies
///   mid-render, fails the render promptly instead of leaving conversion UI
///   spinning forever.
///
/// Must be used from the main actor (WKWebView requirement); the coordinator
/// awaits these calls like any other async work.
private enum WebTiming {
    /// Overall navigation timeout.
    static let navigationTimeout: TimeInterval = 20
    /// Budget for waiting on lazy content to settle.
    static let stabilizationBudget: TimeInterval = 4
}

/// Wraps a continuation so it resolves exactly once, from any thread, no
/// matter how many racing paths try to finish it. This is what makes
/// timeout / delegate callback / cancellation / process-death mutually
/// exclusive without ordering assumptions.
///
/// Internal (not private) so gate semantics are directly unit-testable.
final class WebGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var resolved = false
    private var resolvedValue: Result<T, Error>?
    private let resolve: (Result<T, Error>) -> Void

    init(_ resolve: @escaping (Result<T, Error>) -> Void) {
        self.resolve = resolve
    }

    func succeed(_ value: T) { finish(.success(value)) }
    func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !resolved else {
            lock.unlock()
            return
        }
        resolved = true
        resolvedValue = result
        lock.unlock()
        resolve(result)
    }
}

@MainActor
final class WebPDFConverter: NSObject, WKNavigationDelegate {

    struct Capture {
        let data: Data
        let title: String?
    }

    /// Desktop-ish capture width in points. Content is scaled to the target
    /// page width during slicing, keeping vectors crisp.
    private static let captureWidth: CGFloat = 768
    /// Hard ceiling for captured height (infinite-scroll protection).
    private static let maxCaptureHeight: CGFloat = 30_000

    // MARK: - Resume-exactly-once gates

    // Pending gates — non-nil only while the corresponding async wait runs.
    // `webViewWebContentProcessDidTerminate` fails ALL of them at once;
    // WebGate guarantees exactly-once resolution even if a WebKit callback
    // arrives afterwards for the same operation.
    private var navigationGate: WebGate<Void>?
    private var evaluationGate: WebGate<Any>?
    private var renderGate: WebGate<Data>?
    private var navigationTimeoutTask: Task<Void, Never>?
    /// Set when the web process died AFTER a successful navigation; every
    /// later phase checks it and throws instead of rendering garbage.
    private var webProcessIsDead = false

    // MARK: - Public API

    /// Quick capture: the page as loaded, sliced into sensible pages.
    /// Auto paper size keeps a single full-height page; fixed sizes paginate.
    func captureWebPage(url: URL, options: ConversionOptions) async throws -> Capture {
        let webView = try await loadInWebView(.url(url))
        defer { dismantle(webView) }

        try await stabilize(webView)
        let height = try await measuredContentHeight(webView)
        let capture = try await renderToPDF(webView, height: height)
        let title = webView.title

        if options.paperSize.isFixed {
            let sliced = try PDFAssembly.slicingCapture(capture, to: options.paperSize.pointSize)
            return Capture(data: sliced, title: title)
        }
        return Capture(data: capture, title: title)
    }

    /// Loads shared HTML directly (Mail and some apps hand over the markup).
    func captureHTML(_ html: String, baseURL: URL?, options: ConversionOptions) async throws -> Capture {
        let webView = try await loadInWebView(.html(html, baseURL: baseURL))
        defer { dismantle(webView) }

        try await stabilize(webView)
        let height = try await measuredContentHeight(webView)
        let capture = try await renderToPDF(webView, height: height)
        let title = webView.title

        if options.paperSize.isFixed {
            let sliced = try PDFAssembly.slicingCapture(capture, to: options.paperSize.pointSize)
            return Capture(data: sliced, title: title)
        }
        return Capture(data: capture, title: title)
    }

    /// Clean/Reader pipeline: extract the article from the loaded DOM, render
    /// the editorial template, paginate to paper. Returns nil when extraction
    /// confidence is too low — the caller falls back to a Quick capture.
    func renderArticle(url: URL, mode: ConversionMode, options: ConversionOptions) async throws -> (data: Data, article: WebContentExtractor.Article)? {
        let webView = try await loadInWebView(.url(url))
        defer { dismantle(webView) }

        try await stabilize(webView)

        let raw = try? await evaluateScript(WebContentExtractor.extractionScript, in: webView)
        guard let article = WebContentExtractor.article(fromScriptResult: raw, url: url),
              article.isUsable else {
            return nil
        }

        let template = WebContentExtractor.templateHTML(for: article, mode: mode)
        let templateView = try await loadInWebView(.html(template, baseURL: nil))
        defer { dismantle(templateView) }
        // Local template HTML settles almost immediately.
        try await stabilize(templateView, budget: 1.0)
        let height = try await measuredContentHeight(templateView)
        let capture = try await renderToPDF(templateView, height: height)

        let pageSize = options.paperSize.isFixed ? options.paperSize.pointSize : PDFPaperSize.a4.pointSize
        let sliced = try PDFAssembly.slicingCapture(capture, to: pageSize)
        return (sliced, article)
    }

    // MARK: - Loading

    private enum LoadRequest {
        case url(URL)
        case html(String, baseURL: URL?)
    }

    private func loadInWebView(_ request: LoadRequest) async throws -> WKWebView {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: Self.captureWidth, height: 900))
        webView.navigationDelegate = self
        webProcessIsDead = false
        // Attach to a window so layout, media queries and lazy loading behave.
        if webViewWindow == nil {
            let host = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.captureWidth, height: 900))
            host.isHidden = true
            webViewWindow = host
        }
        webViewWindow?.addSubview(webView)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let gate = WebGate<Void> { result in
                        switch result {
                        case .success: continuation.resume()
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    }
                    self.navigationGate = gate

                    switch request {
                    case .url(let url):
                        webView.load(URLRequest(url: url))
                    case .html(let html, let baseURL):
                        webView.loadHTMLString(html, baseURL: baseURL)
                    }

                    self.navigationTimeoutTask = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(WebTiming.navigationTimeout * 1_000_000_000))
                        // The gate makes this race with didFinish/didFail/
                        // termination/cancellation safe — first finish wins.
                        self?.navigationGate?.fail(ConversionError.pageTooSlow)
                    }
                }
            } onCancel: {
                // Cancellation must not leave the load waiting out its full
                // timeout — fail the gate immediately.
                Task { @MainActor [weak self] in
                    self?.navigationGate?.fail(CancellationError())
                }
            }
        } catch {
            dismantle(webView)
            throw error
        }

        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        navigationGate = nil
        loadedWebViews.append(webView)
        return webView
    }

    private var webViewWindow: UIWindow?
    private var loadedWebViews: [WKWebView] = []

    private func dismantle(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        loadedWebViews.removeAll { $0 === webView }
        navigationGate = nil
        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        evaluationGate = nil
        renderGate = nil
        if loadedWebViews.isEmpty {
            webViewWindow?.isHidden = true
            webViewWindow = nil
            webProcessIsDead = false
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView,
                             didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            guard !self.webProcessIsDead else { return }
            self.navigationGate?.succeed(())
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.navigationGate?.fail(ConversionError.from(networkError: error))
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.navigationGate?.fail(ConversionError.from(networkError: error))
        }
    }

    /// Web process death: fails EVERY currently pending continuation —
    /// navigation, JS evaluation, and PDF render alike. WebGate guarantees
    /// exactly-once resolution, so this is safe even when a WebKit callback
    /// arrives afterwards for an already-failed operation. No continuation
   /// can remain suspended, none can resume twice, and no conversion UI can
    /// keep spinning against a dead process.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.webProcessIsDead = true
            let error = ConversionError.webProcessTerminated
            self.navigationGate?.fail(error)
            self.evaluationGate?.fail(error)
            self.renderGate?.fail(error)
        }
    }

    // MARK: - Stability + measurement

    /// Waits briefly for lazy content: polls document height until it stops
    /// changing twice in a row, within a fixed budget.
    private func stabilize(_ webView: WKWebView, budget: TimeInterval = WebTiming.stabilizationBudget) async throws {
        let step: UInt64 = 400_000_000
        var lastHeight: CGFloat = -1
        var stableCount = 0
        let deadline = Date().addingTimeInterval(budget)

        while Date() < deadline {
            try Task.checkCancellation()
            if webProcessIsDead { throw ConversionError.webProcessTerminated }
            try? await Task.sleep(nanoseconds: step)
            let height = (try? await measuredContentHeight(webView)) ?? 0
            if abs(height - lastHeight) < 1 {
                stableCount += 1
                if stableCount >= 2 { return }
            } else {
                stableCount = 0
            }
            lastHeight = height
        }
    }

    @discardableResult
    private func evaluateScript(_ script: String, in webView: WKWebView) async throws -> Any {
        if webProcessIsDead { throw ConversionError.webProcessTerminated }
        try Task.checkCancellation()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                let gate = WebGate<Any> { result in
                    switch result {
                    case .success(let value): continuation.resume(returning: value)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                self.evaluationGate = gate
                webView.evaluateJavaScript(script) { result, _ in
                    Task { @MainActor in
                        self.evaluationGate = nil
                        if let result {
                            gate.succeed(result)
                        } else {
                            gate.fail(ConversionError.generationFailed)
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.evaluationGate?.fail(CancellationError())
            }
        }
    }

    private func measuredContentHeight(_ webView: WKWebView) async throws -> CGFloat {
        let script = "Math.max(document.body ? document.body.scrollHeight : 0," +
                     "document.documentElement ? document.documentElement.scrollHeight : 0," +
                     "document.body ? document.body.offsetHeight : 0," +
                     "document.documentElement ? document.documentElement.offsetHeight : 0)"
        let result = try await evaluateScript(script, in: webView)
        let height: CGFloat
        if let number = result as? NSNumber {
            height = CGFloat(truncating: number)
        } else {
            height = webView.scrollView.contentSize.height
        }
        return min(max(height, webView.frame.height), Self.maxCaptureHeight)
    }

    private func renderToPDF(_ webView: WKWebView, height: CGFloat) async throws -> Data {
        if webProcessIsDead { throw ConversionError.webProcessTerminated }
        try Task.checkCancellation()

        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.frame.width, height: height)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                let gate = WebGate<Data> { result in
                    switch result {
                    case .success(let data): continuation.resume(returning: data)
                    case .failure(let error): continuation.resume(throwing: error)
                    }
                }
                self.renderGate = gate
                webView.createPDF(configuration: configuration) { result in
                    switch result {
                    case .success(let data):
                        gate.succeed(data)
                    case .failure:
                        gate.fail(ConversionError.generationFailed)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.renderGate?.fail(CancellationError())
            }
        }
    }
}
