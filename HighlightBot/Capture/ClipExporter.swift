import Foundation
import AVFoundation
import CoreMedia
import UIKit
import os
import OSLog
import HighlightCore

/// Result of a successful export.
struct ExportedClip: Sendable {
    let fileURL: URL
    let thumbnailURL: URL?
    let duration: TimeInterval
    let sizeBytes: Int64

    /// Thumbnail name relative to the clips directory, as `ClipRecord` stores it.
    var thumbnailFileName: String? {
        thumbnailURL.map { "Thumbnails/" + $0.lastPathComponent }
    }
}

/// Errors from `ClipExporter`.
enum ExportError: LocalizedError {
    case cannotCreateTempFile(URL)
    case exportSessionUnavailable
    case exportFailed(String)
    case exportCancelled

    var errorDescription: String? {
        switch self {
        case .cannotCreateTempFile(let url): return "Cannot create temporary file at \(url.lastPathComponent)."
        case .exportSessionUnavailable: return "AVAssetExportSession could not be created."
        case .exportFailed(let message): return "Export failed: \(message)"
        case .exportCancelled: return "Export was cancelled."
        }
    }
}

/// Turns a `ClipPlan` (init segment + media segments on disk) into a flat,
/// shareable `.mp4` plus a JPEG thumbnail.
///
/// Steps: stream-concatenate the segment files into `tmp/export/<base>.mp4`
/// (an fMP4 byte stream is a valid MP4), then passthrough-export to
/// `clipsDirectory/<base>.mp4` (no re-encode, typically <1 s) while, in
/// parallel, generating a 640×360 thumbnail at 0.5 s from the same
/// concatenated stream — the decoder spin-up overlaps the export instead of
/// following it. If passthrough fails, fall back to a re-encode with
/// `AVAssetExportPresetHighestQuality` and log a warning.
final class ClipExporter: Sendable {
    let clipsDirectory: URL
    private let lastExport = OSAllocatedUnfairLock(initialState: 0.0)

    /// `clipsDirectory` is Documents/Clips; created if missing.
    init(clipsDirectory: URL) {
        self.clipsDirectory = clipsDirectory
        try? FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
    }

    /// Wall-clock seconds of the most recent `export`, including thumbnail.
    var lastExportSeconds: Double {
        lastExport.withLock { $0 }
    }

    func export(_ plan: ClipPlan, baseName: String) async throws -> ExportedClip {
        let clock = ContinuousClock()
        let started = clock.now
        defer {
            let seconds = (clock.now - started).timeInterval
            lastExport.withLock { $0 = seconds }
            Log.export.info("Export \(baseName, privacy: .public) took \(seconds, format: .fixed(precision: 3))s")
        }

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appending(path: "export", directoryHint: .isDirectory)
        let concatURL = tempDirectory.appending(path: baseName + ".mp4")
        let outputURL = clipsDirectory.appending(path: baseName + ".mp4")
        defer { try? fileManager.removeItem(at: concatURL) }

        Log.export.info("Exporting \(plan.mediaSegments.count) media segments (\(plan.duration, format: .fixed(precision: 2))s, \(plan.byteCount) bytes) as \(baseName, privacy: .public)")
        try concatenate(plan.urls, to: concatURL)

        let asset = AVURLAsset(url: concatURL)
        // Thumbnail reads the concatenated stream, so it can run alongside the
        // export rather than waiting for the finished file.
        async let thumbnail = Self.writeThumbnail(asset: asset, baseName: baseName, clipsDirectory: clipsDirectory)
        do {
            try await Self.runExport(asset: asset, preset: AVAssetExportPresetPassthrough, to: outputURL)
        } catch {
            Log.export.warning("Passthrough export failed (\(error.localizedDescription, privacy: .public)); re-encoding with HighestQuality")
            try await Self.runExport(asset: asset, preset: AVAssetExportPresetHighestQuality, to: outputURL)
        }
        let thumbnailURL = await thumbnail
        let sizeBytes = Self.fileSize(at: outputURL)

        // Passthrough keeps the plan's timing, so reparsing the output for its
        // duration is redundant.
        return ExportedClip(fileURL: outputURL, thumbnailURL: thumbnailURL, duration: plan.duration, sizeBytes: sizeBytes)
    }

    // MARK: - Steps

