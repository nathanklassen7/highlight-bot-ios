import BallTracking
import Foundation
import Observation

/// Ball-tracking settings that are not part of `RecordingConfig`. Backed by
/// `UserDefaults` so they survive relaunches.
@MainActor
@Observable
final class TrackingPreferences {
    private enum Key {
        static let playerOverlay = "tracking.playerOverlayEnabled"
        static let liveOverlay = "tracking.liveOverlayEnabled"
        static let detector = "tracking.detectorKind"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the clip player shows the ball overlay once a track exists.
    var playerOverlayEnabled: Bool {
        didSet { defaults.set(playerOverlayEnabled, forKey: Key.playerOverlay) }
    }

    /// Whether the Record screen runs live tracking (phase 2).
    var liveOverlayEnabled: Bool {
        didSet { defaults.set(liveOverlayEnabled, forKey: Key.liveOverlay) }
    }

    /// Detector used for new analyses. Debug-only picker in Settings.
    var detectorKind: BallDetectorKind {
        didSet { defaults.set(detectorKind.rawValue, forKey: Key.detector) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playerOverlayEnabled = defaults.object(forKey: Key.playerOverlay) as? Bool ?? true
        liveOverlayEnabled = defaults.bool(forKey: Key.liveOverlay)
        detectorKind = defaults.string(forKey: Key.detector).flatMap(BallDetectorKind.init(rawValue:)) ?? .default
    }
}
