import BallTracking
import Foundation
import HighlightCore
import Observation
import os

enum ClipTrackStatus: Equatable {
    case none
    case analyzing(fraction: Double)
    case ready(BallTrack)
    case failed(String)
}

/// Runs `ClipTrackRunner` over saved clips on demand, caches results as sidecars,
/// and publishes per-clip status for the player.
@MainActor
@Observable
final class ClipTrackService {
    private(set) var statuses: [UUID: ClipTrackStatus] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Cancellation flags read by `ClipTrackRunner` on its worker queue, where
    /// `Task.isCancelled` would not reflect our detached task.
    @ObservationIgnored private var cancelFlags: [UUID: OSAllocatedUnfairLock<Bool>] = [:]
    @ObservationIgnored private let preferences: TrackingPreferences

    init(preferences: TrackingPreferences) {
        self.preferences = preferences
    }

    func status(for record: ClipRecord) -> ClipTrackStatus {
        statuses[record.id] ?? .none
    }

    /// Populates `.ready` from the sidecar if one exists. Cheap; call on appear.
    func loadCached(for record: ClipRecord) {
        if case .ready = status(for: record) { return }
        if case .analyzing = status(for: record) { return }
        if let track = ClipTrackStore.load(for: record) {
            statuses[record.id] = .ready(track)
        }
    }

    /// Starts analysis unless a result or a run already exists.
    func analyze(_ record: ClipRecord) {
        switch status(for: record) {
        case .ready, .analyzing: return
        case .none, .failed: break
        }
        if let track = ClipTrackStore.load(for: record) {
            statuses[record.id] = .ready(track)
            return
        }

        statuses[record.id] = .analyzing(fraction: 0)
        let id = record.id
        let url = record.fileURL
        let runner = ClipTrackRunner(detectorKind: preferences.detectorKind)
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        cancelFlags[id] = cancelFlag
        Log.tracking.info("Analysing \(record.fileName, privacy: .public) with \(runner.detectorName, privacy: .public)")

        // Nested Sendable closures may not re-capture a weak `self` var, so each
        // hop back to the main actor goes through a `let` copy of the reference.
        let onProgress: @Sendable (ClipTrackProgress) -> Void = { [weak self] progress in
            let service = self
            Task { @MainActor in
                service?.updateProgress(id, fraction: progress.fraction)
            }
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let outcome: ClipTrackStatus
            do {
                let result = try await runner.run(url: url, progress: onProgress, isCancelled: { cancelFlag.withLock { $0 } })
                try ClipTrackStore.save(result.track, for: record)
                Log.tracking.info("Tracked \(record.fileName, privacy: .public): \(result.track.frames.count) frames, tracking \(result.track.trackingFraction * 100, format: .fixed(precision: 1))%, mean detect \(result.meanDetectMillis, format: .fixed(precision: 2)) ms, wall \(result.wallSeconds, format: .fixed(precision: 1)) s")
                outcome = .ready(result.track)
            } catch ClipTrackError.cancelled {
                outcome = .none
            } catch is CancellationError {
                // `Task.cancel()` landed while the runner was still loading the
                // asset, before it consulted the per-frame flag.
                outcome = .none
            } catch {
                Log.tracking.error("Tracking failed for \(record.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                outcome = .failed(error.localizedDescription)
            }
            let service = self
            await MainActor.run {
                service?.finish(id, with: outcome)
            }
        }
        tasks[id] = task
    }

    /// Stops a running analysis; the status returns to `.none` once the runner unwinds.
    func cancel(_ record: ClipRecord) {
        cancelFlags[record.id]?.withLock { $0 = true }
        tasks[record.id]?.cancel()
    }

    private func updateProgress(_ id: UUID, fraction: Double) {
        guard case .analyzing = statuses[id] else { return }
        statuses[id] = .analyzing(fraction: fraction)
    }

    private func finish(_ id: UUID, with status: ClipTrackStatus) {
        statuses[id] = status
        tasks[id] = nil
        cancelFlags[id] = nil
    }
}
