import Foundation

/// Identifies one recorder session (one `AVAssetWriter` lifetime).
///
/// Every writer start produces a new initialization segment; media segments
/// from different sessions cannot be concatenated, so the ring buffer and the
/// clip assembler only ever join segments that share a `SessionID`.
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    /// Creates a fresh, random session identifier.
    public init() {
        self.rawValue = UUID()
    }

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(UUID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue.uuidString }
}
