import Foundation
import HighlightCore

/// Error type thrown by the mock so tests can match on its message.
struct MockBackendError: Error, Equatable, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Records every backend call and lets tests inject delays, failures, and
/// hold saves open until released.
actor MockRecordingBackend: RecordingBackend {
    enum Call: Equatable, Sendable {
        case startRecording
        case stopRecording
        case saveClip(lastSeconds: TimeInterval, source: TriggerSourceID)
        case restartSession
    }

    private(set) var calls: [Call] = []

    var startError: MockBackendError?
    var saveError: MockBackendError?
    var restartError: MockBackendError?

    var startDelay: Duration = .zero
    var stopDelay: Duration = .zero
    var saveDelay: Duration = .zero
    var restartDelay: Duration = .zero

    /// When true, `saveClip` blocks until `releaseSaves()` is called.
    var holdSaves = false
    private var heldSaves: [CheckedContinuation<Void, Never>] = []

    var clipDuration: TimeInterval = 20

    // MARK: Configuration

    func setStartError(_ error: MockBackendError?) { startError = error }
    func setSaveError(_ error: MockBackendError?) { saveError = error }
    func setRestartError(_ error: MockBackendError?) { restartError = error }
    func setStartDelay(_ delay: Duration) { startDelay = delay }
    func setStopDelay(_ delay: Duration) { stopDelay = delay }
    func setSaveDelay(_ delay: Duration) { saveDelay = delay }
    func setHoldSaves(_ hold: Bool) { holdSaves = hold }

    /// Lets every blocked `saveClip` continue.
    func releaseSaves() {
        let waiting = heldSaves
        heldSaves.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }

    /// Number of `saveClip` calls currently blocked by `holdSaves`.
    var heldSaveCount: Int { heldSaves.count }

    func count(of call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    var saveCalls: [Call] {
        calls.filter {
            if case .saveClip = $0 { return true }
            return false
        }
    }

    // MARK: RecordingBackend

    func startRecording() async throws {
        calls.append(.startRecording)
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        if let startError { throw startError }
    }

    func stopRecording() async {
        calls.append(.stopRecording)
        if stopDelay > .zero { try? await Task.sleep(for: stopDelay) }
    }

    func saveClip(lastSeconds: TimeInterval, source: TriggerSourceID) async throws -> ClipRecord {
        calls.append(.saveClip(lastSeconds: lastSeconds, source: source))
        if saveDelay > .zero { try? await Task.sleep(for: saveDelay) }
        if holdSaves {
            await withCheckedContinuation { continuation in
                heldSaves.append(continuation)
            }
        }
        if let saveError { throw saveError }
        let now = Date()
        return ClipRecord(
            id: UUID(),
            createdAt: now,
            duration: min(lastSeconds, clipDuration),
            fileName: ClipNaming.baseName(for: now) + ".mp4",
            thumbnailFileName: nil,
            triggerSource: source,
            sizeBytes: 1_000_000
        )
    }

    func restartSession() async throws {
        calls.append(.restartSession)
        if restartDelay > .zero { try? await Task.sleep(for: restartDelay) }
        if let restartError { throw restartError }
    }
}
