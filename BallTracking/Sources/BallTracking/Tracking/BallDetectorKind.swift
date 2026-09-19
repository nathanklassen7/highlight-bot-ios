import CoreGraphics
import CoreMedia
import Foundation

/// The detectors the app and lab can choose between.
public enum BallDetectorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case vision
    case luma
    /// Motion-mask candidates + `TrajectoryFitter` (parabola RANSAC).
    case motion

    public var id: String { rawValue }

    /// Detector used when nothing else is specified. The lab evaluation on real
    /// footage (docs/superpowers/specs/2026-09-18-ball-tracking-lab-results.md)
    /// found Vision does not detect a ball this small; the luma detector does.
    public static let `default`: BallDetectorKind = .luma

    public var displayName: String {
        switch self {
        case .vision: "Vision trajectories"
        case .luma: "Luma blobs"
        case .motion: "Motion + trajectory"
        }
    }

    public func makeDetector(frameDuration: CMTime) -> any BallDetector {
        switch self {
        case .vision:
            var config = VisionTrajectoryDetector.Config()
            config.frameDuration = frameDuration
            return VisionTrajectoryDetector(config: config)
        case .luma:
            return LumaBlobDetector()
        case .motion:
            return MotionCandidateDetector()
        }
    }

    /// The stage that turns this detector's candidates into track frames.
    /// `imageSize` is the stored frame in pixels; the fitter's thresholds are physical.
    public func makeTrackStage(imageSize: CGSize, trackerConfig: BallTrackerConfig = .default) -> any BallTrackStage {
        switch self {
        case .vision, .luma:
            return BallTracker(config: trackerConfig)
        case .motion:
            return TrajectoryFitter(imageSize: imageSize)
        }
    }
}
