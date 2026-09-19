import Foundation

/// User-facing recording settings. Persisted by the app as JSON.
///
/// The defaults match the decided values in `docs/ios-app-plan.md` §6:
/// 20 s buffer, 5 s segments, 1080p60 H.264 at ~10 Mbps with AAC audio.
public struct RecordingConfig: Codable, Sendable, Equatable {
    /// Length of footage the user wants when they trigger a save (seconds).
    public var bufferSeconds: TimeInterval
    /// Duration of each fMP4 media segment produced by the recorder (seconds).
    public var segmentInterval: TimeInterval
    /// Capture width in pixels.
    public var width: Int
    /// Capture height in pixels.
    public var height: Int
    /// Capture frame rate in frames per second.
    public var frameRate: Int
    /// Target video bitrate in bits per second.
    public var videoBitrate: Int
    /// Video codec used by the encoder.
    public var codec: VideoCodec
    /// Whether audio is recorded alongside video.
    public var recordAudio: Bool
    /// Seconds without a save trigger before recording stops automatically.
    public var inactivityTimeout: TimeInterval
    /// Minimum free disk space required to start recording, in bytes.
    public var minimumFreeBytes: Int64
    /// Whether the debug metrics overlay is shown.
    public var debugOverlayEnabled: Bool

    public init(
        bufferSeconds: TimeInterval = 20,
        segmentInterval: TimeInterval = 5,
        width: Int = 1920,
        height: Int = 1080,
        frameRate: Int = 60,
        videoBitrate: Int = 10_000_000,
        codec: VideoCodec = .h264,
        recordAudio: Bool = true,
        inactivityTimeout: TimeInterval = 45 * 60,
        minimumFreeBytes: Int64 = 500 * 1024 * 1024,
        debugOverlayEnabled: Bool = false
    ) {
        self.bufferSeconds = bufferSeconds
        self.segmentInterval = segmentInterval
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoBitrate = videoBitrate
        self.codec = codec
        self.recordAudio = recordAudio
        self.inactivityTimeout = inactivityTimeout
        self.minimumFreeBytes = minimumFreeBytes
        self.debugOverlayEnabled = debugOverlayEnabled
    }

    /// The default configuration.
    public static let `default` = RecordingConfig()

    /// Buffer lengths offered in the UI picker, in seconds.
    public static let bufferOptions: [TimeInterval] = [10, 20, 30, 60]

    /// Number of media segments needed to cover `bufferSeconds`, rounded up.
    /// Returns 0 when `segmentInterval` is invalid.
    public var segmentsPerBuffer: Int {
        guard segmentInterval > 0, segmentInterval.isFinite, bufferSeconds > 0 else { return 0 }
        // Subtract a tiny epsilon so that ratios which are integral in decimal
        // (e.g. 0.9 / 0.3) do not round up because of binary representation.
        let ratio = bufferSeconds / segmentInterval - 1e-9
        return max(1, Int(ratio.rounded(.up)))
    }

    /// Seconds the ring must retain so that a whole-segment clip can always
    /// cover `bufferSeconds`: `bufferSeconds + segmentInterval`.
    public var retainSeconds: TimeInterval {
        bufferSeconds + segmentInterval
    }

    /// Returns every validation problem; an empty array means the config is valid.
    public func validate() -> [ConfigError] {
        var errors: [ConfigError] = []
        let segmentIntervalValid = segmentInterval > 0 && segmentInterval.isFinite
        if !segmentIntervalValid {
            errors.append(.segmentIntervalInvalid)
        }
        if !(bufferSeconds > 0 && bufferSeconds.isFinite)
            || (segmentIntervalValid && bufferSeconds < segmentInterval) {
            errors.append(.bufferTooShort)
        }
        if frameRate <= 0 {
            errors.append(.frameRateInvalid)
        }
        if width <= 0 || height <= 0 {
            errors.append(.resolutionInvalid)
        }
        if videoBitrate <= 0 {
            errors.append(.bitrateInvalid)
        }
        if !(inactivityTimeout > 0 && inactivityTimeout.isFinite) {
            errors.append(.inactivityTimeoutInvalid)
        }
        return errors
    }
}
