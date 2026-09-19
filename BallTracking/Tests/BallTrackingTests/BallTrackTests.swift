import CoreGraphics
import Foundation
import Testing
@testable import BallTracking

struct BallTrackTests {
    private func frame(_ t: Double, _ state: BallTrackState, x: Double = 0.5) -> BallTrackFrame {
        BallTrackFrame(time: t, state: state,
                       position: state == .searching ? nil : CGPoint(x: x, y: 0.5),
                       velocity: state == .searching ? nil : CGVector(dx: 1, dy: 0),
                       radius: state == .searching ? nil : 0.005, candidateCount: 1)
    }

    private var sample: BallTrack {
        BallTrack(version: BallTrack.currentVersion, detector: "luma-blob", frameRate: 50,
                  displaySize: CGSize(width: 1920, height: 1080),
                  frames: [
                      frame(0.00, .searching),
                      frame(0.02, .tentative, x: 0.10),
                      frame(0.04, .tentative, x: 0.12),
                      frame(0.06, .tracking, x: 0.14),
                      frame(0.08, .tracking, x: 0.16),
                      frame(0.10, .coasting, x: 0.18),
                      frame(0.12, .tracking, x: 0.20),
                      frame(0.14, .searching),
                  ])
    }

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(BallTrack.self, from: data)
        #expect(decoded == sample)
    }

    @Test("frame(at:) returns the nearest frame within 1.5 periods, else nil")
    func nearestFrame() {
        let track = sample
        #expect(track.frame(at: 0.061)?.time == 0.06)
        #expect(track.frame(at: 0.071)?.time == 0.08)
        #expect(track.frame(at: 0.139)?.time == 0.14)
        #expect(track.frame(at: 0.5) == nil)
        #expect(track.frame(at: -0.5) == nil)
    }

    @Test("trail collects tracking positions back to the last searching frame")
    func trail() {
        let trail = sample.trail(endingAt: 0.12, duration: 0.2)
        #expect(trail == [CGPoint(x: 0.14, y: 0.5), CGPoint(x: 0.16, y: 0.5), CGPoint(x: 0.20, y: 0.5)])
        #expect(sample.trail(endingAt: 0.12, duration: 0.05).count == 2)
        #expect(sample.trail(endingAt: 0.14, duration: 1).isEmpty)
    }

    @Test("tracking fraction counts only .tracking frames")
    func fraction() {
        #expect(abs(sample.trackingFraction - 3.0 / 8.0) < 0.0001)
        #expect(BallTrack(version: 1, detector: "x", frameRate: 50, displaySize: .zero, frames: []).trackingFraction == 0)
    }
}
