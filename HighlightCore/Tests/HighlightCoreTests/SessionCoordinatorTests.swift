import Foundation
import Testing
@testable import HighlightCore

@Suite("SessionCoordinator")
struct SessionCoordinatorTests {
    private struct Harness {
        let backend: MockRecordingBackend
        let coordinator: SessionCoordinator
        let events: EventRecorder<SessionEvent>
    }

    private func makeHarness(
        config: RecordingConfig = .default,
        warningLeadTime: TimeInterval = 300,
        saveCooldown: TimeInterval = SessionCoordinator.saveCooldownSeconds
    ) async -> Harness {
        let backend = MockRecordingBackend()
        let coordinator = SessionCoordinator(
            config: config,
            backend: backend,
            warningLeadTime: warningLeadTime,
            saveCooldown: saveCooldown
        )
        let events = await EventRecorder.recording(coordinator.events())
        return Harness(backend: backend, coordinator: coordinator, events: events)
    }

    private func stateChanges(_ events: [SessionEvent]) -> [SessionState] {
        events.compactMap {
            if case .stateChanged(let state) = $0 { return state }
            return nil
        }
    }

    // MARK: Start / stop

    @Test("idle → starting → recording on startRecording")
    func idleToRecording() async {
        let h = await makeHarness()
        #expect(await h.coordinator.state == .idle)
        #expect(await h.coordinator.selectedClipSeconds == 20)

        await h.coordinator.handle(.start)

        #expect(await h.coordinator.state == .recording(pendingSaves: 0))
        #expect(await h.backend.calls == [.startRecording])
        let events = await h.events.waitForCount(2)
        #expect(stateChanges(events) == [.starting, .recording(pendingSaves: 0)])
    }

    @Test("startRecording failure → idle + startFailed")
    func startFailure() async {
        let h = await makeHarness()
        await h.backend.setStartError(MockBackendError(message: "camera busy"))

        await h.coordinator.handle(.start)

        #expect(await h.coordinator.state == .idle)
        let events = await h.events.waitForCount(3)
        #expect(events == [.stateChanged(.starting), .stateChanged(.idle), .startFailed(reason: "camera busy")])
    }

