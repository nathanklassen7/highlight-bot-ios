import CoreGraphics
import Foundation

/// A zoom into part of a clip's frame. The visible region keeps the frame's
/// aspect ratio and is `1 / scale` of its width and height, centred on
/// `centerX`/`centerY`. Coordinates are fractions of the oriented frame
/// (what the viewer sees, after rotation), with y pointing down.
///
/// Rendering scales that region up to fill the original frame size, so a
/// zoomed clip keeps its resolution and orientation.
public struct ClipCrop: Equatable, Sendable, Codable {
    public var scale: Double
    public var centerX: Double
    public var centerY: Double

    public init(scale: Double, centerX: Double, centerY: Double) {
        self.scale = scale
        self.centerX = centerX
        self.centerY = centerY
    }

    public static let minimumScale: Double = 1
    public static let maximumScale: Double = 4
    /// A scale within this much of 1 counts as no zoom.
    public static let identityTolerance: Double = 0.01

    public static let identity = ClipCrop(scale: 1, centerX: 0.5, centerY: 0.5)

    public var isIdentity: Bool { scale < Self.minimumScale + Self.identityTolerance }

    /// Scale inside `minimumScale...maximumScale` and the centre moved so the
    /// visible region stays inside the frame.
    public func clamped() -> ClipCrop {
        let scale = min(max(scale.isFinite ? scale : Self.minimumScale, Self.minimumScale), Self.maximumScale)
        let half = 0.5 / scale
        func fit(_ value: Double) -> Double {
            min(max(value.isFinite ? value : 0.5, half), 1 - half)
        }
        return ClipCrop(scale: scale, centerX: fit(centerX), centerY: fit(centerY))
    }

    /// The visible region in unit coordinates (the whole frame is 0...1).
    public var unitRect: CGRect {
        let crop = clamped()
        let side = 1 / crop.scale
        return CGRect(x: crop.centerX - side / 2, y: crop.centerY - side / 2, width: side, height: side)
    }

    /// The visible region in a frame of `size`.
    public func rect(in size: CGSize) -> CGRect {
        let unit = unitRect
        return CGRect(
            x: unit.minX * size.width,
            y: unit.minY * size.height,
            width: unit.width * size.width,
            height: unit.height * size.height
        )
    }

    /// Maps a frame of `size` (origin at zero) so the visible region fills it.
    public func fillTransform(for size: CGSize) -> CGAffineTransform {
        let region = rect(in: size)
        let scale = clamped().scale
        return CGAffineTransform(translationX: -region.minX, y: -region.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
    }

    /// Zooms to `newScale`, keeping the content under the anchor (a fraction
    /// of the visible region, as a pinch location on screen) in place.
    public func zoomed(to newScale: Double, anchorX: Double, anchorY: Double) -> ClipCrop {
        pinched(to: newScale, fromX: anchorX, fromY: anchorY, toX: anchorX, toY: anchorY)
    }

    /// Zooms to `newScale` and moves the content that was under `from` to
    /// sit under `to`, as a two-finger pinch that also drifts. Points are
    /// fractions of the visible region, as touch locations on screen, and may
    /// fall outside it.
    public func pinched(to newScale: Double, fromX: Double, fromY: Double, toX: Double, toY: Double) -> ClipCrop {
        let current = unitRect
        let contentX = current.minX + fromX * current.width
        let contentY = current.minY + fromY * current.height
        let scale = min(max(newScale, Self.minimumScale), Self.maximumScale)
        let side = 1 / scale
        let minX = contentX - toX * side
        let minY = contentY - toY * side
        return ClipCrop(scale: scale, centerX: minX + side / 2, centerY: minY + side / 2).clamped()
    }

    /// Pans by a drag of `dx`/`dy`, in fractions of the visible region. The
    /// region moves against the drag, so content follows the finger.
    public func panned(byX dx: Double, y dy: Double) -> ClipCrop {
        let crop = clamped()
        return ClipCrop(
            scale: crop.scale,
            centerX: crop.centerX - dx / crop.scale,
            centerY: crop.centerY - dy / crop.scale
        ).clamped()
    }
}
