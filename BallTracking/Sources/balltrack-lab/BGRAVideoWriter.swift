import Accelerate
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreText
import CoreVideo
import Foundation

/// Writes an H.264 `.mp4` from BGRA pixel buffers appended in presentation order.
/// Not thread-safe; use from the one queue that produces the frames.
final class BGRAVideoWriter {
    let width: Int
    let height: Int
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var started = false

    init(output: URL, width: Int, height: Int, bitRate: Int = 8_000_000) throws {
        self.width = width
        self.height = height
        try? FileManager.default.removeItem(at: output)
        writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
        ])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw LabError.failed("cannot add writer input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw LabError.failed(writer.error?.localizedDescription ?? "startWriting failed")
        }
    }

    /// A fresh BGRA buffer from the writer's pool. Contents are undefined.
    func makeBuffer() throws -> CVPixelBuffer {
        guard let pool = adaptor.pixelBufferPool else { throw LabError.failed("no pixel buffer pool") }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard let buffer else { throw LabError.failed("pixel buffer pool exhausted") }
        return buffer
    }

    func append(_ buffer: CVPixelBuffer, at pts: CMTime) throws {
        if !started {
            writer.startSession(atSourceTime: pts)
            started = true
        }
        while !input.isReadyForMoreMediaData { usleep(2_000) }
        guard adaptor.append(buffer, withPresentationTime: pts) else {
            throw LabError.failed(writer.error?.localizedDescription ?? "append failed")
        }
    }

    func finish() throws {
        if !started { writer.startSession(atSourceTime: .zero) }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw LabError.failed(writer.error?.localizedDescription ?? "finishWriting failed")
        }
    }
}

/// Drawing helpers for BGRA pixel buffers. Coordinates are top-left origin pixels.
enum LabDrawing {
    /// Runs `body` with a CGContext over the buffer, flipped so y grows downward.
    static func withContext(on pixelBuffer: CVPixelBuffer, _ body: (CGContext, Int, Int) -> Void) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        body(context, width, height)
    }

    /// Renders a 420v (or any CoreImage-readable) buffer into a BGRA buffer.
    static func render(_ source: CVPixelBuffer, into destination: CVPixelBuffer, using ciContext: CIContext) {
        ciContext.render(CIImage(cvPixelBuffer: source), to: destination)
    }

    /// Fills a BGRA buffer from an 8-bit plane (stride == width) as grey.
    static func fillGrey(_ plane: [UInt8], width: Int, height: Int, into destination: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(destination, [])
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        guard let base = CVPixelBufferGetBaseAddress(destination) else { return }
        var alpha = [UInt8](repeating: 255, count: width * height)
        plane.withUnsafeBufferPointer { src in
            alpha.withUnsafeMutableBufferPointer { a in
                var grey = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                         height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var alphaBuffer = vImage_Buffer(data: a.baseAddress!, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
                var dst = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                        rowBytes: CVPixelBufferGetBytesPerRow(destination))
                // Memory order B,G,R,A: the four planes interleave in argument order.
                _ = vImageConvert_Planar8toARGB8888(&grey, &grey, &grey, &alphaBuffer, &dst, vImage_Flags(kvImageNoFlags))
            }
        }
    }

    /// Copies a BGRA buffer into a rectangle of another BGRA buffer, scaled to fit.
    static func blit(_ source: CVPixelBuffer, into destination: CVPixelBuffer, rect: CGRect) {
        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(destination, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(destination, [])
        }
        guard let srcBase = CVPixelBufferGetBaseAddress(source), let dstBase = CVPixelBufferGetBaseAddress(destination) else { return }
        var src = vImage_Buffer(data: srcBase, height: vImagePixelCount(CVPixelBufferGetHeight(source)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(source)), rowBytes: CVPixelBufferGetBytesPerRow(source))
        let dstRowBytes = CVPixelBufferGetBytesPerRow(destination)
        let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
        var dst = vImage_Buffer(data: dstBase + y * dstRowBytes + x * 4, height: vImagePixelCount(h),
                                width: vImagePixelCount(w), rowBytes: dstRowBytes)
        _ = vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
    }

    static func drawText(_ text: String, in context: CGContext, at origin: CGPoint, size: CGFloat = 28,
                         color: CGColor = CGColor(red: 1, green: 1, blue: 0.2, alpha: 1)) {
        let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
        // Use the CoreText attribute keys directly: CTLineDraw understands
        // `kCTForegroundColorAttributeName` with a CGColor, whereas the AppKit
        // `.foregroundColor` key expects an NSColor.
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let box = CGRect(x: origin.x - 6, y: origin.y - 4, width: bounds.width + 12, height: bounds.height + 8)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        context.fill(box)
        // Text draws in CG's native orientation; undo the flip locally.
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: -bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    static func strokeCircle(_ context: CGContext, center: CGPoint, radius: CGFloat, color: CGColor, lineWidth: CGFloat) {
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    static func strokePolyline(_ context: CGContext, points: [CGPoint], color: CGColor, lineWidth: CGFloat) {
        guard points.count > 1 else { return }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginPath()
        context.move(to: points[0])
        for p in points.dropFirst() { context.addLine(to: p) }
        context.strokePath()
    }
}
