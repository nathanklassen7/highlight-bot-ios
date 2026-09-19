import UIKit

/// Thin wrappers around UIKit feedback generators for trigger/save feedback.
@MainActor
enum Haptics {
    /// A clip was written to disk.
    static func saved() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    /// A save or start failed.
    static func error() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    /// Recording was started or stopped.
    static func toggled() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
