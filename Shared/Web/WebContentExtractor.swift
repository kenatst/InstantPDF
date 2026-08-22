import Foundation

/// Reader-like content extraction executed inside the loaded WKWebView.
/// Pure JavaScript heuristics on the public DOM — no server calls, no
/// scraping beyond what the page itself served, no private APIs.
enum WebContentExtractor {

    struct Article {
        let title: String
        let author: String?
        let siteName: String
        let html: String
        let textLength: Int
        let url: URL?

        /// Extraction confidence: enough real text to be worth a Clean/Reader
        /// document rather than falling back to a visual capture.
        var isUsable: Bool { textLength >= 400 && !html.isEmpty }
    }

    /// Runs against the live DOM and returns raw extraction JSON.
    /// Kept as a computed constant so tests can at least assert its shape.
    static var extractionScript: String {
        """
        (function() {
            function textLength(el) {
                return (el.innerText || '').trim().length;
            }
            var selectors = ['article', 'main', '[role="main"]', '.post-content',
                             '.entry-content', '.article-body', '.article__body',
                             '#content', '.content', 'articlebody'];
            var best = null;
            var bestLength = 0;
            for (var i = 0; i < selectors.length; i++) {
                var nodes = document.querySelectorAll(selectors[i]);
                for (var j = 0; j < nodes.length; j++) {
                    var len = textLength(nodes[j]);
                    if (len > bestLength) { best = nodes[j]; bestLength = len; }
                }
            }
            if (!best || bestLength < 200) { best = document.body; }

            var clone = best.cloneNode(true);
            var junk = clone.querySelectorAll('script, style, noscript, iframe, form, nav, header, footer, aside, button, svg, [role="navigation"], [aria-hidden="true"], .ad, .ads, .adsbygoogle, .sidebar, .share, .sharing, .newsletter, .paywall, .cookie');
            for (var k = 0; k < junk.length; k++) { junk[k].remove(); }

            function meta(name) {
                var el = document.querySelector('meta[property="' + name + '"]') ||
                         document.querySelector('meta[name="' + name + '"]');
                return el ? (el.getAttribute('content') || '') : '';
            }

            var text = (clone.innerText || '').trim();
            return {
                title: (document.title || '').trim().slice(0, 160),
                author: (meta('author') || meta('article:author')).slice(0, 120),
                siteName: (meta('og:site_name') || location.hostname).slice(0, 80),
                html: clone.innerHTML,
                textLength: text.length
            };
        })();
        """
    }

    /// Parses the JS result dictionary into an `Article`.
    static func article(fromScriptResult result: Any?, url: URL?) -> Article? {
        guard let dict = result as? [String: Any] else { return nil }
        guard let html = dict["html"] as? String, !html.isEmpty else { return nil }

        let title = (dict["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let author = (dict["author"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let siteName = (dict["siteName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let textLength = dict["textLength"] as? Int ?? 0
        let host = url?.host ?? siteName

        return Article(title: title.isEmpty ? (host.isEmpty ? "Webpage" : host) : title,
                       author: author?.isEmpty == true ? nil : author,
                       siteName: siteName.isEmpty ? host : siteName,
                       html: html,
                       textLength: textLength,
                       url: url)
    }

    // MARK: - Editorial template

    /// Builds the Clean/Reader HTML document. Typography-first, paper-white,
    /// no product branding anywhere.
    static func templateHTML(for article: Article, mode: ConversionMode) -> String {
        let serif = mode == .reader
        let bodyFont = serif
            ? "-apple-system-serif, 'Iowan Old Style', 'Palatino', Georgia, serif"
            : "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
        let baseSize = serif ? "17pt" : "13pt"
        let lineHeight = serif ? "1.65" : "1.55"

        let title = escapeHTML(article.title)
        let kicker = escapeHTML(article.siteName)
        let authorLine = article.author.map { "<div class=\"byline\">\(escapeHTML($0))</div>" } ?? ""

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
            @page { margin: 0; }
            * { box-sizing: border-box; }
            body {
                font-family: \(bodyFont);
                font-size: \(baseSize);
                line-height: \(lineHeight);
                color: #1d1d1f;
                margin: 0;
                padding: 56px 56px 64px 56px;
                background: #ffffff;
            }
            .kicker {
                font-size: 10pt;
                font-weight: 600;
                letter-spacing: 0.08em;
                text-transform: uppercase;
                color: #86868b;
                margin-bottom: 10px;
            }
            h1, h2, h3, h4 {
                font-weight: 700;
                letter-spacing: -0.015em;
                page-break-after: avoid;
            }
            h1 {
                font-size: \(serif ? "26pt" : "22pt");
                line-height: 1.2;
                margin: 0 0 8px 0;
            }
            .byline {
                font-size: 10.5pt;
                color: #6e6e73;
                margin-bottom: 6px;
            }
            hr {
                border: none;
                border-top: 1px solid #d2d2d7;
                margin: 18px 0 22px 0;
            }
            p { margin: 0 0 0.9em 0; }
            img, video {
                max-width: 100%;
                height: auto;
                page-break-inside: avoid;
            }
            figure { margin: 1.2em 0; page-break-inside: avoid; }
            figcaption { font-size: 9.5pt; color: #86868b; }
            a { color: #0066cc; text-decoration: none; }
            blockquote {
                margin: 1em 0;
                padding-left: 14px;
                border-left: 3px solid #d2d2d7;
                color: #4a4a4e;
            }
            pre {
                font-family: ui-monospace, 'SF Mono', Menlo, monospace;
                font-size: 9.5pt;
                background: #f5f5f7;
                padding: 10px 12px;
                border-radius: 6px;
                overflow: hidden;
                page-break-inside: avoid;
            }
            code { font-family: ui-monospace, 'SF Mono', Menlo, monospace; font-size: 0.85em; }
            ul, ol { padding-left: 1.4em; }
            .source {
                margin-top: 28px;
                padding-top: 10px;
                border-top: 1px solid #d2d2d7;
                font-size: 9pt;
                color: #86868b;
                word-break: break-all;
            }
        </style>
        </head>
        <body>
            <div class="kicker">\(kicker)</div>
            <h1>\(title)</h1>
            \(authorLine)
            <hr>
            \(article.html)
            \(article.url.map { "<div class=\"source\">\(escapeHTML($0.absoluteString))</div>" } ?? "")
        </body>
        </html>
        """
    }

    static func escapeHTML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
