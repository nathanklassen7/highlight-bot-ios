import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public struct ClipTrackProgress: Sendable, Equatable {
    public var framesDone: Int
    public var estimatedTotal: Int
    public var fraction: Double
}

public struct ClipTrackResult: Sendable {
    public var track: BallTrack
    public var meanDetectMillis: Double
    public var p95DetectMillis: Double
    public var wallSeconds: Double
    public var detectErrors: Int
}

public enum ClipTrackError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case readerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The video has no video track."
        case .readerFailed(let message): "Could not read the video: \(message)"
        case .cancelled: "Analysis was cancelled."
        }
    }
}

/// Decodes a movie file frame by frame and runs a detector plus `BallTracker`
/// over it. Used by the app for saved clips and by `balltrack-lab`.
public struct ClipTrackRunner: Sendable {
    public let detectorName: String
    private let trackerConfig: BallTrackerConfig
    private let makeDetector: @Sendable (CMTime) -> any BallDetector

    public init(detectorKind: BallDetectorKind = .default, trackerConfig: BallTrackerConfig = .default) {
        self.init(detectorName: detectorKind.rawValue, trackerConfig: trackerConfig) { frameDuration in
            detectorKind.makeDetector(frameDuration: frameDuration)
        }
    }

    public init(detectorName: String,
                trackerConfig: BallTrackerConfig = .default,
                makeDetector: @escaping @Sendable (CMTime) -> any BallDetector) {
        self.detectorName = detectorName
        self.trackerConfig = trackerConfig
        self.makeDetector = makeDetector
    }

    /// Blocks a background queue for the whole decode; call from a detached task.
    /// `progress` fires roughly every 10 frames and once at the end.
    public func run(url: URL,
                    progress: (@Sendable (ClipTrackProgress) -> Void)? = nil,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> ClipTrackResult {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipTrackError.noVideoTrack
        }
        let (naturalSize, transform, nominalFrameRate, minFrameDuration) =
            try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration)
        let duration = try await asset.load(.duration)

        let frameDuration = (minFrameDuration.isNumeric && minFrameDuration.seconds > 0)
            ? minFrameDuration : CMTime(value: 1, timescale: 60)
        let frameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : 1 / frameDuration.seconds
        let estimatedTotal = max(1, Int((duration.seconds * frameRate).rounded()))
        let orientation = FrameOrientation(storedSize: naturalSize, transform: transform)

        // `AVURLAsset` is Sendable in the SDK; `AVAssetTrack` is not, but it is safe to
        // hand to one other queue for reading. The compiler cannot prove that.
        let assetRef = asset
        nonisolated(unsafe) let trackRef = videoTrack
        let detectorName = self.detectorName
        let trackerConfig = self.trackerConfig
        let makeDetector = self.makeDetector

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.process(asset: assetRef, videoTrack: trackRef,
                                                  detectorName: detectorName,
                                                  detector: makeDetector(frameDuration),
                                                  trackerConfig: trackerConfig,
                                                  orientation: orientation,
                                                  frameRate: frameRate,
                                                  estimatedTotal: estimatedTotal,
                                                  progress: progress,
                                                  isCancelled: isCancelled)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func process(asset: AVURLAsset,
                                videoTrack: AVAssetTrack,
                                detectorName: String,
                                detector: any BallDetector,
                                trackerConfig: BallTrackerConfig,
                                orientation: FrameOrientation,
                                frameRate: Double,
                                estimatedTotal: Int,
                                progress: (@Sendable (ClipTrackProgress) -> Void)?,
                                isCancelled: @Sendable () -> Bool) throws -> ClipTrackResult {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipTrackError.readerFailed("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipTrackError.readerFailed(reader.error?.localizedDescription ?? "startReading returned false")
        }

        var tracker = BallTracker(config: trackerConfig)
        var frames: [BallTrackFrame] = []
        frames.reserveCapacity(estimatedTotal)
        var detectMillis: [Double] = []
        detectMillis.reserveCapacity(estimatedTotal)
        var detectErrors = 0
        let wallStart = ContinuousClock.now

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw ClipTrackError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            let detectStart = ContinuousClock.now
            var candidates: [BallObservation] = []
            do {
                candidates = try detector.detect(pixelBuffer: pixelBuffer, time: pts)
            } catch {
                detectErrors += 1
            }
            detectMillis.append((ContinuousClock.now - detectStart).millis)

            let frame = tracker.update(time: pts.seconds, candidates: candidates)
            frames.append(orientation.apply(to: frame))

            if frames.count % 10 == 0 {
                let fraction = min(0.99, Double(frames.count) / Double(estimatedTotal))
                progress?(ClipTrackProgress(framesDone: frames.count, estimatedTotal: estimatedTotal, fraction: fraction))
            }
        }
        if reader.status == .failed {
            throw ClipTrackError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        progress?(ClipTrackProgress(framesDone: frames.count, estimatedTotal: frames.count, fraction: 1.0))

        let sorted = detectMillis.sorted()
        let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

        let track = BallTrack(version: BallTrack.currentVersion,
                              detector: detectorName,
                              frameRate: frameRate,
                              displaySize: orientation.displaySize,
                              frames: frames)
        return ClipTrackResult(track: track,
                               meanDetectMillis: mean,
                               p95DetectMillis: p95,
                               wallSeconds: (ContinuousClock.now - wallStart).seconds,
                               detectErrors: detectErrors)
    }
}

extension Duration {
    var millis: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