    /// Appends each file's bytes to `output` in 1 MiB chunks, never holding a
    /// whole segment set in memory.
    private func concatenate(_ urls: [URL], to output: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: output.path) {
            try fileManager.removeItem(at: output)
        }
        guard fileManager.createFile(atPath: output.path, contents: nil) else {
            throw ExportError.cannotCreateTempFile(output)
        }

        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }

        for url in urls {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            while let chunk = try reader.read(upToCount: 1 << 20), !chunk.isEmpty {
                try writer.write(contentsOf: chunk)
            }
        }
    }

    /// Exports `asset` (or just `timeRange` of it) to an `.mp4` at `outputURL`,
    /// replacing any existing file. `videoComposition` is applied when given
    /// (the montage uses one for per-clip orientation). `progress`, when
    /// given, receives the session's 0...1 completion as it advances. Shared
    /// with `ClipTrimmer` and `MontageExporter`.
    static func runExport(
        asset: AVAsset,
        preset: String,
        timeRange: CMTimeRange? = nil,
        videoComposition: AVVideoComposition? = nil,
        progress: (@Sendable (Double) -> Void)? = nil,
        to outputURL: URL
    ) async throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ExportError.exportSessionUnavailable
        }
        session.shouldOptimizeForNetworkUse = true
        if let timeRange {
            session.timeRange = timeRange
        }
        if let videoComposition {
            session.videoComposition = videoComposition
        }

        // Setup and the pre-18 export run on the caller; the observer task and
        // the cancellation handler only call thread-safe members (`progress`,
        // `states`, `cancelExport`).
        nonisolated(unsafe) let exportSession = session
        do {
            try await withTaskCancellationHandler {
                if #available(iOS 18, *) {
                    // `states` ends when the export finishes, so waiting for both
                    // children is safe; only a thrown export needs to cancel the
                    // observer.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        if let progress {
                            group.addTask {
                                for await state in exportSession.states(updateInterval: 0.2) {
                                    if case .exporting(let exportProgress) = state {
                                        progress(exportProgress.fractionCompleted)
                                    }
                                }
                            }
                        }
                        group.addTask {
                            try await exportSession.export(to: outputURL, as: .mp4)
                        }
                        do {
                            try await group.waitForAll()
                        } catch {
                            group.cancelAll()
                            throw error
                        }
                    }
                } else {
                    session.outputURL = outputURL
                    session.outputFileType = .mp4
                    // No state stream before iOS 18; sample `progress` while the
                    // export runs and stop as soon as it returns.
                    let observer: Task<Void, Never>? = progress.map { progress in
                        Task {
                            while !Task.isCancelled {
                                progress(Double(exportSession.progress))
                                try? await Task.sleep(for: .milliseconds(200))
                            }
                        }
                    }
                    await session.export()
                    observer?.cancel()
                    switch session.status {
                    case .completed:
                        break
                    case .cancelled:
                        throw ExportError.exportCancelled
                    default:
                        throw ExportError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
                    }
                }
            } onCancel: {
                exportSession.cancelExport()
            }
        } catch {
            // A cancelled iOS 18 export may surface as `CancellationError` or
            // an `AVError`; the caller only needs to know it was cancelled.
            guard Task.isCancelled else { throw error }
            try? fileManager.removeItem(at: outputURL)
            throw ExportError.exportCancelled
        }
        if Task.isCancelled {
            try? fileManager.removeItem(at: outputURL)
            throw ExportError.exportCancelled
        }
    }

    /// Best-effort 640×360 JPEG at `seconds`, written to `clipsDirectory/Thumbnails/<baseName>.jpg`.
    /// Returns nil (and logs) rather than failing the export when thumbnail
    /// generation has trouble. Shared with `ClipTrimmer`.
    static func writeThumbnail(
        asset: AVAsset,
        at seconds: Double = 0.5,
        baseName: String,
        clipsDirectory: URL
    ) async -> URL? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        do {
            let result = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
            guard let data = UIImage(cgImage: result.image).jpegData(compressionQuality: 0.8) else {
                Log.export.error("Thumbnail JPEG encoding returned nil for \(baseName, privacy: .public)")
                return nil
            }
            let directory = clipsDirectory.appending(path: "Thumbnails", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appending(path: baseName + ".jpg")
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            Log.export.error("Thumbnail failed for \(baseName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Size in bytes of the file at `url`; 0 if it cannot be read.
    static func fileSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]), let size = values.fileSize else {
            return 0
        }
        return Int64(size)
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for logging and metrics.
    var timeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
