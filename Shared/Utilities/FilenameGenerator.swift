import Foundation

/// Human-friendly PDF filenames. Timestamps never appear in the visible
/// name; collisions are resolved with a numeric suffix instead.
///
///   Paris Trip Photos.pdf
///   Thread — username.pdf
///   5 Photos — 22 Aug 2026.pdf
///   Notes — 22 Aug 2026.pdf
enum FilenameGenerator {

    /// Full filename (with extension) for a converted document.
    static func fileName(for document: ConvertedDocument, date: Date = Date()) -> String {
        let base = baseName(for: document, date: date)
        return base + ".pdf"
    }

    /// The basename without extension, dated where it helps.
    static func baseName(for document: ConvertedDocument, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        let dateSuffix = formatter.string(from: date)

        let title = sanitize(document.suggestedTitle)

        switch document.source {
        case .x:
            return title.isEmpty ? "Thread — \(dateSuffix)" : title
        case .photos:
            return title.isEmpty ? "Photos — \(dateSuffix)" : "\(title) — \(dateSuffix)"
        case .textEditor:
            return title.isEmpty ? "Notes — \(dateSuffix)" : title
        default:
            return title.isEmpty ? "PDF — \(dateSuffix)" : title
        }
    }

    /// Makes a string safe as a file basename: removes path separators and
    /// control characters, collapses whitespace, caps length. Never empty —
    /// falls back to "PDF".
    static func sanitize(_ raw: String) -> String {
        var cleaned = raw
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")

        cleaned = cleaned.components(separatedBy: CharacterSet.controlCharacters).joined(separator: "")

        // Collapse runs of whitespace into single spaces.
        let components = cleaned.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        cleaned = components.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // Trim leading dots so nothing hidden-looking is produced.
        while cleaned.hasPrefix(".") { cleaned = String(cleaned.dropFirst()) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)

        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        // A name with no letters or digits ("---") is useless — fall back.
        if cleaned.rangeOfCharacter(from: CharacterSet.alphanumerics) == nil {
            return "PDF"
        }
        return cleaned
    }

    /// Resolves collisions with a human " 2", " 3"… suffix — never overwrites.
    static func uniqueFileName(_ desired: String, existingNames: Set<String>) -> String {
        guard !desired.isEmpty else { return uniqueFileName("PDF.pdf", existingNames: existingNames) }
        guard existingNames.contains(desired) else { return desired }

        let ext = (desired as NSString).pathExtension
        let base = (desired as NSString).deletingPathExtension

        var counter = 2
        var candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        while existingNames.contains(candidate) {
            counter += 1
            candidate = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
        }
        return candidate
    }

    /// "Thread — username" for X status URLs, nil for everything else.
    static func threadTitle(for url: URL) -> String? {
        guard ContentSource.isXStatusURL(url) else { return nil }
        let parts = url.path.components(separatedBy: "/").filter { !$0.isEmpty }
        guard parts.count >= 1 else { return nil }
        return "Thread — \(parts[0])"
    }
}
