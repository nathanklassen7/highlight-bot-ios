import Foundation
import Testing
@testable import HighlightCore

@Suite("MontageFraming")
struct MontageFramingTests {
    private func input(
        _ orientation: ClipOrientation,
        seconds: Double,
        width: Int = 1920,
        height: Int = 1080
    ) -> MontageFramingInput {
        MontageFramingInput(orientation: orientation, outputSeconds: seconds, width: width, height: height)
    }

    @Test("needsChoice is false for a single orientation")
    func needsChoiceHomogeneous() {
        let landscape = [input(.landscape, seconds: 5), input(.landscape, seconds: 3)]
        #expect(!MontageFraming.needsChoice(landscape))
        let portrait = [input(.portrait, seconds: 4, width: 1080, height: 1920)]
        #expect(!MontageFraming.needsChoice(portrait))
    }

    @Test("needsChoice is true when landscape and portrait mix")
    func needsChoiceMixed() {
        let mixed = [
            input(.landscape, seconds: 5),
            input(.portrait, seconds: 2, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.needsChoice(mixed))
    }

    @Test("unknown counts as landscape for choice and orientation sets")
    func mixedWithUnknown() {
        let items = [
            input(.landscape, seconds: 4),
            input(.unknown, seconds: 3, width: 0, height: 0),
            input(.portrait, seconds: 1, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.needsChoice(items))
        #expect(MontageFraming.orientations(of: items) == [.landscape, .portrait])
        #expect(MontageFraming.letterboxedCount(items, keeping: .landscape) == 1)
    }

    @Test("suggestedOrientation sums output seconds including trim and slow-mo")
    func suggestedBySeconds() {
        let landscapeHeavy = [
            input(.landscape, seconds: 12),
            input(.portrait, seconds: 5, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.suggestedOrientation(for: landscapeHeavy) == .landscape)

        let portraitHeavy = [
            input(.landscape, seconds: 4),
            input(.portrait, seconds: 10, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.suggestedOrientation(for: portraitHeavy) == .portrait)

        let trimmedLandscape = ClipEdit(start: 0, end: 8, slowMotion: nil).outputDuration
        let slowPortrait = ClipEdit(
            start: 0,
            end: 4,
            slowMotion: SlowMotionSegment(start: 1, end: 2, rate: 0.5)
        ).outputDuration
        let fromEdits = [
            input(.landscape, seconds: trimmedLandscape),
            input(.portrait, seconds: slowPortrait, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.suggestedOrientation(for: fromEdits) == .landscape)
    }

    @Test("suggestedOrientation breaks ties landscape before portrait before square")
    func suggestedTieBreak() {
        let tie = [
            input(.portrait, seconds: 6, width: 1080, height: 1920),
            input(.landscape, seconds: 6),
        ]
        #expect(MontageFraming.suggestedOrientation(for: tie) == .landscape)

        let portraitSquare = [
            input(.square, seconds: 5, width: 1080, height: 1080),
            input(.portrait, seconds: 5, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.suggestedOrientation(for: portraitSquare) == .portrait)
    }

    @Test("renderSize picks the largest matching oriented frame")
    func renderSizeLargest() {
        let items = [
            input(.landscape, seconds: 1, width: 1280, height: 720),
            input(.landscape, seconds: 1, width: 1920, height: 1080),
            input(.portrait, seconds: 1, width: 1080, height: 1920),
        ]
        let size = MontageFraming.renderSize(for: items, keeping: .landscape)
        #expect(size.width == 1920)
        #expect(size.height == 1080)
    }

    @Test("renderSize falls back to standard HD when nothing matches")
    func renderSizeFallback() {
        let onlyPortrait = [input(.portrait, seconds: 1, width: 1080, height: 1920)]
        let landscapeDefault = MontageFraming.renderSize(for: onlyPortrait, keeping: .landscape)
        #expect(landscapeDefault == (1920, 1080))

        let portraitDefault = MontageFraming.renderSize(for: onlyPortrait, keeping: .portrait)
        #expect(portraitDefault == (1080, 1920))

        let squareDefault = MontageFraming.renderSize(for: onlyPortrait, keeping: .square)
        #expect(squareDefault == (1080, 1080))
    }

    @Test("letterboxedCount counts mismatched effective orientations")
    func letterboxedCount() {
        let items = [
            input(.landscape, seconds: 2),
            input(.landscape, seconds: 3),
            input(.portrait, seconds: 1, width: 1080, height: 1920),
        ]
        #expect(MontageFraming.letterboxedCount(items, keeping: .landscape) == 1)
        #expect(MontageFraming.letterboxedCount(items, keeping: .portrait) == 2)
    }

    // MARK: - Montage items

    private func item(width: Int, height: Int, duration: Double, edit: ClipEdit? = nil) -> MontageItem {
        let clip = ClipRecord(
            id: UUID(),
            createdAt: .now,
            duration: duration,
            fileName: "clip.mp4",
            thumbnailFileName: nil,
            triggerSource: .tap,
            sizeBytes: 1,
            videoWidth: width,
            videoHeight: height
        )
        return MontageItem(clip: clip, edit: edit)
    }

    @Test("MontageItem overloads classify from the record's oriented size")
    func itemOrientations() {
        let items = [
            item(width: 1920, height: 1080, duration: 6),
            item(width: 1080, height: 1920, duration: 4),
            item(width: 0, height: 0, duration: 2),
        ]
        #expect(MontageFraming.orientations(of: items) == [.landscape, .portrait])
        #expect(MontageFraming.needsChoice(items))
        #expect(MontageFraming.letterboxedCount(items, keeping: .landscape) == 1)
        #expect(MontageFraming.letterboxedCount(items, keeping: .portrait) == 2)

        let allLandscape = [item(width: 1920, height: 1080, duration: 3)]
        #expect(!MontageFraming.needsChoice(allLandscape))
    }

    @Test("MontageItem overloads weigh the edited output duration, not the source")
    func itemSuggestedUsesOutputDuration() {
        let items = [
            item(width: 1920, height: 1080, duration: 20, edit: ClipEdit(start: 0, end: 3, slowMotion: nil)),
            item(width: 1080, height: 1920, duration: 8),
        ]
        #expect(MontageFraming.suggestedOrientation(for: items) == .portrait)
    }

    @Test("MontageItem renderSize picks the largest of the kept orientation")
    func itemRenderSize() {
        let items = [
            item(width: 1280, height: 720, duration: 2),
            item(width: 1920, height: 1080, duration: 2),
            item(width: 1080, height: 1920, duration: 2),
        ]
        #expect(MontageFraming.renderSize(for: items, keeping: .landscape) == (1920, 1080))
        #expect(MontageFraming.renderSize(for: items, keeping: .portrait) == (1080, 1920))

        let legacyOnly = [item(width: 0, height: 0, duration: 2)]
        #expect(MontageFraming.renderSize(for: legacyOnly, keeping: .landscape) == (1920, 1080))
    }
}
