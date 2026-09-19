import BallTracking
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

/// `sizes --input clip.mp4 --out DIR [--threshold 60] [--min-area 20] [--max-area 800] [--side-by-side]`
/// Blob-size exclusion on the motion mask, rendered so it can be checked by eye:
/// DIR/sizes.mp4 colours every connected component of the mask by its area —
/// white when inside [min, max] (kept), red when too large, blue when too small.
/// With `--side-by-side` the source frame is placed to the left at half size.
struct SizesCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        var maskConfig = MotionMask.Config()
        maskConfig.threshold = UInt8(clamping: options.int("threshold", default: Int(maskConfig.threshold)))
        maskConfig.closing = options.int("closing", default: maskConfig.closing)
        let minArea = options.int("min-area", default: 20)
        let maxArea = options.int("max-area", default: 800)
        // Shape exclusion on what survives the size test: the ball is compact, the
        // players' outline slivers are thin. Set --min-fill 0 --max-aspect 99 to disable.
        let minFill = options.double("min-fill", default: 0.4)
        let maxAspect = options.double("max-aspect", default: 3.0)
        // Mean thickness = area / longest bounding-box side. A ball streak is ≥ ~5 px
        // thick; an outline sliver is 2–3 px however long it is.
        let minThickness = options.double("min-thickness", default: 0)
        let sideBySide = options.flag("side-by-side")
        // With --kept-only, every reject is omitted (black); only kept blobs draw, in white.
        let keptOnly = options.flag("kept-only")
        let output = outDir.appending(path: "sizes.mp4")
        let config = maskConfig

        let clip = try await ClipFrames(url: input)
        print("Rendering size-filtered mask (area \(minArea)…\(maxArea) px kept) → \(output.path)")

        struct Stats: Sendable { var frames = 0; var kept: [Int] = []; var large = 0; var small = 0; var thin = 0 }
        let stats: Stats = try await onBackgroundQueue {
            var mask = MotionMask(config: config)
            let w = clip.width, h = clip.height
            let outWidth = sideBySide ? w : w
            let outHeight = sideBySide ? h / 2 : h
            let writer = try BGRAVideoWriter(output: output, width: outWidth, height: outHeight, bitRate: 20_000_000)
            var labeler = MaskComponents(width: w, height: h)
            var colour = [UInt8](repeating: 0, count: w * h * 4)
            var scratch: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, nil, &scratch)
            let ciContext = CIContext(options: [.cacheIntermediates: false])
            var stats = Stats()

            try clip.forEach { index, pts, pixelBuffer in
                let hasMask = mask.update(pixelBuffer: pixelBuffer)
                var kept = 0
                colour.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
                if hasMask {
                    let shapes = labeler.shapes(of: mask.pixels)
                    var counted = Set<Int32>()
                    for i in 0..<(w * h) where mask.pixels[i] != 0 {
                        let label = labeler.labels[i]
                        let shape = shapes[Int(label)]
                        let o = i * 4
                        let verdict: Int  // 0 kept, 1 small, 2 large, 3 thin
                        if shape.area < minArea { verdict = 1 }
                        else if shape.area > maxArea { verdict = 2 }
                        else if shape.fill < minFill || shape.aspect > maxAspect || shape.thickness < minThickness { verdict = 3 }
                        else { verdict = 0 }
                        switch verdict {  // memory order B,G,R,A
                        case 1 where !keptOnly: colour[o] = 200; colour[o + 1] = 60; colour[o + 2] = 40     // blue: too small
                        case 2 where !keptOnly: colour[o] = 40; colour[o + 1] = 40; colour[o + 2] = 210     // red: too large
                        case 3 where !keptOnly: colour[o] = 40; colour[o + 1] = 190; colour[o + 2] = 40     // green: thin
                        case 0: colour[o] = 255; colour[o + 1] = 255; colour[o + 2] = 255   // white: kept
                        default: break                                                       // omitted
                        }
                        colour[o + 3] = 255
                        if counted.insert(label).inserted {
                            switch verdict {
                            case 1: stats.small += 1
                            case 2: stats.large += 1
                            case 3: stats.thin += 1
                            default: kept += 1
                            }
                        }
                    }
                    stats.frames += 1
                    stats.kept.append(kept)
                }

                let dest = try writer.makeBuffer()
                guard let scratch else { throw LabError.failed("no scratch buffer") }
                Self.copy(colour, into: scratch, width: w, height: h)
                if sideBySide {
                    let half = CGSize(width: Double(w) / 2, height: Double(h) / 2)
                    LabDrawing.withContext(on: dest) { context, _, _ in
                        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: w, height: outHeight))
                    }
                    let source = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
                    ciContext.render(source, to: dest, bounds: CGRect(origin: .zero, size: half), colorSpace: CGColorSpaceCreateDeviceRGB())
                    LabDrawing.blit(scratch, into: dest, rect: CGRect(origin: CGPoint(x: half.width, y: 0), size: half))
                } else {
                    LabDrawing.blit(scratch, into: dest, rect: CGRect(x: 0, y: 0, width: w, height: h))
                }
                LabDrawing.withContext(on: dest) { context, _, _ in
                    LabDrawing.drawText(String(format: "f%05d  t%.3f  kept=%d  (white kept | red >%d px | blue <%d px | green thin: fill<%.2f, aspect>%.0f, thickness<%.1f)",
                                               index, pts.seconds, kept, maxArea, minArea, minFill, maxAspect, minThickness),
                                        in: context, at: CGPoint(x: 16, y: 16), size: sideBySide ? 20 : 28)
                }
                try writer.append(dest, at: pts)
                if index % 100 == 0 { print("  frame \(index)") }
                return true
            }
            try writer.finish()
            return stats
        }

        let sorted = stats.kept.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        print("frames \(stats.frames)   kept blobs/frame median \(median) p90 \(p90) max \(sorted.last ?? 0)   dropped: too large \(stats.large), too small \(stats.small), thin \(stats.thin)")
        print("Done. Output in \(outDir.path)")
    }

    private static func copy(_ bgra: [UInt8], into buffer: CVPixelBuffer, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        bgra.withUnsafeBufferPointer { src in
            for y in 0..<height {
                memcpy(base + y * rowBytes, src.baseAddress! + y * width * 4, width * 4)
            }
        }
    }
}

