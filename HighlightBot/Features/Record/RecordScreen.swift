import HighlightCore
import SwiftUI
import UIKit

/// Live preview. While recording the whole screen is the trigger target: tap
/// saves a clip, long-press stops. Idle, only the shutter (or a long-press)
/// starts a session, so a stray tap cannot begin recording.
///
/// The chrome follows the iPhone Camera app so the controls land where a
/// Camera user already expects them: small toggles in a strip along the top,
/// the lens picker as zoom pills above the shutter, the clip length where the
/// mode strip sits, and a bottom bar of last-clip thumbnail, shutter, and
/// flip-camera. `RootView`'s tab pill sits in the middle of the top strip
/// while idle; the thumbnail is a second way into the Library.
struct RecordScreen: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var isDimmed = false
    @State private var recordingStartedAt: Date?
    @State private var showTagPicker = false
    /// Back lens the flip button returns to from selfie.
    @State private var lastBackLens: CameraLens = .wide

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
        .onChange(of: container.sessionState) { oldState, newState in
            if newState.isRecording && !oldState.isRecording {
                recordingStartedAt = .now
            }
            if !newState.isRecording {
                recordingStartedAt = nil
                if newState != .starting {
                    isDimmed = false
                }
            }
        }
        .onChange(of: container.settings.config.lens, initial: true) { _, lens in
            if !lens.isSelfie {
                lastBackLens = lens
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
        .task(id: container.saveCallout) {
            guard container.saveCallout != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            container.saveCallout = nil
        }
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet(
                title: "Recording Tags",
                initialSelection: container.tagPreferences.activeTags,
                footnote: "New clips are tagged with these as they are saved."
            ) { tags in
                container.tagPreferences.activeTags = tags
            }
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

            if isDimmed {
                DimmedModeView(isRecording: container.sessionState.isRecording)
            }

            controlsOverlay
        }
        .contentShape(Rectangle())
        .onTapGesture { handleTap() }
        .onLongPressGesture(minimumDuration: 0.6) { handleLongPress() }
    }

    /// Phones held sideways get the Camera app's landscape arrangement: the
    /// shutter column on the trailing edge with the lens and clip-length
    /// pickers beside it. Everything else uses the portrait stack.
    private var isLandscapePhone: Bool {
        verticalSizeClass == .compact
    }

    private var controlsOverlay: some View {
        ZStack {
            if !isDimmed {
                scrims
            }
            if isLandscapePhone {
                landscapeControls
            } else {
                portraitControls
            }
        }
        .allowsHitTesting(!isDimmed)
    }

    /// Soft darkening behind the top strip and bottom bar so white chrome
    /// stays legible over a bright viewfinder. Camera letterboxes instead;
    /// the preview here is full-bleed, so a gradient does the same job.
    private var scrims: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 120)
            Spacer()
            LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                .frame(height: isLandscapePhone ? 0 : 260)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var portraitControls: some View {
        VStack(spacing: 0) {
            topStrip
            if showsDebugOverlay {
                DebugOverlay(metrics: container.metrics)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            Spacer()

            if !isDimmed {
                lensPills
                    .padding(.bottom, 18)
                clipLengthStrip
                    .padding(.bottom, 22)
                bottomBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var landscapeControls: some View {
        ZStack {
            VStack(spacing: 0) {
                topStrip
                if showsDebugOverlay {
                    DebugOverlay(metrics: container.metrics)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 8)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if !isDimmed {
                HStack(alignment: .center, spacing: 20) {
                    Spacer()
                    lensPills(axis: .vertical)
                    clipLengthStrip(axis: .vertical)
                    shutterColumn
                }
                .padding(.trailing, 16)
                .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Top strip

    /// Camera's top row: toggles at the edges, the live status in the middle.
    /// Save outcome and buffer fill hang under the status so the eye only has
    /// one place to look while recording.
    private var topStrip: some View {
        // Top-aligned so the edge buttons hold still while the status block
        // grows downward (buffer bar, save badge).
        ZStack(alignment: .top) {
            HStack(spacing: 10) {
                if !isDimmed {
                    voiceButton
                }
                dimButton
                Spacer(minLength: 0)
                if !isDimmed {
                    activeTagsButton
                }
            }
            // In landscape the shutter column owns the trailing edge; the
            // status block stays centred on the screen regardless.
            .padding(.trailing, isLandscapePhone ? Self.landscapeShutterColumnWidth : 0)

            VStack(spacing: 8) {
                statusIndicator
                bufferIndicator
                saveStatusBadge
            }
        }
    }

    /// Nothing while idle: the shutter is the only start control.
    @ViewBuilder
    private var statusIndicator: some View {
        if container.sessionState != .idle {
            statusPill
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        Group {
            switch container.sessionState {
            case .idle:
                EmptyView()
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
                            .frame(width: 10, height: 10)
                            .opacity(recDotLit(at: context.date) ? 1 : 0)
                        Text(elapsedText(at: context.date))
                            .monospacedDigit()
                        if container.isVoiceListening {
                            Image(systemName: "waveform")
                                .accessibilityLabel("Listening for “clip it”")
                        }
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
        .padding(.vertical, 7)
        .background(container.sessionState.isRecording ? Color.red.opacity(0.85) : .black.opacity(0.55), in: Capsule())
    }

    /// How much of the clip length is already in the ring. Matters most in the
    /// first seconds of a session, when a tap would save a short clip.
    @ViewBuilder
    private var bufferIndicator: some View {
        if container.sessionState.isRecording, !isDimmed {
            let total = max(container.settings.config.bufferSeconds, 1)
            let buffered = min(container.metrics.bufferedSeconds, total)
            VStack(spacing: 3) {
                ProgressView(value: buffered, total: total)
                    .tint(buffered >= total ? .white : .red)
                    .frame(width: 96)
                Text(buffered >= total ? "\(Int(total))s ready" : "\(Int(buffered.rounded(.down)))s / \(Int(total))s")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .shadow(color: .black.opacity(0.6), radius: 2)
            }
        }
    }

    /// Turns the "clip it" trigger on and off without a trip to Settings.
    /// Unlike the lens, this is safe mid-session: the recogniser reads the
    /// microphone buffers the capture session is already delivering. With
    /// audio recording off the microphone only opens on the next start, which
    /// is the one case where the switch does nothing until then.
    private var voiceButton: some View {
        let listening = container.settings.config.voiceTriggerEnabled
        // VERIFY: "person.wave.2" and its .fill variant ship in SF Symbols 5 /
        // iOS 17; a missing name renders empty rather than crashing.
        return Button {
            toggleVoiceTrigger()
        } label: {
            StripIcon(systemImage: listening ? "person.wave.2.fill" : "person.wave.2", tint: listening ? .yellow : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Voice trigger")
        .accessibilityValue(listening ? "On" : "Off")
        .accessibilityHint(listening ? "Stops listening for “clip it”" : "Saves a clip when you say “clip it”")
    }

    /// Permission is requested on the way on, the same as the Settings toggle;
    /// `AppContainer` reports anything still missing through `errorMessage`.
    private func toggleVoiceTrigger() {
        let enabling = !container.settings.config.voiceTriggerEnabled
        container.settings.config.voiceTriggerEnabled = enabling
        guard enabling else { return }
        Task {
            _ = await container.permissions.requestMicrophone()
            _ = await container.permissions.requestSpeech()
        }
    }

    /// Outlined at rest, yellow and filled while the screen is dimmed. The
    /// dimmed overlay swallows taps for saving, so waking is by long-press.
    private var dimButton: some View {
        Button {
            isDimmed = true
        } label: {
            StripIcon(systemImage: isDimmed ? "moon.fill" : "moon", tint: isDimmed ? .yellow : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dim screen")
        .accessibilityValue(isDimmed ? "On" : "Off")
        .accessibilityHint(isDimmed ? "Hold anywhere to wake" : "")
    }

    private var activeTagsButton: some View {
        let activeTags = container.tagPreferences.activeTags
        return Button {
            showTagPicker = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                if activeTags.isEmpty {
                    Text("Tags")
                } else {
                    TagPillRow(tags: activeTags, limit: 1, size: .compact)
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.black.opacity(0.55), in: Capsule())
        }
        .buttonStyle(.plain)
        // Leaves room for the icon-only tab pill between this and the toggles.
        .frame(maxWidth: 110, alignment: .trailing)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Recording tags")
        .accessibilityValue(activeTags.isEmpty ? "None" : activeTags.joined(separator: ", "))
    }

    private var showsDebugOverlay: Bool {
        !isDimmed && container.settings.config.debugOverlayEnabled
    }

    // MARK: - Lens pills

    private enum ControlAxis {
        case horizontal, vertical
    }

    private var lensPills: some View {
        lensPills(axis: .horizontal)
    }

    /// Camera's zoom cluster: one round pill per back lens, the active one
    /// larger and yellow. Selfie lives on the flip button, so while the front
    /// camera is up no pill is lit and tapping one comes back to that lens.
    /// Lens changes reconfigure the camera, so the pills lock while a session
    /// is live.
    private func lensPills(axis: ControlAxis) -> some View {
        let current = container.settings.config.lens
        let locked = lensLocked
        let pills = ForEach(Self.backLenses) { lens in
            let selected = lens == current
            Button {
                container.settings.config.lens = lens
            } label: {
                Text(Self.pillLabel(for: lens, selected: selected))
                    .font(.system(size: selected ? 13 : 11, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.yellow : Color.white)
                    .frame(width: selected ? 38 : 30, height: selected ? 38 : 30)
                    .background(.black.opacity(0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lens: \(lens.displayName)")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        return Group {
            switch axis {
            case .horizontal: HStack(spacing: 8) { pills }
            case .vertical: VStack(spacing: 8) { pills }
            }
        }
        .padding(4)
        .background(.black.opacity(0.25), in: Capsule())
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
        .animation(.easeInOut(duration: 0.15), value: current)
        .accessibilityHint(locked ? "Stop recording to change lens" : "")
    }

    private var lensLocked: Bool {
        container.sessionState != .idle
    }

    /// Widest first, as Camera orders its zoom pills.
    private static let backLenses = CameraLens.allCases
        .filter { !$0.isSelfie }
        .sorted { zoomFactor($0) < zoomFactor($1) }

    private static func zoomFactor(_ lens: CameraLens) -> Double {
        Double(lens.shortLabel.filter { $0.isNumber || $0 == "." }) ?? .infinity
    }

    /// ".5" and "1" at rest, "0.5×" and "1×" when chosen, as Camera does.
    private static func pillLabel(for lens: CameraLens, selected: Bool) -> String {
        if selected { return lens.shortLabel }
        var label = lens.shortLabel
        if label.hasSuffix("×") { label.removeLast() }
        if label.hasPrefix("0.") { label.removeFirst() }
        return label
    }

    // MARK: - Clip length strip

    private var clipLengthStrip: some View {
        clipLengthStrip(axis: .horizontal)
    }

    /// Sits where Camera's PHOTO / VIDEO mode strip does: plain text, the
    /// selected length in yellow. Lengths beyond the buffer are dimmed.
    private func clipLengthStrip(axis: ControlAxis) -> some View {
        let bufferSeconds = container.settings.config.bufferSeconds
        let items = ForEach(RecordingConfig.bufferOptions, id: \.self) { seconds in
            let enabled = seconds <= bufferSeconds
            let selected = seconds == container.selectedClipSeconds
            Button {
                container.setClipSeconds(seconds)
            } label: {
                Text("\(Int(seconds))s")
                    .font(.footnote.weight(.semibold))
                    .tracking(0.6)
                    .monospacedDigit()
                    .foregroundStyle(selected ? Color.yellow : Color.white)
                    .shadow(color: .black.opacity(0.7), radius: 2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.35)
            .accessibilityLabel("Clip length \(Int(seconds)) seconds")
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        return Group {
            switch axis {
            case .horizontal: HStack(spacing: 14) { items }
            case .vertical: VStack(spacing: 10) { items }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clip length")
    }

    // MARK: - Bottom bar

    /// Camera's bottom row: last shot on the left, shutter in the middle,
    /// flip camera on the right.
    private var bottomBar: some View {
        ZStack {
            HStack {
                libraryThumbnail
                Spacer()
                flipButton
            }
            recordButton
        }
    }

    /// Shutter ring width plus the gap to the next column; what the top
    /// strip's trailing controls step inward by in landscape.
    private static let landscapeShutterColumnWidth: CGFloat = 72 + 20

    private var shutterColumn: some View {
        VStack {
            flipButton
            Spacer()
            recordButton
            Spacer()
            libraryThumbnail
        }
    }

    /// Video-mode shutter: white ring, red disc to start, red square to stop.
    private var recordButton: some View {
        let state = container.sessionState
        let busy = state == .starting || state == .stopping
        return Button {
            container.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 72, height: 72)
                if state.isRecording {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.red)
                        .frame(width: 30, height: 30)
                } else {
                    Circle()
                        .fill(.red)
                        .frame(width: 58, height: 58)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: state.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.5 : 1)
        .accessibilityLabel(state.isRecording ? "Stop recording" : "Start recording")
    }

    /// Selfie is a camera flip, not a zoom step. Coming back lands on the
    /// back lens that was up before.
    private var flipButton: some View {
        let selfie = container.settings.config.lens.isSelfie
        let locked = lensLocked
        return Button {
            container.settings.config.lens = selfie ? lastBackLens : .selfie
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.camera")
                .font(.title3.weight(.semibold))
                .foregroundStyle(selfie ? Color.yellow : Color.white)
                .frame(width: 48, height: 48)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
        .accessibilityLabel(selfie ? "Switch to back camera" : "Switch to front camera")
        .accessibilityHint(locked ? "Stop recording to change lens" : "")
    }

    /// The way into the Library grid. Shows the last clip when there is one
    /// and a blank slot otherwise, so the door is always in the same place.
    private var libraryThumbnail: some View {
        Button {
            container.openLibrary()
        } label: {
            Group {
                if let last = container.lastClip {
                    ThumbnailImage(fileName: last.thumbnailFileName)
                        .overlay(alignment: .bottomTrailing) {
                            Text(durationText(last.duration))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                                .padding(3)
                        }
                } else {
                    Image(systemName: "photo.stack")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.black.opacity(0.55))
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.8), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Open Library")
    }

    // MARK: - Gestures

    private func handleTap() {
        guard container.sessionState.isRecording else { return }
        container.tapTrigger.fireSave()
    }

    private func handleLongPress() {
        if isDimmed {
            isDimmed = false
            return
        }
        container.tapTrigger.fireToggle()
    }

    // MARK: - Helpers

    @ViewBuilder
    private var saveStatusBadge: some View {
        if pendingSaves > 0 {
            SaveStatusBadge(
                title: pendingSaves > 1 ? "Saving \(pendingSaves)…" : "Saving…",
                color: .blue,
                showsProgress: true
            )
        } else if let saveCallout = container.saveCallout {
            switch saveCallout {
            case .saved:
                SaveStatusBadge(title: "Saved!", color: .green)
            case .failed:
                SaveStatusBadge(title: "Failed!", color: .red)
            }
        }
    }

    /// Changes whenever a preview (re)start might be needed.
    private var previewKey: String {
        "\(permissionsSatisfied)-\(scenePhase == .background)"
    }

    private var permissionsSatisfied: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        let permissions = container.permissions
        let microphoneOK = !container.settings.config.needsMicrophone || permissions.microphone == .granted
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

/// Round toggle for the top strip.
private struct StripIcon: View {
    let systemImage: String
    let tint: Color

    var body: some View {
        Image(systemName: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(.black.opacity(0.55), in: Circle())
    }
}

/// Status pill for in-flight saves and their outcome.
private struct SaveStatusBadge: View {
    let title: String
    let color: Color
    var showsProgress = false

    var body: some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView().tint(.white)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(color.opacity(0.85), in: Capsule())
        .accessibilityAddTraits(.isStaticText)
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

/// Opaque black overlay for long sessions. Taps still save while recording; long-press wakes.
private struct DimmedModeView: View {
    let isRecording: Bool

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 4) {
                Text("Screen dimmed")
                Text(isRecording ? "Tap to save · Hold to wake" : "Hold to wake")
            }
            .font(.caption2)
            .foregroundStyle(.white.opacity(0.45))
        }
        .accessibilityLabel(
            isRecording
                ? "Screen dimmed. Tap to save a clip, hold to wake."
                : "Screen dimmed. Hold to wake."
        )
    }
}

/// Shown until camera (and, if audio or the voice trigger is on, microphone)
/// access is granted.
private struct PermissionsGateView: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.openURL) private var openURL

    var body: some View {
        let permissions = container.permissions
        let needsMic = container.settings.config.needsMicrophone
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
