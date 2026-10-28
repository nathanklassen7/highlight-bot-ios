import Foundation

/// Disk-space queries. Stateless; everything is a static function.
final class StorageMonitor: Sendable {
    /// Bytes the system is willing to let this app use on the volume that
    /// contains `url` (`volumeAvailableCapacityForImportantUsage`). Returns 0
    /// if the query fails so callers treat failure as "no space".
    static func freeBytes(at url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values.volumeAvailableCapacityForImportantUsage ?? 0
        } catch {
            Log.ui.error("freeBytes failed for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Sum of regular-file sizes under `url`, recursively. Returns 0 for a
    /// missing directory.
    static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }
}
