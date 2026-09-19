import HighlightCore
import SwiftUI
import UIKit

/// Live preview. The whole screen is the trigger target: tap saves a clip
/// (or starts recording when idle), long-press toggles recording.
struct RecordScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.scenePhase) private var scenePhase

    @State private var isDimmed = false
    @State private var playerRecord: ClipRecord?
    @State private var recordingStartedAt: Date?

    var body: some View {
        ZStack {
            if permissionsSatisfied {
                captureStack
            } else {
                PermissionsGateView()
            }

            if let message = container.errorMessage {
                VStack {
                    ErrorBanner(message: message)
                        .padding(.top, 8)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 0.2), value: container.errorMessage)
        .fullScreenCover(item: $playerRecord) { record in
            ClipPlayerScreen(record: record)
        }
        .onChange(of: container.sessionState) { oldState, newState in
            if newState.isRecording && !oldState.isRecording {
                recordingStartedAt = .now
            }
            if !newState.isRecording {
                recordingStartedAt = nil
                isDimmed = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                container.permissions.refresh()
            }
        }
        // Keep the viewfinder live whenever we may use the camera: on appear,
        // after permissions are granted, and after returning to the foreground.
        .task(id: previewKey) {
            guard permissionsSatisfied, scenePhase != .background else { return }
            await container.startPreview()
        }
        .task(id: container.errorMessage) {
            guard container.errorMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            container.errorMessage = nil
        }
    }

    // MARK: - Capture stack

    private var captureStack: some View {
        ZStack {
            PreviewLayerView(source: container.pipeline.source)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Zero-size host for AVCaptureEventInteraction (volume / Camera Control / BT shutter).
            HardwareTriggerHost(trigger: container.hardwareTrigger)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)

            controlsOverlay

            if isDimmed {
                DimmedModeView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .onLongPressGesture(minimumDuration: 0.6) { handleLongPress() }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    statusIndicator
                    if container.settings.config.debugOverlayEnabled {
                        DebugOverlay(metrics: container.metrics)
                    }
                }
                Spacer()
                if pendingSaves > 0 {
                    SavingBadge(count: pendingSaves)
                }
                dimButton
            }

            Spacer()

            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    bufferBar
                    clipSecondsPicker
                }
                Spacer()
                recordButton
                Spacer()
                lastClipButton
                    .frame(width: 112, alignment: .trailing)
            }
        }
        .padding(16)
    }

    // MARK: - Overlay pieces

    @ViewBuilder
    private var statusIndicator: some View {
        Group {
            switch container.sessionState {
            case .idle:
                Label("Tap to start", systemImage: "hand.tap")
            case .starting:
                HStack(spacing: 6) {
                    ProgressView().tint(.white)
                    Text("Starting…")
                }
            case .recording:
                TimelineView(.periodic(from: recordingStartedAt ?? .now, by: 0.5)) { context in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(.red)
                            .frame(width: 12, height: 12)
                            .opacity(recDotLit(at: context.date) ? 1 : 0)
                        Text("REC")
                            .fontWeight(.bold)
                        Text(elapsedText(at: context.date))
                            .monospacedDigit()
                    }
                }
            case .interrupted:
                Label("Interrupted", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .stopping:
                HStack(spacing: 6) {
                    ProgressView().tint(.white)
                    Text("Stopping…")
                }
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var dimButton: some View {
        Button {
            isDimmed = true
        } label: {
            Image(systemName: "moon.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dim screen")
    }

    private var bufferBar: some View {
        let total = max(container.settings.config.bufferSeconds, 1)
        let buffered = min(container.metrics.bufferedSeconds, total)
        return VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: buffered, total: total)
                .tint(.red)
                .frame(width: 200)
            Text("\(Int(buffered.rounded(.down)))s / \(Int(total))s buffered")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()
        }
    }

    private var clipSecondsPicker: some View {
        let bufferSeconds = container.settings.config.bufferSeconds
        return HStack(spacing: 6) {
            ForEach(RecordingConfig.bufferOptions, id: \.self) { seconds in
                let enabled = seconds <= bufferSeconds
                let selected = seconds == container.selectedClipSeconds
                Button {
                    container.setClipSeconds(seconds)
                } label: {
                    Text("\(Int(seconds))s")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(selected ? Color.white : Color.white.opacity(0.2), in: Capsule())
                        .foregroundStyle(selected ? .black : .white)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.35)
                .accessibilityLabel("Clip length \(Int(seconds)) seconds")
            }
        }
    }

    private var recordButton: some View {
        let state = container.sessionState
        let busy = state == .starting || state == .stopping
        return Button {
            container.toggleRecording()
        } label: {
            Image(systemName: state.isRecording ? "stop.fill" : "record.circle")
                .font(.title2.weight(.semibold))
                .foregroundStyle(state.isRecording ? .white : .red)
                .frame(width: 56, height: 56)
                .background(.black.opacity(0.55), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .accessibilityLabel(state.isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private var lastClipButton: some View {
        if let last = container.lastClip {
            Button {
                playerRecord = last
            } label: {
                ThumbnailImage(url: last.thumbnailURL)
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
                    .overlay(alignment: .bottomTrailing) {
                        Text(durationText(last.duration))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open last clip")
        } else {
            Color.clear.frame(width: 96, height: 54)
        }
    }

    // MARK: - Gestures

    private func handleTap() {
        if container.sessionState.isRecording {
            container.tapTrigger.fireSave()
        } else if container.sessionState == .idle && !isDimmed {
            container.toggleRecording()
        }
    }

    private func handleLongPress() {
        if isDimmed {
            isDimmed = false
            return
        }
        container.tapTrigger.fireToggle()
    }

    // MARK: - Helpers

    /// Changes whenever a preview (re)start might be needed.
    private var previewKey: String {
        "\(permissionsSatisfied)-\(scenePhase == .background)"
    }

    private var permissionsSatisfied: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let permissions = container.permissions
        let microphoneOK = !container.settings.config.recordAudio || permissions.microphone == .granted
        return permissions.camera == .granted && microphoneOK
        #endif
    }

    private var pendingSaves: Int {
        if case .recording(let pending) = container.sessionState {
            return pending
        }
        return 0
    }

    private func recDotLit(at date: Date) -> Bool {
        guard let start = recordingStartedAt else { return true }
        let elapsed = max(0, date.timeIntervalSince(start))
        return Int(elapsed / 0.5) % 2 == 0
    }

    private func elapsedText(at date: Date) -> String {
        guard let start = recordingStartedAt else { return "0:00" }
        return durationText(max(0, date.timeIntervalSince(start)))
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .minuteSecond))
    }
}

// MARK: - Subviews

/// "Saving…" pill shown while the coordinator has pending saves.
private struct SavingBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().tint(.white)
            Text(count > 1 ? "Saving \(count)…" : "Saving…")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.85), in: Capsule())
    }
}

