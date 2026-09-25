import Foundation
import Testing
@testable import HighlightCore

@Suite("FrameRatePolicy")
struct FrameRatePolicyTests {
    @Test("idle viewfinder runs at the idle rate")
    func idle() {
        #expect(FrameRatePolicy.target(configured: 60, isRecording: false, thermalState: .nominal, lowPowerMode: false) == 30)
        #expect(FrameRatePolicy.target(configured: 120, isRecording: false, thermalState: .nominal, lowPowerMode: false) == 30)
    }

    @Test("idle never raises a lower configured rate")
    func idleRespectsConfigured() {
        #expect(FrameRatePolicy.target(configured: 24, isRecording: false, thermalState: .nominal, lowPowerMode: false) == 24)
    }

    @Test("recording at nominal or fair thermal runs the configured rate")
    func recordingNominal() {
        #expect(FrameRatePolicy.target(configured: 60, isRecording: true, thermalState: .nominal, lowPowerMode: false) == 60)
        #expect(FrameRatePolicy.target(configured: 120, isRecording: true, thermalState: .fair, lowPowerMode: false) == 120)
    }

    @Test("serious or critical thermal drops to the reduced rate")
    func recordingHot() {
        #expect(FrameRatePolicy.target(configured: 60, isRecording: true, thermalState: .serious, lowPowerMode: false) == 30)
        #expect(FrameRatePolicy.target(configured: 120, isRecording: true, thermalState: .critical, lowPowerMode: false) == 30)
        #expect(FrameRatePolicy.target(configured: 30, isRecording: true, thermalState: .critical, lowPowerMode: false) == 30)
    }

    @Test("Low Power Mode drops to the reduced rate regardless of thermal")
    func lowPower() {
        #expect(FrameRatePolicy.target(configured: 60, isRecording: true, thermalState: .nominal, lowPowerMode: true) == 30)
        #expect(FrameRatePolicy.target(configured: 24, isRecording: true, thermalState: .nominal, lowPowerMode: true) == 24)
    }
}
