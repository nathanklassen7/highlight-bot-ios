# Ball Tracking — Design

**Status:** proposed, awaiting review
**Scope of this document:** the first two deliverables of ball tracking (clip-player overlay, then live viewfinder overlay) and the interfaces that future hit/rally detection and video effects will build on.

## Summary

Track a white ping pong ball in table-tennis footage and draw it on screen. Phase 1 analyses a **saved clip** on demand and overlays the ball in `ClipPlayerScreen`. Phase 2 runs the same detector and tracker **live** on the viewfinder via the existing `FrameTap`. Both phases share one Swift package, `BallTracking`, so a single macOS command-line harness (`balltrack-lab`) exercises exactly the code the app runs, against the user's reference clip.

Detection is pluggable. Two detectors ship: Apple Vision's `VNDetectTrajectoriesRequest` (purpose-built for small balls on parabolic paths, Neural Engine accelerated) and a classical luma-difference blob detector (bright, moving, ball-sized blobs). The lab decides the default on real footage before the app wires anything up; the interface makes the choice reversible.

Every track is a time-stamped sequence of normalised positions with velocity and a track state. That is the input hit/bounce detection needs (velocity sign changes) and the input effects need (positions per frame), so the future features attach without reworking this layer.

## Goals and non-goals

Goals
- Overlay showing the tracked ball (marker + short trail) on saved clips, toggled by the user, analysed on demand and cached.
- The same overlay live on the Record screen (phase 2), toggled from Settings and the Record screen.
- Tuned for a white 40 mm ball on typical indoor tables; static camera.
- Offline harness that runs against `~/Documents/pp highlights/8b95514af4e6468faee879eb63c1dd97.mp4` (1920×1080, 50 fps, 20.4 s, 1018 frames) and produces an annotated video plus metrics.
- Interfaces ready for hit detection, rally bounds, and per-frame effects.

Non-goals (this design)
- Hit/bounce/rally detection itself. The data shape supports it; the algorithm is future work.
- Video effects on export.
- Multi-ball, moving-camera, or coloured-ball support.
- Auto-analysis of every saved clip. On demand only; a "analyse automatically" setting is a follow-up.
- Persisting live tracks alongside recordings.

## Reference footage

The clip is a wide-angle static shot from a room corner (GoPro-style, slight fisheye). The table is dark blue, walls dark grey, floor grey. The ball is roughly 8–14 px across at 1080p, motion-blurred into short streaks at 50 fps. Confounders: a player in a white shirt in the near foreground, white stools, white table edge lines, bright window on the right, black pendant lights (static). Rallies are short: flights between hits last ~0.2–0.4 s (10–20 frames), and the ball bounces on the table mid-flight.

Consequences for design: the detector needs a small minimum object size, the tracker must survive abrupt direction changes at hits and bounces, and the white shirt is the main false-positive source, so size and motion-consistency filters matter more than brightness alone.

## Key decisions

### 1. Clip player first, live second

The user chose this ordering. It also derisks: offline analysis has no real-time budget, so detector accuracy can be judged before worrying about per-frame latency on device. The live path then reuses the detector, tracker, and overlay geometry unchanged; only the frame source and the view host differ.

### 2. One package, `BallTracking`, shared by app and lab

`BallTracking/` is a new SwiftPM package (iOS 17 / macOS 14, Swift 6) containing detectors, tracker, track model, offline runner, and overlay geometry. It depends on Foundation, CoreMedia, CoreVideo, Accelerate, AVFoundation, and Vision, all of which exist on macOS, so `swift test` and the lab run on the Mac. `HighlightCore` stays untouched (it is the dependency-free state-machine package; tracking has media dependencies). The app target depends on both packages.

The lab CLI is an executable target in the same package. Its `run` command calls the same `ClipTrackRunner` the app calls, so lab results are the app's results.

### 3. Pluggable detector, default chosen by the lab

```
protocol BallDetector { func detect(pixelBuffer:time:) throws -> [BallObservation]; func reset() }
```

Two implementations:

