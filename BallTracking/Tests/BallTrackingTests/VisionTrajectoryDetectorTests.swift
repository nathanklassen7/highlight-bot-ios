// BallTracking/Tests/BallTrackingTests/VisionTrajectoryDetectorTests.swift
import CoreGraphics
import CoreMedia
import Testing
@testable import BallTracking

struct VisionTrajectoryDetectorTests {
    @Test("wraps a pixel buffer in a timed sample buffer")
    func sampleBufferFactory() throws {
        let frame = SyntheticFrames.make420v(width: 320, height: 180)
        let time = CMTime(value: 30, timescale: 60)
        let sample = try SampleBufferFactory.make(pixelBuffer: frame, time: time, duration: CMTime(value: 1, timescale: 60))
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == time)
        #expect(CMSampleBufferGetImageBuffer(sample) != nil)
    }

    @Test("detects a synthetic ball on a parabolic path without throwing")
    func syntheticParabola() throws {
        let detector = VisionTrajectoryDetector(config: .init(trajectoryLength: 5,
                                                              minimumNormalizedRadius: 0.002,
                                                              maximumNormalizedRadius: 0.05,
                                                              frameDuration: CMTime(value: 1, timescale: 60)))
        var all: [BallObservation] = []
        for i in 0..<60 {
            let t = Double(i) / 60
            let x = 40 + 800 * t
            let y = 400 - 900 * t + 1400 * t * t
            let frame = SyntheticFrames.make420v(width: 960, height: 540, background: 30,
                                                 discs: [.init(center: CGPoint(x: x, y: y), radius: 6, luma: 235)])
            let observations = try detector.detect(pixelBuffer: frame, time: CMTime(value: CMTimeValue(i), timescale: 60))
            all.append(contentsOf: observations)
        }
        // Vision needs `trajectoryLength` frames before reporting; afterwards it
        // should have seen the disc. If this assertion fails on synthetic input
        // while the lab (Task 8) detects on real footage, relax it to `>= 0` and
        // say so in the commit message.
        #expect(!all.isEmpty)
        for observation in all {
            #expect((0...1).contains(observation.center.x))
            #expect((0...1).contains(observation.center.y))
        }
    }
}
