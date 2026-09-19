import CoreGraphics
import Foundation

/// One flight of the ball in image space: `x(t) = a + b·τ + f·τ²`,
/// `y(t) = c + d·τ + e·τ²`, `τ = t − t0`. Units are pixels and seconds. `e` is
/// half the apparent gravity and is always positive for a ball in flight; `f`
/// absorbs perspective (a ball flying away from the camera slows in the image)
/// and drag, both of which are large for a 2.7 g ball on wide-angle footage.
public struct TrajectoryModel: Sendable, Equatable, Codable {
    public var t0: TimeInterval
    public var a: Double, b: Double, f: Double
    public var c: Double, d: Double, e: Double

    public func position(at t: TimeInterval) -> CGPoint {
        let tau = t - t0
        return CGPoint(x: a + b * tau + f * tau * tau, y: c + d * tau + e * tau * tau)
    }

    public func velocity(at t: TimeInterval) -> CGVector {
        let tau = t - t0
        return CGVector(dx: b + 2 * f * tau, dy: d + 2 * e * tau)
    }
}

/// A completed flight, closed when its model stopped matching candidates.
public struct TrajectorySegment: Sendable, Equatable, Codable {
    public enum BreakKind: String, Sendable, Codable {
        /// The next flight started within a few frames with the horizontal velocity reversed.
        case hit
        /// The next flight started within a few frames going up where this one was going down.
        case bounce
        /// The next flight started within a few frames but neither sign flipped.
        case redirect
        /// No flight followed within the coast limit.
        case lost
    }

    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var model: TrajectoryModel
    public var inlierCount: Int
    public var breakKind: BreakKind
    /// Acceptance statistics of the fit that started this flight, for tuning.
    public var meanConfidence: Double
    public var meanClutter: Double
    public var rms: Double
}

public struct TrajectoryFitterConfig: Sendable, Equatable {
    /// Frames of candidates kept for fitting.
    public var windowFrames = 12
    /// A candidate within this many pixels of the model at its own timestamp is an inlier.
    /// The ball's centroids scatter ≤ 3.5 px about a fitted flight on the reference clip.
    public var inlierRadius = 6.0
    /// Inliers (at most one per frame) needed to accept a model.
    public var minInliers = 6
    /// Of those, this many must be in consecutive frames ending at the current one. A
    /// ball in flight is in every frame; fragments of a moving player are not, and six
    /// inliers cherry-picked from twelve frames with six free parameters is otherwise
    /// easy to find among ~45 candidates per frame.
    public var minConsecutive = 5
    /// Largest/smallest candidate radius across the support. The ball's radius varies
    /// ~1.5× with blur and merged lobes; player fragments span 5× or more.
    public var maxRadiusRatio = 3.0
    /// Mean candidate confidence over the support. The detector's confidence folds in
    /// compactness, arrival, local contrast and chroma as soft weights; along real
    /// flights on the reference clip it averages ~0.35–0.4, under false tracks on
    /// players 0.05–0.27, and a departing-ghost flight ≤ 0.1. Per frame these scores
    /// are unreliable; averaged over a flight they are decisive.
    public var minMeanConfidence = 0.28
    /// A ball flies through empty space. Mean number of *other* candidates within
    /// `clutterRadius` of each inlier: the ball sees 0–1 (its departing ghost), a
    /// trajectory threaded through a player's fragments sees 3–4.
    public var maxMeanClutter = 1.5
    public var clutterRadius = 30.0
    /// Plausible image-space speed at the current time, px/s.
    public var minSpeed = 200.0
    public var maxSpeed = 4000.0
    /// Plausible band for `e` (half the apparent vertical acceleration), px/s². Gravity
    /// drops a ball ~0.28 m over a 12-frame window whatever its speed, which is 50+ px
    /// anywhere on 1080p footage of a table, so a flight always shows positive `e`; a
    /// walking player's edge, which can otherwise mimic a slow straight ball, does not.
    /// Measured on the reference clip: 1000–1800. The upper end covers a near ball.
    public var gravityRange: ClosedRange<Double> = 300...8000
    /// Bound on |f|, the horizontal acceleration term. Measured up to ~2000 on the clip.
    public var maxHorizontalAcceleration = 6000.0
    /// RMS distance of the support from the model, px. A real ball fits within ~2 px;
    /// a model hopping between player fragments inside `inlierRadius` scatters to ~5.
    public var maxResidualRMS = 3.0
    /// Frames the model may predict through without an inlier before the track is dropped.
    public var maxCoastFrames = 3
    /// A gap between frames longer than this restarts the fitter (seek, source change).
    public var maxGap: TimeInterval = 0.5
    /// Hypotheses evaluated per RANSAC run, an upper bound on cost in busy frames.
    public var maxHypotheses = 6000