| | `VisionTrajectoryDetector` | `LumaBlobDetector` |
| --- | --- | --- |
| Method | `VNDetectTrajectoriesRequest`, `trajectoryLength` 6, radius bounds 0.002–0.03 | Downsample Y plane 2×, abs-diff vs previous frame, keep pixels that are bright and changed, connected components, size/aspect/fill filters |
| Strengths | Apple-tuned for exactly this; Neural Engine; trajectory segments naturally end at hits (useful later) | Per-frame position with no warm-up; ~2–4 ms; fully deterministic and unit-testable on synthetic frames; tunable |
| Weaknesses | Needs ≥6 frames before emitting; may struggle with 10-frame flights and fisheye; opaque | Fails on white backgrounds; white shirt edges produce candidates; more code |

We believe the luma detector has better odds on this footage (short flights, tiny ball) and Vision has better odds of generalising to other rooms. The plan builds both, runs both through the lab on the clip, and sets `BallDetectorKind.default` from the result. A debug-only picker in the app allows field A/B later.

### 4. Tracker is a pure alpha-beta filter with hit recovery

`BallTracker` is a value type in pure Swift: constant-velocity prediction, gated nearest-candidate association, alpha-beta update, states `searching → tentative → tracking ↔ coasting`. Two additions matter for ping pong:

- **Reacquire on direction change.** If no candidate is within the prediction gate, look again around the *last position* with a wider radius and, on success, re-bootstrap velocity from that displacement. Hits and bounces reverse velocity within one frame; without this every hit drops the track.
- **Tentative confirmation.** A track needs 3 consecutive matches before it draws, so single-frame shirt noise never flashes on screen.

Kalman filtering was considered and rejected for now: the alpha-beta filter has two tunable numbers, is trivially testable, and the measurement noise here is dominated by association errors, not sensor noise.

### 5. Track storage: JSON sidecar per clip

A completed analysis is a `BallTrack` (Codable): version, detector name, frame rate, display size, and one `BallTrackFrame` per video frame. Saved to `Documents/Clips/Tracks/<clipBaseName>.track.json` (~150–250 KB for a 20 s clip). No SwiftData schema change; `ClipStore.delete` removes the sidecar with the media. The lab writes the identical format, so a lab-produced track can be dropped onto a device for inspection.

### 6. Coordinates: normalised, display-oriented, top-left origin

All positions are normalised to 0…1 of the **displayed** frame with the origin top-left. Vision reports bottom-left origin; the detector converts. Saved clips carry a `preferredTransform` (0° or 180° for this landscape-only app); `ClipTrackRunner` maps stored-frame coordinates through the transform so consumers never see it. For live frames the same helper takes the `captureRotationAngle`.

### 7. Overlay rendering

A SwiftUI `Canvas` draws a ring at the ball, a fading polyline trail for the last 0.4 s, and nothing while searching. Geometry goes through `OverlayGeometry`, which maps normalised points into a video rect. In the player the video rect is `AVMakeRect(aspectRatio:insideRect:)` over the player bounds (aspect-fit, which is what `VideoPlayer` does); on the Record screen it is computed from the source's `previewVideoGravity` (aspect-fill for the camera, aspect-fit for replay) and rotation. The overlay is `allowsHitTesting(false)` so tap-to-save keeps working.

## Architecture

```
BallTracking (SwiftPM, iOS 17 / macOS 14)
  Model/      BallObservation, BallTrackState, BallTrackFrame, BallTrack
  Tracking/   BallDetector (protocol), BallDetectorKind (factory), BallTracker, BallTrackerConfig, BallTrail
  Detectors/  VisionTrajectoryDetector, LumaBlobDetector, SampleBufferFactory
  Offline/    ClipTrackRunner (AVAssetReader → detector → tracker → BallTrack), FrameOrientation
  Overlay/    OverlayGeometry
balltrack-lab (executable in the same package)
  run      clip.mp4 → track.json, summary.json, timeline, annotated.mp4
  extract  clip.mp4 → PNG frames for labelling
  score    track.json + truth.json → recall / false-positive rate / mean error

HighlightBot (app)
  Tracking/   ClipTrackStore (sidecar I/O), ClipTrackService (@MainActor, analyse + cache + progress),
              TrackingPreferences (UserDefaults), BallTrackOverlay (Canvas)
              phase 2: BallTrackingAnalyzer (FrameAnalyzer), BallOverlayView on RecordScreen
  Features/Library/ClipPlayerScreen   ball button → analyse (progress) → overlay via VideoPlayer(videoOverlay:)
  Capture/RecordingPipeline           phase 2: preview-time SampleFanout so FrameTap sees frames before recording
```

