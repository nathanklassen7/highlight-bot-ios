import Foundation

/// The segments that make up one clip: the session's initialization segment
/// followed by a contiguous run of media segments. The app concatenates
/// `urls` in order and passthrough-exports the result.
public struct ClipPlan: Sendable, Equatable {
    public let sessionID: SessionID
    public let initializationSegment: Segment
    /// Ascending `seq`, contiguous.
    public let mediaSegments: [Segment]

    public init(sessionID: SessionID, initializationSegment: Segment, mediaSegments: [Segment]) {
        self.sessionID = sessionID
        self.initializationSegment = initializationSegment
        self.mediaSegments = mediaSegments
    }

    /// Sum of media durations, in seconds.
    public var duration: TimeInterval {
        mediaSegments.reduce(0) { $0 + $1.duration }
    }

    /// Total bytes across the initialization segment and all media segments.
    public var byteCount: Int {
        mediaSegments.reduce(initializationSegment.byteCount) { $0 + $1.byteCount }
    }

    /// `[init] + media`, in concatenation order.
    public var urls: [URL] {
        [initializationSegment.url] + mediaSegments.map(\.url)
    }
}
