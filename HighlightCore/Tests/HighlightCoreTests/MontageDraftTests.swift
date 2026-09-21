import Foundation
import Testing
@testable import HighlightCore

@Suite("MontageDraft")
struct MontageDraftTests {
    /// A clip captured `seconds` after the epoch.
    private func clip(at seconds: TimeInterval, duration: TimeInterval = 10, id: UUID = UUID()) -> ClipRecord {
        ClipRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: seconds),
            duration: duration,
            fileName: "\(Int(seconds)).mp4",
            thumbnailFileName: nil,
            triggerSource: .tap,
            sizeBytes: 1
        )
    }

    @Test("init orders clips oldest first regardless of input order")
    func oldestFirst() {
        let newest = clip(at: 300)
        let oldest = clip(at: 100)
        let middle = clip(at: 200)
        let draft = MontageDraft(clips: [newest, oldest, middle])
        #expect(draft.items.map(\.clip.id) == [oldest.id, middle.id, newest.id])
        #expect(!draft.isReordered)
        #expect(!draft.hasChanges)
    }

    @Test("init breaks timestamp ties by id so the order is stable")
    func stableTies() {
        let a = clip(at: 100, id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let b = clip(at: 100, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)
        #expect(MontageDraft(clips: [b, a]).items.map(\.id) == [a.id, b.id])
        #expect(MontageDraft(clips: [a, b]).items.map(\.id) == [a.id, b.id])
    }

    @Test("items start as full-length edits")
    func fullEdits() {
        let draft = MontageDraft(clips: [clip(at: 1, duration: 7), clip(at: 2, duration: 9)])
        #expect(draft.items.map(\.edit) == [.full(duration: 7), .full(duration: 9)])
        #expect(draft.totalDuration == 16)
        #expect(!draft.hasEdits)
    }

    @Test("move reorders like List.onMove and flags the draft as reordered")
    func move() {
        let clips = [clip(at: 1), clip(at: 2), clip(at: 3)]
        var draft = MontageDraft(clips: clips)
        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(draft.items.map(\.id) == [clips[2].id, clips[0].id, clips[1].id])
        #expect(draft.isReordered)
        #expect(draft.hasChanges)
    }

    @Test("move non-contiguous indices before destination matches onMove")
    func moveNonContiguous() {
        let clips = [clip(at: 1), clip(at: 2), clip(at: 3), clip(at: 4)]
        var draft = MontageDraft(clips: clips)
        draft.move(fromOffsets: IndexSet([0, 2]), toOffset: 2)
        #expect(draft.items.map(\.id) == [clips[1].id, clips[0].id, clips[2].id, clips[3].id])
    }

    @Test("move contiguous pair to end matches onMove")
    func moveContiguousToEnd() {
        let clips = [clip(at: 1), clip(at: 2), clip(at: 3), clip(at: 4)]
        var draft = MontageDraft(clips: clips)
        draft.move(fromOffsets: IndexSet([0, 1]), toOffset: 4)
        #expect(draft.items.map(\.id) == [clips[2].id, clips[3].id, clips[0].id, clips[1].id])
    }

    @Test("moving back to the original order clears isReordered")
    func moveBack() {
        let clips = [clip(at: 1), clip(at: 2)]
        var draft = MontageDraft(clips: clips)
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        draft.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(!draft.isReordered)
    }

    @Test("update replaces one item's edit and changes the total")
    func update() {
        let clips = [clip(at: 1, duration: 10), clip(at: 2, duration: 10)]
        var draft = MontageDraft(clips: clips)
        let edit = ClipEdit(start: 2, end: 6, slowMotion: SlowMotionSegment(start: 3, end: 4, rate: 0.5))
        draft.update(edit, for: clips[1].id)
        #expect(draft.item(withID: clips[1].id)?.edit == edit)
        #expect(draft.item(withID: clips[0].id)?.edit == .full(duration: 10))
        #expect(draft.totalDuration == 15)
        #expect(draft.hasEdits)
        #expect(draft.hasChanges)
    }

    @Test("update for an unknown id is a no-op")
    func updateUnknown() {
        var draft = MontageDraft(clips: [clip(at: 1)])
        let before = draft
        draft.update(ClipEdit(start: 1, end: 2), for: UUID())
        #expect(draft == before)
    }

    @Test("item hasChanges follows its edit")
    func itemChanges() {
        let record = clip(at: 1, duration: 10)
        #expect(!MontageItem(clip: record).hasChanges)
        #expect(MontageItem(clip: record, edit: ClipEdit(start: 1, end: 10)).hasChanges)
    }
}
