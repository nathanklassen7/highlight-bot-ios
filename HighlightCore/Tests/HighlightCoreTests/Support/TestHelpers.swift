import Foundation
import HighlightCore

/// Collects everything from an `AsyncStream` so tests can wait for conditions
/// without racing the producer.
actor EventRecorder<Element: Sendable> {
    private(set) var events: [Element] = []
    private var task: Task<Void, Never>?

    private init() {}

    /// Creates a recorder that is already consuming `stream`. The stream
    /// buffers unboundedly, so nothing emitted after subscription is lost.
    static func recording(_ stream: AsyncStream<Element>) async -> EventRecorder {
        let recorder = EventRecorder()
        await recorder.start(stream)
        return recorder
    }

    private func start(_ stream: AsyncStream<Element>) {
        task = Task {
            for await event in stream {
                self.append(event)
            }
        }
    }

    private func append(_ event: Element) {
        events.append(event)
    }

    func stop() {
        task?.cancel()
    }

    /// Polls until `predicate` is satisfied or `timeout` elapses. Returns the
    /// events seen at that point.
    @discardableResult
    func waitUntil(
        timeout: Duration = .seconds(3),
        _ predicate: @Sendable ([Element]) -> Bool
    ) async -> [Element] {
        let deadline = ContinuousClock.now + timeout
        while !predicate(events), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return events
    }

    /// Waits until at least `count` events have arrived.
    @discardableResult
    func waitForCount(_ count: Int, timeout: Duration = .seconds(3)) async -> [Element] {
        await waitUntil(timeout: timeout) { $0.count >= count }
    }
}

/// Polls an async condition until it holds or the timeout elapses.
func eventually(
    timeout: Duration = .seconds(3),
    _ condition: @Sendable () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

// MARK: - Segment fixtures

enum Fixtures {
    static func initSegment(_ session: SessionID, bytes: Int = 8) -> IncomingSegment {
        IncomingSegment(
            sessionID: session,
            seq: 0,
            kind: .initialization,
            data: Data(repeating: 0xAA, count: bytes),
            startTime: 0,
            duration: 0
        )
    }

    static func mediaSegment(
        _ session: SessionID,
        seq: Int,
        duration: TimeInterval = 5,
        bytes: Int = 16
    ) -> IncomingSegment {
        IncomingSegment(
            sessionID: session,
            seq: seq,
            kind: .media,
            data: Data(repeating: UInt8(truncatingIfNeeded: seq), count: bytes),
            startTime: TimeInterval(seq - 1) * duration,
            duration: duration
        )
    }

    static func storedInit(_ session: SessionID) -> Segment {
        Segment(
            sessionID: session,
            seq: 0,
            kind: .initialization,
            url: URL(string: "memory://\(session)/0.init")!,
            startTime: 0,
            duration: 0,
            byteCount: 8
        )
    }

    static func storedMedia(_ session: SessionID, seq: Int, duration: TimeInterval = 5) -> Segment {
        Segment(
            sessionID: session,
            seq: seq,
            kind: .media,
            url: URL(string: "memory://\(session)/\(seq).m4s")!,
            startTime: TimeInterval(seq - 1) * duration,
            duration: duration,
            byteCount: 16
        )
    }
}

extension TriggerEvent {
    static func save(_ seconds: TimeInterval? = nil, source: TriggerSourceID = .tap) -> TriggerEvent {
        TriggerEvent(source: source, kind: .saveClip(seconds: seconds))
    }
    static let start = TriggerEvent(source: .ui, kind: .startRecording)
    static let stop = TriggerEvent(source: .ui, kind: .stopRecording)
    static let toggle = TriggerEvent(source: .tap, kind: .toggleRecording)
}