### Data flow, phase 1 (clip player)

1. User taps the ball button in `ClipPlayerScreen`.
2. `ClipTrackService.analyze(record)` checks `ClipTrackStore.load(for:)`. Cached → overlay on immediately.
3. Otherwise a detached `.userInitiated` task runs `ClipTrackRunner.run(url:progress:isCancelled:)`. Progress (0…1) drives a pill in the player. Dismissing the player cancels.
4. Result is written to the sidecar and published; the overlay's `TimelineView(.animation)` reads `player.currentTime()` each display frame, finds the nearest `BallTrackFrame` by binary search, and draws.

### Data flow, phase 2 (live)

1. `TrackingPreferences.liveOverlayEnabled` → `AppContainer` registers a `BallTrackingAnalyzer` with `FrameTap` (unregisters when off, so cost is zero when disabled).
2. `RecordingPipeline.startPreview` installs a recorder-less `SampleFanout` so frames reach `FrameTap` during preview, not only while recording. `stopRecording` swaps back to the preview fanout rather than clearing the consumer.
3. `BallTrackingAnalyzer.analyze` runs detector + tracker + `BallTrail` and yields a `BallTrackingSnapshot` on an `AsyncStream` (buffering newest). `FrameTap` guarantees one `analyze` in flight per analyzer, so the detector and tracker need no lock.
4. `AppContainer` mirrors snapshots into observable state; `BallOverlayView` draws over `PreviewLayerView` using `OverlayGeometry(imageSize:bounds:gravity:rotationDegrees:)`.

## Interfaces (pinned)

```swift
public struct BallObservation: Sendable, Equatable {
    public var time: TimeInterval      // seconds
    public var center: CGPoint         // normalised, top-left origin
    public var radius: Double          // fraction of frame width
    public var confidence: Double      // 0…1
}

public protocol BallDetector: AnyObject, Sendable {
    var name: String { get }
    func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation]
    func reset()
}

public enum BallDetectorKind: String, Codable, CaseIterable, Sendable {
    case vision, luma
    public static var `default`: BallDetectorKind   // set by the lab evaluation task
    public func makeDetector(frameDuration: CMTime) -> any BallDetector
}

public enum BallTrackState: String, Codable, Sendable { case searching, tentative, tracking, coasting }

public struct BallTrackFrame: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var state: BallTrackState
    public var position: CGPoint?      // nil while searching
    public var velocity: CGVector?     // normalised units per second
    public var radius: Double?
    public var candidateCount: Int
    public var isVisible: Bool { get }  // computed: state == .tracking || .coasting
}

public struct BallTracker: Sendable {
    public init(config: BallTrackerConfig = .default)
    public mutating func update(time: TimeInterval, candidates: [BallObservation]) -> BallTrackFrame
    public mutating func reset()
}

public struct BallTrack: Codable, Sendable, Equatable {
    public var version: Int            // 1
    public var detector: String
    public var frameRate: Double
    public var displaySize: CGSize
    public var frames: [BallTrackFrame]           // sorted by time
    public func frame(at time: TimeInterval) -> BallTrackFrame?   // nearest within 1.5 frame periods
    public func trail(endingAt time: TimeInterval, duration: TimeInterval) -> [CGPoint]
    public var trackingFraction: Double
}

public struct ClipTrackRunner: Sendable {
    public init(detectorKind: BallDetectorKind = .default, trackerConfig: BallTrackerConfig = .default)
    public func run(url: URL,
                    progress: (@Sendable (ClipTrackProgress) -> Void)?,
                    isCancelled: @Sendable () -> Bool) async throws -> ClipTrackResult
}

public struct OverlayGeometry: Sendable, Equatable {
    public init(videoRect: CGRect)
    public init(imageSize: CGSize, bounds: CGRect, gravity: OverlayGravity, rotationDegrees: Int)
    public func point(forNormalized p: CGPoint) -> CGPoint
    public func length(forNormalizedWidthFraction r: Double) -> CGFloat
}
```

## Testing strategy

