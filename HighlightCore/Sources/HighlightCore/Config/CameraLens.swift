import Foundation

/// Which back camera feeds the session. The ultra-wide sees roughly twice
/// the field of view but supports fewer formats; when it cannot run the
/// requested frame rate the capture layer picks the nearest it can.
public enum CameraLens: String, Codable, Sendable, CaseIterable, Identifiable {
    case wide
    case ultraWide

    public var id: String { rawValue }

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .wide: "Wide (1×)"
        case .ultraWide: "Ultra Wide (0.5×)"
        }
    }

    /// Short zoom-style label for in-viewfinder controls.
    public var shortLabel: String {
        switch self {
        case .wide: "1×"
        case .ultraWide: "0.5×"
        }
    }

    /// The other lens.
    public var toggled: CameraLens {
        self == .wide ? .ultraWide : .wide
    }
}
