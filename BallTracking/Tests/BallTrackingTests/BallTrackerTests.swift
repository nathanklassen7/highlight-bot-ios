// BallTracking/Tests/BallTrackingTests/BallTrackerTests.swift
import CoreGraphics
import Testing
@testable import BallTracking

struct BallTrackerTests {
    private let dt = 1.0 / 50.0

    private func obs(_ t: Double, _ x: Double, _ y: Double, confidence: Double = 0.9) -> BallObservation {
        BallObservation(time: t, center: CGPoint(x: x, y: y), radius: 0.005, confidence: confidence)
    }

    @Test("no candidates keeps searching with nil position")
    func searching() {
        var tracker = BallTracker()
        let frame = tracker.update(time: 0, candidates: [])
        #expect(frame.state == .searching)
        #expect(frame.position == nil)
        #expect(frame.isVisible == false)
    }

    @Test("confirms after three consecutive matches and converges on a constant-velocity target")
    func confirmsAndConverges() {
        var tracker = BallTracker()
        var states: [BallTrackState] = []
        var last: BallTrackFrame?
        for i in 0..<10 {
            let t = Double(i) * dt
            let x = 0.2 + 1.0 * t   // 1.0 normalised units / s
            let frame = tracker.update(time: t, candidates: [obs(t, x, 0.5)])
            states.append(frame.state)
            last = frame
        }
        #expect(states[0] == .tentative)
        #expect(states[1] == .tentative)
        #expect(states[2] == .tracking)
        #expect(states.dropFirst(2).allSatisfy { $0 == .tracking })
        let expectedX = 0.2 + 1.0 * (9 * dt)
        #expect(abs((last?.position?.x ?? 0) - expectedX) < 0.01)
        #expect(abs((last?.velocity?.dx ?? 0) - 1.0) < 0.25)
    }

    @Test("coasts through misses, then gives up after maxMisses")
    func coastsThenDrops() {
        var config = BallTrackerConfig()
        config.maxMisses = 3
        var tracker = BallTracker(config: config)
        var t = 0.0
        for _ in 0..<4 {
            _ = tracker.update(time: t, candidates: [obs(t, 0.3 + t, 0.5)])
            t += dt
        }
        let c1 = tracker.update(time: t, candidates: []); t += dt
        #expect(c1.state == .coasting)
        #expect(c1.isVisible)
        // Predicted position keeps moving at the estimated velocity.
        #expect((c1.position?.x ?? 0) > 0.3 + 3 * dt)
        _ = tracker.update(time: t, candidates: []); t += dt
        _ = tracker.update(time: t, candidates: []); t += dt
        let dropped = tracker.update(time: t, candidates: [])
        #expect(dropped.state == .searching)
    }

    @Test("survives an abrupt direction reversal (a hit)")
    func survivesReversal() {
        var tracker = BallTracker()
        var t = 0.0
        var x = 0.3
        var states: [BallTrackState] = []
        for i in 0..<20 {
            let vx = i < 10 ? 1.2 : -1.2
            x += vx * dt
            states.append(tracker.update(time: t, candidates: [obs(t, x, 0.5)]).state)
            t += dt
        }
        #expect(!states.dropFirst(3).contains(.searching))
        #expect(states.last == .tracking)
    }

    @Test("ignores a far-away spurious candidate while tracking")
    func ignoresOutlier() {
        var tracker = BallTracker()
        var t = 0.0
        for _ in 0..<5 {
            _ = tracker.update(time: t, candidates: [obs(t, 0.4 + 0.5 * t, 0.5)])
            t += dt
        }
        let truthX = 0.4 + 0.5 * t
        let frame = tracker.update(time: t, candidates: [obs(t, truthX, 0.5), obs(t, 0.9, 0.1, confidence: 1.0)])
        #expect(frame.state == .tracking)
        #expect(abs((frame.position?.x ?? 0) - truthX) < 0.01)
    }

    @Test("a tentative track dies on its first miss")
    func tentativeDies() {
        var tracker = BallTracker()
        _ = tracker.update(time: 0, candidates: [obs(0, 0.5, 0.5)])
        let frame = tracker.update(time: dt, candidates: [])
        #expect(frame.state == .searching)
    }

    @Test("a time gap larger than maxGap resets the track")
    func gapResets() {
        var tracker = BallTracker()
        var t = 0.0
        for _ in 0..<5 {
            _ = tracker.update(time: t, candidates: [obs(t, 0.5, 0.5)])
            t += dt
        }
        let frame = tracker.update(time: t + 2.0, candidates: [])
        #expect(frame.state == .searching)
    }
}
