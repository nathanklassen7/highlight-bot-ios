import Foundation

/// Persisted clip metadata (value type). The app's SwiftData model maps to
/// and from this.
public struct ClipRecord: Sendable, Codable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let createdAt: Date
    /// Clip length in seconds.
    public let duration: TimeInterval
    /// File name relative to the clips directory, e.g. `2026-09-18T20-11-03Z-3F2A.mp4`.
    public let fileName: String
    /// Thumbnail file name relative to the clips directory, if one was generated.
    public let thumbnailFileName: String?
    /// Which trigger produced the clip.
    public let triggerSource: TriggerSourceID
    /// Size of the clip file in bytes.
    public let sizeBytes: Int64
    /// Oriented pixel width, after the capture transform: a portrait 1080p
    /// clip stores 1080. `0` for records written before this was captured.
    public let videoWidth: Int
    /// Oriented pixel height. `0` alongside `videoWidth` on older records.
    public let videoHeight: Int
    /// User tags (sport or anything else). Normalized via `ClipTag`.
    public let tags: [String]
    /// User favourite flag.
    public let isStarred: Bool
    /// True for a clip the montage editor exported from several source clips.
    public let isMontage: Bool

    /// Landscape, portrait, or square from the stored size; `.unknown` when the
    /// size is missing. Use `ClipOrientation.effective` where a decision needs
    /// an answer.
    public var orientation: ClipOrientation {
        ClipOrientation.classify(width: videoWidth, height: videoHeight)
    }

    public init(
        id: UUID,
        createdAt: Date,
        duration: TimeInterval,
        fileName: String,
        thumbnailFileName: String?,
        triggerSource: TriggerSourceID,
        sizeBytes: Int64,
        videoWidth: Int = 0,
        videoHeight: Int = 0,
        tags: [String] = [],
        isStarred: Bool = false,
        isMontage: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.triggerSource = triggerSource
        self.sizeBytes = sizeBytes
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.tags = tags
        self.isStarred = isStarred
        self.isMontage = isMontage
    }

    /// Copy with different user metadata. Capture fields are immutable.
    public func with(tags: [String]? = nil, isStarred: Bool? = nil, isMontage: Bool? = nil) -> ClipRecord {
        ClipRecord(
            id: id,
            createdAt: createdAt,
            duration: duration,
            fileName: fileName,
            thumbnailFileName: thumbnailFileName,
            triggerSource: triggerSource,
            sizeBytes: sizeBytes,
            videoWidth: videoWidth,
            videoHeight: videoHeight,
            tags: tags ?? self.tags,
            isStarred: isStarred ?? self.isStarred,
            isMontage: isMontage ?? self.isMontage
        )
    }

    // MARK: - Codable

    // Custom decoding so records written before `tags` / `isStarred` /
    // `isMontage` / `videoWidth` / `videoHeight` existed still decode
    // (missing keys → defaults).
    private enum CodingKeys: String, CodingKey {
        case id, createdAt, duration, fileName, thumbnailFileName, triggerSource, sizeBytes
        case videoWidth, videoHeight, tags, isStarred, isMontage
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fileName = try container.decode(String.self, forKey: .fileName)
        thumbnailFileName = try container.decodeIfPresent(String.self, forKey: .thumbnailFileName)
        triggerSource = try container.decode(TriggerSourceID.self, forKey: .triggerSource)
        sizeBytes = try container.decode(Int64.self, forKey: .sizeBytes)
        videoWidth = try container.decodeIfPresent(Int.self, forKey: .videoWidth) ?? 0
        videoHeight = try container.decodeIfPresent(Int.self, forKey: .videoHeight) ?? 0
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        isMontage = try container.decodeIfPresent(Bool.self, forKey: .isMontage) ?? false
    }
}
