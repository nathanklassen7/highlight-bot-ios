import Foundation

/// The two kinds of fMP4 segment a segmented `AVAssetWriter` produces.
public enum SegmentKind: String, Sendable, Codable {
    /// The `ftyp`/`moov` header. Exactly one per session, always `seq == 0`.
    case initialization
    /// A `moof`/`mdat` fragment holding a few seconds of footage.
    case media

    /// File extension used when the segment is written to disk.
    public var fileExtension: String {
        switch self {
        case .initialization: "init"
        case .media: "m4s"
        }
    }
}

/// A segment as produced by the recorder, before it hits disk.
public struct IncomingSegment: Sendable, Equatable {
    public let sessionID: SessionID
    /// 0 for the initialization segment, then 1, 2, 3 … per session.
    public let seq: Int
    public let kind: SegmentKind
    public let data: Data
    /// Seconds since session start; 0 for the initialization segment.
    public let startTime: TimeInterval
    /// Duration in seconds; 0 for the initialization segment.
    public let duration: TimeInterval

    public init(
        sessionID: SessionID,
        seq: Int,
        kind: SegmentKind,
        data: Data,
        startTime: TimeInterval,
        duration: TimeInterval
    ) {
        self.sessionID = sessionID
        self.seq = seq
        self.kind = kind
        self.data = data
        self.startTime = startTime
        self.duration = duration
    }
}

/// A segment persisted by the ring buffer. Only the index lives in memory;
/// the bytes are behind `url`.
public struct Segment: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(sessionID.rawValue.uuidString)/\(seq)" }
    public let sessionID: SessionID
    public let seq: Int
    public let kind: SegmentKind
    public let url: URL
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let byteCount: Int

    public init(
        sessionID: SessionID,
        seq: Int,
        kind: SegmentKind,
        url: URL,
        startTime: TimeInterval,
        duration: TimeInterval,
        byteCount: Int
    ) {
        self.sessionID = sessionID
        self.seq = seq
        self.kind = kind
        self.url = url
        self.startTime = startTime
        self.duration = duration
        self.byteCount = byteCount
    }
}
