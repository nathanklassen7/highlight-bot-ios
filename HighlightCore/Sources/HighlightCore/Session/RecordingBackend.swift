import Foundation

/// Side effects the coordinator needs performed. Implemented by the app's
/// `RecordingPipeline`; mocked in tests.
public protocol RecordingBackend: Sendable {
    /// Start capture and the segmented writer.
    func startRecording() async throws
    /// Stop capture and the writer.
    func stopRecording() async
    /// Snapshot the ring, export, return the record. Must not stop recording.
    func saveClip(lastSeconds: TimeInterval, source: TriggerSourceID) async throws -> ClipRecord
    /// Called when the capture source reports resume; backend must begin a new session.
    func restartSession() async throws
}
