import Foundation

/// Which camera feeds the session.
///
/// Back lenses are separate physical cameras. Ultra-wide falls back to wide
/// when the device has none. Selfie is the front camera at its default field
/// of view. What each lens can run lives in `CaptureConstraints`.
public enum CameraLens: String, Codable, Sendable, CaseIterable, Identifiable {
    case wide
    case ultraWide
    case selfie

    public var id: String { rawValue }

    /// Human-readable name for settings UI.
    public var displayName: String {
        switch self {
        case .wide: "Wide (1×)"
        case .ultraWide: "Ultra Wide (0.5×)"
        case .selfie: "Selfie"
        }
    }

    /// Short zoom-style label for the in-viewfinder control.
    public var shortLabel: String {
        switch self {
        case .wide: "1×"
        case .ultraWide: "0.5×"
        case .selfie: "Selfie"
        }
    }

    /// SF Symbol drawn on the record-screen lens button in place of a zoom label.
    /// Nil for the back cameras, whose zoom label is enough to tell them apart.
    public var buttonSymbol: String? {
        isSelfie ? "person.crop.square" : nil
    }

    /// Front-facing lens.
    public var isSelfie: Bool {
        self == .selfie
    }

    /// The lens the record-screen button advances to.
    public var next: CameraLens {
        switch self {
        case .wide: .ultraWide
        case .ultraWide: .selfie
        case .selfie: .wide
        }
    }

    /// Earlier builds stored a second selfie zoom step. It is the same camera.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "selfieUltraWide" {
            self = .selfie
            return
        }
        guard let lens = Self(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown camera lens \(raw)"
            )
        }
        self = lens
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
