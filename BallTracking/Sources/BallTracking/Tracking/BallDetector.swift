import CoreMedia
import CoreVideo

/// Finds ball-like objects in one frame. Implementations may keep state across
/// frames (previous frame, Vision sequence handler), so a detector must only be
/// fed consecutive frames from one source, in order, from one task at a time.
public protocol BallDetector: AnyObject, Sendable {
    var name: String { get }
    /// `time` is the frame's presentation time. Returns zero or more candidates.
    func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation]
    /// Forget cross-frame state (source restarted, seek, loop).
    func reset()
}
