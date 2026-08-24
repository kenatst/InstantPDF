import SwiftUI
import PDFKit

/// Host sheet for all PDF tools operating on one document (by persistent ID).
/// Every tool writes its output as a NEW Library record; the original file
/// bytes are never modified. On success the host reports the NEW record UUID
/// through `onOutputCreated`, and the presenting viewer navigates straight
/// to the result — no manual back-back-find-your-output dance.
struct PDFToolsHostView: View {
    let recordID: UUID
    /// Called with the freshly created document's persistent ID.
    var onOutputCreated: (UUID) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var entitlements = EntitlementCenter.shared

    @State private var record: StoredPDFRecord?
    @State private var isProcessing = false
    @State private var progressText = ""
    // Compression state
    @State private var compressionPreset: PDFTools.CompressionPreset = .balanced
    @State private var compressionResultSize: Int?
    @State private var compressionOriginalSize: Int?
    // Signature state
    @ObservedObject private var signatureStore = SignatureStore.shared
    @State private var signatureImage: UIImage?
    @State private var signaturePage = 1
    @State private var signatureScale: CGFloat = 1.0
    @State private var signatureVertical: CGFloat = 0.78
    @State private var showingSignatureCanvas = false
    // Extract state
    @State private var selectedPages: Set<Int> = []
    @State private var pageCount = 0
    // Shared output name
    @State private var outputName = ""
    @State private var savedMessage: String?
    @State private var errorMessage: String?
    // Paywall (locked tool tapped)
    @State private var paywallFeature: ProFeature?
    /// Post-purchase activation flow, then resume the requested tool.
    @State private var showingActivationFlow = false

    private let storage = StorageManager.shared

    enum ToolSection { case menu, compress, sign, extract, ocr }
    @State private var section: ToolSection = .menu

