import AVFoundation
import HighlightCore
import SwiftUI
import UIKit

/// What the editor did with the clip when the user saved.
enum ClipEditOutcome {
    /// The original clip now points at the trimmed media.
    case replaced(ClipRecord)
    /// The original is untouched; a new clip holds the trimmed media.
    case savedCopy(ClipRecord)
}

/// Full-screen trim editor for one clip. Drag the yellow handles to choose a
/// range, play to preview just that range, then Save to replace the original
/// or keep the trim as a new clip. Trimming re-encodes, so Save takes a few
/// seconds; the screen locks while it runs.
///
/// Present with `.fullScreenCover`. `onComplete` fires before dismissal so the
/// presenter can refresh its copy of the record.
struct ClipEditorScreen: View {
    let record: ClipRecord
    let onComplete: (ClipEditOutcome) -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var duration: Double
    @State private var start: Double = 0
    @State private var end: Double
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var isEditing = false
    @State private var frames: [UIImage] = []
    @State private var showSaveOptions = false
    @State private var isExporting = false
    @State private var statusMessage: String?

    private static let filmstripFrameCount = 12

    init(record: ClipRecord, onComplete: @escaping (ClipEditOutcome) -> Void) {
        self.record = record
        self.onComplete = onComplete
        let duration = max(record.duration, 0.01)
        _duration = State(initialValue: duration)
        _end = State(initialValue: duration)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                ZStack {
                    PlayerLayerView(player: player)
                    playPauseButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { togglePlayback() }

                controls
            }
            .padding(.horizontal, ScreenMetrics.horizontal)
            .disabled(isExporting)

            if isExporting {
                exportingOverlay
            }
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled(isExporting)
        .onAppear { load() }
        .onDisappear { teardown() }
        .onChange(of: start) { _, value in
            handleEdgeChange(to: value)
        }
        .onChange(of: end) { _, value in
            handleEdgeChange(to: value)
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === player.currentItem else { return }
            playhead = end
            isPlaying = false
        }
        .confirmationDialog("Save trimmed clip?", isPresented: $showSaveOptions, titleVisibility: .visible) {
            Button("Replace Original") {
                Task { await save(replacingOriginal: true) }
            }
            Button("Save as New Clip") {
                Task { await save(replacingOriginal: false) }
            }
        } message: {
            Text("Keeps \(TrimRangeBar.timeText(selectedDuration)) of \(TrimRangeBar.timeText(duration)). Replacing removes the rest from this device.")
        }
        .overlay(alignment: .top) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .padding(.top, 60)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: statusMessage)
        .animation(.easeInOut(duration: 0.2), value: isExporting)
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.body)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Trim")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                player.pause()
                showSaveOptions = true
            } label: {
                Text("Save")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(hasChanges ? Color.yellow : Color.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!hasChanges)
            .accessibilityHint(hasChanges ? "" : "Move a handle to trim the clip first")
        }
        .padding(.vertical, 12)
    }

    private var playPauseButton: some View {
        Button {
            togglePlayback()
        } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: isPlaying ? 0 : 2)
                .frame(width: 72, height: 72)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(isPlaying ? 0 : 1)
        .allowsHitTesting(!isPlaying)
        .animation(.easeInOut(duration: 0.15), value: isPlaying)
        .accessibilityLabel(isPlaying ? "Pause" : "Play selection")
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Text(TrimRangeBar.timeText(start))
                Spacer()
                Text("\(TrimRangeBar.timeText(selectedDuration)) selected")
                    .foregroundStyle(hasChanges ? Color.yellow : Color.white.opacity(0.85))
                Spacer()
                Text(TrimRangeBar.timeText(end))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            TrimRangeBar(
                duration: duration,
                start: $start,
                end: $end,
                playhead: playhead,
                minimumDuration: ClipTrimmer.minimumDuration,
                frames: frames,
                onEditingChanged: { editing in
                    isEditing = editing
                    if editing {
                        player.pause()
                        isPlaying = false
                    } else {
                        seek(to: playhead, preview: false)
                    }
                },
                onScrub: { time in
                    seek(to: time, preview: true)
                }
            )
            .frame(height: 64)
            .padding(.vertical, 4)

            Text("Drag the handles to trim. Saving re-encodes the clip.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var exportingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text("Trimming…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity)
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Derived

    private var selectedDuration: Double { max(end - start, 0) }

    /// Save is a no-op until at least one handle has moved.
    private var hasChanges: Bool {
        start > 0.01 || end < duration - 0.01
    }

    // MARK: - Playback

    private func load() {
        let item = AVPlayerItem(url: record.fileURL)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        applyEndTime()
        addTimeObserver()

        let url = record.fileURL
        Task {
            frames = await Self.loadFrames(from: url, count: Self.filmstripFrameCount)
        }
        Task {
            // `record.duration` came from the export plan; trust the file if it
            // disagrees so the end handle can reach the true last frame.
            guard let actual = await Self.loadDuration(of: url), abs(actual - duration) > 0.05 else { return }
            let endWasAtLimit = end >= duration - 0.01
            duration = actual
            if endWasAtLimit || end > actual {
                end = actual
            }
            start = min(start, max(actual - ClipTrimmer.minimumDuration, 0))
        }
    }

    private func teardown() {
        removeTimeObserver()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if playhead >= end - 0.05 || playhead < start {
            seek(to: start, preview: false)
        }
        player.play()
        isPlaying = true
    }

    /// Playback stops at `end` on its own; seeks are clamped to the range too.
    private func applyEndTime() {
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
    }

    /// Show the frame under a moving handle. Handle drags arrive with
    /// `isEditing` set; VoiceOver adjustments arrive without it. Programmatic
    /// changes (the duration refinement in `load`) preview nothing, so the
    /// playhead stays where the user left it.
    private func handleEdgeChange(to time: Double) {
        applyEndTime()
        guard isEditing || UIAccessibility.isVoiceOverRunning else {
            playhead = min(max(playhead, start), end)
            return
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        }
        seek(to: time, preview: isEditing)
    }

    private func seek(to seconds: Double, preview: Bool) {
        playhead = min(max(seconds, start), end)
        let time = CMTime(seconds: playhead, preferredTimescale: 600)
        let tolerance = preview ? CMTime(seconds: 0.05, preferredTimescale: 600) : .zero
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    private func addTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            MainActor.assumeIsolated {
                isPlaying = player.timeControlStatus == .playing && player.rate != 0
                guard !isEditing, time.isNumeric else { return }
                let seconds = time.seconds
                guard seconds.isFinite else { return }
                playhead = min(max(seconds, start), end)
                // Belt and braces for `forwardPlaybackEndTime`, which can be
                // missed when it moves while the item is already past it.
                if isPlaying, playhead >= end - 0.02 {
                    player.pause()
                    isPlaying = false
                    playhead = end
                }
            }
        }
    }

    private func removeTimeObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    // MARK: - Save

    private func save(replacingOriginal: Bool) async {
        guard let clip = container.clipStore.clip(withID: record.id) else {
            statusMessage = "This clip no longer exists."
            return
        }
        isExporting = true
        defer { isExporting = false }

        let trimmer = ClipTrimmer(clipsDirectory: AppDirectories.clips)
        let baseName = Self.freshBaseName(for: record)
        do {
            let exported = try await trimmer.trim(record.fileURL, start: start, end: end, baseName: baseName)
            let outcome: ClipEditOutcome
            do {
                if replacingOriginal {
                    try container.clipStore.replaceMedia(clip, with: exported)
                    let updated = clip.record
                    if container.lastClip?.id == updated.id {
                        container.lastClip = updated
                    }
                    outcome = .replaced(updated)
                } else {
                    // Same timestamp, tags, and star so the copy sits beside its source.
                    let copy = ClipRecord(
                        id: UUID(),
                        createdAt: record.createdAt,
                        duration: exported.duration,
                        fileName: exported.fileURL.lastPathComponent,
                        thumbnailFileName: exported.thumbnailFileName,
                        triggerSource: record.triggerSource,
                        sizeBytes: exported.sizeBytes,
                        tags: record.tags,
                        isStarred: record.isStarred
                    )
                    try container.clipStore.insert(copy)
                    outcome = .savedCopy(copy)
                }
            } catch {
                ClipTrimmer.discard(exported)
                throw error
            }
            Haptics.saved()
            onComplete(outcome)
            dismiss()
        } catch {
            Log.ui.error("Trim failed: \(String(describing: error), privacy: .public)")
            Haptics.error()
            statusMessage = "Trim failed: \(error.localizedDescription)"
        }
    }

    /// Keeps the original timestamp in the file name (so Files-app sorting
    /// matches `createdAt`) with a new random suffix that does not collide.
    private static func freshBaseName(for record: ClipRecord) -> String {
        let directory = AppDirectories.clips
        for _ in 0..<8 {
            let candidate = ClipNaming.baseName(for: record.createdAt)
            if !FileManager.default.fileExists(atPath: directory.appending(path: candidate + ".mp4").path) {
                return candidate
            }
        }
        return ClipNaming.baseName(for: .now)
    }

    // MARK: - Asset loading

    /// `count` evenly spaced frames for the filmstrip, small and fast. Missing
    /// frames are skipped rather than failing the whole strip.
    nonisolated private static func loadFrames(from url: URL, count: Int) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let duration = await loadDuration(of: url), count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let times = (0..<count).map { index in
            CMTime(seconds: (Double(index) + 0.5) / Double(count) * duration, preferredTimescale: 600)
        }
        var images: [UIImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image {
                images.append(UIImage(cgImage: image))
            }
        }
        return images
    }

    nonisolated private static func loadDuration(of url: URL) async -> Double? {
        guard let time = try? await AVURLAsset(url: url).load(.duration), time.isNumeric else { return nil }
        let seconds = time.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }
}
