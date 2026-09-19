import CoreGraphics
import Foundation

/// One candidate ball sighting in one frame, as reported by a `BallDetector`.
/// `center` is normalised to the frame (0…1, origin top-left). `radius` is a
/// fraction of the frame width. Several observations per frame are normal;
/// `BallTracker` decides which one, if any, is the ball.
public struct BallObservation: Sendable, Equatable {
    public var time: TimeInterval
    public var center: CGPoint
    public var radius: Double
    public var confidence: Double

    public init(time: TimeInterval, center: CGPoint, radius: Double, confidence: Double) {
        self.time = time
        self.center = center
        self.radius = radius
        self.confidence = confidence
    }
}
