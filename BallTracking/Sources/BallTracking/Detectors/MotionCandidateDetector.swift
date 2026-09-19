import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Candidate stage on the approved motion mask: connected components of
/// `MotionMask`, loosely filtered by size and shape, emitted as `BallObservation`s.
/// It deliberately does **not** rank by brightness or reject by colour; the
/// trajectory stage decides which candidate is the ball by how it moves.
///
/// A two-frame difference lights both where a ball arrived and where it left. Each
/// component's centre and radius come from its *arriving* pixels (brighter now
/// than before) when there are enough of them, so a fast ball reports its current
/// position rather than the midpoint of a two-lobed blob; its departing ghost is
/// still emitted, with lower confidence, so the fitter can see it.
///
/// `@unchecked Sendable`: the mask and scratch buffers are only touched inside
/// `detect`/`reset`, which callers serialise (see `BallDetector`).
public final class MotionCandidateDetector: BallDetector, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        public var mask = MotionMask.Config()
        /// Component area bounds in full-resolution pixels, measured on the dilated mask.
        /// One moving pixel dilates to 9 px, so 20 requires a few genuine pixels; the far
        /// ball on the reference clip is ≥ ~35 px dilated, the near ball up to ~300.
        public var minArea = 20
        public var maxArea = 800
        /// Bounding-box long/short side. Streaks are allowed; walls and limbs are not.
        public var maxAspect = 4.0
        /// Kept per frame. Trimmed by area plausibility (closest to `idealArea` in log
        /// space), never by brightness. On the reference clip p90 is ~59, so this binds
        /// only on the busiest swings.
        public var maxCandidates = 60
        /// Dilated area of a typical ball blob on 1080p footage (11×7 px ball → ~100 px).
        public var idealArea = 100.0

        public init() {}
        public static let `default` = Config()
    }

    /// One component that passed the filters, in full-resolution pixels.
    public struct Blob: Sendable, Equatable {
        public var area: Int
        /// Pixels brighter than in the previous frame: where something arrived.
        public var arrivals: Int
        public var minX: Int, maxX: Int, minY: Int, maxY: Int
        public var fill: Double

        public var width: Int { maxX - minX + 1 }
        public var height: Int { maxY - minY + 1 }
    }

    public let name = "motion"
    public let config: Config
    /// The mask for the most recent frame, for drawing and debugging.
    public private(set) var mask: MotionMask
    /// Blobs behind the observations `detect` last returned, in the same order.
    public private(set) var lastBlobs: [Blob] = []

    private var visited: [UInt8] = []
    private var stack: [Int32] = []

    public init(config: Config = .default) {
        self.config = config
        mask = MotionMask(config: config.mask)
        stack.reserveCapacity(4096)
    }

    public func reset() {
        mask.reset()
        lastBlobs = []
    }

    public func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation] {
        guard mask.update(pixelBuffer: pixelBuffer) else {
            lastBlobs = []
            return []
        }
        let w = mask.width, h = mask.height
        if visited.count != w * h {
            visited = [UInt8](repeating: 0, count: w * h)
        } else {
            visited.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        }

        var scored: [(observation: BallObservation, blob: Blob, plausibility: Double)] = []
        let seconds = time.seconds
        let fw = Double(w), fh = Double(h)
        let logIdeal = log(config.idealArea)

        forEachComponent(width: w, height: h) { component in
            guard component.area >= config.minArea, component.area <= config.maxArea else { return }
            let bw = Double(component.maxX - component.minX + 1)
            let bh = Double(component.maxY - component.minY + 1)
            let aspect = max(bw, bh) / min(bw, bh)
            guard aspect <= config.maxAspect else { return }
            let fill = Double(component.area) / (bw * bh)

            let useArrivals = component.arrivals >= config.minArea
            let cx: Double, cy: Double, sizeArea: Double
            if useArrivals {
                cx = Double(component.arrivalSumX) / Double(component.arrivals) + 0.5
                cy = Double(component.arrivalSumY) / Double(component.arrivals) + 0.5
                sizeArea = Double(component.arrivals)
            } else {
                cx = Double(component.sumX) / Double(component.area) + 0.5
                cy = Double(component.sumY) / Double(component.area) + 0.5
                sizeArea = Double(component.area)
            }
            let arrivalFraction = Double(component.arrivals) / Double(component.area)
            let confidence = fill * (0.5 + 0.5 * arrivalFraction)
            let observation = BallObservation(time: seconds,
                                              center: CGPoint(x: cx / fw, y: cy / fh),
                                              radius: (sizeArea / .pi).squareRoot() / fw,
                                              confidence: confidence)
            let blob = Blob(area: component.area, arrivals: component.arrivals,
                            minX: component.minX, maxX: component.maxX, minY: component.minY, maxY: component.maxY,
                            fill: fill)
            scored.append((observation, blob, abs(log(Double(component.area)) - logIdeal)))
        }

        if scored.count > config.maxCandidates {
            scored.sort { $0.plausibility < $1.plausibility }
            scored.removeLast(scored.count - config.maxCandidates)
        }
        scored.sort { $0.observation.confidence > $1.observation.confidence }
        lastBlobs = scored.map(\.blob)
        return scored.map(\.observation)
    }

    // MARK: - Connected components

    private struct Component {
        var area = 0
        var arrivals = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var sumX = 0, sumY = 0
        var arrivalSumX = 0, arrivalSumY = 0
    }

    /// 4-connected components over the mask. Components past 4× `maxArea` are still
    /// flooded (so they are marked visited) but not reported.
    private func forEachComponent(width w: Int, height h: Int, _ body: (Component) -> Void) {
        let discardAbove = config.maxArea * 4
        mask.pixels.withUnsafeBufferPointer { pixels in
            mask.currentLuma.withUnsafeBufferPointer { cur in
                mask.previousLuma.withUnsafeBufferPointer { prev in
                    visited.withUnsafeMutableBufferPointer { seen in
                        for start in 0..<(w * h) where pixels[start] != 0 && seen[start] == 0 {
                            var component = Component()
                            var discard = false
                            stack.removeAll(keepingCapacity: true)
                            stack.append(Int32(start))
                            seen[start] = 1

                            while let popped = stack.popLast() {
                                let i = Int(popped)
                                let x = i % w, y = i / w
                                component.area += 1
                                if !discard {
                                    component.minX = min(component.minX, x); component.maxX = max(component.maxX, x)
                                    component.minY = min(component.minY, y); component.maxY = max(component.maxY, y)
                                    component.sumX += x; component.sumY += y
                                    if cur[i] > prev[i] {
                                        component.arrivals += 1
                                        component.arrivalSumX += x; component.arrivalSumY += y
                                    }
                                    if component.area > discardAbove { discard = true }
                                }
                                if x > 0, pixels[i - 1] != 0, seen[i - 1] == 0 { seen[i - 1] = 1; stack.append(Int32(i - 1)) }
                                if x + 1 < w, pixels[i + 1] != 0, seen[i + 1] == 0 { seen[i + 1] = 1; stack.append(Int32(i + 1)) }
                                if y > 0, pixels[i - w] != 0, seen[i - w] == 0 { seen[i - w] = 1; stack.append(Int32(i - w)) }
                                if y + 1 < h, pixels[i + w] != 0, seen[i + w] == 0 { seen[i + w] = 1; stack.append(Int32(i + w)) }
                            }
                            if !discard { body(component) }
                        }
                    }
                }
            }
        }
    }
}
