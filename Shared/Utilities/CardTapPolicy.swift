import Foundation
import CoreGraphics

/// Pure hit-testing policy for the share extension's background-tap
/// cancellation: a touch may cancel/dismiss ONLY when it lands outside the
/// card. The gesture recognizer's delegate calls this, so unit tests of this
/// function cover the shipped behavior — taps on Create PDF / Share / Done /
/// Retry / segmented controls can never trigger background cancellation.
enum CardTapPolicy {
    /// - Parameters:
    ///   - locationInCard: touch location in the card view's coordinate space.
    ///   - cardBounds: the card view's bounds.
    /// - Returns: `true` when the flow should cancel (tap outside the card).
    static func cancels(locationInCard: CGPoint, cardBounds: CGRect) -> Bool {
        !cardBounds.contains(locationInCard)
    }
}
