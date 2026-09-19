import Foundation
import HighlightCore
import SwiftData
import os

/// Main-actor facade over the SwiftData store for `Clip`. Deleting a clip also
/// removes its media and thumbnail files.
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

    // MARK: - Tags and favourites

    /// Replaces the clip's tags with the normalized, de-duplicated `tags`.
    func updateTags(_ clip: Clip, tags: [String]) throws {
        clip.tags = ClipTag.normalized(tags)
        try context.save()
    }

    /// Unions `tags` onto every clip in `clips` (bulk tag from select mode).
    func addTags(_ clips: [Clip], tags: [String]) throws {
        let additions = ClipTag.normalized(tags)
        guard !additions.isEmpty else { return }
        for clip in clips {
            clip.tags = ClipTag.merge(clip.tags, additions)
        }
        try context.save()
    }

    func setStarred(_ clip: Clip, isStarred: Bool) throws {
        clip.isStarred = isStarred
        try context.save()
    }

    func setStarred(_ clips: [Clip], isStarred: Bool) throws {
        for clip in clips {
            clip.isStarred = isStarred
        }
        try context.save()
    }

    /// Every distinct tag currently on at least one clip, de-duplicated
    /// case-insensitively and sorted for display. Empty on fetch failure.
    func usedTags() -> [String] {
        do {
            let all = try context.fetch(FetchDescriptor<Clip>())
            return ClipTag.sortedForDisplay(ClipTag.merge([], all.flatMap(\.tags)))
        } catch {
            Log.ui.error("usedTags fetch failed: \(String(describing: error))")
            return []
        }
    }

    private func removeFiles(for record: ClipRecord) {
        let fm = FileManager.default
        var urls = [record.fileURL]
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
