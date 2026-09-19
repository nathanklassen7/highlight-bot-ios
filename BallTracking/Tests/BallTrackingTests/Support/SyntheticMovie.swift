import AVFoundation
import CoreGraphics
import Foundation

/// Writes a short H.264 movie of a white disc moving over a dark background so
/// `ClipTrackRunner` can be tested end to end on macOS.
enum SyntheticMovie {
    static func write(to url: URL, width: Int = 640, height: Int = 360, frames: Int = 40, fps: Int32 = 50,
                      transform: CGAffineTransform = .identity,
                      position: (Int) -> CGPoint) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        precondition(writer.canAdd(input))
        writer.add(input)
        precondition(writer.startWriting(), "startWriting: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            let frame = SyntheticFrames.make420v(width: width, height: height, background: 30,
                                                 discs: [.init(center: position(i), radius: 5, luma: 235)])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            precondition(adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "finishWriting: \(String(describing: writer.error))")
    }
}
