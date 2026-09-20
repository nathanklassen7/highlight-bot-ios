import AVFoundation
import Foundation

/// Beep-and-flash patterns that acknowledge a save trigger and report how it
/// ended: 1 beep when the save is accepted, 3 when the clip is on disk, 5 when
/// it failed. The camera torch pulses with every beep.
///
/// Audio goes through `AVAudioPlayer` rather than System Sound Services
/// because iOS suppresses system sounds while an `AVCaptureSession` has a
/// microphone attached, which is exactly when saves happen. While the capture
/// session is live (`.playAndRecord`) the beep ignores the Ring/Silent switch,
/// so callers gate on `RecordingConfig.saveBeepEnabled`.
///
/// Patterns run one after another so a fast save never plays its 3 beeps on
/// top of the acknowledgement beep.
@MainActor
final class SaveFeedback {
    /// Which outputs a pattern uses. Beep and flash are toggled independently
    /// in Settings; with neither selected the pattern is skipped.
    struct Channels: OptionSet, Sendable {
        let rawValue: UInt8
        static let beep = Channels(rawValue: 1 << 0)
        static let flash = Channels(rawValue: 1 << 1)
        static let all: Channels = [.beep, .flash]
    }

    /// Matches the length of `clip-saved.wav`.
    private static let beepDuration: Duration = .milliseconds(140)
    private static let gapDuration: Duration = .milliseconds(120)

    private let setTorch: @Sendable (Bool) async -> Void
    private var player: AVAudioPlayer?
    private var playerUnavailable = false
    private var queue: Task<Void, Never>?

    /// `setTorch` is called on the main actor; implementations hop to their
    /// own queue as needed.
    init(setTorch: @escaping @Sendable (Bool) async -> Void) {
        self.setTorch = setTorch
    }

    /// A save trigger was accepted and the clip is being written.
    func acknowledge(_ channels: Channels) { play(pulses: 1, channels: channels) }

    /// The clip is on disk.
    func succeeded(_ channels: Channels) { play(pulses: 3, channels: channels) }

    /// The save failed.
    func failed(_ channels: Channels) { play(pulses: 5, channels: channels) }

    // MARK: - Private

    private func play(pulses count: Int, channels: Channels) {
        guard !channels.isEmpty else { return }
        let previous = queue
        queue = Task { @MainActor [weak self] in
            await previous?.value
            for index in 0..<count {
                guard let self else { return }
                if index > 0 {
                    try? await Task.sleep(for: Self.gapDuration)
                }
                if channels.contains(.flash) { await self.setTorch(true) }
                if channels.contains(.beep) { self.beep() }
                try? await Task.sleep(for: Self.beepDuration)
                if channels.contains(.flash) { await self.setTorch(false) }
            }
        }
    }

    private func beep() {
        guard let player = player ?? makePlayer() else { return }
        player.currentTime = 0
        if !player.play() {
            Log.ui.error("Save beep failed to start.")
        }
    }

    private func makePlayer() -> AVAudioPlayer? {
        guard !playerUnavailable else { return nil }
        guard let url = Bundle.main.url(forResource: "clip-saved", withExtension: "wav") else {
            playerUnavailable = true
            Log.ui.error("clip-saved.wav missing from the app bundle; save beep disabled.")
            return nil
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            return player
        } catch {
            playerUnavailable = true
            Log.ui.error("Save beep could not be loaded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
