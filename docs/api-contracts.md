# API Contracts (frozen for parallel implementation)

These signatures are the agreed interface between the three work streams
(`HighlightCore`, `HighlightBot/Capture` + `Triggers` + `Support`, and
`HighlightBot/App` + `Features`). Implementers may add private helpers and
additional public members, but must not rename, remove, or change the meaning of
anything listed here without flagging it in their final report.

Conventions

- Swift 6 language mode, strict concurrency. Everything public is `Sendable`
  unless it is an `actor` or explicitly noted.
- `HighlightCore` imports only `Foundation`. No AVFoundation, UIKit, SwiftUI,
  SwiftData, CoreMedia.
- Tests in `HighlightCore` use **Swift Testing** (`import Testing`), not XCTest.
  XCTest is not available on the dev machine.
- App target: iOS 17.2 minimum, landscape only.

---

## HighlightCore — `Config/`

```swift
public enum VideoCodec: String, Codable, Sendable, CaseIterable, Identifiable {
    case h264, hevc
    public var id: String { rawValue }
    public var displayName: String   // "H.264", "HEVC"
}

public struct RecordingConfig: Codable, Sendable, Equatable {
    public var bufferSeconds: TimeInterval       // 20
    public var segmentInterval: TimeInterval     // 5
    public var width: Int                        // 1920
    public var height: Int                       // 1080
    public var frameRate: Int                    // 60
    public var videoBitrate: Int                 // 10_000_000
    public var codec: VideoCodec                 // .h264
    public var recordAudio: Bool                 // true
    public var inactivityTimeout: TimeInterval   // 45 * 60
    public var minimumFreeBytes: Int64           // 500 * 1024 * 1024
    public var debugOverlayEnabled: Bool         // false

    public init(/* all fields, each with the default above */)
    public static let `default`: RecordingConfig
    public static let bufferOptions: [TimeInterval]   // [10, 20, 30, 60]

    /// Number of media segments needed to cover `bufferSeconds`, rounded up.
    public var segmentsPerBuffer: Int
    /// Seconds the ring must retain: bufferSeconds + segmentInterval.
    public var retainSeconds: TimeInterval

    public func validate() -> [ConfigError]      // empty == valid
}

public enum ConfigError: Error, Equatable, Sendable, CustomStringConvertible {
    case bufferTooShort, segmentIntervalInvalid, frameRateInvalid,
         resolutionInvalid, bitrateInvalid, inactivityTimeoutInvalid
}
```

## HighlightCore — `RingBuffer/`

