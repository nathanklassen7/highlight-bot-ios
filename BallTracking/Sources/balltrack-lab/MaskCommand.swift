import BallTracking
import CoreGraphics
import Foundation

/// `mask --input clip.mp4 --out DIR [--threshold 60]`
/// Writes DIR/mask.mp4: the `MotionMask` for every source frame, white on black, in
/// stored orientation. Frame 0 has no predecessor and is black, so frame k of this
/// video corresponds to frame k−1 of an ffmpeg `tblend` render of the same clip.
struct MaskCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var config = MotionMask.Config()
        config.threshold = UInt8(clamping: options.int("threshold", default: Int(config.threshold)))
        let maskConfig = config
        let output = outDir.appending(path: "mask.mp4")
        // Frames whose raw mask plane is also written losslessly as DIR/mask_fNNNNN.pgm,
        // for pixel-exact comparison against an ffmpeg render.
        let dumpFrames = Set((options.string("dump-frames") ?? "").split(separator: ",").compactMap { Int($0) })

        let clip = try await ClipFrames(url: input)
        print("Rendering motion mask (threshold \(maskConfig.threshold)) for \(input.lastPathComponent) → \(output.path)")

        let stats: MaskStats = try await onBackgroundQueue {
            var mask = MotionMask(config: maskConfig)
            // Binary masks are all hard edges; at 8 Mbps H.264 ringing grows blobs by
            // ~30 % after decode, so spend more bits to keep the video faithful.
            let writer = try BGRAVideoWriter(output: output, width: clip.width, height: clip.height, bitRate: 30_000_000)
            var stats = MaskStats()
            let black = [UInt8](repeating: 0, count: clip.width * clip.height)
            var maskMillis: [Double] = []
            try clip.forEach { index, pts, pixelBuffer in
                let start = ContinuousClock.now
                let hasMask = mask.update(pixelBuffer: pixelBuffer)
                maskMillis.append((ContinuousClock.now - start).millis)
                let plane = hasMask ? mask.pixels : black
                let buffer = try writer.makeBuffer()
                LabDrawing.fillGrey(plane, width: clip.width, height: clip.height, into: buffer)
                LabDrawing.withContext(on: buffer) { context, _, _ in
                    LabDrawing.drawText(String(format: "f%05d  t%.3f  mask", index, pts.seconds), in: context, at: CGPoint(x: 16, y: 16))
                }
                try writer.append(buffer, at: pts)
                if dumpFrames.contains(index) {
                    try Self.writePGM(plane, width: clip.width, height: clip.height,
                                      to: outDir.appending(path: String(format: "mask_f%05d.pgm", index)))
                }
                if hasMask {
                    let on = mask.pixels.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
                    stats.record(frame: index, movingFraction: Double(on) / Double(clip.width * clip.height))
                }
                if index % 100 == 0 { print("  frame \(index)") }
                return true
            }
            try writer.finish()
            stats.meanMillis = maskMillis.isEmpty ? 0 : maskMillis.reduce(0, +) / Double(maskMillis.count)
            return stats
        }

        print(String(format: "frames %d   mask ms mean %.2f   moving fraction mean %.3f%%  max %.3f%% (frame %d)",
                     stats.frames, stats.meanMillis, stats.meanMoving * 100, stats.maxMoving * 100, stats.maxFrame))
        print("Done. Output in \(outDir.path)")
    }

    /// Binary PGM (P5), 8-bit, stride == width.
    static func writePGM(_ plane: [UInt8], width: Int, height: Int, to url: URL) throws {
        var data = Data("P5\n\(width) \(height)\n255\n".utf8)
        data.append(contentsOf: plane)
        try data.write(to: url)
    }
}

struct MaskStats: Sendable {
    var frames = 0
    var sumMoving = 0.0
    var maxMoving = 0.0
    var maxFrame = 0
    var meanMillis = 0.0

    var meanMoving: Double { frames == 0 ? 0 : sumMoving / Double(frames) }

    mutating func record(frame: Int, movingFraction: Double) {
        frames += 1
        sumMoving += movingFraction
        if movingFraction > maxMoving {
            maxMoving = movingFraction
            maxFrame = frame
        }
    }
}
