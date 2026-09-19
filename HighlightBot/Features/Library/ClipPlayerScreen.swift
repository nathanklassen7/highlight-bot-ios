import AVFoundation
import AVKit
import HighlightCore
import SwiftUI

/// Full-screen player for one clip with loop and slow-motion controls, plus
/// Share / Save to Photos / Delete.
struct ClipPlayerScreen: View {
    let record: ClipRecord

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var portraitGutter: CGFloat {
        verticalSizeClass == .regular ? 8 : 0
    }

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
    @State private var timeObserver: Any?

    private static let slowMotionRates: [Float] = [0.5, 0.25, 0.15]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

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
                .padding(16)

                Spacer()

                VStack(spacing: 10) {
                    scrubber
                    bottomBar
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            .padding(.horizontal, portraitGutter)
        }
        .statusBarHidden(true)
        .onAppear { startPlayback() }
        .onDisappear {
            removeTimeObserver()
            player.pause()
            looper?.disableLooping()
            looper = nil
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
        .task(id: statusMessage) {
            guard statusMessage != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            statusMessage = nil
        }
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
        .background(.black.opacity(0.55), in: Capsule())
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
        .animation(.easeInOut(duration: 0.2), value: isSpeedMenuExpanded)
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

            if !isSpeedMenuExpanded, !Self.slowMotionRates.contains(rate) {
                Text(percentLabel(for: rate))
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }

            ForEach(Self.slowMotionRates, id: \.self) { option in
                let isSelected = option == rate
                let isVisible = isSpeedMenuExpanded || isSelected
                Button {
                    applyRate(option)
                } label: {
                    Text(percentLabel(for: option))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isSelected && isSpeedMenuExpanded ? Color.yellow : Color.white)
                }
                .opacity(isVisible ? 1 : 0)
                .frame(width: isVisible ? nil : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
                .accessibilityLabel("Playback speed \(percentLabel(for: option))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
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
        player.actionAtItemEnd = .advance
        applyLooping()
        addTimeObserver()
    }

    /// Rebuilds the queue: an `AVPlayerLooper` when looping, a single item otherwise.
    private func applyLooping() {
        let item = AVPlayerItem(url: record.fileURL)
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        if isLooping {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        player.rate = rate
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
            guard !isScrubbing else { return }
            currentTime = seconds(from: time)
            if let itemDuration = player.currentItem?.duration {
                let value = seconds(from: itemDuration)
                if value > 0 { duration = value }
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
