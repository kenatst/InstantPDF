import SwiftUI

/// PDF It's organized product control center. Every preference below is wired
/// to a real behavior; product education and DEBUG tooling stay clearly apart.
@MainActor
struct SettingsView: View {
    @AppStorage(AppSettingsKeys.defaultMode, store: AppConfiguration.sharedDefaults)
    private var defaultMode: ConversionMode = .quick

    @ObservedObject private var entitlements = EntitlementCenter.shared

    @AppStorage(AppSettingsKeys.defaultPaperSize, store: AppConfiguration.sharedDefaults)
    private var defaultPaperSize: PDFPaperSize = .automatic

    @AppStorage(AppSettingsKeys.imageQuality, store: AppConfiguration.sharedDefaults)
    private var imageQuality: ImageQuality = .balanced

    @AppStorage(AppSettingsKeys.includeSourceURL, store: AppConfiguration.sharedDefaults)
    private var includeSourceURL = false

    @AppStorage(AppSettingsKeys.includeCreationDate, store: AppConfiguration.sharedDefaults)
    private var includeCreationDate = false

    @State private var recordCount = 0
    @State private var totalBytes: Int64 = 0
    /// nil = System Default.
    @State private var languageOverride: AppLanguage?

    private let storage = StorageManager.shared
    @Environment(\.dismiss) private var dismissView
    @Environment(\.colorScheme) private var colorScheme
    /// Injected from the app root; selecting a language refreshes all UI live.
    @ObservedObject private var languageSetting: LanguageSetting

    init(languageSetting: LanguageSetting) {
        _languageSetting = ObservedObject(wrappedValue: languageSetting)
    }

    init() {
        _languageSetting = ObservedObject(wrappedValue: LanguageSetting.shared)
    }

