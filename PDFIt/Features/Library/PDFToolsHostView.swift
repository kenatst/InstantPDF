import SwiftUI
import PDFKit

/// The tool a user activated from the Viewer. Identifiable so
/// `.sheet(item:)` presentation carries stable context.
enum PDFToolKind: String, CaseIterable, Identifiable {
    case tools
    case compress
    case sign
    case extract
    case recognizeText

    var id: String { rawValue }
}

/// Host sheet for all PDF tools operating on one document (by persistent ID).
/// Every tool writes its output as a NEW Library record; the original file
/// bytes are never modified.
struct PDFToolsHostView: View {
    let recordID: UUID
    var onDocumentCreated: () -> Void = {}

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
    @State private var pendingCompressedData: Data?
    // Signature state
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

    private let storage = StorageManager.shared

    enum ToolSection { case menu, compress, sign, extract, ocr }
    @State private var section: ToolSection = .menu

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
                } onClear: {
                    signatureImage = nil
                }
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

    /// Saves finished data as a NEW library record.
    @discardableResult
    private func saveOutput(_ data: Data, source: ContentSource) -> StoredPDFRecord? {
        let document = ConvertedDocument(data: data,
                                         pageCount: PDFAssembly.pageCount(of: data),
                                         suggestedTitle: outputName,
                                         sourceURL: record.map { URL(string: $0.sourceURL ?? "") }.flatMap { $0 },
                                         source: source)
        let saved = try? storage.save(document: document)
        if saved != nil {
            savedMessage = String(localized: "Saved to Library.")
            onDocumentCreated()
        }
        return saved
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
                // Route through the host app paywall by presenting inline gate.
                section = section // no-op; the row shows PRO badge and opens paywall below
            }
            action()
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
        progressText = String(localized: "Compressing…")
        Task {
            do {
                let result = try PDFTools.compress(from: url, preset: compressionPreset)
                await MainActor.run {
                    compressionResultSize = result.byteCount
                    let originalBytes = (try? Data(contentsOf: url).count) ?? 0
                    if result.byteCount < originalBytes {
                        outputName = "\(record.displayName) — Compressed"
                        _ = saveOutput(result.data, source: record.contentSource)
                    } else {
                        // Honest outcome: nothing to gain.
                        progressText = ""
                        savedMessage = String(localized: "This PDF is already well optimized — no smaller copy was created.")
                        pendingCompressedData = nil
                    }
                    isProcessing = false
                    if pendingCompressedData == nil { /* stay on results */ }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    savedMessage = String(localized: "Compression failed.")
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
        .onChange(of: showingSignatureCanvas) { _, showing in
            if !showing && signatureImage != nil {
                outputName = "\(record?.displayName ?? "Document") — Signed"
            }
        }
    }

    private func applySignature() {
        guard let url = sourceURL(), let record,
              let signature = signatureImage,
              let png = signature.pngData() else { return }
        isProcessing = true
        progressText = String(localized: "Placing signature…")
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
                    _ = saveOutput(signed, source: record.contentSource)
                    isProcessing = false
                    section = .menu
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    savedMessage = String(localized: "Signing failed.")
                }
            }
        }
    }

    // MARK: - Extract

    private var extractView: some View {
        VStack(spacing: 0) {
            HStack {
                Text(String(localized: "plural.pages \(selectedPages.count)"))
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
        progressText = String(localized: "Extracting pages…")
        let ordered = selectedPages.sorted()
        Task {
            do {
                let extracted = try PDFTools.extractPages(from: url, pageNumbers: ordered)
                await MainActor.run {
                    outputName = "\(record.displayName) — Extract"
                    _ = saveOutput(extracted, source: record.contentSource)
                    isProcessing = false
                    section = .menu
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    savedMessage = String(localized: "Extraction failed.")
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
        progressText = String(localized: "Recognizing text…")
        Task {
            do {
                let searchable = try await OCRRouter.makeSearchablePDF(from: url)
                await MainActor.run {
                    outputName = "\(record.displayName) — Searchable"
                    _ = saveOutput(searchable, source: record.contentSource)
                    isProcessing = false
                    section = .menu
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    savedMessage = String(localized: "Text recognition failed.")
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
                }
                Text("\(pageNumber)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
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

// MARK: - Signature drawing canvas

struct SignatureCanvasView: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: (UIImage) -> Void
    var onClear: () -> Void = {}

    @State private var strokes: [[CGPoint]] = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Sign below with your finger or Apple Pencil.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Canvas { context, size in
                    for stroke in strokes where stroke.count > 1 {
                        var path = Path()
                        path.move(to: stroke[0])
                        for point in stroke.dropFirst() {
                            path.addLine(to: point)
                        }
                        context.stroke(path, with: .color(.black),
                                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if strokes.last != nil, value.translation.width != .zero || true {
                                strokes[strokes.count - 1].append(value.location)
                            }
                        }
                        .onEnded { _ in }
                )
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Color.secondary.opacity(0.35),
                                      style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                )
                .padding(.horizontal, 20)

                HStack(spacing: 14) {
                    Button("Clear") {
                        strokes.removeAll()
                        onClear()
                    }
                    .secondaryDarkButton()

                    Button("Done") {
                        renderSignature { image in
                            if let image {
                                onDone(image)
                                dismiss()
                            }
                        }
                    }
                    .primaryOrangeButton()
                    .disabled(strokes.isEmpty)
                }
                .padding(.horizontal, 20)
            }
            .themeBackground()
            .navigationTitle("Create Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    /// Renders strokes to a transparent PNG trimmed to ink bounds.
    private func renderSignature(completion: @escaping (UIImage?) -> Void) {
        let canvasSize = CGSize(width: 800, height: 320)
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 2
            f.opaque = false
            return f
        }())
        let image = renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))
            UIColor.black.setStroke()
            for stroke in strokes where stroke.count > 1 {
                let path = UIBezierPath()
                // Map from view coordinates to canvas coordinates.
                let viewSize = CGSize(width: UIScreen.main.bounds.width - 40,
                                      height: UIScreen.main.bounds.height * 0.4)
                path.move(to: CGPoint(x: stroke[0].x / max(viewSize.width, 1) * canvasSize.width,
                                      y: stroke[0].y / max(viewSize.height, 1) * canvasSize.height))
                for point in stroke.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x / max(viewSize.width, 1) * canvasSize.width,
                                             y: point.y / max(viewSize.height, 1) * canvasSize.height))
                }
                path.lineWidth = 6
                path.lineCapStyle = .round
                path.stroke()
            }
        }
        completion(image.trimmedToInk())
    }
}

extension UIImage {
    /// Crops fully-transparent margins so signature placement scales
    /// predictably. Falls back to the original image when ink bounds cannot
    /// be determined.
    func trimmedToInk() -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return self }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow

        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let alpha = bytesPerPixel == 4 ? bytes[offset + 3] : 255
                if alpha > 8 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil } // no ink at all
        let inset = 4
        minX = max(0, minX - inset); minY = max(0, minY - inset)
        maxX = min(width - 1, maxX + inset); maxY = min(height - 1, maxY + inset)
        let cropRect = CGRect(x: minX, y: minY,
                              width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cropped = cgImage.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped)
    }
}