/// 4-connected component labelling of a binary plane; `labels[i]` indexes `areas`.
struct MaskComponents {
    let width: Int
    let height: Int
    private(set) var labels: [Int32]
    private var stack: [Int32] = []

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        labels = [Int32](repeating: 0, count: width * height)
        stack.reserveCapacity(4096)
    }

    struct Shape {
        var area = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var fill: Double { Double(area) / Double((maxX - minX + 1) * (maxY - minY + 1)) }
        var aspect: Double {
            let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
            return max(bw, bh) / min(bw, bh)
        }
        var thickness: Double {
            Double(area) / Double(max(maxX - minX + 1, maxY - minY + 1))
        }
    }

    /// Labels every component and returns its shape, indexed by label (index 0 unused).
    mutating func shapes(of mask: [UInt8]) -> [Shape] {
        labels.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        var shapes = [Shape()]
        var next: Int32 = 1
        let w = width, h = height
        for start in 0..<(w * h) where mask[start] != 0 && labels[start] == 0 {
            var shape = Shape()
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(start))
            labels[start] = next
            while let popped = stack.popLast() {
                let i = Int(popped)
                let x = i % w, y = i / w
                shape.area += 1
                shape.minX = min(shape.minX, x); shape.maxX = max(shape.maxX, x)
                shape.minY = min(shape.minY, y); shape.maxY = max(shape.maxY, y)
                if x > 0, mask[i - 1] != 0, labels[i - 1] == 0 { labels[i - 1] = next; stack.append(Int32(i - 1)) }
                if x + 1 < w, mask[i + 1] != 0, labels[i + 1] == 0 { labels[i + 1] = next; stack.append(Int32(i + 1)) }
                if y > 0, mask[i - w] != 0, labels[i - w] == 0 { labels[i - w] = next; stack.append(Int32(i - w)) }
                if y + 1 < h, mask[i + w] != 0, labels[i + w] == 0 { labels[i + w] = next; stack.append(Int32(i + w)) }
            }
            shapes.append(shape)
            next &+= 1
        }
        return shapes
    }
}
