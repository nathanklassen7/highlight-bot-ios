import CoreMedia
import Foundation

/// The detectors the app and lab can choose between.
public enum BallDetectorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case vision
    case luma

    public var id: String { rawValue }

    /// Detector used when nothing else is specified. Set by the lab evaluation
    /// (plan Task 8) after comparing both on real footage.
    public static let `default`: BallDetectorKind = .vision

    public var displayName: String {
        switch self {
        case .vision: "Vision trajectories"
        case .luma: "Luma blobs"
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
        }
    }
}
