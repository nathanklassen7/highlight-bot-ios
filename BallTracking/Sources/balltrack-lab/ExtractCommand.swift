import AVFoundation
import CoreImage
import Foundation

/// Dumps every Nth frame as PNG (display orientation) for hand labelling.
struct ExtractCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        let every = max(1, options.int("every", default: 10))
        let start = options.double("start", default: 0)
        let end = options.double("end", default: .infinity)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LabError.failed("no video track")
        }
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let assetRef = asset
        nonisolated(unsafe) let trackRef = videoTrack
        let compositionRef = composition

        let written: Int = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reader = try AVAssetReader(asset: assetRef)
                    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [trackRef], videoSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ])
                    output.videoComposition = compositionRef
                    guard reader.canAdd(output) else { throw LabError.failed("cannot add reader output") }
                    reader.add(output)
                    guard reader.startReading() else {
                        throw LabError.failed(reader.error?.localizedDescription ?? "reader failed")
                    }
                    let ciContext = CIContext()
                    var index = 0
                    var count = 0
                    while let sample = output.copyNextSampleBuffer() {
                        defer { index += 1 }
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        guard index % every == 0, t >= start, t <= end,
                              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                        let image = CIImage(cvPixelBuffer: pixelBuffer)
                        let url = outDir.appending(path: String(format: "f%05d_t%.3f.png", index, t))
                        try ciContext.writePNGRepresentation(of: image, to: url, format: .BGRA8,
                                                             colorSpace: CGColorSpaceCreateDeviceRGB())
                        count += 1
                    }
                    if reader.status == .failed {
                        throw LabError.failed(reader.error?.localizedDescription ?? "reader failed")
                    }
                    continuation.resume(returning: count)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        print("Wrote \(written) frames to \(outDir.path)")
    }
}
