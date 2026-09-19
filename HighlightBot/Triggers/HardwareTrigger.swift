import Foundation
import AVFoundation
import AVKit   // AVCaptureEventInteraction / AVCaptureEvent live in AVKit, not AVFoundation.
import UIKit
import SwiftUI
import os
import HighlightCore

/// Hardware capture buttons: volume up/down, Camera Control (iPhone 16), and
/// Bluetooth camera shutters such as the AB Shutter3 (which presents as
/// volume-up). Delivered by `AVCaptureEventInteraction`, which iOS only
/// activates while the app is foreground *and* an `AVCaptureSession` is
/// running; otherwise the buttons keep their normal volume behaviour.
///
/// Both primary and secondary presses save a clip. Toggling recording is a
/// deliberate long-press in the UI, never a hardware button, to avoid
/// accidentally stopping a session mid-game.
final class HardwareTrigger: TriggerSource {
    let id: TriggerSourceID = .hardwareButton

    private let emitter = OSAllocatedUnfairLock<(@Sendable (TriggerEvent) -> Void)?>(initialState: nil)

    init() {}

    func start(emit: @escaping @Sendable (TriggerEvent) -> Void) async throws {
        emitter.withLock { $0 = emit }
    }

    func stop() async {
        emitter.withLock { $0 = nil }
    }

    /// Volume-up / Camera Control / shutter button 1.
    func firePrimary() {
        send(.saveClip(seconds: nil), label: "primary")
    }

    /// Volume-down / shutter button 2.
    func fireSecondary() {
        send(.saveClip(seconds: nil), label: "secondary")
    }

    private func send(_ kind: TriggerKind, label: String) {
        let emit = emitter.withLock { $0 }
        guard let emit else {
            Log.ui.notice("HardwareTrigger \(label, privacy: .public) fired before start(); ignoring")
            return
        }
        Log.ui.info("HardwareTrigger \(label, privacy: .public) press")
        emit(TriggerEvent(source: id, kind: kind))
    }
}

/// Hosts the `AVCaptureEventInteraction` on a transparent, non-hit-testable
/// `UIView`. Place it anywhere inside `RecordScreen`; it must be in a visible
/// window for events to arrive.
struct HardwareTriggerHost: UIViewRepresentable {
    let trigger: HardwareTrigger

    /// Keeps the interaction alive for the view's lifetime.
    final class Coordinator {
        var interaction: AVCaptureEventInteraction?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        // VERIFY: capture events are not touches, so the interaction should still fire
        // with user interaction disabled. If it does not, re-enable and rely on
        // `.allowsHitTesting(false)` on the SwiftUI side so the tap gesture underneath
        // keeps working.
        view.isUserInteractionEnabled = false

        let trigger = self.trigger
        // VERIFY: AVCaptureEventInteraction(primary:secondary:) initializer signature and
        // AVCaptureEvent.phase (.began / .ended / .cancelled), iOS 17.2+, from AVKit. The
        // header is not in the macOS SDK on this machine so it could not be checked here.
        //
        // Fire on `.began` (button down) rather than `.ended`: it shaves the hold time off
        // trigger latency, and it matches the Pi controller, which acts on key-down and
        // ignores repeat/up so one press is always exactly one clip.
        let interaction = AVCaptureEventInteraction(
            primary: { event in
                if event.phase == .began { trigger.firePrimary() }
            },
            secondary: { event in
                if event.phase == .began { trigger.fireSecondary() }
            }
        )
        interaction.isEnabled = true
        view.addInteraction(interaction)
        context.coordinator.interaction = interaction
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.interaction?.isEnabled = true
    }
}
