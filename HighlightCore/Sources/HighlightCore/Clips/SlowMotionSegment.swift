import Foundation

/// A stretch of a clip, in source seconds, that plays back slower than real
/// time. `rate` is the playback speed (0.5 = half speed), so the segment
/// occupies `duration / rate` seconds in the finished clip.
public struct SlowMotionSegment: Equatable, Sendable, Codable {
    public var start: Double
    public var end: Double
    public var rate: Float

    public init(start: Double, end: Double, rate: Float) {
        self.start = start
        self.end = end
        self.rate = rate
    }

    /// Speeds offered for a slow-mo segment. Same options as the player's
    /// speed menu minus 100%, which would be no slow-mo at all.
    public static let rates: [Float] = [0.5, 0.25, 0.15]
    public static let defaultRate: Float = 0.5
    /// Length of a freshly inserted segment, before the user adjusts it.
    public static let defaultDuration: Double = 1.0
    /// Shortest allowed segment; the editor enforces the same floor on its handles.
    public static let minimumDuration: Double = 0.25

    public var duration: Double { max(end - start, 0) }

    /// Seconds the segment lasts once slowed.
    public var scaledDuration: Double { duration / Double(rate) }

    /// Extra seconds the slow-mo adds to the finished clip. In-place stretch
    /// replaces the segment's source duration; replay keeps the 1× pass and
    /// appends `scaledDuration`.
    public var addedDuration: Double { addedDuration(replay: false) }

    public func addedDuration(replay: Bool) -> Double {
        replay ? scaledDuration : scaledDuration - duration
    }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    /// `defaultDuration` seconds centred in `start...end` (shrunk if the range
    /// is shorter than that).
    public static func centered(in start: Double, _ end: Double, rate: Float = defaultRate) -> SlowMotionSegment {
        let length = min(defaultDuration, max(end - start, 0))
        let mid = (start + end) / 2
        return SlowMotionSegment(start: mid - length / 2, end: mid + length / 2, rate: rate)
    }

    /// Moves the segment inside `start...end`, keeping `minimumDuration` when
    /// the range allows it. Used when the trim handles move past the segment.
    public func clamped(to start: Double, _ end: Double, minimumDuration: Double = minimumDuration) -> SlowMotionSegment {
        var result = self
        let floor = min(minimumDuration, max(end - start, 0))
        result.end = min(max(result.end, start + floor), end)
        result.start = max(min(result.start, result.end - floor), start)
        return result
    }
}
