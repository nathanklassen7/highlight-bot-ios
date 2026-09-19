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

    public init(
        id: UUID,
        createdAt: Date,
        duration: TimeInterval,
        fileName: String,
        thumbnailFileName: String?,
        triggerSource: TriggerSourceID,
        sizeBytes: Int64
    ) {
        self.id = id
        self.createdAt = createdAt
        self.duration = duration
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.triggerSource = triggerSource
        self.sizeBytes = sizeBytes
    }
}
