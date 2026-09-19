import CoreGraphics
import Foundation
import Testing
@testable import BallTracking

struct TrajectoryFitterTests {
    private let size = CGSize(width: 1920, height: 1080)
    private let dt = 0.02

    /// Deterministic noise so failures reproduce.
    private struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    private func observation(_ x: Double, _ y: Double, t: Double, confidence: Double = 0.8, radius: Double = 6) -> BallObservation {
        BallObservation(time: t, center: CGPoint(x: x / size.width, y: y / size.height), radius: radius / size.width, confidence: confidence)
    }

    private func noise(_ n: Int, t: Double, rng: inout LCG) -> [BallObservation] {
        (0..<n).map { _ in observation(rng.next() * size.width, rng.next() * size.height, t: t, confidence: 0.3 + 0.5 * rng.next()) }
    }

    private func pixels(_ p: CGPoint?) -> CGPoint? {
        p.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
    }

    /// x = 300 + 1500 t, y = 500 − 800 t + 2000 t²  (px, seconds): ~1.7 kpx/s, e = 2000.
    private func parabola(_ t: Double) -> CGPoint {
        CGPoint(x: 300 + 1500 * t, y: 500 - 800 * t + 2000 * t * t)
    }

    @Test("a parabola among 20 noise points per frame is tracked and its parameters recovered")
    func recoversParabola() {
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 42)
        var frames: [BallTrackFrame] = []
        for i in 0..<12 {
            let t = Double(i) * dt
            let p = parabola(t)
            var candidates = noise(20, t: t, rng: &rng)
            candidates.insert(observation(p.x, p.y, t: t), at: Int(rng.next() * Double(candidates.count)))
            frames.append(fitter.update(time: t, candidates: candidates))
        }
        let last = frames.last!
        #expect(last.state == .tracking)
        let reported = pixels(last.position)!
        let truth = parabola(11 * dt)
        #expect(hypot(reported.x - truth.x, reported.y - truth.y) < 3)

