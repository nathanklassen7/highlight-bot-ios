import CoreGraphics
import CoreMedia
import Testing
@testable import BallTracking

struct LumaBlobDetectorTests {
    private func time(_ i: Int) -> CMTime { CMTime(value: CMTimeValue(i), timescale: 50) }

    @Test("first frame yields nothing; a moving disc yields one candidate at the disc")
    func movingDisc() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 116, y: 176), radius: 4, luma: 230)])
        #expect(try detector.detect(pixelBuffer: f0, time: time(0)).isEmpty)
        let candidates = try detector.detect(pixelBuffer: f1, time: time(1))
        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(abs(c.center.x - 116.0 / 640.0) < 0.01)
        #expect(abs(c.center.y - 176.0 / 360.0) < 0.015)
        #expect(c.radius > 0.003 && c.radius < 0.012)
        #expect(c.time == time(1).seconds)
        // The disc is chroma-neutral (Cb = Cr = 128), so the chroma filter must accept it.
        #expect(c.confidence > 0)
    }

    @Test("a moving skin-coloured blob is rejected by the chroma filter")
    func skinColouredBlobRejected() throws {
        let detector = LumaBlobDetector()
        // Lit skin measured on real footage: luma ~200, Cb ~100, Cr ~155 (deviation 28).
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 200, cb: 100, cr: 155)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [.init(center: CGPoint(x: 116, y: 176), radius: 4, luma: 200, cb: 100, cr: 155)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        let candidates = try detector.detect(pixelBuffer: f1, time: time(1))
        if !candidates.isEmpty { dump(candidates, width: 640, height: 360) }
        #expect(candidates.isEmpty)
    }

    @Test("a white blob with mild chroma (deviation 12) is still accepted")
    func mildChromaBlobAccepted() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 200, cb: 128, cr: 116)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [.init(center: CGPoint(x: 116, y: 176), radius: 4, luma: 200, cb: 128, cr: 116)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        let candidates = try detector.detect(pixelBuffer: f1, time: time(1))
        #expect(candidates.count == 1)
        if let c = candidates.first {
            #expect(abs(c.center.x - 116.0 / 640.0) < 0.01)
            #expect(abs(c.center.y - 176.0 / 360.0) < 0.01)
        }
    }

    @Test("a static bright disc produces no candidates")
    func staticDisc() throws {
        let detector = LumaBlobDetector()
        let frame = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 300, y: 100), radius: 5, luma: 240)])
        _ = try detector.detect(pixelBuffer: frame, time: time(0))
        #expect(try detector.detect(pixelBuffer: frame, time: time(1)).isEmpty)
    }

    @Test("a large moving bright shape (a shirt) is rejected by the area cap")
    func largeBlobRejected() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 200, y: 200), radius: 60, luma: 220)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 230, y: 200), radius: 60, luma: 220)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        #expect(try detector.detect(pixelBuffer: f1, time: time(1)).isEmpty)
    }

    @Test("a dark moving disc is ignored")
    func darkDiscIgnored() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, background: 120, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 20)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, background: 120, discs: [.init(center: CGPoint(x: 120, y: 180), radius: 4, luma: 20)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        #expect(try detector.detect(pixelBuffer: f1, time: time(1)).isEmpty)
    }

    @Test("a small bright blob inside a large bright region is rejected as a fragment")
    func fragmentInsideBrightRegionRejected() throws {
        let detector = LumaBlobDetector()
        let big = SyntheticFrames.Disc(center: CGPoint(x: 300, y: 180), radius: 60, luma: 200)
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, background: 40, discs: [big])
        // Brighter than the surrounding shirt, so |Δluma| = 35 ≥ minMotion: a moving,
        // ball-sized blob by the old rules, but its surround is bright (200).
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [big, .init(center: CGPoint(x: 300, y: 180), radius: 4, luma: 235)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        let candidates = try detector.detect(pixelBuffer: f1, time: time(1))
        let nearCenter = candidates.filter { hypot($0.center.x - 300.0 / 640.0, $0.center.y - 180.0 / 360.0) < 0.03 }
        if !nearCenter.isEmpty { dump(candidates, width: 640, height: 360) }
        #expect(nearCenter.isEmpty)
    }

    @Test("an isolated ball next to a moving shirt wins the ranking")
    func isolatedBallBeatsMovingShirt() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [.init(center: CGPoint(x: 200, y: 180), radius: 60, luma: 200)])
        // A 3 px shift leaves a thin bright crescent of ball-sized edge fragments.
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, background: 40,
                                          discs: [.init(center: CGPoint(x: 203, y: 180), radius: 60, luma: 200),
                                                  .init(center: CGPoint(x: 500, y: 180), radius: 4, luma: 235)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        let candidates = try detector.detect(pixelBuffer: f1, time: time(1))

        let ball = candidates.filter { hypot($0.center.x - 500.0 / 640.0, $0.center.y - 180.0 / 360.0) < 0.02 }
        let fragments = candidates.filter {
            let dx = ($0.center.x - 203.0 / 640.0) * 640.0
            let dy = ($0.center.y - 180.0 / 360.0) * 360.0
            return hypot(dx, dy) < 66 // disc radius 60 plus a little for centroid blur
        }
        if ball.isEmpty || !fragments.isEmpty || candidates.first != ball.first { dump(candidates, width: 640, height: 360) }
        #expect(!ball.isEmpty)
        #expect(candidates.first != nil && candidates.first == ball.first)
        #expect(fragments.isEmpty)
    }

    private func dump(_ candidates: [BallObservation], width: Double, height: Double) {
        print("LumaBlobDetector returned \(candidates.count) candidate(s):")
        for c in candidates {
            let px = c.center.x * width, py = c.center.y * height
            print(String(format: "  center=(%.1f, %.1f)px radius=%.1fpx confidence=%.3f", px, py, c.radius * width, c.confidence))
        }
    }

    @Test("reset forgets the previous frame")
    func resetForgets() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 116, y: 180), radius: 4, luma: 230)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        detector.reset()
        #expect(try detector.detect(pixelBuffer: f1, time: time(1)).isEmpty)
    }
}
