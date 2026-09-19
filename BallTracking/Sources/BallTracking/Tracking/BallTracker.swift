// BallTracking/Sources/BallTracking/Tracking/BallTracker.swift
import CoreGraphics
import Foundation

/// Tuning for `BallTracker`. Distances are normalised frame units; times are seconds.
public struct BallTrackerConfig: Sendable, Equatable {
    /// Fraction of the measurement residual applied to position each match (alpha).
    public var positionGain: Double = 0.6
    /// Fraction of the residual-derived velocity correction applied each match (beta).
    public var velocityGain: Double = 0.3
    /// Association radius around the predicted position, before adding `speed * dt`.
    public var gateRadius: Double = 0.05
    /// Wider radius around the last position used when the prediction fails,
    /// which is what happens at a hit or a bounce.
    public var reacquireRadius: Double = 0.15
    /// Consecutive matches needed before a tentative track becomes `.tracking`.
    public var confirmAfter: Int = 3
    /// Consecutive misses tolerated while confirmed before dropping to `.searching`.
    public var maxMisses: Int = 6
    /// Larger gaps between frames reset the track (source restarted, seek).
    public var maxGap: TimeInterval = 0.5

    public init() {}
    public static let `default` = BallTrackerConfig()
}

/// Single-target alpha-beta tracker: constant-velocity prediction, gated
/// nearest-candidate association, blended update. Value type; the owner
/// decides threading.
public struct BallTracker: Sendable {
    private let config: BallTrackerConfig
    private var state: BallTrackState = .searching
    private var position = CGPoint.zero
    private var velocity = CGVector.zero
    private var radius = 0.0
    private var hits = 0
    private var misses = 0
    private var lastTime: TimeInterval?

    public init(config: BallTrackerConfig = .default) {
        self.config = config
    }

    public mutating func reset() {
        state = .searching
        position = .zero
        velocity = .zero
        radius = 0
        hits = 0
        misses = 0
        lastTime = nil
    }

    public mutating func update(time: TimeInterval, candidates: [BallObservation]) -> BallTrackFrame {
        if let last = lastTime, time < last || time - last > config.maxGap {
            reset()
        }
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        switch state {
        case .searching:
            if let best = candidates.max(by: { $0.confidence < $1.confidence }) {
                position = best.center
                velocity = .zero
                radius = best.radius
                hits = 1
                misses = 0
                state = .tentative
            }

        case .tentative, .tracking, .coasting:
            let previous = position
            let predicted = CGPoint(x: position.x + velocity.dx * dt, y: position.y + velocity.dy * dt)
            let speed = hypot(velocity.dx, velocity.dy)
            let gate = config.gateRadius + speed * dt

            if let match = Self.nearest(candidates, to: predicted, within: gate) {
                let residual = CGVector(dx: match.center.x - predicted.x, dy: match.center.y - predicted.y)
                position = CGPoint(x: predicted.x + config.positionGain * residual.dx,
                                   y: predicted.y + config.positionGain * residual.dy)
                if dt > 0 {
                    if hits == 1 {
                        // Second sighting: bootstrap velocity from the raw displacement.
                        velocity = CGVector(dx: (match.center.x - previous.x) / dt,
                                            dy: (match.center.y - previous.y) / dt)
                    } else {
                        velocity = CGVector(dx: velocity.dx + config.velocityGain * residual.dx / dt,
                                            dy: velocity.dy + config.velocityGain * residual.dy / dt)
                    }
                }
                radius = radius * 0.7 + match.radius * 0.3
                hits += 1
                misses = 0
                state = hits >= config.confirmAfter ? .tracking : .tentative
            } else if state != .tentative, dt > 0,
                      let match = Self.nearest(candidates, to: position, within: config.reacquireRadius) {
                // The prediction overshot because the ball changed direction (hit,
                // bounce). Restart the motion model from the last known position.
                velocity = CGVector(dx: (match.center.x - position.x) / dt,
                                    dy: (match.center.y - position.y) / dt)
                position = match.center
                radius = radius * 0.7 + match.radius * 0.3
                hits += 1
                misses = 0
                state = .tracking
            } else {
                misses += 1
                if state == .tentative || misses > config.maxMisses {
                    reset()
                    lastTime = time
                } else {
                    position = predicted
                    state = .coasting
                }
            }
        }

        return makeFrame(time: time, candidateCount: candidates.count)
    }

    private func makeFrame(time: TimeInterval, candidateCount: Int) -> BallTrackFrame {
        let hasTrack = state != .searching
        return BallTrackFrame(
            time: time,
            state: state,
            position: hasTrack ? position : nil,
            velocity: hasTrack ? velocity : nil,
            radius: hasTrack ? radius : nil,
            candidateCount: candidateCount
        )
    }

    private static func nearest(_ candidates: [BallObservation], to point: CGPoint, within radius: Double) -> BallObservation? {
        var best: BallObservation?
        var bestDistance = radius
        for candidate in candidates {
            let distance = hypot(candidate.center.x - point.x, candidate.center.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}
