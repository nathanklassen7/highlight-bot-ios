import BallTracking
import CoreMedia
import Foundation
import os

struct RunSummary: Codable {
    var input: String
    var detector: String
    var frames: Int
    var durationSeconds: Double
    var frameRate: Double
    var meanDetectMillis: Double
    var p95DetectMillis: Double
    var wallSeconds: Double
    var realtimeFactor: Double
    var trackingFraction: Double
    var visibleFraction: Double
    var trackStarts: Int
    var longestTrackingRunSeconds: Double
    var meanCandidatesPerFrame: Double
    var detectErrors: Int
}

struct RunCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let detectorArg = options.string("detector") ?? "default"
        let runner = try makeRunner(detectorArg)

        let debugWriter: DebugMosaicWriter?
        if options.flag("debug") {
            let clip = try await ClipFrames(url: input)
            let debugURL = outDir.appending(path: "debug.mp4")
            debugWriter = try DebugMosaicWriter(output: debugURL, width: clip.width, height: clip.height)
            print("Writing debug mosaic to \(debugURL.path)…")
        } else {
            debugWriter = nil
        }
        // Keep the last fitter state so the flight segments can be written out.
        let lastFitter = OSAllocatedUnfairLock<TrajectoryFitter?>(initialState: nil)
        let onFrame: @Sendable (ClipTrackFrameEvent) throws -> Void = { event in
            if let fitter = event.stage as? TrajectoryFitter {
                lastFitter.withLock { $0 = fitter }
            }
            try debugWriter?.append(event)
        }

        print("Analysing \(input.lastPathComponent) with \(runner.detectorName)…")
        let lastPrinted = OSAllocatedUnfairLock(initialState: -1)
        let result = try await runner.run(url: input, progress: { progress in
            let percent = Int(progress.fraction * 100)
            let shouldPrint = lastPrinted.withLock { last -> Bool in
                guard percent / 10 != last / 10 else { return false }
                last = percent
                return true
            }
            if shouldPrint {
                print("  \(percent)% (\(progress.framesDone) frames)")
            }
        }, isCancelled: { false }, onFrame: onFrame)
        try debugWriter?.finish()

        if let fitter = lastFitter.withLock({ $0 }) {
            let segmentsURL = outDir.appending(path: "segments.json")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fitter.segments).write(to: segmentsURL)
            let kinds = Dictionary(grouping: fitter.segments, by: \.breakKind).mapValues(\.count)
            print("flights: \(fitter.segments.count) closed" + (fitter.currentModel == nil ? "" : " + 1 open")
                  + "  breaks: " + kinds.map { "\($0.key.rawValue)=\($0.value)" }.sorted().joined(separator: " "))
        }

        let track = result.track
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(track).write(to: outDir.appending(path: "track.json"))

        let summary = Self.summarise(result, input: input)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        try pretty.encode(summary).write(to: outDir.appending(path: "summary.json"))

        print(Self.describe(summary))
        print(Self.timeline(track))

        if !options.flag("no-annotate") {
            let annotated = outDir.appending(path: "annotated.mp4")
            print("Writing \(annotated.path)…")
            try await AnnotatedVideoWriter(input: input, track: track, output: annotated).write()
        }
        print("Done. Output in \(outDir.path)")
    }

    private func makeRunner(_ detectorArg: String) throws -> ClipTrackRunner {
        switch detectorArg {
        case "default":
            return ClipTrackRunner(detectorKind: .default)
        case "vision":
            let trajectoryLength = options.int("trajectory-length", default: VisionTrajectoryDetector.Config.default.trajectoryLength)
            return ClipTrackRunner(detectorName: "vision") { frameDuration in
                var config = VisionTrajectoryDetector.Config()
                config.trajectoryLength = trajectoryLength
                config.frameDuration = frameDuration
                return VisionTrajectoryDetector(config: config)
            }
        case "luma":
            var config = LumaBlobDetector.Config()
            config.minLuma = UInt8(clamping: options.int("min-luma", default: Int(config.minLuma)))
            config.minMotion = UInt8(clamping: options.int("min-motion", default: Int(config.minMotion)))
            config.maxArea = options.int("max-area", default: config.maxArea)
            let lumaConfig = config
            return ClipTrackRunner(detectorName: "luma") { _ in LumaBlobDetector(config: lumaConfig) }
        case "motion":
            let detectorConfig = try CandidatesCommand.detectorConfig(options)
            var fitterConfig = TrajectoryFitterConfig()
            fitterConfig.inlierRadius = options.double("inlier-radius", default: fitterConfig.inlierRadius)
            fitterConfig.minInliers = options.int("min-inliers", default: fitterConfig.minInliers)
            fitterConfig.windowFrames = options.int("window", default: fitterConfig.windowFrames)
            let fitter = fitterConfig
            return ClipTrackRunner(detectorName: "motion",
                                   makeDetector: { _ in MotionCandidateDetector(config: detectorConfig) },
                                   makeStage: { size in TrajectoryFitter(config: fitter, imageSize: size) })
        default:
            throw LabError.usage("--detector must be vision, luma, motion, or default")
        }
    }

    static func summarise(_ result: ClipTrackResult, input: URL) -> RunSummary {
        let track = result.track
        let frames = track.frames
        let duration = frames.count > 1 ? frames.last!.time - frames.first!.time : 0

        var starts = 0
        var previousState = BallTrackState.searching
        var runStart: TimeInterval?
        var longestRun = 0.0
        for frame in frames {
            if frame.state == .tracking && previousState != .tracking && previousState != .coasting {
                starts += 1
            }
            if frame.isVisible {
                if runStart == nil { runStart = frame.time }
                longestRun = max(longestRun, frame.time - (runStart ?? frame.time))
            } else {
                runStart = nil
            }
            previousState = frame.state
        }

        return RunSummary(
            input: input.path,
            detector: track.detector,
            frames: frames.count,
            durationSeconds: duration,
            frameRate: track.frameRate,
            meanDetectMillis: result.meanDetectMillis,
            p95DetectMillis: result.p95DetectMillis,
            wallSeconds: result.wallSeconds,
            realtimeFactor: result.wallSeconds > 0 ? duration / result.wallSeconds : 0,
            trackingFraction: track.trackingFraction,
            visibleFraction: frames.isEmpty ? 0 : Double(frames.filter(\.isVisible).count) / Double(frames.count),
            trackStarts: starts,
            longestTrackingRunSeconds: longestRun,
            meanCandidatesPerFrame: frames.isEmpty ? 0 : Double(frames.map(\.candidateCount).reduce(0, +)) / Double(frames.count),
            detectErrors: result.detectErrors
        )
    }

    static func describe(_ s: RunSummary) -> String {
        """

        detector            \(s.detector)
        frames              \(s.frames) (\(String(format: "%.2f", s.durationSeconds)) s @ \(String(format: "%.1f", s.frameRate)) fps)
        detect ms           mean \(String(format: "%.2f", s.meanDetectMillis))  p95 \(String(format: "%.2f", s.p95DetectMillis))  errors \(s.detectErrors)
        wall                \(String(format: "%.1f", s.wallSeconds)) s (\(String(format: "%.1f", s.realtimeFactor))× realtime)
        tracking fraction   \(String(format: "%.1f", s.trackingFraction * 100))%   visible \(String(format: "%.1f", s.visibleFraction * 100))%
        track starts        \(s.trackStarts)
        longest run         \(String(format: "%.2f", s.longestTrackingRunSeconds)) s
        candidates/frame    \(String(format: "%.2f", s.meanCandidatesPerFrame))
        """
    }

    /// One character per half second: '#' ≥75 % visible, '+' ≥25 %, '.' otherwise.
    static func timeline(_ track: BallTrack, bucket: TimeInterval = 0.5) -> String {
        guard let first = track.frames.first?.time, let last = track.frames.last?.time, last > first else { return "" }
        let buckets = Int(((last - first) / bucket).rounded(.up))
        var visible = [Int](repeating: 0, count: buckets)
        var total = [Int](repeating: 0, count: buckets)
        for frame in track.frames {
            let b = min(buckets - 1, Int((frame.time - first) / bucket))
            total[b] += 1
            if frame.isVisible { visible[b] += 1 }
        }
        var chars = ""
        var scale = ""
        for b in 0..<buckets {
            let f = total[b] == 0 ? 0 : Double(visible[b]) / Double(total[b])
            chars.append(f >= 0.75 ? "#" : f >= 0.25 ? "+" : ".")
            scale.append(b % 10 == 0 ? "|" : " ")
        }
        return "\ntimeline (0.5 s per char; | every 5 s)\n\(chars)\n\(scale)\n"
    }
}