        let model = fitter.currentModel!
        #expect(abs(model.b - 1500) < 75)
        #expect(abs(model.e - 2000) < 400)
        // Velocity is reported in normalised units per second.
        let v = last.velocity!
        #expect(abs(v.dx * size.width - 1500) < 100)
        #expect(abs(v.dy * size.height - (-800 + 2 * 2000 * 11 * dt)) < 150)
        // Tracking must begin once six frames of support exist, not before frame 0..4.
        #expect(frames.prefix(5).allSatisfy { $0.state == .searching })
        #expect(frames[6].state == .tracking)
    }

    @Test("a level mover with no gravity is not a ball (a walking player's edge)")
    func levelMoverRejected() {
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 7)
        var last: BallTrackFrame?
        for i in 0..<16 {
            let t = Double(i) * dt
            var candidates = noise(20, t: t, rng: &rng)
            candidates.append(observation(200 + 300 * t, 600, t: t))
            last = fitter.update(time: t, candidates: candidates)
        }
        #expect(last?.state == .searching)
        #expect(fitter.currentModel == nil)
    }

    @Test("a flight slowing in x (perspective, drag) is tracked and its x-acceleration recovered")
    func deceleratingFlight() {
        // Measured on the reference clip: x from 23 px/frame to 7 px/frame over 14 frames.
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 21)
        var last: BallTrackFrame?
        for i in 0..<12 {
            let t = Double(i) * dt
            var candidates = noise(20, t: t, rng: &rng)
            candidates.append(observation(800 + 1200 * t - 1800 * t * t, 540 - 500 * t + 1600 * t * t, t: t))
            last = fitter.update(time: t, candidates: candidates)
        }
        #expect(last?.state == .tracking)
        let model = fitter.currentModel!
        #expect(abs(model.f - (-1800)) < 500)
        #expect(abs(model.e - 1600) < 400)
    }

    @Test("a model that hops between scattered points inside the inlier radius is rejected by residual")
    func scatteredHopsRejected() {
        // A parabola with ±6 px jitter on every point: within the 8 px radius, but a
        // real ball's centroids scatter by ~1–2 px, so this is fragment hopping.
        var fitter = TrajectoryFitter(imageSize: size)
        var tracked = 0
        for i in 0..<16 {
            let t = Double(i) * dt
            let p = parabola(t)
            // Zigzag: no smooth curve passes within ~3 px of every point.
            let jx = i % 2 == 0 ? 6.0 : -6.0, jy = (i / 2) % 2 == 0 ? 6.0 : -6.0
            let frame = fitter.update(time: t, candidates: [observation(p.x + jx, p.y + jy, t: t)])
            if frame.state == .tracking { tracked += 1 }
        }
        #expect(tracked == 0)
    }

    @Test("noise alone never produces a track")
    func noiseOnly() {
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 99)
        for i in 0..<40 {
            let t = Double(i) * dt
            let frame = fitter.update(time: t, candidates: noise(45, t: t, rng: &rng))
            #expect(frame.state == .searching, "frame \(i)")
            #expect(frame.position == nil)
            #expect(frame.candidateCount == 45)
        }
        #expect(fitter.segments.isEmpty)
    }

    @Test("a reversal in x at frame 8 yields two segments joined by a hit")
    func hitMakesTwoSegments() {
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 3)
        var states: [BallTrackState] = []
        for i in 0..<24 {
            let t = Double(i) * dt
            let p: CGPoint
            if i < 8 {
                p = CGPoint(x: 400 + 1800 * t, y: 500 - 600 * t + 2000 * t * t)
            } else {
                let u = t - 8 * dt
                let hit = CGPoint(x: 400 + 1800 * 8 * dt, y: 500 - 600 * 8 * dt + 2000 * pow(8 * dt, 2))
                p = CGPoint(x: hit.x - 1600 * u, y: hit.y - 900 * u + 2000 * u * u)
            }
            var candidates = noise(20, t: t, rng: &rng)
            candidates.append(observation(p.x, p.y, t: t))
            states.append(fitter.update(time: t, candidates: candidates).state)
        }
        #expect(states[7] == .tracking)
        #expect(states.last == .tracking)
        // The new flight has six points by frame 13; allow a little slack.
        #expect(states[15] == .tracking)
        #expect(fitter.segments.count + (fitter.currentModel == nil ? 0 : 1) >= 2)
        #expect(fitter.segments.contains { $0.breakKind == .hit } || fitter.segments.last?.breakKind == .hit)
        #expect(fitter.currentModel!.b < 0)
    }

    @Test("missing candidates for two frames coast, then tracking resumes")
    func coasts() {
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 11)
        var states: [BallTrackState] = []
        var positions: [CGPoint?] = []
        for i in 0..<16 {
            let t = Double(i) * dt
            var candidates = noise(20, t: t, rng: &rng)
            if i != 9 && i != 10 {
                let p = parabola(t)
                candidates.append(observation(p.x, p.y, t: t))
            }
            let frame = fitter.update(time: t, candidates: candidates)
            states.append(frame.state)
            positions.append(pixels(frame.position))
        }
        #expect(states[8] == .tracking)
        #expect(states[9] == .coasting)
        #expect(states[10] == .coasting)
        #expect(states[11] == .tracking)
        #expect(states[15] == .tracking)
        let coasted = positions[9]!, truth = parabola(9 * dt)
        #expect(hypot(coasted.x - truth.x, coasted.y - truth.y) < 8)
    }

    @Test("after the ball vanishes the track is dropped within the coast limit")
    func dropsAfterCoastLimit() {
        var fitter = TrajectoryFitter(imageSize: size)
        var rng = LCG(state: 5)
        var states: [BallTrackState] = []
        for i in 0..<20 {
            let t = Double(i) * dt
            var candidates = noise(20, t: t, rng: &rng)
            if i < 10 {
                let p = parabola(t)
                candidates.append(observation(p.x, p.y, t: t))
            }
            states.append(fitter.update(time: t, candidates: candidates).state)
        }
        #expect(states[9] == .tracking)
        #expect(states[10] == .coasting)
        #expect(states[13] == .searching)
        #expect(states[19] == .searching)
        #expect(fitter.currentModel == nil)
        #expect(fitter.segments.count == 1)
        #expect(fitter.segments[0].breakKind == .lost)
    }

    @Test("an implausibly slow drift is not a track")
    func slowDriftRejected() {
        var fitter = TrajectoryFitter(imageSize: size)
        var last: BallTrackFrame?
        for i in 0..<12 {
            let t = Double(i) * dt
            // 50 px/s: a hand, not a ball.
            last = fitter.update(time: t, candidates: [observation(500 + 50 * t, 400, t: t)])
        }
        #expect(last?.state == .searching)
    }

    @Test("a time gap resets the fitter")
    func gapResets() {
        var fitter = TrajectoryFitter(imageSize: size)
        for i in 0..<10 {
            let t = Double(i) * dt
            let p = parabola(t)
            _ = fitter.update(time: t, candidates: [observation(p.x, p.y, t: t)])
        }
        #expect(fitter.currentModel != nil)
        let frame = fitter.update(time: 5.0, candidates: [])
        #expect(frame.state == .searching)
        #expect(fitter.currentModel == nil)
    }
}
