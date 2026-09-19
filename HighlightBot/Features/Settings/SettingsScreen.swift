import HighlightCore
import SwiftUI

/// Editable `RecordingConfig` plus storage management and debug toggles.
struct SettingsScreen: View {
    @Environment(AppContainer.self) private var container

    @State private var usedBytes: Int64 = 0
    @State private var showDeleteAllConfirm = false
    @State private var statusMessage: String?

    private static let inactivityMinutes: [Int] = [15, 30, 45, 60, 120]

    /// Preset capture resolutions exposed in the picker.
    private enum Resolution: String, CaseIterable, Identifiable {
        case p1080, p720

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .p1080: "1080p"
            case .p720: "720p"
            }
        }

        var size: (width: Int, height: Int) {
            switch self {
            case .p1080: (1920, 1080)
            case .p720: (1280, 720)
            }
        }

        init(width: Int, height: Int) {
            self = (width >= 1920 || height >= 1080) ? .p1080 : .p720
        }
    }

    var body: some View {
        @Bindable var settings = container.settings
        let isRecording = container.sessionState.isRecording

        NavigationStack {
            Form {
                Section {
                    Picker("Buffer length", selection: $settings.config.bufferSeconds) {
                        ForEach(RecordingConfig.bufferOptions, id: \.self) { seconds in
                            Text("\(Int(seconds)) seconds").tag(seconds)
                        }
                    }
                    Picker("Inactivity timeout", selection: $settings.config.inactivityTimeout) {
                        ForEach(Self.inactivityMinutes, id: \.self) { minutes in
                            Text("\(minutes) min").tag(TimeInterval(minutes * 60))
                        }
                    }
                } header: {
                    Text("Recording")
                } footer: {
                    Text("Recording stops automatically after this long without a saved clip.")
                }

                Section {
                    // Width is the selection; height follows in onChange below.
                    Picker("Resolution", selection: $settings.config.width) {
                        ForEach(Resolution.allCases) { resolution in
                            Text(resolution.displayName).tag(resolution.size.width)
                        }
                    }
                    Picker("Frame rate", selection: $settings.config.frameRate) {
                        ForEach(RecordingConfig.frameRateOptions, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }
                    Picker("Codec", selection: $settings.config.codec) {
                        ForEach(VideoCodec.allCases) { codec in
                            Text(codec.displayName).tag(codec)
                        }
                    }
                    Toggle("Record audio", isOn: $settings.config.recordAudio)
                } header: {
                    Text("Capture")
                } footer: {
                    if isRecording {
                        Text("Capture settings apply the next time recording starts.")
                    } else {
                        Text("120 fps captures at 720p. H.264 shares everywhere; HEVC makes smaller files.")
                    }
                }

                Section("Storage") {
                    LabeledContent("Clips on device", value: ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file))
                    Button("Delete all clips", role: .destructive) {
                        showDeleteAllConfirm = true
                    }
                    .disabled(usedBytes == 0)
                }

                Section("Debug") {
                    Toggle("Show pipeline metrics", isOn: $settings.config.debugOverlayEnabled)
                    Button("Reset settings to defaults") {
                        settings.reset()
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Self.versionText)
                    LabeledContent("Minimum iOS", value: "17.2")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .confirmationDialog(
                "Delete all clips?",
                isPresented: $showDeleteAllConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete all", role: .destructive) { deleteAll() }
            } message: {
                Text("Every saved clip is removed from this device. Clips already shared or saved to Photos are not affected.")
            }
            .overlay(alignment: .bottom) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: statusMessage)
            .task(id: statusMessage) {
                guard statusMessage != nil else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                statusMessage = nil
            }
            .onAppear { refreshStorage() }
            .onChange(of: container.lastClip) { _, _ in refreshStorage() }
            .onChange(of: settings.config.frameRate) { _, fps in
                if fps > RecordingConfig.maxFrameRateFor1080p {
                    let size = Resolution.p720.size
                    settings.config.width = size.width
                    settings.config.height = size.height
                }
            }
            .onChange(of: settings.config.width) { _, width in
                let resolution = Resolution(width: width, height: settings.config.height)
                let size = resolution.size
                if settings.config.height != size.height {
                    settings.config.height = size.height
                }
                if resolution == .p1080, settings.config.frameRate > RecordingConfig.maxFrameRateFor1080p {
                    settings.config.frameRate = RecordingConfig.maxFrameRateFor1080p
                }
            }
        }
    }

    // MARK: - Actions

    private func refreshStorage() {
        usedBytes = container.clipStore.totalBytes()
    }

    private func deleteAll() {
        do {
            try container.clipStore.deleteAll()
            container.lastClip = nil
            statusMessage = "All clips deleted"
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
        refreshStorage()
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
