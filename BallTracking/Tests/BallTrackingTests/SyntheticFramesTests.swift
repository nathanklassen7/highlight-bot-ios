import CoreGraphics
import CoreVideo
import Testing
@testable import BallTracking

struct SyntheticFramesTests {
    @Test("disc is bright, background is dark, format is 420v")
    func discAndBackground() {
        let frame = SyntheticFrames.make420v(width: 320, height: 180, background: 40,
                                             discs: [.init(center: CGPoint(x: 100, y: 90), radius: 5, luma: 230)])
        #expect(CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(SyntheticFrames.luma(of: frame, x: 100, y: 90) == 230)
        #expect(SyntheticFrames.luma(of: frame, x: 10, y: 10) == 40)
        #expect(SyntheticFrames.luma(of: frame, x: 100 + 8, y: 90) == 40)
    }
}
