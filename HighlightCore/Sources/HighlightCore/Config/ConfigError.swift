import Foundation

/// A single validation failure reported by `RecordingConfig.validate()`.
public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    /// `bufferSeconds` is not positive or is shorter than one segment.
    case bufferTooShort
    /// `segmentInterval` is not a positive, finite number of seconds.
    case segmentIntervalInvalid
    /// `frameRate` is not positive.
    case frameRateInvalid
    /// `width` or `height` is not positive.
    case resolutionInvalid
    /// `videoBitrate` is not positive.
    case bitrateInvalid
    /// `inactivityTimeout` is not positive.
    case inactivityTimeoutInvalid

    public var description: String {
        switch self {
        case .bufferTooShort:
            "Buffer length must be positive and at least one segment interval long."
        case .segmentIntervalInvalid:
            "Segment interval must be a positive number of seconds."
        case .frameRateInvalid:
            "Frame rate must be a positive number of frames per second."
        case .resolutionInvalid:
            "Width and height must both be positive."
        case .bitrateInvalid:
            "Video bitrate must be positive."
        case .inactivityTimeoutInvalid:
            "Inactivity timeout must be a positive number of seconds."
        }
    }
}