    public init() {}
    public static let `default` = TrajectoryFitterConfig()
}

/// Picks the ball out of per-frame motion candidates by how it moves: over a sliding
/// window it searches (guided RANSAC) for a parabola that passes within
/// `inlierRadius` of a candidate in at least `minInliers` frames. Once a model holds
/// it is kept and refined frame to frame; RANSAC runs again only when the current
/// frame has no inlier. Replaces `BallTracker`'s association for the motion
/// detector while producing the same `BallTrackFrame`.
///
/// Positions in and out are normalised (0…1, top-left origin); internally the fitter
/// works in pixels of `imageSize` so thresholds are physical.
public struct TrajectoryFitter: Sendable {
    public let config: TrajectoryFitterConfig
    public let imageSize: CGSize

    /// The flight currently being tracked, if any.
    public private(set) var currentModel: TrajectoryModel?
    /// Completed flights, oldest first. A `.hit`/`.bounce` break is the seed of rally detection.
    public private(set) var segments: [TrajectorySegment] = []

    private struct Point {
        var x: Double, y: Double
        var radius: Double
        var confidence: Double
    }

    private struct Frame {
        var time: TimeInterval
        var points: [Point]
    }

    private struct Fit {
        var model: TrajectoryModel
        var inliers: [(frame: Int, point: Int)]
        var score: Double
        var meanConfidence: Double
        var meanClutter: Double
        var rms: Double
    }

    private struct Support {
        var inliers: [(frame: Int, point: Int)]
        var rms: Double
        var count: Int { inliers.count }
        func contains(frame: Int) -> Bool { inliers.contains { $0.frame == frame } }

        /// Inlier frames counting back from `anchor` without a gap.
        func consecutive(endingAt anchor: Int) -> Int {
            var run = 0
            while contains(frame: anchor - run) { run += 1 }
            return run
        }
    }

    private func meanConfidence(_ inliers: [(frame: Int, point: Int)]) -> Double {
        guard !inliers.isEmpty else { return 0 }
        return inliers.reduce(0.0) { $0 + window[$1.frame].points[$1.point].confidence } / Double(inliers.count)
    }

    /// Mean count of other candidates within `clutterRadius` of each inlier, in its frame.
    private func meanClutter(_ inliers: [(frame: Int, point: Int)]) -> Double {
        guard !inliers.isEmpty else { return 0 }
        let r2 = config.clutterRadius * config.clutterRadius
        var total = 0
        for (f, p) in inliers {
            let frame = window[f]
            let center = frame.points[p]
            for (i, other) in frame.points.enumerated() where i != p {
                let dx = other.x - center.x, dy = other.y - center.y
                if dx * dx + dy * dy <= r2 { total += 1 }
            }
        }
        return Double(total) / Double(inliers.count)
    }

    private func radiusRatio(_ inliers: [(frame: Int, point: Int)]) -> Double {
        var lo = Double.infinity, hi = 0.0
        for (f, p) in inliers {
            let r = window[f].points[p].radius
            lo = min(lo, r); hi = max(hi, r)
        }
        return lo > 0 ? hi / lo : .infinity
    }