```swift
public struct SessionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init()
    public init(rawValue: UUID)
}

public enum SegmentKind: String, Sendable, Codable { case initialization, media }

/// A segment as produced by the recorder, before it hits disk.
public struct IncomingSegment: Sendable {
    public let sessionID: SessionID
    public let seq: Int                 // 0 for initialization, then 1, 2, 3 ... per session
    public let kind: SegmentKind
    public let data: Data
    public let startTime: TimeInterval  // seconds since session start; 0 for init
    public let duration: TimeInterval   // 0 for init
    public init(sessionID:seq:kind:data:startTime:duration:)
}

/// A segment persisted by the ring buffer.
public struct Segment: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(sessionID.rawValue.uuidString)/\(seq)" }
    public let sessionID: SessionID
    public let seq: Int
    public let kind: SegmentKind
    public let url: URL
    public let startTime: TimeInterval
    public let duration: TimeInterval
    public let byteCount: Int
    public init(sessionID:seq:kind:url:startTime:duration:byteCount:)
}

/// Where segment bytes live. Default implementation is disk; tests use in-memory.
public protocol SegmentStorage: Sendable {
    func write(_ data: Data, sessionID: SessionID, seq: Int, kind: SegmentKind) throws -> URL
    func delete(_ url: URL) throws
    func deleteAll(for sessionID: SessionID) throws
    func deleteEverything() throws
}

public struct FileSegmentStorage: SegmentStorage {
    /// Layout: <root>/<sessionID>/<seq>.<init|m4s>
    public init(rootDirectory: URL)
    public let rootDirectory: URL
}

public struct InMemorySegmentStorage: SegmentStorage {   // for tests; url is a synthetic "memory://" URL
    public init()
    public func data(at url: URL) -> Data?
}

public struct RingBufferPolicy: Sendable, Equatable {
    public var retainSeconds: TimeInterval
    public init(retainSeconds: TimeInterval)
    public init(config: RecordingConfig)   // uses config.retainSeconds
}

public actor SegmentRingBuffer {
    public init(policy: RingBufferPolicy, storage: any SegmentStorage)

    public var policy: RingBufferPolicy { get }
    public func updatePolicy(_ policy: RingBufferPolicy)

    /// Persists the segment and evicts. A new session's initialization segment
    /// makes that session current; all segments of older sessions are evicted.
    @discardableResult
    public func append(_ incoming: IncomingSegment) throws -> Segment

    public var currentSessionID: SessionID? { get }
    /// Total media duration retained for the current session.
    public var bufferedSeconds: TimeInterval { get }
    public var segments: [Segment] { get }   // all retained, ordered by (session, seq)

    /// Whole-segment plan covering at least `lastSeconds` of the current
    /// session, or nil if there is no init segment or no media.
    public func snapshot(lastSeconds: TimeInterval) -> ClipPlan?

    public func clear() throws
}
```

Eviction rule: after each append, for the current session, drop the oldest
media segments while `(total media duration - oldest.duration) >= retainSeconds`.
Never drop the current session's initialization segment. Storage deletes happen
inside `append` (synchronously; the caller runs on a utility queue).

## HighlightCore — `Clips/`

```swift
public struct ClipPlan: Sendable, Equatable {
    public let sessionID: SessionID
    public let initializationSegment: Segment
    public let mediaSegments: [Segment]     // ascending seq, contiguous
    public var duration: TimeInterval        // sum of media durations
    public var byteCount: Int
    public var urls: [URL]                   // [init] + media, in order
    public init(sessionID:initializationSegment:mediaSegments:)
}

public enum ClipAssembler {
    /// Pure selection. Filters to `sessionID`, requires an init segment, sorts
    /// media by seq, walks backwards from the newest segment while
    /// accumulated duration < lastSeconds, stops at any seq gap. Returns nil
    /// if no init or no media.
    public static func plan(segments: [Segment], sessionID: SessionID, lastSeconds: TimeInterval) -> ClipPlan?
}

/// Persisted clip metadata (value type). The app's SwiftData model maps to/from this.
public struct ClipRecord: Sendable, Codable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let createdAt: Date
    public let duration: TimeInterval
    public let fileName: String            // relative to the clips directory, e.g. "2026-09-18T20-11-03Z-3F2A.mp4"
    public let thumbnailFileName: String?  // relative, e.g. "...jpg"
    public let triggerSource: TriggerSourceID
    public let sizeBytes: Int64
    public let tags: [String]              // user tags, normalized via ClipTag; [] when absent from JSON
    public let isStarred: Bool             // user favourite; false when absent from JSON
    public init(id:createdAt:duration:fileName:thumbnailFileName:triggerSource:sizeBytes:tags:isStarred:)  // last two default
    /// Copy with different user metadata; capture fields never change.
    public func with(tags: [String]? = nil, isStarred: Bool? = nil) -> ClipRecord
}

/// Tag normalization and the canonical sport list. Tags are plain strings on ClipRecord.
public enum ClipTag {
    public static let suggestedSports: [String]   // "Hockey", "Soccer", ... always offered in the picker
    public static let maxLength: Int              // 40
    /// Trim, collapse whitespace, clip to maxLength, canonicalize sport casing ("hockey" -> "Hockey"). nil if empty.
    public static func normalize(_ raw: String) -> String?
    public static func isSuggestedSport(_ tag: String) -> Bool                 // case-insensitive
    public static func merge(_ base: [String], _ additions: [String]) -> [String]  // case-insensitive union, first casing wins
    public static func normalized(_ tags: [String]) -> [String]                // normalize + de-dupe
    public static func sortedForDisplay(_ tags: [String]) -> [String]
    public static func contains(_ tags: [String], _ tag: String) -> Bool        // case-insensitive
    public static func removing(_ tag: String, from tags: [String]) -> [String]
}

public enum ClipNaming {
    /// "yyyy-MM-dd'T'HH-mm-ss'Z'-XXXX" using UTC and 4 random hex chars; caller appends extension.
    public static func baseName(for date: Date) -> String
}
```

