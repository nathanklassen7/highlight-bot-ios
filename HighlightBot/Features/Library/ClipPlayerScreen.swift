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

    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var isLooping = true
    @State private var rate: Float = 1.0
    @State private var showDeleteConfirm = false
    @State private var statusMessage: String?

    private static let rates: [Float] = [0.25, 0.5, 1.0]

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

                bottomBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .statusBarHidden(true)
        .onAppear { startPlayback() }
        .onDisappear {
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

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                isLooping.toggle()
                applyLooping()
            } label: {
                Label("Loop", systemImage: isLooping ? "repeat.circle.fill" : "repeat.circle")
            }

            Button {
                cycleRate()
            } label: {
                Label(rateLabel, systemImage: "tortoise.fill")
                    .monospacedDigit()
            }
            .accessibilityLabel("Playback speed \(rateLabel)")

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

    private var rateLabel: String {
        switch rate {
        case 0.25: "0.25×"
        case 0.5: "0.5×"
        default: "1×"
        }
    }

    // MARK: - Playback

    private func startPlayback() {
        player.actionAtItemEnd = .advance
        applyLooping()
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

    private func cycleRate() {
        let index = Self.rates.firstIndex(of: rate) ?? (Self.rates.count - 1)
        rate = Self.rates[(index + 1) % Self.rates.count]
        // VERIFY: setting `rate` directly resumes playback at that speed; slow rates
        // require `AVPlayerItem.canPlaySlowForward`, which is true for local MP4s.
        player.rate = rate
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
