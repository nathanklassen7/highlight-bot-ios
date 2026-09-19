import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// Sequential decode of a movie's video track as 420v pixel buffers in **stored**
/// orientation (the frame the detectors see). Load asynchronously, then iterate
/// synchronously from a background queue via `onBackgroundQueue`.
struct ClipFrames: @unchecked Sendable {
    let url: URL
    let width: Int
    let height: Int
    let frameRate: Double
    let frameDuration: CMTime
    let estimatedFrames: Int
    private let asset: AVURLAsset
    /// `AVAssetTrack` is not Sendable, but handing it to one reader on one queue is safe.
    private let videoTrack: AVAssetTrack

    init(url: URL) async throws {
        self.url = url
        asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw LabError.failed("no video track in \(url.path)")
        }
        videoTrack = track
        let (naturalSize, nominalFrameRate, minFrameDuration) =
            try await track.load(.naturalSize, .nominalFrameRate, .minFrameDuration)
        let duration = try await asset.load(.duration)
        width = Int(naturalSize.width.rounded())
        height = Int(naturalSize.height.rounded())
        frameDuration = (minFrameDuration.isNumeric && minFrameDuration.seconds > 0)
            ? minFrameDuration : CMTime(value: 1, timescale: 60)
        frameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : 1 / frameDuration.seconds
        estimatedFrames = max(1, Int((duration.seconds * frameRate).rounded()))
    }

    /// Decodes every frame in order. `body` receives the zero-based frame index, the
    /// presentation time and the pixel buffer; return false to stop early. Blocks the
    /// calling thread; call inside `onBackgroundQueue`.
    func forEach(_ body: (Int, CMTime, CVPixelBuffer) throws -> Bool) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw LabError.failed("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw LabError.failed(reader.error?.localizedDescription ?? "startReading returned false")
        }
        var index = 0
        while let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if try !body(index, pts, pixelBuffer) {
                reader.cancelReading()
                return
            }
        }
        if reader.status == .failed {
            throw LabError.failed(reader.error?.localizedDescription ?? "reader failed")
        }
    }
}

extension Duration {
    var millis: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
}

/// Runs blocking media work on a global queue and returns its result. Everything the
/// closure needs must be created inside it or be Sendable.
func onBackgroundQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                continuation.resume(returning: try work())
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