## HighlightCore — `Session/`

```swift
public struct TriggerSourceID: Hashable, Sendable, Codable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String)
    public static let ui            = TriggerSourceID(rawValue: "ui")           // buttons in the UI
    public static let tap           = TriggerSourceID(rawValue: "tap")          // full-screen tap
    public static let hardwareButton = TriggerSourceID(rawValue: "hardware")    // volume / Camera Control / BT shutter
    public static let voice         = TriggerSourceID(rawValue: "voice")
    public static let vision        = TriggerSourceID(rawValue: "vision")
    public static let system        = TriggerSourceID(rawValue: "system")       // inactivity timeout etc.
}

public enum TriggerKind: Sendable, Equatable, Hashable {
    case saveClip(seconds: TimeInterval?)   // nil = use coordinator's selectedClipSeconds
    case startRecording
    case stopRecording
    case toggleRecording
}

public struct TriggerEvent: Sendable, Equatable {
    public let source: TriggerSourceID
    public let kind: TriggerKind
    public let timestamp: Date
    public init(source: TriggerSourceID, kind: TriggerKind, timestamp: Date = .now)
}

/// A thing that produces trigger events (tap, hardware button, voice, vision).
public protocol TriggerSource: AnyObject, Sendable {
    var id: TriggerSourceID { get }
    /// Begin emitting. `emit` may be called from any thread.
    func start(emit: @escaping @Sendable (TriggerEvent) -> Void) async throws
    func stop() async
}

public actor TriggerBus {
    public init()
    public func register(_ source: any TriggerSource) async throws
    public func unregister(_ id: TriggerSourceID) async
    public func stopAll() async
    /// Inject an event directly (used by UI buttons and tests).
    public func emit(_ event: TriggerEvent)
    /// Each call returns an independent stream that receives all future events.
    public func subscribe() -> AsyncStream<TriggerEvent>
}

public enum SessionState: Sendable, Equatable, Hashable {
    case idle
    case starting
    case recording(pendingSaves: Int)
    case interrupted           // capture interrupted (phone call, background); will resume
    case stopping

    public var isRecording: Bool   // true for .recording and .interrupted
}

public enum SessionEvent: Sendable, Equatable {
    case stateChanged(SessionState)
    case clipSaved(ClipRecord)
    case saveFailed(reason: String)
    case startFailed(reason: String)
    case inactivityTimeoutFired
    case inactivityWarning(secondsRemaining: TimeInterval)   // fired once, 5 minutes before timeout
}

/// Side effects the coordinator needs performed. Implemented by the app's
/// `RecordingPipeline`; mocked in tests.
public protocol RecordingBackend: Sendable {
    func startRecording() async throws
    func stopRecording() async
    /// Snapshot the ring, export, return the record. Must not stop recording.
    func saveClip(lastSeconds: TimeInterval, source: TriggerSourceID) async throws -> ClipRecord
    /// Called when the capture source reports resume; backend must begin a new session.
    func restartSession() async throws
}

public actor SessionCoordinator {
    public static let saveCooldownSeconds: TimeInterval = 4
    public init(config: RecordingConfig, backend: any RecordingBackend, clock: any Clock<Duration> = ContinuousClock(), warningLeadTime: TimeInterval = 300, saveCooldown: TimeInterval = SessionCoordinator.saveCooldownSeconds)

    public var state: SessionState { get }
    public var selectedClipSeconds: TimeInterval { get }       // defaults to config.bufferSeconds
    public func setSelectedClipSeconds(_ seconds: TimeInterval)
    public func updateConfig(_ config: RecordingConfig)

    public func events() -> AsyncStream<SessionEvent>          // independent per subscriber

    /// Consume triggers from a bus until cancelled.
    public func run(bus: TriggerBus) async
    /// Handle a single trigger (used by run and by tests).
    public func handle(_ event: TriggerEvent) async

    // Capture-side notifications from the pipeline
    public func captureDidInterrupt() async
    public func captureDidResume() async
    public func captureDidFail(reason: String) async
}
```

