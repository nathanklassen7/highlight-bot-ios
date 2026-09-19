import CoreGraphics
import Foundation

public enum OverlayGravity: Sendable, Equatable {
    /// Letterbox: the whole frame is visible (`AVLayerVideoGravity.resizeAspect`).
    case aspectFit
    /// Crop: the frame fills the view (`AVLayerVideoGravity.resizeAspectFill`).
    case aspectFill
}

/// Maps normalised frame coordinates to points in a view that shows the frame.
public struct OverlayGeometry: Sendable, Equatable {
    /// Where the (rotated) frame sits in the view. Can exceed the view for aspect-fill.
    public let videoRect: CGRect
    /// Clockwise rotation applied to the stored frame for display; 0 when the
    /// coordinates are already display-oriented (saved clips).
    public let rotationDegrees: Int

    /// For coordinates that are already display-oriented and a known video rect
    /// (e.g. `AVMakeRect(aspectRatio:insideRect:)` for a player).
    public init(videoRect: CGRect) {
        self.videoRect = videoRect
        rotationDegrees = 0
    }

    /// For stored-orientation frames shown by a preview layer with `gravity` in
    /// `bounds`, rotated `rotationDegrees` clockwise (0/90/180/270).
    public init(imageSize: CGSize, bounds: CGRect, gravity: OverlayGravity, rotationDegrees: Int) {
        let degrees = ((rotationDegrees % 360) + 360) % 360
        let transposed = degrees == 90 || degrees == 270
        let rotatedSize = transposed ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        videoRect = Self.fit(rotatedSize, in: bounds, gravity: gravity)
        self.rotationDegrees = degrees
    }

    public func point(forNormalized p: CGPoint) -> CGPoint {
        let r = FrameOrientation.rotate(p, clockwiseDegrees: rotationDegrees)
        return CGPoint(x: videoRect.minX + r.x * videoRect.width,
                       y: videoRect.minY + r.y * videoRect.height)
    }

    /// Converts a length given as a fraction of the stored frame's width.
    public func length(forNormalizedWidthFraction r: Double) -> CGFloat {
        let transposed = rotationDegrees == 90 || rotationDegrees == 270
        return CGFloat(r) * (transposed ? videoRect.height : videoRect.width)
    }

    static func fit(_ size: CGSize, in bounds: CGRect, gravity: OverlayGravity) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let sx = bounds.width / size.width
        let sy = bounds.height / size.height
        let scale = gravity == .aspectFit ? min(sx, sy) : max(sx, sy)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}
