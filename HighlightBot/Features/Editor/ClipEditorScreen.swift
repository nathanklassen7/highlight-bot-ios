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

/// How the editor hands back its result.
enum ClipEditorMode {
    /// Save re-encodes and writes a clip, replacing the original or adding a copy.
    case export(onComplete: (ClipEditOutcome) -> Void)
    /// Done returns the edit without encoding; the caller applies it later.
    /// Used by the montage builder, where clips are rendered together at the end.
    case configure(onDone: (ClipEdit) -> Void)
}

/// Full-screen trim/edit screen for one clip. Drag the yellow handles to
/// choose a range, optionally add a slow-mo segment (green handles, speed from
/// the same menu as the player), and play to preview. In export mode, Save
/// re-encodes and replaces the original or keeps the result as a new clip;
/// the screen locks while it runs. In configure mode (the montage builder),
/// Done hands the settings back and nothing is encoded.
///
/// Preview plays the slow-mo by switching the player's rate as the playhead
/// crosses the segment, so the timeline stays in source seconds. Export
/// stretches the segment for real (see `ClipTrimmer`). With Slow-mo replay
/// on, the first pass stays at 1× and the segment plays again at the slow
/// rate afterwards; Save appends that replay to the file.
///
/// Present with `.fullScreenCover`. In `.export` mode `onComplete` fires before
/// dismissal so the presenter can refresh its copy of the record. In
/// `.configure` mode nothing is encoded: Done hands the `ClipEdit` back and
/// the montage builder renders it later.
struct ClipEditorScreen: View {
    let record: ClipRecord
    let mode: ClipEditorMode

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    @State private var player = AVPlayer()
    @State private var timeObserver: Any?
    @State private var duration: Double
    @State private var start: Double
    @State private var end: Double
    @State private var slowMotion: SlowMotionSegment?
    /// When a segment exists, play the trim at 1× then replay the segment slow.
    @State private var isSlowMotionReplay: Bool
    /// True while the post-pass replay of the green range is in flight.
    @State private var isReplayingSlowMotion = false
    /// True between hitting `end` and the seek back to the slow-mo start landing.
    @State private var isSeekingSlowMotionReplay = false
    @State private var isSpeedMenuExpanded = false
    @State private var playhead: Double = 0
    @State private var isPlaying = false
    @State private var isEditing = false
    @State private var frames: [UIImage] = []
    @State private var showSaveOptions = false
    @State private var isExporting = false
    @State private var statusMessage: String?

    private static let filmstripFrameCount = 12

    /// Single-clip editing from the player or Library: Save re-encodes.
    init(record: ClipRecord, onComplete: @escaping (ClipEditOutcome) -> Void) {
        self.init(record: record, edit: .full(duration: record.duration), mode: .export(onComplete: onComplete))
    }

    /// Montage child: starts from `edit` and hands the result to `onDone`
    /// without encoding anything.
    init(record: ClipRecord, edit: ClipEdit, onDone: @escaping (ClipEdit) -> Void) {
        self.init(record: record, edit: edit, mode: .configure(onDone: onDone))
    }