State machine (ported from `highlight-bot/src/state_machine.py`, saving is a task not a state):

| State | Trigger | Result |
| --- | --- | --- |
| idle | startRecording / toggleRecording | starting → backend.startRecording() → recording(0); on throw → idle + startFailed |
| idle | saveClip | ignored |
| recording | saveClip(s) | ignored if within saveCooldown of the last accepted save; else pendingSaves += 1, spawn task: backend.saveClip(s ?? selected) → clipSaved / saveFailed; pendingSaves -= 1. Resets inactivity timer. |
| recording | stopRecording / toggleRecording | stopping → backend.stopRecording() → idle. Pending saves finish independently. |
| recording | inactivity timeout elapses | inactivityTimeoutFired then same as stopRecording |
| recording | captureDidInterrupt | interrupted |
| interrupted | captureDidResume | backend.restartSession() → recording(pendingSaves) |
| interrupted | stopRecording / toggleRecording | stopping → idle |
| interrupted | saveClip | saveFailed("capture interrupted") |
| any | captureDidFail | backend.stopRecording(); idle; startFailed(reason) |

Inactivity: timer starts on entering recording, resets on every accepted saveClip, fires
`inactivityWarning` once at `timeout - 300s` (if timeout > 300s), and
`inactivityTimeoutFired` at `timeout`. Cancelled on leaving recording.

---

## App target — `HighlightBot/Capture/` (owned by the Capture stream)

