import Foundation
import HighlightCore
import SwiftData
import os

/// Main-actor facade over the SwiftData store for `Clip`. Deleting a clip also
/// removes its media, thumbnail, and ball-track sidecar files.
@MainActor
final class ClipStore {
    private let context: ModelContext

    init(container: ModelContainer) {
        context = container.mainContext
    }

    /// Inserts a new `Clip` built from `record` and saves.
    func insert(_ record: ClipRecord) throws {
        context.insert(Clip(record: record))
        try context.save()
    }

    /// Deletes the model and its files on disk.
    func delete(_ clip: Clip) throws {
        removeFiles(for: clip.record)
        context.delete(clip)
        try context.save()
    }

    /// Deletes every clip and its files.
    func deleteAll() throws {
        let all = try context.fetch(FetchDescriptor<Clip>())
        for clip in all {
            removeFiles(for: clip.record)
            context.delete(clip)
        }
        try context.save()
    }

    /// Sum of `sizeBytes` across all clips; 0 if the fetch fails.
    func totalBytes() -> Int64 {
        do {
            return try context.fetch(FetchDescriptor<Clip>()).reduce(0) { $0 + $1.sizeBytes }
        } catch {
            Log.ui.error("totalBytes fetch failed: \(String(describing: error))")
            return 0
        }
    }

    /// Most recently created clip, if any.
    func newest() -> Clip? {
        var descriptor = FetchDescriptor<Clip>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Looks up the model backing a `ClipRecord`, if it still exists.
    func clip(withID id: UUID) -> Clip? {
        var descriptor = FetchDescriptor<Clip>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func removeFiles(for record: ClipRecord) {
        let fm = FileManager.default
        var urls = [record.fileURL, record.trackURL]
        if let thumb = record.thumbnailURL { urls.append(thumb) }
        for url in urls where fm.fileExists(atPath: url.path) {
            do {
                try fm.removeItem(at: url)
            } catch {
                Log.ui.error("Failed to remove \(url.lastPathComponent): \(String(describing: error))")
            }
        }
    }
}
