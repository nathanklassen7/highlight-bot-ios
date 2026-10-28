import Foundation
import HighlightCore
import Observation

/// Persists the user's `RecordingConfig` as JSON in `UserDefaults` and notifies
/// the container when it changes.
@MainActor
@Observable
final class SettingsStore {
    private static let key = "recordingConfig"

    /// Current configuration. Every mutation (including nested field edits via
    /// bindings) is persisted and forwarded to `onChange`.
    ///
    /// Capture rules are enforced here, not in the screens: whichever field
    /// the caller changed wins and the others give way (see
    /// `CaptureConstraints.resolve`). A resolved write re-enters `didSet`
    /// once; resolving is idempotent, so that pass persists and stops.
    var config: RecordingConfig {
        didSet {
            let changed = CaptureConstraints.changedField(from: oldValue, to: config)
            let resolved = config.resolved(keeping: changed)
            if resolved != config {
                config = resolved
                return
            }
            guard config != oldValue else { return }
            persist()
            onChange?(config)
        }
    }

    /// Called on the main actor after `config` changes. Set by `AppContainer`.
    @ObservationIgnored var onChange: (@MainActor (RecordingConfig) -> Void)?

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.config = Self.load(from: defaults) ?? .default
    }

    /// Restores `RecordingConfig.default`.
    func reset() {
        config = .default
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: Self.key)
    }

    private static func load(from defaults: UserDefaults) -> RecordingConfig? {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(RecordingConfig.self, from: data)
        else { return nil }
        // Ignore persisted configs that no longer validate (e.g. after a schema change).
        return decoded.validate().isEmpty ? decoded.resolved() : nil
    }
}
