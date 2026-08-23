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

/// Review screen: reorder, rotate, delete, enhance presets, batch groups.
struct ScanReviewView: View {
    @StateObject private var model: ScanFlowModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedPaper: PDFPaperSize = .automatic
    @State private var renamingGroupID: UUID?
    @State private var newGroupName = ""
    /// Saved documents awaiting Library persistence by HomeView.
    var onFinish: ([ConvertedDocument]) -> Void

    init(model: ScanFlowModel, onFinish: @escaping ([ConvertedDocument]) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onFinish = onFinish
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.session.groups.count > 1 && model.advancedBatchEnabled {
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
                    ScanPageCard(page: $page)
                }
                .onMove { offsets, destination in
                    model.session.move(fromOffsets: offsets, toOffset: destination)
                }
            }
            .padding(16)

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
            onFinish([document])
            dismiss()
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
        onFinish(documents)
        dismiss()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                model.cleanUp()
                dismiss()
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
                    // Deletion handled by parent through session; binding-only
                    // card cannot remove from array — expose via notification.
                    NotificationCenter.default.post(name: .scanDeletePage, object: page.id)
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

extension Notification.Name {
    static let scanDeletePage = Notification.Name("pdfit.scan.deletePage")
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