    private init(record: ClipRecord, edit: ClipEdit, mode: ClipEditorMode) {
        self.record = record
        self.mode = mode
        let duration = max(record.duration, 0.01)
        // A saved edit may predate a trim of this clip; keep it inside the file.
        let seeded = edit.clamped(toClipDuration: duration, minimumDuration: ClipTrimmer.minimumDuration)
        _duration = State(initialValue: duration)
        _start = State(initialValue: seeded.start)
        _end = State(initialValue: seeded.end)
        _slowMotion = State(initialValue: seeded.slowMotion)
        _isSlowMotionReplay = State(initialValue: seeded.slowMotion != nil && seeded.isSlowMotionReplay)
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
                .onTapGesture {
                    if isSpeedMenuExpanded {
                        isSpeedMenuExpanded = false
                    } else {
                        togglePlayback()
                    }
                }

                controls
            }
            .padding(.horizontal, ScreenMetrics.horizontal)
            .speedMenuOverlay(
                isExpanded: $isSpeedMenuExpanded,
                rates: SlowMotionSegment.rates,
                selection: slowMotion?.rate ?? SlowMotionSegment.defaultRate,
                accessibilityNoun: "Slow-mo speed",
                onSelect: { rate in slowMotion?.rate = rate }
            )
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
        .onChange(of: slowMotion) { old, new in
            // Preview whichever slow-mo edge moved; a rate change previews nothing.
            guard let new else {
                stopSlowMotionReplayPhase()
                return
            }
            if old?.start != new.start {
                handleEdgeChange(to: new.start)
            } else if old?.end != new.end {
                handleEdgeChange(to: new.end)
            }
        }
        .onChange(of: isSlowMotionReplay) { _, replay in
            if !replay {
                stopSlowMotionReplayPhase()
            }
            applyPreviewRate()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard notification.object as AnyObject? === player.currentItem else { return }
            handlePlaybackReachedEnd()
        }
        .confirmationDialog("Save edited clip?", isPresented: $showSaveOptions, titleVisibility: .visible) {
            Button("Replace Original") {
                Task { await save(replacingOriginal: true) }
            }
            Button("Save as New Clip") {
                Task { await save(replacingOriginal: false) }
            }
        } message: {
            Text(saveMessage)
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

            Text("Trim/edit")
                .font(.headline)
                .foregroundStyle(.white)

            Spacer()

            switch mode {
            case .export:
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
                .accessibilityHint(hasChanges ? "" : "Move a handle or add slow-mo first")
            case .configure(let onDone):
                // Always enabled: resetting a clip to full length is a valid edit.
                Button {
                    player.pause()
                    onDone(currentEdit)
                    dismiss()
                } label: {
                    Text("Done")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.yellow)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Keeps this trim for the montage")
            }
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
                Text(selectionText)
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
                slowMotion: $slowMotion,
                playhead: playhead,
                minimumDuration: ClipTrimmer.minimumDuration,
                slowMotionMinimumDuration: SlowMotionSegment.minimumDuration,
                frames: frames,
                onEditingChanged: { editing in
                    isEditing = editing
                    if editing {
                        player.pause()
                        isPlaying = false
                        stopSlowMotionReplayPhase()
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

            slowMotionBar

            Text(hintText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    /// Compact-width portrait (iPhone). Landscape keeps the single-row bar.
    private var stacksSlowMotionControls: Bool {
        horizontalSizeClass == .compact && verticalSizeClass == .regular
    }

    /// Add/remove the slow-mo segment and, once there is one, pick its speed.
    /// The speed menu floats above this bar via `speedMenuOverlay`.
    @ViewBuilder
    private var slowMotionBar: some View {
        Group {
            if stacksSlowMotionControls {
                VStack(alignment: .leading, spacing: 12) {
                    addSlowMotionButton
                    if let slowMotion {
                        HStack(spacing: 12) {
                            slowMotionSpeedTrigger(slowMotion)
                            slowMotionDurationLabel(slowMotion)
                            Spacer(minLength: 0)
                        }
                        slowMotionReplayToggle
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                HStack(spacing: 12) {
                    addSlowMotionButton
                    if let slowMotion {
                        slowMotionDivider
                        slowMotionSpeedTrigger(slowMotion)
                        slowMotionDurationLabel(slowMotion)
                        slowMotionDivider
                        slowMotionReplayToggle
                            .fixedSize()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.white.opacity(0.08), in: Capsule())
            }
        }
        .animation(.easeInOut(duration: 0.15), value: slowMotion == nil)
        .animation(.easeInOut(duration: 0.15), value: isSlowMotionReplay)
        .animation(.easeInOut(duration: 0.15), value: stacksSlowMotionControls)
    }

    private var addSlowMotionButton: some View {
        Button {
            toggleSlowMotion()
        } label: {
            Label(
                slowMotion == nil ? "Add Slow-mo" : "Remove Slow-mo",
                systemImage: slowMotion == nil ? "plus.circle" : "minus.circle"
            )
            .font(.footnote.weight(.semibold))
            .foregroundStyle(slowMotion == nil ? Color.white : Color.green)
        }
        .buttonStyle(.plain)
        .accessibilityHint(slowMotion == nil ? "Inserts a 1 second slow-mo segment halfway through the selection" : "")
    }

    private func slowMotionSpeedTrigger(_ slowMotion: SlowMotionSegment) -> some View {
        SpeedMenuTrigger(
            rate: slowMotion.rate,
            isExpanded: $isSpeedMenuExpanded,
            accessibilityNoun: "slow-mo speeds"
        )
        .font(.title3)
        .foregroundStyle(.white)
    }

    private func slowMotionDurationLabel(_ slowMotion: SlowMotionSegment) -> some View {
        Text("\(TrimRangeBar.timeText(slowMotion.duration)) → \(TrimRangeBar.timeText(slowMotion.scaledDuration))")
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(Color.green)
            .accessibilityLabel("Slow-mo lasts \(TrimRangeBar.timeText(slowMotion.duration)) and plays for \(TrimRangeBar.timeText(slowMotion.scaledDuration))")
    }

    private var slowMotionReplayToggle: some View {
        Toggle("Slow-mo replay", isOn: $isSlowMotionReplay)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isSlowMotionReplay ? Color.green : Color.white)
            .tint(.green)
            .controlSize(.small)
            .accessibilityHint("Plays the trimmed clip at normal speed, then replays the slow-mo segment")
    }

    private var slowMotionDivider: some View {
        Divider()
            .frame(height: 16)
            .overlay(Color.white.opacity(0.3))
    }

    private var exportingOverlay: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
            Text(slowMotion == nil ? "Trimming…" : "Encoding slow-mo…")
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

    /// Length of the clip Save will write: the selection plus whatever the
    /// slow-mo stretch (or appended replay) adds.
    private var outputDuration: Double {
        selectedDuration + extraSlowMotionDuration
    }

    private var extraSlowMotionDuration: Double {
        guard let slowMotion else { return 0 }
        return slowMotion.addedDuration(replay: isSlowMotionReplay)
    }

    private var isTrimmed: Bool {
        start > 0.01 || end < duration - 0.01
    }

    /// Save is a no-op until a handle has moved or slow-mo has been added.
    private var hasChanges: Bool {
        isTrimmed || slowMotion != nil
    }

    private var isConfiguring: Bool {
        if case .configure = mode { return true }
        return false
    }

    /// The trim and slow-mo as they stand, for the configure mode's Done.
    private var currentEdit: ClipEdit {
        ClipEdit(
            start: start,
            end: end,
            slowMotion: slowMotion,
            isSlowMotionReplay: slowMotion != nil && isSlowMotionReplay
        )
    }

    private var selectionText: String {
        let selected = "\(TrimRangeBar.timeText(selectedDuration)) selected"
        guard slowMotion != nil else { return selected }
        return "\(selected) · \(isConfiguring ? "makes" : "saves") \(TrimRangeBar.timeText(outputDuration))"
    }

    private var hintText: String {
        let saveNote = isConfiguring
            ? "Done keeps the edit for the montage; nothing is encoded yet."
            : "Saving re-encodes the clip."
        if slowMotion == nil {
            return "Drag the handles to trim. \(saveNote)"
        }
        if isSlowMotionReplay {
            return "The clip plays at full speed, then the green range replays in slow-mo. \(saveNote)"
        }
        return "Yellow handles trim; green handles bound the slow-mo. \(saveNote)"
    }

    private var saveMessage: String {
        var parts: [String] = []
        if isTrimmed {
            parts.append("Keeps \(TrimRangeBar.timeText(selectedDuration)) of \(TrimRangeBar.timeText(duration)).")
        }
        if let slowMotion {
            if isSlowMotionReplay {
                parts.append("Then \(TrimRangeBar.timeText(slowMotion.duration)) replays at \(SpeedMenu.percentLabel(for: slowMotion.rate)), so the clip runs \(TrimRangeBar.timeText(outputDuration)).")
            } else {
                parts.append("\(TrimRangeBar.timeText(slowMotion.duration)) plays at \(SpeedMenu.percentLabel(for: slowMotion.rate)), so the clip runs \(TrimRangeBar.timeText(outputDuration)).")
            }
        }
        parts.append(isTrimmed ? "Replacing removes the rest from this device." : "Replacing overwrites the original on this device.")
        return parts.joined(separator: " ")
    }

    // MARK: - Slow-mo

    /// Inserts a `SlowMotionSegment.defaultDuration` segment centred in the
    /// selection, or removes the existing one.
    private func toggleSlowMotion() {
        isSpeedMenuExpanded = false
        if slowMotion == nil {
            let segment = SlowMotionSegment.centered(in: start, end)
            slowMotion = segment
            seek(to: segment.start, preview: false)
        } else {
            slowMotion = nil
            stopSlowMotionReplayPhase()
            if isPlaying { player.rate = 1 }
        }
    }

    /// Preview runs at the slow-mo rate while the playhead is inside the
    /// segment and at 1× elsewhere. Replay mode keeps the first pass at 1×
    /// and only slows during the appended replay. Only touches the player
    /// while it is playing, since setting a non-zero rate on a paused player
    /// starts it.
    private func applyPreviewRate() {
        guard isPlaying else { return }
        let target: Float
        if isReplayingSlowMotion, let slowMotion {
            target = slowMotion.rate
        } else if isSlowMotionReplay {
            target = 1
        } else {
            target = slowMotion.map { $0.contains(playhead) ? $0.rate : 1 } ?? 1
        }
        if player.rate != target {
            player.rate = target
        }
    }

    /// Drop the post-pass replay without pausing a first-pass preview.
    private func stopSlowMotionReplayPhase() {
        isSeekingSlowMotionReplay = false
        guard isReplayingSlowMotion else {
            applyEndTime()
            return
        }
        isReplayingSlowMotion = false
        applyEndTime()
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
            slowMotion = slowMotion?.clamped(to: start, end, minimumDuration: SlowMotionSegment.minimumDuration)
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
        if isReplayingSlowMotion, let segment = slowMotion, playhead < segment.end - 0.05 {
            player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: segment.end, preferredTimescale: 600)
            player.rate = segment.rate
            isPlaying = true
            return
        }
        isReplayingSlowMotion = false
        applyEndTime()
        if playhead >= end - 0.05 || playhead < start {
            seek(to: start, preview: false)
        }
        player.play()
        isPlaying = true
        applyPreviewRate()
    }

    /// Playback stops at `end` on its own; seeks are clamped to the range too.
    /// During a slow-mo replay the end time is the segment's end instead.
    private func applyEndTime() {
        let limit = isReplayingSlowMotion ? (slowMotion?.end ?? end) : end
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: limit, preferredTimescale: 600)
    }

    /// First pass reached `end`. Either start the slow-mo replay or stop.
    private func handlePlaybackReachedEnd() {
        if isSlowMotionReplay, let segment = slowMotion, !isReplayingSlowMotion {
            beginSlowMotionReplay(segment)
            return
        }
        finishPlayback()
    }

    /// Seek back to the green range and play it at the slow-mo rate.
    private func beginSlowMotionReplay(_ segment: SlowMotionSegment) {
        isReplayingSlowMotion = true
        isSeekingSlowMotionReplay = true
        isPlaying = true
        playhead = segment.start
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: segment.end, preferredTimescale: 600)
        let time = CMTime(seconds: segment.start, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in
                isSeekingSlowMotionReplay = false
                guard finished, isReplayingSlowMotion, isSlowMotionReplay, isPlaying else { return }
                player.rate = segment.rate
                isPlaying = player.rate != 0
            }
        }
    }

    private func finishPlayback() {
        player.pause()
        isPlaying = false
        isReplayingSlowMotion = false
        isSeekingSlowMotionReplay = false
        playhead = end
        applyEndTime()
    }

    /// Show the frame under a moving handle. Handle drags arrive with
    /// `isEditing` set; VoiceOver adjustments arrive without it. Programmatic
    /// changes (the duration refinement in `load`) preview nothing, so the
    /// playhead stays where the user left it.
    private func handleEdgeChange(to time: Double) {
        if isReplayingSlowMotion {
            stopSlowMotionReplayPhase()
        } else {
            applyEndTime()
        }
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
                let wasPlaying = isPlaying
                let playerPlaying = player.timeControlStatus == .playing && player.rate != 0
                guard !isEditing, time.isNumeric else {
                    if !isSeekingSlowMotionReplay {
                        isPlaying = playerPlaying
                    }
                    return
                }
                let seconds = time.seconds
                guard seconds.isFinite else { return }

                if isSeekingSlowMotionReplay {
                    return
                }

                if isReplayingSlowMotion, let segment = slowMotion {
                    playhead = min(max(seconds, segment.start), segment.end)
                    if playhead >= segment.end - 0.02, wasPlaying || playerPlaying {
                        finishPlayback()
                        return
                    }
                    isPlaying = playerPlaying
                    applyPreviewRate()
                    return
                }

                playhead = min(max(seconds, start), end)
                if playhead >= end - 0.02, wasPlaying || playerPlaying {
                    handlePlaybackReachedEnd()
                    return
                }
                isPlaying = playerPlaying
                applyPreviewRate()
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
        guard case .export(let onComplete) = mode else { return }
        guard let clip = container.clipStore.clip(withID: record.id) else {
            statusMessage = "This clip no longer exists."
            return
        }
        isExporting = true
        defer { isExporting = false }

        let trimmer = ClipTrimmer(clipsDirectory: AppDirectories.clips)
        let baseName = Self.freshBaseName(for: record)
        do {
            let exported = try await trimmer.trim(
                record.fileURL,
                start: start,
                end: end,
                slowMotion: slowMotion,
                replay: isSlowMotionReplay,
                baseName: baseName
            )
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
                    // Same timestamp, tags, star, and montage flag so the copy sits beside its source.
                    let copy = ClipRecord(
                        id: UUID(),
                        createdAt: record.createdAt,
                        duration: exported.duration,
                        fileName: exported.fileURL.lastPathComponent,
                        thumbnailFileName: exported.thumbnailFileName,
                        triggerSource: record.triggerSource,
                        sizeBytes: exported.sizeBytes,
                        tags: record.tags,
                        isStarred: record.isStarred,
                        isMontage: record.isMontage
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
            Log.ui.error("Edit failed: \(String(describing: error), privacy: .public)")
            Haptics.error()
            statusMessage = "Save failed: \(error.localizedDescription)"
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