    /// Maps a purchased feature back to its tool screen so contextual
    /// purchase resumes exactly where the user started.
    static func section(for feature: ProFeature) -> ToolSection {
        switch feature {
        case .compression: return .compress
        case .signature: return .sign
        case .extractPages: return .extract
        case .ocr: return .ocr
        default: return .menu
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isProcessing {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text(progressText)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    switch section {
                    case .menu: menuView
                    case .compress: compressView
                    case .sign: signView
                    case .extract: extractView
                    case .ocr: ocrConfirmView
                    }
                }
            }
            .themeBackground()
            .navigationTitle("PDF Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showingSignatureCanvas) {
                SignatureCanvasView { image in
                    signatureImage = image
                    showingSignatureCanvas = false
                    outputName = "\(record?.displayName ?? "Document") — Signed"
                }
            }
            .sheet(item: $paywallFeature) { feature in
#if DEBUG
                PaywallView(feature: feature,
                            onVerifiedPurchase: { _ in
                    // Verified purchase from a locked tool row: run the
                    // activation flow; when it finishes, land back on the
                    // EXACT tool the user originally wanted.
                    showingActivationFlow = true
                }, onDebugDemoMode: { intent in
                    // Demo Mode does not impersonate a purchase. Resume the
                    // exact tool immediately and skip the activation ceremony.
                    section = Self.section(for: intent)
                })
#else
                PaywallView(feature: feature) { _ in
                    showingActivationFlow = true
                }
#endif
            }
            .sheet(isPresented: $showingActivationFlow) {
                ProActivationFlow { intent in
                    if let intent {
                        section = Self.section(for: intent)
                    } else {
                        section = .menu
                    }
                }
            }
            .alert("Tool failed", isPresented: Binding(get: { errorMessage != nil },
                                                       set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .onAppear(perform: load)
    }

    // MARK: - Data

    private func load() {
        record = storage.record(withID: recordID)
        if let record, let url = storage.fileURL(for: record) {
            pageCount = PDFDocument(url: url)?.pageCount ?? 0
            compressionOriginalSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        }
        outputName = suggestedOutputName(suffix: "Extract")
    }

    private func sourceURL() -> URL? {
        guard let record else { return nil }
        return storage.fileURL(for: record)
    }

    private func suggestedOutputName(suffix: String) -> String {
        guard let base = record?.displayName, !base.isEmpty else { return suffix }
        return "\(base) — \(suffix)"
    }

    /// Saves finished data as a NEW library record and hands its UUID to the
    /// presenter for immediate navigation. A failed save is USER-VISIBLE.
    @discardableResult
    private func saveOutput(_ data: Data, source: ContentSource) -> StoredPDFRecord? {
        let document = ConvertedDocument(data: data,
                                         pageCount: PDFAssembly.pageCount(of: data),
                                         suggestedTitle: outputName,
                                         sourceURL: record.map { URL(string: $0.sourceURL ?? "") }.flatMap { $0 },
                                         source: source)
        do {
            let saved = try storage.save(document: document)
            savedMessage = String(localized: "Saved to Library.", bundle: LanguageManager.bundle)
            dismiss()
            onOutputCreated(saved.id)
            return saved
        } catch {
            errorMessage = String(localized: "The result couldn't be saved to your Library.", bundle: LanguageManager.bundle)
            return nil
        }
    }

    // MARK: - Menu

    private var menuView: some View {
        List {
            if let savedMessage {
                Section {
                    Label(savedMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            Section("Organize") {
                toolRow(symbol: "arrow.down.doc", title: "Compress", pro: .compression) { section = .compress }
                toolRow(symbol: "square.and.line.vertical.and.square.fill", title: "Extract Pages", pro: .extractPages) { section = .extract }
                toolRow(symbol: "text.viewfinder", title: "Recognize Text", pro: .ocr) { section = .ocr }
            }
            Section("Annotate") {
                toolRow(symbol: "signature", title: "Sign", pro: .signature) { section = .sign }
            }
        }
    }

    private func toolRow(symbol: String, title: String, pro feature: ProFeature?, action: @escaping () -> Void) -> some View {
        let locked = feature.map { !FeaturePolicy.isUnlocked($0, entitlement: entitlements) } ?? false
        return Button {
            if locked {
                // Contextual paywall ON INTENT — never a silent no-op, never
                // executing a gated action anyway.
                paywallFeature = feature
            } else {
                action()
            }
        } label: {
            HStack {
                Label(LocalizedStringKey(title), systemImage: symbol)
                Spacer()
                if locked {
                    ProBadge()
                }
            }
        }
        .foregroundStyle(.primary)
    }

    // MARK: - Compress

    private var compressView: some View {
        Form {
            Section("Quality") {
                Picker("Preset", selection: $compressionPreset) {
                    ForEach(PDFTools.CompressionPreset.allCases) { preset in
                        Text(LocalizedStringKey(preset.displayNameKey)).tag(preset)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            if let original = compressionOriginalSize {
                Section("Size") {
                    LabeledContent("Original", value: ByteCountFormatter.string(fromByteCount: Int64(original), countStyle: .file))
                    if let result = compressionResultSize {
                        LabeledContent("Result", value: ByteCountFormatter.string(fromByteCount: Int64(result), countStyle: .file))
                    }
                }
            }
            Section {
                TextField("Output name", text: $outputName)
            }
            Section {
                Button {
                    runCompression()
                } label: {
                    Text("Compress").fontWeight(.semibold)
                }
                .disabled(isProcessing)
            }
        }
    }

    private func runCompression() {
        guard let url = sourceURL(), let record else { return }
        isProcessing = true
        progressText = String(localized: "Compressing…", bundle: LanguageManager.bundle)
        Task {
            do {
                let result = try PDFTools.compress(from: url, preset: compressionPreset)
                await MainActor.run {
                    compressionResultSize = result.byteCount
                    let originalBytes = (try? Data(contentsOf: url).count) ?? 0
                    if result.byteCount < originalBytes {
                        outputName = "\(record.displayName) — Compressed"
                        isProcessing = false
                        _ = saveOutput(result.data, source: record.contentSource)
                    } else {
                        // Honest outcome: nothing to gain — no bigger "compressed" copy.
                        isProcessing = false
                        section = .menu
                        savedMessage = String(localized: "This PDF is already well optimized — no smaller copy was created.", bundle: LanguageManager.bundle)
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = String(localized: "Compression failed.", bundle: LanguageManager.bundle)
                }
            }
        }
    }

    // MARK: - Sign

    private var signView: some View {
        Form {
            Section("Signature") {
                if let signatureImage {
                    Image(uiImage: signatureImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 80)
                        .background(Color.white.cornerRadius(8))
                    Button("Redraw") { showingSignatureCanvas = true }
                } else if let saved = signatureStore.savedImage {
                    Image(uiImage: saved)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 60)
                        .background(Color.white.cornerRadius(8))
                    Button("Use Saved Signature") { signatureImage = saved }
                    Button("Create New Signature") { showingSignatureCanvas = true }
                    Button("Delete Signature", role: .destructive) { signatureStore.delete() }
                } else {
                    Button("Create Signature") { showingSignatureCanvas = true }
                }
            }
            if signatureImage != nil {
                Section("Placement") {
                    Stepper(value: $signaturePage, in: 1...max(1, pageCount)) {
                        Text("Page \(signaturePage) of \(max(1, pageCount))")
                    }
                    VStack(alignment: .leading) {
                        Text("Vertical position")
                        Slider(value: $signatureVertical, in: 0.1...0.9)
                    }
                    Stepper(value: $signatureScale, in: 0.4...2.0, step: 0.1) {
                        Text("Size ×\(String(format: "%.1f", signatureScale))")
                    }
                }
                Section {
                    TextField("Output name", text: $outputName)
                    Button {
                        applySignature()
                    } label: {
                        Text("Save Signed Copy").fontWeight(.semibold)
                    }
                }
            }
        }
    }

    private func applySignature() {
        guard let url = sourceURL(), let record,
              let signature = signatureImage,
              let png = signature.pngData() else { return }
        isProcessing = true
        progressText = String(localized: "Placing signature…", bundle: LanguageManager.bundle)
        Task {
            let width: CGFloat = 0.32 * signatureScale
            let height: CGFloat = 0.12 * signatureScale
            let rect = CGRect(x: 0.60, y: max(0.02, signatureVertical - height / 2), width: width, height: min(height, 0.94))
            do {
                let signed = try PDFTools.placeSignature(pngData: png,
                                                         on: url,
                                                         pages: [signaturePage],
                                                         normalizedRect: rect)
                await MainActor.run {
                    outputName = "\(record.displayName) — Signed"
                    isProcessing = false
                    _ = saveOutput(signed, source: record.contentSource)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = String(localized: "Signing failed.", bundle: LanguageManager.bundle)
                }
            }
        }
    }

    // MARK: - Extract

    private var extractView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "plural.pages \(selectedPages.count)", bundle: LanguageManager.bundle))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select All") {
                    selectedPages = selectedPages.count == pageCount ? [] : Set(1...max(1, pageCount))
                }
                .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                    ForEach(1...max(1, pageCount), id: \.self) { pageNumber in
                        ExtractPageCell(recordID: recordID,
                                        pageNumber: pageNumber,
                                        isSelected: selectedPages.contains(pageNumber)) {
                            if selectedPages.contains(pageNumber) {
                                selectedPages.remove(pageNumber)
                            } else {
                                selectedPages.insert(pageNumber)
                            }
                        }
                    }
                }
                .padding(16)
            }

            VStack(spacing: 10) {
                TextField("Output name", text: $outputName)
                    .textFieldStyle(.roundedBorder)
                Button {
                    runExtraction()
                } label: {
                    Text("Extract \(selectedPages.isEmpty ? "" : "(\(selectedPages.count)) ")Pages")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .primaryOrangeButton()
                .disabled(selectedPages.isEmpty || isProcessing)
            }
            .padding(16)
        }
        .onAppear {
            if outputName.isEmpty || !outputName.contains("Extract") {
                outputName = suggestedOutputName(suffix: "Extract")
            }
        }
    }

    private func runExtraction() {
        guard let url = sourceURL(), let record, !selectedPages.isEmpty else { return }
        isProcessing = true
        progressText = String(localized: "Extracting pages…", bundle: LanguageManager.bundle)
        let ordered = selectedPages.sorted()
        Task {
            do {
                let extracted = try PDFTools.extractPages(from: url, pageNumbers: ordered)
                await MainActor.run {
                    outputName = "\(record.displayName) — Extract"
                    isProcessing = false
                    _ = saveOutput(extracted, source: record.contentSource)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = String(localized: "Extraction failed.", bundle: LanguageManager.bundle)
                }
            }
        }
    }

    // MARK: - OCR

    private var ocrConfirmView: some View {
        Form {
            Section {
                Text("Runs entirely on this device using Apple Vision. The scan keeps its exact appearance and becomes searchable/selectable.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Output name", text: $outputName)
                Button {
                    runOCR()
                } label: {
                    Text("Make Searchable").fontWeight(.semibold)
                }
            }
        }
    }

    private func runOCR() {
        guard let url = sourceURL(), let record else { return }
        isProcessing = true
        progressText = String(localized: "Recognizing text…", bundle: LanguageManager.bundle)
        Task {
            do {
                let searchable = try await OCRRouter.makeSearchablePDF(from: url)
                await MainActor.run {
                    outputName = "\(record.displayName) — Searchable"
                    isProcessing = false
                    _ = saveOutput(searchable, source: record.contentSource)
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    errorMessage = String(localized: "Text recognition failed.", bundle: LanguageManager.bundle)
                }
            }
        }
    }
}

// MARK: - One lazy page cell for extraction

private struct ExtractPageCell: View {
    let recordID: UUID
    let pageNumber: Int
    let isSelected: Bool
    let toggle: () -> Void

    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let thumbnail {
                            Image(uiImage: thumbnail)
                                .resizable()
                                .scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.15))
                                .overlay(ProgressView())
                        }
                    }
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.Colors.orangePrimary : Color.white)
                        .shadow(radius: 2)
                        .padding(4)
                        .allowsHitTesting(false)
                }
                Text("\(pageNumber)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task {
            guard let record = StorageManager.shared.record(withID: recordID),
                  let url = StorageManager.shared.fileURL(for: record),
                  let document = PDFDocument(url: url),
                  let page = document.page(at: pageNumber - 1) else { return }
            let image = page.thumbnail(of: CGSize(width: 220, height: 300), for: .mediaBox)
            thumbnail = image
        }
    }
}
