import Foundation

/// Every failure the conversion pipeline can surface, already translated
/// into language a human can act on. Engineering details stay in logs.
enum ConversionError: Error, Equatable {
    /// The share sheet did not expose anything we can process.
    case noUsableContent
    /// One or more attachments were skipped (e.g. videos), others may still convert.
    case someContentSkipped
    /// A single attachment exceeded the size limit.
    case fileTooLarge(name: String?)
    /// The file could not be read or decoded.
    case unreadableFile(name: String?)
    /// The URL is not something we can load (bad scheme, malformed…).
    case invalidURL
    /// The page failed to load (network, SSL, unreachable, 404…).
    case pageUnreachable(reason: String?)
    /// The page loaded but took too long to become stable.
    case pageTooSlow
    /// The site served a wall/challenge instead of real content (login gate,
    /// CAPTCHA, bot check, blurred paywall preview). Honest, actionable.
    case siteBlocked
    /// The web view crashed while rendering.
    case webProcessTerminated
    /// PDF generation produced nothing usable.
    case generationFailed
    /// The user cancelled.
    case cancelled
}

extension ConversionError {
    /// Short, human sentence for titles.
    var headline: String {
        switch self {
        case .noUsableContent: return String(localized: "Nothing to convert", bundle: LanguageManager.bundle)
        case .someContentSkipped: return String(localized: "Some items were skipped", bundle: LanguageManager.bundle)
        case .fileTooLarge: return String(localized: "This file is too large", bundle: LanguageManager.bundle)
        case .unreadableFile: return String(localized: "This file couldn't be read", bundle: LanguageManager.bundle)
        case .invalidURL: return String(localized: "This link isn't valid", bundle: LanguageManager.bundle)
        case .pageUnreachable: return String(localized: "We couldn't load this page", bundle: LanguageManager.bundle)
        case .pageTooSlow: return String(localized: "This page took too long to load", bundle: LanguageManager.bundle)
        case .siteBlocked: return String(localized: "This site blocked the conversion", bundle: LanguageManager.bundle)
        case .webProcessTerminated: return String(localized: "The page couldn't be rendered", bundle: LanguageManager.bundle)
        case .generationFailed: return String(localized: "We couldn't create the PDF", bundle: LanguageManager.bundle)
        case .cancelled: return String(localized: "Cancelled", bundle: LanguageManager.bundle)
        }
    }

    /// One-line explanation shown under the headline.
    var message: String {
        switch self {
        case .noUsableContent:
            return String(localized: "The app didn't share content PDF It can work with.", bundle: LanguageManager.bundle)
        case .someContentSkipped:
            return String(localized: "Videos and audio aren't supported — everything else was converted.", bundle: LanguageManager.bundle)
        case .fileTooLarge(let name):
            if let name {
                return String(localized: "error.file_too_large.named \(name)", bundle: LanguageManager.bundle)
            } else {
                return String(localized: "Files over 100 MB can't be converted safely.", bundle: LanguageManager.bundle)
            }
        case .unreadableFile(let name):
            if let name {
                return String(localized: "error.unreadable_file.named \(name)", bundle: LanguageManager.bundle)
            } else {
                return String(localized: "The file couldn't be read.", bundle: LanguageManager.bundle)
            }
        case .invalidURL:
            return String(localized: "Check the link and try again.", bundle: LanguageManager.bundle)
        case .pageUnreachable:
            return String(localized: "Check your connection, then retry.", bundle: LanguageManager.bundle)
        case .pageTooSlow:
            return String(localized: "The site never finished loading. Retry, or save the link as text.", bundle: LanguageManager.bundle)
        case .siteBlocked:
            return String(localized: "Some sites (login walls, CAPTCHAs, blurred previews) don't allow clean captures. Try Reader mode, or convert the page from your browser instead.", bundle: LanguageManager.bundle)
        case .webProcessTerminated:
            return String(localized: "The site used too much memory to render. Try again, or save the link as text.", bundle: LanguageManager.bundle)
        case .generationFailed:
            return String(localized: "Something went wrong while creating the PDF. Please try again.", bundle: LanguageManager.bundle)
        case .cancelled:
            return String(localized: "The conversion was cancelled.", bundle: LanguageManager.bundle)
        }
    }

    /// Recovery options worth offering in the UI, in display order.
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .pageUnreachable, .pageTooSlow, .webProcessTerminated, .siteBlocked:
            return [.retry, .saveLinkAsText, .cancel]
        case .fileTooLarge, .unreadableFile, .invalidURL, .generationFailed,
             .noUsableContent, .someContentSkipped:
            return [.cancel]
        case .cancelled:
            return [.cancel]
        }
    }

    enum RecoveryAction: String {
        case retry
        case saveLinkAsText
        case cancel

        var title: String {
            switch self {
            case .retry: return String(localized: "Retry", bundle: LanguageManager.bundle)
            case .saveLinkAsText: return String(localized: "Save Link as PDF", bundle: LanguageManager.bundle)
            case .cancel: return String(localized: "Cancel", bundle: LanguageManager.bundle)
            }
        }
    }
}

extension ConversionError {
    /// Maps Foundation/WebKit networking errors onto user-facing cases.
    static func from(networkError error: Error) -> ConversionError {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorTimedOut:
                return .pageTooSlow
            case NSURLErrorNotConnectedToInternet,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed:
                return .pageUnreachable(reason: "offline")
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot:
                return .pageUnreachable(reason: "ssl")
            case NSURLErrorCancelled:
                return .cancelled
            default:
                return .pageUnreachable(reason: nil)
            }
        }
        return .pageUnreachable(reason: nil)
    }
}
