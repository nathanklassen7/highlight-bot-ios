import BallTracking
import CoreGraphics
import CoreImage
import Foundation

/// `candidates --input clip.mp4 --out DIR [--threshold 60] [--max-area 300] [--max-candidates 40]`
/// Writes DIR/candidates.mp4 (source frame with every `MotionCandidateDetector`
/// candidate as a magenta circle; the top-confidence one is drawn thicker) and
/// DIR/candidates.jsonl (one line per candidate, stored-frame pixels).
struct CandidatesCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let config = try Self.detectorConfig(options)
        let videoURL = outDir.appending(path: "candidates.mp4")
        let jsonlURL = outDir.appending(path: "candidates.jsonl")

        let clip = try await ClipFrames(url: input)
        print("Detecting motion candidates in \(input.lastPathComponent) → \(videoURL.path)")

        let stats: CandidateStats = try await onBackgroundQueue {
            let detector = MotionCandidateDetector(config: config)
            let writer = try BGRAVideoWriter(output: videoURL, width: clip.width, height: clip.height)
            let ciContext = CIContext(options: [.cacheIntermediates: false])
            FileManager.default.createFile(atPath: jsonlURL.path, contents: nil)
            let jsonl = try FileHandle(forWritingTo: jsonlURL)
            defer { try? jsonl.close() }
            var stats = CandidateStats()
            let fw = Double(clip.width), fh = Double(clip.height)

            try clip.forEach { index, pts, pixelBuffer in
                let start = ContinuousClock.now
                let candidates = try detector.detect(pixelBuffer: pixelBuffer, time: pts)
                stats.record(millis: (ContinuousClock.now - start).millis, count: candidates.count)
                let blobs = detector.lastBlobs

                var lines = ""
                for (c, blob) in zip(candidates, blobs) {
                    lines += String(format: "{\"frame\":%d,\"t\":%.4f,\"x\":%.1f,\"y\":%.1f,\"radius\":%.2f,\"area\":%d,\"arrivals\":%d,\"fill\":%.3f,\"luma\":%.1f,\"surround\":%.1f,\"chroma\":%.1f,\"confidence\":%.3f}\n",
                                    index, pts.seconds, c.center.x * fw, c.center.y * fh, c.radius * fw,
                                    blob.area, blob.arrivals, blob.fill, blob.meanLuma, blob.surroundLuma, blob.chromaDeviation, c.confidence)
                }
                jsonl.write(Data(lines.utf8))

                let buffer = try writer.makeBuffer()
                LabDrawing.render(pixelBuffer, into: buffer, using: ciContext)
                LabDrawing.withContext(on: buffer) { context, _, _ in
                    Self.draw(candidates, in: context, width: fw, height: fh)
                    LabDrawing.drawText(String(format: "f%05d  t%.3f  candidates=%d", index, pts.seconds, candidates.count),
                                        in: context, at: CGPoint(x: 16, y: 16))
                }
                try writer.append(buffer, at: pts)
                if index % 100 == 0 { print("  frame \(index)") }
                return true
            }
            try writer.finish()
            return stats
        }

        print(stats.describe())
        print("Done. Output in \(outDir.path)")
    }

    static func detectorConfig(_ options: Options) throws -> MotionCandidateDetector.Config {
        var config = MotionCandidateDetector.Config()
        config.mask.threshold = UInt8(clamping: options.int("threshold", default: Int(config.mask.threshold)))
        config.maxArea = options.int("max-area", default: config.maxArea)
        config.maxCandidates = options.int("max-candidates", default: config.maxCandidates)
        return config
    }

    /// Magenta circle per candidate at 2× its radius (minimum 5 px) so an 11 px ball is
    /// visible at 1080p; the top-confidence candidate is drawn thicker.
    static func draw(_ candidates: [BallObservation], in context: CGContext, width: Double, height: Double) {
        let magenta = CGColor(red: 1, green: 0.2, blue: 0.9, alpha: 0.95)
        for (i, c) in candidates.enumerated() {
            let center = CGPoint(x: c.center.x * width, y: c.center.y * height)
            let radius = max(5, c.radius * width * 2)
            LabDrawing.strokeCircle(context, center: center, radius: radius, color: magenta, lineWidth: i == 0 ? 3 : 1.5)
        }
    }
}

struct CandidateStats: Sendable {
    var frames = 0
    var totalCandidates = 0
    var emptyFrames = 0
    var maxCount = 0
    var counts: [Int] = []
    var sumMillis = 0.0

    mutating func record(millis: Double, count: Int) {
        frames += 1
        totalCandidates += count
        if count == 0 { emptyFrames += 1 }
        maxCount = max(maxCount, count)
        counts.append(count)
        sumMillis += millis
    }

    func describe() -> String {
        let sorted = counts.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return String(format: "frames %d   detect ms mean %.2f   candidates/frame mean %.1f median %d p90 %d max %d   empty frames %d (%.1f%%)",
                      frames, frames == 0 ? 0 : sumMillis / Double(frames),
                      frames == 0 ? 0 : Double(totalCandidates) / Double(frames), median, p90, maxCount,
                      emptyFrames, frames == 0 ? 0 : Double(emptyFrames) / Double(frames) * 100)
    }
}
