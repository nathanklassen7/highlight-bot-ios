import Foundation

/// Video codec used by the encoder. H.264 maximises share compatibility;
/// HEVC produces smaller files.
public enum VideoCodec: String, Codable, Sendable, CaseIterable, Identifiable {
    case h264
    case hevc

    public var id: String { rawValue }

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}