    private var window: [Frame] = []
    private var lastTime: TimeInterval?
    private var misses = 0
    private var currentStart: TimeInterval = 0
    private var currentInlierCount = 0
    private var currentFitStats = (meanConfidence: 0.0, meanClutter: 0.0, rms: 0.0)
    /// Time and pixel position of the last candidate the current (or last) model matched.
    private var lastMatchTime: TimeInterval = 0
    private var lastMatchPoint: CGPoint?
    private var lastRadius = 0.0
    private var state: BallTrackState = .searching

    public init(config: TrajectoryFitterConfig = .default, imageSize: CGSize) {
        self.config = config
        self.imageSize = imageSize
    }

    public mutating func reset() {
        if let model = currentModel {
            close(model, kind: .lost)
        }
        window.removeAll(keepingCapacity: true)
        lastTime = nil
        lastMatchPoint = nil
        misses = 0
        state = .searching
        currentModel = nil
    }

    public mutating func update(time: TimeInterval, candidates: [BallObservation]) -> BallTrackFrame {
        if let last = lastTime, time < last || time - last > config.maxGap {
            reset()
        }
        lastTime = time

        let w = imageSize.width, h = imageSize.height
        let points = candidates.map {
            Point(x: $0.center.x * w, y: $0.center.y * h, radius: $0.radius * w, confidence: $0.confidence)
        }
        window.append(Frame(time: time, points: points))
        if window.count > config.windowFrames {
            window.removeFirst(window.count - config.windowFrames)
        }
        let current = window.count - 1

        var matched: Point?
        if let model = currentModel {
            if let index = inlier(of: model, in: window[current]) {
                // The flight continues: refine on everything it explains in the window,
                // keeping the old model if the refit stops looking like a ball.
                matched = window[current].points[index]
                let support = self.support(of: model)
                if support.count >= 4, let refined = leastSquares(support.inliers, quadraticX: true),
                   passesPlausibility(refined, at: time), self.support(of: refined).rms <= config.maxResidualRMS {
                    currentModel = refined
                }
                currentInlierCount = support.count
                lastMatchTime = time
                lastMatchPoint = CGPoint(x: matched!.x, y: matched!.y)
                misses = 0
                state = .tracking
            } else if let fit = ransac(anchoredAt: current, continuingFrom: reachableRegion(at: time)) {
                // The ball changed course; a new flight explains the recent frames better
                // and is where the ball could have got to since it was last seen.
                let newStart = window[fit.inliers.map(\.frame).min()!].time
                close(model, kind: breakKind(from: model, to: fit.model, at: newStart))
                let point = window[current].points[fit.inliers.last(where: { $0.frame == current })!.point]
                adopt(fit, start: newStart, time: time, point: point)
                matched = point
                state = .tracking
            } else {
                misses += 1
                if misses > config.maxCoastFrames {
                    close(model, kind: .lost)
                    currentModel = nil
                    state = .searching
                } else {
                    state = .coasting
                }
            }
        }

        if currentModel == nil {
            // Shortly after a loss the ball must still be within reach of where it was
            // last seen; after that it may reappear anywhere (new point, new serve).
            let recentlyLost = time - lastMatchTime <= Self.reacquireWindow
            if let fit = ransac(anchoredAt: current, continuingFrom: recentlyLost ? reachableRegion(at: time) : nil) {
                let start = window[fit.inliers.map(\.frame).min()!].time
                // A flight found right after one was lost is the same ball changing course:
                // relabel the break now that the new direction is known.
                if let index = segments.indices.last, segments[index].breakKind == .lost,
                   start - segments[index].endTime <= Self.reacquireWindow {
                    segments[index].breakKind = breakKind(from: segments[index].model, to: fit.model, at: start)
                }
                let point = window[current].points[fit.inliers.last(where: { $0.frame == current })!.point]
                adopt(fit, start: start, time: time, point: point)
                matched = point
                state = .tracking
            }
        }

        if let matched { lastRadius = matched.radius }
        return makeFrame(time: time, matched: matched, candidateCount: candidates.count)
    }

    // MARK: - Output

