import Foundation

/// Errors thrown by `SegmentRingBuffer.append`.
public enum RingBufferError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A media segment arrived for a session that is not the current one.
    /// Media can only follow the initialization segment of its own session.
    case sessionNotCurrent(SessionID, current: SessionID?)
    /// A segment with this `(sessionID, seq)` is already retained.
    case duplicateSegment(SessionID, seq: Int)

    public var description: String {
        switch self {
        case let .sessionNotCurrent(sessionID, current):
            "Media segment for session \(sessionID) rejected; current session is \(current?.description ?? "none")."
        case let .duplicateSegment(sessionID, seq):
            "Segment \(seq) of session \(sessionID) is already in the ring buffer."
        }
    }
}

/// Disk-backed rolling buffer of fMP4 segments with an in-memory index.
///
/// Only one session is ever retained. A new session's initialization segment
/// makes that session current and evicts every segment of the previous one.
/// After each append the oldest media segments of the current session are
/// evicted while at least `policy.retainSeconds` of footage would remain.
public actor SegmentRingBuffer {
    public private(set) var policy: RingBufferPolicy
    private let storage: any SegmentStorage
    /// Retained segments ordered by `(sessionID, seq)`. In practice all belong
    /// to `currentSessionID`.
    private var index: [Segment] = []
    public private(set) var currentSessionID: SessionID?

    public init(policy: RingBufferPolicy, storage: any SegmentStorage) {
        self.policy = policy
        self.storage = storage
    }

    /// Replaces the eviction policy. Takes effect on the next `append`.
    public func updatePolicy(_ policy: RingBufferPolicy) {
        self.policy = policy
    }

    /// All retained segments, ordered by `(session, seq)`.
    public var segments: [Segment] { index }

    /// Total media duration retained for the current session, in seconds.
    public var bufferedSeconds: TimeInterval {
        currentMedia.reduce(0) { $0 + $1.duration }
    }

    /// Persists the segment, updates the index and evicts.
    ///
    /// - An `.initialization` segment for a new session makes that session
    ///   current and evicts all segments of any other session.
    /// - A `.media` segment for a session other than the current one throws
    ///   `RingBufferError.sessionNotCurrent`.
    /// - A segment whose `(sessionID, seq)` is already retained throws
    ///   `RingBufferError.duplicateSegment`.
    ///
    /// Storage deletes run synchronously inside this call. If a delete fails
    /// after the incoming segment was persisted, the index has already been
    /// updated (the segment is retained and evicted entries are gone from the
    /// index); only the storage error is surfaced.
    @discardableResult
    public func append(_ incoming: IncomingSegment) throws -> Segment {
        switch incoming.kind {
        case .initialization:
            return try appendInitialization(incoming)
        case .media:
            return try appendMedia(incoming)
        }
    }

    /// Whole-segment plan covering at least `lastSeconds` of the current
    /// session, or nil if there is no initialization segment or no media.
    public func snapshot(lastSeconds: TimeInterval) -> ClipPlan? {
        guard let sessionID = currentSessionID else { return nil }
        return ClipAssembler.plan(segments: index, sessionID: sessionID, lastSeconds: lastSeconds)
    }

    /// Drops every segment and deletes everything from storage, including any
    /// orphaned files from sessions no longer in the index.
    public func clear() throws {
        index.removeAll()
        currentSessionID = nil
        try storage.deleteEverything()
    }

    // MARK: - Private

    private var currentMedia: [Segment] {
        guard let sessionID = currentSessionID else { return [] }
        return index.filter { $0.sessionID == sessionID && $0.kind == .media }
    }

    private func appendInitialization(_ incoming: IncomingSegment) throws -> Segment {
        let previousSessionID = currentSessionID
        let isNewSession = previousSessionID != incoming.sessionID

        if !isNewSession, contains(sessionID: incoming.sessionID, seq: incoming.seq) {
            throw RingBufferError.duplicateSegment(incoming.sessionID, seq: incoming.seq)
        }

        let segment = try persist(incoming)

        if isNewSession {
            index.removeAll()
            currentSessionID = incoming.sessionID
        }
        insertSorted(segment)

        if isNewSession, let previousSessionID {
            try storage.deleteAll(for: previousSessionID)
        }
        try evict()
        return segment
    }

    private func appendMedia(_ incoming: IncomingSegment) throws -> Segment {
        guard let current = currentSessionID, current == incoming.sessionID else {
            throw RingBufferError.sessionNotCurrent(incoming.sessionID, current: currentSessionID)
        }
        if contains(sessionID: incoming.sessionID, seq: incoming.seq) {
            throw RingBufferError.duplicateSegment(incoming.sessionID, seq: incoming.seq)
        }

        let segment = try persist(incoming)
        insertSorted(segment)
        try evict()
        return segment
    }

    private func persist(_ incoming: IncomingSegment) throws -> Segment {
        let url = try storage.write(
            incoming.data,
            sessionID: incoming.sessionID,
            seq: incoming.seq,
            kind: incoming.kind
        )
        return Segment(
            sessionID: incoming.sessionID,
            seq: incoming.seq,
            kind: incoming.kind,
            url: url,
            startTime: incoming.startTime,
            duration: incoming.duration,
            byteCount: incoming.data.count
        )
    }

    private func contains(sessionID: SessionID, seq: Int) -> Bool {
        index.contains { $0.sessionID == sessionID && $0.seq == seq }
    }

    private func insertSorted(_ segment: Segment) {
        let position = index.firstIndex { existing in
            if existing.sessionID != segment.sessionID {
                return existing.sessionID.rawValue.uuidString > segment.sessionID.rawValue.uuidString
            }
            return existing.seq > segment.seq
        }
        index.insert(segment, at: position ?? index.endIndex)
    }

    /// Drops the oldest current-session media while the remaining footage
    /// would still be at least `policy.retainSeconds`. Never touches the
    /// initialization segment.
    private func evict() throws {
        var media = currentMedia
        var total = media.reduce(0) { $0 + $1.duration }
        var firstError: (any Error)?

        while let oldest = media.first, total - oldest.duration >= policy.retainSeconds {
            media.removeFirst()
            total -= oldest.duration
            index.removeAll { $0 == oldest }
            do {
                try storage.delete(oldest.url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError {
            throw firstError
        }
    }
}
