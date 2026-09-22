import AVFoundation
import CoreGraphics
import Foundation
import HighlightCore

/// Errors from `MontageExporter` raised before any encoding starts.
enum MontageError: LocalizedError {
    case tooFewClips(minimum: Int)
    case missingFile(String)
    case clip(index: Int, underlying: any Error)

    var errorDescription: String? {
        switch self {
        case .tooFewClips(let minimum):
            "A montage needs at least \(minimum) clips."
        case .missingFile(let name):
            "\(name) is missing from this device."
        case .clip(let index, let underlying):
            "Clip \(index + 1): \(underlying.localizedDescription)"
        }
    }
}

/// Where a montage export is and how long it has left. `fraction` covers
/// the whole job (build, encode, thumbnail); the encode dominates.
struct MontageExportProgress: Equatable, Sendable {
    var fraction: Double
    var estimatedSecondsRemaining: Double
}

/// Joins ordered `MontageItem`s into one `.mp4` (plus thumbnail) in
/// `clipsDirectory`. Each item contributes its trimmed range with its slow-mo
/// applied the same way `ClipTrimmer` does for a single clip. Always
/// re-encodes: cuts are not on keyframes and the sources may differ in codec
/// or orientation. The output codec follows the first clip (HEVC stays HEVC).
final class MontageExporter: Sendable {
    let clipsDirectory: URL

    /// `clipsDirectory` is Documents/Clips; created if missing.
    init(clipsDirectory: URL) {
        self.clipsDirectory = clipsDirectory
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }

    /// Writes `clipsDirectory/<baseName>.mp4`. Source files are not modified.
    /// `orientation` is the one the montage keeps — the draft's
    /// `resolvedOrientation` — and decides the render frame; items in the
    /// other orientation get black bars.
    /// `onProgress` is called on an arbitrary thread as the encode advances,
    /// first with the up-front estimate, then with refined remaining times.
    func export(
        _ items: [MontageItem],
        baseName: String,
        keeping orientation: ClipOrientation,
        onProgress: @escaping @Sendable (MontageExportProgress) -> Void = { _ in }
    ) async throws -> ExportedClip {
        guard items.count >= MontageDraft.minimumClipCount else {
            throw MontageError.tooFewClips(minimum: MontageDraft.minimumClipCount)
        }
        for (index, item) in items.enumerated() {
            guard FileManager.default.fileExists(atPath: item.clip.fileURL.path) else {
                throw MontageError.missingFile(item.clip.fileName)
            }
            do {
                try ClipTrimmer.validate(item.edit)
            } catch {
                throw MontageError.clip(index: index, underlying: error)
            }
        }

        let clock = ContinuousClock()
        let started = clock.now
        let outputURL = clipsDirectory.appending(path: baseName + ".mp4")
        let expectedDuration = items.reduce(0) { $0 + $1.outputDuration }
        let preset = await ClipTrimmer.preset(for: AVURLAsset(url: items[0].clip.fileURL))
        let frame = MontageFraming.renderSize(for: items, keeping: orientation)
        Log.export.info("Exporting montage of \(items.count) clips (\(expectedDuration, format: .fixed(precision: 2))s) as \(baseName, privacy: .public) (\(preset, privacy: .public), \(orientation.rawValue, privacy: .public) \(frame.width)x\(frame.height))")

        let built = try await MontageComposition.build(
            items,
            renderSize: CGSize(width: frame.width, height: frame.height)
        )
        // A cancel during the build must not start the encode.
        try Task.checkCancellation()
        let estimate = ExportTimeEstimate(workloads: built.workloads, secondsPerUnit: ExportSpeedStore.secondsPerUnit())
        Log.export.info("Montage estimate: \(estimate.units, format: .fixed(precision: 1)) units, ~\(estimate.totalSeconds, format: .fixed(precision: 1))s")
        onProgress(MontageExportProgress(fraction: Self.encodeStart, estimatedSecondsRemaining: estimate.totalSeconds))

        let encodeStarted = clock.now
        try await ClipExporter.runExport(
            asset: built.composition,
            preset: preset,
            videoComposition: built.videoComposition,
            progress: { sessionFraction in
                let elapsed = (clock.now - encodeStarted).timeInterval
                onProgress(MontageExportProgress(
                    fraction: Self.encodeStart + sessionFraction * (Self.encodeEnd - Self.encodeStart),
                    estimatedSecondsRemaining: estimate.remainingSeconds(progress: sessionFraction, elapsed: elapsed)
                ))
            },
            to: outputURL
        )
        let encodeSeconds = (clock.now - encodeStarted).timeInterval
        if estimate.units > 0 {
            ExportSpeedStore.record(observedSecondsPerUnit: encodeSeconds / estimate.units)
        }
        onProgress(MontageExportProgress(fraction: Self.encodeEnd, estimatedSecondsRemaining: 0))

        // Read timing, size, and the thumbnail from the finished file so the
        // record matches what was actually written rather than what was asked
        // for; the oriented size agrees with `frame` by construction.
        let output = AVURLAsset(url: outputURL)
        let duration = await ClipTrimmer.duration(of: output) ?? expectedDuration
        let thumbnailURL = await ClipExporter.writeThumbnail(
            asset: output,
            at: min(0.5, duration / 2),
            baseName: baseName,
            clipsDirectory: clipsDirectory
        )
        let sizeBytes = ClipExporter.fileSize(at: outputURL)
        let size = await ClipExporter.orientedSize(of: output)
        onProgress(MontageExportProgress(fraction: 1, estimatedSecondsRemaining: 0))

        let seconds = (clock.now - started).timeInterval
        Log.export.info("Montage \(baseName, privacy: .public) took \(seconds, format: .fixed(precision: 3))s (encode \(encodeSeconds, format: .fixed(precision: 3))s, estimate \(estimate.totalSeconds, format: .fixed(precision: 1))s)")
        return ExportedClip(
            fileURL: outputURL,
            thumbnailURL: thumbnailURL,
            duration: duration,
            sizeBytes: sizeBytes,
            videoWidth: size.width,
            videoHeight: size.height
        )
    }

    /// Share of the overall bar given to the encode; the rest is build and thumbnail.
    private static let encodeStart: Double = 0.03
    private static let encodeEnd: Double = 0.97
}
