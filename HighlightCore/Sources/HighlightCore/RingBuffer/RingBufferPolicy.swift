import Foundation

/// How much footage the ring buffer keeps for the current session.
public struct RingBufferPolicy: Sendable, Equatable {
    /// Seconds of media that must remain after eviction.
    public var retainSeconds: TimeInterval

    public init(retainSeconds: TimeInterval) {
        self.retainSeconds = retainSeconds
    }

    /// Uses `config.retainSeconds` (`bufferSeconds + segmentInterval`).
    public init(config: RecordingConfig) {
        self.init(retainSeconds: config.retainSeconds)
    }
}
