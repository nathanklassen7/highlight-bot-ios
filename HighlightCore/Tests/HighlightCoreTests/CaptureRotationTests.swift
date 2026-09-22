import Foundation
import Testing
@testable import HighlightCore

@Suite("CaptureRotation")
struct CaptureRotationTests {
    @Test("snapped angles from the design checklist")
    func designAngles() {
        #expect(CaptureRotation.snapped(-10) == 0)
        #expect(CaptureRotation.snapped(44) == 0)
        #expect(CaptureRotation.snapped(45) == 90)
        #expect(CaptureRotation.snapped(89) == 90)
        #expect(CaptureRotation.snapped(91) == 90)
        #expect(CaptureRotation.snapped(269) == 270)
        #expect(CaptureRotation.snapped(315) == 0)
        #expect(CaptureRotation.snapped(359) == 0)
        #expect(CaptureRotation.snapped(450) == 90)
    }

    @Test("cardinal snaps are idempotent")
    func idempotentCardinals() {
        for angle in [0.0, 90, 180, 270] {
            #expect(CaptureRotation.snapped(angle) == angle)
        }
    }

    @Test("large and negative angles fold into 0..360 before snapping")
    func normalization() {
        #expect(CaptureRotation.snapped(720) == 0)
        #expect(CaptureRotation.snapped(-90) == 270)
    }
}
