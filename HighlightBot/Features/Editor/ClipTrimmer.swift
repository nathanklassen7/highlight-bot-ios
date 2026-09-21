import AVFoundation
import Foundation
import HighlightCore

/// Errors from `ClipTrimmer`.
enum TrimError: LocalizedError {
    case rangeTooShort(minimum: Double)
    case rangeOutOfBounds
    case slowMotionOutOfRange
    case noVideoTrack

    var errorDescription: String? {
        switch self {
        case .rangeTooShort(let minimum):
            "A trimmed clip must be at least \(minimum.formatted(.number.precision(.fractionLength(0...1)))) s long."
        case .rangeOutOfBounds:
            "The trim range is outside the clip."
        case .slowMotionOutOfRange:
            "The slow-mo segment is outside the trimmed range."
        case .noVideoTrack:
            "The clip has no video track."
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

    /// The checks `trim` runs before touching AVFoundation, for callers that
    /// render several edits at once. Throws `TrimError`.
    static func validate(_ edit: ClipEdit) throws {
        guard edit.start >= 0, edit.end > edit.start else { throw TrimError.rangeOutOfBounds }
        // Allow a hair of slack so a handle sitting exactly at the floor passes.
        guard edit.end - edit.start >= minimumDuration - 0.01 else {
            throw TrimError.rangeTooShort(minimum: minimumDuration)
        }
        if let slowMotion = edit.slowMotion {
            guard slowMotion.rate > 0, slowMotion.rate < 1,
                  slowMotion.end > slowMotion.start,
                  slowMotion.start >= edit.start - 0.01, slowMotion.end <= edit.end + 0.01 else {
                throw TrimError.slowMotionOutOfRange
            }
        }
    }

    let clipsDirectory: URL

    /// `clipsDirectory` is Documents/Clips; created if missing.
    init(clipsDirectory: URL) {
        self.clipsDirectory = clipsDirectory
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }

    /// Writes `[start, end)` of `sourceURL` to `clipsDirectory/<baseName>.mp4`.
    /// The source file is not modified.
    ///
    /// With `slowMotion`, that part of the range (source seconds, inside
    /// `[start, end)`) is stretched to `duration / rate` in the output, so the
    /// clip runs longer than `end - start`. The stretch goes through an
    /// `AVMutableComposition`, which retimes frames rather than synthesising
    /// new ones; audio in the segment is slowed with pitch correction.
    ///
    /// With `replay`, the trimmed range stays at 1× and the slow-mo segment is
    /// appended afterwards at `duration / rate`.
    func trim(
        _ sourceURL: URL,
        start: Double,
        end: Double,
        slowMotion: SlowMotionSegment? = nil,
        replay: Bool = false,
        baseName: String
    ) async throws -> ExportedClip {
        try Self.validate(ClipEdit(start: start, end: end, slowMotion: slowMotion, isSlowMotionReplay: replay))

        let clock = ContinuousClock()
        let started = clock.now
        let asset = AVURLAsset(url: sourceURL)
        let outputURL = clipsDirectory.appending(path: baseName + ".mp4")
        let preset = await Self.preset(for: asset)
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )

        var expectedDuration = end - start
        if let slowMotion {
            let clampedSegment = slowMotion.clamped(to: start, end, minimumDuration: 0)
            expectedDuration += clampedSegment.addedDuration(replay: replay)
            Log.export.info("Trimming \(sourceURL.lastPathComponent, privacy: .public) to \(start, format: .fixed(precision: 2))–\(end, format: .fixed(precision: 2))s with \(clampedSegment.start, format: .fixed(precision: 2))–\(clampedSegment.end, format: .fixed(precision: 2))s at \(clampedSegment.rate, format: .fixed(precision: 2))x replay=\(replay) as \(baseName, privacy: .public) (\(preset, privacy: .public))")
            let composition = try await Self.composition(of: asset, range: range, slowMotion: clampedSegment, replay: replay)
            try await ClipExporter.runExport(asset: composition, preset: preset, to: outputURL)
        } else {
            Log.export.info("Trimming \(sourceURL.lastPathComponent, privacy: .public) to \(start, format: .fixed(precision: 2))–\(end, format: .fixed(precision: 2))s as \(baseName, privacy: .public) (\(preset, privacy: .public))")
            try await ClipExporter.runExport(asset: asset, preset: preset, timeRange: range, to: outputURL)
        }

        // Read timing and the thumbnail from the finished file so the record
        // matches what was actually written.
        let output = AVURLAsset(url: outputURL)
        let duration = await Self.duration(of: output) ?? expectedDuration
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

    /// `range` of `asset` on fresh video/audio tracks, with `slowMotion`
    /// (source seconds) stretched to its scaled duration. When `replay` is
    /// true, the range stays at 1× and the segment is inserted again after it
    /// before the stretch. The video track's orientation transform is carried
    /// over so portrait clips stay portrait.
    private static func composition(
        of asset: AVAsset,
        range: CMTimeRange,
        slowMotion: SlowMotionSegment,
        replay: Bool
    ) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let sourceVideo = videoTracks.first else { throw TrimError.noVideoTrack }

        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.exportFailed("Could not add a video track to the composition.")
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        video.preferredTransform = try await sourceVideo.load(.preferredTransform)

        let sourceAudio = audioTracks.first
        var audio: AVMutableCompositionTrack?
        if let sourceAudio {
            audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            if let audio {
                try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
            }
        }

        let segmentRange = CMTimeRange(
            start: CMTime(seconds: slowMotion.start, preferredTimescale: 600),
            duration: CMTime(seconds: slowMotion.duration, preferredTimescale: 600)
        )
        let scaledDuration = CMTime(seconds: slowMotion.scaledDuration, preferredTimescale: 600)

        if replay {
            let insertAt = range.duration
            try video.insertTimeRange(segmentRange, of: sourceVideo, at: insertAt)
            if let sourceAudio, let audio {
                try audio.insertTimeRange(segmentRange, of: sourceAudio, at: insertAt)
            }
            composition.scaleTimeRange(
                CMTimeRange(start: insertAt, duration: segmentRange.duration),
                toDuration: scaledDuration
            )
        } else {
            // Composition time starts at 0 where the source starts at `range.start`.
            let segmentStart = CMTime(seconds: slowMotion.start, preferredTimescale: 600) - range.start
            composition.scaleTimeRange(
                CMTimeRange(start: segmentStart, duration: segmentRange.duration),
                toDuration: scaledDuration
            )
        }
        return composition
    }

    /// HEVC sources stay HEVC; anything else uses the H.264 highest-quality preset.
    /// Shared with `MontageExporter`.
    static func preset(for asset: AVAsset) async -> String {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let description = try? await track.load(.formatDescriptions).first else {
            return AVAssetExportPresetHighestQuality
        }
        let codec = CMFormatDescriptionGetMediaSubType(description)
        return codec == kCMVideoCodecType_HEVC ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
    }

    static func duration(of asset: AVAsset) async -> Double? {
        guard let time = try? await asset.load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
