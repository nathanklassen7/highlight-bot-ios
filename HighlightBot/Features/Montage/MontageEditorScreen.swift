import HighlightCore
import SwiftUI

/// Full-screen montage builder. Lists the chosen clips in order (oldest first
/// to start), lets the user drag them into a new order and tap one to trim it
/// or add slow-mo in `ClipEditorScreen`. Per-clip edits live in the draft,
/// not on disk, so a clip can be reopened and tweaked. The check mark renders
/// every clip's edit in sequence as one new clip flagged `isMontage`.
///
/// Present with `.fullScreenCover`. `onComplete` fires with the saved record
/// before dismissal; the store has already been updated.
struct MontageEditorScreen: View {
    let onComplete: (ClipRecord) -> Void

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var draft: MontageDraft
    @State private var editingItem: MontageItem?
    @State private var isExporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress: MontageExportProgress?
    @State private var showDiscardConfirm = false
    @State private var statusMessage: String?

    init(clips: [ClipRecord], onComplete: @escaping (ClipRecord) -> Void) {
        _draft = State(initialValue: MontageDraft(clips: clips))
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                clipList
                footer
            }
            .padding(.horizontal, ScreenMetrics.horizontal)
            .disabled(isExporting)

            if isExporting {
                exportingOverlay
            }
        }
        .statusBarHidden(true)
        .interactiveDismissDisabled(isExporting)
        .fullScreenCover(item: $editingItem) { item in
            ClipEditorScreen(record: item.clip, edit: item.edit) { edit in
                draft.update(edit, for: item.id)
            }
        }
        .confirmationDialog("Discard this montage?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard", role: .destructive) {
                dismiss()
            }
        } message: {
            Text("Your clip order and edits are lost. The original clips are not changed.")
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
                if draft.hasChanges {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            } label: {
                Text("Cancel")
                    .font(.body)
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("Montage")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            Button {
                guard !isExporting else { return }
                exportTask = Task { await exportMontage() }
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppPalette.onFill)
                    .frame(width: 34, height: 34)
                    .background(AppPalette.confirm, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Save montage")
            .accessibilityHint("Exports the clips in this order as one new clip")
        }
        .padding(.vertical, 12)
    }

    /// Drag handles come from active edit mode; reordering uses UIKit's
    /// reorder control, which VoiceOver exposes as a "Reorder" action. Row
    /// taps use `onTapGesture` because a `Button` label can swallow the
    /// reorder press. No selection binding, so edit mode adds no check marks.
    // VERIFY: in iOS 17 `List` with `editMode = .active` and `.onMove` shows
    // grab handles and still delivers `onTapGesture` to row content.
    private var clipList: some View {
        List {
            ForEach(Array(draft.items.enumerated()), id: \.element.id) { index, item in
                MontageRow(index: index, item: item)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        editingItem = item
                    }
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.08))
                            .padding(.vertical, 4)
                    )
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 8))
                    .accessibilityAddTraits(.isButton)
            }
            .onMove { source, destination in
                draft.move(fromOffsets: source, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.editMode, .constant(.active))
        .environment(\.defaultMinListRowHeight, 70)
        .tint(.white)
        .animation(.easeInOut(duration: 0.15), value: draft.items.map(\.id))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                Text("\(draft.items.count) clips")
                Spacer()
                Text("\(TrimRangeBar.timeText(draft.totalDuration)) total")
                    .foregroundStyle(draft.hasEdits ? Color.yellow : Color.white.opacity(0.85))
            }
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))

            Text("Drag the handles to reorder. Tap a clip to trim it or add slow-mo. Saving re-encodes everything into one new clip.")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var exportingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView(value: exportProgress?.fraction ?? 0)
                .progressViewStyle(.linear)
                .tint(.white)
                .frame(width: 220)
                .animation(.linear(duration: 0.2), value: exportProgress?.fraction ?? 0)
            Text("Exporting montage…")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text(remainingText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
                .contentTransition(.numericText())
            Button("Cancel") { exportTask?.cancel() }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityHint("Stops the export and keeps your draft")
        }
        .padding(28)
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exporting montage, \(Int(((exportProgress?.fraction ?? 0) * 10).rounded()) * 10) percent, \(remainingText)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// "About 12 s left" from the exporter's estimate; rounds up so the
    /// number never says 0 while work remains.
    private var remainingText: String {
        guard let exportProgress else { return "Preparing…" }
        if exportProgress.fraction >= 0.97 { return "Finishing up…" }
        let seconds = Int(exportProgress.estimatedSecondsRemaining.rounded(.up))
        if seconds < 1 { return "Almost done" }
        let text = Duration.seconds(seconds).formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
        return "About \(text) left"
    }

    // MARK: - Export

    /// Renders the draft, indexes the result as a new clip stamped now, and
    /// hands it to the presenter. Failures and a user cancel keep the draft
    /// so the user can retry or dismiss.
    private func exportMontage() async {
        isExporting = true
        exportProgress = nil
        defer {
            isExporting = false
            exportProgress = nil
            exportTask = nil
        }

        let now = Date.now
        let baseName = ClipNaming.baseName(for: now)
        let exporter = MontageExporter(clipsDirectory: AppDirectories.clips)
        do {
            let exported = try await exporter.export(draft.items, baseName: baseName) { progress in
                Task { @MainActor in
                    // Callbacks hop over one by one and can land out of order
                    // or after the export has finished; never move the bar
                    // backwards or revive it.
                    guard isExporting else { return }
                    if let current = exportProgress, progress.fraction < current.fraction { return }
                    exportProgress = progress
                }
            }
            let record = ClipRecord(
                id: UUID(),
                createdAt: now,
                duration: exported.duration,
                fileName: exported.fileURL.lastPathComponent,
                thumbnailFileName: exported.thumbnailFileName,
                triggerSource: .ui,
                sizeBytes: exported.sizeBytes,
                // Only what every source shares; the user can add more afterwards.
                tags: ClipStore.commonTags(of: draft.items.map(\.clip.tags)),
                isStarred: false,
                isMontage: true
            )
            do {
                try container.clipStore.insert(record)
            } catch {
                ClipTrimmer.discard(exported)
                throw error
            }
            container.lastClip = record
            Haptics.saved()
            onComplete(record)
            dismiss()
        } catch {
            if Self.isCancellation(error) {
                statusMessage = "Export cancelled"
                return
            }
            Log.export.error("Montage failed: \(String(describing: error), privacy: .public)")
            Haptics.error()
            statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    /// The user tapped Cancel: not a failure, so no haptic or error log.
    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if case .exportCancelled? = error as? ExportError { return true }
        return false
    }
}

/// One clip in the montage list: position, thumbnail, capture time, and the
/// length it contributes (yellow once edited, tortoise when it has slow-mo).
private struct MontageRow: View {
    let index: Int
    let item: MontageItem

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 20)

            ThumbnailImage(fileName: item.clip.thumbnailFileName)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.clip.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Text(TrimRangeBar.timeText(item.outputDuration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.hasChanges ? Color.yellow : Color.white.opacity(0.7))
                    if item.edit.slowMotion != nil {
                        Image(systemName: "tortoise.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.green)
                            .accessibilityLabel("Has slow-mo")
                    }
                    if item.hasChanges {
                        Text("edited")
                            .font(.caption2)
                            .foregroundStyle(Color.yellow.opacity(0.8))
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the trim editor for this clip")
    }
}
