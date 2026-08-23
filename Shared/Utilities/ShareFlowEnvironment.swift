import Foundation

/// Compile-time environment flag: true inside the Share Extension target
/// (which sets the EXTENSION compilation condition), false in the app.
enum ShareFlowEnvironment {
    static let isExtension: Bool = {
        #if EXTENSION
        return true
        #else
        return false
        #endif
    }()
}
