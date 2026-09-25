import Darwin
import Foundation
import os

/// Process CPU usage between consecutive samples, as a percentage of one
/// core (a process saturating two cores reads 200). Uses `getrusage` user +
/// system time over wall-clock elapsed, so it reflects everything the app
/// did in the interval: capture callbacks, encoder bookkeeping, SwiftUI,
/// speech recognition. The first call returns 0 because there is nothing to
/// diff against.
final class CPUUsageSampler: Sendable {
    private struct Last: Sendable {
        var cpuSeconds: Double
        var wallNanos: UInt64
    }

    private let last = OSAllocatedUnfairLock<Last?>(initialState: nil)

    init() {}

    func sample() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let cpuSeconds = Self.seconds(usage.ru_utime) + Self.seconds(usage.ru_stime)
        let wallNanos = DispatchTime.now().uptimeNanoseconds

        return last.withLock { previous -> Double in
            defer { previous = Last(cpuSeconds: cpuSeconds, wallNanos: wallNanos) }
            guard let previous, wallNanos > previous.wallNanos else { return 0 }
            let wallSeconds = Double(wallNanos - previous.wallNanos) / 1_000_000_000
            let delta = max(0, cpuSeconds - previous.cpuSeconds)
            return delta / wallSeconds * 100
        }
    }

    private static func seconds(_ time: timeval) -> Double {
        Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000
    }
}
