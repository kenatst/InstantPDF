import Foundation
import UniformTypeIdentifiers

/// What the Share Extension handed us, in their original order.
struct ExtractedInput {
    var items: [IncomingItem] = []
    /// Attachments we refused (video/audio) — surfaced as a gentle notice.
    var skippedCount: Int = 0

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
        guard let extensionItems = context.inputItems as? [NSExtensionItem] else {
            return ExtractedInput()
        }

        let store = TempFileStore()
        defer { store.cleanUp() }

        var result = ExtractedInput()
        var index = 0

        for item in extensionItems {
            let itemTitle = item.attributedTitle?.string ?? item.attributedContentText?.string
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
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

        // A file URL wins: it keeps big payloads out of RAM entirely.
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return await loadFileURL(provider: provider, itemTitle: itemTitle, index: index, store: store)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
            return await loadAsFile(provider: provider,
                                    type: .pdf,
                                    itemTitle: itemTitle,
                                    index: index,
                                    store: store)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider: provider), isHTTPURL(url) {
            return IncomingItem(kind: .url(url),
                                title: itemTitle,
                                sourceURL: url,
                                source: ContentSource.detect(from: url),
                                index: index)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            return await loadImage(provider: provider, itemTitle: itemTitle, index: index, store: store)
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

        if provider.hasItemConformingToTypeIdentifier(UTType.html.identifier),
           let html = await loadHTML(provider: provider) {
            let baseURL = await loadURL(provider: provider)
            return IncomingItem(kind: .html(html, baseURL: baseURL),
                                title: itemTitle,
                                sourceURL: baseURL,
                                source: .website,
                                index: index)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.rtf.identifier),
           let text = await loadRTF(provider: provider) {
            return IncomingItem(kind: .text(text),
                                title: itemTitle,
                                source: .textEditor,
                                index: index)
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
        if let url = any as? URL { return url }
        if let string = any as? String { return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let nsURL = any as? NSURL { return nsURL as URL }
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
