import CoreGraphics
import CoreVideo
import Testing
@testable import BallTracking

struct MotionMaskTests {
    private let width = 640
    private let height = 360

    /// Pixels inside a disc, using the same inclusion rule as `SyntheticFrames.make420v`.
    private func footprint(_ disc: SyntheticFrames.Disc) -> Set<Int> {
        var set = Set<Int>()
        let r2 = disc.radius * disc.radius
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) + 0.5 - disc.center.x
                let dy = Double(y) + 0.5 - disc.center.y
                if dx * dx + dy * dy <= r2 { set.insert(y * width + x) }
            }
        }
        return set
    }

    private func dilated(_ set: Set<Int>) -> Set<Int> {
        var out = Set<Int>()
        for i in set {
            let x = i % width, y = i / width
            for dy in -1...1 {
                for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < width, ny >= 0, ny < height { out.insert(ny * width + nx) }
                }
            }
        }
        return out
    }

    private func onPixels(_ mask: MotionMask) -> Set<Int> {
        var set = Set<Int>()
        for (i, v) in mask.pixels.enumerated() where v != 0 { set.insert(i) }
        return set
    }

    @Test("first frame yields no mask; a moving disc yields exactly both footprints, dilated once")
    func movingDisc() {
        var mask = MotionMask()
        let d0 = SyntheticFrames.Disc(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)
        let d1 = SyntheticFrames.Disc(center: CGPoint(x: 116, y: 176), radius: 4, luma: 230)
        let f0 = SyntheticFrames.make420v(width: width, height: height, discs: [d0])
        let f1 = SyntheticFrames.make420v(width: width, height: height, discs: [d1])

        #expect(mask.update(pixelBuffer: f0) == false)
        #expect(mask.hasMask == false)
        #expect(mask.update(pixelBuffer: f1) == true)
        #expect(mask.width == width && mask.height == height)
        #expect(mask.pixels.count == width * height)

        let expected = dilated(footprint(d0).symmetricDifference(footprint(d1)))
        let actual = onPixels(mask)
        #expect(actual == expected)
        #expect(mask.pixels.allSatisfy { $0 == 0 || $0 == 255 })
    }

    @Test("a disc that overlaps itself only masks the changed pixels")
    func overlappingDisc() {
        var mask = MotionMask()
        let d0 = SyntheticFrames.Disc(center: CGPoint(x: 200, y: 100), radius: 6, luma: 230)
        let d1 = SyntheticFrames.Disc(center: CGPoint(x: 203, y: 100), radius: 6, luma: 230)
        mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, discs: [d0]))
        mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, discs: [d1]))
        let expected = dilated(footprint(d0).symmetricDifference(footprint(d1)))
        #expect(onPixels(mask) == expected)
    }

    @Test("a static frame produces an empty mask")
    func staticFrame() {
        var mask = MotionMask()
        let frame = SyntheticFrames.make420v(width: width, height: height, discs: [.init(center: CGPoint(x: 300, y: 100), radius: 5, luma: 240)])
        mask.update(pixelBuffer: frame)
        #expect(mask.update(pixelBuffer: frame) == true)
        #expect(onPixels(mask).isEmpty)
    }

    @Test("threshold is applied in full-range grey units, matching the approved ffmpeg render")
    func thresholdInFullRangeUnits() {
        // Video-range luma is expanded by 255/219 before differencing, as ffmpeg's
        // `format=gray` does. A raw step of 40 (≈47 full-range) stays below 60; a raw
        // step of 60 (≈70 full-range) crosses it.
        var below = MotionMask()
        below.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, background: 40))
        below.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, background: 40,
                                                            discs: [.init(center: CGPoint(x: 100, y: 100), radius: 5, luma: 80)]))
        #expect(onPixels(below).isEmpty)

        var above = MotionMask()
        above.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, background: 40))
        above.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, background: 40,
                                                            discs: [.init(center: CGPoint(x: 100, y: 100), radius: 5, luma: 100)]))
        let disc = SyntheticFrames.Disc(center: CGPoint(x: 100, y: 100), radius: 5, luma: 100)
        #expect(onPixels(above) == dilated(footprint(disc)))
    }

    @Test("currentLuma and previousLuma expose the two frames in full range")
    func lumaPlanes() {
        var mask = MotionMask()
        mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, background: 40,
                                                          discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)]))
        mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, background: 40,
                                                          discs: [.init(center: CGPoint(x: 116, y: 176), radius: 4, luma: 230)]))
        let expanded230 = UInt8(((230.0 - 16) * 255 / 219).rounded())
        let expanded40 = UInt8(((40.0 - 16) * 255 / 219).rounded())
        #expect(mask.currentLuma[176 * width + 116] == expanded230)
        #expect(mask.currentLuma[180 * width + 100] == expanded40)
        #expect(mask.previousLuma[180 * width + 100] == expanded230)
        #expect(mask.previousLuma[176 * width + 116] == expanded40)
    }

    @Test("reset forgets the previous frame")
    func resetForgets() {
        var mask = MotionMask()
        mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)]))
        mask.reset()
        #expect(mask.hasMask == false)
        #expect(mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height, discs: [.init(center: CGPoint(x: 116, y: 180), radius: 4, luma: 230)])) == false)
    }

    @Test("a frame size change restarts the pair")
    func sizeChangeRestarts() {
        var mask = MotionMask()
        mask.update(pixelBuffer: SyntheticFrames.make420v(width: width, height: height))
        #expect(mask.update(pixelBuffer: SyntheticFrames.make420v(width: 320, height: 180)) == false)
        #expect(mask.update(pixelBuffer: SyntheticFrames.make420v(width: 320, height: 180)) == true)
        #expect(mask.width == 320 && mask.height == 180)
    }
}
