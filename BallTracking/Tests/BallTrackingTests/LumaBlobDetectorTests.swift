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
