import CoreGraphics
import Foundation

/// A complete analysis of one video: one `BallTrackFrame` per decoded frame, in
/// display orientation. Persisted as JSON next to the clip.
public struct BallTrack: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var detector: String
    public var frameRate: Double
    /// Pixel size of the displayed frame (after `preferredTransform`).
    public var displaySize: CGSize
    /// Sorted by `time`.
    public var frames: [BallTrackFrame]

    public init(version: Int, detector: String, frameRate: Double, displaySize: CGSize, frames: [BallTrackFrame]) {
        self.version = version
        self.detector = detector
        self.frameRate = frameRate
        self.displaySize = displaySize
        self.frames = frames
    }

    /// Index of the frame whose time is closest to `time`, or nil when empty.
    public func index(nearest time: TimeInterval) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time < time { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(frames[low - 1].time - time) < abs(frames[low].time - time) {
            return low - 1
        }
        return low
    }

    /// Nearest frame within 1.5 frame periods of `time`.
    public func frame(at time: TimeInterval) -> BallTrackFrame? {
        guard let i = index(nearest: time) else { return nil }
        let tolerance = 1.5 / max(frameRate, 1)
        return abs(frames[i].time - time) <= tolerance ? frames[i] : nil
    }

    /// Tracking positions from `time - duration` up to `time`, oldest first,
    /// stopping at the most recent `.searching` frame so a trail never spans a lost ball.
    public func trail(endingAt time: TimeInterval, duration: TimeInterval) -> [CGPoint] {
        guard let end = index(nearest: time) else { return [] }
        var points: [CGPoint] = []
        var i = end
        while i >= 0, time - frames[i].time <= duration {
            let frame = frames[i]
            if frame.state == .searching { break }
            if frame.state == .tracking, let position = frame.position {
                points.append(position)
            }
            i -= 1
        }
        points.reverse()
        return points
    }

    public var trackingFraction: Double {
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter { $0.state == .tracking }.count) / Double(frames.count)
    }
}
