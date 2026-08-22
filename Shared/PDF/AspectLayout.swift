import Foundation
import CoreGraphics

/// Pure aspect-ratio math shared by the image converter. No I/O — unit tested.
enum AspectLayout {

    /// Rect that fits (or fills) `bounds` while preserving the given aspect
    /// ratio. `fill` returns a rect larger than `bounds`; the caller clips.
    static func rect(aspectRatio: CGSize, inRect bounds: CGRect, mode: ImageLayout) -> CGRect {
        guard aspectRatio.width > 0, aspectRatio.height > 0, bounds.width > 0, bounds.height > 0 else {
            return bounds
        }

        let horizontalScale = bounds.width / aspectRatio.width
        let verticalScale = bounds.height / aspectRatio.height
        let scale: CGFloat
        switch mode {
        case .fit: scale = min(horizontalScale, verticalScale)
        case .fill: scale = max(horizontalScale, verticalScale)
        }

        let size = CGSize(width: aspectRatio.width * scale,
                          height: aspectRatio.height * scale)
        let origin = CGPoint(x: bounds.midX - size.width / 2,
                             y: bounds.midY - size.height / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Scales `content` down so it fits inside `limit`, keeping aspect.
    static func fittedSize(_ content: CGSize, limitingTo limit: CGSize) -> CGSize {
        guard content.width > 0, content.height > 0 else { return content }
        let scale = min(1, limit.width / content.width, limit.height / content.height)
        return CGSize(width: content.width * scale, height: content.height * scale)
    }
}