    var body: some View {
        Form {
            proSection

            Section {
                NavigationLink {
                    ShareExtensionGuideView()
                } label: {
                    Label("Use PDF It from any app", systemImage: "square.and.arrow.up")
                }
                NavigationLink {
                    ProFeaturesGuideView(activationMode: false)
                } label: {
                    Label("Pro Features Guide", systemImage: "sparkles.rectangle.stack")
                }
                .disabled(!entitlements.isPro)
            } header: {
                SettingsSectionHeader("Using PDF It", symbol: "sparkles.rectangle.stack")
            } footer: {
                Text("How to turn shared content into PDFs from Safari, X, Photos and more.")
            }

            Section {
                Picker("Language", selection: languageBinding) {
                    Text("System Default").tag(AppLanguage?.none)
                    Divider()
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(AppLanguage?.some(language))
                    }
                }
            } header: {
                SettingsSectionHeader("Language", symbol: "globe")
            } footer: {
                Text("Applies to the app and the Share Extension. The system language is used until you pick one here.")
            }

            Section {
                Picker("Default Mode", selection: $defaultMode) {
                    ForEach(ConversionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Default Page Size", selection: $defaultPaperSize) {
                    ForEach(PDFPaperSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                Picker("Image Quality", selection: $imageQuality) {
                    ForEach(ImageQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
                Toggle("Include Source Link", isOn: $includeSourceURL)
                    .tint(Theme.Colors.orangePrimary)
                Toggle("Include Creation Date", isOn: $includeCreationDate)
                    .tint(Theme.Colors.orangePrimary)
            } header: {
                SettingsSectionHeader("Defaults", symbol: "slider.horizontal.3")
            } footer: {
                Text("Adds a subtle footer to generated text and article PDFs. Existing PDFs are never modified.")
            }

            Section {
                LabeledContent("Saved PDFs", value: "\(recordCount)")
                LabeledContent("Total Size",
                               value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            } header: {
                SettingsSectionHeader("Storage", symbol: "internaldrive")
            } footer: {
                Text("Your PDFs stay securely on this device until you delete them.")
            }

            Section {
                HStack {
                    Label("Local Processing Only", systemImage: "lock.shield.fill")
                        .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
                HStack {
                    Label("No Accounts or Tracking", systemImage: "person.crop.circle.badge.xmark")
                        .foregroundStyle(colorScheme == .dark ? .white : Color(hex: "111215"))
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Colors.orangePrimary)
                }
                Link("Privacy Policy", destination: ExternalLinks.privacyPolicy)
                Link("Terms of Use", destination: ExternalLinks.termsOfUse)
                Link("Support & Feedback", destination: ExternalLinks.support)
            } header: {
                SettingsSectionHeader("Privacy & Support", symbol: "lock.shield")
            } footer: {
                Text("PDF It processes and stores documents locally. Your documents are not uploaded to PDF It. When you convert a webpage, PDF It loads the page directly from its source website.")
            }

            Section {
                LabeledContent("Version", value: shortVersion)
                LabeledContent("Build", value: buildVersion)
                LabeledContent("Creator Tag", value: String(localized: "PDFs are tagged “PDF It” in their metadata", bundle: LanguageManager.bundle))
            } header: {
                SettingsSectionHeader("About", symbol: "info.circle")
            }

#if DEBUG
            developerSection
            developerActionsSection
#endif
        }
        .scrollContentBackground(.hidden)
        .background((colorScheme == .dark ? Theme.Colors.darkBackground : Theme.Colors.warmBackground).ignoresSafeArea())
        .tint(Theme.Colors.orangePrimary)
        .environment(\.locale, settingsLocale)
        // Refresh only this surface when its explicit bundle changes. Keeping
        // MainTabView's identity stable means the Settings sheet stays open.
        .id(languageSetting.refreshToken)
        .navigationTitle(String(localized: "Settings", bundle: LanguageManager.bundle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismissView() }
                    .foregroundStyle(Theme.Colors.orangePrimary)
            }
        }
        .onAppear {
            languageOverride = LanguageManager.current
            reloadStorage()
        }
    }

    private var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var buildVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    private var languageBinding: Binding<AppLanguage?> {
        Binding(get: { languageOverride },
                set: { newValue in
                    languageOverride = newValue
                    languageSetting.select(newValue)
                })
    }

    private var settingsLocale: Locale {
        guard let language = languageSetting.language else { return .autoupdatingCurrent }
        return Locale(identifier: language.rawValue)
    }

    private func reloadStorage() {
        let records = storage.fetchRecords()
        recordCount = records.count
        totalBytes = records.reduce(0) { $0 + $1.fileSize }
    }

    // MARK: - PDF It Pro section (the user's control center entry)

    @State private var showingProPaywall = false
    @State private var showingActivationPreview = false
    @State private var showStoreKitUnavailableNote = false

    @ViewBuilder
    private var proSection: some View {
        Section {
            if entitlements.isPro {
                HStack(spacing: Theme.Spacing.sm) {
                    proIcon
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PDF It Pro")
                            .font(.headline.weight(.bold))
                        Text("Active")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                }
#if !APP_STORE
                Button {
                    if let url = URL(string: "itms-apps://apps.apple.com/account/subscriptions") {
                        openURL(url)
                    } else {
                        showStoreKitUnavailableNote = true
                    }
                } label: {
                    Label("Manage Subscription", systemImage: "arrow.triangle.2.circlepath")
                }
#endif
            } else {
                Button {
                    showingProPaywall = true
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        proIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text("PDF It Pro")
                                .font(.headline.weight(.bold))
                                .foregroundStyle(.primary)
                            Text("Unlock Pro")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.Colors.orangePrimary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.bold))
                            .foregroundStyle(Theme.Colors.orangePrimary)
                    }
                }
            }

            Button {
                Task {
                    await entitlements.restore()
                    showStoreKitUnavailableNote = !entitlements.isPro && entitlements.status.isUnavailable
                }
            } label: {
                Text("Restore Purchases")
            }
        } header: {
            SettingsSectionHeader("PDF IT PRO", symbol: "crown")
                .accessibilityIdentifier("pdf_settings_pro_header")
        } footer: {
            if showStoreKitUnavailableNote {
                Text("Purchases are temporarily unavailable.")
            }
        }
        .sheet(isPresented: $showingProPaywall) {
            // Settings-initiated purchase: celebrate on verified success,
            // then simply land back (no pending intent to resume).
            PaywallView(feature: .webConversion, onVerifiedPurchase: { _ in
                showingActivationPreview = true
            })
        }
        .sheet(isPresented: $showingActivationPreview) {
            ProActivationFlow { _ in } // no intent side effects
        }
    }

    private var proIcon: some View {
        Image(systemName: "crown.fill")
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(Theme.Colors.orangePrimary)
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.Colors.orangePrimary.opacity(0.13))
            )
    }

    @Environment(\.openURL) private var openURL

#if DEBUG
    /// DEBUG-ONLY developer surface. Lets the tester run the whole app —
    /// including the Share Extension via the App Group flag — as Pro before
    /// App Store Connect products exist. Compiled out of Release entirely.
    @State private var forcePro = EntitlementCenter.debugForceProEnabled

    @ViewBuilder
    private var developerSection: some View {
        Section {
            Toggle("Force PDF It Pro", isOn: $forcePro)
                .tint(Theme.Colors.orangePrimary)
                .onChange(of: forcePro) { _, enabled in
                    EntitlementCenter.shared.setDebugProOverride(enabled)
                }
        } header: {
            SettingsSectionHeader("Developer", symbol: "hammer")
        } footer: {
            Text("DEBUG builds only. Forces every Pro feature, in the app and the Share Extension. Not present in release.")
        }
    }

    /// DEBUG-only visual QA entries. Never compiled into Release.
    @ViewBuilder
    private var developerActionsSection: some View {
        Section {
            Button("Preview Pro Activation") { showingActivationPreview = true }
            Button("Reset Pro Welcome State") {
                ProActivationState.resetWelcomeState()
            }
        } header: {
            SettingsSectionHeader("Pro Flow QA", symbol: "checklist")
        } footer: {
            Text("Preview replays celebration, Share tutorial and feature guide without a purchase. Reset lets the activation flow run again after a real purchase.")
        }
    }
#endif
}

private struct SettingsSectionHeader: View {
    let title: LocalizedStringKey
    let symbol: String

    init(_ title: LocalizedStringKey, symbol: String) {
        self.title = title
        self.symbol = symbol
    }

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }
}
