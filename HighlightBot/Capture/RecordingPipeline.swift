import Foundation
import AVFoundation
import CoreMedia
import os
import OSLog
import HighlightCore

/// One-second snapshot of pipeline health for the debug overlay and logs.
struct PipelineMetrics: Sendable, Equatable {
    var capturedFrames: Int
    /// Frames dropped by the capture output (`didDrop`). Should stay 0.
    var droppedFrames: Int
    /// Frames dropped by `FrameTap` because an analyzer was busy. Expected.
    var analyzerDroppedFrames: Int
    /// Video buffers the writer refused (encoder behind). Should stay 0.
    var skippedVideoAppends: Int
    /// Audio buffers the writer refused. Each one is an audible gap.
    var skippedAudioAppends: Int
    var bufferedSeconds: TimeInterval
    /// Time from segment delivery to the ring buffer finishing the disk write, ms.
    var lastSegmentWriteMillis: Double
    var lastExportSeconds: Double
    /// Duration of the last video data callback, microseconds. Budget: <1000.
    var lastCallbackMicros: Double
    /// Process CPU over the last metrics interval, percent of one core.
    var cpuPercent: Double
    var thermalState: ProcessInfo.ThermalState
    var freeBytes: Int64
    var currentFrameRate: Int
    /// Angle stamped into the file transform, degrees. Frozen while recording,
    /// so a sideways clip shows up here before anyone opens the file.
    var rotationDegrees: Int
    var sessionID: SessionID?

    static let zero = PipelineMetrics(
        capturedFrames: 0,
        droppedFrames: 0,
        analyzerDroppedFrames: 0,
        skippedVideoAppends: 0,
        skippedAudioAppends: 0,
        bufferedSeconds: 0,
        lastSegmentWriteMillis: 0,
        lastExportSeconds: 0,
        lastCallbackMicros: 0,
        cpuPercent: 0,
        thermalState: .nominal,
        freeBytes: 0,
        currentFrameRate: 0,
        rotationDegrees: 0,
        sessionID: nil
    )
}

/// Failures surfaced to the `SessionCoordinator`.
enum PipelineError: LocalizedError {
    case lowStorage(freeBytes: Int64)
    case nothingToSave
    case notRecording
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .lowStorage(let freeBytes):
            let megabytes = Double(freeBytes) / (1024 * 1024)
            return String(format: "Not enough free storage (%.0f MB available).", megabytes)
        case .nothingToSave: return "The buffer has no footage to save yet."
        case .notRecording: return "Not recording."
        case .exportFailed(let message): return "Clip export failed: \(message)"
        }
    }
}

/// Wires `CaptureSource` → `SampleFanout` → `SegmentedRecorder` →
/// `SegmentRingBuffer`, plus `FrameTap`, and implements
/// `HighlightCore.RecordingBackend` for the coordinator. The App creates one.
///
/// Per recording session it builds a fresh recorder and fanout (so config
/// changes apply on the next start) and runs thermal- and power-driven
/// frame-rate changes. Two longer-lived tasks sit alongside: 1 Hz metrics
/// for as long as the camera runs, and capture-event forwarding to the
/// coordinator for the pipeline's lifetime (`CaptureSource.events` is a
/// single stream).
///
/// Frame rate follows `FrameRatePolicy`: the idle viewfinder runs at 30 fps
/// and the configured rate is only requested for the span of a recording.
/// `@unchecked Sendable`: `source` is a non-Sendable protocol type owned only
/// here; all mutable state sits behind `state`.
final class RecordingPipeline: RecordingBackend, @unchecked Sendable {
    let source: any CaptureSource

    private let ring: SegmentRingBuffer
    private let exporter: ClipExporter
    private let frameTap: FrameTap
    private let audioListener: (any AudioSampleListener)?
    private let coordinator: SessionCoordinator
    private let thermal = ThermalMonitor()
    private let powerMode = PowerModeMonitor()
    private let cpu = CPUUsageSampler()
    private let recorderQueue = DispatchQueue(label: "com.highlightbot.recorder", qos: .utility)

