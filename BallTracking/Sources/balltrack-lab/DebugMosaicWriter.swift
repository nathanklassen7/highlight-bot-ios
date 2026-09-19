import BallTracking
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

/// Writes `debug.mp4`: a 2×2 mosaic at half size — source | mask / candidates | track —
/// so one video shows which stage was wrong on any frame. Fed from
/// `ClipTrackRunner`'s `onFrame` hook, in stored orientation.
///
/// `@unchecked Sendable`: only ever touched from the runner's decode queue, which
/// calls `onFrame` serially; the closure that captures it has to be `@Sendable`.
final class DebugMosaicWriter: @unchecked Sendable {
    private let writer: BGRAVideoWriter
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let width: Int, height: Int
    private let quadrant: CGSize
    private var scratch: CVPixelBuffer?
    private var recent: [BallTrackFrame] = []

    init(output: URL, width: Int, height: Int) throws {
        self.width = width & ~1
        self.height = height & ~1
        quadrant = CGSize(width: Double(self.width) / 2, height: Double(self.height) / 2)
        writer = try BGRAVideoWriter(output: output, width: self.width, height: self.height, bitRate: 12_000_000)
    }

    func append(_ event: ClipTrackFrameEvent) throws {
        let dest = try writer.makeBuffer()
        let time = event.time.seconds
        recent.append(event.frame)
        recent.removeAll { time - $0.time > 0.6 }

        let topLeft = CGRect(origin: .zero, size: quadrant)
        let topRight = CGRect(origin: CGPoint(x: quadrant.width, y: 0), size: quadrant)
        let bottomLeft = CGRect(origin: CGPoint(x: 0, y: quadrant.height), size: quadrant)
        let bottomRight = CGRect(origin: CGPoint(x: quadrant.width, y: quadrant.height), size: quadrant)

        // Source into three quadrants. CoreImage is bottom-left origin; flip the rects.
        let source = CIImage(cvPixelBuffer: event.pixelBuffer)
        let scale = quadrant.width / source.extent.width
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        for rect in [topLeft, bottomLeft, bottomRight] {
            let ciRect = CGRect(x: rect.minX, y: Double(height) - rect.maxY, width: rect.width, height: rect.height)
            let placed = scaled.transformed(by: CGAffineTransform(translationX: ciRect.minX, y: ciRect.minY))
            ciContext.render(placed, to: dest, bounds: ciRect, colorSpace: CGColorSpaceCreateDeviceRGB())
        }

        // Mask into the top-right quadrant.
        if let detector = event.detector as? MotionCandidateDetector, detector.mask.hasMask {
            let mask = detector.mask
            let scratch = try scratchBuffer(width: mask.width, height: mask.height)
            LabDrawing.fillGrey(mask.pixels, width: mask.width, height: mask.height, into: scratch)
            LabDrawing.blit(scratch, into: dest, rect: topRight)
        } else {
            LabDrawing.withContext(on: dest) { context, _, _ in
                context.setFillColor(CGColor(gray: 0, alpha: 1))
                context.fill(topRight)
            }
        }

        let fw = Double(width), fh = Double(height)
        let model = (event.stage as? TrajectoryFitter)?.currentModel
        LabDrawing.withContext(on: dest) { context, _, _ in
            // Candidates quadrant.
            context.saveGState()
            context.translateBy(x: bottomLeft.minX, y: bottomLeft.minY)
            context.scaleBy(x: 0.5, y: 0.5)
            CandidatesCommand.draw(event.candidates, in: context, width: fw, height: fh)
            context.restoreGState()

            // Track quadrant: parabola over its window, trail, ring.
            context.saveGState()
            context.translateBy(x: bottomRight.minX, y: bottomRight.minY)
            context.scaleBy(x: 0.5, y: 0.5)
            if let model {
                var curve: [CGPoint] = []
                var t = time - 0.24
                while t <= time + 0.04 {
                    curve.append(model.position(at: t))
                    t += 0.005
                }
                LabDrawing.strokePolyline(context, points: curve, color: CGColor(red: 0.3, green: 0.8, blue: 1, alpha: 0.9), lineWidth: 2)
            }
            let trail = Self.trail(recent, endingAt: time, duration: 0.4).map { CGPoint(x: $0.x * fw, y: $0.y * fh) }
            LabDrawing.strokePolyline(context, points: trail, color: CGColor(gray: 1, alpha: 0.8), lineWidth: 3)
            if event.frame.isVisible, let position = event.frame.position {
                let center = CGPoint(x: position.x * fw, y: position.y * fh)
                let radius = max(14, (event.frame.radius ?? 0.005) * fw * 2.5)
                let color = event.frame.state == .tracking
                    ? CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
                    : CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)
                LabDrawing.strokeCircle(context, center: center, radius: radius, color: color, lineWidth: 4)
            }
            context.restoreGState()

            // Separators and labels.
            context.setStrokeColor(CGColor(gray: 0.4, alpha: 1))
            context.setLineWidth(2)
            context.strokeLineSegments(between: [CGPoint(x: quadrant.width, y: 0), CGPoint(x: quadrant.width, y: fh),
                                                 CGPoint(x: 0, y: quadrant.height), CGPoint(x: fw, y: quadrant.height)])
            let label = String(format: "f%05d  t%.3f", event.index, time)
            LabDrawing.drawText("\(label)  source", in: context, at: CGPoint(x: 12, y: 10), size: 20)
            LabDrawing.drawText("mask", in: context, at: CGPoint(x: topRight.minX + 12, y: 10), size: 20)
            LabDrawing.drawText("candidates=\(event.candidates.count)", in: context, at: CGPoint(x: 12, y: bottomLeft.minY + 10), size: 20)
            var trackLabel = event.frame.state.rawValue
            if let model {
                let v = model.velocity(at: time)
                trackLabel += String(format: "  v=%.0f px/s  e=%.0f", hypot(v.dx, v.dy), model.e)
            }
            if let fitter = event.stage as? TrajectoryFitter {
                trackLabel += "  segments=\(fitter.segments.count)"
            }
            LabDrawing.drawText(trackLabel, in: context, at: CGPoint(x: bottomRight.minX + 12, y: bottomRight.minY + 10), size: 20)
        }

        try writer.append(dest, at: event.time)
    }

    func finish() throws {
        try writer.finish()
    }

    private func scratchBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        if let scratch, CVPixelBufferGetWidth(scratch) == width, CVPixelBufferGetHeight(scratch) == height {
            return scratch
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let buffer else { throw LabError.failed("cannot allocate scratch buffer") }
        scratch = buffer
        return buffer
    }

    /// Same rule as `BallTrack.trail`: tracking positions back to the last `.searching` frame.
    private static func trail(_ frames: [BallTrackFrame], endingAt time: TimeInterval, duration: TimeInterval) -> [CGPoint] {
        var points: [CGPoint] = []
        for frame in frames.reversed() where frame.time <= time {
            if time - frame.time > duration || frame.state == .searching { break }
            if frame.state == .tracking, let p = frame.position { points.append(p) }
        }
        return points.reversed()
    }
}
