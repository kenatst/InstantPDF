import SwiftUI
import PDFKit

/// Interactive placement surface: renders the chosen page and lets the user
/// DRAG the signature anywhere on it. The normalized center coordinates are
/// written straight into the host's placement state — what you see is EXACTLY
/// what gets stamped into the PDF.
struct SignaturePlacementCanvas: View {
    let recordID: UUID
    let pageNumber: Int
    let signature: UIImage
    @Binding var normalizedX: CGFloat
    @Binding var normalizedY: CGFloat
    @Binding var scale: CGFloat

    @State private var pageSize: CGSize = CGSize(width: 612, height: 792)
    @State private var pageImage: UIImage?

    /// Signature display width as a fraction of the page preview width.
    private var relativeWidth: CGFloat { 0.32 * scale }

    var body: some View {
        GeometryReader { geo in
            let canvasSize = geo.size
            // Fit the page inside the canvas preserving aspect.
            let pageAspect = pageSize.width / max(pageSize.height, 1)
            let drawHeight = min(canvasSize.height, canvasSize.width / pageAspect)
            let drawWidth = drawHeight * pageAspect
            let origin = CGPoint(x: (canvasSize.width - drawWidth) / 2,
                                 y: (canvasSize.height - drawHeight) / 2)

            ZStack(alignment: .topLeading) {
                if let pageImage {
                    Image(uiImage: pageImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: drawWidth, height: drawHeight)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: drawWidth, height: drawHeight)
                }

                // The draggable signature, centered on (normalizedX, Y).
                Image(uiImage: signature)
                    .resizable()
                    .scaledToFit()
                    .frame(width: drawWidth * relativeWidth)
                    .position(x: origin.x + normalizedX * drawWidth,
                              y: origin.y + normalizedY * drawHeight)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let x = origin.x + value.location.x
                                let y = origin.y + value.location.y
                                normalizedX = min(1, max(0, x / max(drawWidth, 1)))
                                normalizedY = min(1, max(0, y / max(drawHeight, 1)))
                            }
                    )
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(Color.secondary.opacity(0.06))
        }
        .task(id: pageNumber) {
            loadPage()
        }
        .onAppear { loadPage() }
    }

    private func loadPage() {
        guard let record = StorageManager.shared.record(withID: recordID),
              let url = StorageManager.shared.fileURL(for: record),
              let document = PDFDocument(url: url),
              let page = document.page(at: max(0, pageNumber - 1)) else { return }
        let bounds = page.bounds(for: .mediaBox)
        pageSize = bounds.size
        pageImage = page.thumbnail(of: CGSize(width: bounds.width * 2,
                                              height: bounds.height * 2),
                                   for: .mediaBox)
    }
}
