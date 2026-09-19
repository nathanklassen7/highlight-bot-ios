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
    @State private var starredOnly = false
    @State private var selectedTagFilters: [String] = []
    @State private var editingTagsFor: ClipRecord?
    @State private var showBulkTagPicker = false

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

                            filterBar

                            if filteredClips.isEmpty {
                                ContentUnavailableView(
                                    "No matching clips",
                                    systemImage: "line.3.horizontal.decrease.circle",
                                    description: Text("Try clearing a filter.")
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                            } else {
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(filteredClips) { clip in
                                        let record = clip.record
                                        clipCell(for: record)
                                    }
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
            .sheet(item: $editingTagsFor) { record in
                TagPickerSheet(title: "Edit Tags", initialSelection: record.tags) { tags in
                    applyTags(tags, to: record)
                }
            }
            .sheet(isPresented: $showBulkTagPicker) {
                TagPickerSheet(
                    title: "Add Tags",
                    initialSelection: [],
                    footnote: "Added to \(selectedIDs.count) selected clip(s). Existing tags are kept."
                ) { tags in
                    bulkAddTags(tags)
                }
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
            .onChange(of: clipsRevision) { _, _ in
                selectedIDs = selectedIDs.intersection(Set(clips.map(\.id)))
                selectedTagFilters = selectedTagFilters.filter { tag in
                    ClipTag.contains(availableFilterTags, tag)
                }
                if clips.isEmpty {
                    exitSelection()
                }
            }
            .onChange(of: starredOnly) { _, _ in pruneSelectionToVisible() }
            .onChange(of: selectedTagFilters) { _, _ in pruneSelectionToVisible() }
            .onAppear { consumePendingLibraryClip() }
            .onChange(of: container.pendingLibraryClip) { _, _ in
                consumePendingLibraryClip()
            }
        }
    }

    // MARK: - Filtering

    private var filteredClips: [Clip] {
        clips.filter { clip in
            (!starredOnly || clip.isStarred)
                && (selectedTagFilters.isEmpty || clip.tags.contains { ClipTag.contains(selectedTagFilters, $0) })
        }
    }

    private var availableFilterTags: [String] {
        ClipTag.sortedForDisplay(ClipTag.merge([], clips.flatMap(\.tags)))
    }

    private var hasActiveFilters: Bool {
        starredOnly || !selectedTagFilters.isEmpty
    }

    /// Bumps when clip count, tags, or starred state changes so selection and filters stay valid.
    private var clipsRevision: Int {
        var hasher = Hasher()
        hasher.combine(clips.count)
        for clip in clips {
            hasher.combine(clip.id)
            hasher.combine(clip.tags)
            hasher.combine(clip.isStarred)
        }
        return hasher.finalize()
    }

    @ViewBuilder
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    starredOnly.toggle()
                } label: {
                    Label("Starred", systemImage: starredOnly ? "star.fill" : "star")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(starredOnly ? AppPalette.onFill : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            starredOnly ? Color.yellow : Color.secondary.opacity(0.15),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(starredOnly ? .isSelected : [])

                ForEach(availableFilterTags, id: \.self) { tag in
                    let selected = ClipTag.contains(selectedTagFilters, tag)
                    Button {
                        toggleTagFilter(tag)
                    } label: {
                        TagPill(tag: tag, size: .regular, isSelected: selected)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }

                if hasActiveFilters {
                    Button {
                        starredOnly = false
                        selectedTagFilters = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filters")
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func pruneSelectionToVisible() {
        guard isSelecting else { return }
        selectedIDs = selectedIDs.intersection(Set(filteredClips.map(\.id)))
    }

    private func toggleTagFilter(_ tag: String) {
        if ClipTag.contains(selectedTagFilters, tag) {
            selectedTagFilters = ClipTag.removing(tag, from: selectedTagFilters)
        } else {
            selectedTagFilters = ClipTag.merge(selectedTagFilters, [tag])
        }
    }

    // MARK: - Selection FABs

    private var hasSelection: Bool { !selectedIDs.isEmpty }

    private var allSelectedStarred: Bool {
        let selected = selectedClips
        return !selected.isEmpty && selected.allSatisfy(\.isStarred)
    }

    private var selectionFABStack: some View {
        VStack(spacing: 12) {
            if isSelecting {
                bulkTagFAB
                bulkStarFAB
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

    private var bulkTagFAB: some View {
        Button {
            showBulkTagPicker = true
        } label: {
            LibraryActionCircle(systemImage: "tag", tint: AppPalette.accent, enabled: hasSelection)
        }
        .buttonStyle(.plain)
        .disabled(!hasSelection)
        .accessibilityLabel("Add tags to selected clips")
    }

    private var bulkStarFAB: some View {
        Button {
            toggleBulkStar()
        } label: {
            LibraryActionCircle(
                systemImage: allSelectedStarred ? "star.slash" : "star.fill",
                tint: .yellow,
                enabled: hasSelection
            )
        }
        .buttonStyle(.plain)
        .disabled(!hasSelection)
        .accessibilityLabel(allSelectedStarred ? "Unstar selected clips" : "Star selected clips")
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

    // MARK: - Grid cells

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
        .overlay(alignment: .topTrailing) {
            if !isSelecting {
                starButton(for: record)
            }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(isSelecting ? (selected ? "Deselect" : "Select") : "Plays the clip")
        .contextMenu {
            if !isSelecting {
                Button {
                    toggleStar(record)
                } label: {
                    Label(
                        record.isStarred ? "Unstar" : "Star",
                        systemImage: record.isStarred ? "star.slash" : "star"
                    )
                }
                Button {
                    editingTagsFor = record
                } label: {
                    Label("Edit Tags", systemImage: "tag")
                }
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

    private func starButton(for record: ClipRecord) -> some View {
        Button {
            toggleStar(record)
        } label: {
            Image(systemName: record.isStarred ? "star.fill" : "star")
                .font(.title3)
                .foregroundStyle(record.isStarred ? Color.yellow : Color.white)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(record.isStarred ? "Unstar" : "Star")
    }

    private var storageText: String {
        let bytes = filteredClips.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let count = filteredClips.count
        return "\(count) clip\(count == 1 ? "" : "s") · \(size)"
    }

    private var selectedText: String {
        let count = selectedIDs.count
        if count == 0 { return "Select clips" }
        return "\(count) selected"
    }

    private var selectedRecords: [ClipRecord] {
        selectedClips.map(\.record)
    }

    /// Selection is pruned to visible clips whenever filters change, so every
    /// bulk action (share, delete, star, tag) sees the same set.
    private var selectedClips: [Clip] {
        filteredClips.filter { selectedIDs.contains($0.id) }
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
        // `lastClip` is a snapshot; tags/star may have changed since it was taken.
        playerRecord = container.clipStore.clip(withID: clip.id)?.record ?? clip
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

    private func toggleStar(_ record: ClipRecord) {
        guard let clip = container.clipStore.clip(withID: record.id) else { return }
        let newValue = !record.isStarred
        do {
            try container.clipStore.setStarred(clip, isStarred: newValue)
            if container.lastClip?.id == record.id {
                container.lastClip = clip.record
            }
            statusMessage = newValue ? "Starred" : "Unstarred"
        } catch {
            statusMessage = "Star failed: \(error.localizedDescription)"
        }
    }

    private func toggleBulkStar() {
        let targets = selectedClips
        guard !targets.isEmpty else { return }
        let star = !allSelectedStarred
        do {
            try container.clipStore.setStarred(targets, isStarred: star)
            if let lastID = container.lastClip?.id,
               targets.contains(where: { $0.id == lastID }),
               let updated = container.clipStore.clip(withID: lastID) {
                container.lastClip = updated.record
            }
            statusMessage = star ? "Starred" : "Unstarred"
        } catch {
            statusMessage = "Star failed: \(error.localizedDescription)"
        }
    }

    private func applyTags(_ tags: [String], to record: ClipRecord) {
        guard let clip = container.clipStore.clip(withID: record.id) else { return }
        do {
            try container.clipStore.updateTags(clip, tags: tags)
            if container.lastClip?.id == record.id {
                container.lastClip = clip.record
            }
            statusMessage = "Tags updated"
        } catch {
            statusMessage = "Tags failed: \(error.localizedDescription)"
        }
    }

    private func bulkAddTags(_ tags: [String]) {
        let targets = selectedClips
        guard !targets.isEmpty else { return }
        do {
            try container.clipStore.addTags(targets, tags: tags)
            if let lastID = container.lastClip?.id,
               let updated = targets.first(where: { $0.id == lastID }) {
                container.lastClip = updated.record
            }
            let count = targets.count
            statusMessage = "Tagged \(count) clip\(count == 1 ? "" : "s")"
        } catch {
            statusMessage = "Tags failed: \(error.localizedDescription)"
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
                .overlay(alignment: .topTrailing) {
                    if isSelecting && record.isStarred {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.yellow)
                            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                            .padding(8)
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

            TagPillRow(tags: record.tags, limit: 2)
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
