import Foundation
import Testing
@testable import HighlightCore

@Suite("SlowMotionSegment")
struct SlowMotionSegmentTests {
    @Test("scaledDuration divides by rate")
    func scaled() {
        let segment = SlowMotionSegment(start: 2, end: 3, rate: 0.5)
        #expect(segment.duration == 1)
        #expect(segment.scaledDuration == 2)
    }

    @Test("addedDuration is the stretch in place and the whole scaled length on replay")
    func added() {
        let segment = SlowMotionSegment(start: 2, end: 3, rate: 0.25)
        #expect(segment.addedDuration == 3)
        #expect(segment.addedDuration(replay: false) == 3)
        #expect(segment.addedDuration(replay: true) == 4)
    }

    @Test("contains is half-open")
    func contains() {
        let segment = SlowMotionSegment(start: 2, end: 3, rate: 0.5)
        #expect(segment.contains(2))
        #expect(segment.contains(2.99))
        #expect(!segment.contains(3))
        #expect(!segment.contains(1.99))
    }

    @Test("centered puts defaultDuration in the middle and shrinks for short ranges")
    func centered() {
        let wide = SlowMotionSegment.centered(in: 0, 10)
        #expect(abs(wide.start - 4.5) < 1e-9)
        #expect(abs(wide.end - 5.5) < 1e-9)
        #expect(wide.rate == SlowMotionSegment.defaultRate)

        let narrow = SlowMotionSegment.centered(in: 0, 0.5)
        #expect(abs(narrow.start - 0) < 1e-9)
        #expect(abs(narrow.end - 0.5) < 1e-9)
    }

    @Test("clamped moves the segment inside the range keeping the minimum length")
    func clamped() {
        let past = SlowMotionSegment(start: 8, end: 9.5, rate: 0.5).clamped(to: 0, 9)
        #expect(past.start == 8)
        #expect(past.end == 9)

        let squeezed = SlowMotionSegment(start: 5, end: 6, rate: 0.5).clamped(to: 0, 5.1)
        #expect(abs(squeezed.end - 5.1) < 1e-9)
        #expect(abs(squeezed.start - (5.1 - SlowMotionSegment.minimumDuration)) < 1e-9)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let segment = SlowMotionSegment(start: 1.5, end: 2.75, rate: 0.15)
        let data = try JSONEncoder().encode(segment)
        #expect(try JSONDecoder().decode(SlowMotionSegment.self, from: data) == segment)
    }
}
