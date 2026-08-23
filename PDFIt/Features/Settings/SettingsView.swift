import SwiftUI

/// Minimal settings, stored in the shared defaults suite so the Share
/// Extension starts from the same preferences.
struct SettingsView: View {
    @AppStorage(AppSettingsKeys.defaultMode, store: AppConfiguration.sharedDefaults)
    private var defaultMode: ConversionMode = .quick

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

    private let storage = StorageManager.shared

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Mode", selection: $defaultMode) {
                    ForEach(ConversionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Picker("Paper size", selection: $defaultPaperSize) {
                    ForEach(PDFPaperSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                Picker("Image quality", selection: $imageQuality) {
                    ForEach(ImageQuality.allCases) { quality in
                        Text(quality.displayName).tag(quality)
                    }
                }
            }

            Section {
                Toggle("Include source link", isOn: $includeSourceURL)
                Toggle("Include creation date", isOn: $includeCreationDate)
            } header: {
                Text("Documents")
            } footer: {
                Text("Adds a small footer to generated text and article PDFs. Existing PDFs are never modified.")
            }

            Section {
                LabeledContent("Saved PDFs", value: "\(recordCount)")
                LabeledContent("Total size",
                               value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            } header: {
                Text("Storage")
            } footer: {
                Text("Your PDFs stay on this device until you delete them.")
            }

            Section {
                LabeledContent("Local processing", value: String(localized: "On device"))
                LabeledContent("No accounts or tracking", value: String(localized: "Yes"))
                Link("Privacy Policy", destination: ExternalLinks.privacyPolicy)
                Link("Terms of Use", destination: ExternalLinks.termsOfUse)
                Link("Support & Feedback", destination: ExternalLinks.support)
            } header: {
                Text("Privacy & Support")
            } footer: {
                Text("Your documents aren't uploaded to PDF It. Conversions run on your device. When you convert a webpage, PDF It loads the page directly from its website.")
            }

            Section("About") {
                LabeledContent("App Name", value: "PDF It")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Creator tag", value: String(localized: "PDFs are tagged “PDF It” in their metadata"))
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismissView() }
            }
        }
        .onAppear(perform: reloadStorage)
    }

    private var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    @Environment(\.dismiss) private var dismissView

    private func reloadStorage() {
        let records = storage.fetchRecords()
        recordCount = records.count
        totalBytes = records.reduce(0) { $0 + $1.fileSize }
    }
}
