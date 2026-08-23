import Foundation
import UniformTypeIdentifiers

/// What the Share Extension handed us, in their original order.
struct ExtractedInput {
    var items: [IncomingItem] = []
    /// Attachments we refused (video/audio) — surfaced as a gentle notice.
    var skippedCount: Int = 0
    /// Owns every staged file referenced by `items`. Extraction deliberately
    /// does NOT clean it up: the receiving flow keeps the session alive until
    /// conversion finishes (or is cancelled/abandoned) and then calls
    /// `cleanUp()`. Deleting it earlier invalidates every file-backed item.
    var staging: TempFileStore?

    var isEmpty: Bool { items.isEmpty }
}

/// Extracts share sheet content into normalized `IncomingItem`s.
///
/// Evolved from the original ordered/race-safe InputProcessor: ordering is
/// now guaranteed structurally by sequential async processing, and large
/// payloads (images, PDFs, files) are staged as file URLs instead of being
/// decoded into memory.
final class InputProcessor {

    /// Extracts every supported attachment, preserving share sheet order.
    func extract(from context: NSExtensionContext) async -> ExtractedInput {
        await extract(extensionItems: context.inputItems as? [NSExtensionItem] ?? [])
    }

    /// Testable core: extraction from explicit extension items, so share-flow
    /// regressions can run without a live extension host.
    func extract(extensionItems: [NSExtensionItem]) async -> ExtractedInput {
        let store = TempFileStore()

        var result = ExtractedInput(staging: store)
        var index = 0

        for item in extensionItems {
            let itemTitle = item.attributedTitle?.string ?? item.attributedContentText?.string
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // X/Twitter and other social hosts register link payloads
                // under nonstandard identifiers that hide the real URL/text
                // representations from the typed lanes below. Registering the
                // known-good identifiers makes loadItem resolve them; the
                // provider's own registrations stay intact.
                URLPayloadNormalizer.registerStandardRepresentations(on: provider)
                if let incoming = await process(provider: provider,
                                                 itemTitle: itemTitle,
                                                 index: index,
                                                 store: store) {
                    result.items.append(incoming)
                } else {
                    result.skippedCount += 1
                }
                index += 1
            }
        }

