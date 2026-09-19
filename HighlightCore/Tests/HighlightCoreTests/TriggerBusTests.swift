import Foundation
import Testing
@testable import HighlightCore

/// A trigger source tests can fire manually.
final class FakeTriggerSource: TriggerSource, @unchecked Sendable {
    // @unchecked: `emitter` and the flags are only mutated inside `lock`.
    let id: TriggerSourceID
    private let lock = NSLock()
    private var emitter: (@Sendable (TriggerEvent) -> Void)?
    private var _startCount = 0
    private var _stopCount = 0
    let startError: (any Error)?

    init(id: TriggerSourceID, startError: (any Error)? = nil) {
        self.id = id
        self.startError = startError
    }

    var startCount: Int { lock.withLock { _startCount } }
    var stopCount: Int { lock.withLock { _stopCount } }

    func start(emit: @escaping @Sendable (TriggerEvent) -> Void) async throws {
        lock.withLock {
            _startCount += 1
            emitter = emit
        }
        if let startError { throw startError }
    }

    func stop() async {
        lock.withLock {
            _stopCount += 1
            emitter = nil
        }
    }

    func fire(_ kind: TriggerKind) {
        let emitter = lock.withLock { self.emitter }
        emitter?(TriggerEvent(source: id, kind: kind))
    }
}

@Suite("TriggerBus")
struct TriggerBusTests {
    @Test("multiple subscribers each receive every event")
    func fanOut() async {
        let bus = TriggerBus()
        let first = await EventRecorder.recording(bus.subscribe())
        let second = await EventRecorder.recording(bus.subscribe())
        #expect(await bus.subscriberCount == 2)

        let events = [
            TriggerEvent(source: .ui, kind: .startRecording),
            TriggerEvent(source: .tap, kind: .saveClip(seconds: nil)),
            TriggerEvent(source: .hardwareButton, kind: .saveClip(seconds: 10)),
        ]
        for event in events {
            await bus.emit(event)
        }

        #expect(await first.waitForCount(3) == events)
        #expect(await second.waitForCount(3) == events)
    }

    @Test("late subscribers only see future events")
    func lateSubscriber() async {
        let bus = TriggerBus()
        let early = await EventRecorder.recording(bus.subscribe())
        await bus.emit(TriggerEvent(source: .ui, kind: .startRecording))
        await early.waitForCount(1)

        let late = await EventRecorder.recording(bus.subscribe())
        let second = TriggerEvent(source: .ui, kind: .stopRecording)
        await bus.emit(second)

        #expect(await late.waitForCount(1) == [second])
        #expect(await early.waitForCount(2).count == 2)
    }

    @Test("registered source emits flow through in order")
    func registeredSource() async throws {
        let bus = TriggerBus()
        let recorder = await EventRecorder.recording(bus.subscribe())
        let source = FakeTriggerSource(id: .hardwareButton)

        try await bus.register(source)
        #expect(source.startCount == 1)
        #expect(await bus.registeredSourceIDs == [.hardwareButton])

        source.fire(.saveClip(seconds: nil))
        source.fire(.toggleRecording)
        source.fire(.saveClip(seconds: 30))

        let received = await recorder.waitForCount(3)
        #expect(received.map(\.kind) == [.saveClip(seconds: nil), .toggleRecording, .saveClip(seconds: 30)])
        #expect(received.allSatisfy { $0.source == .hardwareButton })
    }

    @Test("unregister stops the source and drops later events")
    func unregister() async throws {
        let bus = TriggerBus()
        let recorder = await EventRecorder.recording(bus.subscribe())
        let source = FakeTriggerSource(id: .tap)
        try await bus.register(source)

        source.fire(.saveClip(seconds: nil))
        await recorder.waitForCount(1)

        await bus.unregister(.tap)
        #expect(source.stopCount == 1)
        #expect(await bus.registeredSourceIDs.isEmpty)

        // The fake dropped its emitter on stop, so this is a no-op.
        source.fire(.saveClip(seconds: nil))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await recorder.events.count == 1)

        await bus.unregister(.tap) // no-op
    }

    @Test("stopAll stops every source")
    func stopAll() async throws {
        let bus = TriggerBus()
        let tap = FakeTriggerSource(id: .tap)
        let hardware = FakeTriggerSource(id: .hardwareButton)
        try await bus.register(tap)
        try await bus.register(hardware)

        await bus.stopAll()
        #expect(tap.stopCount == 1)
        #expect(hardware.stopCount == 1)
        #expect(await bus.registeredSourceIDs.isEmpty)
    }

    @Test("re-registering the same id replaces the previous source")
    func replaceSource() async throws {
        let bus = TriggerBus()
        let first = FakeTriggerSource(id: .voice)
        let second = FakeTriggerSource(id: .voice)
        try await bus.register(first)
        try await bus.register(second)

        #expect(first.stopCount == 1)
        #expect(second.startCount == 1)
        #expect(await bus.registeredSourceIDs == [.voice])
    }

    @Test("a source that fails to start is not registered")
    func startFailure() async {
        let bus = TriggerBus()
        let source = FakeTriggerSource(id: .vision, startError: MockBackendError(message: "no camera"))

        await #expect(throws: MockBackendError(message: "no camera")) {
            try await bus.register(source)
        }
        #expect(await bus.registeredSourceIDs.isEmpty)
    }

    @Test("cancelled subscriber is removed")
    func subscriberRemovedOnCancel() async {
        let bus = TriggerBus()
        let recorder = await EventRecorder.recording(bus.subscribe())
        #expect(await bus.subscriberCount == 1)

        await recorder.stop()
        let removed = await eventually { await bus.subscriberCount == 0 }
        #expect(removed)
    }
}
