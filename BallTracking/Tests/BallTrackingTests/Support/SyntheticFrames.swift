import CoreGraphics
import CoreVideo
import Foundation

/// Builds 420v (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) pixel buffers
/// with a flat background and filled discs, the same format the camera and
/// `AVAssetReader` deliver.
enum SyntheticFrames {
    struct Disc {
        var center: CGPoint   // pixels
        var radius: Double    // pixels
        var luma: UInt8
    }

    static func make420v(width: Int, height: Int, background: UInt8 = 40, discs: [Disc] = []) -> CVPixelBuffer {
        precondition(width % 2 == 0 && height % 2 == 0, "420 planes need even dimensions")
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         nil, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let pixelBuffer = buffer!

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            memset(yBase + row * yStride, Int32(background), width)
        }
        for disc in discs {
            let r2 = disc.radius * disc.radius
            let minY = max(0, Int(disc.center.y - disc.radius) - 1)
            let maxY = min(height - 1, Int(disc.center.y + disc.radius) + 1)
            let minX = max(0, Int(disc.center.x - disc.radius) - 1)
            let maxX = min(width - 1, Int(disc.center.x + disc.radius) + 1)
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = Double(x) + 0.5 - disc.center.x
                    let dy = Double(y) + 0.5 - disc.center.y
                    if dx * dx + dy * dy <= r2 {
                        yBase[y * yStride + x] = disc.luma
                    }
                }
            }
        }

        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<(height / 2) {
            memset(cbcrBase + row * cbcrStride, 128, width) // interleaved Cb,Cr: width/2 pairs = width bytes
        }
        return pixelBuffer
    }

    /// Luma value at a pixel, for assertions.
    static func luma(of pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        return base[y * stride + x]
    }
}
