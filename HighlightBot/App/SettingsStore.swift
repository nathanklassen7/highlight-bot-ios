import Foundation
import HighlightCore
import Observation
import os

/// Persists the user's `RecordingConfig` as JSON in `UserDefaults` and notifies
/// the container when it changes.
@MainActor
@Observable
final class SettingsStore {
    private static let key = "recordingConfig"

    /// Current configuration. Every mutation (including nested field edits via
    /// bindings) is persisted and forwarded to `onChange`.
    var config: RecordingConfig {
        didSet {
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
        do {
            let data = try JSONEncoder().encode(config)
            defaults.set(data, forKey: Self.key)
        } catch {
            Log.ui.error("Failed to persist recording config: \(String(describing: error))")
        }
    }

    private static func load(from defaults: UserDefaults) -> RecordingConfig? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            let decoded = try JSONDecoder().decode(RecordingConfig.self, from: data)
            // Ignore persisted configs that no longer validate (e.g. after a schema change).
            return decoded.validate().isEmpty ? decoded : nil
        } catch {
            Log.ui.error("Failed to decode persisted recording config; using defaults: \(String(describing: error))")
            return nil
        }
    }
}
