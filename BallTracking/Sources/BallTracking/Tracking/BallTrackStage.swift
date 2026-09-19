import CoreGraphics
import Foundation

/// The second stage of the pipeline: turns each frame's candidates into one
/// `BallTrackFrame`. `BallTracker` (alpha-beta association) and `TrajectoryFitter`
/// (parabola RANSAC) both conform; `ClipTrackRunner` picks one per detector kind.
public protocol BallTrackStage: Sendable {
    mutating func update(time: TimeInterval, candidates: [BallObservation]) -> BallTrackFrame
    mutating func reset()
}

extension BallTracker: BallTrackStage {}
extension TrajectoryFitter: BallTrackStage {}
