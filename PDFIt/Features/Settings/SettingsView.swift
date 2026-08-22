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
                LabeledContent("PDFs", value: "\(recordCount)")
                LabeledContent("Total size",
                               value: ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))
            } header: {
                Text("Storage")
            } footer: {
                Text("Your PDFs stay on this device until you delete them.")
            }

            Section {
                LabeledContent("Works offline", value: "Yes")
                LabeledContent("Account required", value: "No")
            } header: {
                Text("Privacy")
            } footer: {
                Text("Conversions happen on your device whenever possible. Nothing is uploaded, tracked, or shared.")
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Creator tag", value: "PDFs are tagged “PDF It” in their metadata")
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