    private func makeFrame(time: TimeInterval, matched: Point?, candidateCount: Int) -> BallTrackFrame {
        guard let model = currentModel, state != .searching else {
            return BallTrackFrame(time: time, state: .searching, position: nil, velocity: nil, radius: nil, candidateCount: candidateCount)
        }
        let w = imageSize.width, h = imageSize.height
        let position: CGPoint
        if let matched {
            position = CGPoint(x: matched.x / w, y: matched.y / h)
        } else {
            let predicted = model.position(at: time)
            position = CGPoint(x: predicted.x / w, y: predicted.y / h)
        }
        let v = model.velocity(at: time)
        return BallTrackFrame(time: time,
                              state: state,
                              position: position,
                              velocity: CGVector(dx: v.dx / w, dy: v.dy / h),
                              radius: lastRadius / w,
                              candidateCount: candidateCount)
    }

    /// A new flight starting within this long of the previous one's last match is
    /// treated as the same ball changing course rather than a new appearance.
    private static let reacquireWindow: TimeInterval = 0.15

    private mutating func adopt(_ fit: Fit, start: TimeInterval, time: TimeInterval, point: Point) {
        currentModel = fit.model
        currentStart = start
        currentInlierCount = fit.inliers.count
        currentFitStats = (fit.meanConfidence, fit.meanClutter, fit.rms)
        lastMatchTime = time
        lastMatchPoint = CGPoint(x: point.x, y: point.y)
        misses = 0
    }

    /// Where the ball can be at `time` given where and when it was last seen: a disc of
    /// radius `maxSpeed · Δt` (plus tolerance) around the last match. A hit reverses the
    /// ball; it does not teleport it, which is what a model switch across the frame
    /// would claim.
    private func reachableRegion(at time: TimeInterval) -> (center: CGPoint, radius: Double)? {
        guard let point = lastMatchPoint else { return nil }
        let dt = max(0, time - lastMatchTime)
        return (point, config.maxSpeed * dt + 2 * config.inlierRadius)
    }

    private mutating func close(_ model: TrajectoryModel, kind: TrajectorySegment.BreakKind) {
        segments.append(TrajectorySegment(startTime: currentStart, endTime: lastMatchTime, model: model,
                                          inlierCount: currentInlierCount, breakKind: kind,
                                          meanConfidence: currentFitStats.meanConfidence,
                                          meanClutter: currentFitStats.meanClutter, rms: currentFitStats.rms))
    }

    private func breakKind(from old: TrajectoryModel, to new: TrajectoryModel, at time: TimeInterval) -> TrajectorySegment.BreakKind {
        let vOld = old.velocity(at: time), vNew = new.velocity(at: time)
        if (vOld.dx > 0) != (vNew.dx > 0) { return .hit }
        if vOld.dy > 0, vNew.dy < 0 { return .bounce }
        return .redirect
    }

    // MARK: - Association

