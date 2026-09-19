import CoreGraphics
import Testing
@testable import BallTracking

struct OverlayGeometryTests {
    private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    @Test("aspect-fit letterboxes a 16:9 image in a square view")
    func aspectFit() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                                       gravity: .aspectFit, rotationDegrees: 0)
        #expect(abs(geometry.videoRect.minY - 87.5) < 0.01)
        #expect(abs(geometry.videoRect.width - 400) < 0.01)
        #expect(abs(geometry.videoRect.height - 225) < 0.01)
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 200, y: 200)))
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 87.5)))
        #expect(abs(geometry.length(forNormalizedWidthFraction: 0.01) - 4) < 0.001)
    }

    @Test("aspect-fill overflows the view and stays centred")
    func aspectFill() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                                       gravity: .aspectFill, rotationDegrees: 0)
        #expect(abs(geometry.videoRect.height - 400) < 0.001)
        #expect(abs(geometry.videoRect.width - 711.11) < 0.1)
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 200, y: 200)))
    }

    @Test("180° rotation mirrors both axes")
    func rotated180() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                       gravity: .aspectFit, rotationDegrees: 180)
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0.1, y: 0.2)), CGPoint(x: 1728, y: 864)))
    }

    @Test("90° clockwise rotation transposes the video rect and maps corners")
    func rotated90() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920),
                                       gravity: .aspectFit, rotationDegrees: 90)
        #expect(geometry.videoRect == CGRect(x: 0, y: 0, width: 1080, height: 1920))
        // Stored top-left lands at display top-right under clockwise rotation.
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0, y: 0)), CGPoint(x: 1080, y: 0)))
        // Radius as a fraction of stored width maps to the display height.
        #expect(abs(geometry.length(forNormalizedWidthFraction: 0.1) - 192) < 0.001)
    }

    @Test("explicit video rect is used verbatim")
    func explicitRect() {
        let geometry = OverlayGeometry(videoRect: CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(close(geometry.point(forNormalized: CGPoint(x: 1, y: 1)), CGPoint(x: 110, y: 70)))
    }
}
