import Foundation
import Testing
@testable import HighlightCore

@Suite("RecordingConfig")
struct RecordingConfigTests {
    @Test("defaults match the plan")
    func defaults() {
        let config = RecordingConfig.default
        #expect(config.bufferSeconds == 20)
        #expect(config.segmentInterval == 5)
        #expect(config.width == 1920)
        #expect(config.height == 1080)
        #expect(config.frameRate == 60)
        #expect(config.videoBitrate == 10_000_000)
        #expect(config.codec == .h264)
        #expect(config.recordAudio == true)
        #expect(config.inactivityTimeout == 45 * 60)
        #expect(config.minimumFreeBytes == 500 * 1024 * 1024)
        #expect(config.debugOverlayEnabled == false)
        #expect(RecordingConfig.bufferOptions == [10, 20, 30, 60])
        #expect(RecordingConfig() == config)
    }

    @Test("default config validates clean")
    func defaultIsValid() {
        #expect(RecordingConfig.default.validate().isEmpty)
    }

    @Test("segmentsPerBuffer rounds up and retainSeconds adds one interval")
    func derivedValues() {
        var config = RecordingConfig.default
        #expect(config.segmentsPerBuffer == 4)
        #expect(config.retainSeconds == 25)

        config.bufferSeconds = 22
        #expect(config.segmentsPerBuffer == 5)
        #expect(config.retainSeconds == 27)

        config.bufferSeconds = 0.9
        config.segmentInterval = 0.3
        #expect(config.segmentsPerBuffer == 3)

        config.segmentInterval = 0
        #expect(config.segmentsPerBuffer == 0)
    }

    @Test("validate reports each problem once")
    func validation() {
        var config = RecordingConfig.default
        config.bufferSeconds = 2
        #expect(config.validate() == [.bufferTooShort])

        config = .default
        config.segmentInterval = 0
        #expect(config.validate() == [.segmentIntervalInvalid])

        config = .default
        config.frameRate = 0
        config.width = 0
        config.videoBitrate = -1
        config.inactivityTimeout = 0
        let errors = config.validate()
        #expect(errors == [.frameRateInvalid, .resolutionInvalid, .bitrateInvalid, .inactivityTimeoutInvalid])
        for error in errors {
            #expect(!error.description.isEmpty)
        }
    }

    @Test("round-trips through JSON")
    func codable() throws {
        var config = RecordingConfig.default
        config.codec = .hevc
        config.bufferSeconds = 30
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(RecordingConfig.self, from: data)
        #expect(decoded == config)
    }

    @Test("codec display names")
    func codecNames() {
        #expect(VideoCodec.h264.displayName == "H.264")
        #expect(VideoCodec.hevc.displayName == "HEVC")
        #expect(VideoCodec.allCases.map(\.id) == ["h264", "hevc"])
    }

    @Test("RingBufferPolicy from config uses retainSeconds")
    func policyFromConfig() {
        let policy = RingBufferPolicy(config: .default)
        #expect(policy.retainSeconds == 25)
    }
}
