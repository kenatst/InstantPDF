import SwiftUI

/// Refined dark-card Settings view matching PDF It's premium identity.
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
    var languageSetting: LanguageSetting?

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
                Text("Using PDF It")
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
            } footer: {
                Text("Applies to the app and the Share Extension. The system language is used until you pick one here.")
            }

            Section("Conversion") {
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
            }

            Section {
                Toggle("Include Source Link", isOn: $includeSourceURL)
                    .tint(Theme.Colors.orangePrimary)
                Toggle("Include Creation Date", isOn: $includeCreationDate)
                    .tint(Theme.Colors.orangePrimary)
            } header: {
                Text("PDF Options")
            } footer: {
                Text("Adds a subtle footer to generated text and article PDFs. Existing PDFs are never modified.")
            }

            Section {
                LabeledContent("Saved PDFs", value: "\(recordCount)")
                LabeledContent("Total Size",
                               value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            } header: {
                Text("Storage")
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
                Text("Privacy & Security")
            } footer: {
                Text("PDF It processes and stores documents locally. Your documents are not uploaded to PDF It. When you convert a webpage, PDF It loads the page directly from its source website.")
            }

            Section("About") {
                LabeledContent("App Name", value: "PDF It")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Creator Tag", value: String(localized: "PDFs are tagged “PDF It” in their metadata"))
            }

#if DEBUG
            developerSection
            developerActionsSection
#endif
        }
        .scrollContentBackground(colorScheme == .dark ? .hidden : .visible)
        .background(colorScheme == .dark ? Theme.Colors.darkBackground.ignoresSafeArea() : Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
        .tint(Theme.Colors.orangePrimary)
        .navigationTitle("Settings")
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

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    private var languageBinding: Binding<AppLanguage?> {
        Binding(get: { languageOverride },
                set: { newValue in
                    languageOverride = newValue
                    languageSetting?.select(newValue)
                })
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
                LabeledContent {
                    Label("Active", systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.green)
                } label: {
                    Label("PDF It Pro", systemImage: "crown.fill")
                        .foregroundStyle(Theme.Colors.orangePrimary)
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
                    Label("PDF It Pro", systemImage: "crown.fill")
                        .foregroundStyle(Theme.Colors.orangePrimary)
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
            Text("PDF IT PRO")
                .accessibilityIdentifier("pdf_settings_pro_header")
        } footer: {
            if showStoreKitUnavailableNote {
                Text("Purchases are temporarily unavailable.")
            }
        }
        .sheet(isPresented: $showingProPaywall) {
            // Settings-initiated purchase: celebrate on verified success,
            // then simply land back (no pending intent to resume).
            PaywallView(feature: .webConversion) { _ in
                showingActivationPreview = true
            }
        }
        .sheet(isPresented: $showingActivationPreview) {
            ProActivationFlow { _ in } // no intent side effects
        }
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
                    UserDefaults(suiteName: AppConfiguration.appGroupIdentifier)?
                        .set(enabled, forKey: EntitlementCenter.debugForceProKey)
                    // Refresh gating everywhere + republish extension-visible state.
                    Task {
                        await EntitlementCenter.shared.recompute()
                        // isPro may not change (force-Pro is a read-time OR);
                        // nudge observers so gates re-evaluate immediately.
                        EntitlementCenter.shared.objectWillChange.send()
                    }
                }
        } header: {
            Text("Developer")
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
            Text("Pro Flow QA")
        } footer: {
            Text("Preview replays celebration, Share tutorial and feature guide without a purchase. Reset lets the activation flow run again after a real purchase.")
        }
    }
#endif
}
