import Foundation
import Testing
@testable import HighlightCore

@Suite("SegmentRingBuffer")
struct SegmentRingBufferTests {
    private func makeRing(retainSeconds: TimeInterval = 25) -> (SegmentRingBuffer, InMemorySegmentStorage) {
        let storage = InMemorySegmentStorage()
        let ring = SegmentRingBuffer(policy: RingBufferPolicy(retainSeconds: retainSeconds), storage: storage)
        return (ring, storage)
    }

    @Test("init segment makes session current and is persisted")
    func initMakesSessionCurrent() async throws {
        let (ring, storage) = makeRing()
        let session = SessionID()
        let segment = try await ring.append(Fixtures.initSegment(session))

        #expect(await ring.currentSessionID == session)
        #expect(segment.kind == .initialization)
        #expect(segment.byteCount == 8)
        #expect(storage.data(at: segment.url) == Data(repeating: 0xAA, count: 8))
        #expect(await ring.segments == [segment])
        #expect(await ring.bufferedSeconds == 0)
    }

    @Test("eviction keeps at least retainSeconds and deletes evicted files")
    func evictionKeepsRetainSeconds() async throws {
        let (ring, storage) = makeRing(retainSeconds: 25)
        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))

        var appended: [Segment] = []
        for seq in 1...5 {
            appended.append(try await ring.append(Fixtures.mediaSegment(session, seq: seq)))
        }
        // 25 s buffered: nothing may be evicted yet (25 - 5 = 20 < 25).
        #expect(await ring.bufferedSeconds == 25)
        #expect(await ring.segments.count == 6)

        appended.append(try await ring.append(Fixtures.mediaSegment(session, seq: 6)))
        // 30 s total: 30 - 5 = 25 >= 25, so seq 1 goes.
        #expect(await ring.bufferedSeconds == 25)
        let seqs = await ring.segments.map(\.seq)
        #expect(seqs == [0, 2, 3, 4, 5, 6])
        #expect(storage.data(at: appended[0].url) == nil)
        #expect(storage.data(at: appended[1].url) != nil)

        for seq in 7...20 {
            try await ring.append(Fixtures.mediaSegment(session, seq: seq))
        }
        #expect(await ring.bufferedSeconds == 25)
        #expect(await ring.segments.map(\.seq) == [0, 16, 17, 18, 19, 20])
        #expect(storage.count == 6)
    }

    @Test("init segment is never evicted")
    func initNeverEvicted() async throws {
        let (ring, _) = makeRing(retainSeconds: 5)
        let session = SessionID()
        let initSegment = try await ring.append(Fixtures.initSegment(session))
        for seq in 1...10 {
            try await ring.append(Fixtures.mediaSegment(session, seq: seq))
        }
        #expect(await ring.segments.first == initSegment)
        #expect(await ring.segments.map(\.seq) == [0, 10])
    }

    @Test("new session evicts the old session entirely")
    func newSessionEvictsOld() async throws {
        let (ring, storage) = makeRing()
        let old = SessionID()
        try await ring.append(Fixtures.initSegment(old))
        for seq in 1...3 {
            try await ring.append(Fixtures.mediaSegment(old, seq: seq))
        }
        #expect(storage.count == 4)

        let new = SessionID()
        let newInit = try await ring.append(Fixtures.initSegment(new))

        #expect(await ring.currentSessionID == new)
        #expect(await ring.segments == [newInit])
        #expect(await ring.bufferedSeconds == 0)
        #expect(storage.count == 1)
        #expect(storage.storedURLs == [newInit.url])
    }

    @Test("media for a non-current session is rejected")
    func mediaForOtherSessionRejected() async throws {
        let (ring, storage) = makeRing()
        let current = SessionID()
        let other = SessionID()

        // No session yet.
        await #expect(throws: RingBufferError.sessionNotCurrent(other, current: nil)) {
            try await ring.append(Fixtures.mediaSegment(other, seq: 1))
        }

        try await ring.append(Fixtures.initSegment(current))
        await #expect(throws: RingBufferError.sessionNotCurrent(other, current: current)) {
            try await ring.append(Fixtures.mediaSegment(other, seq: 1))
        }
        #expect(storage.count == 1)
        #expect(await ring.segments.count == 1)
    }

    @Test("duplicate seq is rejected")
    func duplicateRejected() async throws {
        let (ring, _) = makeRing()
        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))
        try await ring.append(Fixtures.mediaSegment(session, seq: 1))
        await #expect(throws: RingBufferError.duplicateSegment(session, seq: 1)) {
            try await ring.append(Fixtures.mediaSegment(session, seq: 1))
        }
        await #expect(throws: RingBufferError.duplicateSegment(session, seq: 0)) {
            try await ring.append(Fixtures.initSegment(session))
        }
    }

    @Test("snapshot returns whole segments covering at least the requested seconds")
    func snapshotCoversRequested() async throws {
        let (ring, _) = makeRing(retainSeconds: 25)
        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))
        for seq in 1...5 {
            try await ring.append(Fixtures.mediaSegment(session, seq: seq))
        }

        let plan = try #require(await ring.snapshot(lastSeconds: 12))
        #expect(plan.sessionID == session)
        #expect(plan.initializationSegment.seq == 0)
        #expect(plan.mediaSegments.map(\.seq) == [3, 4, 5])
        #expect(plan.duration == 15)
        #expect(plan.urls.count == 4)
        #expect(plan.byteCount == 8 + 3 * 16)

        let everything = try #require(await ring.snapshot(lastSeconds: 60))
        #expect(everything.mediaSegments.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(everything.duration == 25)
    }

    @Test("snapshot is nil without init or without media")
    func snapshotNilCases() async throws {
        let (ring, _) = makeRing()
        #expect(await ring.snapshot(lastSeconds: 10) == nil)

        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))
        #expect(await ring.snapshot(lastSeconds: 10) == nil)

        try await ring.append(Fixtures.mediaSegment(session, seq: 1))
        #expect(await ring.snapshot(lastSeconds: 10) != nil)
    }

    @Test("snapshot stops at a seq gap")
    func snapshotStopsAtGap() async throws {
        let (ring, _) = makeRing(retainSeconds: 100)
        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))
        try await ring.append(Fixtures.mediaSegment(session, seq: 1))
        try await ring.append(Fixtures.mediaSegment(session, seq: 2))
        // seq 3 lost
        try await ring.append(Fixtures.mediaSegment(session, seq: 4))
        try await ring.append(Fixtures.mediaSegment(session, seq: 5))

        let plan = try #require(await ring.snapshot(lastSeconds: 100))
        #expect(plan.mediaSegments.map(\.seq) == [4, 5])
        #expect(plan.duration == 10)
    }

    @Test("updatePolicy takes effect on next append")
    func updatePolicy() async throws {
        let (ring, _) = makeRing(retainSeconds: 100)
        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))
        for seq in 1...6 {
            try await ring.append(Fixtures.mediaSegment(session, seq: seq))
        }
        #expect(await ring.bufferedSeconds == 30)

        await ring.updatePolicy(RingBufferPolicy(retainSeconds: 10))
        #expect(await ring.policy.retainSeconds == 10)
        try await ring.append(Fixtures.mediaSegment(session, seq: 7))
        #expect(await ring.bufferedSeconds == 10)
        #expect(await ring.segments.map(\.seq) == [0, 6, 7])
    }

    @Test("clear empties index and storage")
    func clear() async throws {
        let (ring, storage) = makeRing()
        let session = SessionID()
        try await ring.append(Fixtures.initSegment(session))
        try await ring.append(Fixtures.mediaSegment(session, seq: 1))

        try await ring.clear()
        #expect(await ring.segments.isEmpty)
        #expect(await ring.currentSessionID == nil)
        #expect(storage.count == 0)

        // After clear, media for the old session is rejected until a new init.
        await #expect(throws: RingBufferError.self) {
            try await ring.append(Fixtures.mediaSegment(session, seq: 2))
        }
    }

    @Test("FileSegmentStorage writes and deletes real files")
    func fileStorage() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HighlightCoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let storage = FileSegmentStorage(rootDirectory: root)
        let ring = SegmentRingBuffer(policy: RingBufferPolicy(retainSeconds: 10), storage: storage)
        let session = SessionID()

        let initSegment = try await ring.append(Fixtures.initSegment(session))
        #expect(initSegment.url.lastPathComponent == "0.init")
        #expect(initSegment.url.deletingLastPathComponent().lastPathComponent == session.rawValue.uuidString)
        #expect(FileManager.default.fileExists(atPath: initSegment.url.path))
        #expect(try Data(contentsOf: initSegment.url) == Data(repeating: 0xAA, count: 8))

        var media: [Segment] = []
        for seq in 1...4 {
            media.append(try await ring.append(Fixtures.mediaSegment(session, seq: seq)))
        }
        #expect(media[0].url.lastPathComponent == "1.m4s")
        // 20 s total, retain 10: seq 1 and 2 evicted.
        #expect(!FileManager.default.fileExists(atPath: media[0].url.path))
        #expect(!FileManager.default.fileExists(atPath: media[1].url.path))
        #expect(FileManager.default.fileExists(atPath: media[2].url.path))
        #expect(FileManager.default.fileExists(atPath: media[3].url.path))

        // New session removes the old directory.
        let next = SessionID()
        try await ring.append(Fixtures.initSegment(next))
        #expect(!FileManager.default.fileExists(atPath: storage.sessionDirectory(for: session).path))
        #expect(FileManager.default.fileExists(atPath: storage.sessionDirectory(for: next).path))

        try await ring.clear()
        let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(remaining.isEmpty)

        // Deleting missing things is not an error.
        try storage.delete(media[0].url)
        try storage.deleteAll(for: session)
    }
}
