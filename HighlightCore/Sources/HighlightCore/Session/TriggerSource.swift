import Foundation

/// Identifies where a trigger came from. Stored on every clip.
public struct TriggerSourceID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Buttons in the UI.
    public static let ui = TriggerSourceID(rawValue: "ui")
    /// Full-screen tap on the record screen.
    public static let tap = TriggerSourceID(rawValue: "tap")
    /// Volume button, Camera Control, or Bluetooth shutter.
    public static let hardwareButton = TriggerSourceID(rawValue: "hardware")
    /// Voice command.
    public static let voice = TriggerSourceID(rawValue: "voice")
    /// Frame analysis (ball tracking).
    public static let vision = TriggerSourceID(rawValue: "vision")
    /// The coordinator itself (inactivity timeout etc.).
    public static let system = TriggerSourceID(rawValue: "system")

    public var description: String { rawValue }
}

/// What a trigger asks the coordinator to do.
public enum TriggerKind: Sendable, Equatable, Hashable {
    /// Save the last `seconds` of footage; nil means the coordinator's `selectedClipSeconds`.
    case saveClip(seconds: TimeInterval?)
    case startRecording
    case stopRecording
    case toggleRecording
}

/// One trigger occurrence.
public struct TriggerEvent: Sendable, Equatable {
    public let source: TriggerSourceID
    public let kind: TriggerKind
    public let timestamp: Date

    public init(source: TriggerSourceID, kind: TriggerKind, timestamp: Date = .now) {
        self.source = source
        self.kind = kind
        self.timestamp = timestamp
    }
}

/// A thing that produces trigger events (tap, hardware button, voice, vision).
public protocol TriggerSource: AnyObject, Sendable {
    var id: TriggerSourceID { get }
    /// Begin emitting. `emit` may be called from any thread.
    func start(emit: @escaping @Sendable (TriggerEvent) -> Void) async throws
    /// Stop emitting. Events delivered after this call are ignored by the bus.
    func stop() async
}
