import HighlightCore
import SwiftData
import SwiftUI

/// Grid of saved clips, newest first. Tap to play; long-press for Share,
/// Save to Photos, and Delete. Select mode toggles membership in a set of
/// clip IDs (range-drag can later union a contiguous slice into the same set).
struct LibraryScreen: View {
    @Environment(AppContainer.self) private var container
    @Query(sort: \Clip.createdAt, order: .reverse) private var clips: [Clip]

    @State private var playerRecord: ClipRecord?
    @State private var pendingDelete: [ClipRecord] = []
    @State private var showDeleteConfirm = false
    @State private var statusMessage: String?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

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
                    .padding(.top, ScreenMetrics.top)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(isSelecting ? selectedText : storageText)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .trailing)

                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(clips) { clip in
                                    let record = clip.record
                                    clipCell(for: record)
                                }
                            }
                        }
                        .padding(.horizontal, ScreenMetrics.horizontal)
                        .padding(.top, ScreenMetrics.top)
                        .padding(.bottom, isSelecting ? 200 : 88)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $playerRecord) { record in
                ClipPlayerScreen(record: record)
            }
            .confirmationDialog(
                deleteDialogTitle,
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    deletePending()
                }
            } message: {
                Text(
                    pendingDelete.count == 1
                        ? "The video file is removed from this device."
                        : "The video files are removed from this device."
                )
            }
            .overlay(alignment: .bottomTrailing) {
                if !clips.isEmpty {
                    selectionFABStack
                        .padding(.bottom, 16)
                }
            }
            .overlay(alignment: .bottom) {
                if let statusMessage {
                    Text(statusMessage)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 88)
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
            .onChange(of: clips.count) { _, _ in
                selectedIDs = selectedIDs.intersection(Set(clips.map(\.id)))
                if clips.isEmpty {
                    exitSelection()
                }
            }
            .onAppear { consumePendingLibraryClip() }
            .onChange(of: container.pendingLibraryClip) { _, _ in
                consumePendingLibraryClip()
            }
        }
    }

    private var hasSelection: Bool { !selectedIDs.isEmpty }

    private var selectionFABStack: some View {
        VStack(spacing: 12) {
            if isSelecting {
                shareFAB
                deleteFAB
            }

            Button {
                if isSelecting {
                    exitSelection()
                } else {
                    isSelecting = true
                }
            } label: {
                LibraryActionCircle(
                    systemImage: isSelecting ? "checkmark" : "checklist",
                    tint: isSelecting ? AppPalette.confirm : AppPalette.accent
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelecting ? "Done" : "Select clips")
        }
        .animation(.easeInOut(duration: 0.2), value: isSelecting)
    }

    @ViewBuilder
    private var shareFAB: some View {
        let urls = selectedRecords.map(\.fileURL)
        if hasSelection {
            ShareLink(items: urls) {
                LibraryActionCircle(systemImage: "square.and.arrow.up", tint: AppPalette.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share selected clips")
        } else {
            LibraryActionCircle(systemImage: "square.and.arrow.up", tint: AppPalette.accent, enabled: false)
                .accessibilityLabel("Share selected clips")
                .accessibilityAddTraits(.isButton)
        }
    }

    private var deleteFAB: some View {
        Button {
            pendingDelete = selectedRecords
            showDeleteConfirm = true
        } label: {
            LibraryActionCircle(systemImage: "trash", tint: AppPalette.danger, enabled: hasSelection)
        }
        .buttonStyle(.plain)
        .disabled(!hasSelection)
        .accessibilityLabel("Delete selected clips")
    }

    @ViewBuilder
    private func clipCell(for record: ClipRecord) -> some View {
        let selected = selectedIDs.contains(record.id)
        Button {
            if isSelecting {
                toggleSelected(record.id)
            } else {
                playerRecord = record
            }
        } label: {
            ClipCell(record: record, isSelecting: isSelecting, isSelected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(isSelecting ? (selected ? "Deselect" : "Select") : "Plays the clip")
        .contextMenu {
            if !isSelecting {
                ShareLink(item: record.fileURL) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Button {
                    Task { await saveToPhotos(record) }
                } label: {
                    Label("Save to Photos", systemImage: "photo.badge.plus")
                }
                Button(role: .destructive) {
                    pendingDelete = [record]
                    showDeleteConfirm = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var storageText: String {
        let bytes = clips.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return "\(clips.count) clip\(clips.count == 1 ? "" : "s") · \(size)"
    }

    private var selectedText: String {
        let count = selectedIDs.count
        if count == 0 { return "Select clips" }
        return "\(count) selected"
    }

    private var selectedRecords: [ClipRecord] {
        clips.compactMap { clip in
            selectedIDs.contains(clip.id) ? clip.record : nil
        }
    }

    private var deleteDialogTitle: String {
        let count = pendingDelete.count
        if count <= 1 { return "Delete this clip?" }
        return "Delete \(count) clips?"
    }

    private func toggleSelected(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func consumePendingLibraryClip() {
        guard let clip = container.pendingLibraryClip else { return }
        container.pendingLibraryClip = nil
        if isSelecting {
            exitSelection()
        }
        playerRecord = clip
    }

    private func deletePending() {
        for record in pendingDelete {
            delete(record)
        }
        pendingDelete = []
        if isSelecting {
            exitSelection()
        }
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
    var isSelecting = false
    var isSelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ThumbnailImage(fileName: record.thumbnailFileName)
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
                .overlay(alignment: .topLeading) {
                    if isSelecting {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                isSelected ? Color.white : Color.white.opacity(0.95),
                                isSelected ? AppPalette.accent : Color.black.opacity(0.35)
                            )
                            .padding(8)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    }
                }
                .overlay {
                    if isSelecting && isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(AppPalette.accent, lineWidth: 3)
                    }
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

private struct LibraryActionCircle: View {
    let systemImage: String
    let tint: Color
    var enabled = true

    var body: some View {
        Image(systemName: systemImage)
            .font(.title3.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 56, height: 56)
            .background(.regularMaterial, in: Circle())
            .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
            .opacity(enabled ? 1 : 0.35)
    }
}
