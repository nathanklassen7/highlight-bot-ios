import Foundation

/// Capture size presets offered to the user, largest first.
///
/// `RecordingConfig` stores raw width and height so the encoder and format
/// picker never depend on this list; the preset is how the UI and the
/// capture rules talk about a size.
public enum CaptureResolution: String, Codable, Sendable, CaseIterable, Identifiable {
    case p1080
    case p720

    public var id: String { rawValue }

    /// Sensor-native (landscape) width in pixels.
    public var width: Int {
        switch self {
        case .p1080: 1920
        case .p720: 1280
        }
    }

    /// Sensor-native (landscape) height in pixels.
    public var height: Int {
        switch self {
        case .p1080: 1080
        case .p720: 720
        }
    }

    public var pixelCount: Int { width * height }

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .p1080: "1080p"
        case .p720: "720p"
        }
    }

    /// The preset for stored dimensions. Width decides: it is what the
    /// resolution picker writes, and a height left over from the previous
    /// preset must not keep the old answer.
    public init(width: Int, height: Int) {
        if let exact = Self.allCases.first(where: { $0.width == width }) {
            self = exact
        } else {
            self = width >= CaptureResolution.p1080.width ? .p1080 : .p720
        }
    }
}
