import Foundation

/// Fan-in of trigger sources and fan-out to subscribers.
///
/// Registered sources push events through a per-source inbox so that events
/// from one source are delivered in the order they were emitted. Every
/// `subscribe()` call gets its own stream that receives all future events.
public actor TriggerBus {
    private struct Registration {
        let source: any TriggerSource
        let inbox: AsyncStream<TriggerEvent>.Continuation
        let forwarder: Task<Void, Never>
    }

    private var registrations: [TriggerSourceID: Registration] = [:]
    private var subscribers: [UUID: AsyncStream<TriggerEvent>.Continuation] = [:]

    public init() {}

    /// Identifiers of the sources currently registered.
    public var registeredSourceIDs: Set<TriggerSourceID> {
        Set(registrations.keys)
    }

    /// Number of live subscriber streams.
    public var subscriberCount: Int {
        subscribers.count
    }

    /// Starts `source` and forwards everything it emits to subscribers.
    /// Registering a second source with the same id stops and replaces the first.
    public func register(_ source: any TriggerSource) async throws {
        if let existing = registrations.removeValue(forKey: source.id) {
            await tearDown(existing)
        }

        let (stream, continuation) = AsyncStream<TriggerEvent>.makeStream(bufferingPolicy: .unbounded)
        let forwarder = Task {
            for await event in stream {
                self.emit(event)
            }
        }
        registrations[source.id] = Registration(source: source, inbox: continuation, forwarder: forwarder)

        do {
            try await source.start { event in
                continuation.yield(event)
            }
        } catch {
            if let registration = registrations.removeValue(forKey: source.id) {
                registration.inbox.finish()
                registration.forwarder.cancel()
            }
            throw error
        }
    }

    /// Stops and removes the source with `id`. No-op if it is not registered.
    public func unregister(_ id: TriggerSourceID) async {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        await tearDown(registration)
    }

    /// Stops and removes every registered source.
    public func stopAll() async {
        let all = registrations
        registrations.removeAll()
        for registration in all.values {
            await tearDown(registration)
        }
    }

    /// Inject an event directly (used by UI buttons and tests).
    public func emit(_ event: TriggerEvent) {
        for continuation in subscribers.values {
            continuation.yield(event)
        }
    }

    /// Each call returns an independent stream that receives all future events.
    /// The subscription ends when the stream is cancelled or dropped.
    public func subscribe() -> AsyncStream<TriggerEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<TriggerEvent>.makeStream(bufferingPolicy: .unbounded)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeSubscriber(id) }
        }
        return stream
    }

    // MARK: - Private

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func tearDown(_ registration: Registration) async {
        await registration.source.stop()
        registration.inbox.finish()
        registration.forwarder.cancel()
    }
}
