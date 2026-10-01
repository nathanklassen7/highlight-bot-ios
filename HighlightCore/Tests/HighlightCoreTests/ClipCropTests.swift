import CoreGraphics
import Foundation
import Testing
@testable import HighlightCore

@Suite("ClipCrop")
struct ClipCropTests {
    private func approx(_ lhs: Double, _ rhs: Double) -> Bool { abs(lhs - rhs) < 1e-9 }

    private func approx(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        approx(lhs.minX, rhs.minX) && approx(lhs.minY, rhs.minY)
            && approx(lhs.width, rhs.width) && approx(lhs.height, rhs.height)
    }

    @Test("identity shows the whole frame")
    func identity() {
        let crop = ClipCrop.identity
        #expect(crop.isIdentity)
        #expect(approx(crop.unitRect, CGRect(x: 0, y: 0, width: 1, height: 1)))
    }

    @Test("scale within the tolerance of 1 counts as identity")
    func identityTolerance() {
        #expect(ClipCrop(scale: 1.005, centerX: 0.3, centerY: 0.7).isIdentity)
        #expect(!ClipCrop(scale: 1.1, centerX: 0.5, centerY: 0.5).isIdentity)
    }

    @Test("clamped keeps scale between the minimum and maximum")
    func clampsScale() {
        #expect(ClipCrop(scale: 0.5, centerX: 0.5, centerY: 0.5).clamped().scale == ClipCrop.minimumScale)
        #expect(ClipCrop(scale: 9, centerX: 0.5, centerY: 0.5).clamped().scale == ClipCrop.maximumScale)
    }

    @Test("clamped keeps the visible region inside the frame")
    func clampsCenter() {
        let crop = ClipCrop(scale: 2, centerX: 0.05, centerY: 0.99).clamped()
        #expect(approx(crop.centerX, 0.25))
        #expect(approx(crop.centerY, 0.75))
        #expect(approx(crop.unitRect, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)))
    }

    @Test("clamped recentres at 1x")
    func clampsIdentityCenter() {
        let crop = ClipCrop(scale: 1, centerX: 0.1, centerY: 0.9).clamped()
        #expect(crop == .identity)
    }

    @Test("rect scales the unit rect to a frame size")
    func rectInSize() {
        let crop = ClipCrop(scale: 2, centerX: 0.5, centerY: 0.5)
        #expect(approx(crop.rect(in: CGSize(width: 1920, height: 1080)), CGRect(x: 480, y: 270, width: 960, height: 540)))
    }

    @Test("fillTransform maps the visible region onto the whole frame")
    func fillTransform() {
        let size = CGSize(width: 1920, height: 1080)
        let crop = ClipCrop(scale: 2, centerX: 0.25, centerY: 0.75)
        let mapped = crop.rect(in: size).applying(crop.fillTransform(for: size))
        #expect(approx(mapped, CGRect(origin: .zero, size: size)))
    }

    @Test("zoomed keeps the content under the anchor in place")
    func zoomAroundAnchor() {
        let start = ClipCrop.identity
        // The top-left quarter point of the view stays over the same content.
        let zoomed = start.zoomed(to: 2, anchorX: 0.25, anchorY: 0.25)
        #expect(zoomed.scale == 2)
        let rect = zoomed.unitRect
        #expect(approx(rect.minX + 0.25 * rect.width, 0.25))
        #expect(approx(rect.minY + 0.25 * rect.height, 0.25))
    }

    @Test("zoomed clamps the region back inside the frame")
    func zoomAtEdge() {
        let zoomed = ClipCrop.identity.zoomed(to: 4, anchorX: 1, anchorY: 0)
        let rect = zoomed.unitRect
        #expect(approx(rect.maxX, 1))
        #expect(approx(rect.minY, 0))
    }

    @Test("pinched moves the content under the start point to the end point")
    func pinchAndPan() {
        let start = ClipCrop(scale: 2, centerX: 0.5, centerY: 0.5)
        let before = start.unitRect
        let contentX = before.minX + 0.4 * before.width
        let contentY = before.minY + 0.6 * before.height

        let pinched = start.pinched(to: 3, fromX: 0.4, fromY: 0.6, toX: 0.5, toY: 0.5)
        #expect(pinched.scale == 3)
        let after = pinched.unitRect
        #expect(approx(after.minX + 0.5 * after.width, contentX))
        #expect(approx(after.minY + 0.5 * after.height, contentY))
    }

    @Test("pinched at the same scale matches panned")
    func pinchedAsPan() {
        let crop = ClipCrop(scale: 2, centerX: 0.5, centerY: 0.5)
        let pinched = crop.pinched(to: 2, fromX: 0.2, fromY: 0.5, toX: 0.4, toY: 0.3)
        let panned = crop.panned(byX: 0.2, y: -0.2)
        #expect(approx(pinched.centerX, panned.centerX))
        #expect(approx(pinched.centerY, panned.centerY))
    }

    @Test("pinched clamps the region back inside the frame")
    func pinchedAtEdge() {
        let pinched = ClipCrop(scale: 2, centerX: 0.5, centerY: 0.5)
            .pinched(to: 2, fromX: 0.5, fromY: 0.5, toX: 5, toY: -5)
        #expect(approx(pinched.unitRect, CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)))
    }

    @Test("panned moves the region against the drag, in view fractions")
    func pan() {
        let crop = ClipCrop(scale: 2, centerX: 0.5, centerY: 0.5)
        // Dragging right by half the view reveals content to the left.
        let panned = crop.panned(byX: 0.5, y: -0.25)
        #expect(approx(panned.centerX, 0.25))
        #expect(approx(panned.centerY, 0.625))
    }

    @Test("panned does nothing at 1x")
    func panIdentity() {
        #expect(ClipCrop.identity.panned(byX: 0.3, y: 0.3) == .identity)
    }

    @Test("round-trips through JSON")
    func codable() throws {
        let crop = ClipCrop(scale: 2.5, centerX: 0.4, centerY: 0.6)
        let data = try JSONEncoder().encode(crop)
        #expect(try JSONDecoder().decode(ClipCrop.self, from: data) == crop)
    }
}