```swift
import AVFoundation
import HighlightCore

enum CaptureEvent: Sendable, Equatable {
    case started
    case stopped
    case interrupted(reason: String)
    case resumed
    case formatChanged(width: Int, height: Int, frameRate: Int)
    case runtimeError(String)
}

/// Receives raw samples on the capture queue. Must return fast (<1 ms).
protocol SampleConsumer: AnyObject {
    func consumeVideo(_ sampleBuffer: CMSampleBuffer)
    func consumeAudio(_ sampleBuffer: CMSampleBuffer)
    func didDropVideoFrame()
}

/// A camera or a file replay. Not an actor: owns its own serial queue.
protocol CaptureSource: AnyObject {
    var events: AsyncStream<CaptureEvent> { get }
    /// AVCaptureVideoPreviewLayer for the camera, AVSampleBufferDisplayLayer for replay.
    @MainActor func makePreviewLayer() -> CALayer
    func setConsumer(_ consumer: (any SampleConsumer)?)
    func configure(_ config: RecordingConfig) async throws
    func start() async throws
    func stop() async
    /// Lower frame rate (thermal). No-op if unsupported.
    func setFrameRate(_ fps: Int) async
}

final class CaptureEngine: CaptureSource { init() }
final class FileReplayCaptureSource: CaptureSource { init(fileURL: URL, loop: Bool = true) }

protocol FrameAnalyzer: AnyObject, Sendable {
    var name: String { get }
    /// Called off the capture queue. Frames are dropped while this is running.
    func analyze(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) async
}

final class FrameTap: Sendable {
    init()
    func register(_ analyzer: any FrameAnalyzer)
    func unregister(name: String)
    /// Non-blocking; drops if the analyzer is busy.
    func enqueue(pixelBuffer: CVPixelBuffer, presentationTime: CMTime)
}

struct PipelineMetrics: Sendable, Equatable {
    var capturedFrames: Int
    var droppedFrames: Int             // from didDrop (capture) — should stay 0
    var analyzerDroppedFrames: Int     // dropped by FrameTap, expected
    var bufferedSeconds: TimeInterval
    var lastSegmentWriteMillis: Double
    var lastExportSeconds: Double
    var lastCallbackMicros: Double     // duration of the last video data callback
    var thermalState: ProcessInfo.ThermalState
    var freeBytes: Int64
    var currentFrameRate: Int
    var sessionID: SessionID?
    static let zero: PipelineMetrics
}

struct ExportedClip: Sendable {
    let fileURL: URL
    let thumbnailURL: URL?
    let duration: TimeInterval
    let sizeBytes: Int64
    var thumbnailFileName: String?     // "Thumbnails/<base>.jpg", as ClipRecord stores it
}

final class ClipExporter: Sendable {
    /// `clipsDirectory` is Documents/Clips; created if missing.
    init(clipsDirectory: URL)
    /// Concatenate plan.urls into a temp fMP4, passthrough-export to .mp4, generate a JPEG thumbnail.
    func export(_ plan: ClipPlan, baseName: String) async throws -> ExportedClip
    /// Building blocks shared with ClipTrimmer.
    static func runExport(asset: AVAsset, preset: String, timeRange: CMTimeRange? = nil, to outputURL: URL) async throws
    static func writeThumbnail(asset: AVAsset, at seconds: Double = 0.5, baseName: String, clipsDirectory: URL) async -> URL?
    static func fileSize(at url: URL) -> Int64
}

/// Wires CaptureSource → SampleFanout → SegmentedRecorder → SegmentRingBuffer, plus FrameTap.
/// Implements HighlightCore.RecordingBackend. The App creates exactly one.
final class RecordingPipeline: RecordingBackend, Sendable {
    init(source: any CaptureSource,
         config: RecordingConfig,
         ringBuffer: SegmentRingBuffer,
         exporter: ClipExporter,
         frameTap: FrameTap,
         coordinator: SessionCoordinator)   // pipeline forwards captureDidInterrupt/Resume/Fail
    func updateConfig(_ config: RecordingConfig) async
    func metrics() -> AsyncStream<PipelineMetrics>    // emits ~1 Hz while recording
    var source: any CaptureSource { get }
}
```

## App target — `HighlightBot/Triggers/`

```swift
/// Fired by the Record screen's gestures.
final class TapTrigger: TriggerSource {
    init()
    let id: TriggerSourceID   // .tap
    func fireSave()           // whole-screen tap
    func fireToggle()         // long-press
}

/// AVCaptureEventInteraction (volume, Camera Control, Bluetooth shutter).
final class HardwareTrigger: TriggerSource {
    init()
    let id: TriggerSourceID   // .hardwareButton
}

/// UIViewRepresentable that hosts the AVCaptureEventInteraction. Place it inside RecordScreen.
struct HardwareTriggerHost: UIViewRepresentable { let trigger: HardwareTrigger }
```

## App target — `HighlightBot/Support/`

```swift
enum PermissionStatus: Sendable, Equatable { case notDetermined, granted, denied, restricted }

@MainActor @Observable final class PermissionsManager {
    var camera: PermissionStatus
    var microphone: PermissionStatus
    var photosAddOnly: PermissionStatus
    func refresh()
    func requestCamera() async -> PermissionStatus
    func requestMicrophone() async -> PermissionStatus
    func requestPhotosAddOnly() async -> PermissionStatus
}

final class StorageMonitor: Sendable {
    static func freeBytes(at url: URL) -> Int64        // volumeAvailableCapacityForImportantUsage
    static func directorySize(_ url: URL) -> Int64
}

final class ThermalMonitor: Sendable {
    init()
    func states() -> AsyncStream<ProcessInfo.ThermalState>
}

enum Log {  // os.Logger wrappers, subsystem "com.nathanklassen.highlightbot"
    static let capture: Logger
    static let recorder: Logger
    static let ring: Logger
    static let export: Logger
    static let session: Logger
    static let ui: Logger
}

enum AppDirectories {
    static var clips: URL          // Documents/Clips
    static var ring: URL           // tmp/ring
    static var thumbnails: URL     // Documents/Clips/Thumbnails (or same dir; exporter decides, must be under Documents)
}
```