    private struct State: Sendable {
        var config: RecordingConfig
        /// Config the source was last configured with; nil until `startPreview`.
        var configuredConfig: RecordingConfig?
        var isSourceRunning = false
        /// Whether the viewfinder should be live. Set by `startPreview`, cleared
        /// by `stopPreview`; a stop that lands while the camera is still
        /// starting is honoured once the start returns.
        var previewWanted = false
        var recorder: SegmentedRecorder?
        var fanout: SampleFanout?
        var isRecording = false
        var currentFrameRate: Int
        var lastRingWriteMillis: Double = 0
        var subscribers: [UUID: AsyncStream<PipelineMetrics>.Continuation] = [:]
        var sessionTasks: [Task<Void, Never>] = []
        /// Runs while the source runs; see `startMetricsTask`.
        var metricsTask: Task<Void, Never>?
        var eventsTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(source: any CaptureSource,
         config: RecordingConfig,
         ringBuffer: SegmentRingBuffer,
         exporter: ClipExporter,
         frameTap: FrameTap,
         audioListener: (any AudioSampleListener)? = nil,
         coordinator: SessionCoordinator) {
        self.source = source
        self.ring = ringBuffer
        self.exporter = exporter
        self.frameTap = frameTap
        self.audioListener = audioListener
        self.coordinator = coordinator
        let config = config.resolved()
        self.state = OSAllocatedUnfairLock(initialState: State(config: config, currentFrameRate: config.frameRate))
    }

    deinit {
        state.withLock { s in
            s.eventsTask?.cancel()
            s.metricsTask?.cancel()
            for task in s.sessionTasks { task.cancel() }
            for continuation in s.subscribers.values { continuation.finish() }
        }
    }

    // MARK: - Configuration & metrics

