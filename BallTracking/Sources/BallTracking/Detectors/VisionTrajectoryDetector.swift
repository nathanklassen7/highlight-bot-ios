import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision

/// Apple Vision's trajectory detector. Reports the newest point of every
/// trajectory Vision is currently following. Vision keeps state per sequence
/// handler, so feed one instance one ordered frame stream from one task at a time.
/// `@unchecked Sendable`: mutable members are only touched inside `detect`/`reset`,
/// which callers serialise (see `BallDetector`).
public final class VisionTrajectoryDetector: BallDetector, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Points needed before Vision reports a trajectory. Minimum 5. Short ping
        /// pong flights (10–20 frames) argue for the low end.
        public var trajectoryLength: Int = 6
        /// Ball radius bounds as a fraction of the frame. A 40 mm ball 3–5 m away
        /// at 1080p is roughly 0.003–0.007.
        public var minimumNormalizedRadius: Float = 0.002
        public var maximumNormalizedRadius: Float = 0.03
        /// Frame period; used as Vision's real-time budget hint and the sample duration.
        public var frameDuration: CMTime = CMTime(value: 1, timescale: 60)

        public init() {}
        public init(trajectoryLength: Int, minimumNormalizedRadius: Float, maximumNormalizedRadius: Float, frameDuration: CMTime) {
            self.trajectoryLength = trajectoryLength
            self.minimumNormalizedRadius = minimumNormalizedRadius
            self.maximumNormalizedRadius = maximumNormalizedRadius
            self.frameDuration = frameDuration
        }
        public static let `default` = Config()
    }

    public let name = "vision-trajectory"
    private let config: Config
    private var handler = VNSequenceRequestHandler()
    private var request: VNDetectTrajectoriesRequest

    public init(config: Config = .default) {
        self.config = config
        request = Self.makeRequest(config: config)
    }

    public func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation] {
        let sample = try SampleBufferFactory.make(pixelBuffer: pixelBuffer, time: time, duration: config.frameDuration)
        try handler.perform([request], on: sample, orientation: .up)
        guard let results = request.results else { return [] }
        let seconds = time.seconds
        return results.compactMap { trajectory in
            guard let last = trajectory.detectedPoints.last else { return nil }
            // Vision uses a bottom-left origin; we use top-left.
            return BallObservation(time: seconds,
                                   center: CGPoint(x: last.x, y: 1 - last.y),
                                   radius: Double(trajectory.movingAverageRadius),
                                   confidence: Double(trajectory.confidence))
        }
    }

    public func reset() {
        handler = VNSequenceRequestHandler()
        request = Self.makeRequest(config: config)
    }

    private static func makeRequest(config: Config) -> VNDetectTrajectoriesRequest {
        let request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                                  trajectoryLength: max(5, config.trajectoryLength),
                                                  completionHandler: nil)
        request.objectMinimumNormalizedRadius = config.minimumNormalizedRadius
        request.objectMaximumNormalizedRadius = config.maximumNormalizedRadius
        request.targetFrameTime = config.frameDuration
        return request
    }
}
