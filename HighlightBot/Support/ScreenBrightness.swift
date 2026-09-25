import UIKit

/// Backlight control for dimmed mode. A brightness set by an app stays in
/// effect until the device locks, even after the app leaves the foreground,
/// so whoever lowers it is responsible for putting it back.
@MainActor
enum ScreenBrightness {
    /// The screen the app is currently drawing on, or nil before any scene
    /// is connected.
    private static var screen: UIScreen? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        return scene?.screen
    }

    static var current: CGFloat? {
        screen?.brightness
    }

    static func set(_ value: CGFloat) {
        screen?.brightness = min(1, max(0, value))
    }
}
