import Foundation
import Testing
@testable import HighlightCore

@Suite("ClipAssembler")
struct ClipAssemblerTests {
    let session = SessionID()

    private func segments(seqs: [Int], duration: TimeInterval = 5, withInit: Bool = true) -> [Segment] {
        var result: [Segment] = []
        if withInit { result.append(Fixtures.storedInit(session)) }
        result += seqs.map { Fixtures.storedMedia(session, seq: $0, duration: duration) }
        return result
    }

    @Test("exact fit returns exactly the needed segments")
    func exactFit() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [1, 2, 3, 4]), sessionID: session, lastSeconds: 10))
        #expect(plan.mediaSegments.map(\.seq) == [3, 4])
        #expect(plan.duration == 10)
    }

    @Test("partial coverage rounds up to whole segments")
    func roundsUp() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [1, 2, 3, 4]), sessionID: session, lastSeconds: 11))
        #expect(plan.mediaSegments.map(\.seq) == [2, 3, 4])
        #expect(plan.duration == 15)
    }

    @Test("more requested than available returns everything")
    func moreThanAvailable() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [1, 2, 3]), sessionID: session, lastSeconds: 60))
        #expect(plan.mediaSegments.map(\.seq) == [1, 2, 3])
        #expect(plan.duration == 15)
    }

    @Test("single segment")
    func singleSegment() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [7]), sessionID: session, lastSeconds: 20))
        #expect(plan.mediaSegments.map(\.seq) == [7])
        #expect(plan.urls == [Fixtures.storedInit(session).url, Fixtures.storedMedia(session, seq: 7).url])
    }

    @Test("zero or negative request still returns the newest segment")
    func zeroRequest() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [1, 2, 3]), sessionID: session, lastSeconds: 0))
        #expect(plan.mediaSegments.map(\.seq) == [3])
    }

    @Test("stops at a seq gap")
    func stopsAtGap() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [1, 2, 4, 5]), sessionID: session, lastSeconds: 100))
        #expect(plan.mediaSegments.map(\.seq) == [4, 5])
    }

    @Test("unsorted input is sorted by seq")
    func sortsInput() throws {
        let plan = try #require(ClipAssembler.plan(segments: segments(seqs: [3, 1, 2]), sessionID: session, lastSeconds: 100))
        #expect(plan.mediaSegments.map(\.seq) == [1, 2, 3])
    }

    @Test("nil without init segment")
    func nilWithoutInit() {
        #expect(ClipAssembler.plan(segments: segments(seqs: [1, 2], withInit: false), sessionID: session, lastSeconds: 10) == nil)
    }

    @Test("nil without media")
    func nilWithoutMedia() {
        #expect(ClipAssembler.plan(segments: segments(seqs: []), sessionID: session, lastSeconds: 10) == nil)
        #expect(ClipAssembler.plan(segments: [], sessionID: session, lastSeconds: 10) == nil)
    }

    @Test("ignores segments from other sessions")
    func filtersSession() throws {
        let other = SessionID()
        var all = segments(seqs: [1, 2])
        all.append(Fixtures.storedInit(other))
        all.append(Fixtures.storedMedia(other, seq: 1))
        all.append(Fixtures.storedMedia(other, seq: 2))
        all.append(Fixtures.storedMedia(other, seq: 3))

        let plan = try #require(ClipAssembler.plan(segments: all, sessionID: session, lastSeconds: 100))
        #expect(plan.sessionID == session)
        #expect(plan.mediaSegments.allSatisfy { $0.sessionID == session })
        #expect(plan.mediaSegments.map(\.seq) == [1, 2])

        #expect(ClipAssembler.plan(segments: all, sessionID: SessionID(), lastSeconds: 10) == nil)
    }

    @Test("ClipNaming produces UTC timestamp with hex suffix")
    func naming() {
        let date = Date(timeIntervalSince1970: 1_789_762_263) // 2026-09-18T20:11:03Z
        let name = ClipNaming.baseName(for: date)
        #expect(name.hasPrefix("2026-09-18T20-11-03Z-"))
        #expect(name.count == "2026-09-18T20-11-03Z-".count + 4)
        let suffix = name.suffix(4)
        #expect(suffix.allSatisfy { $0.isHexDigit })
    }

    @Test("ClipRecord round-trips through JSON with a flat trigger source")
    func clipRecordCodable() throws {
        let record = ClipRecord(
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 20,
            fileName: "clip.mp4",
            thumbnailFileName: "clip.jpg",
            triggerSource: .hardwareButton,
            sizeBytes: 12_345,
            tags: ["Hockey", "Playoffs"],
            isStarred: true
        )
        let data = try JSONEncoder().encode(record)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"triggerSource\":\"hardware\""))
        let decoded = try JSONDecoder().decode(ClipRecord.self, from: data)
        #expect(decoded == record)
        #expect(decoded.tags == ["Hockey", "Playoffs"])
        #expect(decoded.isStarred)
    }

    @Test("ClipRecord decodes legacy JSON without tags or isStarred")
    func clipRecordLegacyDecode() throws {
        let json = """
        {"id":"6BA7B810-9DAD-11D1-80B4-00C04FD430C8","createdAt":0,"duration":20,"fileName":"clip.mp4","triggerSource":"tap","sizeBytes":1}
        """
        let decoded = try JSONDecoder().decode(ClipRecord.self, from: Data(json.utf8))
        #expect(decoded.tags.isEmpty)
        #expect(decoded.isStarred == false)
        #expect(decoded.thumbnailFileName == nil)
    }

    @Test("ClipRecord.with replaces only user metadata")
    func clipRecordWith() {
        let record = ClipRecord(
            id: UUID(),
            createdAt: .now,
            duration: 5,
            fileName: "a.mp4",
            thumbnailFileName: nil,
            triggerSource: .tap,
            sizeBytes: 1
        )
        let tagged = record.with(tags: ["Golf"])
        #expect(tagged.tags == ["Golf"])
        #expect(tagged.isStarred == false)
        #expect(tagged.id == record.id)
        let starred = tagged.with(isStarred: true)
        #expect(starred.tags == ["Golf"])
        #expect(starred.isStarred)
    }
}
