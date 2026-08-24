import SwiftUI
import Combine

/// Observable language state for SwiftUI: views read the published language
/// and the app root updates its locale environment on change.
/// This is how switching Français → English updates the UI immediately,
/// without relaunch and without Bundle swizzling.
@MainActor
final class LanguageSetting: ObservableObject {
    static let shared = LanguageSetting()

    @Published private(set) var language: AppLanguage?

    /// Bumped on every change; used as an identity token at the app root.
    @Published private(set) var refreshToken: UUID = UUID()

    private var cancellable: AnyCancellable?

    init() {
        language = LanguageManager.current
        // The Share Extension may change the stored value while we run.
        cancellable = NotificationCenter.default
            .publisher(for: .pdfItLanguageChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let current = LanguageManager.current
                if current != self.language {
                    self.language = current
                    self.refreshToken = UUID()
                }
            }
    }

    func select(_ language: AppLanguage?) {
        LanguageManager.current = language
        self.language = language
        refreshToken = UUID()
    }
}

private struct LanguageSettingKey: EnvironmentKey {
    static let defaultValue: AppLanguage? = nil
}

extension EnvironmentValues {
    /// The active in-app language override (nil = system default).
    var pdfItLanguage: AppLanguage? {
        get { self[LanguageSettingKey.self] }
        set { self[LanguageSettingKey.self] = newValue }
    }
}
