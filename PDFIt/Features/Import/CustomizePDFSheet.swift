import SwiftUI

/// Compact "Customize PDF" sheet shown before final generation.
/// Optional by design — Create PDF without touching it stays the default flow.
struct CustomizePDFSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Binding var customization: PDFCustomization
    /// Multi-image imports can reorder before creation.
    var imageOrder: Binding<[URL]>? = nil
    /// Present for a staged "Customize First" web conversion: shows the
    /// Create button that consumes URL + mode + paper + customization.
    var onCreateStaged: (() -> Void)? = nil

    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Document") {
                    TextField("Title (optional)", text: $customization.documentTitle)
                    TextField("Author (optional)", text: $customization.authorText)
                }

                Section("Cover Page") {
                    Toggle("Add Cover Page", isOn: $customization.includeCoverPage)
                    if customization.includeCoverPage {
                        TextField("Cover Title", text: $customization.coverTitle)
                        TextField("Subtitle", text: $customization.coverSubtitle)
                    }
                }

                Section("Pages") {
                    Toggle("Page Numbers", isOn: $customization.includePageNumbers)
                    Stepper(value: $customization.extraMargin, in: 0...48, step: 8) {
                        Text("Extra Margin: \(Int(customization.extraMargin)) pt")
                    }
                }

                Section {
                    Toggle("Source URL Footer", isOn: $customization.includeSourceURLFooter)
                    Toggle("Creation Date Footer", isOn: $customization.includeCreationDateFooter)
                } header: {
                    Text("Footers")
                } footer: {
                    Text("Applies to generated text and article pages. Existing PDFs pass through untouched.")
                }

                if let imageOrder {
                    Section("Image Order") {
                        ForEach(Array(imageOrder.wrappedValue.enumerated()), id: \.offset) { pair in
                            HStack(spacing: 10) {
                                Image(systemName: "photo")
                                    .foregroundStyle(Theme.Colors.orangePrimary)
                                Text(String(localized: "Photo \(pair.offset + 1)", bundle: LanguageManager.bundle))
                                Spacer()
                                Image(systemName: "line.3.horizontal")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .onMove { source, destination in
                            imageOrder.wrappedValue.move(fromOffsets: source, toOffset: destination)
                        }
                        .environment(\.editMode, .constant(.active))
                    }
                }

                Section {
                    Toggle("Watermark", isOn: watermarkBinding)
                    if customization.trimmedWatermark != nil {
                        TextField("Watermark text", text: $customization.watermarkText)
                    }
                } header: {
                    Text("Watermark")
                } footer: {
                    Text("A subtle diagonal mark on every page. Off unless you type something.")
                }
            }
            .navigationTitle("Customize PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if onCreateStaged != nil {
                        Button("Create PDF") {
                            dismiss()
                            onCreateStaged?()
                        }
                        .fontWeight(.semibold)
                    } else {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        .tint(Theme.Colors.orangePrimary)
        .presentationDetents([.medium, .large])
    }

    private var watermarkBinding: Binding<Bool> {
        Binding(get: { customization.trimmedWatermark != nil },
                set: { on in
                    if on {
                        if customization.trimmedWatermark == nil {
                            customization.watermarkText = "CONFIDENTIAL"
                        }
                    } else {
                        customization.watermarkText = ""
                    }
                })
    }
}
