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
    var thermalState: ProcessInfo.ThermalState
    var freeBytes: Int64
    var currentFrameRate: Int
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
        thermalState: .nominal,
        freeBytes: 0,
        currentFrameRate: 0,
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
/// changes apply on the next start), then runs three tasks: 1 Hz metrics,
/// thermal-driven frame-rate changes, and capture-event forwarding to the
/// coordinator. The capture-event task lives for the pipeline's lifetime
/// because `CaptureSource.events` is a single stream.
/// `@unchecked Sendable`: `source` is a non-Sendable protocol type owned only
/// here; all mutable state sits behind `state`.
final class RecordingPipeline: RecordingBackend, @unchecked Sendable {
    let source: any CaptureSource

    private let ring: SegmentRingBuffer
    private let exporter: ClipExporter
    private let frameTap: FrameTap
    private let coordinator: SessionCoordinator
    private let thermal = ThermalMonitor()
    private let recorderQueue = DispatchQueue(label: "com.highlightbot.recorder", qos: .utility)

    private struct State: Sendable {
        var config: RecordingConfig
        /// Config the source was last configured with; nil until `startPreview`.
        var configuredConfig: RecordingConfig?
        var isSourceRunning = false
        var recorder: SegmentedRecorder?
        var fanout: SampleFanout?
        var isRecording = false
        var currentFrameRate: Int
        var lastRingWriteMillis: Double = 0
        var subscribers: [UUID: AsyncStream<PipelineMetrics>.Continuation] = [:]
        var sessionTasks: [Task<Void, Never>] = []
        var eventsTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    init(source: any CaptureSource,
         config: RecordingConfig,
         ringBuffer: SegmentRingBuffer,
         exporter: ClipExporter,
         frameTap: FrameTap,
         coordinator: SessionCoordinator) {
        self.source = source
        self.ring = ringBuffer
        self.exporter = exporter
        self.frameTap = frameTap
        self.coordinator = coordinator
        self.state = OSAllocatedUnfairLock(initialState: State(config: config, currentFrameRate: config.frameRate))
    }

    deinit {
        state.withLock { s in
            s.eventsTask?.cancel()
            for task in s.sessionTasks { task.cancel() }
            for continuation in s.subscribers.values { continuation.finish() }
        }
    }

    // MARK: - Configuration & metrics

    /// Stores the config, updates the ring policy now, and applies everything
    /// else (format, bitrate, segment interval) on the next `startRecording`.
    func updateConfig(_ config: RecordingConfig) async {
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

    /// Independent stream per caller; emits ~1 Hz while recording.
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

    /// Runs the camera so the viewfinder is live without recording. Reconfigures
    /// the source if the config changed since the last configure. Safe to call
    /// repeatedly; a no-op while recording.
    func startPreview() async throws {
        let (config, configured, running, recording) = state.withLock {
            ($0.config, $0.configuredConfig, $0.isSourceRunning, $0.isRecording)
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
            state.withLock { $0.isSourceRunning = true }
            Log.session.info("Preview started")
        }
        ensureEventsTask()
    }

    /// Stops the camera entirely (also stops recording if active).
    func stopPreview() async {
        if state.withLock({ $0.isRecording }) {
            await stopRecording()
        }
        guard state.withLock({ $0.isSourceRunning }) else { return }
        await source.stop()
        state.withLock { $0.isSourceRunning = false }
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
        try await startPreview()

        let recorder = SegmentedRecorder(
            config: config,
            queue: recorderQueue,
            videoRotationAngle: source.captureRotationAngle
        ) { [weak self] segment in
            self?.handleSegment(segment)
        }
        let fanout = SampleFanout(recorder: recorder, frameTap: frameTap)
        recorder.start()
        source.setConsumer(fanout)

        state.withLock { s in
            s.recorder = recorder
            s.fanout = fanout
            s.isRecording = true
            s.currentFrameRate = config.frameRate
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
        await recorder?.stop()
        do {
            try await ring.clear()
        } catch {
            Log.ring.error("ring.clear failed: \(error.localizedDescription, privacy: .public)")
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
            sizeBytes: exported.sizeBytes
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
            guard isRecording else { return }
            await coordinator.captureDidFail(reason: message)
        }
    }

    private func startSessionTasks() {
        let metricsTask = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let snapshot = await self.collectMetrics()
                self.broadcast(snapshot)
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let thermalStates = thermal.states()
        let thermalTask = Task(priority: .utility) { [weak self] in
            for await thermalState in thermalStates {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.applyThermalState(thermalState)
            }
        }

        state.withLock { $0.sessionTasks = [metricsTask, thermalTask] }
    }

    /// `.serious`/`.critical` → 30 fps; `.nominal`/`.fair` → configured rate.
    private func applyThermalState(_ thermalState: ProcessInfo.ThermalState) async {
        let (configured, current) = state.withLock { ($0.config.frameRate, $0.currentFrameRate) }
        let target: Int
        switch thermalState {
        case .serious, .critical:
            target = min(30, configured)
        case .nominal, .fair:
            target = configured
        @unknown default:
            target = configured
        }
        guard target != current else { return }
        Log.session.notice("Thermal state \(thermalState.rawValue): frame rate \(current) → \(target)")
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
            thermalState: ProcessInfo.processInfo.thermalState,
            freeBytes: StorageMonitor.freeBytes(at: AppDirectories.ring),
            currentFrameRate: frameRate,
            sessionID: recorder?.currentSessionID
        )
        Log.session.debug("metrics frames=\(metrics.capturedFrames) dropped=\(metrics.droppedFrames) analyzerDropped=\(metrics.analyzerDroppedFrames) buffered=\(metrics.bufferedSeconds, format: .fixed(precision: 1))s cbMicros=\(metrics.lastCallbackMicros, format: .fixed(precision: 0)) cbMaxMicros=\(counters?.maxCallbackMicros ?? 0, format: .fixed(precision: 0)) writeMs=\(metrics.lastSegmentWriteMillis, format: .fixed(precision: 1)) skippedVideo=\(metrics.skippedVideoAppends) skippedAudio=\(metrics.skippedAudioAppends) fps=\(metrics.currentFrameRate) thermal=\(metrics.thermalState.rawValue)")
        return metrics
    }

    private func broadcast(_ metrics: PipelineMetrics) {
        let continuations = state.withLock { Array($0.subscribers.values) }
        for continuation in continuations {
            continuation.yield(metrics)
        }
    }
}