    @Test("stopRecording → stopping → idle")
    func stopToIdle() async {
        let h = await makeHarness()
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.stop)

        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls == [.startRecording, .stopRecording])
        let events = await h.events.waitForCount(4)
        #expect(stateChanges(events) == [.starting, .recording(pendingSaves: 0), .stopping, .idle])
    }

    @Test("toggle starts when idle and stops when recording")
    func toggle() async {
        let h = await makeHarness()
        await h.coordinator.handle(.toggle)
        #expect(await h.coordinator.state == .recording(pendingSaves: 0))
        await h.coordinator.handle(.toggle)
        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls == [.startRecording, .stopRecording])
    }

    @Test("saveClip and stopRecording are ignored while idle")
    func ignoredWhileIdle() async {
        let h = await makeHarness()
        await h.coordinator.handle(.save())
        await h.coordinator.handle(.stop)
        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls.isEmpty)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await h.events.events.isEmpty)
    }

    @Test("startRecording is ignored while already recording")
    func startWhileRecording() async {
        let h = await makeHarness()
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.start)
        #expect(await h.backend.count(of: .startRecording) == 1)
    }

    // MARK: Saving

    @Test("save increments then decrements pendingSaves and emits clipSaved")
    func saveFlow() async {
        let h = await makeHarness(saveCooldown: 0)
        await h.backend.setHoldSaves(true)
        await h.coordinator.handle(.start)

        await h.coordinator.handle(.save(source: .tap))
        #expect(await h.coordinator.state == .recording(pendingSaves: 1))
        #expect(await eventually { await h.backend.heldSaveCount == 1 })
        #expect(await h.backend.saveCalls == [.saveClip(lastSeconds: 20, source: .tap)])

        await h.coordinator.handle(.save(10, source: .hardwareButton))
        #expect(await h.coordinator.state == .recording(pendingSaves: 2))
        #expect(await eventually { await h.backend.heldSaveCount == 2 })

        await h.backend.releaseSaves()

        let events = await h.events.waitUntil { events in
            events.filter { if case .clipSaved = $0 { return true } else { return false } }.count == 2
        }
        let saved = events.compactMap { event -> ClipRecord? in
            if case .clipSaved(let record) = event { return record }
            return nil
        }
        #expect(saved.count == 2)
        #expect(Set(saved.map(\.triggerSource)) == [.tap, .hardwareButton])
        #expect(saved.contains { $0.duration == 10 })
        #expect(await eventually { await h.coordinator.state == .recording(pendingSaves: 0) })
        #expect(stateChanges(await h.events.events).last == .recording(pendingSaves: 0))
        #expect(await h.backend.count(of: .stopRecording) == 0)
    }

    @Test("save with explicit seconds overrides selectedClipSeconds")
    func saveSecondsOverride() async {
        let h = await makeHarness(saveCooldown: 0)
        await h.coordinator.setSelectedClipSeconds(30)
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.save())
        await h.coordinator.handle(.save(60))

        #expect(await eventually { await h.backend.saveCalls.count == 2 })
        #expect(await h.backend.saveCalls == [
            .saveClip(lastSeconds: 30, source: .tap),
            .saveClip(lastSeconds: 60, source: .tap),
        ])
    }

    @Test("save failure emits saveFailed and keeps recording")
    func saveFailure() async {
        let h = await makeHarness()
        await h.backend.setSaveError(MockBackendError(message: "export failed"))
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.save())

        let events = await h.events.waitUntil { $0.contains(.saveFailed(reason: "export failed")) }
        #expect(events.contains(.saveFailed(reason: "export failed")))
        #expect(await eventually { await h.coordinator.state == .recording(pendingSaves: 0) })
        #expect(await h.backend.count(of: .stopRecording) == 0)
    }

    @Test("saveClip is ignored for saveCooldown after an accepted save")
    func saveCooldownIgnoresRapidSaves() async {
        let h = await makeHarness(saveCooldown: 0.08)
        await h.backend.setHoldSaves(true)
        await h.coordinator.handle(.start)

        await h.coordinator.handle(.save())
        await h.coordinator.handle(.save(10, source: .hardwareButton))
        #expect(await h.coordinator.state == .recording(pendingSaves: 1))
        #expect(await eventually { await h.backend.saveCalls == [.saveClip(lastSeconds: 20, source: .tap)] })

        await h.backend.releaseSaves()
        try? await Task.sleep(for: .milliseconds(100))
        await h.coordinator.handle(.save(10, source: .hardwareButton))
        #expect(await eventually { await h.backend.saveCalls.count == 2 })
        #expect(await h.backend.saveCalls == [
            .saveClip(lastSeconds: 20, source: .tap),
            .saveClip(lastSeconds: 10, source: .hardwareButton),
        ])
    }

    @Test("default saveCooldown is 4 seconds")
    func defaultSaveCooldown() {
        #expect(SessionCoordinator.saveCooldownSeconds == 4)
    }

    @Test("stop while a save is pending goes idle and the save still completes")
    func stopWithPendingSave() async {
        let h = await makeHarness()
        await h.backend.setHoldSaves(true)
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.save())
        #expect(await eventually { await h.backend.heldSaveCount == 1 })

        await h.coordinator.handle(.stop)
        #expect(await h.coordinator.state == .idle)
        #expect(await h.coordinator.pendingSaveCount == 1)

        await h.backend.releaseSaves()
        let events = await h.events.waitUntil { events in
            events.contains { if case .clipSaved = $0 { return true } else { return false } }
        }
        #expect(events.contains { if case .clipSaved = $0 { return true } else { return false } })
        #expect(await h.coordinator.state == .idle)
        #expect(await h.coordinator.pendingSaveCount == 0)
    }

    // MARK: Interruption

    @Test("interrupted → resume calls restartSession and keeps pendingSaves")
    func interruptAndResume() async {
        let h = await makeHarness()
        await h.backend.setHoldSaves(true)
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.save())
        #expect(await h.coordinator.state == .recording(pendingSaves: 1))

        await h.coordinator.captureDidInterrupt()
        #expect(await h.coordinator.state == .interrupted)
        #expect(await h.coordinator.state.isRecording)

        await h.coordinator.captureDidResume()
        #expect(await h.coordinator.state == .recording(pendingSaves: 1))
        #expect(await h.backend.count(of: .restartSession) == 1)

        await h.backend.releaseSaves()
        #expect(await eventually { await h.coordinator.state == .recording(pendingSaves: 0) })
    }

    @Test("saveClip while interrupted emits saveFailed")
    func saveWhileInterrupted() async {
        let h = await makeHarness()
        await h.coordinator.handle(.start)
        await h.coordinator.captureDidInterrupt()
        await h.coordinator.handle(.save())

        let events = await h.events.waitUntil { $0.contains(.saveFailed(reason: "capture interrupted")) }
        #expect(events.contains(.saveFailed(reason: "capture interrupted")))
        #expect(await h.backend.saveCalls.isEmpty)
        #expect(await h.coordinator.state == .interrupted)
    }

    @Test("stop while interrupted → idle")
    func stopWhileInterrupted() async {
        let h = await makeHarness()
        await h.coordinator.handle(.start)
        await h.coordinator.captureDidInterrupt()
        await h.coordinator.handle(.toggle)
        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls == [.startRecording, .stopRecording])
    }

    @Test("interrupt and resume are ignored outside their states")
    func interruptResumeIgnored() async {
        let h = await makeHarness()
        await h.coordinator.captureDidInterrupt()
        #expect(await h.coordinator.state == .idle)
        await h.coordinator.captureDidResume()
        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls.isEmpty)
    }

    @Test("restartSession failure behaves like captureDidFail")
    func resumeFailure() async {
        let h = await makeHarness()
        await h.backend.setRestartError(MockBackendError(message: "writer refused"))
        await h.coordinator.handle(.start)
        await h.coordinator.captureDidInterrupt()
        await h.coordinator.captureDidResume()

        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls == [.startRecording, .restartSession, .stopRecording])
        let events = await h.events.waitUntil { $0.contains(.startFailed(reason: "writer refused")) }
        #expect(events.contains(.startFailed(reason: "writer refused")))
    }

    // MARK: Failure

    @Test("captureDidFail → idle + startFailed from recording")
    func captureFailWhileRecording() async {
        let h = await makeHarness()
        await h.coordinator.handle(.start)
        await h.coordinator.captureDidFail(reason: "device disconnected")

        #expect(await h.coordinator.state == .idle)
        #expect(await h.backend.calls == [.startRecording, .stopRecording])
        let events = await h.events.waitUntil { $0.contains(.startFailed(reason: "device disconnected")) }
        #expect(stateChanges(events) == [.starting, .recording(pendingSaves: 0), .stopping, .idle])
        #expect(events.last == .startFailed(reason: "device disconnected"))
    }

    @Test("captureDidFail while starting wins over the start result")
    func captureFailWhileStarting() async {
        let h = await makeHarness()
        await h.backend.setStartDelay(.milliseconds(100))

        let start = Task { await h.coordinator.handle(.start) }
        #expect(await eventually { await h.coordinator.state == .starting })
        await h.coordinator.captureDidFail(reason: "boom")
        await start.value

        #expect(await h.coordinator.state == .idle)
        let states = stateChanges(await h.events.events)
        #expect(!states.contains(.recording(pendingSaves: 0)))
    }

    // MARK: Inactivity

    @Test("inactivity timeout fires and stops recording")
    func inactivityTimeout() async {
        var config = RecordingConfig.default
        config.inactivityTimeout = 0.05
        let h = await makeHarness(config: config)

        await h.coordinator.handle(.start)
        let events = await h.events.waitUntil { $0.contains(.inactivityTimeoutFired) }
        #expect(events.contains(.inactivityTimeoutFired))
        #expect(!events.contains { if case .inactivityWarning = $0 { return true } else { return false } })
        #expect(await eventually { await h.coordinator.state == .idle })
        #expect(await h.backend.calls == [.startRecording, .stopRecording])

        let fired = await h.events.events.firstIndex(of: .inactivityTimeoutFired)!
        let stopping = await h.events.events.firstIndex(of: .stateChanged(.stopping))!
        #expect(fired < stopping)
    }

    @Test("inactivity warning fires once before the timeout")
    func inactivityWarning() async {
        var config = RecordingConfig.default
        config.inactivityTimeout = 0.12
        let h = await makeHarness(config: config, warningLeadTime: 0.06)

        await h.coordinator.handle(.start)
        let events = await h.events.waitUntil { $0.contains(.inactivityTimeoutFired) }
        let warnings = events.filter { $0 == .inactivityWarning(secondsRemaining: 0.06) }
        #expect(warnings.count == 1)
        let warningIndex = events.firstIndex(of: .inactivityWarning(secondsRemaining: 0.06))!
        let firedIndex = events.firstIndex(of: .inactivityTimeoutFired)!
        #expect(warningIndex < firedIndex)
        #expect(await eventually { await h.coordinator.state == .idle })
    }

    @Test("save trigger resets the inactivity timer")
    func saveResetsTimer() async {
        var config = RecordingConfig.default
        config.inactivityTimeout = 0.15
        let h = await makeHarness(config: config, saveCooldown: 0)

        await h.coordinator.handle(.start)
        // Keep poking well inside the timeout; recording must survive.
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(60))
            await h.coordinator.handle(.save())
        }
        #expect(await h.coordinator.state.isRecording)
        #expect(!(await h.events.events.contains(.inactivityTimeoutFired)))

        // Now go quiet and let it fire.
        let events = await h.events.waitUntil(timeout: .seconds(2)) { $0.contains(.inactivityTimeoutFired) }
        #expect(events.contains(.inactivityTimeoutFired))
    }

    @Test("stopping cancels the inactivity timer")
    func stopCancelsTimer() async {
        var config = RecordingConfig.default
        config.inactivityTimeout = 0.05
        let h = await makeHarness(config: config)

        await h.coordinator.handle(.start)
        await h.coordinator.handle(.stop)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(!(await h.events.events.contains(.inactivityTimeoutFired)))
        #expect(await h.backend.count(of: .stopRecording) == 1)
    }

    // MARK: Config / bus

    @Test("updateConfig follows bufferSeconds when selection was the default")
    func updateConfig() async {
        let h = await makeHarness()
        var config = RecordingConfig.default
        config.bufferSeconds = 30
        await h.coordinator.updateConfig(config)
        #expect(await h.coordinator.selectedClipSeconds == 30)

        await h.coordinator.setSelectedClipSeconds(10)
        config.bufferSeconds = 60
        await h.coordinator.updateConfig(config)
        #expect(await h.coordinator.selectedClipSeconds == 10)
    }

    @Test("run(bus:) consumes triggers until cancelled")
    func runWithBus() async {
        let h = await makeHarness()
        let bus = TriggerBus()
        let runner = Task { await h.coordinator.run(bus: bus) }
        #expect(await eventually { await bus.subscriberCount == 1 })

        await bus.emit(.start)
        #expect(await eventually { await h.coordinator.state == .recording(pendingSaves: 0) })

        await bus.emit(.save(15, source: .hardwareButton))
        #expect(await eventually { await h.backend.saveCalls == [.saveClip(lastSeconds: 15, source: .hardwareButton)] })

        await bus.emit(.toggle)
        #expect(await eventually { await h.coordinator.state == .idle })

        runner.cancel()
        await runner.value
        #expect(await eventually { await bus.subscriberCount == 0 })
    }

    @Test("multiple event subscribers each receive every event")
    func multipleEventSubscribers() async {
        let h = await makeHarness()
        let second = await EventRecorder.recording(h.coordinator.events())
        await h.coordinator.handle(.start)
        await h.coordinator.handle(.stop)

        let first = await h.events.waitForCount(4)
        let other = await second.waitForCount(4)
        #expect(first == other)
        #expect(stateChanges(first) == [.starting, .recording(pendingSaves: 0), .stopping, .idle])
    }

    @Test("SessionState.isRecording")
    func isRecording() {
        #expect(SessionState.recording(pendingSaves: 0).isRecording)
        #expect(SessionState.recording(pendingSaves: 3).isRecording)
        #expect(SessionState.interrupted.isRecording)
        #expect(!SessionState.idle.isRecording)
        #expect(!SessionState.starting.isRecording)
        #expect(!SessionState.stopping.isRecording)
    }
}