/// Transient red banner for `AppContainer.errorMessage`.
private struct ErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.red.opacity(0.9), in: Capsule())
            .accessibilityAddTraits(.isStaticText)
    }
}

/// Opaque black overlay for long sessions. Taps still save; long-press wakes.
private struct DimmedModeView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 4) {
                Text("Screen dimmed")
                Text("Tap to save · Hold to wake")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.25))
        }
        .accessibilityLabel("Screen dimmed. Tap to save a clip, hold to wake.")
    }
}

/// Shown until camera (and, if audio is on, microphone) access is granted.
private struct PermissionsGateView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openURL) private var openURL

    var body: some View {
        let permissions = container.permissions
        let needsMic = container.settings.config.recordAudio
        let anyDenied = [permissions.camera, permissions.microphone].contains { $0 == .denied || $0 == .restricted }

        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)
            Text("Highlight Bot needs camera\(needsMic ? " and microphone" : "") access")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Video is recorded continuously into a short buffer on this device. Nothing is saved until you tap.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)

            HStack(spacing: 24) {
                PermissionRow(title: "Camera", status: permissions.camera) {
                    _ = await permissions.requestCamera()
                }
                PermissionRow(title: needsMic ? "Microphone" : "Microphone (optional)", status: permissions.microphone) {
                    _ = await permissions.requestMicrophone()
                }
            }

            if anyDenied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        openURL(url)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { permissions.refresh() }
    }
}

/// One permission with its current status and an Allow button when undetermined.
private struct PermissionRow: View {
    let title: String
    let status: PermissionStatus
    let request: @MainActor () async -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
            switch status {
            case .notDetermined:
                Button("Allow") {
                    Task { await request() }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .denied:
                Label("Denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .restricted:
                Label("Restricted", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.footnote)
    }
}
