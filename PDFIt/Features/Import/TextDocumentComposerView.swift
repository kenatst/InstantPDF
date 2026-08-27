import SwiftUI
import PDFKit

/// A deliberately small document composer. The same configuration value is
/// edited here, rendered for preview, and persisted without a second style path.
struct TextEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var previewModel = TextDocumentPreviewModel()
    @ObservedObject private var entitlements = EntitlementCenter.shared
    @ObservedObject private var signatureStore = SignatureStore.shared

    @State private var document = TextDocumentConfiguration()
    @State private var options: ConversionOptions = {
        var value = ConversionOptions.fromSharedDefaults()
        if value.paperSize == .automatic { value.paperSize = .a4 }
        return value
    }()
    @State private var showingStyle = false
    @State private var showingLayout = false
    @State private var showingPreview = false
    @State private var showingSignatureCanvas = false
    @State private var showingSignatureActions = false
    @State private var showingSignaturePlacement = false
    @State private var signatureBaseData: Data?
    @State private var paywallFeature: ProFeature?
    @State private var resumeSignatureAfterPaywall = false
    @State private var creationDate = Date()
    @State private var isCreating = false
    @State private var isPreparingSignature = false
    @State private var errorMessage: String?

    let onCreate: (ConvertedDocument) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                writeView
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Text to PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: openPreview) { Image(systemName: "doc.text.magnifyingglass") }
                        .accessibilityLabel("Preview")
                        .disabled(!document.isRenderable)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .overlay {
                if isPreparingSignature {
                    ZStack {
                        Color.black.opacity(0.18).ignoresSafeArea()
                        ProgressView("Preparing document…")
                            .padding(.horizontal, 24)
                            .padding(.vertical, 18)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
            }
            .sheet(isPresented: $showingStyle) {
                TextDocumentStyleSheet(document: $document)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showingLayout) {
                TextDocumentSettingsSheet(document: $document, options: $options)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showingPreview) {
                TextDocumentPreviewSheet(model: previewModel,
                                         document: document,
                                         options: options,
                                         creationDate: creationDate,
                                         onCreate: createPDF)
            }
            .sheet(isPresented: $showingSignatureCanvas) {
                SignatureCanvasView { image in
                    attachSignature(image)
                }
            }
            .sheet(isPresented: $showingSignaturePlacement, onDismiss: previewModel.invalidate) {
                if let signatureBaseData,
                   let signature = document.signature,
                   let image = UIImage(data: signature.pngData) {
                    TextSignaturePlacementSheet(documentData: signatureBaseData,
                                                pageCount: max(1, PDFAssembly.pageCount(of: signatureBaseData)),
                                                signature: image,
                                                placement: signaturePlacementBinding)
                }
            }
            .sheet(item: $paywallFeature, onDismiss: resumeSignatureIfNeeded) { feature in
                PaywallView(feature: feature,
                            onVerifiedPurchase: { _ in
                    resumeSignatureAfterPaywall = true
                    paywallFeature = nil
                }, onDemoMode: { _ in
                    resumeSignatureAfterPaywall = true
                    paywallFeature = nil
                })
            }
            .confirmationDialog("Signature",
                                isPresented: $showingSignatureActions,
                                titleVisibility: .visible) {
                if let saved = signatureStore.savedImage {
                    Button("Use Saved Signature") { attachSignature(saved) }
                    Button("Delete Saved Signature", role: .destructive) {
                        signatureStore.delete()
                        document.signature = nil
                    }
                }
                Button("Create New Signature") { showingSignatureCanvas = true }
                if document.signature != nil {
                    Button("Remove from Document", role: .destructive) {
                        document.signature = nil
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert("Couldn’t Create PDF", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .onChange(of: document) { _, _ in previewModel.invalidate() }
            .onChange(of: options) { _, _ in previewModel.invalidate() }
        }
    }

    private var signaturePlacementBinding: Binding<TextDocumentSignature> {
        Binding(get: { document.signature ?? TextDocumentSignature(pngData: Data()) },
                set: { document.signature = $0 })
    }

    private var writeView: some View {
        VStack(alignment: document.alignment == .center ? .center : .leading, spacing: 0) {
            TextField("Title (Optional)", text: $document.title, axis: .vertical)
                .font(.system(size: min(34, max(18, document.titleSize)),
                              weight: swiftUIFontWeight(document.titleWeight),
                              design: swiftUIFontDesign))
                .foregroundStyle(documentInk)
                .multilineTextAlignment(swiftUITextAlignment)
                .padding(.bottom, document.title.isEmpty ? 12 : 20)

            ZStack(alignment: .topLeading) {
                if document.body.isEmpty {
                    Text("Start writing…")
                        .font(.system(size: min(18, max(11, document.bodySize + 1)),
                                      weight: swiftUIFontWeight(document.bodyWeight),
                                      design: swiftUIFontDesign))
                        .foregroundStyle(Color.black.opacity(0.28))
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $document.body)
                    .font(.system(size: min(18, max(11, document.bodySize + 1)),
                                  weight: swiftUIFontWeight(document.bodyWeight),
                                  design: swiftUIFontDesign))
                    .foregroundStyle(documentInk)
                    .multilineTextAlignment(swiftUITextAlignment)
                    .lineSpacing(max(1, document.bodySize * (document.lineHeightMultiple - 1)))
                    .scrollContentBackground(.hidden)
                    .background(.clear)
                    .padding(.horizontal, -5)
                    .textInputAutocapitalization(.sentences)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(canvasPadding)
        .frame(maxWidth: 520)
        .aspectRatio(options.paperSize.pointSize.width / options.paperSize.pointSize.height, contentMode: .fit)
        .frame(minHeight: 520)
        .background(Color.white)
        .shadow(color: .black.opacity(0.10), radius: 18, y: 7)
    }

    private let documentInk = Color(red: 0.08, green: 0.085, blue: 0.10)

    private var canvasPadding: CGFloat {
        switch document.margin {
        case .compact: return 30
        case .normal: return 40
        case .large: return 50
        }
    }

    private var swiftUITextAlignment: TextAlignment {
        document.alignment == .center ? .center : (document.alignment == .right ? .trailing : .leading)
    }

    private var swiftUIFontDesign: Font.Design {
        switch document.fontFamily {
        case .system: return .default
        case .serif: return .serif
        case .rounded: return .rounded
        }
    }

    private func swiftUIFontWeight(_ weight: TextDocumentWeight) -> Font.Weight {
        switch weight {
        case .regular: return .regular
        case .medium: return .medium
        case .bold: return .bold
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 11) {
            HStack(spacing: 0) {
                composerTool("Style", symbol: "textformat") { showingStyle = true }
                composerTool("Layout", symbol: "rectangle.inset.filled") { showingLayout = true }
                Button(action: requestSignature) {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: document.signature == nil ? "signature" : "checkmark.seal.fill")
                                .font(.system(size: 18, weight: .medium))
                            if !FeaturePolicy.isUnlocked(.signature, entitlement: entitlements) {
                                ProBadge().scaleEffect(0.72).offset(x: 20, y: -8)
                            }
                        }
                        Text("Signature").font(.caption.weight(.medium))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(document.signature == nil ? Color.primary : Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)

            Button(action: createPDF) {
                HStack(spacing: 9) {
                    if isCreating { ProgressView().tint(.white) }
                    Text("Create PDF")
                    if !isCreating { Image(systemName: "arrow.right") }
                }
            }
            .primaryOrangeButton()
            .disabled(!document.isRenderable || isCreating)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    private func composerTool(_ title: LocalizedStringKey,
                              symbol: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private func openPreview() {
        guard document.isRenderable else { return }
        showingPreview = true
    }

    private func requestSignature() {
        guard FeaturePolicy.isUnlocked(.signature, entitlement: entitlements) else {
            paywallFeature = .signature
            return
        }
        beginSignatureFlow()
    }

    private func beginSignatureFlow() {
        if signatureStore.savedImage != nil || document.signature != nil {
            showingSignatureActions = true
        } else {
            showingSignatureCanvas = true
        }
    }

    private func resumeSignatureIfNeeded() {
        guard resumeSignatureAfterPaywall else { return }
        resumeSignatureAfterPaywall = false
        beginSignatureFlow()
    }

    private func attachSignature(_ image: UIImage) {
        guard let png = image.pngData() else { return }
        document.signature = TextDocumentSignature(pngData: png)
        isPreparingSignature = true
        Task {
            var unsigned = document
            unsigned.signature = nil
            let data = await previewModel.render(document: unsigned,
                                                 options: options,
                                                 creationDate: creationDate)
            isPreparingSignature = false
            signatureBaseData = data
            showingSignaturePlacement = data != nil
            if data == nil { errorMessage = previewModel.errorMessage }
        }
    }

    private func createPDF() {
        guard document.isRenderable, !isCreating else { return }
        isCreating = true
        Task {
            let data = await previewModel.render(document: document,
                                                 options: options,
                                                 creationDate: creationDate)
            isCreating = false
            guard let data else {
                errorMessage = previewModel.errorMessage ?? String(localized: "The PDF couldn’t be generated.", bundle: LanguageManager.bundle)
                return
            }
            let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let converted = ConvertedDocument(data: data,
                                              pageCount: PDFAssembly.pageCount(of: data),
                                              suggestedTitle: title.isEmpty
                                                ? String(localized: "Text Document", bundle: LanguageManager.bundle)
                                                : title,
                                              sourceURL: nil,
                                              source: .textEditor)
            dismiss()
            onCreate(converted)
        }
    }
}

@MainActor
private final class TextDocumentPreviewModel: ObservableObject {
    @Published private(set) var baseData: Data?
    @Published private(set) var finalData: Data?
    @Published private(set) var pageCount = 0
    @Published private(set) var isRendering = false
    @Published private(set) var errorMessage: String?

    private var renderedDocument: TextDocumentConfiguration?
    private var renderedOptions: ConversionOptions?

    func render(document: TextDocumentConfiguration,
                options: ConversionOptions,
                creationDate: Date) async -> Data? {
        if matches(document: document, options: options), let finalData { return finalData }
        guard document.isRenderable else {
            return nil
        }
        isRendering = true
        errorMessage = nil
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                var unsignedDocument = document
                let signature = unsignedDocument.signature
                unsignedDocument.signature = nil
                let base = try TextPDFConverter().convert(document: unsignedDocument,
                                                          options: options,
                                                          creationDate: creationDate)
                let final: Data
                if let signature {
                    final = try PDFTools.placeSignature(pngData: signature.pngData,
                                                        on: base,
                                                        pages: [min(max(1, signature.pageNumber), PDFAssembly.pageCount(of: base))],
                                                        normalizedRect: signature.normalizedRect)
                } else {
                    final = base
                }
                return (base, final)
            }.value
            baseData = result.0
            finalData = result.1
            pageCount = PDFAssembly.pageCount(of: result.1)
            renderedDocument = document
            renderedOptions = options
            isRendering = false
            return result.1
        } catch is CancellationError {
            isRendering = false
            return nil
        } catch {
            isRendering = false
            errorMessage = String(localized: "Preview couldn’t be generated.", bundle: LanguageManager.bundle)
            return nil
        }
    }

    func matches(document: TextDocumentConfiguration, options: ConversionOptions) -> Bool {
        renderedDocument == document && renderedOptions == options
    }

    func invalidate() {
        renderedDocument = nil
        renderedOptions = nil
        baseData = nil
        finalData = nil
        pageCount = 0
        isRendering = false
        errorMessage = nil
    }

}

private struct ComposerPDFPreview: UIViewRepresentable {
    let data: Data
    @Binding var currentPage: Int

    final class Coordinator: NSObject {
        var parent: ComposerPDFPreview
        var data: Data?
        weak var pdfView: PDFView?

        init(parent: ComposerPDFPreview) { self.parent = parent }

        @objc func pageChanged() {
            guard let view = pdfView,
                  let page = view.currentPage,
                  let index = view.document?.index(for: page) else { return }
            parent.currentPage = index + 1
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        context.coordinator.pdfView = view
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .horizontal
        view.usePageViewController(true, withViewOptions: nil)
        view.pageBreakMargins = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.backgroundColor = .secondarySystemBackground
        NotificationCenter.default.addObserver(context.coordinator,
                                               selector: #selector(Coordinator.pageChanged),
                                               name: .PDFViewPageChanged,
                                               object: view)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.data != data else { return }
        context.coordinator.data = data
        view.document = PDFDocument(data: data)
        view.autoScales = true
        currentPage = 1
    }

    static func dismantleUIView(_ view: PDFView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
    }
}

private struct TextDocumentSettingsSheet: View {
    private enum AdvancedField {
        case header
        case footer
    }

    @Environment(\.dismiss) private var dismiss
    @Binding var document: TextDocumentConfiguration
    @Binding var options: ConversionOptions
    @ObservedObject private var entitlements = EntitlementCenter.shared
    @State private var paywallFeature: ProFeature?
    @State private var pendingAdvancedField: AdvancedField?
    @State private var resumeAdvancedAfterPaywall = false
    @State private var headerEnabled: Bool
    @State private var footerEnabled: Bool
    @FocusState private var focusedField: AdvancedField?

    init(document: Binding<TextDocumentConfiguration>, options: Binding<ConversionOptions>) {
        _document = document
        _options = options
        _headerEnabled = State(initialValue: !document.wrappedValue.headerText.isEmpty)
        _footerEnabled = State(initialValue: !document.wrappedValue.footerText.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Page") {
                    Picker("Paper", selection: $options.paperSize) {
                        Text("A4").tag(PDFPaperSize.a4)
                        Text("Letter").tag(PDFPaperSize.letter)
                    }
                    .pickerStyle(.segmented)
                    Picker("Margins", selection: $document.margin) {
                        ForEach(TextDocumentMargin.allCases) { margin in
                            Text(margin.displayName).tag(margin)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Document Details") {
                    TextField(document.preset == .letter ? "Recipient (Optional)" : "Subtitle (Optional)",
                              text: $document.subtitle)
                    TextField("Author (Optional)", text: $document.author)
                }

                Section("Optional Elements") {
                    Toggle("Date", isOn: $document.includeDate)
                    Toggle("Page Numbers", isOn: $document.includePageNumbers)
                    advancedToggle(title: "Header", value: $headerEnabled, field: .header)
                    if headerEnabled && FeaturePolicy.isUnlocked(.advancedCustomization, entitlement: entitlements) {
                        TextField("Header text", text: $document.headerText)
                            .focused($focusedField, equals: .header)
                    }
                    advancedToggle(title: "Footer", value: $footerEnabled, field: .footer)
                    if footerEnabled && FeaturePolicy.isUnlocked(.advancedCustomization, entitlement: entitlements) {
                        TextField("Footer text", text: $document.footerText)
                            .focused($focusedField, equals: .footer)
                    }
                }
            }
            .navigationTitle("Layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $paywallFeature, onDismiss: resumeAdvancedIfNeeded) { feature in
                PaywallView(feature: feature,
                            onVerifiedPurchase: { _ in
                    resumeAdvancedAfterPaywall = true
                    paywallFeature = nil
                }, onDemoMode: { _ in
                    resumeAdvancedAfterPaywall = true
                    paywallFeature = nil
                })
            }
        }
    }

    private func advancedToggle(title: LocalizedStringKey,
                                value: Binding<Bool>,
                                field: AdvancedField) -> some View {
        Toggle(isOn: Binding(get: { value.wrappedValue }, set: { newValue in
            if newValue && !FeaturePolicy.isUnlocked(.advancedCustomization, entitlement: entitlements) {
                requestAdvanced(field)
            } else {
                value.wrappedValue = newValue
                if !newValue {
                    if field == .header { document.headerText = "" }
                    if field == .footer { document.footerText = "" }
                }
            }
        })) {
            HStack {
                Text(title)
                if !FeaturePolicy.isUnlocked(.advancedCustomization, entitlement: entitlements) {
                    Spacer()
                    ProBadge()
                }
            }
        }
    }

    private func requestAdvanced(_ field: AdvancedField) {
        pendingAdvancedField = field
        paywallFeature = .advancedCustomization
    }

    private func resumeAdvancedIfNeeded() {
        guard resumeAdvancedAfterPaywall, let field = pendingAdvancedField else { return }
        resumeAdvancedAfterPaywall = false
        pendingAdvancedField = nil
        if field == .header { headerEnabled = true }
        if field == .footer { footerEnabled = true }
        focusedField = field
    }
}

private struct TextDocumentStyleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var document: TextDocumentConfiguration
    @State private var showingCustomize = false
    private let alignments: [TextDocumentAlignment] = [.left, .center, .justified]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(TextDocumentPreset.allCases) { preset in
                            presetButton(preset)
                        }
                    }

                    Divider()

                    DisclosureGroup("Customize", isExpanded: $showingCustomize) {
                        VStack(alignment: .leading, spacing: 20) {
                            semanticPicker("Typography", selection: $document.fontFamily) {
                                ForEach(TextDocumentFontFamily.allCases) { family in
                                    Text(family.displayName).tag(family)
                                }
                            }
                            semanticPicker("Text Size", selection: Binding(get: {
                                document.textSize
                            }, set: { document.apply($0) })) {
                                ForEach(TextDocumentTextSize.allCases) { size in
                                    Text(size.displayName).tag(size)
                                }
                            }
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Alignment").font(.subheadline.weight(.semibold))
                                Picker("Alignment", selection: $document.alignment) {
                                    ForEach(alignments) { alignment in
                                        Image(systemName: alignment.systemImage).tag(alignment)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        .padding(.top, 18)
                    }
                    .font(.headline)
                }
                .padding(20)
            }
            .navigationTitle("Style")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func presetButton(_ preset: TextDocumentPreset) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { document.apply(preset) }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.white)
                    VStack(alignment: preset == .editorial ? .center : .leading, spacing: 5) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.black.opacity(0.8))
                            .frame(width: preset == .editorial ? 50 : 62,
                                   height: preset == .editorial ? 6 : 5)
                        ForEach(0..<4, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Color.black.opacity(index == 3 ? 0.18 : 0.30))
                                .frame(width: index == 3 ? 54 : 82, height: 2)
                        }
                    }
                }
                .frame(height: 84)
                .shadow(color: .black.opacity(0.08), radius: 5, y: 2)

                HStack {
                    Text(preset.displayName).font(.subheadline.weight(.semibold))
                    Spacer()
                    if document.preset == preset {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(document.preset == preset ? Color.accentColor : .clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func semanticPicker<Selection: Hashable, Content: View>(_ title: LocalizedStringKey,
                                                                     selection: Binding<Selection>,
                                                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.semibold))
            Picker(title, selection: selection, content: content).pickerStyle(.segmented)
        }
    }
}

private struct TextDocumentPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: TextDocumentPreviewModel
    let document: TextDocumentConfiguration
    let options: ConversionOptions
    let creationDate: Date
    let onCreate: () -> Void
    @State private var currentPage = 1

    var body: some View {
        NavigationStack {
            Group {
                if model.isRendering {
                    ProgressView("Preparing preview…")
                } else if let data = model.finalData,
                          model.matches(document: document, options: options) {
                    ComposerPDFPreview(data: data, currentPage: $currentPage)
                        .ignoresSafeArea(edges: .bottom)
                } else if let error = model.errorMessage {
                    ContentUnavailableView("Preview Unavailable",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                }
            }
            .background(Color(.secondarySystemBackground))
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Edit") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Text(String.localizedStringWithFormat(
                        String(localized: "Page %lld of %lld", bundle: LanguageManager.bundle),
                        currentPage,
                        max(1, model.pageCount)
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Button("Edit") { dismiss() }.secondaryDarkButton()
                        Button("Create PDF", action: onCreate)
                            .primaryOrangeButton()
                            .disabled(model.finalData == nil)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial)
            }
            .task {
                _ = await model.render(document: document,
                                       options: options,
                                       creationDate: creationDate)
            }
        }
    }
}

private struct TextSignaturePlacementSheet: View {
    @Environment(\.dismiss) private var dismiss
    let documentData: Data
    let pageCount: Int
    let signature: UIImage
    @Binding var placement: TextDocumentSignature

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                SignaturePlacementCanvas(documentData: documentData,
                                         pageNumber: placement.pageNumber,
                                         signature: signature,
                                         normalizedX: $placement.normalizedX,
                                         normalizedY: $placement.normalizedY,
                                         scale: $placement.scale)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 16)
                Stepper(value: $placement.pageNumber, in: 1...max(1, pageCount)) {
                    Text(String.localizedStringWithFormat(
                        String(localized: "Page %lld of %lld", bundle: LanguageManager.bundle),
                        placement.pageNumber,
                        pageCount
                    ))
                }
                .padding(.horizontal, 20)
                HStack {
                    Text("Size")
                    Slider(value: $placement.scale, in: 0.4...2, step: 0.05)
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 16)
            .navigationTitle("Place Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
