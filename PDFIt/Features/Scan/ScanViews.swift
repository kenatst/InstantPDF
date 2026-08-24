import SwiftUI
import VisionKit

/// Camera entry: presents the native VisionKit document scanner.
/// No decoration over the camera — functional and professional only.
struct ScanCameraView: UIViewControllerRepresentable {
    let onCompletion: ([UIImage]) -> Void
    let onError: (String) -> Void

    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion, onError: onError)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let onCompletion: ([UIImage]) -> Void
        let onError: (String) -> Void

        init(onCompletion: @escaping ([UIImage]) -> Void,
             onError: @escaping (String) -> Void) {
            self.onCompletion = onCompletion
            self.onError = onError
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            images.reserveCapacity(scan.pageCount)
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            controller.dismiss(animated: true)
            onCompletion(images)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
            onCompletion([])
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            controller.dismiss(animated: true)
            onError(error.localizedDescription)
        }
    }
}

/// THE scan entry sheet. Flow:
///   tap Scan Document → this sheet opens → camera presented automatically
///   (with graceful simulator/unavailability fallback) → capture lands in
///   the review screen → Create PDF → documents returned via onFinish.
struct ScanFlowSheet: View {
    @StateObject private var model: ScanFlowModel
    @Environment(\.dismiss) private var dismiss
    /// Documents produced by the flow; HomeView persists them.
    var onFinish: ([ConvertedDocument]) -> Void

    @State private var phase: Phase = .launching
    @State private var unavailabilityMessage: String?
    @ObservedObject private var entitlements = EntitlementCenter.shared
    @State private var showingBatchPaywall = false

    enum Phase { case launching, camera, review, batchGate }

