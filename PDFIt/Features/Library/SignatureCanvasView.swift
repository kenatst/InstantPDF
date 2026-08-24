import SwiftUI
import PencilKit

/// Local-only signature storage inside the app's support directory.
/// One reusable default signature, saved as a transparent PNG. Never
/// uploaded, never logged; deleting removes the persisted bytes.
final class SignatureStore: ObservableObject {
    static let shared = SignatureStore()

    @Published private(set) var savedImage: UIImage?

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Signatures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("signature.png")
    }

    private init() {
        reload()
    }

    func reload() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let image = UIImage(contentsOfFile: fileURL.path) else {
            savedImage = nil
            return
        }
        savedImage = image
    }

    /// Persists the trimmed transparent PNG. Returns false on write failure.
    @discardableResult
    func save(_ image: UIImage) -> Bool {
        guard let png = image.pngData() else { return false }
        do {
            try png.write(to: fileURL, options: [.atomic])
            savedImage = image
            return true
        } catch {
            return false
        }
    }

    /// Removes the persisted signature bytes entirely.
    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
        savedImage = nil
    }
}

/// Real iOS drawing surface: PKCanvasView with finger drawing enabled,
/// Apple Pencil supported, no gesture arbitration issues. Ink is rendered
/// to a transparent PNG trimmed to the drawn bounds on Done.
struct SignatureCanvasView: View {
    @Environment(\.dismiss) private var dismiss
    var onDone: (UIImage) -> Void

    @StateObject private var store = SignatureStore.shared
    @State private var hasInk = false
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Sign below with your finger or Apple Pencil.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                PencilKitCanvas(hasInk: $hasInk)
                    .frame(height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.35),
                                          style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    )
                    .padding(.horizontal, 20)

                HStack(spacing: 14) {
                    Button("Clear") {
                        PencilKitCanvas.clearInk()
                        hasInk = false
                    }
                        .secondaryDarkButton()
                    Button("Done") { finish() }
                        .primaryOrangeButton()
                        .disabled(!hasInk)
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
            .alert("Save failed", isPresented: $saveFailed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("The signature couldn't be saved on this device.")
            }
        }
    }

    private func finish() {
        PencilKitCanvas.exportInk { image in
            guard let inkTrimmed = image?.trimmedToInk(),
                  store.save(inkTrimmed) else {
                saveFailed = true
                return
            }
            onDone(inkTrimmed)
            dismiss()
        }
    }
}

#if DEBUG
extension SignatureCanvasView {
    static func _previewDone(_ action: @escaping (UIImage) -> Void) -> SignatureCanvasView {
        SignatureCanvasView(onDone: action)
    }
}
#endif

/// UIViewRepresentable wrapping PKCanvasView. Drawing state and ink export
/// live at this boundary so SwiftUI never arbitrates stroke gestures.
struct PencilKitCanvas: UIViewRepresentable {
    @Binding var hasInk: Bool

    /// Shared backing store for the active drawing session (one canvas is
    /// alive at a time; the sheet owns its lifetime).
    private static let box = InkBox()

    final class InkBox {
        weak var view: PKCanvasView?
    }

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .systemBackground
        canvas.drawingPolicy = .anyInput // finger AND Apple Pencil
        canvas.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvas.delegate = CanvasDelegate.shared
        canvas.overrideUserInterfaceStyle = .light
        Self.box.view = canvas
        CanvasDelegate.shared.onInkChange = { [weak canvas] strokes in
            _ = canvas
            Task { @MainActor in
                if self.hasInk != !strokes.isEmpty {
                    self.hasInk = !strokes.isEmpty
                }
            }
        }
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {}

    static func clearInk() {
        box.view?.drawing = PKDrawing()
    }

    /// Renders the current drawing to a transparent PNG at 2x scale.
    static func exportInk(completion: @escaping (UIImage?) -> Void) {
        guard let canvas = box.view else {
            completion(nil)
            return
        }
        let drawing = canvas.drawing
        guard !drawing.bounds.isEmpty else {
            completion(nil)
            return
        }
        let image = drawing.image(from: drawing.bounds, scale: 2)
        completion(image)
    }
}

/// Forwards stroke-count changes out of PKCanvasView without retain cycles.
final class CanvasDelegate: NSObject, PKCanvasViewDelegate {
    static let shared = CanvasDelegate()
    var onInkChange: (([PKStroke]) -> Void)?

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        onInkChange?(canvasView.drawing.strokes)
    }
}

extension UIImage {
    /// Crops fully-transparent margins so signature placement scales
    /// predictably. Returns nil when the canvas has no ink at all.
    func trimmedToInk() -> UIImage? {
        guard let cgImage = self.cgImage else { return nil }
        // Convert to a known RGBA byte layout for safe pixel scanning.
        guard let context = CGContext(data: nil,
                                      width: cgImage.width,
                                      height: cgImage.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return self }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        let width = cgImage.width
        let height = cgImage.height
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var minX = width, minY = height, maxX = 0, maxY = 0
        for y in 0..<height {
            for x in 0..<width {
                let alpha = bytes[(y * width + x) * 4 + 3]
                if alpha > 8 {
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil } // no ink at all
        let inset = 4
        let cx0 = max(0, minX - inset), cy0 = max(0, minY - inset)
        let cx1 = min(width - 1, maxX + inset), cy1 = min(height - 1, maxY + inset)
        let cropRect = CGRect(x: cx0, y: cy0,
                              width: cx1 - cx0 + 1, height: cy1 - cy0 + 1)
        guard let cropped = context.makeImage()?.cropping(to: cropRect) else { return self }
        return UIImage(cgImage: cropped)
    }
}
