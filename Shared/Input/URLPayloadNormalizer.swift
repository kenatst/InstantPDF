import Foundation
import UniformTypeIdentifiers

/// Provider-normalization layer for share payloads.
///
/// Why this exists: hosts like X/Twitter expose link shares through wildly
/// inconsistent NSItemProvider combinations — a bare `public.plain-text`
/// carrying "post text https://x.com/user/status/1", UTF-8 data instead of
/// string objects, `twitter.com`/`mobile.twitter.com` host variants, or a
/// URL attachment plus a separate text attachment for the same post. The
/// typed lanes in `InputProcessor` handled each shape in isolation; anything
/// that didn't fit degraded into a text conversion or a web failure.
///
/// This layer runs ONCE over the extracted items and guarantees the product
/// contract: whenever a valid http(s) URL can be resolved from any payload
/// combination, the share is treated as WEB CONTENT and converted normally,
/// with the accompanying text retained as a graceful fallback — never
/// discarded, never duplicated.
///
/// No private APIs, no scraping: only payload shapes apps already hand to
/// the share sheet are interpreted.
enum URLPayloadNormalizer {

    /// Text longer than this, after stripping the URL, is substantial enough
    /// to remain its own document section rather than a mere caption.
    static let standaloneLeftoverThreshold = 600

    // MARK: - URL resolution from raw strings

