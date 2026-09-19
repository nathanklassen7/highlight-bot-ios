import AVFoundation
import BallTracking
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Re-reads the input in display orientation (BGRA, via a video composition so
/// `preferredTransform` is applied) and writes an H.264 copy with the track drawn on.
struct AnnotatedVideoWriter {
    let input: URL
    let track: BallTrack
    let output: URL

    func write() async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LabError.failed("no video track")
        }
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let size = composition.renderSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())

        // `AVURLAsset` and `AVVideoComposition` are Sendable in the SDK; `AVAssetTrack`
        // is not, but handing it to one other queue for reading is safe.
        let assetRef = asset
        nonisolated(unsafe) let trackRef = videoTrack
        let compositionRef = composition
        let track = self.track
        let output = self.output

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.process(asset: assetRef, videoTrack: trackRef, composition: compositionRef,
                                     width: width, height: height, track: track, output: output)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func process(asset: AVURLAsset, videoTrack: AVAssetTrack, composition: AVVideoComposition,
                                width: Int, height: Int, track: BallTrack, output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.videoComposition = composition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw LabError.failed("cannot add reader output") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw LabError.failed("cannot add writer input") }
        writer.add(input)

        guard reader.startReading() else { throw LabError.failed(reader.error?.localizedDescription ?? "reader failed") }
        guard writer.startWriting() else { throw LabError.failed(writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let geometry = OverlayGeometry(videoRect: CGRect(x: 0, y: 0, width: width, height: height))
        var index = 0

        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let pool = adaptor.pixelBufferPool else { throw LabError.failed("no pixel buffer pool") }
            var destination: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
            guard let destination else { throw LabError.failed("pool exhausted") }

            ciContext.render(CIImage(cvPixelBuffer: source), to: destination)
            draw(on: destination, width: width, height: height, geometry: geometry,
                 frame: track.frame(at: pts.seconds),
                 trail: track.trail(endingAt: pts.seconds, duration: 0.4),
                 index: index, time: pts.seconds)

            while !input.isReadyForMoreMediaData { usleep(2_000) }
            guard adaptor.append(destination, withPresentationTime: pts) else {
                throw LabError.failed(writer.error?.localizedDescription ?? "append failed")
            }
            index += 1
        }
        if reader.status == .failed {
            throw LabError.failed(reader.error?.localizedDescription ?? "reader failed")
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw LabError.failed(writer.error?.localizedDescription ?? "finishWriting failed") }
    }

    private static func draw(on pixelBuffer: CVPixelBuffer, width: Int, height: Int, geometry: OverlayGeometry,
                             frame: BallTrackFrame?, trail: [CGPoint], index: Int, time: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // CoreGraphics is bottom-left; flip so our top-left coordinates draw upright.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        if trail.count > 1 {
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: geometry.point(forNormalized: trail[0]))
            for p in trail.dropFirst() { context.addLine(to: geometry.point(forNormalized: p)) }
            context.strokePath()
        }

        if let frame, frame.isVisible, let position = frame.position {
            let center = geometry.point(forNormalized: position)
            let radius = max(10, geometry.length(forNormalizedWidthFraction: frame.radius ?? 0.005) * 2.5)
            let color = frame.state == .tracking
                ? CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
                : CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)
            context.setStrokeColor(color)
            context.setLineWidth(4)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }

        let state = frame?.state.rawValue ?? "—"
        let label = String(format: "f%05d  t%.3f  ", index, time) + state + "  cands=\(frame?.candidateCount ?? 0)"
        drawText(label, in: context, at: CGPoint(x: 16, y: 16), height: height)
    }

    private static func drawText(_ text: String, in context: CGContext, at origin: CGPoint, height: Int) {
        let font = CTFontCreateWithName("Menlo" as CFString, 28, nil)
        // Use the CoreText attribute keys directly: CTLineDraw understands
        // `kCTForegroundColorAttributeName` with a CGColor, whereas the AppKit
        // `.foregroundColor` key expects an NSColor.
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
            kCTForegroundColorAttributeName as NSAttributedString.Key: CGColor(red: 1, green: 1, blue: 0.2, alpha: 1),
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
}
