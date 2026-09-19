import CoreGraphics
import Foundation

/// Lifecycle of the single track `BallTracker` maintains.
public enum BallTrackState: String, Codable, Sendable {
    /// No ball. Waiting for a candidate to start a tentative track.
    case searching
    /// A candidate was accepted but not yet confirmed by consecutive matches.
    case tentative
    /// Confirmed and matched this frame.
    case tracking
    /// Confirmed, but no candidate matched this frame; position is predicted.
    case coasting
}

/// The tracker's output for one video frame. Positions are normalised to the
/// displayed frame (0…1, origin top-left); velocity is in normalised units per second.
public struct BallTrackFrame: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var state: BallTrackState
    public var position: CGPoint?
    public var velocity: CGVector?
    public var radius: Double?
    public var candidateCount: Int

    public init(time: TimeInterval,
                state: BallTrackState,
                position: CGPoint?,
                velocity: CGVector?,
                radius: Double?,
                candidateCount: Int) {
        self.time = time
        self.state = state
        self.position = position
        self.velocity = velocity
        self.radius = radius
        self.candidateCount = candidateCount
    }

    /// True when an overlay should draw the ball for this frame.
    public var isVisible: Bool {
        state == .tracking || state == .coasting
    }
}
