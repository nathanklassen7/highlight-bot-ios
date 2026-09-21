import Foundation
import Testing
@testable import HighlightCore

@Suite("ExportEstimate")
struct ExportEstimateTests {
    private let hd = 1920.0 * 1080.0

    @Test("one second of 1080p60 straight encode is one unit")
    func referenceUnit() {
        let load = ExportWorkload(outputSeconds: 10, frameRate: 60, pixelCount: hd, retimedSeconds: 0)
        #expect(abs(load.units - 10) < 1e-9)
    }

    @Test("units scale with frame rate and pixel count")
    func density() {
        let uhd30 = ExportWorkload(outputSeconds: 10, frameRate: 30, pixelCount: 3840 * 2160, retimedSeconds: 0)
        // Half the frames, four times the pixels.
        #expect(abs(uhd30.units - 20) < 1e-9)
        let hd120 = ExportWorkload(outputSeconds: 10, frameRate: 120, pixelCount: hd, retimedSeconds: 0)
        #expect(abs(hd120.units - 20) < 1e-9)
    }

    @Test("retimed seconds add retimingWeight on top")
    func retiming() {
        let load = ExportWorkload(outputSeconds: 10, frameRate: 60, pixelCount: hd, retimedSeconds: 4)
        #expect(abs(load.units - (10 + 4 * ExportWorkload.retimingWeight)) < 1e-9)
    }

    @Test("zero or negative frame rate and pixel count do not produce NaN or zero work")
    func degenerateInputs() {
        let load = ExportWorkload(outputSeconds: 5, frameRate: 0, pixelCount: 0, retimedSeconds: 0)
        #expect(load.units.isFinite)
        #expect(load.units > 0)
    }

    @Test("totalSeconds is units times speed with a floor")
    func total() {
        #expect(abs(ExportTimeEstimate(units: 10, secondsPerUnit: 0.3).totalSeconds - 3) < 1e-9)
        #expect(ExportTimeEstimate(units: 0.1, secondsPerUnit: 0.3).totalSeconds == ExportTimeEstimate.minimumTotalSeconds)
        let fromLoads = ExportTimeEstimate(
            workloads: [
                ExportWorkload(outputSeconds: 10, frameRate: 60, pixelCount: hd, retimedSeconds: 0),
                ExportWorkload(outputSeconds: 5, frameRate: 60, pixelCount: hd, retimedSeconds: 0),
            ],
            secondsPerUnit: 0.5
        )
        #expect(abs(fromLoads.units - 15) < 1e-9)
        #expect(abs(fromLoads.totalSeconds - 7.5) < 1e-9)
    }

    @Test("before real progress the up-front estimate stands")
    func remainingEarly() {
        let estimate = ExportTimeEstimate(units: 100, secondsPerUnit: 0.3) // 30 s
        #expect(abs(estimate.remainingSeconds(progress: 0, elapsed: 0) - 30) < 1e-9)
        #expect(abs(estimate.remainingSeconds(progress: 0.02, elapsed: 5) - 30 * 0.98) < 1e-9)
    }

    @Test("once progress is established the elapsed-time projection takes over")
    func remainingLate() {
        let estimate = ExportTimeEstimate(units: 100, secondsPerUnit: 0.3) // model says 30 s
        // Half done after 10 s: projection says 10 s left; model said 15. At 50% the weight is 1.
        #expect(abs(estimate.remainingSeconds(progress: 0.5, elapsed: 10) - 10) < 1e-9)
        // Encoder slower than the model: projection wins too.
        #expect(abs(estimate.remainingSeconds(progress: 0.5, elapsed: 40) - 40) < 1e-9)
    }

    @Test("remaining blends between model and projection in the ramp")
    func remainingBlend() {
        let estimate = ExportTimeEstimate(units: 100, secondsPerUnit: 0.3) // 30 s
        // progress 0.175 is halfway through the 0.05...0.30 ramp → weight 0.5
        let model = 30 * (1 - 0.175)
        let projected = 10.0 / 0.175 * (1 - 0.175)
        let expected = model * 0.5 + projected * 0.5
        #expect(abs(estimate.remainingSeconds(progress: 0.175, elapsed: 10) - expected) < 1e-9)
    }

    @Test("remaining is clamped to non-negative and progress to 0...1")
    func remainingClamp() {
        let estimate = ExportTimeEstimate(units: 10, secondsPerUnit: 0.3)
        #expect(estimate.remainingSeconds(progress: 1, elapsed: 100) == 0)
        #expect(estimate.remainingSeconds(progress: 1.5, elapsed: 1) == 0)
        #expect(abs(estimate.remainingSeconds(progress: -1, elapsed: 0) - estimate.totalSeconds) < 1e-9)
    }

    @Test("calibration is an equal-weight moving average that ignores junk")
    func calibration() {
        #expect(ExportTimeEstimate.calibrated(previous: nil, observedSecondsPerUnit: 0.5) == 0.5)
        #expect(abs(ExportTimeEstimate.calibrated(previous: 0.5, observedSecondsPerUnit: 0.3) - 0.4) < 1e-9)
        #expect(ExportTimeEstimate.calibrated(previous: 0.4, observedSecondsPerUnit: 0) == 0.4)
        #expect(ExportTimeEstimate.calibrated(previous: 0.4, observedSecondsPerUnit: .nan) == 0.4)
        #expect(ExportTimeEstimate.calibrated(previous: nil, observedSecondsPerUnit: -1) == ExportTimeEstimate.defaultSecondsPerUnit)
    }
}