    /// Index of the candidate nearest the model at the frame's time, if within `inlierRadius`.
    private func inlier(of model: TrajectoryModel, in frame: Frame) -> Int? {
        let predicted = model.position(at: frame.time)
        var best: Int?
        var bestDistance = config.inlierRadius
        for (i, p) in frame.points.enumerated() {
            let d = hypot(p.x - predicted.x, p.y - predicted.y)
            if d <= bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    private func support(of model: TrajectoryModel) -> Support {
        var result: [(frame: Int, point: Int)] = []
        var sumSquares = 0.0
        for (f, frame) in window.enumerated() {
            if let p = inlier(of: model, in: frame) {
                result.append((f, p))
                let predicted = model.position(at: frame.time)
                let pt = frame.points[p]
                let dx = pt.x - predicted.x, dy = pt.y - predicted.y
                sumSquares += dx * dx + dy * dy
            }
        }
        return Support(inliers: result, rms: result.isEmpty ? 0 : (sumSquares / Double(result.count)).squareRoot())
    }

    private func score(_ inliers: [(frame: Int, point: Int)]) -> Double {
        // Count first; confidence breaks ties so a departing-ghost trajectory (same
        // shape, one frame late, lower confidence) loses to the ball's own.
        inliers.reduce(0.0) { $0 + 1 + window[$1.frame].points[$1.point].confidence }
    }

    // MARK: - RANSAC

    /// Searches for a flight that has an inlier in frame `anchor` (the current frame),
    /// so a new model is always tied to something visible now. Guided sampling: the
    /// anchor candidate A, a candidate B one to three frames earlier at a plausible
    /// speed, and a candidate C at least three frames before B inside the cone a
    /// plausible acceleration allows. Every surviving triple is fitted and scored.
    /// `continuingFrom` restricts anchors to a disc the ball could have reached.
    private func ransac(anchoredAt anchor: Int, continuingFrom region: (center: CGPoint, radius: Double)? = nil) -> Fit? {
        guard window.count >= config.minInliers, !window[anchor].points.isEmpty else { return nil }
        let tA = window[anchor].time
        var best: Fit?
        var hypotheses = 0
        let maxAccelY = 2 * config.gravityRange.upperBound
        let maxAccelX = 2 * config.maxHorizontalAcceleration
        let r = config.inlierRadius

        // Candidates arrive sorted by confidence, so the most ball-like anchors are tried
        // first and the hypothesis cap, if it binds, cuts the least promising ones.
        search: for (ia, A) in window[anchor].points.enumerated() {
            if let region, hypot(A.x - region.center.x, A.y - region.center.y) > region.radius { continue }
            for fb in stride(from: anchor - 1, through: max(0, anchor - 3), by: -1) {
                let tB = window[fb].time
                let dtAB = tA - tB
                guard dtAB > 0 else { continue }
                for (ib, B) in window[fb].points.enumerated() {
                    let vx = (A.x - B.x) / dtAB, vy = (A.y - B.y) / dtAB
                    let speed = hypot(vx, vy)
                    guard speed >= config.minSpeed, speed <= config.maxSpeed else { continue }

                    // Stage 1: loose inliers of the constant-velocity line through A and B,
                    // one per earlier frame, with room for the velocity estimate's error
                    // and for the largest plausible acceleration on each axis.
                    var loose: [(frame: Int, point: Int)] = []
                    for fc in stride(from: fb - 1, through: 0, by: -1) {
                        let tC = window[fc].time
                        let span = tA - tC
                        let px = B.x - vx * (tB - tC), py = B.y - vy * (tB - tC)
                        let linear = r * (1 + span / dtAB)
                        let allowX = linear + 0.5 * maxAccelX * span * span
                        let allowY = linear + 0.5 * maxAccelY * span * span
                        var bestIndex: Int?
                        var bestDistance = Double.infinity
                        for (ic, C) in window[fc].points.enumerated() {
                            let dx = abs(C.x - px), dy = abs(C.y - py)
                            guard dx <= allowX, dy <= allowY else { continue }
                            let d = dx / allowX + dy / allowY
                            if d < bestDistance { bestDistance = d; bestIndex = ic }
                        }
                        if let bestIndex { loose.append((fc, bestIndex)) }
                    }
                    // A and B count too; the parabola needs `minInliers` in total.
                    guard loose.count + 2 >= config.minInliers else { continue }

                    // Stage 2: exact fits through A, B and a third point at least three
                    // frames before B, trying the farthest few for conditioning.
                    for C in loose.filter({ fb - $0.frame >= 3 }).suffix(3) {
                        hypotheses += 1
                        guard hypotheses <= config.maxHypotheses else { break search }
                        // Seed with linear x: three points over a short span constrain a
                        // line well; the quadratic terms come from the refit on the support.
                        guard let seed = leastSquares([(anchor, ia), (fb, ib), C], quadraticX: false),
                              passesPlausibility(seed, at: tA, checkAcceleration: false) else { continue }
                        var model = seed
                        var support = self.support(of: seed)
                        guard support.count >= 4, support.contains(frame: anchor) else { continue }
                        // Local optimisation: refit on the support while it keeps growing.
                        for _ in 0..<4 {
                            guard let refined = leastSquares(support.inliers, quadraticX: true),
                                  passesPlausibility(refined, at: tA) else { break }
                            let refinedSupport = self.support(of: refined)
                            guard refinedSupport.count >= support.count, refinedSupport.contains(frame: anchor) else { break }
                            let grew = refinedSupport.count > support.count
                            model = refined
                            support = refinedSupport
                            if !grew { break }
                        }
                        // The seed skipped the acceleration check; whatever survived must pass it.
                        guard support.count >= config.minInliers,
                              support.consecutive(endingAt: anchor) >= config.minConsecutive,
                              support.rms <= config.maxResidualRMS,
                              radiusRatio(support.inliers) <= config.maxRadiusRatio,
                              passesPlausibility(model, at: tA) else { continue }
                        let confidence = meanConfidence(support.inliers)
                        let clutter = meanClutter(support.inliers)
                        guard confidence >= config.minMeanConfidence, clutter <= config.maxMeanClutter else { continue }
                        let s = score(support.inliers)
                        if best == nil || s > best!.score {
                            best = Fit(model: model, inliers: support.inliers, score: s,
                                       meanConfidence: confidence, meanClutter: clutter, rms: support.rms)
                        }
                    }
                }
            }
        }
        return best
    }

    /// `checkAcceleration` is off for three-point seeds over a short span, whose
    /// curvature terms are too noisy to judge; the refit on the support is judged fully.
    private func passesPlausibility(_ model: TrajectoryModel, at time: TimeInterval, checkAcceleration: Bool = true) -> Bool {
        guard model.a.isFinite, model.c.isFinite else { return false }
        if checkAcceleration {
            guard config.gravityRange.contains(model.e), abs(model.f) <= config.maxHorizontalAcceleration else { return false }
        }
        let v = model.velocity(at: time)
        let speed = hypot(v.dx, v.dy)
        return speed >= config.minSpeed && speed <= config.maxSpeed
    }

    // MARK: - Least squares

    /// Fits the model to the given window points, `τ` measured from the earliest of
    /// them. `y` is always quadratic; `x` is linear unless `quadraticX`. Needs ≥ 3
    /// points at ≥ 3 distinct times.
    private func leastSquares(_ samples: [(frame: Int, point: Int)], quadraticX: Bool) -> TrajectoryModel? {
        guard samples.count >= 3 else { return nil }
        let t0 = samples.map { window[$0.frame].time }.min()!
        var n = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0, s4 = 0.0
        var sx = 0.0, stx = 0.0, st2x = 0.0
        var sy = 0.0, sty = 0.0, st2y = 0.0
        for (f, p) in samples {
            let tau = window[f].time - t0
            let pt = window[f].points[p]
            let t2 = tau * tau
            n += 1; s1 += tau; s2 += t2; s3 += t2 * tau; s4 += t2 * t2
            sx += pt.x; stx += tau * pt.x; st2x += t2 * pt.x
            sy += pt.y; sty += tau * pt.y; st2y += t2 * pt.y
        }
        let m = [[n, s1, s2], [s1, s2, s3], [s2, s3, s4]]
        let det = det3(m)
        guard abs(det) > 1e-12 else { return nil }
        func solve(_ rhs: [Double]) -> (Double, Double, Double) {
            func replaced(_ column: Int) -> [[Double]] {
                var r = m
                for row in 0..<3 { r[row][column] = rhs[row] }
                return r
            }
            return (det3(replaced(0)) / det, det3(replaced(1)) / det, det3(replaced(2)) / det)
        }
        let (c, d, e) = solve([sy, sty, st2y])
        let a: Double, b: Double, f: Double
        if quadraticX {
            (a, b, f) = solve([sx, stx, st2x])
        } else {
            let detX = n * s2 - s1 * s1
            guard abs(detX) > 1e-12 else { return nil }
            a = (sx * s2 - s1 * stx) / detX
            b = (n * stx - s1 * sx) / detX
            f = 0
        }
        return TrajectoryModel(t0: t0, a: a, b: b, f: f, c: c, d: d, e: e)
    }

    private func det3(_ m: [[Double]]) -> Double {
        m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
    }
}