    init(model: ScanFlowModel, onFinish: @escaping ([ConvertedDocument]) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        Group {
            switch phase {
            case .launching:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .themeBackground()
            case .camera:
                ScanCameraView { images in
                    if images.isEmpty {
                        // User cancelled inside the camera — close everything.
                        dismiss()
                    } else {
                        model.ingest(images: images)
                        withAnimation { phase = .review }
                    }
                } onError: { message in
                    unavailabilityMessage = message
                    phase = .review // review still reachable for context/cancel
                }
                .ignoresSafeArea()
            case .review:
                ScanReviewView(model: model,
                               batchEnabled: model.advancedBatchEnabled && entitlements.isPro,
                               onFinish: { documents in
                                   onFinish(documents)
                                   dismiss()
                               },
                               onClose: { dismiss() })
            case .batchGate:
                PaywallView(feature: .advancedBatch)
            }
        }
        .onAppear(perform: begin)
        .alert("Scanning unavailable", isPresented: Binding(
            get: { unavailabilityMessage != nil },
            set: { if !$0 { unavailabilityMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(unavailabilityMessage ?? "Document scanning requires a real iPhone or iPad with a camera.")
        }
    }

    private func begin() {
        guard phase == .launching else { return }
        guard ScanCameraView.isSupported else {
            unavailabilityMessage = String(localized: "This device doesn't support document scanning. Scanning requires a camera.")
            return
        }
        phase = .camera
    }
}

/// Review screen: reorder, rotate, delete, enhance presets, batch groups,
/// smart name suggestion, and the Create PDF path through the shared engine.
struct ScanReviewView: View {
    @StateObject private var model: ScanFlowModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPaper: PDFPaperSize = .automatic
    @State private var renamingGroupID: UUID?
    @State private var newGroupName = ""
    /// Whether the Pro batch workflow is unlocked for this session.
    var batchEnabled: Bool = true
    /// Documents produced by the flow; caller persists them.
    var onFinish: ([ConvertedDocument]) -> Void
    var onClose: (() -> Void)? = nil

    @State private var documentName = ""
    @State private var showingNameField = false

    init(model: ScanFlowModel,
         batchEnabled: Bool = true,
         onFinish: @escaping ([ConvertedDocument]) -> Void,
         onClose: (() -> Void)? = nil) {
        _model = StateObject(wrappedValue: model)
        self.batchEnabled = batchEnabled
        self.onFinish = onFinish
        self.onClose = onClose
        // Seed the smart suggestion once, from the group/document name.
        _documentName = State(initialValue: OCRRouter.suggestedName(ocrText: nil,
                                                                    fallbackTitle: nil))
    }

    private func finishCreating(_ documents: [ConvertedDocument]) {
        // Apply the user-edited smart name when creating a single document.
        if documents.count == 1, !documentName.trimmingCharacters(in: .whitespaces).isEmpty {
            let original = documents[0]
            let renamed = ConvertedDocument(data: original.data,
                                            pageCount: original.pageCount,
                                            suggestedTitle: documentName,
                                            sourceURL: original.sourceURL,
                                            source: original.source)
            onFinish([renamed])
        } else {
            onFinish(documents)
        }
        model.cleanUp()
        onClose?()
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.session.groups.count > 1 && batchEnabled {
                    batchList
                } else {
                    pageGrid
                }
            }
            .themeBackground()
            .navigationTitle(model.session.groups.count > 1 ? "Batch Scan" : "Review Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .sheet(isPresented: $model.showingCamera) {
                ScanCameraView { images in
                    model.ingest(images: images)
                } onError: { message in
                    // surfaced through alert below
                }
            }
            .alert("Rename Document", isPresented: Binding(get: { renamingGroupID != nil },
                                                           set: { if !$0 { renamingGroupID = nil } })) {
                TextField("Name", text: $newGroupName)
                Button("Save") {
                    if let id = renamingGroupID {
                        model.session.renameGroup(id: id, to: newGroupName)
                    }
                    renamingGroupID = nil
                }
                Button("Cancel", role: .cancel) { renamingGroupID = nil }
            }
        }
    }

    // MARK: - Single-document grid

    private var pageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
                ForEach($model.session.pages) { $page in
                    ScanPageCard(page: $page,
                                 onDelete: { model.session.removePage(id: page.id) })
                }
                .onMove { offsets, destination in
                    model.session.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Scan — date", text: $documentName)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)

            enhancementPicker
            paperPicker
            createButton(titleKey: "Create PDF") {
                await convert(group: nil)
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    // MARK: - Batch list (Pro)

    private var batchList: some View {
        List {
            ForEach($model.session.groups) { $group in
                Section {
                    ForEach(model.session.pages(in: group)) { page in
                        HStack(spacing: 12) {
                            ScanThumbnail(url: page.imageURL)
                                .frame(width: 44, height: 56)
                            Text(page.enhancement.displayNameKey)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Menu {
                                Button("Move to Previous Document") {
                                    model.session.movePage(id: page.id, toAdjacentGroup: -1)
                                }
                                .disabled(group.id == model.session.groups.first?.id)
                                Button("Move to Next Document") {
                                    model.session.movePage(id: page.id, toAdjacentGroup: +1)
                                }
                                .disabled(group.id == model.session.groups.last?.id)
                                Button("Rotate", systemImage: "rotate.right") {
                                    model.session.rotatePage(id: page.id)
                                }
                                Button("Delete", role: .destructive) {
                                    model.session.removePage(id: page.id)
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(group.name)
                        Spacer()
                        Text(String(localized: "plural.pages \(group.pageIDs.count)"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Menu {
                            Button("Rename", systemImage: "pencil") {
                                newGroupName = group.name
                                renamingGroupID = group.id
                            }
                            Button("Delete Group", role: .destructive) {
                                model.session.removeGroup(id: group.id)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                    }
                }
            }
            .onMove { offsets, destination in
                model.session.moveGroups(fromOffsets: offsets, toOffset: destination)
            }
            .onDelete { offsets in
                for index in offsets {
                    let group = model.session.groups[index]
                    model.session.removeGroup(id: group.id)
                }
            }

            Section {
                paperPicker
                ForEach(model.session.groups, id: \.id) { group in
                    createButton(titleKey: "Save All Documents") {
                        await saveAll()
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            }
        }
        .environment(\.editMode, .constant(.active))
    }

    private var enhancementPicker: some View {
        Picker("Enhancement", selection: Binding(
            get: { model.session.pages.first?.enhancement ?? .original },
            set: { newValue in model.session.setEnhancementAllPages(newValue) })) {
            ForEach(ScanEnhancement.allCases) { preset in
                Text(String(localized: String.LocalizationValue(preset.displayNameKey)))
                    .tag(preset)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
    }

    private var paperPicker: some View {
        Picker("Page Size", selection: $selectedPaper) {
            ForEach(PDFPaperSize.allCases) { size in
                Text(size.displayName).tag(size)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func createButton(titleKey: String,
                              action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            if model.isConvertingForUI {
                ProgressView().frame(maxWidth: .infinity)
            } else {
                Text(LocalizedStringKey(titleKey)).fontWeight(.semibold)
            }
        }
        .primaryOrangeButton()
        .disabled(model.isConvertingForUI || model.session.isEmpty)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func convert(group: ScanGroup?) async {
        model.isConvertingForUI = true
        defer { model.isConvertingForUI = false }
        do {
            let document = try await model.createPDF(for: group, paperSize: selectedPaper)
            finishCreating([document])
        } catch {
            model.isConvertingForUI = false
        }
    }

    private func saveAll() async {
        model.isConvertingForUI = true
        defer { model.isConvertingForUI = false }
        var documents: [ConvertedDocument] = []
        for group in model.session.groups {
            do {
                documents.append(try await model.createPDF(for: group, paperSize: selectedPaper))
            } catch {
                continue
            }
        }
        finishCreating(documents)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                model.cleanUp()
                onClose?()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                model.showingCamera = true
            } label: {
                Image(systemName: "plus.viewfinder")
            }
            .accessibilityLabel("Add more pages")
        }
    }
}

// MARK: - Page card with per-page controls

struct ScanPageCard: View {
    @Binding var page: ScannedPage
    var onDelete: (() -> Void)? = nil
    @State private var showingPreview = false

    var body: some View {
        VStack(spacing: 6) {
            ScanThumbnail(url: page.imageURL)
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onTapGesture { showingPreview = true }

            HStack(spacing: 10) {
                Button {
                    page.rotationQuarterTurns = (page.rotationQuarterTurns + 1) % 4
                } label: {
                    Image(systemName: "rotate.right")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("Rotate page")

                Button(role: .destructive) {
                    onDelete?()
                } label: {
                    Image(systemName: "trash")
                        .font(.footnote.weight(.semibold))
                }
                .accessibilityLabel("Delete page")
            }
            .buttonStyle(.plain)
        }
        .fullScreenCover(isPresented: $showingPreview) {
            ScanPagePreview(url: page.imageURL)
        }
    }
}

/// Downsampled thumbnail — never decodes full resolution in grid.
struct ScanThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(hex: "F2F4F7"))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "doc.viewfinder")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: url) {
            image = await ThumbnailRenderer.thumbnail(for: url, maxPixel: 300)
        }
    }
}

struct ScanPagePreview: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .padding(16)
            }
            ScrollView([.horizontal, .vertical]) {
                if let ui = UIImage(contentsOfFile: url.path) {
                    Image(uiImage: ui)
                        .resizable()
                        .scaledToFit()
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

/// Background downsampled rendering used across the scan flow.
enum ThumbnailRenderer {
    static func thumbnail(for url: URL, maxPixel: CGFloat) async -> UIImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0 else { return nil }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ] as CFDictionary
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: cg)
        }.value
    }
}
