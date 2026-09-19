import Accelerate
import CoreVideo
import Foundation

/// Two-frame motion mask: `|Y_t − Y_{t−1}| > threshold`, dilated once with a 3×3
/// kernel, at full resolution. This is the Swift form of the ffmpeg chain the user
/// approved on the reference clip
/// (`format=gray,tblend=all_mode=difference,geq=gt(lum,60),dilation`), so the
/// threshold is in **full-range** grey units: video-range luma (16…235) is
/// expanded by 255/219 before differencing, exactly as `format=gray` does.
///
/// Value type. Keeps the previous frame, so feed it consecutive frames from one
/// source in order and `reset()` on seeks or source changes.
public struct MotionMask: Sendable {
    public struct Config: Sendable, Equatable {
        /// Minimum full-range luma difference for a pixel to count as moving (strict `>`).
        public var threshold: UInt8 = 60
        /// Side of the square kernel of a morphological closing (dilate then erode) applied
        /// after the 3×3 dilation. Joins blobs closer than about this many pixels — a
        /// blurred fast ball fragments into several pieces otherwise. 0 or 1 disables it.
        public var closing: Int = 0
        public init() {}
        public static let `default` = Config()
    }

    public let config: Config
    /// Size of the most recent frame. Zero until the first frame.
    public private(set) var width = 0
    public private(set) var height = 0
    /// True once two consecutive frames of the same size have been seen.
    public private(set) var hasMask = false
    /// The mask for the most recent frame, row-major with stride `width`, 0 or 255.
    /// Meaningless while `hasMask` is false.
    public private(set) var pixels: [UInt8] = []

    /// Full-range luma of the most recent frame, same layout as `pixels`.
    public var currentLuma: [UInt8] { current }
    /// Full-range luma of the frame before it. Meaningless while `hasMask` is false.
    public var previousLuma: [UInt8] { previous }

    private var current: [UInt8] = []
    private var previous: [UInt8] = []
    private var scratch: [UInt8] = []
    private var hasPrevious = false

    /// Video range 16…235 → 0…255, clamped. Identity for full-range buffers.
    private static let videoRangeExpansion: [UInt8] = (0..<256).map { y in
        UInt8(clamping: Int((Double(y - 16) * 255 / 219).rounded()))
    }

    public init(config: Config = .default) {
        self.config = config
    }

    public mutating func reset() {
        hasPrevious = false
        hasMask = false
    }

    /// Ingests a frame. Returns true when `pixels` now holds a mask, i.e. from the
    /// second consecutive frame onward. Buffers that are not planar 8-bit are ignored.
    @discardableResult
    public mutating func update(pixelBuffer: CVPixelBuffer) -> Bool {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) >= 1, w > 0, h > 0 else {
            hasMask = false
            return false
        }
        if w != width || h != height {
            width = w; height = h
            current = [UInt8](repeating: 0, count: w * h)
            previous = [UInt8](repeating: 0, count: w * h)
            scratch = [UInt8](repeating: 0, count: w * h)
            pixels = [UInt8](repeating: 0, count: w * h)
            hasPrevious = false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            hasMask = false
            return false
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let isFullRange = Self.isFullRange(CVPixelBufferGetPixelFormatType(pixelBuffer))

        // The last frame becomes `previous`; the new one overwrites the older buffer.
        if hasPrevious { swap(&current, &previous) }

        var src = vImage_Buffer(data: base, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: stride)
        let copyError: vImage_Error = current.withUnsafeMutableBufferPointer { dst in
            var dstBuffer = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            if isFullRange {
                return vImageCopyBuffer(&src, &dstBuffer, 1, vImage_Flags(kvImageNoFlags))
            }
            return Self.videoRangeExpansion.withUnsafeBufferPointer { table in
                vImageTableLookUp_Planar8(&src, &dstBuffer, table.baseAddress!, vImage_Flags(kvImageNoFlags))
            }
        }
        guard copyError == kvImageNoError else {
            hasMask = false
            return false
        }

        guard hasPrevious else {
            hasPrevious = true
            hasMask = false
            return false
        }

        thresholdDifference()
        dilate()
        if config.closing > 1 { close(kernel: config.closing | 1) }
        hasMask = true
        return true
    }

    // MARK: - Internals

    private static func isFullRange(_ format: OSType) -> Bool {
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8PlanarFullRange,
             kCVPixelFormatType_422YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_444YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_OneComponent8:
            return true
        default:
            return false
        }
    }

    /// `scratch[i] = |current[i] − previous[i]| > threshold ? 255 : 0`.
    private mutating func thresholdDifference() {
        let threshold = Int(config.threshold)
        current.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                scratch.withUnsafeMutableBufferPointer { out in
                    for i in 0..<cur.count {
                        let d = abs(Int(cur[i]) - Int(prev[i]))
                        out[i] = d > threshold ? 255 : 0
                    }
                }
            }
        }
    }

    /// Closing: k×k max then k×k min, `pixels` → `scratch` → `pixels`.
    private mutating func close(kernel k: Int) {
        let w = width, h = height
        pixels.withUnsafeMutableBufferPointer { a in
            scratch.withUnsafeMutableBufferPointer { b in
                var bufA = vImage_Buffer(data: a.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var bufB = vImage_Buffer(data: b.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                guard vImageMax_Planar8(&bufA, &bufB, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageNoFlags)) == kvImageNoError,
                      vImageMin_Planar8(&bufB, &bufA, nil, 0, 0, vImagePixelCount(k), vImagePixelCount(k), vImage_Flags(kvImageNoFlags)) == kvImageNoError
                else { return }
            }
        }
    }

    /// 3×3 max filter (dilation for a binary image) from `scratch` into `pixels`.
    private mutating func dilate() {
        let w = width, h = height
        scratch.withUnsafeMutableBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                var srcBuffer = vImage_Buffer(data: src.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var dstBuffer = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                let error = vImageMax_Planar8(&srcBuffer, &dstBuffer, nil, 0, 0, 3, 3, vImage_Flags(kvImageNoFlags))
                if error != kvImageNoError {
                    // Fall back to the undilated mask rather than stale data.
                    dst.baseAddress!.update(from: src.baseAddress!, count: w * h)
                }
            }
        }
    }
}
