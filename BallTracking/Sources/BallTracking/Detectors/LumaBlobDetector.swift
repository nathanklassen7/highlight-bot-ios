import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Classical detector for a bright ball on a darker, mostly static background.
/// Works on the Y plane of 420 buffers (no colour conversion), sampling the
/// CbCr plane only to measure each blob's mean chroma.
/// Candidate blobs must be bright, moving, ball-sized, *achromatic* (mean
/// |Cb−128| and |Cr−128| within `Config.maxChromaDeviation`, which rejects lit
/// skin, hair, paddle rubber and coloured fabric while keeping a white ball) and
/// *isolated*: the ring around a blob must be dark (`Config.maxSurroundLuma`),
/// which separates a ball on a table or wall from ball-sized fragments of a
/// moving shirt.
/// `@unchecked Sendable`: scratch buffers are only touched inside `detect`/`reset`,
/// which callers serialise (see `BallDetector`).
public final class LumaBlobDetector: BallDetector, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Integer downsample factor applied to the luma plane before analysis.
        public var downsample: Int = 2
        /// Minimum luma (video range 16…235) for a pixel to count as "bright".
        public var minLuma: UInt8 = 150
        /// Minimum |Y − Y_previous| for a pixel to count as "moving".
        public var minMotion: UInt8 = 20
        /// Blob area bounds in analysis-resolution pixels. A 10 px ball at 1080p is
        /// ~20 px² at 540p; motion blur streaks are larger.
        public var minArea: Int = 3
        public var maxArea: Int = 400
        /// Bounding-box long/short side; streaks are allowed, walls are not.
        public var maxAspect: Double = 3.5
        /// area / bboxArea; rejects thin edge fragments.
        public var minFill: Double = 0.3
        /// Mean luma of the ring around a blob's bounding box (inner margin 2 px,
        /// outer margin 8 px at analysis resolution, on the current frame). Blobs
        /// whose surround is brighter than this are fragments of a larger bright
        /// object, not a ball.
        public var maxSurroundLuma: UInt8 = 90
        /// Maximum of the blob's mean |Cb−128| and mean |Cr−128| (video-range 420
        /// chroma). A white ball is near 0; skin, hair, rubber and coloured fabric
        /// are 20–60. Ignored when the buffer has no chroma plane.
        public var maxChromaDeviation: UInt8 = 16
        public var maxCandidates: Int = 8

        public init() {}
        public static let `default` = Config()
    }

    public let name = "luma-blob"
    private let config: Config

    private var width = 0
    private var height = 0
    private var fullWidth = 0
    private var fullHeight = 0
    private var current: [UInt8] = []
    private var previous: [UInt8] = []
    private var mask: [UInt8] = []
    private var labels: [Int32] = []
    private var stack: [Int32] = []
    private var hasPrevious = false

    public init(config: Config = .default) {
        self.config = config
    }

    public func reset() {
        hasPrevious = false
    }

    public func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation] {
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard planar, CVPixelBufferGetPlaneCount(pixelBuffer) >= 1, srcWidth > 0, srcHeight > 0 else { return [] }

        let ds = max(1, config.downsample)
        let w = srcWidth / ds
        let h = srcHeight / ds
        if w != width || h != height || srcWidth != fullWidth || srcHeight != fullHeight {
            width = w; height = h; fullWidth = srcWidth; fullHeight = srcHeight
            current = [UInt8](repeating: 0, count: w * h)
            previous = [UInt8](repeating: 0, count: w * h)
            mask = [UInt8](repeating: 0, count: w * h)
            labels = [Int32](repeating: 0, count: w * h)
            stack.reserveCapacity(4096)
            hasPrevious = false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return [] }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        // Interleaved Cb,Cr at half the luma resolution. Only valid while the buffer is locked.
        var chroma: ChromaPlane? = nil
        if CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
           let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            chroma = ChromaPlane(base: chromaBase.assumingMemoryBound(to: UInt8.self),
                                 bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1),
                                 lumaStep: ds)
        }

        var src = vImage_Buffer(data: base, height: vImagePixelCount(srcHeight), width: vImagePixelCount(srcWidth), rowBytes: stride)
        let scaleError: vImage_Error = current.withUnsafeMutableBufferPointer { dst in
            var dstBuffer = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            return vImageScale_Planar8(&src, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
        }
        guard scaleError == kvImageNoError else { return [] }

        defer { swap(&current, &previous); hasPrevious = true }
        guard hasPrevious else { return [] }

        buildMask()
        let blobs = labelBlobs(chroma: chroma)
        let seconds = time.seconds
        let fw = Double(fullWidth), fh = Double(fullHeight), scale = Double(ds)
        let hasChroma = chroma != nil
        let maxChromaDeviation = Double(config.maxChromaDeviation)

        var observations: [BallObservation] = blobs.compactMap { blob in
            guard blob.area >= config.minArea, blob.area <= config.maxArea else { return nil }
            let area = Double(blob.area)
            let bw = Double(blob.maxX - blob.minX + 1)
            let bh = Double(blob.maxY - blob.minY + 1)
            let aspect = max(bw, bh) / min(bw, bh)
            guard aspect <= config.maxAspect else { return nil }
            let fill = area / (bw * bh)
            guard fill >= config.minFill else { return nil }
            if hasChroma {
                let chromaDeviation = max(abs(Double(blob.sumCb) / area - 128),
                                          abs(Double(blob.sumCr) / area - 128))
                guard chromaDeviation <= maxChromaDeviation else { return nil }
            }
            let surround = surroundMeanLuma(of: blob)
            guard surround <= Double(config.maxSurroundLuma) else { return nil }
            let cx = (Double(blob.sumX) / Double(blob.area) + 0.5) * scale
            let cy = (Double(blob.sumY) / Double(blob.area) + 0.5) * scale
            let radiusPixels = (Double(blob.area) / .pi).squareRoot() * scale
            let meanLuma = Double(blob.sumLuma) / Double(blob.area)
            let confidence = min(1, meanLuma / 235) * fill * (1 - surround / 255)
            return BallObservation(time: seconds,
                                   center: CGPoint(x: cx / fw, y: cy / fh),
                                   radius: radiusPixels / fw,
                                   confidence: confidence)
        }
        observations.sort { $0.confidence > $1.confidence }
        if observations.count > config.maxCandidates {
            observations.removeLast(observations.count - config.maxCandidates)
        }
        return observations
    }

    // MARK: - Internals

    private func buildMask() {
        let minLuma = config.minLuma
        let minMotion = Int(config.minMotion)
        current.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                mask.withUnsafeMutableBufferPointer { out in
                    for i in 0..<cur.count {
                        let y = cur[i]
                        let d = abs(Int(y) - Int(prev[i]))
                        out[i] = (y >= minLuma && d >= minMotion) ? 1 : 0
                    }
                }
            }
        }
    }

    private struct Blob {
        var area = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var sumX = 0, sumY = 0, sumLuma = 0
        var sumCb = 0, sumCr = 0
    }

    /// View of a locked buffer's interleaved CbCr plane. Never outlives the lock
    /// in `detect`; passed by value into `labelBlobs`, not stored on the instance.
    private struct ChromaPlane {
        let base: UnsafePointer<UInt8>
        let bytesPerRow: Int
        /// Luma pixels per analysis pixel (`Config.downsample`).
        let lumaStep: Int

        /// Byte offset of the Cb sample covering analysis pixel (x, y); Cr is at +1.
        @inline(__always)
        func offset(x: Int, y: Int) -> Int {
            let cx = x * lumaStep / 2
            let cy = y * lumaStep / 2
            return cy * bytesPerRow + cx * 2
        }
    }

    /// Mean luma of `current` in the ring between the blob's bounding box grown by
    /// 2 px (excluded) and grown by 8 px (included), clamped to the frame.
    /// Returns 0 if the ring is empty (blob fills the frame), which never rejects.
    private func surroundMeanLuma(of blob: Blob) -> Double {
        let w = width, h = height
        let innerMinX = blob.minX - 2, innerMaxX = blob.maxX + 2
        let innerMinY = blob.minY - 2, innerMaxY = blob.maxY + 2
        let outerMinX = max(0, blob.minX - 8), outerMaxX = min(w - 1, blob.maxX + 8)
        let outerMinY = max(0, blob.minY - 8), outerMaxY = min(h - 1, blob.maxY + 8)
        guard outerMinX <= outerMaxX, outerMinY <= outerMaxY else { return 0 }

        var sum = 0
        var count = 0
        current.withUnsafeBufferPointer { cur in
            for y in outerMinY...outerMaxY {
                let row = y * w
                let insideY = y >= innerMinY && y <= innerMaxY
                for x in outerMinX...outerMaxX {
                    if insideY && x >= innerMinX && x <= innerMaxX { continue }
                    sum += Int(cur[row + x])
                    count += 1
                }
            }
        }
        return count > 0 ? Double(sum) / Double(count) : 0
    }

    /// 4-connected components over `mask`. Blobs that grow past 4× `maxArea` are
    /// still flooded (so they are labelled) but discarded early. When `chroma` is
    /// present, each blob pixel also accumulates its Cb/Cr sample.
    private func labelBlobs(chroma: ChromaPlane?) -> [Blob] {
        let w = width, h = height
        let discardAbove = config.maxArea * 4
        var blobs: [Blob] = []
        labels.withUnsafeMutableBufferPointer { lab in
            lab.update(repeating: 0)
        }
        var nextLabel: Int32 = 1
        for start in 0..<(w * h) where mask[start] != 0 && labels[start] == 0 {
            var blob = Blob()
            var discard = false
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(start))
            labels[start] = nextLabel

            func visit(_ j: Int) {
                if mask[j] != 0 && labels[j] == 0 {
                    labels[j] = nextLabel
                    stack.append(Int32(j))
                }
            }

            while let popped = stack.popLast() {
                let i = Int(popped)
                let x = i % w, y = i / w
                blob.area += 1
                if !discard {
                    blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                    blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
                    blob.sumX += x; blob.sumY += y; blob.sumLuma += Int(current[i])
                    if let chroma {
                        let c = chroma.offset(x: x, y: y)
                        blob.sumCb += Int(chroma.base[c])
                        blob.sumCr += Int(chroma.base[c + 1])
                    }
                    if blob.area > discardAbove { discard = true }
                }
                if x > 0 { visit(i - 1) }
                if x + 1 < w { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y + 1 < h { visit(i + w) }
            }
            if !discard { blobs.append(blob) }
            nextLabel &+= 1
        }
        return blobs
    }
}
