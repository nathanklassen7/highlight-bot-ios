import Foundation
import Testing
@testable import HighlightCore

@Suite("MontageDraft")
struct MontageDraftTests {
    /// A clip captured `seconds` after the epoch, landscape 1080p unless asked
    /// otherwise.
    private func clip(
        at seconds: TimeInterval,
        duration: TimeInterval = 10,
        id: UUID = UUID(),
        width: Int = 1920,
        height: Int = 1080
    ) -> ClipRecord {
        ClipRecord(
            id: id,
            createdAt: Date(timeIntervalSince1970: seconds),
            duration: duration,
            fileName: "\(Int(seconds)).mp4",
            thumbnailFileName: nil,
            triggerSource: .tap,
            sizeBytes: 1,
            videoWidth: width,
            videoHeight: height
        )
    }

    /// A clip the montage would have to letterbox against a landscape frame.
    private func portraitClip(at seconds: TimeInterval, duration: TimeInterval = 10) -> ClipRecord {
        clip(at: seconds, duration: duration, width: 1080, height: 1920)
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

    // MARK: - Output orientation

    @Test("outputOrientation starts unset")
    func orientationDefaultsToNil() {
        let draft = MontageDraft(clips: [clip(at: 1), portraitClip(at: 2)])
        #expect(draft.outputOrientation == nil)
    }

    @Test("outputOrientation survives move and update")
    func orientationSurvivesEdits() {
        let clips = [clip(at: 1), portraitClip(at: 2), clip(at: 3)]
        var draft = MontageDraft(clips: clips)
        draft.outputOrientation = .portrait

        draft.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(draft.outputOrientation == .portrait)

        draft.update(ClipEdit(start: 1, end: 4), for: clips[0].id)
        #expect(draft.outputOrientation == .portrait)
        #expect(draft.resolvedOrientation == .portrait)
    }

    @Test("outputOrientation alone does not make the draft dirty")
    func orientationIsNotAnEdit() {
        var draft = MontageDraft(clips: [clip(at: 1), portraitClip(at: 2)])
        draft.outputOrientation = .portrait
        #expect(!draft.isReordered)
        #expect(!draft.hasEdits)
        #expect(!draft.hasChanges)
    }

    @Test("resolvedOrientation prefers the explicit choice over the majority")
    func resolvedPrefersExplicitChoice() {
        var draft = MontageDraft(clips: [clip(at: 1), clip(at: 2), portraitClip(at: 3)])
        #expect(draft.resolvedOrientation == .landscape)
        draft.outputOrientation = .portrait
        #expect(draft.resolvedOrientation == .portrait)
    }

    @Test("resolvedOrientation is the shared orientation when every clip agrees")
    func resolvedUsesSharedOrientation() {
        let portrait = MontageDraft(clips: [portraitClip(at: 1), portraitClip(at: 2)])
        #expect(portrait.resolvedOrientation == .portrait)

        // Legacy records carry no size and are landscape by construction.
        let legacy = MontageDraft(clips: [clip(at: 1, width: 0, height: 0), clip(at: 2)])
        #expect(legacy.resolvedOrientation == .landscape)
    }

    @Test("resolvedOrientation falls back to the orientation with the most output seconds")
    func resolvedFallsBackToSuggestion() {
        let clips = [clip(at: 1, duration: 4), portraitClip(at: 2, duration: 12)]
        var draft = MontageDraft(clips: clips)
        #expect(draft.resolvedOrientation == MontageFraming.suggestedOrientation(for: draft.items))
        #expect(draft.resolvedOrientation == .portrait)

        // Trimming the portrait clip below the landscape one flips the suggestion.
        draft.update(ClipEdit(start: 0, end: 2), for: clips[1].id)
        #expect(draft.resolvedOrientation == .landscape)
    }
}
