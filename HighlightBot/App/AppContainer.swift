import Foundation
import HighlightCore
import Observation
import SwiftData
import UIKit
import os

/// Errors raised by the app layer itself (not by Core or the capture pipeline).
enum AppError: Error, LocalizedError {
    /// A backend call arrived before the pipeline was wired up.
    case notReady

    var errorDescription: String? {
        switch self {
        case .notReady: "The recording pipeline is not ready yet."
        }
    }
}

/// Shown in the Record save pill after in-flight saves drain.
enum SaveCallout: Equatable, Hashable {
    case saved
    case failed
}

/// Breaks the construction cycle between `SessionCoordinator` (needs a backend)
/// and `RecordingPipeline` (needs the coordinator). The coordinator is created
/// with this proxy; `target` is set once the pipeline exists.
final class BackendProxy: RecordingBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _target: (any RecordingBackend)?

    var target: (any RecordingBackend)? {
        get { lock.withLock { _target } }
        set { lock.withLock { _target = newValue } }
    }

    private func resolved() throws -> any RecordingBackend {
        guard let target else { throw AppError.notReady }
        return target
    }

    func startRecording() async throws {
        try await resolved().startRecording()
    }

    func stopRecording() async {
        guard let target else { return }
        await target.stopRecording()
    }

    func saveClip(lastSeconds: TimeInterval, source: TriggerSourceID) async throws -> ClipRecord {
        try await resolved().saveClip(lastSeconds: lastSeconds, source: source)
    }

    func restartSession() async throws {
        try await resolved().restartSession()
    }
}

/// Dependency container. Built once by `HighlightBotApp`, injected into the
/// environment, and the only object views talk to for session state and actions.
@MainActor
@Observable
final class AppContainer {
    let settings: SettingsStore
    let permissions: PermissionsManager
    let triggerBus: TriggerBus
    let tapTrigger: TapTrigger
    let hardwareTrigger: HardwareTrigger
    let voiceTrigger: VoiceTrigger
    let coordinator: SessionCoordinator
    let pipeline: RecordingPipeline
    let clipStore: ClipStore
    /// Active recording tags and remembered custom tags.
    let tagPreferences: TagPreferences
    let modelContainer: ModelContainer
    /// Kept so config changes can update the eviction policy directly.
    let ringBuffer: SegmentRingBuffer

