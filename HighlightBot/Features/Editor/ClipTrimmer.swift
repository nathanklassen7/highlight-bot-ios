import AVFoundation
import Foundation
import HighlightCore

/// Errors from `ClipTrimmer`.
enum TrimError: LocalizedError {
    case rangeTooShort(minimum: Double)
    case rangeOutOfBounds

    var errorDescription: String? {
        switch self {
        case .rangeTooShort(let minimum):
            "A trimmed clip must be at least \(minimum.formatted(.number.precision(.fractionLength(0...1)))) s long."
        case .rangeOutOfBounds:
            "The trim range is outside the clip."
        }
    }
}

/// Cuts a saved clip down to a time range and writes the result as a new
/// `.mp4` (plus thumbnail) beside the original.
///
/// Trimming re-encodes rather than passing through: a passthrough cut can
/// only start on a keyframe, so the clip would begin up to a segment early.
/// Re-encoding a 20–30 s clip takes a few seconds on recent iPhones. The
/// source's codec family is kept (HEVC stays HEVC).
final class ClipTrimmer: Sendable {
    /// Shortest allowed result. The editor enforces the same floor on its handles.
    static let minimumDuration: Double = 1.0

    let clipsDirectory: URL

    /// `clipsDirectory` is Documents/Clips; created if missing.
    init(clipsDirectory: URL) {
        self.clipsDirectory = clipsDirectory
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }

    /// Writes `[start, end)` of `sourceURL` to `clipsDirectory/<baseName>.mp4`.
    /// The source file is not modified.
    func trim(_ sourceURL: URL, start: Double, end: Double, baseName: String) async throws -> ExportedClip {
        guard start >= 0, end > start else { throw TrimError.rangeOutOfBounds }
        // Allow a hair of slack so a handle sitting exactly at the floor passes.
        guard end - start >= Self.minimumDuration - 0.01 else {
            throw TrimError.rangeTooShort(minimum: Self.minimumDuration)
        }

        let clock = ContinuousClock()
        let started = clock.now
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = clipsDirectory.appending(path: baseName + ".mp4")
        let preset = await Self.preset(for: asset)
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        Log.export.info("Trimming \(sourceURL.lastPathComponent, privacy: .public) to \(start, format: .fixed(precision: 2))–\(end, format: .fixed(precision: 2))s as \(baseName, privacy: .public) (\(preset, privacy: .public))")
        try await ClipExporter.runExport(asset: asset, preset: preset, timeRange: range, to: outputURL)

        // Read timing and the thumbnail from the finished file so the record
        // matches what was actually written.
        let output = AVURLAsset(url: outputURL)
        let duration = await Self.duration(of: output) ?? (end - start)
        let thumbnailURL = await ClipExporter.writeThumbnail(
            asset: output,
            at: min(0.5, duration / 2),
            baseName: baseName,
            clipsDirectory: clipsDirectory
        )
        let sizeBytes = ClipExporter.fileSize(at: outputURL)

        let seconds = (clock.now - started).timeInterval
        Log.export.info("Trim \(baseName, privacy: .public) took \(seconds, format: .fixed(precision: 3))s")
        return ExportedClip(fileURL: outputURL, thumbnailURL: thumbnailURL, duration: duration, sizeBytes: sizeBytes)
    }

    /// Removes the files a trim produced. For callers that could not record
    /// the result and would otherwise leave orphans in the clips directory.
    static func discard(_ exported: ExportedClip) {
        let fm = FileManager.default
        for url in [exported.fileURL, exported.thumbnailURL].compactMap({ $0 }) where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                Log.export.error("Failed to discard \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// HEVC sources stay HEVC; anything else uses the H.264 highest-quality preset.
    private static func preset(for asset: AVAsset) async -> String {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first else {
            return AVAssetExportPresetHighestQuality
        }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        return codec == kCMVideoCodecType_HEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }

    private static func duration(of asset: AVAsset) async -> Double? {
        guard let time = try? await asset.load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
