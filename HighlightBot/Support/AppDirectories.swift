import Foundation

/// Well-known on-disk locations. Every accessor creates the directory if it
/// is missing, so callers can use the URL immediately.
///
/// - `clips` and `thumbnails` live under Documents so they survive relaunches
///   and are visible in the Files app (`UIFileSharingEnabled`).
/// - `ring` lives under tmp and is excluded from backup; the OS may purge it,
///   which is fine because ring segments are worthless across launches.
enum AppDirectories {
    /// Documents/Clips — exported `.mp4` files.
    static var clips: URL {
        ensure(documents.appending(path: "Clips", directoryHint: .isDirectory))
    }

    /// Documents/Clips/Thumbnails — JPEG thumbnails, one per clip.
    static var thumbnails: URL {
        ensure(clips.appending(path: "Thumbnails", directoryHint: .isDirectory))
    }

    /// Documents/Clips/Tracks — ball-track JSON sidecars, one per analysed clip.
    static var tracks: URL {
        ensure(clips.appending(path: "Tracks", directoryHint: .isDirectory))
    }

    /// tmp/ring — fMP4 segments written by the ring buffer. Excluded from backup.
    static var ring: URL {
        let url = ensure(FileManager.default.temporaryDirectory.appending(path: "ring", directoryHint: .isDirectory))
        excludeFromBackup(url)
        return url
    }

    /// The app's Documents directory. The sandbox always provides exactly one,
    /// so indexing `[0]` cannot fail on iOS.
    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    @discardableResult
    private static func ensure(_ url: URL) -> URL {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            Log.ui.error("Failed to create directory \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try mutable.setResourceValues(values)
        } catch {
            Log.ui.error("Failed to exclude \(url.path, privacy: .public) from backup: \(error.localizedDescription, privacy: .public)")
        }
    }
}
