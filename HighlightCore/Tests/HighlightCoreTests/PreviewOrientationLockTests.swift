import Foundation
import Testing
@testable import HighlightCore

@Suite("PreviewOrientationLock")
struct PreviewOrientationLockTests {
    @Test("covering size swaps on a quarter turn and not on a half turn")
    func coveringSize() {
        let portrait = PreviewOrientationLock.coveringSize(
            parentWidth: 393,
            parentHeight: 852,
            rotationRadians: 0
        )
        #expect(portrait.width == 393)
        #expect(portrait.height == 852)

        let quarter = PreviewOrientationLock.coveringSize(
            parentWidth: 852,
            parentHeight: 393,
            rotationRadians: -.pi / 2
        )
        #expect(quarter.width == 393)
        #expect(quarter.height == 852)

        let half = PreviewOrientationLock.coveringSize(
            parentWidth: 852,
            parentHeight: 393,
            rotationRadians: .pi
        )
        #expect(half.width == 852)
        #expect(half.height == 393)
    }

    @Test("animated counter-rotation inverts the interface delta with QA1890's short-way bias")
    func nextAnimatedRotation() {
        let next = PreviewOrientationLock.nextAnimatedRotation(
            current: 0,
            interfaceDelta: .pi / 2
        )
        #expect(next == -.pi / 2 + PreviewOrientationLock.shortWayBias)

        #expect(
            PreviewOrientationLock.nextAnimatedRotation(current: -.pi / 2, interfaceDelta: 0)
                == -.pi / 2
        )
    }
}
