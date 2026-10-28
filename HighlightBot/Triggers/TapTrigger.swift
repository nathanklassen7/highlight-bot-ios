import Foundation
import os
import HighlightCore

/// Trigger source fed by the Record screen's gestures: a whole-screen tap
/// saves a clip, a long-press toggles recording. The view calls `fireSave`
/// / `fireToggle`; events flow to the bus through the `emit` closure given
/// to `start`.
final class TapTrigger: TriggerSource {
    let id: TriggerSourceID = .tap

    private let emitter = OSAllocatedUnfairLock<(@Sendable (TriggerEvent) -> Void)?>(initialState: nil)

    init() {}

    func start(emit: @escaping @Sendable (TriggerEvent) -> Void) async throws {
        emitter.withLock { $0 = emit }
    }

    func stop() async {
        emitter.withLock { $0 = nil }
    }

    /// Whole-screen tap: save the coordinator's selected clip length.
    func fireSave() {
        send(.saveClip(seconds: nil))
    }

    /// Long-press: start or stop recording.
    func fireToggle() {
        send(.toggleRecording)
    }

    private func send(_ kind: TriggerKind) {
        guard let emit = emitter.withLock({ $0 }) else { return }
        emit(TriggerEvent(source: id, kind: kind))
    }
}