        result.items.sort { $0.index < $1.index }
        // Provider normalization: any resolvable http(s) URL — including one
        // embedded in shared text or recovered from an opaque payload —
        // becomes real web content, with companion text kept as fallback.
        result.items = URLPayloadNormalizer.normalize(result.items)
        return result
    }

    // MARK: - Per-provider work

    private func process(provider: NSItemProvider,
                         itemTitle: String?,
                         index: Int,
                         store: TempFileStore) async -> IncomingItem? {

        let registered = provider.registeredTypeIdentifiers

        // Reject video/audio before anything else.
        if registered.contains(where: InputClassification.isUnsupported) {
            return nil
        }

        // Specific document types beat the generic file-URL lane: some hosts
        // advertise public.file-url whose representation is URL metadata, not
        // the payload itself. Loading by concrete type always yields bytes.
        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return await loadAsFile(provider: provider,
                                    type: .pdf,
                                    itemTitle: itemTitle,
                                    index: index,
                                    store: store)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await loadImage(provider: provider, itemTitle: itemTitle, index: index, store: store)
        }

        // Remaining files arrive as a file URL — big payloads stay out of RAM.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFileURL(provider: provider, itemTitle: itemTitle, index: index, store: store)
        }

        // Webpage intent beats everything textual: Safari and most browsers
        // hand over the URL first. Non-http(s) URLs fall through below.
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider: provider), isHTTPURL(url) {
            return IncomingItem(kind: .url(url),
                                title: itemTitle,
                                sourceURL: url,
                                source: ContentSource.detect(from: url),
                                index: index)
        }

        // HTML before plain text: a provider advertising both is web content,
        // and plain text would strip the structure we can still preserve.
        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
           let html = await loadHTML(provider: provider) {
            let baseURL = await loadURL(provider: provider)
            return IncomingItem(kind: .html(html, baseURL: baseURL),
                                title: itemTitle,
                                sourceURL: baseURL,
                                source: .website,
                                index: index)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.utf8PlainText.identifier) {
            if let text = await loadText(provider: provider) {
                return IncomingItem(kind: .text(text),
                                    title: itemTitle,
                                    source: .textEditor,
                                    index: index)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),
           let text = await loadRTF(provider: provider) {
            return IncomingItem(kind: .text(text),
                                title: itemTitle,
                                source: .textEditor,
                                index: index)
        }

        // Safari's webpage activation sometimes delivers a property list
        // instead of a plain URL item (keys like "_webURL").
        if let url = await loadWebPagePropertyList(provider: provider), isHTTPURL(url) {
            return IncomingItem(kind: .url(url),
                                title: itemTitle,
                                sourceURL: url,
                                source: ContentSource.detect(from: url),
                                index: index)
        }

        // Last chance for hosts like X that expose only opaque/text-ish
        // payloads — resolve whatever URL or prose is actually in there.
        if let recovered = await recoverFromOpaquePayload(provider: provider,
                                                          itemTitle: itemTitle,
                                                          index: index) {
            return recovered
        }

        return nil
    }

    /// Second-chance lane for hosts like X that advertise only opaque or
    /// text-ish representations. Runs after every typed lane failed; any
    /// resolvable http(s) URL is treated as real web content, with leftover
    /// prose retained as the item's attached-text fallback.
    private func recoverFromOpaquePayload(provider: NSItemProvider,
                                          itemTitle: String?,
                                          index: Int) async -> IncomingItem? {
        let registered = provider.registeredTypeIdentifiers

        // 1) Any identifier whose raw bytes decode to something containing
        //    an http(s) URL — covers UTF-8 data under odd type identifiers.
        for identifier in registered where !InputClassification.isUnsupported(identifier) {
            guard let any = try? await provider.loadItem(forTypeIdentifier: identifier, options: nil),
                  let text = Self.stringPayload(from: any),
                  let link = URLPayloadNormalizer.firstURL(in: text) else { continue }
            let url = URLPayloadNormalizer.canonical(link.url)
            let leftover = String(text[link.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            return IncomingItem(kind: .url(url),
                                title: itemTitle,
                                sourceURL: url,
                                source: ContentSource.detect(from: url),
                                index: index,
                                attachedText: leftover.isEmpty ? nil : leftover)
        }

        // 2) Plain text without its own typed lane (some hosts register only
        //    public.data). Text WITH a URL becomes web content; pure prose
        //    still converts as text instead of being dropped.
        if let text = await loadTextFromAnyRepresentation(provider: provider) {
            if let link = URLPayloadNormalizer.firstURL(in: text) {
                let url = URLPayloadNormalizer.canonical(link.url)
                let leftover = String(text[link.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return IncomingItem(kind: .url(url),
                                    title: itemTitle,
                                    sourceURL: url,
                                    source: ContentSource.detect(from: url),
                                    index: index,
                                    attachedText: leftover.isEmpty ? nil : leftover)
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return IncomingItem(kind: .text(text),
                                    title: itemTitle,
                                    source: .textEditor,
                                    index: index)
            }
        }
        return nil
    }

    /// Coerces a loaded representation into a string: String/NSString,
    /// attributed strings, UTF-8 (and common legacy encodings) data.
    static func stringPayload(from any: Any) -> String? {
        if let string = any as? String { return string }
        if let nsString = any as? NSString { return nsString as String }
        if let attributed = any as? NSAttributedString { return attributed.string }
        if let url = any as? URL { return url.absoluteString }
        if let nsURL = any as? NSURL { return nsURL.absoluteString }
        if let data = any as? Data {
            for encoding in [String.Encoding.utf8,
                             .isoLatin1,
                             .windowsCP1252,
                             .macOSRoman] {
                if let string = String(data: data, encoding: encoding), !string.isEmpty {
                    return string
                }
            }
        }
        if let number = any as? NSNumber { return number.stringValue }
        return nil
    }

    /// Loads plain text from any registered textual/data representation.
    private func loadTextFromAnyRepresentation(provider: NSItemProvider) async -> String? {
        var candidates = provider.registeredTypeIdentifiers.filter { identifier in
            identifier == UTType.plainText.identifier
                || identifier == UTType.utf8PlainText.identifier
                || identifier == UTType.text.identifier
                || identifier == UTType.data.identifier
                || identifier == "public.data"
        }
        if candidates.isEmpty {
            candidates = provider.registeredTypeIdentifiers.filter { !InputClassification.isUnsupported($0) }
        }
        for identifier in candidates {
            guard let any = try? await provider.loadItem(forTypeIdentifier: identifier, options: nil),
                  let text = Self.stringPayload(from: any) else { continue }
            if !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Loaders

    private func loadFileURL(provider: NSItemProvider,
                             itemTitle: String?,
                             index: Int,
                             store: TempFileStore) async -> IncomingItem? {
        guard let staged = await stageFileRepresentation(provider, UTType.fileURL.identifier, store) else {
            return nil
        }
        return makeItem(forStagedFile: staged, provider: provider, itemTitle: itemTitle, index: index)
    }

    private func loadAsFile(provider: NSItemProvider,
                            type: UTType,
                            itemTitle: String?,
                            index: Int,
                            store: TempFileStore) async -> IncomingItem? {
        guard let staged = await stageFileRepresentation(provider, type.identifier, store) else {
            return nil
        }
        return makeItem(forStagedFile: staged, provider: provider, itemTitle: itemTitle, index: index)
    }

    private func loadImage(provider: NSItemProvider,
                           itemTitle: String?,
                           index: Int,
                           store: TempFileStore) async -> IncomingItem? {
        // Prefer a real file — HEIC/PNG/JPEG stay encoded on disk. The copy
        // happens inside the provider callback, where the URL is valid.
        if let staged = await stageFileRepresentation(provider, UTType.image.identifier, store) {
            return IncomingItem(kind: .image(staged),
                                title: itemTitle,
                                source: .photos,
                                index: index)
        }
        // Some apps only hand over decoded data — re-encode on disk so we
        // still never hold a decoded bitmap.
        if let any = try? await provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) {
            if let data = any as? Data, let staged = try? store.stage(data: data, fileExtension: "img") {
                return IncomingItem(kind: .image(staged),
                                    title: itemTitle,
                                    source: .photos,
                                    index: index)
            }
        }
        return nil
    }

    private func makeItem(forStagedFile staged: URL,
                          provider: NSItemProvider,
                          itemTitle: String?,
                          index: Int) -> IncomingItem? {
        let fileClass = InputClassification.classify(fileURL: staged)
        switch fileClass {
        case .pdf:
            return IncomingItem(kind: .pdf(staged),
                                title: itemTitle,
                                originalFilename: staged.lastPathComponent,
                                source: .files,
                                index: index)
        case .image:
            return IncomingItem(kind: .image(staged),
                                title: itemTitle,
                                originalFilename: staged.lastPathComponent,
                                source: .photos,
                                index: index)
        case .other:
            return IncomingItem(kind: .file(staged),
                                title: itemTitle,
                                originalFilename: staged.lastPathComponent,
                                source: .files,
                                index: index)
        }
    }

    /// Loads a file representation and copies it into the staging area.
    /// The copy runs inside the provider callback — the delivered URL is
    /// only valid there.
    private func stageFileRepresentation(_ provider: NSItemProvider,
                                         _ typeIdentifier: String,
                                         _ store: TempFileStore) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: try? store.stage(url))
            }
        }
    }

    private func loadURL(provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) else { return nil }
        guard let any = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) else {
            return nil
        }
        return Self.url(fromItem: any)
    }
    /// Safari's webpage activation can deliver a property-list item carrying
    /// the page address under keys like "_webURL" instead of a URL item.
    private func loadWebPagePropertyList(provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) else { return nil }
        guard let any = try? await provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil),
              let dictionary = Self.dictionary(fromPropertyListItem: any) else {
            return nil
        }
        for key in ["_webURL", "webURL", "URL", "url"] {
            if let value = dictionary[key] as? String,
               let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return url
            }
        }
        return nil
    }

    /// Property-list payloads arrive either pre-deserialized or as raw data.
    private static func dictionary(fromPropertyListItem any: Any) -> NSDictionary? {
        if let dictionary = any as? NSDictionary { return dictionary }
        if let dictionary = any as? [AnyHashable: Any] { return dictionary as NSDictionary }
        if let data = any as? Data,
           let decoded = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = decoded as? NSDictionary {
            return dictionary
        }
        return nil
    }

    /// Accepts every representation apps actually hand over for URLs:
    /// URL/NSURL objects, plain strings, raw data, or a property list.
    private static func url(fromItem any: Any) -> URL? {
        if let url = any as? URL { return url }
        if let nsURL = any as? NSURL { return nsURL as URL }
        if let string = any as? String { return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let nsString = any as? NSString { return URL(string: (nsString as String).trimmingCharacters(in: .whitespacesAndNewlines)) }
        // Raw bytes: hosts deliver either serialized URLs or plain strings.
        if let data = any as? Data,
           let string = String(data: data, encoding: .utf8)?
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !string.isEmpty {
            return URL(string: string)
        }
        if let dictionary = any as? NSDictionary {
            for key in ["_webURL", "webURL", "URL", "url"] {
                if let value = dictionary[key] as? String {
                    return URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
        }
        return nil
    }

    private func loadText(provider: NSItemProvider) async -> String? {
        for identifier in [UTType.plainText.identifier, UTType.utf8PlainText.identifier] {
            guard provider.hasItemConformingToTypeIdentifier(identifier) else { continue }
            if let any = try? await provider.loadItem(forTypeIdentifier: identifier, options: nil) {
                if let string = any as? String, !string.isEmpty { return string }
                if let nsString = any as? NSString, nsString.length > 0 { return nsString as String }
                if let attributed = any as? NSAttributedString, attributed.length > 0 {
                    return attributed.string
                }
                // Some hosts deliver UTF-8 bytes rather than a string object.
                if let data = any as? Data,
                   let string = String(data: data, encoding: .utf8),
                   !string.isEmpty {
                    return string
                }
            }
        }
        return nil
    }

    private func loadHTML(provider: NSItemProvider) async -> String? {
        guard let any = try? await provider.loadItem(forTypeIdentifier: UTType.html.identifier, options: nil) else {
            return nil
        }
        if let string = any as? String { return string }
        if let data = any as? Data { return String(data: data, encoding: .utf8) }
        if let attributed = any as? NSAttributedString { return attributed.string }
        return nil
    }

    private func loadRTF(provider: NSItemProvider) async -> String? {
        guard let any = try? await provider.loadItem(forTypeIdentifier: UTType.rtf.identifier, options: nil) else {
            return nil
        }
        let data: Data?
        if let d = any as? Data { data = d }
        else if let url = any as? URL { data = try? Data(contentsOf: url) }
        else { data = nil }
        guard let data else { return nil }
        guard let attributed = try? NSAttributedString(data: data,
                                                       options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                       documentAttributes: nil) else {
            return nil
        }
        return attributed.string.isEmpty ? nil : attributed.string
    }

    private func isHTTPURL(_ url: URL) -> Bool {
        url.scheme == "http" || url.scheme == "https"
    }
}