## App target — `HighlightBot/App/` and `Features/` (owned by the App stream)

```swift
@MainActor @Observable final class SettingsStore {
    var config: RecordingConfig      // persisted to UserDefaults on change (JSON)
    init(defaults: UserDefaults = .standard)
}

/// SwiftData model.
@Model final class Clip {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var duration: TimeInterval
    var fileName: String
    var thumbnailFileName: String?
    var triggerSource: String
    var sizeBytes: Int64
    var tags: [String] = []      // defaults let SwiftData migrate stores that predate the column
    var isStarred: Bool = false
    init(record: ClipRecord)
    var record: ClipRecord { get }
    var fileURL: URL             // AppDirectories.clips.appending(path: fileName)
    var thumbnailURL: URL?
}

@MainActor final class ClipStore {
    init(container: ModelContainer)
    func insert(_ record: ClipRecord) throws
    func delete(_ clip: Clip) throws          // also removes files
    func deleteAll() throws
    func totalBytes() -> Int64
    func newest() -> Clip?
    func clip(withID: UUID) -> Clip?
    func updateTags(_ clip: Clip, tags: [String]) throws        // replaces, normalized
    func applyTags(_ clips: [Clip], add: [String], remove: [String]) throws  // bulk: union `add`, strip `remove`
    static func commonTags(of clips: [[String]]) -> [String]    // tags every clip shares; seeds the bulk picker
    func setStarred(_ clip: Clip, isStarred: Bool) throws
    func setStarred(_ clips: [Clip], isStarred: Bool) throws
    func usedTags() -> [String]                                 // distinct tags on at least one clip
    /// Trim result replaces the clip's media: repoint fileName/thumbnail/duration/size, save, then delete the old files.
    func replaceMedia(_ clip: Clip, with exported: ExportedClip) throws
}

/// Trim/edit screen (HighlightBot/Features/Editor/). Opened from the player's bottom bar and the Library long-press menu.
/// Yellow handles trim; an optional slow-mo segment gets green handles and a speed from the player's speed menu.
/// Preview switches the player's rate inside the segment; Save re-encodes with the segment stretched for real.
enum ClipEditOutcome { case replaced(ClipRecord), savedCopy(ClipRecord) }
struct ClipEditorScreen: View {        // present with .fullScreenCover; onComplete fires before dismiss
    init(record: ClipRecord, onComplete: @escaping (ClipEditOutcome) -> Void)
}
struct TrimRangeBar: View              // filmstrip + start/end handles + playhead + optional green slow-mo range; enforces both minimums
/// A stretch of the clip, in source seconds, played at `rate` (0.5 = half speed). Occupies duration / rate in the output.
struct SlowMotionSegment: Equatable, Sendable {
    var start: Double, end: Double, rate: Float
    static let rates: [Float]          // 0.5, 0.25, 0.15 — the player's menu minus 100%
    static let defaultRate: Float      // 0.5
    static let defaultDuration: Double // 1.0 s, inserted centred in the selection
    static let minimumDuration: Double // 0.25 s
    var duration: Double; var scaledDuration: Double; var addedDuration: Double
    static func centered(in start: Double, _ end: Double, rate: Float = defaultRate) -> SlowMotionSegment
    func clamped(to start: Double, _ end: Double, minimumDuration: Double = minimumDuration) -> SlowMotionSegment
}
final class ClipTrimmer: Sendable {
    static let minimumDuration: Double // 1.0 s
    init(clipsDirectory: URL)
    /// Re-encodes [start, end) of the source (HEVC stays HEVC) to clipsDirectory/<baseName>.mp4 plus thumbnail. Source untouched.
    /// With slowMotion, goes through an AVMutableComposition (preferredTransform carried over) and scaleTimeRange()s the segment.
    func trim(_ sourceURL: URL, start: Double, end: Double, slowMotion: SlowMotionSegment? = nil, baseName: String) async throws -> ExportedClip
    static func discard(_ exported: ExportedClip)   // remove a trim's files if the store could not record it
}

/// Speed picker shared by the player (playback rate) and editor (slow-mo rate). HighlightBot/Features/Library/SpeedMenu.swift.
enum SpeedMenu { static let playbackRates: [Float]; static func percentLabel(for rate: Float) -> String }  // 1.0, 0.5, 0.25, 0.15
struct SpeedMenuTrigger: View   // tortoise + percent; publishes its bounds via SpeedMenuAnchorKey
struct SpeedMenuList: View      // the rate list
extension View {
    /// Floats a SpeedMenuList just above the SpeedMenuTrigger inside this view while isExpanded is true.
    func speedMenuOverlay(isExpanded: Binding<Bool>, rates: [Float], selection: Float, accessibilityNoun: String = "Playback speed", onSelect: @escaping (Float) -> Void) -> some View
}

/// Tag lists that outlive clips, in UserDefaults. No Tag table: the clip list is small enough to scan.
@MainActor @Observable final class TagPreferences {
    var activeTags: [String]                 // chosen on Record; AppContainer stamps these onto every saved clip
    private(set) var rememberedTags: [String] // every custom (non-sport) tag ever added, for the picker
    func remember(_ tags: [String])
    func forget(_ tag: String)               // drop from rememberedTags; clips still using it are untouched
    func previousTags(usedOnClips: [String]) -> [String]   // remembered ∪ used ∪ active, minus sports, sorted
}

/// Shared tag UI (HighlightBot/Features/Tags/). One picker for Record, Library, and Player.
struct TagPill: View        // colored capsule; TagStyle.color(for:) gives each suggested sport a fixed color, all custom tags share one
struct TagPillRow: View     // up to `limit` pills + "+N"
struct TagPickerSheet: View // Sports (always) → Custom (previous tags, long-press to forget, + new-tag field); onSave([String]) on Done

/// DI container. Builds everything once; environment object for the app.
@MainActor @Observable final class AppContainer {
    let settings: SettingsStore
    let permissions: PermissionsManager
    let triggerBus: TriggerBus
    let tapTrigger: TapTrigger
    let hardwareTrigger: HardwareTrigger
    let coordinator: SessionCoordinator
    let pipeline: RecordingPipeline
    let clipStore: ClipStore
    let tagPreferences: TagPreferences
    let modelContainer: ModelContainer
    var sessionState: SessionState
    var metrics: PipelineMetrics
    var lastClip: ClipRecord?
    init()          // picks CaptureEngine on device, FileReplayCaptureSource in Simulator (#if targetEnvironment(simulator))
    func start() async   // registers triggers, starts coordinator.run(bus:), subscribes to events/metrics
}
```

Screens: `RecordScreen`, `LibraryScreen`, `ClipPlayerScreen`, `ClipEditorScreen`,
`SettingsScreen`, `DebugOverlay`. Navigation: `RootView` with a `TabView` (Record, Library,
Settings) — Record tab hides the tab bar while recording.

Info.plist keys required: `NSCameraUsageDescription`,
`NSMicrophoneUsageDescription`, `NSPhotoLibraryAddUsageDescription`,
`UIFileSharingEnabled = YES`, `LSSupportsOpeningDocumentsInPlace = YES`,
`UISupportedInterfaceOrientations = [LandscapeLeft, LandscapeRight]` (iPhone and iPad),
`UIRequiresFullScreen = YES`.
