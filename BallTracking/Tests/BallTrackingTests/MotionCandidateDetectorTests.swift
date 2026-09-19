import CoreGraphics
import CoreMedia
import Testing
@testable import BallTracking

struct MotionCandidateDetectorTests {
    private let width = 640
    private let height = 360
    private func time(_ i: Int) -> CMTime { CMTime(value: CMTimeValue(i), timescale: 50) }

    private func frame(_ discs: [SyntheticFrames.Disc], background: UInt8 = 40) -> CVPixelBuffer {
        SyntheticFrames.make420v(width: width, height: height, background: background, discs: discs)
    }

    private func pixels(_ c: BallObservation) -> CGPoint {
        CGPoint(x: c.center.x * Double(width), y: c.center.y * Double(height))
    }

    private func distance(_ c: BallObservation, to p: CGPoint) -> Double {
        hypot(pixels(c).x - p.x, pixels(c).y - p.y)
    }

    @Test("first frame yields nothing; a moving disc yields the disc (best) plus its departing ghost")
    func movingDisc() throws {
        let detector = MotionCandidateDetector()
        let from = CGPoint(x: 100, y: 180), to = CGPoint(x: 116, y: 176)
        #expect(try detector.detect(pixelBuffer: frame([.init(center: from, radius: 4, luma: 230)]), time: time(0)).isEmpty)
        let candidates = try detector.detect(pixelBuffer: frame([.init(center: to, radius: 4, luma: 230)]), time: time(1))

        // A two-frame difference lights both footprints. The one the ball arrived at
        // must rank first; the ghost it left is a legitimate but lower-confidence candidate.
        #expect(candidates.count == 2)
        let best = try #require(candidates.first)
        #expect(distance(best, to: to) < 1.5)
        #expect(best.time == time(1).seconds)
        // Radius comes from the arriving pixels (the undilated 4 px disc), not the dilated blob.
        #expect(best.radius * Double(width) > 3.0 && best.radius * Double(width) < 5.5)
        let ghost = candidates[1]
        #expect(distance(ghost, to: from) < 1.5)
        #expect(ghost.confidence < best.confidence)
    }

    @Test("a static bright disc produces no candidates")
    func staticDisc() throws {
        let detector = MotionCandidateDetector()
        let f = frame([.init(center: CGPoint(x: 300, y: 100), radius: 5, luma: 240)])
        _ = try detector.detect(pixelBuffer: f, time: time(0))
        #expect(try detector.detect(pixelBuffer: f, time: time(1)).isEmpty)
    }

    @Test("a large moving shape is rejected by the area cap")
    func largeBlobRejected() throws {
        let detector = MotionCandidateDetector()
        _ = try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 200, y: 200), radius: 60, luma: 220)]), time: time(0))
        let candidates = try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 230, y: 200), radius: 60, luma: 220)]), time: time(1))
        #expect(candidates.isEmpty)
    }

    @Test("a dark moving disc on a dark background is below threshold")
    func lowContrastIgnored() throws {
        let detector = MotionCandidateDetector()
        _ = try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 80)]), time: time(0))
        #expect(try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 120, y: 180), radius: 4, luma: 80)]), time: time(1)).isEmpty)
    }

    @Test("two moving discs yield a top-ranked candidate at each new position")
    func twoDiscs() throws {
        let detector = MotionCandidateDetector()
        let a1 = CGPoint(x: 100, y: 100), a2 = CGPoint(x: 118, y: 104)
        let b1 = CGPoint(x: 400, y: 250), b2 = CGPoint(x: 385, y: 262)
        _ = try detector.detect(pixelBuffer: frame([.init(center: a1, radius: 4, luma: 230), .init(center: b1, radius: 5, luma: 220)]), time: time(0))
        let candidates = try detector.detect(pixelBuffer: frame([.init(center: a2, radius: 4, luma: 230), .init(center: b2, radius: 5, luma: 220)]), time: time(1))
        #expect(candidates.count == 4)
        let top = Array(candidates.prefix(2))
        #expect(top.contains { distance($0, to: a2) < 1.5 })
        #expect(top.contains { distance($0, to: b2) < 1.5 })
    }

    @Test("a disc that overlaps its previous position yields one candidate near the new position")
    func slowDisc() throws {
        let detector = MotionCandidateDetector()
        _ = try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 200, y: 100), radius: 6, luma: 230)]), time: time(0))
        let candidates = try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 205, y: 100), radius: 6, luma: 230)]), time: time(1))
        #expect(candidates.count == 1)
        let c = try #require(candidates.first)
        // The arriving crescent leads the disc centre; stay within a radius of it.
        #expect(distance(c, to: CGPoint(x: 205, y: 100)) < 6)
    }

    @Test("candidates are capped, keeping the most ball-sized blobs")
    func capped() throws {
        var config = MotionCandidateDetector.Config()
        config.maxCandidates = 10
        let detector = MotionCandidateDetector(config: config)
        var before: [SyntheticFrames.Disc] = []
        var after: [SyntheticFrames.Disc] = []
        for i in 0..<15 {
            let y = 30.0 + Double(i) * 20
            // Ball-sized discs on the left, oversized ones on the right.
            before.append(.init(center: CGPoint(x: 60, y: y), radius: 4, luma: 230))
            after.append(.init(center: CGPoint(x: 90, y: y), radius: 4, luma: 230))
            before.append(.init(center: CGPoint(x: 400, y: y), radius: 8, luma: 230))
            after.append(.init(center: CGPoint(x: 440, y: y), radius: 8, luma: 230))
        }
        _ = try detector.detect(pixelBuffer: frame(before), time: time(0))
        let candidates = try detector.detect(pixelBuffer: frame(after), time: time(1))
        #expect(candidates.count == 10)
        // Everything kept is one of the small discs (or their ghosts), not the r=8 ones.
        #expect(candidates.allSatisfy { pixels($0).x < 200 })
    }

    @Test("reset forgets the previous frame")
    func resetForgets() throws {
        let detector = MotionCandidateDetector()
        _ = try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)]), time: time(0))
        detector.reset()
        #expect(try detector.detect(pixelBuffer: frame([.init(center: CGPoint(x: 116, y: 180), radius: 4, luma: 230)]), time: time(1)).isEmpty)
    }
}
