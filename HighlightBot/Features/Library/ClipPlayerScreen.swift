import AVFoundation
import HighlightCore
import SwiftUI
import UIKit

/// Full-screen player for one clip with loop and slow-motion controls, plus
/// Share / Save to Photos / Delete. Swipe down to close; swipe sideways to
/// move through `navigationOrder`.
struct ClipPlayerScreen: View {
    @State private var record: ClipRecord

    /// Clip IDs in the order the Library shows them (newest first). Swiping
    /// left advances to the next ID, right goes back. Neighbours are re-fetched
    /// from the store on each swipe so deleted clips are skipped.
    let navigationOrder: [UUID]

    @Environment(AppContainer.self) private var container
    @Environment(\.dismiss) private var dismiss

    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var isLooping = false
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
    /// Re-arms `timeObserver` when the playing item changes (loop toggle, clip
    /// swipe, trim replace, or an `AVPlayerLooper` replica advance).
    @State private var currentItemObservation: NSKeyValueObservation?
    /// False after dismiss so a queued item-change callback cannot re-arm the observer.
    @State private var isPlayerActive = false
    /// Invalidates seek completions after a newer seek, a scrub start, or a queue rebuild.
    @State private var seekSession = 0
    @State private var seekInFlight = false
    @State private var pendingSeek: PendingSeek?
    @State private var showTagPicker = false
    @State private var showEditor = false
    /// Vertical distance the player has followed a swipe-down; 0 when not dragging.
    @State private var dismissDragOffset: CGFloat = 0
    /// Horizontal distance the player has followed a sideways swipe; 0 at rest.
    @State private var pageDragOffset: CGFloat = 0
    /// Locked on the first movement past `minimumDistance` so a drag can't
    /// flip between dismissing and paging mid-gesture.
    @State private var dragAxis: Axis?
    /// Resolved once when a horizontal drag locks so the hot path doesn't
    /// hit the store on every movement.
    @State private var pageNeighbors = PageNeighbors()
    @State private var isPageTransitioning = false
    /// False until `AVPlayerLayer` has a frame; the poster thumbnail shows
    /// through, then the layer fades in over `playerFadeDuration`.
    @State private var isPlayerVisible = false

    private static let playerFadeDuration: TimeInterval = 0.1

    private static let dismissDragThreshold: CGFloat = 120
    private static let dismissFlingThreshold: CGFloat = 300
    /// Fraction of the screen width a sideways drag must cover to change clips.
    private static let pageDragThresholdFraction: CGFloat = 0.3
    private static let pageFlingThreshold: CGFloat = 300
    /// How far the content follows the finger when there is no clip in that direction.
    private static let pageEdgeResistance: CGFloat = 0.25

    init(record: ClipRecord, navigationOrder: [UUID] = []) {
        _record = State(initialValue: record)
        self.navigationOrder = navigationOrder
    }

    var body: some View {
        GeometryReader { proxy in
            playerContent(
                pageWidth: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing
            )
        }
    }

    private func playerContent(pageWidth: CGFloat) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ZStack {
                // The poster frame sits under the transparent player layer, so any
                // moment the layer has no frame (first load, item swap) shows the
                // thumbnail instead of black. No readiness timing to get right.
                pageThumbnail(for: record)

                PlayerLayerView(player: player) { ready in
                    if ready {
                        isPlayerVisible = true
                    }
                }
                .opacity(isPlayerVisible ? 1 : 0)
                // Fade only on the way in; hiding on a clip swap must be instant
                // so the previous video never cross-fades over the new poster.
                .animation(isPlayerVisible ? .easeOut(duration: Self.playerFadeDuration) : nil, value: isPlayerVisible)
                .ignoresSafeArea()

                // Neighbouring clips sit one page to either side so a sideways
                // drag reveals them edge-to-edge instead of empty black.
                if isShowingNeighborPages {
                    if let previous = pageNeighbors.previous {
                        pageThumbnail(for: previous)
                            .offset(x: -pageWidth)
                    }
                    if let next = pageNeighbors.next {
                        pageThumbnail(for: next)
                            .offset(x: pageWidth)
                    }
                }

                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        handleScreenTap()
                    }

