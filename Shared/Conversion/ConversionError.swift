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
        case .noUsableContent: return "Nothing to convert"
        case .someContentSkipped: return "Some items were skipped"
        case .fileTooLarge: return "This file is too large"
        case .unreadableFile: return "This file couldn't be read"
        case .invalidURL: return "This link isn't valid"
        case .pageUnreachable: return "We couldn't load this page"
        case .pageTooSlow: return "This page took too long to load"
        case .webProcessTerminated: return "The page couldn't be rendered"
        case .generationFailed: return "We couldn't create the PDF"
        case .cancelled: return "Cancelled"
        }
    }

    /// One-line explanation shown under the headline.
    var message: String {
        switch self {
        case .noUsableContent:
            return "The app didn't share content PDF It can work with."
        case .someContentSkipped:
            return "Videos and audio aren't supported — everything else was converted."
        case .fileTooLarge(let name):
            return name.map { "\($0) is over the 100 MB limit." } ?? "Files over 100 MB can't be converted safely."
        case .unreadableFile(let name):
            return name.map { "We couldn't read \($0)." } ?? "The file couldn't be read."
        case .invalidURL:
            return "Check the link and try again."
        case .pageUnreachable:
            return "Check your connection, then retry."
        case .pageTooSlow:
            return "The site never finished loading. Retry, or save the link as text."
        case .webProcessTerminated:
            return "The site used too much memory to render. Try again, or save the link as text."
        case .generationFailed:
            return "Something went wrong while creating the PDF. Please try again."
        case .cancelled:
            return "The conversion was cancelled."
        }
    }

    /// Recovery options worth offering in the UI, in display order.
    var recoveryActions: [RecoveryAction] {
        switch self {
        case .pageUnreachable, .pageTooSlow, .webProcessTerminated:
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
            case .retry: return "Retry"
            case .saveLinkAsText: return "Save Link as PDF"
            case .cancel: return "Cancel"
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
