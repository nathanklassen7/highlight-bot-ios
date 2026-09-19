import CoreGraphics
import Foundation

/// Maps stored-frame coordinates to display coordinates for a video track with a
/// `preferredTransform`. Detectors see the stored frame; overlays see the displayed
/// one. Everything stays normalised (0…1, origin top-left).
public struct FrameOrientation: Sendable, Equatable {
    public let storedSize: CGSize
    public let transform: CGAffineTransform
    public let displaySize: CGSize
    private let displayOrigin: CGPoint

    public init(storedSize: CGSize, transform: CGAffineTransform) {
        self.storedSize = storedSize
        self.transform = transform
        let rect = CGRect(origin: .zero, size: storedSize).applying(transform)
        displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
        displayOrigin = rect.origin
    }

    public func normalizedPoint(_ p: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: p.x * storedSize.width, y: p.y * storedSize.height).applying(transform)
        return CGPoint(x: (pixel.x - displayOrigin.x) / displaySize.width,
                       y: (pixel.y - displayOrigin.y) / displaySize.height)
    }

    public func normalizedVector(_ v: CGVector) -> CGVector {
        let dx = v.dx * storedSize.width
        let dy = v.dy * storedSize.height
        let rx = dx * transform.a + dy * transform.c
        let ry = dx * transform.b + dy * transform.d
        return CGVector(dx: rx / displaySize.width, dy: ry / displaySize.height)
    }

    public func normalizedRadius(_ r: Double) -> Double {
        r * storedSize.width / displaySize.width
    }

    public func apply(to frame: BallTrackFrame) -> BallTrackFrame {
        var mapped = frame
        mapped.position = frame.position.map(normalizedPoint)
        mapped.velocity = frame.velocity.map(normalizedVector)
        mapped.radius = frame.radius.map(normalizedRadius)
        return mapped
    }

    /// Rotates a normalised top-left-origin point by a multiple of 90° clockwise,
    /// i.e. the way the displayed image is rotated relative to the stored one.
    public static func rotate(_ p: CGPoint, clockwiseDegrees: Int) -> CGPoint {
        switch ((clockwiseDegrees % 360) + 360) % 360 {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }
}