    /// Stores the config, updates the ring policy now, and applies everything
    /// else (format, bitrate, segment interval) on the next `startRecording`.
    func updateConfig(_ config: RecordingConfig) async {
        let config = config.resolved()
        let (recording, previewing) = state.withLock { s in
            s.config = config
            if !s.isRecording { s.currentFrameRate = config.frameRate }
            return (s.isRecording, s.isSourceRunning)
        }
        await ring.updatePolicy(RingBufferPolicy(config: config))
        // Apply capture-format changes to the live viewfinder right away when
        // we are not recording; while recording they wait for the next start.
        if previewing && !recording {
            do {
                try await startPreview()
            } catch {
                Log.session.error("Reconfiguring preview failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Independent stream per caller; emits ~1 Hz while the camera is running.
    func metrics() -> AsyncStream<PipelineMetrics> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: PipelineMetrics.self, bufferingPolicy: .bufferingNewest(1))
        state.withLock { $0.subscribers[id] = continuation }
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: - Preview lifecycle

    /// Runs the camera so the viewfinder is live without recording, at the
    /// idle frame rate. Reconfigures the source if the config changed since
    /// the last configure. Safe to call repeatedly; a no-op while recording.
    func startPreview() async throws {
        try await ensureSourceRunning()
        guard !state.withLock({ $0.isRecording }) else { return }
        await applyFrameRatePolicy()
    }

    /// Configure (if needed) and start the source. Does not touch the frame
    /// rate; callers pick idle or recording.
    private func ensureSourceRunning() async throws {
        let (config, configured, running, recording) = state.withLock { s in
            s.previewWanted = true
            return (s.config, s.configuredConfig, s.isSourceRunning, s.isRecording)
        }
        if recording { return }

        if configured != config {
            try await source.configure(config)
            state.withLock { s in
                s.configuredConfig = config
                s.currentFrameRate = config.frameRate
            }
        }
        if !running {
            try await source.start()
            // A stopPreview() that arrived while the camera was starting wins;
            // otherwise the viewfinder would stay up behind another tab.
            let stillWanted = state.withLock { s in
                if s.previewWanted { s.isSourceRunning = true }
                return s.previewWanted
            }
            guard stillWanted else {
                await source.stop()
                Log.session.info("Preview start abandoned; camera stopped")
                return
            }
            Log.session.info("Preview started")
            startMetricsTask()
        }
        ensureEventsTask()
    }

    /// Stops the camera entirely (also stops recording if active).
    func stopPreview() async {
        state.withLock { $0.previewWanted = false }
        if state.withLock({ $0.isRecording }) {
            await stopRecording()
        }
        guard state.withLock({ $0.isSourceRunning }) else { return }
        await source.stop()
        state.withLock { $0.isSourceRunning = false }
        stopMetricsTask()
        Log.session.info("Preview stopped")
    }

    // MARK: - RecordingBackend

    func startRecording() async throws {
        let config = state.withLock { $0.config }
        let freeBytes = StorageMonitor.freeBytes(at: AppDirectories.ring)
        guard freeBytes >= config.minimumFreeBytes else {
            Log.session.error("Refusing to record: \(freeBytes) bytes free < \(config.minimumFreeBytes) required")
            throw PipelineError.lowStorage(freeBytes: freeBytes)
        }
        if state.withLock({ $0.isRecording }) {
            return
        }

        // Camera must be configured with the current config and running.
        try await ensureSourceRunning()
        // Bring the camera up from the idle rate before any frame reaches the
        // writer, so the first segment is already at the recording rate.
        let recordingRate = Self.recordingFrameRate(for: config)
        await source.setFrameRate(recordingRate)

        // Freeze before the angle is read, never after: the writer stamps the
        // transform once and the ring holds one initialization segment per
        // session, so the angle below has to hold for the whole recording.
        source.setRotationFrozen(true)

        let recorder = SegmentedRecorder(
            config: config,
            queue: recorderQueue,
            videoRotationAngle: source.captureRotationAngle,
            clock: source.captureClock
        ) { [weak self] segment in
            self?.handleSegment(segment)
        }
        let fanout = SampleFanout(recorder: recorder, frameTap: frameTap, audioListener: audioListener)
        // start() allocates the encoder; keep it ahead of setConsumer so that
        // work never lands inside a capture callback.
        recorder.start()
        source.setConsumer(fanout)

        state.withLock { s in
            s.recorder = recorder
            s.fanout = fanout
            s.isRecording = true
            s.currentFrameRate = recordingRate
            s.lastRingWriteMillis = 0
        }
        ensureEventsTask()
        startSessionTasks()
        Log.session.info("Recording started (\(config.width)x\(config.height)@\(config.frameRate), \(config.segmentInterval, format: .fixed(precision: 1))s segments, retain \(config.retainSeconds, format: .fixed(precision: 1))s)")
    }

    func stopRecording() async {
        let (recorder, tasks) = state.withLock { s -> (SegmentedRecorder?, [Task<Void, Never>]) in
            let recorder = s.recorder
            let tasks = s.sessionTasks
            s.recorder = nil
            s.fanout = nil
            s.isRecording = false
            s.sessionTasks = []
            return (recorder, tasks)
        }
        for task in tasks { task.cancel() }

        // The camera keeps running so the viewfinder stays live; only the
        // recorder detaches.
        source.setConsumer(nil)
        // Unconditional: a freeze that outlived its session would leave the
        // preview stuck sideways with nothing to unstick it.
        source.setRotationFrozen(false)
        await recorder?.stop()
        do {
            try await ring.clear()
        } catch {
            Log.ring.error("ring.clear failed: \(error.localizedDescription, privacy: .public)")
        }
        // Back to the idle rate; the viewfinder does not need 60 fps.
        if state.withLock({ $0.isSourceRunning }) {
            await applyFrameRatePolicy()
        }
        Log.session.info("Recording stopped")
    }

    /// Wait for the segment containing the trigger moment to land in the ring,
    /// snapshot, export. Recording continues throughout.
    ///
    /// The writer closes segments only at fixed boundaries (it cannot flush on
    /// demand while compressing; see `SegmentedRecorder.supportsOnDemandFlush`),
    /// so the footage from the last boundary up to the trigger is still inside
    /// the writer when the trigger fires. We wait for the next boundary — at
    /// most `segmentInterval` plus a delivery margin — so the clip ends 0 to
    /// `segmentInterval` seconds *after* the trigger rather than before it.
    func saveClip(lastSeconds: TimeInterval, source triggerSource: TriggerSourceID) async throws -> ClipRecord {
        let (recorder, config) = state.withLock { ($0.isRecording ? $0.recorder : nil, $0.config) }
        guard let recorder else { throw PipelineError.notRecording }

        let bufferedBefore = await ring.bufferedSeconds
        let segmentsBefore = await ring.segments.count
        let waitStarted = ContinuousClock.now

        let flushed = await recorder.flushSegment()
        // Expected boundary wait, or a full interval if the recorder cannot tell yet.
        let expected = flushed ? 0.5 : (recorder.secondsUntilNextBoundary ?? config.segmentInterval)
        let maxWait = min(expected + 1.5, config.segmentInterval + 2.0)
        let deadline = waitStarted + .milliseconds(Int64(maxWait * 1_000))

        var arrived = false
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            let buffered = await ring.bufferedSeconds
            let count = await ring.segments.count
            if buffered > bufferedBefore || count > segmentsBefore {
                arrived = true
                break
            }
        }
        let waitedMillis = (ContinuousClock.now - waitStarted).timeInterval * 1_000
        Log.session.info("Trigger tail \(arrived ? "arrived" : "did not arrive", privacy: .public) after \(waitedMillis, format: .fixed(precision: 0)) ms (expected \(expected, format: .fixed(precision: 2))s, flushed=\(flushed))")

        guard let plan = await ring.snapshot(lastSeconds: lastSeconds) else {
            throw PipelineError.nothingToSave
        }

        let baseName = ClipNaming.baseName(for: .now)
        let exported: ExportedClip
        do {
            exported = try await exporter.export(plan, baseName: baseName)
        } catch {
            throw PipelineError.exportFailed(error.localizedDescription)
        }

        return ClipRecord(
            id: UUID(),
            createdAt: .now,
            duration: exported.duration,
            fileName: exported.fileURL.lastPathComponent,
            thumbnailFileName: exported.thumbnailURL.map { "Thumbnails/" + $0.lastPathComponent },
            triggerSource: triggerSource,
            sizeBytes: exported.sizeBytes,
            videoWidth: exported.videoWidth,
            videoHeight: exported.videoHeight
        )
    }

    /// New writer session (new `SessionID`); the ring evicts the old one when
    /// the new initialization segment arrives.
    func restartSession() async throws {
        let recorder = state.withLock { $0.isRecording ? $0.recorder : nil }
        guard let recorder else { throw PipelineError.notRecording }
        await recorder.restart()
        Log.session.notice("Writer session restarted")
    }

    // MARK: - Segment handoff

    /// Called on AVFoundation's delegate queue. Persisting happens off that
    /// queue so the writer is never blocked on disk I/O.
    private func handleSegment(_ segment: IncomingSegment) {
        let received = DispatchTime.now().uptimeNanoseconds
        let ring = self.ring
        Task(priority: .utility) { [weak self] in
            do {
                let stored = try await ring.append(segment)
                let millis = Double(DispatchTime.now().uptimeNanoseconds - received) / 1_000_000
                self?.state.withLock { $0.lastRingWriteMillis = millis }
                let buffered = await ring.bufferedSeconds
                Log.ring.debug("stored \(stored.id, privacy: .public) \(stored.kind.rawValue, privacy: .public) \(stored.byteCount) bytes in \(millis, format: .fixed(precision: 2)) ms; buffered \(buffered, format: .fixed(precision: 2))s")
            } catch {
                Log.ring.error("ring.append failed for seq \(segment.seq): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Background tasks

    private func ensureEventsTask() {
        let needsTask = state.withLock { $0.eventsTask == nil }
        guard needsTask else { return }

        let events = source.events
        let task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.handleCaptureEvent(event)
            }
        }
        state.withLock { s in
            if s.eventsTask == nil {
                s.eventsTask = task
            } else {
                task.cancel()
            }
        }
    }

    private func handleCaptureEvent(_ event: CaptureEvent) async {
        let isRecording = state.withLock { $0.isRecording }
        switch event {
        case .started, .stopped:
            break
        case .formatChanged(let width, let height, let frameRate):
            state.withLock { $0.currentFrameRate = frameRate }
            Log.session.notice("Capture format now \(width)x\(height)@\(frameRate)")
        case .interrupted(let reason):
            Log.session.notice("Capture interrupted: \(reason, privacy: .public)")
            guard isRecording else { return }
            await coordinator.captureDidInterrupt()
        case .resumed:
            Log.session.notice("Capture resumed")
            guard isRecording else { return }
            await coordinator.captureDidResume()
        case .runtimeError(let message):
            Log.session.error("Capture failed: \(message, privacy: .public)")
            state.withLock { $0.isSourceRunning = false }
            stopMetricsTask()
            guard isRecording else { return }
            await coordinator.captureDidFail(reason: message)
        }
    }

    /// 1 Hz metrics for as long as the camera runs, recording or not, so the
    /// overlay can show idle cost (frame rate, CPU) as well as session health.
    /// Replaces any previous task.
    private func startMetricsTask() {
        let task = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.collectMetrics()
                self.broadcast(snapshot)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        let previous = state.withLock { s -> Task<Void, Never>? in
            defer { s.metricsTask = task }
            return s.metricsTask
        }
        previous?.cancel()
    }

    private func stopMetricsTask() {
        let task = state.withLock { s -> Task<Void, Never>? in
            defer { s.metricsTask = nil }
            return s.metricsTask
        }
        task?.cancel()
    }

    private func startSessionTasks() {
        // Both streams yield their current value first, so the policy is
        // re-applied once at session start and then on every change.
        let thermalStates = thermal.states()
        let thermalTask = Task(priority: .utility) { [weak self] in
            for await _ in thermalStates {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.applyFrameRatePolicy()
            }
        }

        let powerStates = powerMode.states()
        let powerTask = Task(priority: .utility) { [weak self] in
            for await _ in powerStates {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.applyFrameRatePolicy()
            }
        }

        state.withLock { $0.sessionTasks = [thermalTask, powerTask] }
    }

    /// The rate a recording should run right now, given heat and power state.
    private static func recordingFrameRate(for config: RecordingConfig) -> Int {
        let info = ProcessInfo.processInfo
        return FrameRatePolicy.target(
            configured: config.frameRate,
            isRecording: true,
            thermalState: info.thermalState,
            lowPowerMode: info.isLowPowerModeEnabled
        )
    }

    /// Asks the source for whatever `FrameRatePolicy` says the rate should be.
    /// The source ignores a request matching its current rate, so this is
    /// cheap to call on every thermal or power change.
    private func applyFrameRatePolicy() async {
        let (config, recording) = state.withLock { ($0.config, $0.isRecording) }
        let info = ProcessInfo.processInfo
        let target = FrameRatePolicy.target(
            configured: config.frameRate,
            isRecording: recording,
            thermalState: info.thermalState,
            lowPowerMode: info.isLowPowerModeEnabled
        )
        Log.session.debug("Frame rate policy → \(target) fps (recording=\(recording) thermal=\(info.thermalState.rawValue) lowPower=\(info.isLowPowerModeEnabled))")
        // Success emits `.formatChanged`, which updates `currentFrameRate`.
        // High-fps slo-mo formats are sometimes locked to 120/240; `setFrameRate`
        // is then a no-op and metrics keep reporting the real rate.
        await source.setFrameRate(target)
    }

    private func collectMetrics() async -> PipelineMetrics {
        let (fanout, recorder, frameRate, ringMillis) = state.withLock {
            ($0.fanout, $0.recorder, $0.currentFrameRate, $0.lastRingWriteMillis)
        }
        let counters = fanout?.snapshotCounters()
        let buffered = await ring.bufferedSeconds
        let metrics = PipelineMetrics(
            capturedFrames: counters?.capturedFrames ?? 0,
            droppedFrames: counters?.droppedFrames ?? 0,
            analyzerDroppedFrames: frameTap.droppedCount,
            skippedVideoAppends: recorder?.skippedVideoAppends ?? 0,
            skippedAudioAppends: recorder?.skippedAudioAppends ?? 0,
            bufferedSeconds: buffered,
            lastSegmentWriteMillis: ringMillis,
            lastExportSeconds: exporter.lastExportSeconds,
            lastCallbackMicros: counters?.lastCallbackMicros ?? 0,
            cpuPercent: cpu.sample(),
            thermalState: ProcessInfo.processInfo.thermalState,
            freeBytes: StorageMonitor.freeBytes(at: AppDirectories.ring),
            currentFrameRate: frameRate,
            rotationDegrees: Int(source.captureRotationAngle.rounded()),
            sessionID: recorder?.currentSessionID
        )
        Log.session.debug("metrics frames=\(metrics.capturedFrames) dropped=\(metrics.droppedFrames) analyzerDropped=\(metrics.analyzerDroppedFrames) buffered=\(metrics.bufferedSeconds, format: .fixed(precision: 1))s cbMicros=\(metrics.lastCallbackMicros, format: .fixed(precision: 0)) cbMaxMicros=\(counters?.maxCallbackMicros ?? 0, format: .fixed(precision: 0)) writeMs=\(metrics.lastSegmentWriteMillis, format: .fixed(precision: 1)) cpu=\(metrics.cpuPercent, format: .fixed(precision: 0))% skippedVideo=\(metrics.skippedVideoAppends) skippedAudio=\(metrics.skippedAudioAppends) fps=\(metrics.currentFrameRate) rotation=\(metrics.rotationDegrees) thermal=\(metrics.thermalState.rawValue)")
        return metrics
    }

    private func broadcast(_ metrics: PipelineMetrics) {
        let continuations = state.withLock { Array($0.subscribers.values) }
        for continuation in continuations {
            continuation.yield(metrics)
        }
    }
}
