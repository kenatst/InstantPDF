import Foundation
import WebKit

/// Loads a URL (or HTML string) in an offscreen WKWebView and converts it to
/// a paginated PDF. All failures are thrown as `ConversionError`s — a failed
/// load becomes a product error state, never a PDF page full of error text.
///
/// Must be used from the main actor (WKWebView requirement); the coordinator
/// awaits these calls like any other async work.
/// Timing constants kept outside the actor so they work in default arguments.
private enum WebTiming {
    /// Overall navigation timeout.
    static let navigationTimeout: TimeInterval = 20
    /// Budget for waiting on lazy content to settle.
    static let stabilizationBudget: TimeInterval = 4
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

    private var navigationCompletion: ((Error?) -> Void)?
    private var terminationHandler: (() -> Void)?

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

        let raw = try? await webView.evaluateJavaScript(WebContentExtractor.extractionScript)
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
        // Attach to a window so layout, media queries and lazy loading behave.
        if webViewWindow == nil {
            let host = UIWindow(frame: CGRect(x: 0, y: 0, width: Self.captureWidth, height: 900))
            host.isHidden = true
            webViewWindow = host
        }
        webViewWindow?.addSubview(webView)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            navigationCompletion = { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
            terminationHandler = { [weak self] in
                self?.navigationCompletion?(ConversionError.webProcessTerminated)
                self?.navigationCompletion = nil
            }

            switch request {
            case .url(let url):
                webView.load(URLRequest(url: url))
            case .html(let html, let baseURL):
                webView.loadHTMLString(html, baseURL: baseURL)
            }

            navigationTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(WebTiming.navigationTimeout * 1_000_000_000))
                guard let self = self, self.navigationCompletion != nil else { return }
                self.navigationCompletion?(ConversionError.pageTooSlow)
                self.navigationCompletion = nil
            }
        }

        navigationTimeoutTask?.cancel()
        navigationTimeoutTask = nil
        navigationCompletion = nil
        loadedWebViews.append(webView)
        return webView
    }

    private var webViewWindow: UIWindow?
    private var loadedWebViews: [WKWebView] = []
    private var navigationTimeoutTask: Task<Void, Never>?

    private func dismantle(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        loadedWebViews.removeAll { $0 === webView }
        if loadedWebViews.isEmpty {
            webViewWindow?.isHidden = true
            webViewWindow = nil
        }
    }

    // MARK: - WKNavigationDelegate

    nonisolated func webView(_ webView: WKWebView,
                             didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            self.navigationCompletion?(nil)
            self.navigationCompletion = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFail navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.navigationCompletion?(ConversionError.from(networkError: error))
            self.navigationCompletion = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView,
                             didFailProvisionalNavigation navigation: WKNavigation!,
                             withError error: Error) {
        Task { @MainActor in
            self.navigationCompletion?(ConversionError.from(networkError: error))
            self.navigationCompletion = nil
        }
    }

    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor in
            self.terminationHandler?()
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

    private func measuredContentHeight(_ webView: WKWebView) async throws -> CGFloat {
        let script = "Math.max(document.body ? document.body.scrollHeight : 0," +
                     "document.documentElement ? document.documentElement.scrollHeight : 0," +
                     "document.body ? document.body.offsetHeight : 0," +
                     "document.documentElement ? document.documentElement.offsetHeight : 0)"
        let result = try await webView.evaluateJavaScript(script)
        let height: CGFloat
        if let number = result as? NSNumber {
            height = CGFloat(truncating: number)
        } else {
            height = webView.scrollView.contentSize.height
        }
        return min(max(height, webView.frame.height), Self.maxCaptureHeight)
    }

    private func renderToPDF(_ webView: WKWebView, height: CGFloat) async throws -> Data {
        let configuration = WKPDFConfiguration()
        configuration.rect = CGRect(x: 0, y: 0, width: webView.frame.width, height: height)
        return try await withCheckedThrowingContinuation { continuation in
            webView.createPDF(configuration: configuration) { result in
                switch result {
                case .success(let data):
                    continuation.resume(returning: data)
                case .failure:
                    continuation.resume(throwing: ConversionError.generationFailed)
                }
            }
        }
    }
}