    /// Ensures the standard URL/text representations are resolvable on
    /// providers whose hosts registered payloads under nonstandard type
    /// identifiers. `registerDataRepresentation` ADDS a data provider for an
    /// identifier the host didn't include — it never replaces or mutates the
    /// host's own registrations, so this is strictly additive and safe.
    static func registerStandardRepresentations(on provider: NSItemProvider) {
        let registered = Set(provider.registeredTypeIdentifiers)
        if !registered.contains(UTType.url.identifier)
            && !registered.contains(UTType.plainText.identifier)
            && !registered.contains(UTType.utf8PlainText.identifier) {
            // Only when nothing typed is available at all: expose plain-text.
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.plainText.identifier,
                visibility: .all) { completion in
                    completion(nil, NSError(domain: "com.kenatst.pdfit",
                                            code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "No payload registered"]))
                    return nil
                }
        }
    }

    /// Resolves an http(s) URL from a raw string payload: the whole trimmed
    /// string as a URL first, then the first embedded URL in prose.
    static func url(fromString raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), isHTTPURL(direct) {
            return canonical(direct)
        }
        guard let detected = firstURL(in: trimmed) else { return nil }
        return canonical(detected.url)
    }

    struct DetectedLink {
        let url: URL
        let range: Range<String.Index>
    }

    /// Finds the first http(s) URL inside arbitrary text.
    ///
    /// Two passes:
    /// 1. `NSDataDetector` link detection — covers fully-qualified URLs.
    /// 2. A conservative scheme-less scan restricted to hosts where a bare
    ///    domain is unambiguous (x.com, twitter.com, t.co and variants) —
    ///    X posts frequently arrive as "text x.com/user/status/1" with no
    ///    scheme at all. Generic scheme-less detection is deliberately NOT
    ///    attempted: too many false positives (filenames, sentences).
    static func firstURL(in text: String) -> DetectedLink? {
        if let detected = detectorURL(in: text) { return detected }
        return schemelessSocialURL(in: text)
    }

    private static func detectorURL(in text: String) -> DetectedLink? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let results = detector.matches(in: text, options: [], range: range)
        // Prefer real http(s) links; skip mailto:, tel: and friends.
        for result in results {
            guard let url = result.url, isHTTPURL(url), result.range.location != NSNotFound else { continue }
            guard let swiftRange = Range(result.range, in: text) else { continue }
            return DetectedLink(url: url, range: swiftRange)
        }
        return nil
    }

    private static let schemelessHostPattern
        = "(?:https?://)?(?:www\\.|mobile\\.|m\\.)?(?:x\\.com|twitter\\.com|t\\.co)/[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+"

    private static func schemelessSocialURL(in text: String) -> DetectedLink? {
        guard let regex = try? NSRegularExpression(pattern: schemelessHostPattern) else { return nil }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        var candidate = String(text[matchRange])
        // Trim trailing sentence punctuation the regex had to allow.
        while let last = candidate.last, ".!?,,;:)…\"'" .contains(last) {
            candidate.removeLast()
        }
        guard !candidate.isEmpty else { return nil }
        if !(candidate.hasPrefix("http://") || candidate.hasPrefix("https://")) {
            candidate = "https://" + candidate
        }
        guard let url = URL(string: candidate), isHTTPURL(url) else { return nil }
        // Shrink the reported range to exclude the trimmed punctuation.
        let urlLength = candidate.count
        let adjustedEnd = text.index(matchRange.lowerBound, offsetBy: urlLength, limitedBy: text.endIndex) ?? text.endIndex
        return DetectedLink(url: url, range: matchRange.lowerBound..<adjustedEnd)
    }

    // MARK: - Canonicalization

    /// Canonicalizes host variants so equivalent links behave identically:
    /// twitter.com / mobile.twitter.com / m.twitter.com / www variants →
    /// the canonical https host. t.co wrappers are preserved — they are the
    /// author's actual link and redirect publicly.
    static func canonical(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var rawHost = components.host?.lowercased()
        // NSDataDetector frequently hands back scheme-less bare domains with
        // a synthesized http:// scheme AND no parsed host — recover it from
        // the path (e.g. "x.com/elon/status/1" → host "x.com").
        if rawHost == nil, let absolute = components.string?.lowercased() {
            for prefix in ["http://", "https://"] where absolute.hasPrefix(prefix) {
                let rest = String(absolute.dropFirst(prefix.count))
                if let slash = rest.firstIndex(of: "/") {
                    rawHost = String(rest[rest.startIndex..<slash])
                } else {
                    rawHost = rest
                }
            }
        }
        guard let normalizedHost = rawHost else { return url }
        let host = normalizedHost.hasPrefix("www.") ? String(normalizedHost.dropFirst(4)) : normalizedHost

        if host == "twitter.com" || host == "mobile.twitter.com" || host == "m.twitter.com" {
            components.host = "x.com"
            components.scheme = "https"
            return components.url ?? url
        }
        if host == "x.com" && components.scheme?.lowercased() != "https" {
            components.scheme = "https"
            return components.url ?? url
        }
        return url
    }

    // MARK: - Collection normalization

    /// Normalizes a freshly extracted item list:
    /// • Text items containing a resolvable http(s) URL become URL items
    ///   (with the text retained as `attachedText` fallback); genuinely
    ///   long remaining text stays an additional text item.
    /// • A lone URL item plus a lone text item in the SAME share (two
    ///   attachments from one host action — the classic social-app shape)
    ///   folds the text into the URL item as its fallback.
    static func normalize(_ items: [IncomingItem]) -> [IncomingItem] {
        var normalized: [IncomingItem] = []

        for item in items {
            switch item.kind {
            case .text(let text):
                if let link = firstURL(in: text) {
                    let canonicalURL = canonical(link.url)
                    let leftover = text.replacingCharacters(with: " ", in: link.range)
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if leftover.count > standaloneLeftoverThreshold {
                        // Substantial standalone text survives as its own item.
                        // The URL item carries the leftover caption so the
                        // companion-fold below recognizes this as an
                        // intentional split — never a duplicate hand-over.
                        normalized.append(item)
                        normalized.append(IncomingItem(kind: .url(canonicalURL),
                                                       title: item.title,
                                                       sourceURL: canonicalURL,
                                                       source: ContentSource.detect(from: canonicalURL),
                                                       index: item.index,
                                                       attachedText: leftover))
                    } else {
                        // Caption-style text: keep it as the URL's fallback only.
                        normalized.append(IncomingItem(kind: .url(canonicalURL),
                                                       title: item.title,
                                                       originalFilename: item.originalFilename,
                                                       sourceURL: canonicalURL,
                                                       source: ContentSource.detect(from: canonicalURL),
                                                       index: item.index,
                                                       attachedText: text))
                    }
                } else {
                    normalized.append(item)
                }
            default:
                normalized.append(item)
            }
        }

        normalized = foldCompanionText(normalized)
        return reindex(normalized)
    }

    /// Exactly one URL item + exactly one text item in one share = the same
    /// content handed over twice (X posts, LinkedIn, Reddit titles). Fold the
    /// text into the URL item so conversion stays pure web conversion with a
    /// text fallback — not a web page followed by a stray text page.
    ///
    /// Skipped when the URL item came from a split long-text payload (its
    /// attachedText is already populated): that pair must stay two items.
    private static func foldCompanionText(_ items: [IncomingItem]) -> [IncomingItem] {
        let urlIndices = items.indices.filter {
            if case .url = items[$0].kind { return true }
            return false
        }
        let textIndices = items.indices.filter {
            if case .text = items[$0].kind { return true }
            return false
        }
        guard urlIndices.count == 1, textIndices.count == 1, items.count == 2 else {
            return items
        }

        let urlIndex = urlIndices[0]
        let textIndex = textIndices[0]
        guard case .url(let url) = items[urlIndex].kind,
              case .text(let text) = items[textIndex].kind else {
            return items
        }
        // The URL was split out of a long shared text payload: the pair is
        // intentional, not a duplicate hand-over.
        if items[urlIndex].attachedText != nil {
            return items
        }

        var folded = items[urlIndex]
        let combined = folded.attachedText.map { $0 + "\n\n" + text } ?? text
        folded = IncomingItem(kind: .url(url),
                              title: folded.title,
                              originalFilename: folded.originalFilename,
                              sourceURL: folded.sourceURL,
                              source: folded.source,
                              index: min(folded.index, items[textIndex].index),
                              attachedText: combined)
        return [folded]
    }

    private static func reindex(_ items: [IncomingItem]) -> [IncomingItem] {
        items.enumerated().map { position, item in
            var copy = item
            copy.index = position
            return copy
        }
    }
    private static func isHTTPURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https"
    }
}

private extension String {
    /// Replaces the given character range with `replacement`.
    func replacingCharacters(with replacement: String, in range: Range<Index>) -> String {
        var copy = self
        copy.replaceSubrange(range, with: replacement)
        return copy
    }
}
