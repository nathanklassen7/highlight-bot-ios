import Foundation
import Testing
@testable import HighlightCore

@Suite("ClipEdit")
struct ClipEditTests {
    @Test("full covers the whole clip and has no changes")
    func full() {
        let edit = ClipEdit.full(duration: 12)
        #expect(edit.start == 0)
        #expect(edit.end == 12)
        #expect(edit.slowMotion == nil)
        #expect(!edit.isSlowMotionReplay)
        #expect(!edit.hasChanges(clipDuration: 12))
        #expect(edit.outputDuration == 12)
    }

    @Test("outputDuration adds the in-place stretch")
    func outputInPlace() {
        let edit = ClipEdit(start: 2, end: 8, slowMotion: SlowMotionSegment(start: 4, end: 5, rate: 0.5))
        #expect(edit.selectedDuration == 6)
        #expect(edit.outputDuration == 7)
    }

    @Test("outputDuration appends the whole scaled segment on replay")
    func outputReplay() {
        let edit = ClipEdit(start: 2, end: 8, slowMotion: SlowMotionSegment(start: 4, end: 5, rate: 0.25), isSlowMotionReplay: true)
        #expect(edit.outputDuration == 10)
    }

    @Test("replay flag without a segment adds nothing")
    func replayWithoutSegment() {
        let edit = ClipEdit(start: 0, end: 5, slowMotion: nil, isSlowMotionReplay: true)
        #expect(edit.outputDuration == 5)
        #expect(!edit.hasChanges(clipDuration: 5))
    }

    @Test("isTrimmed ignores movement inside the edge tolerance")
    func trimmedTolerance() {
        #expect(!ClipEdit(start: 0.005, end: 9.995).isTrimmed(clipDuration: 10))
        #expect(ClipEdit(start: 0.5, end: 10).isTrimmed(clipDuration: 10))
        #expect(ClipEdit(start: 0, end: 9.5).isTrimmed(clipDuration: 10))
    }

    @Test("hasChanges is true with only a slow-mo segment")
    func changesWithSlowMotion() {
        let edit = ClipEdit(start: 0, end: 10, slowMotion: SlowMotionSegment(start: 4, end: 5, rate: 0.5))
        #expect(edit.hasChanges(clipDuration: 10))
    }

    @Test("clamped fits a stale edit into a shorter file")
    func clampedShorter() {
        let stale = ClipEdit(start: 1, end: 12, slowMotion: SlowMotionSegment(start: 10, end: 11.5, rate: 0.5))
        let fitted = stale.clamped(toClipDuration: 10, minimumDuration: 1)
        #expect(fitted.start == 1)
        #expect(fitted.end == 10)
        #expect(fitted.slowMotion != nil)
        let segment = fitted.slowMotion!
        #expect(segment.end == 10)
        #expect(segment.start <= 10 - SlowMotionSegment.minimumDuration)
    }

    @Test("clamped pulls start back when it would leave less than the minimum")
    func clampedStart() {
        let edit = ClipEdit(start: 9.8, end: 12).clamped(toClipDuration: 10, minimumDuration: 1)
        #expect(edit.end == 10)
        #expect(abs(edit.start - 9) < 1e-9)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let edit = ClipEdit(start: 1, end: 4, slowMotion: SlowMotionSegment(start: 2, end: 3, rate: 0.5), isSlowMotionReplay: true)
        let data = try JSONEncoder().encode(edit)
        #expect(try JSONDecoder().decode(ClipEdit.self, from: data) == edit)
    }
}
