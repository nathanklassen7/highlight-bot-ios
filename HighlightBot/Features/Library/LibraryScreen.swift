import HighlightCore
import SwiftData
import SwiftUI

/// Grid of saved clips, newest first. Tap to play; long-press for Share,
/// Save to Photos, and Delete.
struct LibraryScreen: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \Clip.createdAt, order: .reverse) private var clips: [Clip]

    @State private var playerRecord: ClipRecord?
    @State private var pendingDelete: ClipRecord?
    @State private var showDeleteConfirm = false
    @State private var statusMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if clips.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "film.stack",
                        description: Text("Start recording on the Record tab and tap the screen to save the last few seconds.")
                    )
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(storageText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(clips) { clip in
                                    let record = clip.record
                                    Button {
                                        playerRecord = record
                                    } label: {
                                        ClipCell(record: record)
                                    }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        ShareLink(item: record.fileURL) {
                                            Label("Share", systemImage: "square.and.arrow.up")
                                        }
                                        Button {
                                            Task { await saveToPhotos(record) }
                                        } label: {
                                            Label("Save to Photos", systemImage: "photo.badge.plus")
                                        }
                                        Button(role: .destructive) {
                                            pendingDelete = record
                                            showDeleteConfirm = true
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $playerRecord) { record in
                ClipPlayerScreen(record: record)
            }
            .confirmationDialog(
                "Delete this clip?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible,
                presenting: pendingDelete
            ) { record in
                Button("Delete", role: .destructive) {
                    delete(record)
                }
            } message: { _ in
                Text("The video file is removed from this device.")
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
        }
    }

    private var storageText: String {
        let bytes = clips.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(clips.count) clip\(clips.count == 1 ? "" : "s") · \(size)"
    }

    private func delete(_ record: ClipRecord) {
        guard let clip = container.clipStore.clip(withID: record.id) else { return }
        do {
            try container.clipStore.delete(clip)
            if container.lastClip?.id == record.id {
                container.lastClip = container.clipStore.newest()?.record
            }
        } catch {
            statusMessage = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func saveToPhotos(_ record: ClipRecord) async {
        do {
            try await PhotosSaver.save(record.fileURL, permissions: container.permissions)
            statusMessage = "Saved to Photos"
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

/// One grid cell: thumbnail, duration, relative time, and trigger source icon.
struct ClipCell: View {
    let record: ClipRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(url: record.thumbnailURL)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomTrailing) {
                    Text(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(6)
                }

            HStack(spacing: 6) {
                Image(systemName: Self.symbol(for: record.triggerSource))
                    .foregroundStyle(.secondary)
                Text(record.createdAt, format: .relative(presentation: .named))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .file))
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    // VERIFY: "camera.shutter.button.fill" and "photo.badge.plus" (used in menus)
    // exist in SF Symbols 5 / iOS 17; a missing name renders empty, not a crash.
    static func symbol(for source: TriggerSourceID) -> String {
        switch source {
        case .tap: "hand.tap.fill"
        case .hardwareButton: "camera.shutter.button.fill"
        case .ui: "rectangle.and.hand.point.up.left.fill"
        case .voice: "waveform"
        case .vision: "eye.fill"
        case .system: "gearshape.fill"
        default: "questionmark.circle"
        }
    }
}
