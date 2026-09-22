import Foundation

/// How a clip is oriented in the UI and montage prompt, derived from stored
/// width and height after the capture transform.
public enum ClipOrientation: String, Sendable, Codable, CaseIterable {
    case landscape
    case portrait
    case square
    case unknown

    /// Classifies oriented pixel dimensions. Missing sizes (`0`) yield
    /// `.unknown` so legacy records decode safely before backfill.
    public static func classify(width: Int, height: Int) -> ClipOrientation {
        guard width > 0, height > 0 else { return .unknown }
        if width == height { return .square }
        return width > height ? .landscape : .portrait
    }

    /// Every clip written before portrait support is landscape by construction;
    /// treat `.unknown` as landscape anywhere a montage or layout decision runs.
    public var effective: ClipOrientation {
        switch self {
        case .unknown: .landscape
        default: self
        }
    }

    /// Short label for confirmation dialogs and footer copy.
    public var displayName: String {
        switch effective {
        case .landscape: "Landscape"
        case .portrait: "Portrait"
        case .square: "Square"
        case .unknown: "Landscape"
        }
    }
}
