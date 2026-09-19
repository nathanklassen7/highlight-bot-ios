import CoreGraphics
import Testing
@testable import BallTracking

struct FrameOrientationTests {
    private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.001) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    @Test("identity transform leaves points alone")
    func identity() {
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: .identity)
        #expect(orientation.displaySize == CGSize(width: 1920, height: 1080))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 0.25, y: 0.75)), CGPoint(x: 0.25, y: 0.75)))
        #expect(orientation.normalizedRadius(0.01) == 0.01)
    }

    @Test("180° transform mirrors both axes and flips velocity")
    func rotated180() {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: transform)
        #expect(orientation.displaySize == CGSize(width: 1920, height: 1080))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 0.25, y: 0.75)), CGPoint(x: 0.75, y: 0.25)))
        let v = orientation.normalizedVector(CGVector(dx: 1, dy: -0.5))
        #expect(abs(v.dx + 1) < 0.001 && abs(v.dy - 0.5) < 0.001)
    }

    @Test("90° clockwise transform swaps display size and maps top-left to top-right")
    func rotated90() {
        // Standard portrait transform for a 1920x1080 stored frame.
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: transform)
        #expect(orientation.displaySize == CGSize(width: 1080, height: 1920))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 0, y: 0)), CGPoint(x: 1, y: 0)))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 1, y: 1)), CGPoint(x: 0, y: 1)))
        #expect(abs(orientation.normalizedRadius(0.01) - 0.01 * 1920 / 1080) < 0.0001)
    }

    @Test("apply(to:) maps a track frame's position, velocity, and radius")
    func applyToFrame() {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: transform)
        let frame = BallTrackFrame(time: 1, state: .tracking, position: CGPoint(x: 0.1, y: 0.2),
                                   velocity: CGVector(dx: 2, dy: 0), radius: 0.01, candidateCount: 1)
        let mapped = orientation.apply(to: frame)
        #expect(close(mapped.position!, CGPoint(x: 0.9, y: 0.8)))
        #expect(abs(mapped.velocity!.dx + 2) < 0.001)
        #expect(mapped.state == .tracking)
        let searching = BallTrackFrame(time: 1, state: .searching, position: nil, velocity: nil, radius: nil, candidateCount: 0)
        #expect(orientation.apply(to: searching) == searching)
    }

    @Test("static rotate covers the four quadrants")
    func rotateHelper() {
        let p = CGPoint(x: 0.1, y: 0.2)
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 0), p))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 90), CGPoint(x: 0.8, y: 0.1)))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 180), CGPoint(x: 0.9, y: 0.8)))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 270), CGPoint(x: 0.2, y: 0.9)))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: -90), CGPoint(x: 0.2, y: 0.9)))
    }
}
