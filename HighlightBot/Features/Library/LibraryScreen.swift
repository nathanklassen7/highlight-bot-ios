import HighlightCore
import SwiftData
import SwiftUI

/// Grid of saved clips, newest first. Tap to play; long-press for Star, Tags,
/// Trim, Share, Save to Photos, and Delete. Select mode toggles membership in a
/// set of clip IDs; with two or more selected, the scissors button opens the montage builder.
/// A vertical drag still scrolls; a drag that starts with a
/// sideways component selects the contiguous grid range between the start clip
/// and the clip under the finger (add if the start was unselected, remove if
/// it was selected), auto-scrolling near the viewport edges.
private enum LibraryMotion {
    static let clipSelection = Animation.easeInOut(duration: 0.12)
}

private enum LibraryLayout {
    static let horizontalPadding: CGFloat = 4
    static let gridSpacing: CGFloat = 4
}

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
    @State private var montageOnly = false
    @State private var selectedTagFilters: [String] = []
    @State private var editingTagsFor: ClipRecord?
    @State private var trimmingRecord: ClipRecord?
    @State private var showBulkTagPicker = false
    @State private var montageRequest: MontageRequest?
    @State private var isLandscape = false

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: LibraryLayout.gridSpacing)]

    var body: some View {
        NavigationStack {
            Group {
                if clips.isEmpty {
                    ContentUnavailableView(
                        "No clips yet",
                        systemImage: "film.stack",
                        description: Text("Start recording and tap the screen to save the last few seconds.")
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

                            if showsFilterBar {
                                filterBar
                            }

                            if filteredClips.isEmpty {
                                ContentUnavailableView(
                                    "No matching clips",
                                    systemImage: "line.3.horizontal.decrease.circle",
                                    description: Text("Try clearing a filter.")
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                            } else {
                                LazyVGrid(columns: columns, spacing: LibraryLayout.gridSpacing) {
                                    ForEach(filteredClips) { clip in
                                        let record = clip.record
                                        clipCell(for: record)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, LibraryLayout.horizontalPadding)
                        .padding(.top, ScreenMetrics.top)
                        .padding(.bottom, selectionScrollBottomInset)
                        .background {
                            LibraryDragSelectBridge(
                                isEnabled: isSelecting,
                                selectedIDs: selectedIDs,
                                orderedIDs: filteredClips.map(\.id),
                                onSelectionChange: { ids in
                                    var transaction = Transaction()
                                    transaction.disablesAnimations = true
                                    withTransaction(transaction) {
                                        selectedIDs = ids
                                    }
                                }
                            )
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $playerRecord) { record in
                ClipPlayerScreen(record: record, navigationOrder: playerNavigationOrder(for: record))
            }
            .fullScreenCover(item: $trimmingRecord) { record in
                ClipEditorScreen(record: record) { outcome in
                    handleEdit(outcome)
                }
            }
            .fullScreenCover(item: $montageRequest) { request in
                MontageEditorScreen(clips: request.clips) { record in
                    handleMontageSaved(record)
                }
            }
            .sheet(item: $editingTagsFor) { record in
                TagPickerSheet(title: "Edit Tags", initialSelection: record.tags) { tags in
                    applyTags(tags, to: record)
                }
            }
            .sheet(isPresented: $showBulkTagPicker) {
                // Capture the shared set when the sheet opens so the diff on
                // Done is against what the user actually saw.
                let common = commonSelectedTags
                let count = selectedClips.count
                TagPickerSheet(
                    title: "Tag \(count) Clip\(count == 1 ? "" : "s")",
                    initialSelection: common,
                    footnote: "Shows tags all \(count) selected clips share. Adding applies to every clip; removing takes it off every clip. Tags only some clips have are left alone."
                ) { tags in
                    bulkApplyTags(tags, common: common)
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
                if !hasStarredClips {
                    starredOnly = false
                }
                if !hasMontageClips {
                    montageOnly = false
                }
                if clips.isEmpty {
                    exitSelection()
                }
            }
            .onChange(of: starredOnly) { _, _ in pruneSelectionToVisible() }
            .onChange(of: montageOnly) { _, _ in pruneSelectionToVisible() }
            .onChange(of: selectedTagFilters) { _, _ in pruneSelectionToVisible() }
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width > proxy.size.height
            } action: { isLandscape = $0 }
        }
    }

    // MARK: - Filtering

    private var filteredClips: [Clip] {
        clips.filter { clip in
            (!starredFilterActive || clip.isStarred)
                && (!montageFilterActive || clip.isMontage)
                && (selectedTagFilters.isEmpty || clip.tags.contains { ClipTag.contains(selectedTagFilters, $0) })
        }
    }

    /// Sideways swipes in the player walk the grid as the user sees it. Should
    /// the clip ever fall outside the active filters, the player walks every
    /// clip instead of having nowhere to go.
    private func playerNavigationOrder(for record: ClipRecord) -> [UUID] {
        let visible = filteredClips.map(\.id)
        return visible.contains(record.id) ? visible : clips.map(\.id)
    }

    private var availableFilterTags: [String] {
        ClipTag.sortedForDisplay(ClipTag.merge([], clips.flatMap(\.tags)))
    }

    private var hasStarredClips: Bool {
        clips.contains(where: \.isStarred)
    }

    private var hasMontageClips: Bool {
        clips.contains(where: \.isMontage)
    }

    /// The bar is only useful when at least one chip can narrow the grid.
    private var showsFilterBar: Bool {
        hasStarredClips || hasMontageClips || !availableFilterTags.isEmpty
    }

    /// A chip that has nothing left to match is hidden, so it must not keep filtering.
    private var starredFilterActive: Bool { starredOnly && hasStarredClips }
    private var montageFilterActive: Bool { montageOnly && hasMontageClips }

    private var hasActiveFilters: Bool {
        starredFilterActive || montageFilterActive || !selectedTagFilters.isEmpty
    }

    /// Bumps when clip count, tags, starred, or montage state changes so selection and filters stay valid.
    private var clipsRevision: Int {
        var hasher = Hasher()
        hasher.combine(clips.count)
        for clip in clips {
            hasher.combine(clip.id)
            hasher.combine(clip.tags)
            hasher.combine(clip.isStarred)
            hasher.combine(clip.isMontage)
        }
        return hasher.finalize()
    }

    @ViewBuilder
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if hasStarredClips {
                    filterChip(
                        title: "Starred",
                        systemImage: starredOnly ? "star.fill" : "star",
                        isOn: starredOnly,
                        fill: .yellow
                    ) {
                        starredOnly.toggle()
                    }
                }

                if hasMontageClips {
                    filterChip(
                        title: "Montage",
                        systemImage: montageOnly ? "film.stack.fill" : "film.stack",
                        isOn: montageOnly,
                        fill: AppPalette.accent
                    ) {
                        montageOnly.toggle()
                    }
                }

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
                        montageOnly = false
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
            // Content keeps the screen inset; the scroll view itself bleeds to
            // the edges (negative padding below) so overflow is visible.
            .padding(.horizontal, LibraryLayout.horizontalPadding)
        }
        .padding(.horizontal, -LibraryLayout.horizontalPadding)
    }

    private func filterChip(
        title: String,
        systemImage: String,
        isOn: Bool,
        fill: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isOn ? AppPalette.onFill : .primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isOn ? fill : Color.secondary.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
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

    private var selectionScrollBottomInset: CGFloat {
        guard isSelecting else { return 88 }
        return isLandscape ? 88 : 200
    }

    private var selectionFABStack: some View {
        Group {
            if isLandscape {
                HStack(alignment: .center, spacing: 12) {
                    if isSelecting {
                        selectionActionFABs
                    }
                    selectionToggleFAB
                }
            } else {
                VStack(spacing: 12) {
                    if isSelecting {
                        selectionActionFABs
                    }
                    selectionToggleFAB
                }
            }
        }
        .animation(LibraryMotion.clipSelection, value: isSelecting)
        .animation(LibraryMotion.clipSelection, value: isLandscape)
    }

    @ViewBuilder
    private var selectionActionFABs: some View {
        montageFAB
        bulkTagFAB
        bulkStarFAB
        shareFAB
        deleteFAB
    }

    private var selectionToggleFAB: some View {
        Button {
            if isSelecting {
                exitSelection()
            } else {
                isSelecting = true
            }
        } label: {
            LibraryActionCircle(
                systemImage: isSelecting ? "xmark" : "checklist",
                tint: isSelecting ? AppPalette.onFill : AppPalette.accent
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isSelecting ? "Done" : "Select clips")
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

    private var canMakeMontage: Bool {
        selectedIDs.count >= MontageDraft.minimumClipCount
    }

    private var montageFAB: some View {
        Button {
            montageRequest = MontageRequest(clips: selectedRecords)
        } label: {
            LibraryActionCircle(systemImage: "scissors", tint: AppPalette.accent, enabled: canMakeMontage)
        }
        .buttonStyle(.plain)
        .disabled(!canMakeMontage)
        .accessibilityLabel("Make a montage from selected clips")
        .accessibilityHint(canMakeMontage ? "" : "Select at least \(MontageDraft.minimumClipCount) clips")
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
        .clipDragSelectTarget(id: record.id)
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
                Button {
                    trimmingRecord = record
                } label: {
                    Label("Trim", systemImage: "scissors")
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
        withAnimation(LibraryMotion.clipSelection) {
            if selectedIDs.contains(id) {
                selectedIDs.remove(id)
            } else {
                selectedIDs.insert(id)
            }
        }
    }

    private func exitSelection() {
        isSelecting = false
        selectedIDs.removeAll()
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

    /// Tags every selected clip has; the bulk picker starts from these.
    private var commonSelectedTags: [String] {
        ClipStore.commonTags(of: selectedClips.map(\.tags))
    }

    /// Diff the picker result against the shared tags: new ones union onto
    /// every selected clip, removed shared ones come off every selected clip.
    /// Tags only some clips had are untouched.
    private func bulkApplyTags(_ result: [String], common: [String]) {
        let targets = selectedClips
        guard !targets.isEmpty else { return }
        let added = result.filter { !ClipTag.contains(common, $0) }
        let removed = common.filter { !ClipTag.contains(result, $0) }
        guard !added.isEmpty || !removed.isEmpty else { return }
        do {
            try container.clipStore.applyTags(targets, add: added, remove: removed)
            if let lastID = container.lastClip?.id,
               let updated = targets.first(where: { $0.id == lastID }) {
                container.lastClip = updated.record
            }
            let count = targets.count
            statusMessage = "Updated tags on \(count) clip\(count == 1 ? "" : "s")"
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

    /// The editor already updated the store (and `lastClip` for a replace);
    /// `@Query` refreshes the grid, so only the toast is left.
    private func handleEdit(_ outcome: ClipEditOutcome) {
        switch outcome {
        case .replaced: statusMessage = "Clip updated"
        case .savedCopy: statusMessage = "Saved as a new clip"
        }
    }

    /// The montage screen already inserted the clip and set `lastClip`;
    /// `@Query` puts it at the top of the grid. Leave select mode and confirm.
    private func handleMontageSaved(_ record: ClipRecord) {
        exitSelection()
        statusMessage = "Montage saved · \(TrimRangeBar.timeText(record.duration))"
    }
}

/// One grid cell: thumbnail with duration and tags overlaid. No caption under the tile.
struct ClipCell: View {
    let record: ClipRecord
    var isSelecting = false
    var isSelected = false

    var body: some View {
        ThumbnailImage(fileName: record.thumbnailFileName)
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottom) {
                // One row so the tag pill can take leftover width and
                // ellipsize instead of running under the duration badge.
                HStack(alignment: .bottom, spacing: 6) {
                    libraryTagBadge
                        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                        .layoutPriority(0)
                    Spacer(minLength: 0)
                    Text(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .layoutPriority(1)
                }
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
            .animation(LibraryMotion.clipSelection, value: isSelected)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityDescription)
    }

    /// Single tag shows its name (truncated if needed). Multiple tags collapse to a count.
    @ViewBuilder
    private var libraryTagBadge: some View {
        if record.tags.count == 1, let tag = record.tags.first {
            TagPill(tag: tag, size: .compact)
        } else if record.tags.count > 1 {
            Text("\(record.tags.count) tags")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppPalette.onFill)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(TagStyle.custom, in: Capsule())
                .accessibilityLabel(record.tags.joined(separator: ", "))
        }
    }

    private var accessibilityDescription: String {
        var parts: [String] = []
        if record.isMontage {
            parts.append("Montage")
        }
        parts.append(record.createdAt.formatted(.relative(presentation: .named)))
        parts.append(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
        if !record.tags.isEmpty {
            parts.append(record.tags.joined(separator: ", "))
        }
        return parts.joined(separator: ", ")
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

/// Clips handed to the montage builder, wrapped so `fullScreenCover(item:)`
/// has an identity per request.
private struct MontageRequest: Identifiable {
    let id = UUID()
    let clips: [ClipRecord]
}
