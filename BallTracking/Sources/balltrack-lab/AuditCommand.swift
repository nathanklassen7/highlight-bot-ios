import BallTracking
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// `audit --track DIR/track.json --input clip.mp4 --out DIR [--frames 12]`
/// The check that caught the earlier false tracks: on evenly spaced `.tracking`
/// frames, crop 80×45 px of the *raw* clip around the reported position, upscale 6×
/// nearest-neighbour, mark the centre, tile 4×3. If the ball is not under the marker
/// in ≥ 10 of 12 tiles the tracker is wrong, whatever the summary says.
/// Assumes the clip needs no display rotation (true of the reference footage).
struct AuditCommand {
    let options: Options

    private static let cropWidth = 80
    private static let cropHeight = 45
    private static let zoom = 6
    private static let columns = 4

    func run() async throws {
        let trackURL = expandPath(try options.required("track"))
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        let count = max(1, options.int("frames", default: 12))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let track = try JSONDecoder().decode(BallTrack.self, from: Data(contentsOf: trackURL))
        let clip = try await ClipFrames(url: input)
        if Int(track.displaySize.width) != clip.width || Int(track.displaySize.height) != clip.height {
            print("warning: track display size \(track.displaySize) differs from stored frame \(clip.width)×\(clip.height); positions may be rotated")
        }

        let trackingIndices = track.frames.indices.filter { track.frames[$0].state == .tracking }
        guard !trackingIndices.isEmpty else {
            print("No .tracking frames in \(trackURL.path); nothing to audit.")
            return
        }
        var chosen: [Int] = []
        for k in 0..<count {
            let position = count == 1 ? 0 : Int((Double(k) * Double(trackingIndices.count - 1) / Double(count - 1)).rounded())
            let index = trackingIndices[position]
            if chosen.last != index { chosen.append(index) }
        }
        let wanted = Set(chosen.map { track.frames[$0].time })
        let tileSize = CGSize(width: Self.cropWidth * Self.zoom, height: Self.cropHeight * Self.zoom)
        let rows = (chosen.count + Self.columns - 1) / Self.columns
        let sheetWidth = Int(tileSize.width) * Self.columns
        let sheetHeight = Int(tileSize.height) * rows

        struct Tile: Sendable { var index: Int; var time: Double; var x: Double; var y: Double; var pixels: [UInt8] }
        let fw = Double(clip.width), fh = Double(clip.height)
        let tiles: [Tile] = try await onBackgroundQueue {
            let ciContext = CIContext(options: [.cacheIntermediates: false])
            var scratch: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, clip.width, clip.height, kCVPixelFormatType_32BGRA, nil, &scratch)
            guard let scratch else { throw LabError.failed("cannot allocate scratch buffer") }
            var tiles: [Tile] = []
            var remaining = wanted
            try clip.forEach { index, pts, pixelBuffer in
                guard let trackIndex = track.index(nearest: pts.seconds),
                      remaining.contains(track.frames[trackIndex].time),
                      let position = track.frames[trackIndex].position else { return true }
                remaining.remove(track.frames[trackIndex].time)
                ciContext.render(CIImage(cvPixelBuffer: pixelBuffer), to: scratch)
                let cx = position.x * fw, cy = position.y * fh
                tiles.append(Tile(index: index, time: pts.seconds, x: cx, y: cy,
                                  pixels: Self.zoomedCrop(from: scratch, centerX: cx, centerY: cy)))
                return !remaining.isEmpty
            }
            return tiles
        }

        // Compose the sheet.
        let bytesPerRow = sheetWidth * 4
        var sheet = [UInt8](repeating: 0, count: bytesPerRow * sheetHeight)
        let tileW = Int(tileSize.width), tileH = Int(tileSize.height)
        for (n, tile) in tiles.enumerated() {
            let ox = (n % Self.columns) * tileW, oy = (n / Self.columns) * tileH
            for y in 0..<tileH {
                let src = y * tileW * 4
                let dst = (oy + y) * bytesPerRow + ox * 4
                sheet.replaceSubrange(dst..<(dst + tileW * 4), with: tile.pixels[src..<(src + tileW * 4)])
            }
        }
        var lines = ""
        sheet.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: sheetWidth, height: sheetHeight, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return }
            context.translateBy(x: 0, y: CGFloat(sheetHeight))
            context.scaleBy(x: 1, y: -1)
            for (n, tile) in tiles.enumerated() {
                let ox = Double((n % Self.columns) * tileW), oy = Double((n / Self.columns) * tileH)
                let center = CGPoint(x: ox + tileSize.width / 2, y: oy + tileSize.height / 2)
                context.setStrokeColor(CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1))
                context.setLineWidth(2)
                context.strokeLineSegments(between: [CGPoint(x: center.x - 40, y: center.y), CGPoint(x: center.x - 12, y: center.y),
                                                     CGPoint(x: center.x + 12, y: center.y), CGPoint(x: center.x + 40, y: center.y),
                                                     CGPoint(x: center.x, y: center.y - 40), CGPoint(x: center.x, y: center.y - 12),
                                                     CGPoint(x: center.x, y: center.y + 12), CGPoint(x: center.x, y: center.y + 40)])
                context.setStrokeColor(CGColor(gray: 0.5, alpha: 1))
                context.stroke(CGRect(x: ox, y: oy, width: tileSize.width, height: tileSize.height))
                LabDrawing.drawText(String(format: "f%05d t%.2f (%.0f,%.0f)", tile.index, tile.time, tile.x, tile.y),
                                    in: context, at: CGPoint(x: ox + 8, y: oy + 6), size: 18)
                lines += String(format: "f%05d t=%.3f x=%.1f y=%.1f\n", tile.index, tile.time, tile.x, tile.y)
            }
            if let image = context.makeImage() {
                let url = outDir.appending(path: "audit.png")
                if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                    print("Wrote \(url.path) (\(tiles.count) tiles; \(trackingIndices.count) tracking frames in track)")
                }
            }
        }
        try lines.write(to: outDir.appending(path: "audit.txt"), atomically: true, encoding: .utf8)
        print(lines, terminator: "")
    }

    /// 80×45 crop around (cx, cy) from a BGRA buffer, scaled 6× nearest-neighbour;
    /// pixels outside the frame are black.
    private static func zoomedCrop(from buffer: CVPixelBuffer, centerX: Double, centerY: Double) -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let outW = cropWidth * zoom, outH = cropHeight * zoom
        var out = [UInt8](repeating: 0, count: outW * outH * 4)
        let x0 = Int(centerX.rounded()) - cropWidth / 2
        let y0 = Int(centerY.rounded()) - cropHeight / 2
        for oy in 0..<outH {
            let sy = y0 + oy / zoom
            guard sy >= 0, sy < height else { continue }
            for ox in 0..<outW {
                let sx = x0 + ox / zoom
                guard sx >= 0, sx < width else { continue }
                let s = sy * rowBytes + sx * 4
                let d = (oy * outW + ox) * 4
                out[d] = base[s]; out[d + 1] = base[s + 1]; out[d + 2] = base[s + 2]; out[d + 3] = 255
            }
        }
        return out
    }
}