                // No full-rect content shape here: taps on empty areas fall through to
                // the background layer above, which toggles the overlay. Taps on
                // controls still land on the controls and reschedule the auto-hide.
                chromeOverlay
                    .opacity(isOverlayVisible ? 1 : 0)
                    .allowsHitTesting(isOverlayVisible)
                    .accessibilityHidden(!isOverlayVisible)
                    .simultaneousGesture(TapGesture().onEnded {
                        scheduleOverlayAutoHide()
                    })
            }
            .offset(x: pageDragOffset, y: dismissDragOffset)
            .scaleEffect(1 - dismissDragProgress * 0.15)
        }
        // Attached to the root so a swipe anywhere counts. Child controls (slider,
        // buttons) still win their own gestures, so scrubbing is unaffected.
        .gesture(swipeGesture(pageWidth: pageWidth))
        .statusBarHidden(true)
        .onAppear { startPlayback() }
        .onDisappear {
            overlayHideTask?.cancel()
            overlayHideTask = nil
            isPlayerActive = false
            currentItemObservation?.invalidate()
            currentItemObservation = nil
            cancelSeeks()
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
        .onChange(of: isOverlayVisible) { _, visible in
            if !visible { isSpeedMenuExpanded = false }
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
        .sheet(isPresented: $showTagPicker) {
            TagPickerSheet(title: "Edit Tags", initialSelection: record.tags) { tags in
                applyTags(tags)
            }
        }
        .onChange(of: showTagPicker) { _, isPresented in
            if isPresented {
                overlayHideTask?.cancel()
                overlayHideTask = nil
                isOverlayVisible = true
            } else {
                scheduleOverlayAutoHide()
            }
        }
        .fullScreenCover(isPresented: $showEditor) {
            ClipEditorScreen(record: record) { outcome in
                handleEdit(outcome)
            }
        }
        .onChange(of: showEditor) { _, isPresented in
            // Two players on one file is wasteful; hand playback to the editor.
            if isPresented {
                player.pause()
                markPlaybackInactive()
            }
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

                    Button {
                        toggleStarred()
                    } label: {
                        Image(systemName: record.isStarred ? "star.fill" : "star")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(record.isStarred ? Color.yellow : Color.white)
                            .padding(10)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(record.isStarred ? "Unstar" : "Star")

                    Text(record.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .foregroundStyle(.white)

                HStack(spacing: 6) {
                    TagPillRow(tags: record.tags, limit: 3, size: .compact)
                    Button {
                        showTagPicker = true
                    } label: {
                        Group {
                            if record.tags.isEmpty {
                                Label("Add tags", systemImage: "tag")
                                    .labelStyle(.titleAndIcon)
                            } else {
                                Label("Edit", systemImage: "tag")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.55), in: Capsule())
                    }
                    .accessibilityLabel("Edit tags")
                    Spacer(minLength: 0)
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
        .speedMenuOverlay(
            isExpanded: $isSpeedMenuExpanded,
            rates: SpeedMenu.playbackRates,
            selection: rate,
            onSelect: { applyRate($0) }
        )
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
                    // Ignore writes while the thumb is following playback. A refresh
                    // that pushes the bound value back through `set` would seek and
                    // suspend the time observer.
                    set: { newValue in
                        guard isScrubbing else { return }
                        seek(to: newValue, preview: true)
                    }
                ),
                in: 0...scrubDuration
            ) { editing in
                if editing {
                    beginScrub()
                } else {
                    endScrub()
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

            SpeedMenuTrigger(rate: rate, isExpanded: $isSpeedMenuExpanded)

            Spacer()

            Button {
                showEditor = true
            } label: {
                Label("Trim", systemImage: "scissors")
            }

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

    private var scrubDuration: Double {
        let value = duration > 0 ? duration : record.duration
        return max(value, 0.01)
    }

    // MARK: - Playback

    private func startPlayback() {
        duration = record.duration
        isPlayerActive = true
        startObservingCurrentItem()
        applyLooping()
        scheduleOverlayAutoHide()
    }

    private func togglePlayback() {
        if isPlaying {
            cancelSeeks()
            player.pause()
            markPlaybackInactive()
            return
        }
        // A cancelled slider gesture can leave `isScrubbing` true. Playback is
        // starting, so the time observer has to be allowed to move the scrubber.
        let scrubWasActive = isScrubbing
        isScrubbing = false
        if isAtEnd {
            isPlaying = true
            seek(to: 0, preview: false, resumeAfter: true)
            return
        }
        if scrubWasActive || seekInFlight {
            isPlaying = true
            seek(to: currentTime, preview: false, resumeAfter: true)
            return
        }
        player.rate = rate
        isPlaying = true
    }

    /// Background tap toggles the overlay, whether playing or paused.
    private func handleScreenTap() {
        if isSpeedMenuExpanded {
            isSpeedMenuExpanded = false
            scheduleOverlayAutoHide()
            return
        }
        if isOverlayVisible {
            overlayHideTask?.cancel()
            overlayHideTask = nil
            isOverlayVisible = false
        } else {
            isOverlayVisible = true
            scheduleOverlayAutoHide()
        }
    }

    // MARK: - Swipe to dismiss / page

    /// 0...1 as the drag approaches the dismiss threshold; drives the shrink.
    private var dismissDragProgress: CGFloat {
        min(max(dismissDragOffset / Self.dismissDragThreshold, 0), 1)
    }

    /// One drag handles both swipe-down (close) and swipe-sideways (next or
    /// previous clip). The axis is locked from the first movement so the
    /// content follows the finger in a straight line. Vertical: the content
    /// pulls away and shrinks; upward drags do nothing. Horizontal: the content
    /// slides with the finger, with resistance when there is no clip that way.
    private func swipeGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard !isScrubbing, !isPageTransitioning else { return }
                let translation = value.translation
                if dragAxis == nil {
                    if abs(translation.height) > abs(translation.width) {
                        dragAxis = .vertical
                    } else {
                        dragAxis = .horizontal
                        pageNeighbors = resolvePageNeighbors()
                    }
                }
                switch dragAxis {
                case .vertical:
                    dismissDragOffset = max(translation.height, 0)
                case .horizontal:
                    let hasNeighbor = pageNeighbors.clip(inSwipeDirection: translation.width) != nil
                    pageDragOffset = hasNeighbor ? translation.width : translation.width * Self.pageEdgeResistance
                case nil:
                    break
                }
            }
            .onEnded { value in
                let axis = dragAxis
                dragAxis = nil
                // A swipe that wins over the slider cancels the slider gesture, and
                // `onEditingChanged(false)` never arrives. Finish the scrub here so
                // `isScrubbing` cannot stay latched while playback continues.
                guard !isScrubbing, !isPageTransitioning else {
                    if isScrubbing {
                        endScrub()
                    }
                    dismissDragOffset = 0
                    pageDragOffset = 0
                    pageNeighbors = PageNeighbors()
                    return
                }
                switch axis {
                case .vertical:
                    endDismissDrag(predictedHeight: value.predictedEndTranslation.height)
                case .horizontal:
                    endPageDrag(
                        translation: value.translation.width,
                        predicted: value.predictedEndTranslation.width,
                        pageWidth: pageWidth
                    )
                case nil:
                    break
                }
            }
    }

    private func endDismissDrag(predictedHeight: CGFloat) {
        let flungDown = predictedHeight > Self.dismissFlingThreshold
        if dismissDragOffset > Self.dismissDragThreshold || flungDown {
            player.pause()
            dismiss()
        } else {
            withAnimation(.spring(duration: 0.3)) { dismissDragOffset = 0 }
        }
    }

    private func endPageDrag(translation: CGFloat, predicted: CGFloat, pageWidth: CGFloat) {
        let passedThreshold = abs(translation) > pageWidth * Self.pageDragThresholdFraction
        let flung = abs(predicted) > Self.pageFlingThreshold && predicted.sign == translation.sign
        // Neighbour pages stay mounted for the whole settle animation either
        // way; `isPageTransitioning` keeps them visible after `dragAxis` clears.
        isPageTransitioning = true
        guard passedThreshold || flung, let next = pageNeighbors.clip(inSwipeDirection: translation) else {
            withAnimation(.spring(duration: 0.25)) {
                pageDragOffset = 0
            } completion: {
                pageNeighbors = PageNeighbors()
                isPageTransitioning = false
            }
            return
        }
        // Slide the strip one page so the neighbour's thumbnail fills the
        // screen, then swap the player underneath it with the offset reset in
        // the same frame. The new record's thumbnail is already behind the
        // layer, so the swap shows the same image until video frames arrive.
        let landedOffset: CGFloat = translation < 0 ? -pageWidth : pageWidth
        var hideChrome = Transaction()
        hideChrome.disablesAnimations = true
        withTransaction(hideChrome) { isOverlayVisible = false }
        withAnimation(.spring(duration: 0.3, bounce: 0)) {
            pageDragOffset = landedOffset
        } completion: {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                switchClip(to: next)
                pageDragOffset = 0
                pageNeighbors = PageNeighbors()
                isPageTransitioning = false
            }
            isOverlayVisible = true
            scheduleOverlayAutoHide()
        }
    }

    private var isShowingNeighborPages: Bool {
        dragAxis == .horizontal || isPageTransitioning
    }

    /// Full-screen, aspect-fit thumbnail; matches the player's `resizeAspect`
    /// framing so a landed page and the video that replaces it line up.
    private func pageThumbnail(for clip: ClipRecord) -> some View {
        ThumbnailImage(fileName: clip.thumbnailFileName, contentMode: .fit)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    /// Nearest existing clips on either side of the current one in
    /// `navigationOrder`. IDs that no longer exist in the store are skipped.
    private func resolvePageNeighbors() -> PageNeighbors {
        guard let index = navigationOrder.firstIndex(of: record.id) else { return PageNeighbors() }
        func nearest(from start: Int, step: Int) -> ClipRecord? {
            var candidate = start
            while navigationOrder.indices.contains(candidate) {
                if let clip = container.clipStore.clip(withID: navigationOrder[candidate]) {
                    return clip.record
                }
                candidate += step
            }
            return nil
        }
        return PageNeighbors(
            previous: nearest(from: index - 1, step: -1),
            next: nearest(from: index + 1, step: 1)
        )
    }

    /// Reloads the single player with another clip. Loop and speed carry over;
    /// position, duration, and the speed menu reset.
    private func switchClip(to next: ClipRecord) {
        record = next
        currentTime = 0
        duration = record.duration
        isSpeedMenuExpanded = false
        isPlayerVisible = false
        applyLooping()
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
    /// The periodic observer is installed only after the new item is in the queue.
    /// It follows the current item's timeline, so leaving it attached across
    /// `removeAllItems()` strands the scrubber while the new item plays.
    private func applyLooping() {
        cancelSeeks()
        isScrubbing = false
        let item = AVPlayerItem(url: record.fileURL)
        looper?.disableLooping()
        looper = nil
        removeTimeObserver()
        player.removeAllItems()
        player.actionAtItemEnd = isLooping ? .advance : .pause
        if isLooping {
            looper = AVPlayerLooper(player: player, templateItem: item)
        } else {
            player.insert(item, after: nil)
        }
        addTimeObserver()
        player.rate = rate
        isPlaying = player.rate != 0
    }

    private func applyRate(_ newRate: Float) {
        rate = newRate
        // Held until the scrub or in-flight seek finishes; that completion applies `rate`.
        guard !isScrubbing, !seekInFlight else { return }
        // VERIFY: setting `rate` directly resumes playback at that speed; slow rates
        // require `AVPlayerItem.canPlaySlowForward`, which is true for local MP4s.
        player.rate = rate
        isPlaying = player.rate != 0
    }

    private func startObservingCurrentItem() {
        currentItemObservation?.invalidate()
        currentItemObservation = player.observe(\.currentItem, options: [.new]) { _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.isPlayerActive else { return }
                    self.addTimeObserver()
                }
            }
        }
    }

    private func beginScrub() {
        isScrubbing = true
        cancelSeeks()
        player.pause()
        isPlaying = false
    }

    /// Sample-accurate seek, then play. Setting `rate` while the seek is in flight
    /// interrupts it, and the periodic observer does not reliably resume afterwards.
    private func endScrub() {
        guard isScrubbing else { return }
        isScrubbing = false
        // Show pause immediately so a tap during the seek cancels it instead of
        // starting a second resume. `rate` stays 0 until the seek completes.
        isPlaying = true
        seek(to: currentTime, preview: false, resumeAfter: true)
    }

    private func cancelSeeks() {
        seekSession += 1
        seekInFlight = false
        pendingSeek = nil
    }

    private func addTimeObserver() {
        removeTimeObserver()
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            MainActor.assumeIsolated {
                let wasPlaying = isPlaying
                let playerPlaying = player.timeControlStatus == .playing && player.rate != 0
                // A resume seek sets `isPlaying` before `rate` is applied. Taking the
                // player's paused status here would clear that and ignore a pause tap.
                if !seekInFlight {
                    isPlaying = playerPlaying
                }
                guard !isScrubbing, !seekInFlight else { return }
                currentTime = seconds(from: time)
                if let itemDuration = player.currentItem?.duration {
                    let value = seconds(from: itemDuration)
                    if value > 0 { duration = value }
                }
                // Only on the playing → stopped transition, so a user-hidden overlay
                // stays hidden while paused at the end.
                if wasPlaying, !isLooping, duration > 0, currentTime >= duration - 0.05,
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

    private func seek(to seconds: Double, preview: Bool, resumeAfter: Bool = false) {
        let clamped = min(max(seconds, 0), scrubDuration)
        currentTime = clamped
        let request = PendingSeek(seconds: clamped, preview: preview, resumeAfter: resumeAfter)
        // One seek at a time. Overlapping seeks cancel each other and leave the
        // periodic observer suspended while the layer keeps drawing frames.
        if seekInFlight {
            pendingSeek = request
            return
        }
        performSeek(request)
    }

    private func performSeek(_ request: PendingSeek) {
        seekInFlight = true
        let session = seekSession
        let time = CMTime(seconds: request.seconds, preferredTimescale: 600)
        let tolerance = request.preview ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard session == self.seekSession else { return }
                    self.seekInFlight = false
                    if let pending = self.pendingSeek {
                        self.pendingSeek = nil
                        self.performSeek(pending)
                        return
                    }
                    guard self.isPlayerActive else { return }
                    if !self.isScrubbing {
                        self.addTimeObserver()
                    }
                    guard request.resumeAfter, !self.isScrubbing else { return }
                    self.player.rate = self.rate
                    self.isPlaying = true
                    // `isPlaying` may already be true, so the change handler will not
                    // schedule the overlay hide. Do it once `rate` is actually non-zero.
                    self.scheduleOverlayAutoHide()
                }
            }
        }
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

    private func refreshRecord() {
        if let clip = container.clipStore.clip(withID: record.id) {
            record = clip.record
            if container.lastClip?.id == record.id {
                container.lastClip = record
            }
        }
    }

    private func toggleStarred() {
        guard let clip = container.clipStore.clip(withID: record.id) else { return }
        do {
            try container.clipStore.setStarred(clip, isStarred: !record.isStarred)
            refreshRecord()
            statusMessage = record.isStarred ? "Starred" : "Unstarred"
        } catch {
            statusMessage = "Couldn't update: \(error.localizedDescription)"
        }
    }

    private func applyTags(_ tags: [String]) {
        guard let clip = container.clipStore.clip(withID: record.id) else { return }
        do {
            try container.clipStore.updateTags(clip, tags: tags)
            refreshRecord()
            statusMessage = "Tags updated"
        } catch {
            statusMessage = "Couldn't update: \(error.localizedDescription)"
        }
    }

    private func saveToPhotos() async {
        do {
            try await PhotosSaver.save(record.fileURL, permissions: container.permissions)
            statusMessage = "Saved to Photos"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    /// Called by the editor before it dismisses. A replaced clip is reloaded
    /// from its new file and starts over; a copy leaves this player alone.
    private func handleEdit(_ outcome: ClipEditOutcome) {
        switch outcome {
        case .replaced(let updated):
            record = updated
            currentTime = 0
            duration = record.duration
            applyLooping()
            statusMessage = "Clip updated"
        case .savedCopy:
            statusMessage = "Saved as a new clip"
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

/// A scrub or playhead move waiting until the in-flight `AVPlayer.seek` finishes.
private struct PendingSeek {
    var seconds: Double
    var preview: Bool
    var resumeAfter: Bool
}

/// The clips on either side of the one playing, in Library order.
private struct PageNeighbors {
    var previous: ClipRecord?
    var next: ClipRecord?

    /// Finger moving left (negative width) reveals `next`; moving right reveals `previous`.
    func clip(inSwipeDirection width: CGFloat) -> ClipRecord? {
        if width < 0 { return next }
        if width > 0 { return previous }
        return nil
    }
}