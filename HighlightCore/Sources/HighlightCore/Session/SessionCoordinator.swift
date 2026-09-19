import Foundation

/// The recording state machine, ported from the Raspberry Pi
/// `state_machine.py` with one simplification: saving is a task, not a state,
/// so recording never pauses while a clip is exported.
///
/// State table (see `docs/api-contracts.md`):
///
/// | State       | Trigger                        | Result |
/// | ----------- | ------------------------------ | ------ |
/// | idle        | startRecording / toggle        | starting → `backend.startRecording()` → recording(0); on throw → idle + `startFailed` |
/// | idle        | saveClip                       | ignored |
/// | recording   | saveClip(s)                    | pendingSaves += 1; task: `backend.saveClip` → `clipSaved` / `saveFailed`; pendingSaves -= 1; resets inactivity timer |
/// | recording   | stopRecording / toggle         | stopping → `backend.stopRecording()` → idle; pending saves finish independently |
/// | recording   | inactivity timeout             | `inactivityTimeoutFired`, then as stopRecording |
/// | recording   | captureDidInterrupt            | interrupted |
/// | interrupted | captureDidResume               | `backend.restartSession()` → recording(pendingSaves) |
/// | interrupted | stopRecording / toggle         | stopping → idle |
/// | interrupted | saveClip                       | `saveFailed("capture interrupted")` |
/// | any         | captureDidFail                 | `backend.stopRecording()`; idle; `startFailed(reason)` |
///
/// The inactivity timer starts when recording begins, restarts on every save
/// trigger, keeps running through `.interrupted`, and is cancelled when the
/// session leaves `isRecording`. It emits `inactivityWarning` once at
/// `timeout - warningLeadTime` (only if `timeout > warningLeadTime`) and then
/// `inactivityTimeoutFired` at `timeout`.
public actor SessionCoordinator {
    public private(set) var state: SessionState = .idle
    /// Seconds saved by a `saveClip(seconds: nil)` trigger. Defaults to `config.bufferSeconds`.
    public private(set) var selectedClipSeconds: TimeInterval
    /// Number of `backend.saveClip` calls still in flight. Mirrors the count in
    /// `.recording(pendingSaves:)` but stays meaningful in other states.
    public private(set) var pendingSaveCount = 0

    private var config: RecordingConfig
    private let backend: any RecordingBackend
    private let clock: any Clock<Duration>
    private let warningLeadTime: TimeInterval

    private var subscribers: [UUID: AsyncStream<SessionEvent>.Continuation] = [:]
    private var inactivityTask: Task<Void, Never>?
    private var inactivityGeneration = 0

    /// - Parameters:
    ///   - config: Recording settings; `bufferSeconds` and `inactivityTimeout` are used here.
    ///   - backend: Performs the actual side effects.
    ///   - clock: Drives the inactivity timer. Inject a test clock to control time.
    ///   - warningLeadTime: How long before the timeout `inactivityWarning` fires. Default 5 minutes.
    public init(
        config: RecordingConfig,
        backend: any RecordingBackend,
        clock: any Clock<Duration> = ContinuousClock(),
        warningLeadTime: TimeInterval = 300
    ) {
        self.config = config
        self.backend = backend
        self.clock = clock
        self.warningLeadTime = warningLeadTime
        self.selectedClipSeconds = config.bufferSeconds
    }

    /// Changes how many seconds a `saveClip(seconds: nil)` trigger saves.
    public func setSelectedClipSeconds(_ seconds: TimeInterval) {
        selectedClipSeconds = seconds
    }

    /// Replaces the configuration. If `selectedClipSeconds` was tracking the
    /// old `bufferSeconds` it follows the new value. A running inactivity
    /// timer restarts with the new timeout.
    public func updateConfig(_ config: RecordingConfig) {
        let previous = self.config
        self.config = config
        if selectedClipSeconds == previous.bufferSeconds {
            selectedClipSeconds = config.bufferSeconds
        }
        if state.isRecording {
            restartInactivityTimer()
        }
    }

    /// Independent stream of events for each subscriber. Ends when cancelled or dropped.
    public func events() -> AsyncStream<SessionEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id) }
        }
        return stream
    }

    /// Consume triggers from a bus until cancelled.
    public func run(bus: TriggerBus) async {
        let stream = await bus.subscribe()
        for await event in stream {
            await handle(event)
        }
    }

    /// Handle a single trigger (used by `run` and by tests).
    public func handle(_ event: TriggerEvent) async {
        switch (state, event.kind) {
        case (.idle, .startRecording), (.idle, .toggleRecording):
            await startRecording()

        case (.idle, .saveClip), (.idle, .stopRecording):
            break

        case (.recording, .saveClip(let seconds)):
            beginSave(lastSeconds: seconds ?? selectedClipSeconds, source: event.source)

        case (.recording, .stopRecording), (.recording, .toggleRecording):
            await stopRecording()

        case (.recording, .startRecording):
            break

        case (.interrupted, .saveClip):
            emit(.saveFailed(reason: "capture interrupted"))

        case (.interrupted, .stopRecording), (.interrupted, .toggleRecording):
            await stopRecording()

        case (.interrupted, .startRecording):
            break

        case (.starting, _), (.stopping, _):
            break
        }
    }

    // MARK: - Capture-side notifications

    /// The capture source was interrupted (phone call, background).
    public func captureDidInterrupt() async {
        guard case .recording = state else { return }
        setState(.interrupted)
    }

    /// The capture source resumed; the backend starts a new session.
    /// If `restartSession()` throws this behaves like `captureDidFail`.
    public func captureDidResume() async {
        guard state == .interrupted else { return }
        do {
            try await backend.restartSession()
            guard state == .interrupted else { return }
            setState(.recording(pendingSaves: pendingSaveCount))
        } catch {
            await captureDidFail(reason: describe(error))
        }
    }

    /// The capture source failed unrecoverably. Stops the backend from any state.
    public func captureDidFail(reason: String) async {
        cancelInactivityTimer()
        setState(.stopping)
        await backend.stopRecording()
        setState(.idle)
        emit(.startFailed(reason: reason))
    }

    // MARK: - Transitions

    private func startRecording() async {
        setState(.starting)
        do {
            try await backend.startRecording()
            // captureDidFail may have moved us to idle while we were awaiting.
            guard state == .starting else { return }
            setState(.recording(pendingSaves: pendingSaveCount))
            restartInactivityTimer()
        } catch {
            guard state == .starting else { return }
            setState(.idle)
            emit(.startFailed(reason: describe(error)))
        }
    }

    private func stopRecording() async {
        cancelInactivityTimer()
        setState(.stopping)
        await backend.stopRecording()
        guard state == .stopping else { return }
        setState(.idle)
    }

    private func beginSave(lastSeconds: TimeInterval, source: TriggerSourceID) {
        pendingSaveCount += 1
        setState(.recording(pendingSaves: pendingSaveCount))
        restartInactivityTimer()

        let backend = self.backend
        Task {
            let outcome: Result<ClipRecord, any Error>
            do {
                outcome = .success(try await backend.saveClip(lastSeconds: lastSeconds, source: source))
            } catch {
                outcome = .failure(error)
            }
            self.saveDidFinish(outcome)
        }
    }

    private func saveDidFinish(_ outcome: Result<ClipRecord, any Error>) {
        pendingSaveCount = max(0, pendingSaveCount - 1)
        switch outcome {
        case .success(let record):
            emit(.clipSaved(record))
        case .failure(let error):
            emit(.saveFailed(reason: describe(error)))
        }
        if case .recording = state {
            setState(.recording(pendingSaves: pendingSaveCount))
        }
    }

    // MARK: - Inactivity timer

    private func restartInactivityTimer() {
        cancelInactivityTimer()
        let timeout = config.inactivityTimeout
        guard timeout > 0, timeout.isFinite else { return }

        inactivityGeneration += 1
        let generation = inactivityGeneration
        let lead = warningLeadTime
        let clock = self.clock

        inactivityTask = Task {
            do {
                if lead > 0, timeout > lead {
                    try await clock.sleep(for: .seconds(timeout - lead))
                    guard self.inactivityGeneration == generation else { return }
                    self.emit(.inactivityWarning(secondsRemaining: lead))
                    try await clock.sleep(for: .seconds(lead))
                } else {
                    try await clock.sleep(for: .seconds(timeout))
                }
            } catch {
                return // cancelled
            }
            guard self.inactivityGeneration == generation else { return }
            await self.inactivityTimeoutElapsed()
        }
    }

    private func cancelInactivityTimer() {
        inactivityGeneration += 1
        inactivityTask?.cancel()
        inactivityTask = nil
    }

    private func inactivityTimeoutElapsed() async {
        guard state.isRecording else { return }
        emit(.inactivityTimeoutFired)
        await stopRecording()
    }

    // MARK: - Events

    private func setState(_ newState: SessionState) {
        guard newState != state else { return }
        state = newState
        emit(.stateChanged(newState))
    }

    private func emit(_ event: SessionEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
