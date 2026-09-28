import Foundation

/// Keeps a camera preview visually still while the rest of the interface
/// rotates. Angles are radians; Core stays Foundation-only.
///
/// UIKit autorotation is a transform on the window. Applying the inverse of
/// the coordinator's `targetTransform` (Apple QA1890) cancels that spin so
/// only chrome moves. Do not mix that with a heading-to-radians map: the
/// landscapeLeft/Right signs disagree with UIKit's window, and overwriting
/// the animated result flips the viewfinder 180° when it lands.
public enum PreviewOrientationLock: Sendable {
    /// Extra radians QA1890 adds so a half-turn (landscapeLeft ↔ landscapeRight)
    /// animates the short way instead of a full 2π spin.
    public static let shortWayBias: Double = 0.0001

    /// Untransformed size that covers `parent` after a z-rotation of `radians`.
    /// A quarter turn swaps width and height; a half turn does not.
    public static func coveringSize(
        parentWidth: Double,
        parentHeight: Double,
        rotationRadians: Double
    ) -> (width: Double, height: Double) {
        var folded = rotationRadians.truncatingRemainder(dividingBy: .pi)
        if folded < 0 { folded += .pi }
        if abs(folded - .pi / 2) < .pi / 4 {
            return (parentHeight, parentWidth)
        }
        return (parentWidth, parentHeight)
    }

    /// Next z-rotation while animating alongside an interface-orientation
    /// change. `interfaceDelta` is `atan2(b, a)` of the coordinator's
    /// `targetTransform`.
    public static func nextAnimatedRotation(current: Double, interfaceDelta: Double) -> Double {
        guard abs(interfaceDelta) > 1e-6 else { return current }
        return current - interfaceDelta + shortWayBias
    }
}
