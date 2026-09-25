import Foundation

/// Publishes `ProcessInfo.isLowPowerModeEnabled` as an async stream. Each call
/// to `states()` returns an independent stream that yields the current value
/// immediately, then every change until the consumer stops iterating.
final class PowerModeMonitor: Sendable {
    init() {}

    func states() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.yield(ProcessInfo.processInfo.isLowPowerModeEnabled)

            let task = Task {
                let notifications = NotificationCenter.default.notifications(
                    named: .NSProcessInfoPowerStateDidChange
                )
                // Only the fact that a change happened matters; the value is re-read
                // from ProcessInfo so nothing non-Sendable leaves this task.
                for await _ in notifications {
                    if Task.isCancelled { break }
                    continuation.yield(ProcessInfo.processInfo.isLowPowerModeEnabled)
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
