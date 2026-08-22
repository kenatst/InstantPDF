import Foundation
import UniformTypeIdentifiers

/// The normalized representation of one piece of incoming shared content.
/// Heavy payloads (images, PDFs, files) are always referenced by a staged
/// file URL so nothing large is eagerly decoded into memory.
struct IncomingItem {
    let id: UUID
    let kind: IncomingKind
    let title: String?
    let originalFilename: String?
    let sourceURL: URL?
    let source: ContentSource
    let index: Int

    init(kind: IncomingKind,
         title: String? = nil,
         originalFilename: String? = nil,
         sourceURL: URL? = nil,
         source: ContentSource = .unknown,
         index: Int = 0) {
        self.id = UUID()
        self.kind = kind
        self.title = title
        self.originalFilename = originalFilename
        self.sourceURL = sourceURL
        self.source = source
        self.index = index
    }
}

enum IncomingKind {
    /// Plain or attributed text, already extracted as a raw string.
    case text(String)
    /// A remote http(s) URL to load and convert.
    case url(URL)
    /// An HTML document handed over by the source app, with an optional base URL.
    case html(String, baseURL: URL?)
    /// A staged image file (JPEG/PNG/HEIC/…). Never decoded before conversion.
    case image(URL)
    /// A staged PDF file, preserved as-is in Quick mode.
    case pdf(URL)
    /// Any other file the user shared.
    case file(URL)
}

extension IncomingItem {
    /// A short human name for the kind, used in summaries and filenames.
    var kindName: String {
        switch kind {
        case .text: return "Text"
        case .url, .html: return "Webpage"
        case .image: return "Image"
        case .pdf: return "PDF"
        case .file: return "File"
        }
    }

    var isImage: Bool {
        if case .image = kind { return true }
        return false
    }
}

/// Lightweight detection of the service a URL points at. Hostname-based only —
/// no scraping, no private APIs. Used for filenames, icons and future parsers.
enum ContentSource: String, Codable, CaseIterable {
    case x
    case reddit
    case wikipedia
    case medium
    case substack
    case github
    case website
    case photos
    case files
    case textEditor
    case unknown

    var displayName: String {
        switch self {
        case .x: return "X"
        case .reddit: return "Reddit"
        case .wikipedia: return "Wikipedia"
        case .medium: return "Medium"
        case .substack: return "Substack"
        case .github: return "GitHub"
        case .website: return "Website"
        case .photos: return "Photos"
        case .files: return "Files"
        case .textEditor: return "Notes"
        case .unknown: return "Document"
        }
    }

    var symbolName: String {
        switch self {
        case .x: return "bubble.left.and.bubble.right"
        case .reddit, .medium, .substack: return "text.bubble"
        case .wikipedia: return "book"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .website: return "safari"
        case .photos: return "photo.on.rectangle"
        case .files: return "folder"
        case .textEditor: return "note.text"
        case .unknown: return "doc"
        }
    }

    static func detect(from url: URL?) -> ContentSource {
        guard let rawHost = url?.host?.lowercased() else { return .website }
        let host = rawHost.hasPrefix("www.") ? String(rawHost.dropFirst(4)) : rawHost
        func matches(_ base: String) -> Bool { host == base || host.hasSuffix("." + base) }

        if matches("x.com") || matches("twitter.com") { return .x }
        if matches("reddit.com") { return .reddit }
        if matches("wikipedia.org") { return .wikipedia }
        if matches("medium.com") { return .medium }
        if matches("substack.com") { return .substack }
        if matches("github.com") { return .github }
        return .website
    }

    /// True when the URL looks like a single X/Twitter post.
    /// Used only to build better filenames — no special scraping is attempted.
    static func isXStatusURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "x.com" || host == "twitter.com" || host.hasSuffix(".x.com") else { return false }
        let path = url.path
        return path.components(separatedBy: "/").filter { !$0.isEmpty }.count >= 3
    }
}
