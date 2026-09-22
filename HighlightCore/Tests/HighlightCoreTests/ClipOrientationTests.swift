import Foundation
import Testing
@testable import HighlightCore

@Suite("ClipOrientation")
struct ClipOrientationTests {
    @Test("classify landscape, portrait, and square")
    func classifyKnown() {
        #expect(ClipOrientation.classify(width: 1920, height: 1080) == .landscape)
        #expect(ClipOrientation.classify(width: 1080, height: 1920) == .portrait)
        #expect(ClipOrientation.classify(width: 1080, height: 1080) == .square)
    }

    @Test("non-positive dimensions are unknown")
    func classifyMissing() {
        #expect(ClipOrientation.classify(width: 0, height: 1080) == .unknown)
        #expect(ClipOrientation.classify(width: 1920, height: 0) == .unknown)
        #expect(ClipOrientation.classify(width: 0, height: 0) == .unknown)
        #expect(ClipOrientation.classify(width: -1, height: 1080) == .unknown)
    }

    @Test("effective treats legacy unknown as landscape")
    func effectiveUnknown() {
        #expect(ClipOrientation.unknown.effective == .landscape)
        #expect(ClipOrientation.landscape.effective == .landscape)
        #expect(ClipOrientation.portrait.effective == .portrait)
        #expect(ClipOrientation.square.effective == .square)
    }

    @Test("displayName matches effective orientation")
    func displayNames() {
        #expect(ClipOrientation.landscape.displayName == "Landscape")
        #expect(ClipOrientation.portrait.displayName == "Portrait")
        #expect(ClipOrientation.square.displayName == "Square")
        #expect(ClipOrientation.unknown.displayName == "Landscape")
    }
}
