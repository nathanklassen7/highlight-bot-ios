import BallTracking
import Foundation
import HighlightCore

/// Reads and writes `BallTrack` JSON sidecars for clips. Plain file I/O; callers
/// choose the thread.
enum ClipTrackStore {
    static func load(for record: ClipRecord) -> BallTrack? {
        let url = record.trackURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let track = try JSONDecoder().decode(BallTrack.self, from: Data(contentsOf: url))
            guard track.version == BallTrack.currentVersion else {
                Log.tracking.notice("Ignoring track sidecar with version \(track.version) for \(record.fileName, privacy: .public)")
                return nil
            }
            return track
        } catch {
            Log.tracking.error("Failed to read track for \(record.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ track: BallTrack, for record: ClipRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(track).write(to: record.trackURL, options: .atomic)
    }
}