    /// Mirror of `coordinator.state`, updated from its event stream.
    var sessionState: SessionState = .idle {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = sessionState.isRecording
        }
    }
    /// Latest `PipelineMetrics` from `pipeline.metrics()`.
    var metrics: PipelineMetrics = .zero
    /// Most recently saved clip (restored from the store on launch).
    var lastClip: ClipRecord?
    /// Clip the Library tab should open after leaving Record.
    var pendingLibraryClip: ClipRecord?
    /// Transient, user-facing error text. Views clear it after showing it.
    var errorMessage: String?
    /// Outcome shown in the Record save pill after in-flight saves drain.
    var saveCallout: SaveCallout?
    /// Mirror of `coordinator.selectedClipSeconds` for the UI picker.
    var selectedClipSeconds: TimeInterval
    /// True while the voice trigger is listening for "clip it".
    var isVoiceListening = false

    @ObservationIgnored private var saveBatchSucceeded = false
    @ObservationIgnored private var saveBatchFailed = false
    /// Set once per session so a permission problem is reported once, not on
    /// every state change.
    @ObservationIgnored private var voiceProblemReported = false

    @ObservationIgnored private let backendProxy: BackendProxy
    @ObservationIgnored private var started = false
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init() {
        let settings = SettingsStore()
        let config = settings.config
        self.settings = settings

        permissions = PermissionsManager()

        let modelContainer = Self.makeModelContainer()
        self.modelContainer = modelContainer
        clipStore = ClipStore(container: modelContainer)
        tagPreferences = TagPreferences()

        triggerBus = TriggerBus()
        tapTrigger = TapTrigger()
        hardwareTrigger = HardwareTrigger()
        let voiceTrigger = VoiceTrigger()
        self.voiceTrigger = voiceTrigger

        let frameTap = FrameTap()
        let ringBuffer = SegmentRingBuffer(
            policy: RingBufferPolicy(config: config),
            storage: FileSegmentStorage(rootDirectory: AppDirectories.ring)
        )
        self.ringBuffer = ringBuffer
        let exporter = ClipExporter(clipsDirectory: AppDirectories.clips)
        let source = Self.makeCaptureSource()

        let proxy = BackendProxy()
        backendProxy = proxy
        let coordinator = SessionCoordinator(config: config, backend: proxy)
        self.coordinator = coordinator
        let pipeline = RecordingPipeline(
            source: source,
            config: config,
            ringBuffer: ringBuffer,
            exporter: exporter,
            frameTap: frameTap,
            audioListener: voiceTrigger,
            coordinator: coordinator
        )
        self.pipeline = pipeline
        proxy.target = pipeline

        selectedClipSeconds = config.bufferSeconds
        lastClip = clipStore.newest()?.record

        settings.onChange = { [weak self] config in
            self?.applyConfig(config)
        }
    }

    /// Registers trigger sources, starts the coordinator loop, and mirrors
    /// session events and pipeline metrics into observable state. Idempotent.
    func start() async {
        guard !started else { return }
        started = true

        permissions.refresh()

        do {
            try await triggerBus.register(tapTrigger)
        } catch {
            Log.ui.error("Failed to register TapTrigger: \(String(describing: error))")
        }
        do {
            try await triggerBus.register(hardwareTrigger)
        } catch {
            Log.ui.error("Failed to register HardwareTrigger: \(String(describing: error))")
        }
        do {
            try await triggerBus.register(voiceTrigger)
        } catch {
            Log.ui.error("Failed to register VoiceTrigger: \(String(describing: error))")
        }

        let coordinator = coordinator
        let bus = triggerBus
        let pipeline = pipeline

        tasks.append(Task {
            await coordinator.run(bus: bus)
        })

        tasks.append(Task { @MainActor [weak self] in
            let events = await coordinator.events()
            for await event in events {
                guard let self else { return }
                self.handle(event)
            }
        })

        tasks.append(Task { @MainActor [weak self] in
            for await snapshot in pipeline.metrics() {
                guard let self else { return }
                self.metrics = snapshot
            }
        })

        sessionState = await coordinator.state
        selectedClipSeconds = await coordinator.selectedClipSeconds
        updateVoiceListening()
    }

    // MARK: - Actions

    /// Run the camera so the viewfinder is live before recording starts.
    /// Safe to call repeatedly. Failures surface in `errorMessage`.
    func startPreview() async {
        do {
            try await pipeline.startPreview()
        } catch {
            Log.ui.error("Preview failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Save the last `selectedClipSeconds` seconds. No-op unless recording.
    func saveClipNow() {
        emit(TriggerEvent(source: .ui, kind: .saveClip(seconds: nil)))
    }

    /// Start or stop recording.
    func toggleRecording() {
        emit(TriggerEvent(source: .ui, kind: .toggleRecording))
    }

    /// Stop a live session if needed, then ask the Library tab to play `lastClip`.
    func openLastClipInLibrary() {
        guard let lastClip else { return }
        switch sessionState {
        case .starting, .stopping:
            return
        case .recording, .interrupted:
            pendingLibraryClip = lastClip
            toggleRecording()
        case .idle:
            pendingLibraryClip = lastClip
        }
    }

    /// Change how many seconds a save captures.
    func setClipSeconds(_ seconds: TimeInterval) {
        selectedClipSeconds = seconds
        let coordinator = coordinator
        Task {
            await coordinator.setSelectedClipSeconds(seconds)
        }
    }

    // MARK: - Private

    private func emit(_ event: TriggerEvent) {
        let bus = triggerBus
        Task {
            await bus.emit(event)
        }
    }

    private func handle(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let state):
            if state.isRecording != sessionState.isRecording {
                Haptics.toggled()
            }
            sessionState = state
            updateVoiceListening()
            if Self.pendingSaves(in: state) > 0 {
                saveCallout = nil
            }
            publishSaveCalloutIfIdle()

        case .clipSaved(let pipelineRecord):
            saveBatchSucceeded = true
            // Stamp whatever is active on the Record screen at the moment the
            // save lands. The pipeline knows nothing about tags.
            let record = pipelineRecord.with(tags: tagPreferences.activeTags)
            do {
                try clipStore.insert(record)
            } catch {
                Log.ui.error("Clip saved but could not be indexed: \(String(describing: error))")
                errorMessage = "Clip saved, but the library could not be updated."
            }
            lastClip = record
            Haptics.saved()
            publishSaveCalloutIfIdle()

        case .saveFailed(let reason):
            saveBatchFailed = true
            errorMessage = "Save failed: \(reason)"
            Haptics.error()
            publishSaveCalloutIfIdle()

        case .startFailed(let reason):
            errorMessage = "Couldn't start recording: \(reason)"
            Haptics.error()

        case .inactivityTimeoutFired:
            errorMessage = "Recording stopped after a period of inactivity."

        case .inactivityWarning(let secondsRemaining):
            let minutes = max(1, Int((secondsRemaining / 60).rounded()))
            errorMessage = "Recording stops in \(minutes) min unless you save a clip."
        }
    }

    private func publishSaveCalloutIfIdle() {
        guard Self.pendingSaves(in: sessionState) == 0,
              saveBatchSucceeded || saveBatchFailed else { return }
        saveCallout = saveBatchFailed ? .failed : .saved
        saveBatchSucceeded = false
        saveBatchFailed = false
    }

    private static func pendingSaves(in state: SessionState) -> Int {
        if case .recording(let pending) = state { return pending }
        return 0
    }

    /// Listen exactly while a session is live and the voice trigger is on.
    /// `.interrupted` counts as live: audio simply stops arriving until the
    /// capture resumes, and the request restarts on its own if it errors.
    private func updateVoiceListening() {
        let shouldListen = sessionState.isRecording && settings.config.voiceTriggerEnabled
        if !sessionState.isRecording {
            voiceProblemReported = false
        }
        guard shouldListen else {
            voiceTrigger.endListening()
            isVoiceListening = false
            return
        }
        // Pending-save changes also arrive here; nothing to do once listening.
        if isVoiceListening { return }
        if let problem = VoiceTrigger.availabilityProblem() {
            voiceTrigger.endListening()
            isVoiceListening = false
            if !voiceProblemReported {
                voiceProblemReported = true
                Log.voice.notice("Voice trigger unavailable: \(problem, privacy: .public)")
                errorMessage = problem
            }
            return
        }
        voiceTrigger.beginListening()
        isVoiceListening = true
    }

    private func applyConfig(_ config: RecordingConfig) {
        if selectedClipSeconds > config.bufferSeconds {
            setClipSeconds(config.bufferSeconds)
        }
        updateVoiceListening()
        let ringBuffer = ringBuffer
        let pipeline = pipeline
        let coordinator = coordinator
        Task {
            await ringBuffer.updatePolicy(RingBufferPolicy(config: config))
            await pipeline.updateConfig(config)
            await coordinator.updateConfig(config)
        }
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema([Clip.self])
        do {
            return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema)])
        } catch {
            // A failed schema migration lands here and would show an empty
            // library. Fault-level so it is not mistaken for a fresh install.
            Log.ui.fault("Persistent ModelContainer failed; falling back to in-memory: \(String(describing: error), privacy: .public)")
            do {
                return try ModelContainer(
                    for: schema,
                    configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
                )
            } catch {
                fatalError("Unable to create an in-memory ModelContainer: \(error)")
            }
        }
    }

    private static func makeCaptureSource() -> any CaptureSource {
        #if targetEnvironment(simulator)
        if let url = Bundle.main.url(forResource: "replay", withExtension: "mov") {
            return FileReplayCaptureSource(fileURL: url)
        }
        Log.capture.warning(
            "No replay.mov in the app bundle. Drop a landscape .mov named replay.mov into HighlightBot/Resources/ and re-run xcodegen to exercise the pipeline in the Simulator."
        )
        return FileReplayCaptureSource(fileURL: AppDirectories.ring.appending(path: "missing-replay.mov"))
        #else
        return CaptureEngine()
        #endif
    }
}
