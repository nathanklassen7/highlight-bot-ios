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
        /// Threshold 90 and a 5×5 closing were chosen by the user from `balltrack-lab sizes`
        /// renders: 90 halves the outline fragments while keeping the blurred ball; the
        /// closing rejoins a fast ball's streak, which otherwise splits into pieces.
        public var mask: MotionMask.Config = {
            var config = MotionMask.Config()
            config.threshold = 90
            config.closing = 5
            return config
        }()
        /// Component area bounds in full-resolution pixels, measured on the dilated mask.
        /// One moving pixel dilates to 9 px, so 20 requires a few genuine pixels; the far
        /// ball on the reference clip is ≥ ~35 px dilated, the near ball up to ~300.
        public var minArea = 20
        public var maxArea = 800
        /// Shape filters, all reviewed on the colour-coded `sizes` render. A fast ball's
        /// motion streak is long (aspect up to ~5) and tapered (fill ~0.3) but always
        /// thick (area / longest side ≥ 5 px); a player's outline sliver is 2–3 px thick
        /// however long it is. Thickness is what separates them.
        public var maxAspect = 6.0
        public var minFill = 0.25
        public var minThickness = 5.0
        /// Kept per frame. Trimmed by area plausibility (closest to `idealArea` in log
        /// space), never by brightness. On the reference clip p90 is ~59, so this binds
        /// only on the busiest swings.
        public var maxCandidates = 60
        /// Dilated area of a typical ball blob on 1080p footage (11×7 px ball → ~100 px).
        public var idealArea = 100.0
        /// Soft appearance scores folded into `confidence` (never used to reject).
        /// Contrast = blob luma − ring luma (full range) at which the contrast score
        /// saturates. Measured on the reference clip: the ball 67–100 (40 when badly
        /// blurred near the camera); heads, shoes, feet, shirt edges −24…58; fragments
        /// inside a bright region ≈ 0. This is contrast against the local surround, not
        /// absolute brightness, and it is a weight — the cap never ranks by it.
        public var contrastScale = 80.0
        /// max(|Cb−128|, |Cr−128|) at which the achromatic score reaches zero: a white ball
        /// measures 4–13, skin 21–31, hair 36, red rubber 30, the pink shirt 16.
        public var chromaScale = 40.0

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
        /// Mean full-range luma of the blob's arriving pixels (or all pixels when none arrived).
        public var meanLuma: Double
        /// Mean full-range luma of the ring 2–8 px outside the bounding box, current frame.
        public var surroundLuma: Double
        /// max(|Cb−128|, |Cr−128|) sampled at the blob's centre; 0 when the buffer has no chroma.
        public var chromaDeviation: Double

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

        // Chroma is sampled straight from the buffer, so hold the lock for the component pass.
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        var chroma: ChromaPlane?
        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
           let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            chroma = ChromaPlane(base: chromaBase.assumingMemoryBound(to: UInt8.self),
                                 bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                                 width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                                 height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
        }

        forEachComponent(width: w, height: h) { component in
            guard component.area >= config.minArea, component.area <= config.maxArea else { return }
            let bw = Double(component.maxX - component.minX + 1)
            let bh = Double(component.maxY - component.minY + 1)
            let aspect = max(bw, bh) / min(bw, bh)
            guard aspect <= config.maxAspect else { return }
            let fill = Double(component.area) / (bw * bh)
            guard fill >= config.minFill, Double(component.area) / max(bw, bh) >= config.minThickness else { return }

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
            let surround = surroundLuma(minX: component.minX, maxX: component.maxX,
                                        minY: component.minY, maxY: component.maxY, width: w, height: h)
            let chromaDeviation = chroma?.deviation(atLumaX: Int(cx), y: Int(cy)) ?? 0
            let meanLuma = useArrivals
                ? Double(component.arrivalLuma) / Double(component.arrivals)
                : Double(component.sumLuma) / Double(component.area)
            // Soft scores in 0…1, multiplied: a compact, arriving, high-contrast, achromatic
            // blob scores ~0.4; a shirt-edge sliver, a lit hand or a departing ghost ≤ 0.2.
            // Weights, not gates; the fitter averages them along a flight.
            let contrast = min(1, max(0, (meanLuma - surround) / config.contrastScale))
            let achromatic = max(0, 1 - chromaDeviation / config.chromaScale)
            let confidence = fill.squareRoot() * (0.2 + 0.8 * arrivalFraction) * contrast * achromatic
            let observation = BallObservation(time: seconds,
                                              center: CGPoint(x: cx / fw, y: cy / fh),
                                              radius: (sizeArea / .pi).squareRoot() / fw,
                                              confidence: confidence)
            let blob = Blob(area: component.area, arrivals: component.arrivals,
                            minX: component.minX, maxX: component.maxX, minY: component.minY, maxY: component.maxY,
                            fill: fill, meanLuma: meanLuma, surroundLuma: surround, chromaDeviation: chromaDeviation)
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

    // MARK: - Appearance

    /// View of a locked buffer's interleaved CbCr plane. Never outlives the lock in `detect`.
    private struct ChromaPlane {
        let base: UnsafePointer<UInt8>
        let bytesPerRow: Int
        let width: Int
        let height: Int

        /// max(|Cb−128|, |Cr−128|) averaged over the 3×3 chroma samples around a luma pixel.
        func deviation(atLumaX x: Int, y: Int) -> Double {
            let cx = x / 2, cy = y / 2
            var sumCb = 0, sumCr = 0, n = 0
            for yy in max(0, cy - 1)...min(height - 1, cy + 1) {
                for xx in max(0, cx - 1)...min(width - 1, cx + 1) {
                    let o = yy * bytesPerRow + xx * 2
                    sumCb += Int(base[o]); sumCr += Int(base[o + 1]); n += 1
                }
            }
            guard n > 0 else { return 0 }
            return max(abs(Double(sumCb) / Double(n) - 128), abs(Double(sumCr) / Double(n) - 128))
        }
    }

    /// Mean current-frame luma in the ring between the bounding box grown by 2 px
    /// (excluded) and by 8 px (included), clamped to the frame. 0 if the ring is empty.
    private func surroundLuma(minX: Int, maxX: Int, minY: Int, maxY: Int, width w: Int, height h: Int) -> Double {
        let innerMinX = minX - 2, innerMaxX = maxX + 2, innerMinY = minY - 2, innerMaxY = maxY + 2
        let outerMinX = max(0, minX - 8), outerMaxX = min(w - 1, maxX + 8)
        let outerMinY = max(0, minY - 8), outerMaxY = min(h - 1, maxY + 8)
        guard outerMinX <= outerMaxX, outerMinY <= outerMaxY else { return 0 }
        var sum = 0, count = 0
        mask.currentLuma.withUnsafeBufferPointer { cur in
            for y in outerMinY...outerMaxY {
                let row = y * w
                let insideY = y >= innerMinY && y <= innerMaxY
                for x in outerMinX...outerMaxX {
                    if insideY && x >= innerMinX && x <= innerMaxX { continue }
                    sum += Int(cur[row + x]); count += 1
                }
            }
        }
        return count > 0 ? Double(sum) / Double(count) : 0
    }

    // MARK: - Connected components

    private struct Component {
        var area = 0
        var arrivals = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var sumX = 0, sumY = 0, sumLuma = 0
        var arrivalSumX = 0, arrivalSumY = 0, arrivalLuma = 0
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
                                    component.sumX += x; component.sumY += y; component.sumLuma += Int(cur[i])
                                    if cur[i] > prev[i] {
                                        component.arrivals += 1
                                        component.arrivalSumX += x; component.arrivalSumY += y
                                        component.arrivalLuma += Int(cur[i])
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
