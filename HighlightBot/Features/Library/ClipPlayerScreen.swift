import AVFoundation
import HighlightCore
import SwiftUI
import UIKit

/// Full-screen player for one clip with loop and slow-motion controls, plus
/// Share / Save to Photos / Delete.
struct ClipPlayerScreen: View {
    let record: ClipRecord

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var isLooping = true
    @State private var rate: Float = 1.0
    @State private var isSpeedMenuExpanded = false
    @State private var showDeleteConfirm = false
    @State private var statusMessage: String?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var isPlaying = false
    @State private var isOverlayVisible = true
    @State private var overlayHideTask: Task<Void, Never>?
    @State private var timeObserver: Any?

    private static let playbackRates: [Float] = [1.0, 0.5, 0.25, 0.15]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PlayerLayerView(player: player)
                .ignoresSafeArea()

            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    handleScreenTap()
                }

            chromeOverlay
                .contentShape(Rectangle())
                .opacity(isOverlayVisible ? 1 : 0)
                .allowsHitTesting(isOverlayVisible)
                .accessibilityHidden(!isOverlayVisible)
                .simultaneousGesture(TapGesture().onEnded {
                    scheduleOverlayAutoHide()
                })
        }
        .statusBarHidden(true)
        .onAppear { startPlayback() }
        .onDisappear {
            overlayHideTask?.cancel()
            overlayHideTask = nil
            removeTimeObserver()
            player.pause()
            looper?.disableLooping()
            looper = nil
        }
        .onChange(of: isPlaying) { _, playing in
            if playing {
                scheduleOverlayAutoHide()
            } else {
                overlayHideTask?.cancel()
                overlayHideTask = nil
                isOverlayVisible = true
            }
        }
        .onChange(of: isScrubbing) { _, scrubbing in
            if scrubbing {
                overlayHideTask?.cancel()
                overlayHideTask = nil
                isOverlayVisible = true
            } else {
                scheduleOverlayAutoHide()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard !isLooping else { return }
            guard notification.object as AnyObject? === player.currentItem else { return }
            handlePlaybackEnded()
        }
        .confirmationDialog("Delete this clip?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteClip() }
        } message: {
            Text("The video file is removed from this device.")
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
        .animation(.easeInOut(duration: 0.2), value: isOverlayVisible)
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
    }

    private var chromeOverlay: some View {
        ZStack {
            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("Close")

                    Spacer()

                    Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .foregroundStyle(.white)
                .padding(.bottom, 16)

                Spacer()

                VStack(spacing: 10) {
                    scrubber
                    bottomBar
                }
                .padding(.bottom, 12)
            }
            .padding(.horizontal, ScreenMetrics.horizontal)

            playPauseButton
        }
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
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
    }

    private var scrubber: some View {
        VStack(spacing: 4) {
            Slider(
                value: Binding(
                    get: { currentTime },
                    set: { seek(to: $0, preview: true) }
                ),
                in: 0...scrubDuration
            ) { editing in
                isScrubbing = editing
                if editing {
                    player.pause()
                } else {
                    seek(to: currentTime, preview: false)
                    player.rate = rate
                }
            }
            .tint(.white)
            .accessibilityLabel("Playback position")

            HStack {
                Text(timeText(currentTime))
                Spacer()
                Text(timeText(scrubDuration))
            }
            .font(.caption2.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                isLooping.toggle()
                applyLooping()
            } label: {
                Label("Loop", systemImage: isLooping ? "repeat.circle.fill" : "repeat.circle")
            }

            speedControl

            Spacer()

            ShareLink(item: record.fileURL) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Button {
                Task { await saveToPhotos() }
            } label: {
                Label("Save to Photos", systemImage: "photo.badge.plus")
            }

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .labelStyle(.iconOnly)
        .font(.title3)
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: Capsule())
    }

    private var speedControl: some View {
        HStack(spacing: 10) {
            Button {
                isSpeedMenuExpanded.toggle()
            } label: {
                Image(systemName: "tortoise.fill")
            }
            .accessibilityLabel(isSpeedMenuExpanded ? "Hide playback speeds" : "Show playback speeds")
            .accessibilityValue(percentLabel(for: rate))

            ForEach(Self.playbackRates, id: \.self) { option in
                let isSelected = option == rate
                let isVisible = isSpeedMenuExpanded || isSelected
                Button {
                    if isSpeedMenuExpanded {
                        applyRate(option)
                    } else {
                        isSpeedMenuExpanded = true
                    }
                } label: {
                    Text(percentLabel(for: option))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isSelected && isSpeedMenuExpanded ? Color.yellow : Color.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .transaction { $0.animation = nil }
                }
                .opacity(isVisible ? 1 : 0)
                .frame(maxWidth: isVisible ? nil : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
                .accessibilityLabel("Playback speed \(percentLabel(for: option))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSpeedMenuExpanded)
    }

    private func percentLabel(for rate: Float) -> String {
        "\(Int((rate * 100).rounded()))%"
    }

    private var scrubDuration: Double {
        let value = duration > 0 ? duration : record.duration
        return max(value, 0.01)
    }

    // MARK: - Playback

    private func startPlayback() {
        duration = record.duration
        applyLooping()
        addTimeObserver()
        scheduleOverlayAutoHide()
    }

    private func togglePlayback() {
        if isPlaying {
            player.pause()
            markPlaybackInactive()
            return
        }
        if isAtEnd {
            seek(to: 0, preview: false)
        }
        player.rate = rate
        isPlaying = true
    }

    private func handleScreenTap() {
        if !isOverlayVisible {
            isOverlayVisible = true
        }
        scheduleOverlayAutoHide()
    }

    private func handlePlaybackEnded() {
        currentTime = scrubDuration
        markPlaybackInactive()
    }

    private func markPlaybackInactive() {
        isPlaying = false
        overlayHideTask?.cancel()
        overlayHideTask = nil
        isOverlayVisible = true
    }

    private var isAtEnd: Bool {
        !isLooping && currentTime >= scrubDuration - 0.05
    }

    private var isPlaybackActive: Bool {
        isPlaying && player.rate != 0 && !isAtEnd
    }

    private func scheduleOverlayAutoHide() {
        overlayHideTask?.cancel()
        guard isPlaybackActive, !isScrubbing, !UIAccessibility.isVoiceOverRunning else {
            if !isPlaybackActive {
                isOverlayVisible = true
            }
            return
        }
        overlayHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            guard isPlaybackActive, !isScrubbing else {
                isOverlayVisible = true
                return
            }
            isOverlayVisible = false
        }
    }

    /// Rebuilds the queue: an `AVPlayerLooper` when looping, a single item otherwise.
    private func applyLooping() {
        let item = AVPlayerItem(url: record.fileURL)
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        player.actionAtItemEnd = isLooping ? .advance : .pause
        if isLooping {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        player.rate = rate
        isPlaying = player.rate != 0
    }

    private func applyRate(_ newRate: Float) {
        rate = newRate
        // VERIFY: setting `rate` directly resumes playback at that speed; slow rates
        // require `AVPlayerItem.canPlaySlowForward`, which is true for local MP4s.
        player.rate = rate
    }

    private func addTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            MainActor.assumeIsolated {
                isPlaying = player.timeControlStatus == .playing && player.rate != 0
                guard !isScrubbing else { return }
                currentTime = seconds(from: time)
                if let itemDuration = player.currentItem?.duration {
                    let value = seconds(from: itemDuration)
                    if value > 0 { duration = value }
                }
                if !isLooping, duration > 0, currentTime >= duration - 0.05,
                   player.timeControlStatus != .playing || player.rate == 0 {
                    currentTime = duration
                    markPlaybackInactive()
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

    private func seek(to seconds: Double, preview: Bool) {
        currentTime = min(max(seconds, 0), scrubDuration)
        let time = CMTime(seconds: currentTime, preferredTimescale: 600)
        player.seek(
            to: time,
            toleranceBefore: preview ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero,
            toleranceAfter: preview ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero
        )
    }

    private func seconds(from time: CMTime) -> Double {
        guard time.isNumeric else { return 0 }
        let value = time.seconds
        return value.isFinite ? value : 0
    }

    private func timeText(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: - Actions

    private func saveToPhotos() async {
        do {
            try await PhotosSaver.save(record.fileURL, permissions: container.permissions)
            statusMessage = "Saved to Photos"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func deleteClip() {
        guard let clip = container.clipStore.clip(withID: record.id) else {
            dismiss()
            return
        }
        do {
            player.pause()
            try container.clipStore.delete(clip)
            if container.lastClip?.id == record.id {
                container.lastClip = container.clipStore.newest()?.record
            }
            dismiss()
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }
}

/// Renders `player` with aspect-fit video and no system playback controls.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        PlayerUIView(player: player)
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
}

private final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init(player: AVPlayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