Unit (macOS, CI): tracker state machine and hit recovery on scripted candidate sequences; `OverlayGeometry` and `FrameOrientation` on known rectangles and 0/90/180/270; `LumaBlobDetector` on synthetic 420v frames with a moving white disc (expects one candidate at the disc, none for a static frame, none for a huge moving blob); `VisionTrajectoryDetector` smoke test on a synthetic parabola (no-throw, and detects if Vision cooperates with synthetic input); `BallTrack` JSON round-trip and lookup; `ClipTrackRunner` on a small generated `.mov` (created in the test with `AVAssetWriter`).

Lab, against the user's clip (the primary acceptance check, run by the orchestrator and reviewed visually):

```
swift run -c release balltrack-lab run --input "<clip>" --detector vision --out /tmp/balltrack/vision
swift run -c release balltrack-lab run --input "<clip>" --detector luma   --out /tmp/balltrack/luma
```

Each run prints frames analysed, mean/p95 detector ms, tracking fraction, number of track starts, longest continuous track, and a one-character-per-half-second ASCII timeline of track state, and writes `annotated.mp4`. Stills are pulled from the annotated video with `ffmpeg` for review in chat. Optional: `extract --every 10` writes PNGs; a hand-labelled `truth.json` (≈30 points plus "ball absent" ranges) lets `score` report recall within 2 % of frame width and false-positive frames.

Acceptance for choosing the default detector: higher tracking fraction during rallies with no sustained false track (≥ 0.5 s) on the shirt or stools, and ≤ 8 ms mean per frame in release on the Mac (a proxy; device timing is measured in phase 2).

App: phase 1 is verified on device by analysing a real clip, scrubbing to frames with the ball, and checking the ring sits on it; the lab's `annotated.mp4` is the reference for what "correct" looks like. The Simulator is not used for clip testing (user decision).

## Future hooks

- **Hits and bounces.** A `HitDetector` consumes `BallTrackFrame`s: an x-velocity sign flip while `.tracking` is a hit, a y-velocity flip from downward to upward is a table bounce. Output `RallyEvent { kind, time, position }`. With `VisionTrajectoryDetector`, trajectory boundaries (`VNTrajectoryObservation.uuid` changes) give a second signal. Rally bounds are the first hit after a long `.searching` gap to the last hit before one.
- **Effects.** `BallTrack` already has per-frame positions; an exporter can render trails/glow into a `AVMutableVideoComposition` using the same `OverlayGeometry`. Live effects would render in the Record screen `Canvas`.
- **Auto-analysis.** `ClipTrackService.analyze` is already the unit of work; a setting can invoke it from `AppContainer.handle(.clipSaved)`.
- **Triggers.** A live hit stream can feed `TriggerBus` (auto-clip on a rally end) with no coordinator changes, as the original plan anticipated.

## Risks

- **Ball too small for Vision.** `objectMinimumNormalizedRadius` accepts 0.002, but Vision's internal downsampling may lose an 8 px ball. Mitigation: the luma detector, and the lab decides before app work.
- **Luma false positives on the white shirt.** Mitigations: area cap, fill ratio, tentative confirmation, motion-consistency gating. If still noisy, restrict analysis to a region of interest around the table (a follow-up; the interface supports a `regionOfInterest` on both detectors).
- **Overlay misalignment in the player.** `VideoPlayer`'s video rect is inferred with `AVMakeRect`; if AVKit insets the content, the ring is offset. Mitigation: verify on device; fallback is hosting an `AVPlayerLayer` directly and reading `videoRect`.
- **Analysis time on device.** 1200 frames × ~5 ms ≈ 6 s plus decode. Acceptable with a progress pill; runs cancel on dismiss.
- **Live-mode thermals (phase 2).** `FrameTap` drops frames while the analyzer is busy, so load self-limits; the analyzer is unregistered when the toggle is off.

## Open decisions for the user

1. Overlay style: white ring + fading trail is the proposal; colour by state (green tracking, amber coasting) is on by default and can be turned off.
2. Whether analysis should also be offered from the Library grid (context menu) or only inside the player. Proposal: player only.
3. Whether to remember the overlay toggle across clips (`TrackingPreferences.playerOverlayEnabled`). Proposal: yes.
