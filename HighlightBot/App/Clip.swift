import Foundation
import HighlightCore
import SwiftData

/// SwiftData model for a saved clip. Mirrors `HighlightCore.ClipRecord`; files
/// live under `AppDirectories.clips` and are referenced by relative name.
@Model
final class Clip {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var fileName: String
    var thumbnailFileName: String?
    var triggerSource: String
    var sizeBytes: Int64
    /// User tags. Defaults let SwiftData add the column to stores that predate it.
    var tags: [String] = []
    /// User favourite flag. Same migration note as `tags`.
    var isStarred: Bool = false

    init(record: ClipRecord) {
        id = record.id
        createdAt = record.createdAt
        duration = record.duration
        fileName = record.fileName
        thumbnailFileName = record.thumbnailFileName
        triggerSource = record.triggerSource.rawValue
        sizeBytes = record.sizeBytes
        tags = record.tags
        isStarred = record.isStarred
    }

    /// Value-type view of this model.
    var record: ClipRecord {
        ClipRecord(
            id: id,
            createdAt: createdAt,
            duration: duration,
            fileName: fileName,
            thumbnailFileName: thumbnailFileName,
            triggerSource: TriggerSourceID(rawValue: triggerSource),
            sizeBytes: sizeBytes,
            tags: tags,
            isStarred: isStarred
        )
    }

    /// Absolute URL of the .mp4.
    var fileURL: URL { record.fileURL }

    /// Absolute URL of the JPEG thumbnail, if one was generated.
    var thumbnailURL: URL? { record.thumbnailURL }
}

extension ClipRecord {
    /// Absolute URL of the .mp4 (`AppDirectories.clips/<fileName>`).
    var fileURL: URL {
        AppDirectories.clips.appending(path: fileName)
    }

    /// Absolute URL of the thumbnail. Hits the file system; prefer
    /// `ThumbnailImage(fileName:)` in views so this never runs in `body`.
    var thumbnailURL: URL? {
        Self.resolveThumbnailURL(fileName: thumbnailFileName)
    }

    /// `fileName` is relative to the clips directory; if the exporter placed it
    /// under `AppDirectories.thumbnails` instead, fall back to that location.
    /// Does one or two `stat` calls — call off the main thread when possible.
    nonisolated static func resolveThumbnailURL(fileName: String?) -> URL? {
        guard let fileName else { return nil }
        let inClips = AppDirectories.clips.appending(path: fileName)
        if FileManager.default.fileExists(atPath: inClips.path) {
            return inClips
        }
        let inThumbnails = AppDirectories.thumbnails.appending(path: fileName)
        if FileManager.default.fileExists(atPath: inThumbnails.path) {
            return inThumbnails
        }
        return inClips
    }
}
