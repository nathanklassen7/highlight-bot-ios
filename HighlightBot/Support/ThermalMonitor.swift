import Foundation

/// Publishes `ProcessInfo.thermalState` as an async stream. Each call to
/// `states()` returns an independent stream that yields the current state
/// immediately, then every change until the consumer stops iterating.
final class ThermalMonitor: Sendable {
    init() {}

    func states() -> AsyncStream<ProcessInfo.ThermalState> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(ProcessInfo.processInfo.thermalState)

            let task = Task {
                let notifications = NotificationCenter.default.notifications(
                    named: ProcessInfo.thermalStateDidChangeNotification
                )
                // Only the fact that a change happened matters; the state is re-read
                // from ProcessInfo so nothing non-Sendable leaves this task.
                for await _ in notifications {
                    if Task.isCancelled { break }
                    continuation.yield(ProcessInfo.processInfo.thermalState)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
