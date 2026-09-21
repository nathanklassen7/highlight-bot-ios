# Ball Tracking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track a white ping pong ball in saved clips and draw it in the clip player (phase 1), then run the same tracker live on the viewfinder (phase 2), with a macOS lab CLI that validates both against the user's reference clip.

**Architecture:** A new SwiftPM package `BallTracking` holds detectors (Vision trajectories, luma blob), a pure alpha-beta `BallTracker`, the `BallTrack` result model, an offline `ClipTrackRunner`, and `OverlayGeometry`. A `balltrack-lab` executable in that package runs the runner against a file and writes an annotated video plus metrics. The app depends on the package: phase 1 adds `ClipTrackService` + a `Canvas` overlay in `ClipPlayerScreen`; phase 2 adds a `FrameAnalyzer` and an overlay on `RecordScreen`.

**Tech Stack:** Swift 6 (strict concurrency), Swift Testing, AVFoundation, Vision (`VNDetectTrajectoriesRequest`), Accelerate (vImage), CoreImage (lab only), SwiftUI `Canvas`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-09-18-ball-tracking-design.md`

**Reference clip:** `/Users/nathan.klassen/Documents/pp highlights/8b95514af4e6468faee879eb63c1dd97.mp4` (1920×1080, 50 fps, 20.37 s, 1018 frames, H.264 + AAC). Referred to below as `$CLIP`.

## Global Constraints

- Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`, as in `project.yml` and `HighlightCore/Package.swift`.
- Package platforms: `.iOS(.v17)`, `.macOS(.v14)`. Everything in `BallTracking` must compile and test on macOS.
- `HighlightCore` is not modified by this plan.
- Coordinates: normalised 0…1, top-left origin, display orientation. Radius is a fraction of frame width.
- Logging via `Log.<category>` (`OSLog`); add a `tracking` category. No `print` in app code.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) like `HighlightCoreTests`.
- Commit messages: imperative, no prefix, matching repo history (e.g. "Add BallTracking package scaffold").
- The working tree currently has unrelated uncommitted UI changes (orientation, 120 fps, REC indicator). Commit them first, or branch from a clean commit. Do not include or revert them in tracking commits.
- Inside an agent sandbox, `swift build`/`swift test` may need `--disable-sandbox`.
- Anything written only for verification (scratch scripts, lab output) lives under `/tmp`, never in the repo. Lab output directory: `/tmp/balltrack/`.
- The `.xcodeproj` is generated. Edit `project.yml`, then run `xcodegen generate`.

## Dispatch plan (subagent-driven)

Each task gets a fresh subagent with: this plan, the spec, the task text, and the "Interfaces" block. Waves run in parallel; a wave starts when the previous wave's commits are on the branch. Between tasks, the orchestrator runs the two-stage review from `superpowers:subagent-driven-development`.

| Wave | Tasks | Parallel? | Notes |
| --- | --- | --- | --- |
| 1 | 1 | no | Scaffold; everything depends on it |
| 2 | 2, 3, 4, 5 | yes (4 agents) | Tracker, geometry, two detectors; disjoint files |
| 3 | 6 | no | Runner + track model + detector factory |
| 4 | 7 | no | Lab CLI |
| 5 | 8 | no (orchestrator) | Run the lab on `$CLIP`, review stills, set default detector |
| 6 | 9, 10 | yes (2 agents) | App plumbing and player UI; interfaces pinned below |
| 7 | 11 | no | Device verification, docs |
| 8 | 12 | no | Phase 2: frames during preview, `BallTrail` |
| 9 | 13 | no | Phase 2: live analyzer |
| 10 | 14 | no | Phase 2: Record screen overlay |

---

## Task 1: `BallTracking` package scaffold, model types, test helper, CI

**Files:**
- Create: `BallTracking/Package.swift`
- Create: `BallTracking/Sources/BallTracking/Model/BallObservation.swift`
- Create: `BallTracking/Sources/BallTracking/Model/BallTrackFrame.swift`
- Create: `BallTracking/Sources/BallTracking/Tracking/BallDetector.swift`
- Create: `BallTracking/Sources/balltrack-lab/Lab.swift` (placeholder executable so the package builds; Task 7 replaces it)
- Create: `BallTracking/Tests/BallTrackingTests/Support/SyntheticFrames.swift`
- Create: `BallTracking/Tests/BallTrackingTests/SyntheticFramesTests.swift`
- Modify: `.github/workflows/core-tests.yml`

**Interfaces:**
- Produces: `BallObservation`, `BallTrackState`, `BallTrackFrame`, `BallDetector`, test helper `SyntheticFrames.make420v(...)`.

- [ ] **Step 1: Package manifest**

```swift
// BallTracking/Package.swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BallTracking",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BallTracking", targets: ["BallTracking"]),
        .executable(name: "balltrack-lab", targets: ["balltrack-lab"]),
    ],
    targets: [
        .target(
            name: "BallTracking",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "balltrack-lab",
            dependencies: ["BallTracking"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BallTrackingTests",
            dependencies: ["BallTracking"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] **Step 2: Model types**

```swift
// BallTracking/Sources/BallTracking/Model/BallObservation.swift
import CoreGraphics
import Foundation

/// One candidate ball sighting in one frame, as reported by a `BallDetector`.
/// `center` is normalised to the frame (0…1, origin top-left). `radius` is a
/// fraction of the frame width. Several observations per frame are normal;
/// `BallTracker` decides which one, if any, is the ball.
public struct BallObservation: Sendable, Equatable {
    public var time: TimeInterval
    public var center: CGPoint
    public var radius: Double
    public var confidence: Double

    public init(time: TimeInterval, center: CGPoint, radius: Double, confidence: Double) {
        self.time = time
        self.center = center
        self.radius = radius
        self.confidence = confidence
    }
}
```

```swift
// BallTracking/Sources/BallTracking/Model/BallTrackFrame.swift
import CoreGraphics
import Foundation

/// Lifecycle of the single track `BallTracker` maintains.
public enum BallTrackState: String, Codable, Sendable {
    /// No ball. Waiting for a candidate to start a tentative track.
    case searching
    /// A candidate was accepted but not yet confirmed by consecutive matches.
    case tentative
    /// Confirmed and matched this frame.
    case tracking
    /// Confirmed, but no candidate matched this frame; position is predicted.
    case coasting
}

/// The tracker's output for one video frame. Positions are normalised to the
/// displayed frame (0…1, origin top-left); velocity is in normalised units per second.
public struct BallTrackFrame: Codable, Sendable, Equatable {
    public var time: TimeInterval
    public var state: BallTrackState
    public var position: CGPoint?
    public var velocity: CGVector?
    public var radius: Double?
    public var candidateCount: Int

    public init(time: TimeInterval,
                state: BallTrackState,
                position: CGPoint?,
                velocity: CGVector?,
                radius: Double?,
                candidateCount: Int) {
        self.time = time
        self.state = state
        self.position = position
        self.velocity = velocity
        self.radius = radius
        self.candidateCount = candidateCount
    }

    /// True when an overlay should draw the ball for this frame.
    public var isVisible: Bool {
        state == .tracking || state == .coasting
    }
}
```

```swift
// BallTracking/Sources/BallTracking/Tracking/BallDetector.swift
import CoreMedia
import CoreVideo

/// Finds ball-like objects in one frame. Implementations may keep state across
/// frames (previous frame, Vision sequence handler), so a detector must only be
/// fed consecutive frames from one source, in order, from one task at a time.
public protocol BallDetector: AnyObject, Sendable {
    var name: String { get }
    /// `time` is the frame's presentation time. Returns zero or more candidates.
    func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation]
    /// Forget cross-frame state (source restarted, seek, loop).
    func reset()
}
```

- [ ] **Step 3: Placeholder executable**

```swift
// BallTracking/Sources/balltrack-lab/Lab.swift
@main
struct Lab {
    static func main() {
        print("balltrack-lab: commands arrive in a later task")
    }
}
```

- [ ] **Step 4: Synthetic-frame test helper**

```swift
// BallTracking/Tests/BallTrackingTests/Support/SyntheticFrames.swift
import CoreGraphics
import CoreVideo
import Foundation

/// Builds 420v (`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) pixel buffers
/// with a flat background and filled discs, the same format the camera and
/// `AVAssetReader` deliver.
enum SyntheticFrames {
    struct Disc {
        var center: CGPoint   // pixels
        var radius: Double    // pixels
        var luma: UInt8
    }

    static func make420v(width: Int, height: Int, background: UInt8 = 40, discs: [Disc] = []) -> CVPixelBuffer {
        precondition(width % 2 == 0 && height % 2 == 0, "420 planes need even dimensions")
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                         nil, &buffer)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed: \(status)")
        let pixelBuffer = buffer!

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        for row in 0..<height {
            memset(yBase + row * yStride, Int32(background), width)
        }
        for disc in discs {
            let r2 = disc.radius * disc.radius
            let minY = max(0, Int(disc.center.y - disc.radius) - 1)
            let maxY = min(height - 1, Int(disc.center.y + disc.radius) + 1)
            let minX = max(0, Int(disc.center.x - disc.radius) - 1)
            let maxX = min(width - 1, Int(disc.center.x + disc.radius) + 1)
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = Double(x) + 0.5 - disc.center.x
                    let dy = Double(y) + 0.5 - disc.center.y
                    if dx * dx + dy * dy <= r2 {
                        yBase[y * yStride + x] = disc.luma
                    }
                }
            }
        }

        let cbcrBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)!.assumingMemoryBound(to: UInt8.self)
        let cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        for row in 0..<(height / 2) {
            memset(cbcrBase + row * cbcrStride, 128, width) // interleaved Cb,Cr: width/2 pairs = width bytes
        }
        return pixelBuffer
    }

    /// Luma value at a pixel, for assertions.
    static func luma(of pixelBuffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        return base[y * stride + x]
    }
}
```

- [ ] **Step 5: Test for the helper**

```swift
// BallTracking/Tests/BallTrackingTests/SyntheticFramesTests.swift
import CoreGraphics
import CoreVideo
import Testing
@testable import BallTracking

struct SyntheticFramesTests {
    @Test("disc is bright, background is dark, format is 420v")
    func discAndBackground() {
        let frame = SyntheticFrames.make420v(width: 320, height: 180, background: 40,
                                             discs: [.init(center: CGPoint(x: 100, y: 90), radius: 5, luma: 230)])
        #expect(CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        #expect(SyntheticFrames.luma(of: frame, x: 100, y: 90) == 230)
        #expect(SyntheticFrames.luma(of: frame, x: 10, y: 10) == 40)
        #expect(SyntheticFrames.luma(of: frame, x: 100 + 8, y: 90) == 40)
    }
}
```

- [ ] **Step 6: Build and test**

Run: `cd BallTracking && swift build && swift test`
Expected: build succeeds; 1 test passes.

- [ ] **Step 7: CI job**

Append to `.github/workflows/core-tests.yml` (keep the existing job unchanged):

```yaml

  balltracking-test:
    name: swift build && swift test (BallTracking, macOS)
    runs-on: macos-15
    defaults:
      run:
        working-directory: BallTracking
    steps:
      - uses: actions/checkout@v4
      - name: Swift version
        run: swift --version
      - name: Build
        run: swift build
      - name: Test
        run: swift test
```

- [ ] **Step 8: Commit**

```bash
git add BallTracking .github/workflows/core-tests.yml
git commit -m "Add BallTracking package scaffold: observation and track-frame models, detector protocol, synthetic-frame test helper, CI job"
```

---

## Task 2: `BallTracker` (alpha-beta filter with hit recovery)

**Files:**
- Create: `BallTracking/Sources/BallTracking/Tracking/BallTracker.swift`
- Test: `BallTracking/Tests/BallTrackingTests/BallTrackerTests.swift`

**Interfaces:**
- Consumes: `BallObservation`, `BallTrackFrame`, `BallTrackState` (Task 1).
- Produces: `BallTrackerConfig`, `BallTracker { init(config:); mutating update(time:candidates:) -> BallTrackFrame; mutating reset() }`.

- [ ] **Step 1: Write failing tests**

```swift
// BallTracking/Tests/BallTrackingTests/BallTrackerTests.swift
import CoreGraphics
import Testing
@testable import BallTracking

struct BallTrackerTests {
    private let dt = 1.0 / 50.0

    private func obs(_ t: Double, _ x: Double, _ y: Double, confidence: Double = 0.9) -> BallObservation {
        BallObservation(time: t, center: CGPoint(x: x, y: y), radius: 0.005, confidence: confidence)
    }

    @Test("no candidates keeps searching with nil position")
    func searching() {
        var tracker = BallTracker()
        let frame = tracker.update(time: 0, candidates: [])
        #expect(frame.state == .searching)
        #expect(frame.position == nil)
        #expect(frame.isVisible == false)
    }

    @Test("confirms after three consecutive matches and converges on a constant-velocity target")
    func confirmsAndConverges() {
        var tracker = BallTracker()
        var states: [BallTrackState] = []
        var last: BallTrackFrame?
        for i in 0..<10 {
            let t = Double(i) * dt
            let x = 0.2 + 1.0 * t   // 1.0 normalised units / s
            let frame = tracker.update(time: t, candidates: [obs(t, x, 0.5)])
            states.append(frame.state)
            last = frame
        }
        #expect(states[0] == .tentative)
        #expect(states[1] == .tentative)
        #expect(states[2] == .tracking)
        #expect(states.dropFirst(2).allSatisfy { $0 == .tracking })
        let expectedX = 0.2 + 1.0 * (9 * dt)
        #expect(abs((last?.position?.x ?? 0) - expectedX) < 0.01)
        #expect(abs((last?.velocity?.dx ?? 0) - 1.0) < 0.25)
    }

    @Test("coasts through misses, then gives up after maxMisses")
    func coastsThenDrops() {
        var config = BallTrackerConfig()
        config.maxMisses = 3
        var tracker = BallTracker(config: config)
        var t = 0.0
        for _ in 0..<4 {
            _ = tracker.update(time: t, candidates: [obs(t, 0.3 + t, 0.5)])
            t += dt
        }
        let c1 = tracker.update(time: t, candidates: []); t += dt
        #expect(c1.state == .coasting)
        #expect(c1.isVisible)
        // Predicted position keeps moving at the estimated velocity.
        #expect((c1.position?.x ?? 0) > 0.3 + 3 * dt)
        _ = tracker.update(time: t, candidates: []); t += dt
        _ = tracker.update(time: t, candidates: []); t += dt
        let dropped = tracker.update(time: t, candidates: [])
        #expect(dropped.state == .searching)
    }

    @Test("survives an abrupt direction reversal (a hit)")
    func survivesReversal() {
        var tracker = BallTracker()
        var t = 0.0
        var x = 0.3
        var states: [BallTrackState] = []
        for i in 0..<20 {
            let vx = i < 10 ? 1.2 : -1.2
            x += vx * dt
            states.append(tracker.update(time: t, candidates: [obs(t, x, 0.5)]).state)
            t += dt
        }
        #expect(!states.dropFirst(3).contains(.searching))
        #expect(states.last == .tracking)
    }

    @Test("ignores a far-away spurious candidate while tracking")
    func ignoresOutlier() {
        var tracker = BallTracker()
        var t = 0.0
        for _ in 0..<5 {
            _ = tracker.update(time: t, candidates: [obs(t, 0.4 + 0.5 * t, 0.5)])
            t += dt
        }
        let truthX = 0.4 + 0.5 * t
        let frame = tracker.update(time: t, candidates: [obs(t, truthX, 0.5), obs(t, 0.9, 0.1, confidence: 1.0)])
        #expect(frame.state == .tracking)
        #expect(abs((frame.position?.x ?? 0) - truthX) < 0.01)
    }

    @Test("a tentative track dies on its first miss")
    func tentativeDies() {
        var tracker = BallTracker()
        _ = tracker.update(time: 0, candidates: [obs(0, 0.5, 0.5)])
        let frame = tracker.update(time: dt, candidates: [])
        #expect(frame.state == .searching)
    }

    @Test("a time gap larger than maxGap resets the track")
    func gapResets() {
        var tracker = BallTracker()
        var t = 0.0
        for _ in 0..<5 {
            _ = tracker.update(time: t, candidates: [obs(t, 0.5, 0.5)])
            t += dt
        }
        let frame = tracker.update(time: t + 2.0, candidates: [])
        #expect(frame.state == .searching)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd BallTracking && swift test --filter BallTrackerTests`
Expected: compile error, `BallTracker` not defined.

- [ ] **Step 3: Implement the tracker**

```swift
// BallTracking/Sources/BallTracking/Tracking/BallTracker.swift
import CoreGraphics
import Foundation

/// Tuning for `BallTracker`. Distances are normalised frame units; times are seconds.
public struct BallTrackerConfig: Sendable, Equatable {
    /// Fraction of the measurement residual applied to position each match (alpha).
    public var positionGain: Double = 0.6
    /// Fraction of the residual-derived velocity correction applied each match (beta).
    public var velocityGain: Double = 0.3
    /// Association radius around the predicted position, before adding `speed * dt`.
    public var gateRadius: Double = 0.05
    /// Wider radius around the last position used when the prediction fails,
    /// which is what happens at a hit or a bounce.
    public var reacquireRadius: Double = 0.15
    /// Consecutive matches needed before a tentative track becomes `.tracking`.
    public var confirmAfter: Int = 3
    /// Consecutive misses tolerated while confirmed before dropping to `.searching`.
    public var maxMisses: Int = 6
    /// Larger gaps between frames reset the track (source restarted, seek).
    public var maxGap: TimeInterval = 0.5

    public init() {}
    public static let `default` = BallTrackerConfig()
}

/// Single-target alpha-beta tracker: constant-velocity prediction, gated
/// nearest-candidate association, blended update. Value type; the owner
/// decides threading.
public struct BallTracker: Sendable {
    private let config: BallTrackerConfig
    private var state: BallTrackState = .searching
    private var position = CGPoint.zero
    private var velocity = CGVector.zero
    private var radius = 0.0
    private var hits = 0
    private var misses = 0
    private var lastTime: TimeInterval?

    public init(config: BallTrackerConfig = .default) {
        self.config = config
    }

    public mutating func reset() {
        state = .searching
        position = .zero
        velocity = .zero
        radius = 0
        hits = 0
        misses = 0
        lastTime = nil
    }

    public mutating func update(time: TimeInterval, candidates: [BallObservation]) -> BallTrackFrame {
        if let last = lastTime, time < last || time - last > config.maxGap {
            reset()
        }
        let dt = lastTime.map { max(0, time - $0) } ?? 0
        lastTime = time

        switch state {
        case .searching:
            if let best = candidates.max(by: { $0.confidence < $1.confidence }) {
                position = best.center
                velocity = .zero
                radius = best.radius
                hits = 1
                misses = 0
                state = .tentative
            }

        case .tentative, .tracking, .coasting:
            let previous = position
            let predicted = CGPoint(x: position.x + velocity.dx * dt, y: position.y + velocity.dy * dt)
            let speed = hypot(velocity.dx, velocity.dy)
            let gate = config.gateRadius + speed * dt

            if let match = Self.nearest(candidates, to: predicted, within: gate) {
                let residual = CGVector(dx: match.center.x - predicted.x, dy: match.center.y - predicted.y)
                position = CGPoint(x: predicted.x + config.positionGain * residual.dx,
                                   y: predicted.y + config.positionGain * residual.dy)
                if dt > 0 {
                    if hits == 1 {
                        // Second sighting: bootstrap velocity from the raw displacement.
                        velocity = CGVector(dx: (match.center.x - previous.x) / dt,
                                            dy: (match.center.y - previous.y) / dt)
                    } else {
                        velocity = CGVector(dx: velocity.dx + config.velocityGain * residual.dx / dt,
                                            dy: velocity.dy + config.velocityGain * residual.dy / dt)
                    }
                }
                radius = radius * 0.7 + match.radius * 0.3
                hits += 1
                misses = 0
                state = hits >= config.confirmAfter ? .tracking : .tentative
            } else if state != .tentative, dt > 0,
                      let match = Self.nearest(candidates, to: position, within: config.reacquireRadius) {
                // The prediction overshot because the ball changed direction (hit,
                // bounce). Restart the motion model from the last known position.
                velocity = CGVector(dx: (match.center.x - position.x) / dt,
                                    dy: (match.center.y - position.y) / dt)
                position = match.center
                radius = radius * 0.7 + match.radius * 0.3
                hits += 1
                misses = 0
                state = .tracking
            } else {
                misses += 1
                if state == .tentative || misses > config.maxMisses {
                    reset()
                    lastTime = time
                } else {
                    position = predicted
                    state = .coasting
                }
            }
        }

        return makeFrame(time: time, candidateCount: candidates.count)
    }

    private func makeFrame(time: TimeInterval, candidateCount: Int) -> BallTrackFrame {
        let hasTrack = state != .searching
        return BallTrackFrame(
            time: time,
            state: state,
            position: hasTrack ? position : nil,
            velocity: hasTrack ? velocity : nil,
            radius: hasTrack ? radius : nil,
            candidateCount: candidateCount
        )
    }

    private static func nearest(_ candidates: [BallObservation], to point: CGPoint, within radius: Double) -> BallObservation? {
        var best: BallObservation?
        var bestDistance = radius
        for candidate in candidates {
            let distance = hypot(candidate.center.x - point.x, candidate.center.y - point.y)
            if distance <= bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return best
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd BallTracking && swift test --filter BallTrackerTests`
Expected: 7 tests pass.

- [ ] **Step 5: Commit**

```bash
git add BallTracking/Sources/BallTracking/Tracking/BallTracker.swift BallTracking/Tests/BallTrackingTests/BallTrackerTests.swift
git commit -m "Add BallTracker: alpha-beta filter with tentative confirmation, coasting, and reacquire on direction change"
```

---

## Task 3: `OverlayGeometry` and `FrameOrientation`

**Files:**
- Create: `BallTracking/Sources/BallTracking/Overlay/OverlayGeometry.swift`
- Create: `BallTracking/Sources/BallTracking/Offline/FrameOrientation.swift`
- Test: `BallTracking/Tests/BallTrackingTests/OverlayGeometryTests.swift`
- Test: `BallTracking/Tests/BallTrackingTests/FrameOrientationTests.swift`

**Interfaces:**
- Consumes: `BallTrackFrame` (Task 1).
- Produces: `OverlayGravity`, `OverlayGeometry { init(videoRect:); init(imageSize:bounds:gravity:rotationDegrees:); videoRect; point(forNormalized:); length(forNormalizedWidthFraction:) }`, `FrameOrientation { init(storedSize:transform:); displaySize; normalizedPoint(_:); normalizedVector(_:); normalizedRadius(_:); apply(to: BallTrackFrame) -> BallTrackFrame; static rotate(_:clockwiseDegrees:) }`.

- [ ] **Step 1: Write failing tests**

```swift
// BallTracking/Tests/BallTrackingTests/OverlayGeometryTests.swift
import CoreGraphics
import Testing
@testable import BallTracking

struct OverlayGeometryTests {
    private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.01) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    @Test("aspect-fit letterboxes a 16:9 image in a square view")
    func aspectFit() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                                       gravity: .aspectFit, rotationDegrees: 0)
        #expect(abs(geometry.videoRect.minY - 87.5) < 0.01)
        #expect(abs(geometry.videoRect.width - 400) < 0.01)
        #expect(abs(geometry.videoRect.height - 225) < 0.01)
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 200, y: 200)))
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 87.5)))
        #expect(abs(geometry.length(forNormalizedWidthFraction: 0.01) - 4) < 0.001)
    }

    @Test("aspect-fill overflows the view and stays centred")
    func aspectFill() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 400, height: 400),
                                       gravity: .aspectFill, rotationDegrees: 0)
        #expect(abs(geometry.videoRect.height - 400) < 0.001)
        #expect(abs(geometry.videoRect.width - 711.11) < 0.1)
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0.5, y: 0.5)), CGPoint(x: 200, y: 200)))
    }

    @Test("180° rotation mirrors both axes")
    func rotated180() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                       gravity: .aspectFit, rotationDegrees: 180)
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0.1, y: 0.2)), CGPoint(x: 1728, y: 864)))
    }

    @Test("90° clockwise rotation transposes the video rect and maps corners")
    func rotated90() {
        let geometry = OverlayGeometry(imageSize: CGSize(width: 1920, height: 1080),
                                       bounds: CGRect(x: 0, y: 0, width: 1080, height: 1920),
                                       gravity: .aspectFit, rotationDegrees: 90)
        #expect(geometry.videoRect == CGRect(x: 0, y: 0, width: 1080, height: 1920))
        // Stored top-left lands at display top-right under clockwise rotation.
        #expect(close(geometry.point(forNormalized: CGPoint(x: 0, y: 0)), CGPoint(x: 1080, y: 0)))
        // Radius as a fraction of stored width maps to the display height.
        #expect(abs(geometry.length(forNormalizedWidthFraction: 0.1) - 192) < 0.001)
    }

    @Test("explicit video rect is used verbatim")
    func explicitRect() {
        let geometry = OverlayGeometry(videoRect: CGRect(x: 10, y: 20, width: 100, height: 50))
        #expect(close(geometry.point(forNormalized: CGPoint(x: 1, y: 1)), CGPoint(x: 110, y: 70)))
    }
}
```

```swift
// BallTracking/Tests/BallTrackingTests/FrameOrientationTests.swift
import CoreGraphics
import Testing
@testable import BallTracking

struct FrameOrientationTests {
    private func close(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.001) -> Bool {
        abs(a.x - b.x) < tol && abs(a.y - b.y) < tol
    }

    @Test("identity transform leaves points alone")
    func identity() {
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: .identity)
        #expect(orientation.displaySize == CGSize(width: 1920, height: 1080))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 0.25, y: 0.75)), CGPoint(x: 0.25, y: 0.75)))
        #expect(orientation.normalizedRadius(0.01) == 0.01)
    }

    @Test("180° transform mirrors both axes and flips velocity")
    func rotated180() {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: transform)
        #expect(orientation.displaySize == CGSize(width: 1920, height: 1080))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 0.25, y: 0.75)), CGPoint(x: 0.75, y: 0.25)))
        let v = orientation.normalizedVector(CGVector(dx: 1, dy: -0.5))
        #expect(abs(v.dx + 1) < 0.001 && abs(v.dy - 0.5) < 0.001)
    }

    @Test("90° clockwise transform swaps display size and maps top-left to top-right")
    func rotated90() {
        // Standard portrait transform for a 1920x1080 stored frame.
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: transform)
        #expect(orientation.displaySize == CGSize(width: 1080, height: 1920))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 0, y: 0)), CGPoint(x: 1, y: 0)))
        #expect(close(orientation.normalizedPoint(CGPoint(x: 1, y: 1)), CGPoint(x: 0, y: 1)))
        #expect(abs(orientation.normalizedRadius(0.01) - 0.01 * 1920 / 1080) < 0.0001)
    }

    @Test("apply(to:) maps a track frame's position, velocity, and radius")
    func applyToFrame() {
        let transform = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)
        let orientation = FrameOrientation(storedSize: CGSize(width: 1920, height: 1080), transform: transform)
        let frame = BallTrackFrame(time: 1, state: .tracking, position: CGPoint(x: 0.1, y: 0.2),
                                   velocity: CGVector(dx: 2, dy: 0), radius: 0.01, candidateCount: 1)
        let mapped = orientation.apply(to: frame)
        #expect(close(mapped.position!, CGPoint(x: 0.9, y: 0.8)))
        #expect(abs(mapped.velocity!.dx + 2) < 0.001)
        #expect(mapped.state == .tracking)
        let searching = BallTrackFrame(time: 1, state: .searching, position: nil, velocity: nil, radius: nil, candidateCount: 0)
        #expect(orientation.apply(to: searching) == searching)
    }

    @Test("static rotate covers the four quadrants")
    func rotateHelper() {
        let p = CGPoint(x: 0.1, y: 0.2)
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 0), p))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 90), CGPoint(x: 0.8, y: 0.1)))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 180), CGPoint(x: 0.9, y: 0.8)))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: 270), CGPoint(x: 0.2, y: 0.9)))
        #expect(close(FrameOrientation.rotate(p, clockwiseDegrees: -90), CGPoint(x: 0.2, y: 0.9)))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd BallTracking && swift test --filter "OverlayGeometryTests|FrameOrientationTests"`
Expected: compile errors for missing types.

- [ ] **Step 3: Implement `FrameOrientation`**

```swift
// BallTracking/Sources/BallTracking/Offline/FrameOrientation.swift
import CoreGraphics
import Foundation

/// Maps stored-frame coordinates to display coordinates for a video track with a
/// `preferredTransform`. Detectors see the stored frame; overlays see the displayed
/// one. Everything stays normalised (0…1, origin top-left).
public struct FrameOrientation: Sendable, Equatable {
    public let storedSize: CGSize
    public let transform: CGAffineTransform
    public let displaySize: CGSize
    private let displayOrigin: CGPoint

    public init(storedSize: CGSize, transform: CGAffineTransform) {
        self.storedSize = storedSize
        self.transform = transform
        let rect = CGRect(origin: .zero, size: storedSize).applying(transform)
        displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
        displayOrigin = rect.origin
    }

    public func normalizedPoint(_ p: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: p.x * storedSize.width, y: p.y * storedSize.height).applying(transform)
        return CGPoint(x: (pixel.x - displayOrigin.x) / displaySize.width,
                       y: (pixel.y - displayOrigin.y) / displaySize.height)
    }

    public func normalizedVector(_ v: CGVector) -> CGVector {
        let dx = v.dx * storedSize.width
        let dy = v.dy * storedSize.height
        let rx = dx * transform.a + dy * transform.c
        let ry = dx * transform.b + dy * transform.d
        return CGVector(dx: rx / displaySize.width, dy: ry / displaySize.height)
    }

    public func normalizedRadius(_ r: Double) -> Double {
        r * storedSize.width / displaySize.width
    }

    public func apply(to frame: BallTrackFrame) -> BallTrackFrame {
        var mapped = frame
        mapped.position = frame.position.map(normalizedPoint)
        mapped.velocity = frame.velocity.map(normalizedVector)
        mapped.radius = frame.radius.map(normalizedRadius)
        return mapped
    }

    /// Rotates a normalised top-left-origin point by a multiple of 90° clockwise,
    /// i.e. the way the displayed image is rotated relative to the stored one.
    public static func rotate(_ p: CGPoint, clockwiseDegrees: Int) -> CGPoint {
        switch ((clockwiseDegrees % 360) + 360) % 360 {
        case 90: return CGPoint(x: 1 - p.y, y: p.x)
        case 180: return CGPoint(x: 1 - p.x, y: 1 - p.y)
        case 270: return CGPoint(x: p.y, y: 1 - p.x)
        default: return p
        }
    }
}
```

- [ ] **Step 4: Implement `OverlayGeometry`**

```swift
// BallTracking/Sources/BallTracking/Overlay/OverlayGeometry.swift
import CoreGraphics
import Foundation

public enum OverlayGravity: Sendable, Equatable {
    /// Letterbox: the whole frame is visible (`AVLayerVideoGravity.resizeAspect`).
    case aspectFit
    /// Crop: the frame fills the view (`AVLayerVideoGravity.resizeAspectFill`).
    case aspectFill
}

/// Maps normalised frame coordinates to points in a view that shows the frame.
public struct OverlayGeometry: Sendable, Equatable {
    /// Where the (rotated) frame sits in the view. Can exceed the view for aspect-fill.
    public let videoRect: CGRect
    /// Clockwise rotation applied to the stored frame for display; 0 when the
    /// coordinates are already display-oriented (saved clips).
    public let rotationDegrees: Int

    /// For coordinates that are already display-oriented and a known video rect
    /// (e.g. `AVMakeRect(aspectRatio:insideRect:)` for a player).
    public init(videoRect: CGRect) {
        self.videoRect = videoRect
        rotationDegrees = 0
    }

    /// For stored-orientation frames shown by a preview layer with `gravity` in
    /// `bounds`, rotated `rotationDegrees` clockwise (0/90/180/270).
    public init(imageSize: CGSize, bounds: CGRect, gravity: OverlayGravity, rotationDegrees: Int) {
        let degrees = ((rotationDegrees % 360) + 360) % 360
        let transposed = degrees == 90 || degrees == 270
        let rotatedSize = transposed ? CGSize(width: imageSize.height, height: imageSize.width) : imageSize
        videoRect = Self.fit(rotatedSize, in: bounds, gravity: gravity)
        self.rotationDegrees = degrees
    }

    public func point(forNormalized p: CGPoint) -> CGPoint {
        let r = FrameOrientation.rotate(p, clockwiseDegrees: rotationDegrees)
        return CGPoint(x: videoRect.minX + r.x * videoRect.width,
                       y: videoRect.minY + r.y * videoRect.height)
    }

    /// Converts a length given as a fraction of the stored frame's width.
    public func length(forNormalizedWidthFraction r: Double) -> CGFloat {
        let transposed = rotationDegrees == 90 || rotationDegrees == 270
        return CGFloat(r) * (transposed ? videoRect.height : videoRect.width)
    }

    static func fit(_ size: CGSize, in bounds: CGRect, gravity: OverlayGravity) -> CGRect {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let sx = bounds.width / size.width
        let sy = bounds.height / size.height
        let scale = gravity == .aspectFit ? min(sx, sy) : max(sx, sy)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd BallTracking && swift test --filter "OverlayGeometryTests|FrameOrientationTests"`
Expected: 10 tests pass.

- [ ] **Step 6: Commit**

```bash
git add BallTracking/Sources/BallTracking/Overlay BallTracking/Sources/BallTracking/Offline/FrameOrientation.swift BallTracking/Tests/BallTrackingTests/OverlayGeometryTests.swift BallTracking/Tests/BallTrackingTests/FrameOrientationTests.swift
git commit -m "Add OverlayGeometry and FrameOrientation for mapping normalised track coordinates to views"
```

---

## Task 4: `VisionTrajectoryDetector`

**Files:**
- Create: `BallTracking/Sources/BallTracking/Detectors/SampleBufferFactory.swift`
- Create: `BallTracking/Sources/BallTracking/Detectors/VisionTrajectoryDetector.swift`
- Test: `BallTracking/Tests/BallTrackingTests/VisionTrajectoryDetectorTests.swift`

**Interfaces:**
- Consumes: `BallDetector`, `BallObservation` (Task 1); `SyntheticFrames` (tests).
- Produces: `VisionTrajectoryDetector { struct Config; init(config:) }`, `SampleBufferFactory.make(pixelBuffer:time:duration:) throws -> CMSampleBuffer`.

Vision's stateful requests throttle on sample-buffer timestamps, so the pixel buffer is wrapped in a `CMSampleBuffer` carrying the PTS.

- [ ] **Step 1: Write failing test**

```swift
// BallTracking/Tests/BallTrackingTests/VisionTrajectoryDetectorTests.swift
import CoreGraphics
import CoreMedia
import Testing
@testable import BallTracking

struct VisionTrajectoryDetectorTests {
    @Test("wraps a pixel buffer in a timed sample buffer")
    func sampleBufferFactory() throws {
        let frame = SyntheticFrames.make420v(width: 320, height: 180)
        let time = CMTime(value: 30, timescale: 60)
        let sample = try SampleBufferFactory.make(pixelBuffer: frame, time: time, duration: CMTime(value: 1, timescale: 60))
        #expect(CMSampleBufferGetPresentationTimeStamp(sample) == time)
        #expect(CMSampleBufferGetImageBuffer(sample) != nil)
    }

    @Test("detects a synthetic ball on a parabolic path without throwing")
    func syntheticParabola() throws {
        let detector = VisionTrajectoryDetector(config: .init(trajectoryLength: 5,
                                                              minimumNormalizedRadius: 0.002,
                                                              maximumNormalizedRadius: 0.05,
                                                              frameDuration: CMTime(value: 1, timescale: 60)))
        var all: [BallObservation] = []
        for i in 0..<60 {
            let t = Double(i) / 60
            let x = 40 + 800 * t
            let y = 400 - 900 * t + 1400 * t * t
            let frame = SyntheticFrames.make420v(width: 960, height: 540, background: 30,
                                                 discs: [.init(center: CGPoint(x: x, y: y), radius: 6, luma: 235)])
            let observations = try detector.detect(pixelBuffer: frame, time: CMTime(value: CMTimeValue(i), timescale: 60))
            all.append(contentsOf: observations)
        }
        // Vision needs `trajectoryLength` frames before reporting; afterwards it
        // should have seen the disc. If this assertion fails on synthetic input
        // while the lab (Task 8) detects on real footage, relax it to `>= 0` and
        // say so in the commit message.
        #expect(!all.isEmpty)
        for observation in all {
            #expect((0...1).contains(observation.center.x))
            #expect((0...1).contains(observation.center.y))
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd BallTracking && swift test --filter VisionTrajectoryDetectorTests`
Expected: compile errors.

- [ ] **Step 3: Implement the sample buffer factory**

```swift
// BallTracking/Sources/BallTracking/Detectors/SampleBufferFactory.swift
import CoreMedia
import CoreVideo
import Foundation

public enum SampleBufferError: Error, Equatable {
    case formatDescription(OSStatus)
    case sampleBuffer(OSStatus)
}

/// Wraps a pixel buffer and presentation time into a `CMSampleBuffer`, which is
/// what Vision's stateful requests need to reason about time.
public enum SampleBufferFactory {
    public static func make(pixelBuffer: CVPixelBuffer, time: CMTime, duration: CMTime) throws -> CMSampleBuffer {
        var formatDescription: CMVideoFormatDescription?
        var status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr, let formatDescription else { throw SampleBufferError.formatDescription(status) }

        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw SampleBufferError.sampleBuffer(status) }
        return sampleBuffer
    }
}
```

- [ ] **Step 4: Implement the detector**

```swift
// BallTracking/Sources/BallTracking/Detectors/VisionTrajectoryDetector.swift
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Vision

/// Apple Vision's trajectory detector. Reports the newest point of every
/// trajectory Vision is currently following. Vision keeps state per sequence
/// handler, so feed one instance one ordered frame stream from one task at a time.
/// `@unchecked Sendable`: mutable members are only touched inside `detect`/`reset`,
/// which callers serialise (see `BallDetector`).
public final class VisionTrajectoryDetector: BallDetector, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Points needed before Vision reports a trajectory. Minimum 5. Short ping
        /// pong flights (10–20 frames) argue for the low end.
        public var trajectoryLength: Int = 6
        /// Ball radius bounds as a fraction of the frame. A 40 mm ball 3–5 m away
        /// at 1080p is roughly 0.003–0.007.
        public var minimumNormalizedRadius: Float = 0.002
        public var maximumNormalizedRadius: Float = 0.03
        /// Frame period; used as Vision's real-time budget hint and the sample duration.
        public var frameDuration: CMTime = CMTime(value: 1, timescale: 60)

        public init() {}
        public init(trajectoryLength: Int, minimumNormalizedRadius: Float, maximumNormalizedRadius: Float, frameDuration: CMTime) {
            self.trajectoryLength = trajectoryLength
            self.minimumNormalizedRadius = minimumNormalizedRadius
            self.maximumNormalizedRadius = maximumNormalizedRadius
            self.frameDuration = frameDuration
        }
        public static let `default` = Config()
    }

    public let name = "vision-trajectory"
    private let config: Config
    private var handler = VNSequenceRequestHandler()
    private let request: VNDetectTrajectoriesRequest

    public init(config: Config = .default) {
        self.config = config
        request = VNDetectTrajectoriesRequest(frameAnalysisSpacing: .zero,
                                              trajectoryLength: max(5, config.trajectoryLength),
                                              completionHandler: nil)
        request.objectMinimumNormalizedRadius = config.minimumNormalizedRadius
        request.objectMaximumNormalizedRadius = config.maximumNormalizedRadius
        request.targetFrameTime = config.frameDuration
    }

    public func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation] {
        let sample = try SampleBufferFactory.make(pixelBuffer: pixelBuffer, time: time, duration: config.frameDuration)
        try handler.perform([request], on: sample, orientation: .up)
        guard let results = request.results else { return [] }
        let seconds = time.seconds
        return results.compactMap { trajectory in
            guard let last = trajectory.detectedPoints.last else { return nil }
            // Vision uses a bottom-left origin; we use top-left.
            return BallObservation(time: seconds,
                                   center: CGPoint(x: last.x, y: 1 - last.y),
                                   radius: Double(trajectory.movingAverageRadius),
                                   confidence: Double(trajectory.confidence))
        }
    }

    public func reset() {
        handler = VNSequenceRequestHandler()
    }
}
```

- [ ] **Step 5: Run tests**

Run: `cd BallTracking && swift test --filter VisionTrajectoryDetectorTests`
Expected: 2 tests pass (see the note in the test if `syntheticParabola` fails).

- [ ] **Step 6: Commit**

```bash
git add BallTracking/Sources/BallTracking/Detectors/SampleBufferFactory.swift BallTracking/Sources/BallTracking/Detectors/VisionTrajectoryDetector.swift BallTracking/Tests/BallTrackingTests/VisionTrajectoryDetectorTests.swift
git commit -m "Add VisionTrajectoryDetector wrapping VNDetectTrajectoriesRequest"
```

---

## Task 5: `LumaBlobDetector`

**Files:**
- Create: `BallTracking/Sources/BallTracking/Detectors/LumaBlobDetector.swift`
- Test: `BallTracking/Tests/BallTrackingTests/LumaBlobDetectorTests.swift`

**Interfaces:**
- Consumes: `BallDetector`, `BallObservation` (Task 1); `SyntheticFrames` (tests).
- Produces: `LumaBlobDetector { struct Config; init(config:) }`.

Method: downsample the Y plane (bright ball = high luma), difference against the previous frame (the ball moves, the room does not), keep pixels that are both bright and changed, connected components, keep ball-sized round-ish blobs.

- [ ] **Step 1: Write failing tests**

```swift
// BallTracking/Tests/BallTrackingTests/LumaBlobDetectorTests.swift
import CoreGraphics
import CoreMedia
import Testing
@testable import BallTracking

struct LumaBlobDetectorTests {
    private func time(_ i: Int) -> CMTime { CMTime(value: CMTimeValue(i), timescale: 50) }

    @Test("first frame yields nothing; a moving disc yields one candidate at the disc")
    func movingDisc() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 116, y: 176), radius: 4, luma: 230)])
        #expect(try detector.detect(pixelBuffer: f0, time: time(0)).isEmpty)
        let candidates = try detector.detect(pixelBuffer: f1, time: time(1))
        #expect(candidates.count == 1)
        let c = candidates[0]
        #expect(abs(c.center.x - 116.0 / 640.0) < 0.01)
        #expect(abs(c.center.y - 176.0 / 360.0) < 0.015)
        #expect(c.radius > 0.003 && c.radius < 0.012)
        #expect(c.time == time(1).seconds)
    }

    @Test("a static bright disc produces no candidates")
    func staticDisc() throws {
        let detector = LumaBlobDetector()
        let frame = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 300, y: 100), radius: 5, luma: 240)])
        _ = try detector.detect(pixelBuffer: frame, time: time(0))
        #expect(try detector.detect(pixelBuffer: frame, time: time(1)).isEmpty)
    }

    @Test("a large moving bright shape (a shirt) is rejected by the area cap")
    func largeBlobRejected() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 200, y: 200), radius: 60, luma: 220)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 230, y: 200), radius: 60, luma: 220)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        #expect(try detector.detect(pixelBuffer: f1, time: time(1)).isEmpty)
    }

    @Test("a dark moving disc is ignored")
    func darkDiscIgnored() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, background: 120, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 20)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, background: 120, discs: [.init(center: CGPoint(x: 120, y: 180), radius: 4, luma: 20)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        #expect(try detector.detect(pixelBuffer: f1, time: time(1)).isEmpty)
    }

    @Test("reset forgets the previous frame")
    func resetForgets() throws {
        let detector = LumaBlobDetector()
        let f0 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 100, y: 180), radius: 4, luma: 230)])
        let f1 = SyntheticFrames.make420v(width: 640, height: 360, discs: [.init(center: CGPoint(x: 116, y: 180), radius: 4, luma: 230)])
        _ = try detector.detect(pixelBuffer: f0, time: time(0))
        detector.reset()
        #expect(try detector.detect(pixelBuffer: f1, time: time(1)).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd BallTracking && swift test --filter LumaBlobDetectorTests`
Expected: compile errors.

- [ ] **Step 3: Implement**

```swift
// BallTracking/Sources/BallTracking/Detectors/LumaBlobDetector.swift
import Accelerate
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Classical detector for a bright ball on a darker, mostly static background.
/// Works on the Y plane of 420 buffers only (no colour conversion).
/// `@unchecked Sendable`: scratch buffers are only touched inside `detect`/`reset`,
/// which callers serialise (see `BallDetector`).
public final class LumaBlobDetector: BallDetector, @unchecked Sendable {
    public struct Config: Sendable, Equatable {
        /// Integer downsample factor applied to the luma plane before analysis.
        public var downsample: Int = 2
        /// Minimum luma (video range 16…235) for a pixel to count as "bright".
        public var minLuma: UInt8 = 150
        /// Minimum |Y − Y_previous| for a pixel to count as "moving".
        public var minMotion: UInt8 = 20
        /// Blob area bounds in analysis-resolution pixels. A 10 px ball at 1080p is
        /// ~20 px² at 540p; motion blur streaks are larger.
        public var minArea: Int = 3
        public var maxArea: Int = 400
        /// Bounding-box long/short side; streaks are allowed, walls are not.
        public var maxAspect: Double = 3.5
        /// area / bboxArea; rejects thin edge fragments.
        public var minFill: Double = 0.3
        public var maxCandidates: Int = 8

        public init() {}
        public static let `default` = Config()
    }

    public let name = "luma-blob"
    private let config: Config

    private var width = 0
    private var height = 0
    private var fullWidth = 0
    private var fullHeight = 0
    private var current: [UInt8] = []
    private var previous: [UInt8] = []
    private var mask: [UInt8] = []
    private var labels: [Int32] = []
    private var stack: [Int32] = []
    private var hasPrevious = false

    public init(config: Config = .default) {
        self.config = config
    }

    public func reset() {
        hasPrevious = false
    }

    public func detect(pixelBuffer: CVPixelBuffer, time: CMTime) throws -> [BallObservation] {
        let planar = CVPixelBufferIsPlanar(pixelBuffer)
        let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
        let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard planar, CVPixelBufferGetPlaneCount(pixelBuffer) >= 1, srcWidth > 0, srcHeight > 0 else { return [] }

        let ds = max(1, config.downsample)
        let w = srcWidth / ds
        let h = srcHeight / ds
        if w != width || h != height || srcWidth != fullWidth || srcHeight != fullHeight {
            width = w; height = h; fullWidth = srcWidth; fullHeight = srcHeight
            current = [UInt8](repeating: 0, count: w * h)
            previous = [UInt8](repeating: 0, count: w * h)
            mask = [UInt8](repeating: 0, count: w * h)
            labels = [Int32](repeating: 0, count: w * h)
            stack.reserveCapacity(4096)
            hasPrevious = false
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return [] }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)

        var src = vImage_Buffer(data: base, height: vImagePixelCount(srcHeight), width: vImagePixelCount(srcWidth), rowBytes: stride)
        let scaleError: vImage_Error = current.withUnsafeMutableBufferPointer { dst in
            var dstBuffer = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            return vImageScale_Planar8(&src, &dstBuffer, nil, vImage_Flags(kvImageNoFlags))
        }
        guard scaleError == kvImageNoError else { return [] }

        defer { swap(&current, &previous); hasPrevious = true }
        guard hasPrevious else { return [] }

        buildMask()
        let blobs = labelBlobs()
        let seconds = time.seconds
        let fw = Double(fullWidth), fh = Double(fullHeight), scale = Double(ds)

        var observations: [BallObservation] = blobs.compactMap { blob in
            guard blob.area >= config.minArea, blob.area <= config.maxArea else { return nil }
            let bw = Double(blob.maxX - blob.minX + 1)
            let bh = Double(blob.maxY - blob.minY + 1)
            let aspect = max(bw, bh) / min(bw, bh)
            guard aspect <= config.maxAspect else { return nil }
            let fill = Double(blob.area) / (bw * bh)
            guard fill >= config.minFill else { return nil }
            let cx = (Double(blob.sumX) / Double(blob.area) + 0.5) * scale
            let cy = (Double(blob.sumY) / Double(blob.area) + 0.5) * scale
            let radiusPixels = (Double(blob.area) / .pi).squareRoot() * scale
            let meanLuma = Double(blob.sumLuma) / Double(blob.area)
            let confidence = min(1, meanLuma / 235) * fill
            return BallObservation(time: seconds,
                                   center: CGPoint(x: cx / fw, y: cy / fh),
                                   radius: radiusPixels / fw,
                                   confidence: confidence)
        }
        observations.sort { $0.confidence > $1.confidence }
        if observations.count > config.maxCandidates {
            observations.removeLast(observations.count - config.maxCandidates)
        }
        return observations
    }

    // MARK: - Internals

    private func buildMask() {
        let minLuma = config.minLuma
        let minMotion = Int(config.minMotion)
        current.withUnsafeBufferPointer { cur in
            previous.withUnsafeBufferPointer { prev in
                mask.withUnsafeMutableBufferPointer { out in
                    for i in 0..<cur.count {
                        let y = cur[i]
                        let d = abs(Int(y) - Int(prev[i]))
                        out[i] = (y >= minLuma && d >= minMotion) ? 1 : 0
                    }
                }
            }
        }
    }

    private struct Blob {
        var area = 0
        var minX = Int.max, maxX = Int.min, minY = Int.max, maxY = Int.min
        var sumX = 0, sumY = 0, sumLuma = 0
    }

    /// 4-connected components over `mask`. Blobs that grow past 4× `maxArea` are
    /// still flooded (so they are labelled) but discarded early.
    private func labelBlobs() -> [Blob] {
        let w = width, h = height
        let discardAbove = config.maxArea * 4
        var blobs: [Blob] = []
        labels.withUnsafeMutableBufferPointer { lab in
            lab.update(repeating: 0)
        }
        var nextLabel: Int32 = 1
        for start in 0..<(w * h) where mask[start] != 0 && labels[start] == 0 {
            var blob = Blob()
            var discard = false
            stack.removeAll(keepingCapacity: true)
            stack.append(Int32(start))
            labels[start] = nextLabel

            func visit(_ j: Int) {
                if mask[j] != 0 && labels[j] == 0 {
                    labels[j] = nextLabel
                    stack.append(Int32(j))
                }
            }

            while let popped = stack.popLast() {
                let i = Int(popped)
                let x = i % w, y = i / w
                blob.area += 1
                if !discard {
                    blob.minX = min(blob.minX, x); blob.maxX = max(blob.maxX, x)
                    blob.minY = min(blob.minY, y); blob.maxY = max(blob.maxY, y)
                    blob.sumX += x; blob.sumY += y; blob.sumLuma += Int(current[i])
                    if blob.area > discardAbove { discard = true }
                }
                if x > 0 { visit(i - 1) }
                if x + 1 < w { visit(i + 1) }
                if y > 0 { visit(i - w) }
                if y + 1 < h { visit(i + w) }
            }
            if !discard { blobs.append(blob) }
            nextLabel &+= 1
        }
        return blobs
    }
}
```

- [ ] **Step 4: Run tests**

Run: `cd BallTracking && swift test --filter LumaBlobDetectorTests`
Expected: 5 tests pass. If `movingDisc` reports two candidates (the disc's old and new positions both differ from the previous frame), that is expected physics: the *old* position is now dark, so it fails `minLuma`; only the new position passes. If it still fails, check that the mask uses `current` (not `previous`) for the luma test.

- [ ] **Step 5: Commit**

```bash
git add BallTracking/Sources/BallTracking/Detectors/LumaBlobDetector.swift BallTracking/Tests/BallTrackingTests/LumaBlobDetectorTests.swift
git commit -m "Add LumaBlobDetector: bright moving blob detection on the downsampled luma plane"
```

---

## Task 6: `BallTrack` model, `BallDetectorKind` factory, `ClipTrackRunner`

**Files:**
- Create: `BallTracking/Sources/BallTracking/Model/BallTrack.swift`
- Create: `BallTracking/Sources/BallTracking/Tracking/BallDetectorKind.swift`
- Create: `BallTracking/Sources/BallTracking/Offline/ClipTrackRunner.swift`
- Test: `BallTracking/Tests/BallTrackingTests/BallTrackTests.swift`
- Test: `BallTracking/Tests/BallTrackingTests/ClipTrackRunnerTests.swift`
- Test helper: `BallTracking/Tests/BallTrackingTests/Support/SyntheticMovie.swift`

**Interfaces:**
- Consumes: Tasks 1–5.
- Produces: `BallTrack`, `BallDetectorKind { vision, luma; static var default; makeDetector(frameDuration:) }`, `ClipTrackProgress`, `ClipTrackResult`, `ClipTrackError`, `ClipTrackRunner { init(detectorKind:trackerConfig:); init(detectorName:trackerConfig:makeDetector:); run(url:progress:isCancelled:) async throws -> ClipTrackResult }`.

- [ ] **Step 1: Write failing tests**

```swift
// BallTracking/Tests/BallTrackingTests/BallTrackTests.swift
import CoreGraphics
import Foundation
import Testing
@testable import BallTracking

struct BallTrackTests {
    private func frame(_ t: Double, _ state: BallTrackState, x: Double = 0.5) -> BallTrackFrame {
        BallTrackFrame(time: t, state: state,
                       position: state == .searching ? nil : CGPoint(x: x, y: 0.5),
                       velocity: state == .searching ? nil : CGVector(dx: 1, dy: 0),
                       radius: state == .searching ? nil : 0.005, candidateCount: 1)
    }

    private var sample: BallTrack {
        BallTrack(version: BallTrack.currentVersion, detector: "luma-blob", frameRate: 50,
                  displaySize: CGSize(width: 1920, height: 1080),
                  frames: [
                      frame(0.00, .searching),
                      frame(0.02, .tentative, x: 0.10),
                      frame(0.04, .tentative, x: 0.12),
                      frame(0.06, .tracking, x: 0.14),
                      frame(0.08, .tracking, x: 0.16),
                      frame(0.10, .coasting, x: 0.18),
                      frame(0.12, .tracking, x: 0.20),
                      frame(0.14, .searching),
                  ])
    }

    @Test("round-trips through JSON")
    func jsonRoundTrip() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(BallTrack.self, from: data)
        #expect(decoded == sample)
    }

    @Test("frame(at:) returns the nearest frame within 1.5 periods, else nil")
    func nearestFrame() {
        let track = sample
        #expect(track.frame(at: 0.061)?.time == 0.06)
        #expect(track.frame(at: 0.071)?.time == 0.08)
        #expect(track.frame(at: 0.139)?.time == 0.14)
        #expect(track.frame(at: 0.5) == nil)
        #expect(track.frame(at: -0.5) == nil)
    }

    @Test("trail collects tracking positions back to the last searching frame")
    func trail() {
        let trail = sample.trail(endingAt: 0.12, duration: 0.2)
        #expect(trail == [CGPoint(x: 0.14, y: 0.5), CGPoint(x: 0.16, y: 0.5), CGPoint(x: 0.20, y: 0.5)])
        #expect(sample.trail(endingAt: 0.12, duration: 0.05).count == 2)
        #expect(sample.trail(endingAt: 0.14, duration: 1).isEmpty)
    }

    @Test("tracking fraction counts only .tracking frames")
    func fraction() {
        #expect(abs(sample.trackingFraction - 3.0 / 8.0) < 0.0001)
        #expect(BallTrack(version: 1, detector: "x", frameRate: 50, displaySize: .zero, frames: []).trackingFraction == 0)
    }
}
```

```swift
// BallTracking/Tests/BallTrackingTests/Support/SyntheticMovie.swift
import AVFoundation
import CoreGraphics
import Foundation

/// Writes a short H.264 movie of a white disc moving over a dark background so
/// `ClipTrackRunner` can be tested end to end on macOS.
enum SyntheticMovie {
    static func write(to url: URL, width: Int = 640, height: Int = 360, frames: Int = 40, fps: Int32 = 50,
                      transform: CGAffineTransform = .identity,
                      position: (Int) -> CGPoint) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        precondition(writer.canAdd(input))
        writer.add(input)
        precondition(writer.startWriting(), "startWriting: \(String(describing: writer.error))")
        writer.startSession(atSourceTime: .zero)

        for i in 0..<frames {
            let frame = SyntheticFrames.make420v(width: width, height: height, background: 30,
                                                 discs: [.init(center: position(i), radius: 5, luma: 235)])
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(2))
            }
            precondition(adaptor.append(frame, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        precondition(writer.status == .completed, "finishWriting: \(String(describing: writer.error))")
    }
}
```

```swift
// BallTracking/Tests/BallTrackingTests/ClipTrackRunnerTests.swift
import CoreGraphics
import CoreMedia
import Foundation
import os
import Testing
@testable import BallTracking

struct ClipTrackRunnerTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "balltracking-tests-\(name)-\(UUID().uuidString).mov")
    }

    @Test("tracks a synthetic ball across a generated movie with the luma detector")
    func tracksSyntheticMovie() async throws {
        let url = temporaryURL("straight")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticMovie.write(to: url) { i in CGPoint(x: 40 + Double(i) * 12, y: 180) }

        let runner = ClipTrackRunner(detectorKind: .luma)
        let reported = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let result = try await runner.run(url: url,
                                          progress: { progress in reported.withLock { $0.append(progress.fraction) } },
                                          isCancelled: { false })

        #expect(result.track.frames.count == 40)
        #expect(result.track.detector == "luma")
        #expect(abs(result.track.frameRate - 50) < 0.5)
        #expect(result.track.displaySize == CGSize(width: 640, height: 360))
        #expect(result.track.trackingFraction > 0.6)
        let last = result.track.frames.last!
        #expect(last.state == .tracking)
        #expect(abs((last.position?.x ?? 0) - (40 + 39 * 12) / 640) < 0.03)
        #expect(result.meanDetectMillis > 0)
        let fractions = reported.withLock { $0 }
        #expect(!fractions.isEmpty)
        #expect(fractions.last == 1.0)
    }

    @Test("applies the track's preferredTransform so positions are display-oriented")
    func appliesTransform() async throws {
        let url = temporaryURL("rotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let rotate180 = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 640, ty: 360)
        try await SyntheticMovie.write(to: url, transform: rotate180) { i in CGPoint(x: 40 + Double(i) * 12, y: 100) }

        let result = try await ClipTrackRunner(detectorKind: .luma).run(url: url, progress: nil, isCancelled: { false })
        let last = result.track.frames.last!
        #expect(last.state == .tracking)
        // Stored x ≈ 508/640 = 0.79 → displayed 0.21; stored y 100/360 = 0.28 → 0.72.
        #expect(abs((last.position?.x ?? 0) - (1 - 508.0 / 640.0)) < 0.03)
        #expect(abs((last.position?.y ?? 0) - (1 - 100.0 / 360.0)) < 0.03)
    }

    @Test("cancellation throws and stops early")
    func cancels() async throws {
        let url = temporaryURL("cancel")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticMovie.write(to: url) { i in CGPoint(x: 40 + Double(i) * 12, y: 180) }
        await #expect(throws: ClipTrackError.cancelled) {
            _ = try await ClipTrackRunner(detectorKind: .luma).run(url: url, progress: nil, isCancelled: { true })
        }
    }

    @Test("missing file surfaces an error")
    func missingFile() async {
        let url = temporaryURL("missing")
        await #expect(throws: (any Error).self) {
            _ = try await ClipTrackRunner(detectorKind: .luma).run(url: url, progress: nil, isCancelled: { false })
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd BallTracking && swift test --filter "BallTrackTests|ClipTrackRunnerTests"`
Expected: compile errors.

- [ ] **Step 3: Implement `BallTrack`**

```swift
// BallTracking/Sources/BallTracking/Model/BallTrack.swift
import CoreGraphics
import Foundation

/// A complete analysis of one video: one `BallTrackFrame` per decoded frame, in
/// display orientation. Persisted as JSON next to the clip.
public struct BallTrack: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var detector: String
    public var frameRate: Double
    /// Pixel size of the displayed frame (after `preferredTransform`).
    public var displaySize: CGSize
    /// Sorted by `time`.
    public var frames: [BallTrackFrame]

    public init(version: Int, detector: String, frameRate: Double, displaySize: CGSize, frames: [BallTrackFrame]) {
        self.version = version
        self.detector = detector
        self.frameRate = frameRate
        self.displaySize = displaySize
        self.frames = frames
    }

    /// Index of the frame whose time is closest to `time`, or nil when empty.
    public func index(nearest time: TimeInterval) -> Int? {
        guard !frames.isEmpty else { return nil }
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time < time { low = mid + 1 } else { high = mid }
        }
        if low > 0, abs(frames[low - 1].time - time) < abs(frames[low].time - time) {
            return low - 1
        }
        return low
    }

    /// Nearest frame within 1.5 frame periods of `time`.
    public func frame(at time: TimeInterval) -> BallTrackFrame? {
        guard let i = index(nearest: time) else { return nil }
        let tolerance = 1.5 / max(frameRate, 1)
        return abs(frames[i].time - time) <= tolerance ? frames[i] : nil
    }

    /// Tracking positions from `time - duration` up to `time`, oldest first,
    /// stopping at the most recent `.searching` frame so a trail never spans a lost ball.
    public func trail(endingAt time: TimeInterval, duration: TimeInterval) -> [CGPoint] {
        guard let end = index(nearest: time) else { return [] }
        var points: [CGPoint] = []
        var i = end
        while i >= 0, time - frames[i].time <= duration {
            let frame = frames[i]
            if frame.state == .searching { break }
            if frame.state == .tracking, let position = frame.position {
                points.append(position)
            }
            i -= 1
        }
        points.reverse()
        return points
    }

    public var trackingFraction: Double {
        guard !frames.isEmpty else { return 0 }
        return Double(frames.filter { $0.state == .tracking }.count) / Double(frames.count)
    }
}
```

- [ ] **Step 4: Implement `BallDetectorKind`**

```swift
// BallTracking/Sources/BallTracking/Tracking/BallDetectorKind.swift
import CoreMedia
import Foundation

/// The detectors the app and lab can choose between.
public enum BallDetectorKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case vision
    case luma

    public var id: String { rawValue }

    /// Detector used when nothing else is specified. Set by the lab evaluation
    /// (plan Task 8) after comparing both on real footage.
    public static let `default`: BallDetectorKind = .vision

    public var displayName: String {
        switch self {
        case .vision: "Vision trajectories"
        case .luma: "Luma blobs"
        }
    }

    public func makeDetector(frameDuration: CMTime) -> any BallDetector {
        switch self {
        case .vision:
            var config = VisionTrajectoryDetector.Config()
            config.frameDuration = frameDuration
            return VisionTrajectoryDetector(config: config)
        case .luma:
            return LumaBlobDetector()
        }
    }
}
```

- [ ] **Step 5: Implement `ClipTrackRunner`**

```swift
// BallTracking/Sources/BallTracking/Offline/ClipTrackRunner.swift
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public struct ClipTrackProgress: Sendable, Equatable {
    public var framesDone: Int
    public var estimatedTotal: Int
    public var fraction: Double
}

public struct ClipTrackResult: Sendable {
    public var track: BallTrack
    public var meanDetectMillis: Double
    public var p95DetectMillis: Double
    public var wallSeconds: Double
    public var detectErrors: Int
}

public enum ClipTrackError: Error, LocalizedError, Equatable {
    case noVideoTrack
    case readerFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noVideoTrack: "The video has no video track."
        case .readerFailed(let message): "Could not read the video: \(message)"
        case .cancelled: "Analysis was cancelled."
        }
    }
}

/// Decodes a movie file frame by frame and runs a detector plus `BallTracker`
/// over it. Used by the app for saved clips and by `balltrack-lab`.
public struct ClipTrackRunner: Sendable {
    public let detectorName: String
    private let trackerConfig: BallTrackerConfig
    private let makeDetector: @Sendable (CMTime) -> any BallDetector

    public init(detectorKind: BallDetectorKind = .default, trackerConfig: BallTrackerConfig = .default) {
        self.init(detectorName: detectorKind.rawValue, trackerConfig: trackerConfig) { frameDuration in
            detectorKind.makeDetector(frameDuration: frameDuration)
        }
    }

    public init(detectorName: String,
                trackerConfig: BallTrackerConfig = .default,
                makeDetector: @escaping @Sendable (CMTime) -> any BallDetector) {
        self.detectorName = detectorName
        self.trackerConfig = trackerConfig
        self.makeDetector = makeDetector
    }

    /// Blocks a background queue for the whole decode; call from a detached task.
    /// `progress` fires roughly every 10 frames and once at the end.
    public func run(url: URL,
                    progress: (@Sendable (ClipTrackProgress) -> Void)? = nil,
                    isCancelled: @escaping @Sendable () -> Bool = { false }) async throws -> ClipTrackResult {
        let asset = AVURLAsset(url: url)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipTrackError.noVideoTrack
        }
        let (naturalSize, transform, nominalFrameRate, minFrameDuration) =
            try await videoTrack.load(.naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration)
        let duration = try await asset.load(.duration)

        let frameDuration = (minFrameDuration.isNumeric && minFrameDuration.seconds > 0)
            ? minFrameDuration : CMTime(value: 1, timescale: 60)
        let frameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : 1 / frameDuration.seconds
        let estimatedTotal = max(1, Int((duration.seconds * frameRate).rounded()))
        let orientation = FrameOrientation(storedSize: naturalSize, transform: transform)

        // AVFoundation objects are safe to hand to one other queue; the compiler cannot prove it.
        nonisolated(unsafe) let assetRef = asset
        nonisolated(unsafe) let trackRef = videoTrack
        let detectorName = self.detectorName
        let trackerConfig = self.trackerConfig
        let makeDetector = self.makeDetector

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try Self.process(asset: assetRef, videoTrack: trackRef,
                                                  detectorName: detectorName,
                                                  detector: makeDetector(frameDuration),
                                                  trackerConfig: trackerConfig,
                                                  orientation: orientation,
                                                  frameRate: frameRate,
                                                  estimatedTotal: estimatedTotal,
                                                  progress: progress,
                                                  isCancelled: isCancelled)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func process(asset: AVURLAsset,
                                videoTrack: AVAssetTrack,
                                detectorName: String,
                                detector: any BallDetector,
                                trackerConfig: BallTrackerConfig,
                                orientation: FrameOrientation,
                                frameRate: Double,
                                estimatedTotal: Int,
                                progress: (@Sendable (ClipTrackProgress) -> Void)?,
                                isCancelled: @Sendable () -> Bool) throws -> ClipTrackResult {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ClipTrackError.readerFailed("cannot add track output") }
        reader.add(output)
        guard reader.startReading() else {
            throw ClipTrackError.readerFailed(reader.error?.localizedDescription ?? "startReading returned false")
        }

        var tracker = BallTracker(config: trackerConfig)
        var frames: [BallTrackFrame] = []
        frames.reserveCapacity(estimatedTotal)
        var detectMillis: [Double] = []
        detectMillis.reserveCapacity(estimatedTotal)
        var detectErrors = 0
        let wallStart = ContinuousClock.now

        while let sample = output.copyNextSampleBuffer() {
            if isCancelled() {
                reader.cancelReading()
                throw ClipTrackError.cancelled
            }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)

            let detectStart = ContinuousClock.now
            var candidates: [BallObservation] = []
            do {
                candidates = try detector.detect(pixelBuffer: pixelBuffer, time: pts)
            } catch {
                detectErrors += 1
            }
            detectMillis.append((ContinuousClock.now - detectStart).millis)

            let frame = tracker.update(time: pts.seconds, candidates: candidates)
            frames.append(orientation.apply(to: frame))

            if frames.count % 10 == 0 {
                let fraction = min(0.99, Double(frames.count) / Double(estimatedTotal))
                progress?(ClipTrackProgress(framesDone: frames.count, estimatedTotal: estimatedTotal, fraction: fraction))
            }
        }
        if reader.status == .failed {
            throw ClipTrackError.readerFailed(reader.error?.localizedDescription ?? "reader failed")
        }
        progress?(ClipTrackProgress(framesDone: frames.count, estimatedTotal: frames.count, fraction: 1.0))

        let sorted = detectMillis.sorted()
        let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]

        let track = BallTrack(version: BallTrack.currentVersion,
                              detector: detectorName,
                              frameRate: frameRate,
                              displaySize: orientation.displaySize,
                              frames: frames)
        return ClipTrackResult(track: track,
                               meanDetectMillis: mean,
                               p95DetectMillis: p95,
                               wallSeconds: (ContinuousClock.now - wallStart).seconds,
                               detectErrors: detectErrors)
    }
}

extension Duration {
    var millis: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
```

- [ ] **Step 6: Run tests**

Run: `cd BallTracking && swift test`
Expected: all tests pass, including the 4 runner tests (they write to the temp directory and take a few seconds for H.264 encoding).

- [ ] **Step 7: Commit**

```bash
git add BallTracking
git commit -m "Add BallTrack model, BallDetectorKind factory, and ClipTrackRunner for offline analysis of movie files"
```

---

## Task 7: `balltrack-lab` CLI

**Files:**
- Replace: `BallTracking/Sources/balltrack-lab/Lab.swift`
- Create: `BallTracking/Sources/balltrack-lab/Options.swift`
- Create: `BallTracking/Sources/balltrack-lab/RunCommand.swift`
- Create: `BallTracking/Sources/balltrack-lab/AnnotatedVideoWriter.swift`
- Create: `BallTracking/Sources/balltrack-lab/ExtractCommand.swift`
- Create: `BallTracking/Sources/balltrack-lab/ScoreCommand.swift`

**Interfaces:**
- Consumes: `ClipTrackRunner`, `BallTrack`, `BallDetectorKind`, `LumaBlobDetector.Config`, `VisionTrajectoryDetector.Config`, `OverlayGeometry`.
- Produces: commands `run`, `extract`, `score`. Output files: `track.json` (a `BallTrack`), `summary.json`, `annotated.mp4`.

- [ ] **Step 1: Option parsing and entry point**

```swift
// BallTracking/Sources/balltrack-lab/Options.swift
import Foundation

/// Minimal `--key value` / `--flag` parser. No positional arguments.
struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            guard arg.hasPrefix("--") else { i += 1; continue }
            let key = String(arg.dropFirst(2))
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                values[key] = args[i + 1]
                i += 2
            } else {
                flags.insert(key)
                i += 1
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }

    func required(_ key: String) throws -> String {
        guard let value = values[key] else { throw LabError.usage("missing --\(key)") }
        return value
    }

    func int(_ key: String, default fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func double(_ key: String, default fallback: Double) -> Double { values[key].flatMap(Double.init) ?? fallback }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

enum LabError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message): "usage error: \(message)"
        case .failed(let message): message
        }
    }
}

func expandPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}
```

```swift
// BallTracking/Sources/balltrack-lab/Lab.swift
import Foundation

@main
struct Lab {
    static let usage = """
    balltrack-lab — run the HighlightBot ball tracker against a movie file.

    Commands:
      run     --input clip.mp4 --out DIR [--detector vision|luma|default] [--no-annotate]
              [--trajectory-length N] [--min-luma N] [--min-motion N] [--max-area N]
              Writes DIR/track.json, DIR/summary.json, DIR/annotated.mp4 and prints a summary.
      extract --input clip.mp4 --out DIR [--every N] [--start SEC] [--end SEC]
              Writes PNG frames named fNNNNN_tSS.SSS.png for labelling.
      score   --track DIR/track.json --truth truth.json [--tolerance 0.02]
              Reports recall, mean error, and false-positive frames against hand labels.
    """

    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            print(usage)
            exit(2)
        }
        args.removeFirst()
        let options = Options(args)
        do {
            switch command {
            case "run": try await RunCommand(options: options).run()
            case "extract": try await ExtractCommand(options: options).run()
            case "score": try ScoreCommand(options: options).run()
            case "help", "--help", "-h": print(usage)
            default:
                print(usage)
                throw LabError.usage("unknown command \(command)")
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(1)
        }
    }
}
```

- [ ] **Step 2: `run` command**

```swift
// BallTracking/Sources/balltrack-lab/RunCommand.swift
import BallTracking
import CoreMedia
import Foundation
import os

struct RunSummary: Codable {
    var input: String
    var detector: String
    var frames: Int
    var durationSeconds: Double
    var frameRate: Double
    var meanDetectMillis: Double
    var p95DetectMillis: Double
    var wallSeconds: Double
    var realtimeFactor: Double
    var trackingFraction: Double
    var visibleFraction: Double
    var trackStarts: Int
    var longestTrackingRunSeconds: Double
    var meanCandidatesPerFrame: Double
    var detectErrors: Int
}

struct RunCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let detectorArg = options.string("detector") ?? "default"
        let runner = try makeRunner(detectorArg)

        print("Analysing \(input.lastPathComponent) with \(runner.detectorName)…")
        let lastPrinted = OSAllocatedUnfairLock(initialState: -1)
        let result = try await runner.run(url: input, progress: { progress in
            let percent = Int(progress.fraction * 100)
            let shouldPrint = lastPrinted.withLock { last -> Bool in
                guard percent / 10 != last / 10 else { return false }
                last = percent
                return true
            }
            if shouldPrint {
                print("  \(percent)% (\(progress.framesDone) frames)")
            }
        }, isCancelled: { false })

        let track = result.track
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(track).write(to: outDir.appending(path: "track.json"))

        let summary = Self.summarise(result, input: input)
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        try pretty.encode(summary).write(to: outDir.appending(path: "summary.json"))

        print(Self.describe(summary))
        print(Self.timeline(track))

        if !options.flag("no-annotate") {
            let annotated = outDir.appending(path: "annotated.mp4")
            print("Writing \(annotated.path)…")
            try await AnnotatedVideoWriter(input: input, track: track, output: annotated).write()
        }
        print("Done. Output in \(outDir.path)")
    }

    private func makeRunner(_ detectorArg: String) throws -> ClipTrackRunner {
        switch detectorArg {
        case "default":
            return ClipTrackRunner(detectorKind: .default)
        case "vision":
            let trajectoryLength = options.int("trajectory-length", default: VisionTrajectoryDetector.Config.default.trajectoryLength)
            return ClipTrackRunner(detectorName: "vision") { frameDuration in
                var config = VisionTrajectoryDetector.Config()
                config.trajectoryLength = trajectoryLength
                config.frameDuration = frameDuration
                return VisionTrajectoryDetector(config: config)
            }
        case "luma":
            var config = LumaBlobDetector.Config()
            config.minLuma = UInt8(clamping: options.int("min-luma", default: Int(config.minLuma)))
            config.minMotion = UInt8(clamping: options.int("min-motion", default: Int(config.minMotion)))
            config.maxArea = options.int("max-area", default: config.maxArea)
            return ClipTrackRunner(detectorName: "luma") { _ in LumaBlobDetector(config: config) }
        default:
            throw LabError.usage("--detector must be vision, luma, or default")
        }
    }

    static func summarise(_ result: ClipTrackResult, input: URL) -> RunSummary {
        let track = result.track
        let frames = track.frames
        let duration = frames.count > 1 ? frames.last!.time - frames.first!.time : 0

        var starts = 0
        var previousState = BallTrackState.searching
        var runStart: TimeInterval?
        var longestRun = 0.0
        for frame in frames {
            if frame.state == .tracking && previousState != .tracking && previousState != .coasting {
                starts += 1
            }
            if frame.isVisible {
                if runStart == nil { runStart = frame.time }
                longestRun = max(longestRun, frame.time - (runStart ?? frame.time))
            } else {
                runStart = nil
            }
            previousState = frame.state
        }

        return RunSummary(
            input: input.path,
            detector: track.detector,
            frames: frames.count,
            durationSeconds: duration,
            frameRate: track.frameRate,
            meanDetectMillis: result.meanDetectMillis,
            p95DetectMillis: result.p95DetectMillis,
            wallSeconds: result.wallSeconds,
            realtimeFactor: result.wallSeconds > 0 ? duration / result.wallSeconds : 0,
            trackingFraction: track.trackingFraction,
            visibleFraction: frames.isEmpty ? 0 : Double(frames.filter(\.isVisible).count) / Double(frames.count),
            trackStarts: starts,
            longestTrackingRunSeconds: longestRun,
            meanCandidatesPerFrame: frames.isEmpty ? 0 : Double(frames.map(\.candidateCount).reduce(0, +)) / Double(frames.count),
            detectErrors: result.detectErrors
        )
    }

    static func describe(_ s: RunSummary) -> String {
        """

        detector            \(s.detector)
        frames              \(s.frames) (\(String(format: "%.2f", s.durationSeconds)) s @ \(String(format: "%.1f", s.frameRate)) fps)
        detect ms           mean \(String(format: "%.2f", s.meanDetectMillis))  p95 \(String(format: "%.2f", s.p95DetectMillis))  errors \(s.detectErrors)
        wall                \(String(format: "%.1f", s.wallSeconds)) s (\(String(format: "%.1f", s.realtimeFactor))× realtime)
        tracking fraction   \(String(format: "%.1f", s.trackingFraction * 100))%   visible \(String(format: "%.1f", s.visibleFraction * 100))%
        track starts        \(s.trackStarts)
        longest run         \(String(format: "%.2f", s.longestTrackingRunSeconds)) s
        candidates/frame    \(String(format: "%.2f", s.meanCandidatesPerFrame))
        """
    }

    /// One character per half second: '#' ≥75 % visible, '+' ≥25 %, '.' otherwise.
    static func timeline(_ track: BallTrack, bucket: TimeInterval = 0.5) -> String {
        guard let first = track.frames.first?.time, let last = track.frames.last?.time, last > first else { return "" }
        let buckets = Int(((last - first) / bucket).rounded(.up))
        var visible = [Int](repeating: 0, count: buckets)
        var total = [Int](repeating: 0, count: buckets)
        for frame in track.frames {
            let b = min(buckets - 1, Int((frame.time - first) / bucket))
            total[b] += 1
            if frame.isVisible { visible[b] += 1 }
        }
        var chars = ""
        var scale = ""
        for b in 0..<buckets {
            let f = total[b] == 0 ? 0 : Double(visible[b]) / Double(total[b])
            chars.append(f >= 0.75 ? "#" : f >= 0.25 ? "+" : ".")
            scale.append(b % 10 == 0 ? "|" : " ")
        }
        return "\ntimeline (0.5 s per char; | every 5 s)\n\(chars)\n\(scale)\n"
    }
}
```

- [ ] **Step 3: Annotated video writer**

```swift
// BallTracking/Sources/balltrack-lab/AnnotatedVideoWriter.swift
import AVFoundation
import BallTracking
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Re-reads the input in display orientation (BGRA, via a video composition so
/// `preferredTransform` is applied) and writes an H.264 copy with the track drawn on.
struct AnnotatedVideoWriter {
    let input: URL
    let track: BallTrack
    let output: URL

    func write() async throws {
        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LabError.failed("no video track")
        }
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        let size = composition.renderSize
        let width = Int(size.width.rounded()), height = Int(size.height.rounded())

        nonisolated(unsafe) let assetRef = asset
        nonisolated(unsafe) let trackRef = videoTrack
        nonisolated(unsafe) let compositionRef = composition
        let track = self.track
        let output = self.output

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.process(asset: assetRef, videoTrack: trackRef, composition: compositionRef,
                                     width: width, height: height, track: track, output: output)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func process(asset: AVURLAsset, videoTrack: AVAssetTrack, composition: AVVideoComposition,
                                width: Int, height: Int, track: BallTrack, output: URL) throws {
        try? FileManager.default.removeItem(at: output)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        readerOutput.videoComposition = composition
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw LabError.failed("cannot add reader output") }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw LabError.failed("cannot add writer input") }
        writer.add(input)

        guard reader.startReading() else { throw LabError.failed(reader.error?.localizedDescription ?? "reader failed") }
        guard writer.startWriting() else { throw LabError.failed(writer.error?.localizedDescription ?? "writer failed") }
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.cacheIntermediates: false])
        let geometry = OverlayGeometry(videoRect: CGRect(x: 0, y: 0, width: width, height: height))
        var index = 0

        while let sample = readerOutput.copyNextSampleBuffer() {
            guard let source = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard let pool = adaptor.pixelBufferPool else { throw LabError.failed("no pixel buffer pool") }
            var destination: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination)
            guard let destination else { throw LabError.failed("pool exhausted") }

            ciContext.render(CIImage(cvPixelBuffer: source), to: destination)
            draw(on: destination, width: width, height: height, geometry: geometry,
                 frame: track.frame(at: pts.seconds),
                 trail: track.trail(endingAt: pts.seconds, duration: 0.4),
                 index: index, time: pts.seconds)

            while !input.isReadyForMoreMediaData { usleep(2_000) }
            guard adaptor.append(destination, withPresentationTime: pts) else {
                throw LabError.failed(writer.error?.localizedDescription ?? "append failed")
            }
            index += 1
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw LabError.failed(writer.error?.localizedDescription ?? "finishWriting failed") }
    }

    private static func draw(on pixelBuffer: CVPixelBuffer, width: Int, height: Int, geometry: OverlayGeometry,
                             frame: BallTrackFrame?, trail: [CGPoint], index: Int, time: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let context = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // CoreGraphics is bottom-left; flip so our top-left coordinates draw upright.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        if trail.count > 1 {
            context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.8))
            context.setLineWidth(3)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.beginPath()
            context.move(to: geometry.point(forNormalized: trail[0]))
            for p in trail.dropFirst() { context.addLine(to: geometry.point(forNormalized: p)) }
            context.strokePath()
        }

        if let frame, frame.isVisible, let position = frame.position {
            let center = geometry.point(forNormalized: position)
            let radius = max(10, geometry.length(forNormalizedWidthFraction: frame.radius ?? 0.005) * 2.5)
            let color = frame.state == .tracking
                ? CGColor(red: 0.2, green: 1, blue: 0.3, alpha: 1)
                : CGColor(red: 1, green: 0.6, blue: 0.1, alpha: 1)
            context.setStrokeColor(color)
            context.setLineWidth(4)
            context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        }

        let state = frame?.state.rawValue ?? "—"
        let label = String(format: "f%05d  t%.3f  %@  cands=%d", index, time, state, frame?.candidateCount ?? 0)
        drawText(label, in: context, at: CGPoint(x: 16, y: 16), height: height)
    }

    private static func drawText(_ text: String, in context: CGContext, at origin: CGPoint, height: Int) {
        let font = CTFontCreateWithName("Menlo" as CFString, 28, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 0.2, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])
        let box = CGRect(x: origin.x - 6, y: origin.y - 4, width: bounds.width + 12, height: bounds.height + 8)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        context.fill(box)
        // Text draws in CG's native orientation; undo the flip locally.
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y + bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = CGPoint(x: 0, y: -bounds.minY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
```

- [ ] **Step 4: `extract` and `score` commands**

```swift
// BallTracking/Sources/balltrack-lab/ExtractCommand.swift
import AVFoundation
import CoreImage
import Foundation

/// Dumps every Nth frame as PNG (display orientation) for hand labelling.
struct ExtractCommand {
    let options: Options

    func run() async throws {
        let input = expandPath(try options.required("input"))
        let outDir = expandPath(try options.required("out"))
        let every = max(1, options.int("every", default: 10))
        let start = options.double("start", default: 0)
        let end = options.double("end", default: .infinity)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let asset = AVURLAsset(url: input)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LabError.failed("no video track")
        }
        let composition = try await AVVideoComposition.videoComposition(withPropertiesOf: asset)
        nonisolated(unsafe) let assetRef = asset
        nonisolated(unsafe) let trackRef = videoTrack
        nonisolated(unsafe) let compositionRef = composition

        let written: Int = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let reader = try AVAssetReader(asset: assetRef)
                    let output = AVAssetReaderVideoCompositionOutput(videoTracks: [trackRef], videoSettings: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    ])
                    output.videoComposition = compositionRef
                    reader.add(output)
                    guard reader.startReading() else { throw LabError.failed("reader failed") }
                    let ciContext = CIContext()
                    var index = 0
                    var count = 0
                    while let sample = output.copyNextSampleBuffer() {
                        defer { index += 1 }
                        let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        guard index % every == 0, t >= start, t <= end,
                              let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                        let image = CIImage(cvPixelBuffer: pixelBuffer)
                        let url = outDir.appending(path: String(format: "f%05d_t%.3f.png", index, t))
                        try ciContext.writePNGRepresentation(of: image, to: url, format: .BGRA8,
                                                             colorSpace: CGColorSpaceCreateDeviceRGB())
                        count += 1
                    }
                    continuation.resume(returning: count)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        print("Wrote \(written) frames to \(outDir.path)")
    }
}
```

```swift
// BallTracking/Sources/balltrack-lab/ScoreCommand.swift
import BallTracking
import CoreGraphics
import Foundation

/// Hand labels. `points` are ball centres (normalised, top-left origin) at given
/// times; `absent` are time ranges where no ball is in play.
struct GroundTruth: Codable {
    struct Point: Codable { var time: Double; var x: Double; var y: Double }
    struct Range: Codable { var start: Double; var end: Double }
    var points: [Point]
    var absent: [Range]
}

struct ScoreCommand {
    let options: Options

    func run() throws {
        let trackURL = expandPath(try options.required("track"))
        let truthURL = expandPath(try options.required("truth"))
        let tolerance = options.double("tolerance", default: 0.02)

        let track = try JSONDecoder().decode(BallTrack.self, from: Data(contentsOf: trackURL))
        let truth = try JSONDecoder().decode(GroundTruth.self, from: Data(contentsOf: truthURL))

        var hits = 0
        var errors: [Double] = []
        for point in truth.points {
            guard let frame = track.frame(at: point.time), frame.isVisible, let position = frame.position else { continue }
            let error = hypot(position.x - point.x, position.y - point.y)
            if error <= tolerance {
                hits += 1
                errors.append(error)
            }
        }

        var absentFrames = 0
        var falsePositives = 0
        for frame in track.frames where truth.absent.contains(where: { frame.time >= $0.start && frame.time <= $0.end }) {
            absentFrames += 1
            if frame.isVisible { falsePositives += 1 }
        }

        let recall = truth.points.isEmpty ? 0 : Double(hits) / Double(truth.points.count)
        let meanError = errors.isEmpty ? 0 : errors.reduce(0, +) / Double(errors.count)
        let fpRate = absentFrames == 0 ? 0 : Double(falsePositives) / Double(absentFrames)
        print(String(format: "labelled points   %d", truth.points.count))
        print(String(format: "recall            %.1f%% (%d within %.3f)", recall * 100, hits, tolerance))
        print(String(format: "mean error        %.4f (fraction of frame)", meanError))
        print(String(format: "absent frames     %d, visible in %d (%.1f%% false-positive rate)", absentFrames, falsePositives, fpRate * 100))
    }
}
```

- [ ] **Step 5: Build and smoke-run against a generated movie**

Run:
```bash
cd BallTracking && swift build -c release
swift run -c release balltrack-lab help
```
Expected: usage text. Then verify `run` end to end on a synthetic movie produced by the test helper — easiest is to run the runner tests (which write and delete temp movies) and separately confirm the CLI handles a real file in Task 8. Alternatively run `swift run -c release balltrack-lab run --input "$CLIP" --detector luma --out /tmp/balltrack/smoke --no-annotate` now; it should print the summary and timeline without error.

- [ ] **Step 6: Commit**

```bash
git add BallTracking/Sources/balltrack-lab
git commit -m "Add balltrack-lab CLI: run, extract, and score commands with annotated video output"
```

---

## Task 8: Evaluate both detectors on the reference clip and set the default

**Files:**
- Modify: `BallTracking/Sources/BallTracking/Tracking/BallDetectorKind.swift` (the `default` constant, if luma wins)
- Possibly modify: detector `Config` defaults after tuning
- Create: `docs/superpowers/specs/2026-09-18-ball-tracking-lab-results.md`

Performed by the orchestrator (it can view images). Output goes under `/tmp/balltrack/`.

- [ ] **Step 1: Run both detectors**

```bash
CLIP="/Users/nathan.klassen/Documents/pp highlights/8b95514af4e6468faee879eb63c1dd97.mp4"
cd BallTracking
swift run -c release balltrack-lab run --input "$CLIP" --detector vision --out /tmp/balltrack/vision
swift run -c release balltrack-lab run --input "$CLIP" --detector luma   --out /tmp/balltrack/luma
```
Expected: both finish; each prints the summary block and the ASCII timeline and writes `annotated.mp4`.

- [ ] **Step 2: Pull stills for review**

Pick times where the ball is in flight (from the timeline's `#` regions; the frame at t≈9.0 s has the ball near the far player's paddle) and where it is not (first ~0.5 s):

```bash
for d in vision luma; do
  for t in 3.0 9.0 9.1 9.2 12.0 16.0; do
    ffmpeg -v error -y -ss $t -i /tmp/balltrack/$d/annotated.mp4 -frames:v 1 /tmp/balltrack/$d/still_$t.png
  done
done
```
Read the stills. For each detector note: ring on the ball (yes/no), ring on the shirt/stools/window (yes/no), trail plausibility.

- [ ] **Step 3: Decide**

Decision rule (from the spec): prefer the detector with the higher `trackingFraction` during rallies that shows no sustained false track (≥ 0.5 s continuous `#` in a region with no ball) and stays ≤ 8 ms mean detect time in release. If both are poor, tune before deciding:
- luma: `--min-luma 130`, `--min-motion 12`, `--max-area 800` (streaks), and, if the shirt creates tracks, raise `minFill` to 0.45 in `Config` and re-run.
- vision: `--trajectory-length 5`; if nothing is detected, check `objectMaximumNormalizedRadius` isn't excluding streaks (raise to 0.05).
Persist any winning tuning into the `Config` defaults in code, not only on the command line.

- [ ] **Step 4: Set the default detector**

If luma wins, change in `BallDetectorKind.swift`:
```swift
    public static let `default`: BallDetectorKind = .luma
```

- [ ] **Step 5: Record results**

Write `docs/superpowers/specs/2026-09-18-ball-tracking-lab-results.md` containing: the two summary blocks verbatim, the two timelines, a sentence per still on what was seen, the tuning applied, the decision, and the exact commands used. Keep stills out of the repo.

- [ ] **Step 6: Run all tests and commit**

```bash
cd BallTracking && swift test
git add BallTracking docs/superpowers/specs/2026-09-18-ball-tracking-lab-results.md
git commit -m "Choose default ball detector from lab evaluation on reference clip"
```

---

## Task 9: App plumbing — package dependency, sidecar store, `ClipTrackService`, preferences

**Files:**
- Modify: `project.yml` (packages + dependency)
- Modify: `HighlightBot/Support/AppDirectories.swift` (add `tracks`)
- Modify: `HighlightBot/Support/Log.swift` (add `tracking`)
- Modify: `HighlightBot/App/Clip.swift` (add `ClipRecord.trackURL`)
- Modify: `HighlightBot/App/ClipStore.swift` (delete sidecar with clip)
- Create: `HighlightBot/Tracking/ClipTrackStore.swift`
- Create: `HighlightBot/Tracking/ClipTrackService.swift`
- Create: `HighlightBot/Tracking/TrackingPreferences.swift`
- Modify: `HighlightBot/App/AppContainer.swift` (own the service and preferences)
- Modify: `HighlightBot/Features/Settings/SettingsScreen.swift` (Debug → detector picker)

**Interfaces:**
- Consumes: `BallTrack`, `BallDetectorKind`, `ClipTrackRunner`, `ClipTrackError` (package).
- Produces (pinned for Task 10):
  - `enum ClipTrackStatus: Equatable { case none; case analyzing(fraction: Double); case ready(BallTrack); case failed(String) }`
  - `@MainActor @Observable final class ClipTrackService { func status(for: ClipRecord) -> ClipTrackStatus; func loadCached(for: ClipRecord); func analyze(_ record: ClipRecord); func cancel(_ record: ClipRecord) }`
  - `@MainActor @Observable final class TrackingPreferences { var playerOverlayEnabled: Bool; var detectorKind: BallDetectorKind }`
  - `AppContainer.clipTracks: ClipTrackService`, `AppContainer.trackingPreferences: TrackingPreferences`
  - `ClipRecord.trackURL: URL`

- [ ] **Step 1: Package dependency**

In `project.yml`, under `packages:` add:
```yaml
  BallTracking:
    path: BallTracking
```
Under `targets.HighlightBot.dependencies:` add:
```yaml
      - package: BallTracking
```
Run `xcodegen generate`.

- [ ] **Step 2: Directories, logging, URLs**

`AppDirectories.swift`, after `thumbnails`:
```swift
    /// Documents/Clips/Tracks — ball-track JSON sidecars, one per analysed clip.
    static var tracks: URL {
        ensure(clips.appending(path: "Tracks", directoryHint: .isDirectory))
    }
```

`Log.swift`, after `ui`:
```swift
    static let tracking = Logger(subsystem: subsystem, category: "tracking")
```

`Clip.swift`, inside `extension ClipRecord`:
```swift
    /// Absolute URL of the ball-track sidecar (`AppDirectories.tracks/<baseName>.track.json`).
    var trackURL: URL {
        let baseName = (fileName as NSString).deletingPathExtension
        return AppDirectories.tracks.appending(path: baseName + ".track.json")
    }
```

`ClipStore.swift`, in `removeFiles(for:)`, change the URL list:
```swift
        var urls = [record.fileURL, record.trackURL]
```

- [ ] **Step 3: Sidecar store**

```swift
// HighlightBot/Tracking/ClipTrackStore.swift
import BallTracking
import Foundation
import HighlightCore

/// Reads and writes `BallTrack` JSON sidecars for clips. Plain file I/O; callers
/// choose the thread.
enum ClipTrackStore {
    static func load(for record: ClipRecord) -> BallTrack? {
        let url = record.trackURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let track = try JSONDecoder().decode(BallTrack.self, from: Data(contentsOf: url))
            guard track.version == BallTrack.currentVersion else {
                Log.tracking.notice("Ignoring track sidecar with version \(track.version) for \(record.fileName, privacy: .public)")
                return nil
            }
            return track
        } catch {
            Log.tracking.error("Failed to read track for \(record.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func save(_ track: BallTrack, for record: ClipRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(track).write(to: record.trackURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Preferences**

```swift
// HighlightBot/Tracking/TrackingPreferences.swift
import BallTracking
import Foundation
import Observation

/// Ball-tracking settings that are not part of `RecordingConfig`. Backed by
/// `UserDefaults` so they survive relaunches.
@MainActor
@Observable
final class TrackingPreferences {
    private enum Key {
        static let playerOverlay = "tracking.playerOverlayEnabled"
        static let liveOverlay = "tracking.liveOverlayEnabled"
        static let detector = "tracking.detectorKind"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Whether the clip player shows the ball overlay once a track exists.
    var playerOverlayEnabled: Bool {
        didSet { defaults.set(playerOverlayEnabled, forKey: Key.playerOverlay) }
    }

    /// Whether the Record screen runs live tracking (phase 2).
    var liveOverlayEnabled: Bool {
        didSet { defaults.set(liveOverlayEnabled, forKey: Key.liveOverlay) }
    }

    /// Detector used for new analyses. Debug-only picker in Settings.
    var detectorKind: BallDetectorKind {
        didSet { defaults.set(detectorKind.rawValue, forKey: Key.detector) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        playerOverlayEnabled = defaults.object(forKey: Key.playerOverlay) as? Bool ?? true
        liveOverlayEnabled = defaults.bool(forKey: Key.liveOverlay)
        detectorKind = defaults.string(forKey: Key.detector).flatMap(BallDetectorKind.init(rawValue:)) ?? .default
    }
}
```

- [ ] **Step 5: Service**

```swift
// HighlightBot/Tracking/ClipTrackService.swift
import BallTracking
import Foundation
import HighlightCore
import Observation

enum ClipTrackStatus: Equatable {
    case none
    case analyzing(fraction: Double)
    case ready(BallTrack)
    case failed(String)
}

/// Runs `ClipTrackRunner` over saved clips on demand, caches results as sidecars,
/// and publishes per-clip status for the player.
@MainActor
@Observable
final class ClipTrackService {
    private(set) var statuses: [UUID: ClipTrackStatus] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Cancellation flags read by `ClipTrackRunner` on its worker queue, where
    /// `Task.isCancelled` would not reflect our detached task.
    @ObservationIgnored private var cancelFlags: [UUID: OSAllocatedUnfairLock<Bool>] = [:]
    @ObservationIgnored private let preferences: TrackingPreferences

    init(preferences: TrackingPreferences) {
        self.preferences = preferences
    }

    func status(for record: ClipRecord) -> ClipTrackStatus {
        statuses[record.id] ?? .none
    }

    /// Populates `.ready` from the sidecar if one exists. Cheap; call on appear.
    func loadCached(for record: ClipRecord) {
        if case .ready = status(for: record) { return }
        if case .analyzing = status(for: record) { return }
        if let track = ClipTrackStore.load(for: record) {
            statuses[record.id] = .ready(track)
        }
    }

    /// Starts analysis unless a result or a run already exists.
    func analyze(_ record: ClipRecord) {
        switch status(for: record) {
        case .ready, .analyzing: return
        case .none, .failed: break
        }
        if let track = ClipTrackStore.load(for: record) {
            statuses[record.id] = .ready(track)
            return
        }

        statuses[record.id] = .analyzing(fraction: 0)
        let id = record.id
        let url = record.fileURL
        let runner = ClipTrackRunner(detectorKind: preferences.detectorKind)
        let cancelFlag = OSAllocatedUnfairLock(initialState: false)
        cancelFlags[id] = cancelFlag
        Log.tracking.info("Analysing \(record.fileName, privacy: .public) with \(runner.detectorName, privacy: .public)")

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result = try await runner.run(url: url, progress: { progress in
                    Task { @MainActor [weak self] in
                        guard let self, case .analyzing = self.statuses[id] else { return }
                        self.statuses[id] = .analyzing(fraction: progress.fraction)
                    }
                }, isCancelled: { cancelFlag.withLock { $0 } })
                try ClipTrackStore.save(result.track, for: record)
                Log.tracking.info("Tracked \(record.fileName, privacy: .public): \(result.track.frames.count) frames, tracking \(result.track.trackingFraction * 100, format: .fixed(precision: 1))%, mean detect \(result.meanDetectMillis, format: .fixed(precision: 2)) ms, wall \(result.wallSeconds, format: .fixed(precision: 1)) s")
                await MainActor.run { [weak self] in
                    self?.finish(id, with: .ready(result.track))
                }
            } catch ClipTrackError.cancelled {
                await MainActor.run { [weak self] in
                    self?.finish(id, with: .none)
                }
            } catch {
                Log.tracking.error("Tracking failed for \(record.fileName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.finish(id, with: .failed(error.localizedDescription))
                }
            }
        }
        tasks[id] = task
    }

    /// Stops a running analysis; the status returns to `.none` once the runner unwinds.
    func cancel(_ record: ClipRecord) {
        cancelFlags[record.id]?.withLock { $0 = true }
        tasks[record.id]?.cancel()
    }

    private func finish(_ id: UUID, with status: ClipTrackStatus) {
        statuses[id] = status
        tasks[id] = nil
        cancelFlags[id] = nil
    }
}
```

Add `import os` at the top of the file for `OSAllocatedUnfairLock`. `ClipTrackRunner.process` calls `isCancelled()` once per frame, so cancellation lands within one frame's work.

- [ ] **Step 6: Container and Settings**

`AppContainer.swift`: add stored properties after `clipStore`:
```swift
    let trackingPreferences: TrackingPreferences
    let clipTracks: ClipTrackService
```
and in `init()`, after `clipStore = ClipStore(container: modelContainer)`:
```swift
        let trackingPreferences = TrackingPreferences()
        self.trackingPreferences = trackingPreferences
        clipTracks = ClipTrackService(preferences: trackingPreferences)
```

`SettingsScreen.swift`: add `import BallTracking`. At the top of `body`, next to `@Bindable var settings = container.settings`, add:
```swift
        @Bindable var tracking = container.trackingPreferences
```
Inside `Section("Debug")`, before the reset button:
```swift
                    Picker("Ball detector", selection: $tracking.detectorKind) {
                        ForEach(BallDetectorKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
```

- [ ] **Step 7: Build**

Run: `xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`. Fix any strict-concurrency diagnostics before continuing (they are errors in this project).

- [ ] **Step 8: Commit**

```bash
git add project.yml HighlightBot.xcodeproj/project.pbxproj HighlightBot/Support/AppDirectories.swift HighlightBot/Support/Log.swift HighlightBot/App/Clip.swift HighlightBot/App/ClipStore.swift HighlightBot/Tracking HighlightBot/App/AppContainer.swift HighlightBot/Features/Settings/SettingsScreen.swift
git commit -m "Add BallTracking dependency, track sidecar store, ClipTrackService, and tracking preferences"
```

---

## Task 10: Clip player overlay

**Files:**
- Create: `HighlightBot/Tracking/BallTrackOverlay.swift`
- Modify: `HighlightBot/Features/Library/ClipPlayerScreen.swift`

**Interfaces:**
- Consumes (from Task 9, pinned): `ClipTrackStatus`, `ClipTrackService`, `TrackingPreferences`, `AppContainer.clipTracks`, `AppContainer.trackingPreferences`; from the package: `BallTrack`, `OverlayGeometry`.
- Produces: `BallTrackOverlay(track:player:)` view.

- [ ] **Step 1: Overlay view**

```swift
// HighlightBot/Tracking/BallTrackOverlay.swift
import AVFoundation
import BallTracking
import SwiftUI

/// Draws the tracked ball and a short trail over a `VideoPlayer`, following the
/// player's current time every display frame. Assumes aspect-fit video, which is
/// what `VideoPlayer` renders, so the video rect is `AVMakeRect` over our bounds.
struct BallTrackOverlay: View {
    let track: BallTrack
    let player: AVPlayer

    var body: some View {
        TimelineView(.animation) { _ in
            Canvas { context, size in
                let time = player.currentTime().seconds
                guard time.isFinite else { return }
                let videoRect = AVMakeRect(aspectRatio: track.displaySize, insideRect: CGRect(origin: .zero, size: size))
                let geometry = OverlayGeometry(videoRect: videoRect)

                let trail = track.trail(endingAt: time, duration: 0.4)
                if trail.count > 1 {
                    var path = Path()
                    path.move(to: geometry.point(forNormalized: trail[0]))
                    for point in trail.dropFirst() {
                        path.addLine(to: geometry.point(forNormalized: point))
                    }
                    context.stroke(path, with: .color(.white.opacity(0.8)),
                                   style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                guard let frame = track.frame(at: time), frame.isVisible, let position = frame.position else { return }
                let center = geometry.point(forNormalized: position)
                let radius = max(8, geometry.length(forNormalizedWidthFraction: frame.radius ?? 0.005) * 2.5)
                let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                let color: Color = frame.state == .tracking ? .green : .orange
                context.stroke(ring, with: .color(color), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Wire into the player**

In `ClipPlayerScreen.swift`:

Add `import BallTracking`.

Replace
```swift
            VideoPlayer(player: player)
                .ignoresSafeArea()
```
with
```swift
            VideoPlayer(player: player) {
                if container.trackingPreferences.playerOverlayEnabled,
                   case .ready(let track) = container.clipTracks.status(for: record) {
                    BallTrackOverlay(track: track, player: player)
                }
            }
            .ignoresSafeArea()
```

In `.onAppear { startPlayback() }` change to:
```swift
        .onAppear {
            startPlayback()
            container.clipTracks.loadCached(for: record)
        }
```
and in `.onDisappear`, add as the first line:
```swift
            container.clipTracks.cancel(record)
```

In `bottomBar`, after `speedControl` and before `Spacer()`:
```swift
            trackingButton
```

Add the button and progress pill:
```swift
    private var trackingButton: some View {
        let status = container.clipTracks.status(for: record)
        let overlayOn = container.trackingPreferences.playerOverlayEnabled
        return Button {
            handleTrackingTap(status: status)
        } label: {
            switch status {
            case .analyzing:
                ProgressView().tint(.white)
            case .ready where overlayOn:
                Label("Hide ball tracking", systemImage: "figure.table.tennis")
                    .foregroundStyle(.green)
            default:
                Label("Show ball tracking", systemImage: "figure.table.tennis")
            }
        }
        .accessibilityLabel(trackingAccessibilityLabel(status: status, overlayOn: overlayOn))
    }

    private func handleTrackingTap(status: ClipTrackStatus) {
        switch status {
        case .analyzing:
            container.clipTracks.cancel(record)
            statusMessage = "Ball tracking cancelled"
        case .ready:
            container.trackingPreferences.playerOverlayEnabled.toggle()
        case .none, .failed:
            container.trackingPreferences.playerOverlayEnabled = true
            container.clipTracks.analyze(record)
        }
    }

    private func trackingAccessibilityLabel(status: ClipTrackStatus, overlayOn: Bool) -> String {
        switch status {
        case .analyzing: "Cancel ball tracking"
        case .ready: overlayOn ? "Hide ball tracking" : "Show ball tracking"
        case .none, .failed: "Track the ball in this clip"
        }
    }
```

Add a progress / failure pill under the top bar. In `body`, inside the outer `VStack` right after the top `HStack ... .padding(16)` block:
```swift
                trackingStatusPill
```
with
```swift
    @ViewBuilder
    private var trackingStatusPill: some View {
        switch container.clipTracks.status(for: record) {
        case .analyzing(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 120).tint(.white)
                Text("Tracking ball… \(Int(fraction * 100))%")
                    .monospacedDigit()
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
        case .failed(let message):
            Text("Ball tracking failed: \(message)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.red.opacity(0.85), in: Capsule())
        case .none, .ready:
            EmptyView()
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project HighlightBot.xcodeproj -scheme HighlightBot -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -20`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add HighlightBot/Tracking/BallTrackOverlay.swift HighlightBot/Features/Library/ClipPlayerScreen.swift
git commit -m "Add ball tracking overlay and analyse button to the clip player"
```

---

## Task 11: Device verification and documentation (phase 1 done)

**Files:**
- Modify: `README.md`
- Modify: `docs/ios-app-plan.md` (§5 Ball tracking paragraph: point at the spec)

- [ ] **Step 1: On-device acceptance (user or orchestrator with a device)**

Build and run on the iPhone. Record a short rally, save a clip, open it in the Library:
1. Tap the table-tennis button. A "Tracking ball… N%" pill appears and reaches 100% within ~15 s for a 20 s clip; the log line `Tracked <file>: …` appears in Console (subsystem `com.nathanklassen.highlightbot`, category `tracking`).
2. Scrub to a frame where the ball is mid-flight. The green ring sits on the ball and a short white trail leads to it. If the ring is consistently offset, `VideoPlayer` is not aspect-fitting to our bounds; note the offset and fall back to hosting an `AVPlayerLayer` (spec, Risks).
3. Tap the button again: overlay hides. Tap again: shows instantly (cached).
4. Close and reopen the clip: still cached (`Documents/Clips/Tracks/*.track.json` exists; visible in the Files app).
5. Delete the clip: the sidecar disappears with it.
6. Start an analysis and close the player mid-way: no crash; reopening shows the button in its idle state.

- [ ] **Step 2: Compare with the lab**

Copy a device clip to the Mac (Files app → AirDrop) and run `balltrack-lab run` on it; the annotated video should agree with what the player shows. Any disagreement points at the overlay geometry, not the tracker.

- [ ] **Step 3: Docs**

README: add a "Ball tracking" section after "Triggers":
```markdown
## Ball tracking

Open a clip and tap the table-tennis button to analyse it. The ball is drawn with a ring and a short trail; results are cached next to the clip in `Documents/Clips/Tracks/`. Detector and tracker live in the `BallTracking` package and can be run against any movie file from the Mac:

```sh
cd BallTracking && swift run -c release balltrack-lab run --input path/to/clip.mp4 --out /tmp/balltrack/out
```

Design: [docs/superpowers/specs/2026-09-18-ball-tracking-design.md](docs/superpowers/specs/2026-09-18-ball-tracking-design.md).
```
Also add `BallTracking/` to the README "Layout" block with the line `BallTracking/           Swift package: ball detectors, tracker, offline runner, and the balltrack-lab CLI`.

`docs/ios-app-plan.md` §5, replace the "Ball tracking." paragraph's first sentence with: "Ball tracking. Designed and planned in `docs/superpowers/specs/2026-09-18-ball-tracking-design.md`; the paragraph below is the original sketch."

- [ ] **Step 4: Commit**

```bash
git add README.md docs/ios-app-plan.md
git commit -m "Document ball tracking in the clip player and the balltrack-lab harness"
```

---

## Phase 2 — live overlay on the Record screen

## Task 12: Frames during preview, `BallTrail`, `previewVideoGravity`

**Files:**
- Create: `BallTracking/Sources/BallTracking/Tracking/BallTrail.swift`
- Test: `BallTracking/Tests/BallTrackingTests/BallTrailTests.swift`
- Modify: `HighlightBot/Capture/SampleFanout.swift`
- Modify: `HighlightBot/Capture/RecordingPipeline.swift`
- Modify: `HighlightBot/Capture/CaptureSource.swift`, `CaptureEngine.swift`, `FileReplayCaptureSource.swift`
- Modify: `HighlightBot/Features/Record/PreviewLayerView.swift`
- Modify: `HighlightBot/App/AppContainer.swift` (expose `frameTap`)

**Interfaces:**
- Produces: `BallTrail { init(maxAge:maxCount:); points: [BallTrail.Point]; mutating append(_ frame: BallTrackFrame) }`; `CaptureSource.previewVideoGravity: AVLayerVideoGravity`; `SampleFanout.init(recorder: SegmentedRecorder?, frameTap:)`; `AppContainer.frameTap: FrameTap`.

- [ ] **Step 1: `BallTrail` tests**

```swift
// BallTracking/Tests/BallTrackingTests/BallTrailTests.swift
import CoreGraphics
import Testing
@testable import BallTracking

struct BallTrailTests {
    private func frame(_ t: Double, _ state: BallTrackState, x: Double = 0.5) -> BallTrackFrame {
        BallTrackFrame(time: t, state: state, position: state == .searching ? nil : CGPoint(x: x, y: 0.5),
                       velocity: nil, radius: nil, candidateCount: 0)
    }

    @Test("keeps tracking points within maxAge and clears on searching")
    func agesAndClears() {
        var trail = BallTrail(maxAge: 0.1, maxCount: 100)
        trail.append(frame(0.00, .tracking, x: 0.1))
        trail.append(frame(0.02, .tracking, x: 0.2))
        trail.append(frame(0.04, .coasting, x: 0.3))   // not appended
        trail.append(frame(0.12, .tracking, x: 0.4))   // evicts t=0.00
        #expect(trail.points.map(\.position.x) == [0.2, 0.4])
        trail.append(frame(0.14, .searching))
        #expect(trail.points.isEmpty)
    }

    @Test("caps the number of points")
    func caps() {
        var trail = BallTrail(maxAge: 10, maxCount: 3)
        for i in 0..<5 { trail.append(frame(Double(i) * 0.02, .tracking, x: Double(i))) }
        #expect(trail.points.map(\.position.x) == [2, 3, 4])
    }
}
```

- [ ] **Step 2: Implement `BallTrail`**

```swift
// BallTracking/Sources/BallTracking/Tracking/BallTrail.swift
import CoreGraphics
import Foundation

/// Rolling history of confirmed positions for drawing a trail in live mode.
/// (Saved clips derive the trail from `BallTrack.trail(endingAt:duration:)` instead.)
public struct BallTrail: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public var time: TimeInterval
        public var position: CGPoint
    }

    public private(set) var points: [Point] = []
    public var maxAge: TimeInterval
    public var maxCount: Int

    public init(maxAge: TimeInterval = 0.4, maxCount: Int = 30) {
        self.maxAge = maxAge
        self.maxCount = maxCount
    }

    public mutating func append(_ frame: BallTrackFrame) {
        if frame.state == .searching {
            points.removeAll()
            return
        }
        if frame.state == .tracking, let position = frame.position {
            points.append(Point(time: frame.time, position: position))
        }
        points.removeAll { frame.time - $0.time > maxAge }
        if points.count > maxCount {
            points.removeFirst(points.count - maxCount)
        }
    }
}
```

Run: `cd BallTracking && swift test --filter BallTrailTests` → 2 pass. Commit:
```bash
git add BallTracking/Sources/BallTracking/Tracking/BallTrail.swift BallTracking/Tests/BallTrackingTests/BallTrailTests.swift
git commit -m "Add BallTrail for live overlay history"
```

- [ ] **Step 3: Optional recorder in `SampleFanout`**

In `SampleFanout.swift` change:
```swift
    let recorder: SegmentedRecorder?
```
```swift
    init(recorder: SegmentedRecorder?, frameTap: FrameTap) {
```
and `recorder.appendVideo(sampleBuffer)` → `recorder?.appendVideo(sampleBuffer)`, `recorder.appendAudio(sampleBuffer)` → `recorder?.appendAudio(sampleBuffer)`. Update the class doc comment: "Every video sample goes to the recorder (when one is attached; preview mode has none) …".

- [ ] **Step 4: Preview fanout in `RecordingPipeline`**

Add to `State`:
```swift
        /// Consumer installed while previewing without recording, so analyzers see frames.
        var previewFanout: SampleFanout?
```
In `startPreview()`, after the `if !running { … }` block and before `ensureEventsTask()`:
```swift
        if !state.withLock({ $0.isRecording }) {
            let preview = state.withLock { s -> SampleFanout in
                if let existing = s.previewFanout { return existing }
                let created = SampleFanout(recorder: nil, frameTap: frameTap)
                s.previewFanout = created
                return created
            }
            source.setConsumer(preview)
        }
```
In `stopRecording()`, replace `source.setConsumer(nil)` with:
```swift
        // The camera keeps running so the viewfinder stays live; only the
        // recorder detaches. Analyzers keep receiving frames via the preview fanout.
        source.setConsumer(state.withLock { $0.previewFanout })
```
In `stopPreview()`, before `await source.stop()` add `source.setConsumer(nil)`.

`collectMetrics()` reads `fanout` (recording) counters; leave as is. `analyzerDroppedFrames` already comes from `frameTap`.

- [ ] **Step 5: `previewVideoGravity`**

`CaptureSource.swift`, add to the protocol after `makePreviewLayer`:
```swift
    /// How the preview layer fits video into its bounds; overlays use it to align.
    var previewVideoGravity: AVLayerVideoGravity { get }
```
`CaptureEngine.swift`: `var previewVideoGravity: AVLayerVideoGravity { .resizeAspectFill }` (in the `// MARK: - CaptureSource` section).
`FileReplayCaptureSource.swift`: `var previewVideoGravity: AVLayerVideoGravity { .resizeAspect }`.
`PreviewLayerView.makeUIView`: replace the two `if let preview … else if let display …` branches with `layer.videoGravity = source.previewVideoGravity` — but `CALayer` has no `videoGravity`; keep the casts and set both from the source:
```swift
        if let preview = layer as? AVCaptureVideoPreviewLayer {
            preview.videoGravity = source.previewVideoGravity
        } else if let display = layer as? AVSampleBufferDisplayLayer {
            display.videoGravity = source.previewVideoGravity
        }
```

- [ ] **Step 6: Expose `frameTap`**

`AppContainer.swift`: add `let frameTap: FrameTap` next to `ringBuffer`, and in `init()` change `let frameTap = FrameTap()` to also assign `self.frameTap = frameTap`.

- [ ] **Step 7: Build and commit**

Run the `xcodebuild` command from Task 9 Step 7. Expected: `BUILD SUCCEEDED`.
```bash
git add HighlightBot/Capture HighlightBot/Features/Record/PreviewLayerView.swift HighlightBot/App/AppContainer.swift
git commit -m "Feed FrameTap during preview via a recorder-less SampleFanout; expose preview video gravity"
```

---

## Task 13: `BallTrackingAnalyzer` (live) and container wiring

**Files:**
- Create: `HighlightBot/Tracking/BallTrackingAnalyzer.swift`
- Modify: `HighlightBot/App/AppContainer.swift`

**Interfaces:**
- Consumes: `FrameAnalyzer`, `FrameTap` (app), `BallDetector`, `BallTracker`, `BallTrail`, `BallTrackFrame`, `BallDetectorKind` (package), `TrackingPreferences.liveOverlayEnabled`.
- Produces: `BallTrackingSnapshot { frame: BallTrackFrame?; trail: BallTrail; imageSize: CGSize; stats: Stats }`, `BallTrackingAnalyzer: FrameAnalyzer { snapshots: AsyncStream<BallTrackingSnapshot>; latest }`, `AppContainer.liveTracking: BallTrackingSnapshot`.

- [ ] **Step 1: Analyzer**

```swift
// HighlightBot/Tracking/BallTrackingAnalyzer.swift
import BallTracking
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

struct BallTrackingSnapshot: Sendable, Equatable {
    struct Stats: Sendable, Equatable {
        var analyzedFrames = 0
        var lastAnalyzeMillis = 0.0
        var averageAnalyzeMillis = 0.0
        var lastCandidates = 0
        var errors = 0
    }

    var frame: BallTrackFrame?
    var trail = BallTrail()
    var imageSize = CGSize.zero
    var stats = Stats()

    static let empty = BallTrackingSnapshot()
}

/// Runs a `BallDetector` and `BallTracker` on live frames from `FrameTap`.
/// `FrameTap` guarantees at most one `analyze` in flight per analyzer, so the
/// detector, tracker, and trail are only touched from one task at a time; the
/// published snapshot is the only shared state and sits behind a lock.
/// `@unchecked Sendable` for that reason.
final class BallTrackingAnalyzer: FrameAnalyzer, @unchecked Sendable {
    let name = "ball-tracking"
    let snapshots: AsyncStream<BallTrackingSnapshot>

    private let detector: any BallDetector
    private var tracker: BallTracker
    private var trail = BallTrail()
    private var stats = BallTrackingSnapshot.Stats()
    private let latestState = OSAllocatedUnfairLock(initialState: BallTrackingSnapshot.empty)
    private let continuation: AsyncStream<BallTrackingSnapshot>.Continuation

    init(detector: any BallDetector, trackerConfig: BallTrackerConfig = .default) {
        self.detector = detector
        tracker = BallTracker(config: trackerConfig)
        let (stream, continuation) = AsyncStream.makeStream(of: BallTrackingSnapshot.self, bufferingPolicy: .bufferingNewest(1))
        snapshots = stream
        self.continuation = continuation
    }

    deinit {
        continuation.finish()
    }

    var latest: BallTrackingSnapshot {
        latestState.withLock { $0 }
    }

    func analyze(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) async {
        let start = ContinuousClock.now
        var candidates: [BallObservation] = []
        do {
            candidates = try detector.detect(pixelBuffer: pixelBuffer, time: presentationTime)
        } catch {
            stats.errors += 1
            if stats.errors == 1 || stats.errors % 100 == 0 {
                Log.tracking.error("Live detect failed (\(self.stats.errors) so far): \(error.localizedDescription, privacy: .public)")
            }
        }
        let frame = tracker.update(time: presentationTime.seconds, candidates: candidates)
        trail.append(frame)

        let millis = (ContinuousClock.now - start).millis
        stats.analyzedFrames += 1
        stats.lastAnalyzeMillis = millis
        stats.averageAnalyzeMillis += (millis - stats.averageAnalyzeMillis) / Double(min(stats.analyzedFrames, 60))
        stats.lastCandidates = candidates.count

        let snapshot = BallTrackingSnapshot(
            frame: frame,
            trail: trail,
            imageSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
            stats: stats
        )
        latestState.withLock { $0 = snapshot }
        continuation.yield(snapshot)
    }
}

private extension Duration {
    var millis: Double { Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15 }
}
```

- [ ] **Step 2: Container wiring**

`AppContainer.swift`: add observable state and private handles:
```swift
    /// Latest live-tracking snapshot; `.empty` when the live overlay is off.
    var liveTracking: BallTrackingSnapshot = .empty

    @ObservationIgnored private var liveAnalyzer: BallTrackingAnalyzer?
    @ObservationIgnored private var liveTrackingTask: Task<Void, Never>?
```
Add `import BallTracking` at the top. In `start()`, after `permissions.refresh()`:
```swift
        applyLiveTracking(enabled: trackingPreferences.liveOverlayEnabled)
```
Add a method in `// MARK: - Actions`:
```swift
    /// Registers or removes the live analyzer. Zero cost when disabled: nothing
    /// is registered with `FrameTap`.
    func applyLiveTracking(enabled: Bool) {
        if enabled {
            guard liveAnalyzer == nil else { return }
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(1, settings.config.frameRate)))
            let detector = trackingPreferences.detectorKind.makeDetector(frameDuration: frameDuration)
            let analyzer = BallTrackingAnalyzer(detector: detector)
            liveAnalyzer = analyzer
            frameTap.register(analyzer)
            liveTrackingTask = Task { @MainActor [weak self] in
                for await snapshot in analyzer.snapshots {
                    guard let self else { return }
                    self.liveTracking = snapshot
                }
            }
            Log.tracking.info("Live ball tracking on (\(detector.name, privacy: .public))")
        } else {
            guard let analyzer = liveAnalyzer else { return }
            frameTap.unregister(name: analyzer.name)
            liveTrackingTask?.cancel()
            liveTrackingTask = nil
            liveAnalyzer = nil
            liveTracking = .empty
            Log.tracking.info("Live ball tracking off")
        }
    }
```
Add `import CoreMedia` for `CMTime`. Because `TrackingPreferences` is `@Observable`, the Record screen toggles `liveOverlayEnabled` and calls `container.applyLiveTracking(enabled:)` (Task 14); the container does not observe preferences itself.

- [ ] **Step 3: Build and commit**

Run the `xcodebuild` command. Expected: `BUILD SUCCEEDED`.
```bash
git add HighlightBot/Tracking/BallTrackingAnalyzer.swift HighlightBot/App/AppContainer.swift
git commit -m "Add live BallTrackingAnalyzer registered with FrameTap when the live overlay is enabled"
```

---

## Task 14: Record screen overlay, toggles, debug stats

**Files:**
- Create: `HighlightBot/Tracking/BallOverlayView.swift`
- Modify: `HighlightBot/Features/Record/RecordScreen.swift`
- Modify: `HighlightBot/Features/Record/DebugOverlay.swift`
- Modify: `HighlightBot/Features/Settings/SettingsScreen.swift`

**Interfaces:**
- Consumes: `BallTrackingSnapshot`, `AppContainer.liveTracking`, `AppContainer.applyLiveTracking(enabled:)`, `TrackingPreferences.liveOverlayEnabled`, `CaptureSource.previewVideoGravity`, `captureRotationAngle`, `OverlayGeometry`, `OverlayGravity`.

- [ ] **Step 1: Overlay view**

```swift
// HighlightBot/Tracking/BallOverlayView.swift
import AVFoundation
import BallTracking
import SwiftUI

/// Live ball overlay for the Record screen. Frames arrive in the sensor's stored
/// orientation; the preview layer rotates them by `rotationDegrees` and fits them
/// with `gravity`, so the overlay applies the same mapping.
struct BallOverlayView: View {
    let snapshot: BallTrackingSnapshot
    let gravity: AVLayerVideoGravity
    let rotationDegrees: Int

    var body: some View {
        Canvas { context, size in
            guard snapshot.imageSize.width > 0 else { return }
            let geometry = OverlayGeometry(
                imageSize: snapshot.imageSize,
                bounds: CGRect(origin: .zero, size: size),
                gravity: gravity == .resizeAspectFill ? .aspectFill : .aspectFit,
                rotationDegrees: rotationDegrees
            )

            let trail = snapshot.trail.points
            if trail.count > 1 {
                var path = Path()
                path.move(to: geometry.point(forNormalized: trail[0].position))
                for point in trail.dropFirst() {
                    path.addLine(to: geometry.point(forNormalized: point.position))
                }
                context.stroke(path, with: .color(.white.opacity(0.8)),
                               style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }

            guard let frame = snapshot.frame, frame.isVisible, let position = frame.position else { return }
            let center = geometry.point(forNormalized: position)
            let radius = max(8, geometry.length(forNormalizedWidthFraction: frame.radius ?? 0.005) * 2.5)
            let ring = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(ring, with: .color(frame.state == .tracking ? .green : .orange), lineWidth: 2.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
```

- [ ] **Step 2: Record screen**

In `RecordScreen.swift` add `import BallTracking`. In `captureStack`, directly after the `PreviewLayerView(...)` modifiers:
```swift
            if container.trackingPreferences.liveOverlayEnabled {
                BallOverlayView(
                    snapshot: container.liveTracking,
                    gravity: container.pipeline.source.previewVideoGravity,
                    rotationDegrees: Int(container.pipeline.source.captureRotationAngle.rounded())
                )
                .ignoresSafeArea()
            }
```
In `controlsOverlay`'s top `HStack`, before `dimButton`:
```swift
                trackingToggleButton
```
with
```swift
    private var trackingToggleButton: some View {
        let enabled = container.trackingPreferences.liveOverlayEnabled
        return Button {
            container.trackingPreferences.liveOverlayEnabled.toggle()
            container.applyLiveTracking(enabled: container.trackingPreferences.liveOverlayEnabled)
        } label: {
            Image(systemName: "figure.table.tennis")
                .font(.body.weight(.semibold))
                .foregroundStyle(enabled ? .green : .white)
                .padding(10)
                .background(.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(enabled ? "Turn off live ball tracking" : "Turn on live ball tracking")
    }
```
Pass tracking stats into the debug overlay: change `DebugOverlay(metrics: container.metrics)` to `DebugOverlay(metrics: container.metrics, tracking: container.trackingPreferences.liveOverlayEnabled ? container.liveTracking : nil)`.

- [ ] **Step 3: Debug overlay lines**

`DebugOverlay.swift`: add `let tracking: BallTrackingSnapshot?` after `metrics`, and append to `text` (before the closing `"""`), building the extra lines separately:
```swift
        \(trackingText)
```
with
```swift
    private var trackingText: String {
        guard let tracking else { return "ball       off" }
        let state = tracking.frame?.state.rawValue ?? "—"
        return """
        ball       \(state) cands=\(tracking.stats.lastCandidates)
        ball ms    \(format(tracking.stats.lastAnalyzeMillis, 1)) avg \(format(tracking.stats.averageAnalyzeMillis, 1)) err \(tracking.stats.errors)
        """
    }
```

- [ ] **Step 4: Settings toggle**

`SettingsScreen.swift`: add a section before `Section("Storage")` (`tracking` is the `@Bindable` declared at the top of `body` in Task 9):
```swift
                Section {
                    Toggle("Live ball tracking overlay", isOn: $tracking.liveOverlayEnabled)
                        .onChange(of: tracking.liveOverlayEnabled) { _, enabled in
                            container.applyLiveTracking(enabled: enabled)
                        }
                } header: {
                    Text("Tracking")
                } footer: {
                    Text("Draws the tracked ball on the viewfinder while previewing and recording. Uses extra battery.")
                }
```

- [ ] **Step 5: Build, verify on device, commit**

Build with the `xcodebuild` command. Expected: `BUILD SUCCEEDED`.

On device: enable the overlay from the Record screen button; toss a ball across the frame in front of a dark background; the ring follows it during preview (not recording) and during recording. Debug overlay shows `ball ms` — expect single-digit ms for luma and `analyzerDr` climbing if the detector is slower than the frame rate (expected, harmless). Rotate the phone between the two landscape orientations; the ring stays on the ball (0° vs 180°). Turn the overlay off: `ball off` in the debug overlay, `analyzerDr` stops climbing.

```bash
git add HighlightBot/Tracking/BallOverlayView.swift HighlightBot/Features/Record HighlightBot/Features/Settings/SettingsScreen.swift
git commit -m "Add live ball tracking overlay to the Record screen with toggles and debug stats"
```

---

## Self-review notes

- Spec coverage: clip-player overlay (Tasks 9–11), live overlay (12–14), pluggable detector with lab-chosen default (4, 5, 8), tracker with hit recovery (2), sidecar storage (9), coordinate conventions (3, 6), lab harness with annotated video and metrics (7), optional ground-truth scoring (7), future hooks (velocity in `BallTrackFrame`, detector name in `BallTrack`).
- Type names used consistently: `BallObservation`, `BallTrackFrame`, `BallTrackState`, `BallTrack`, `BallDetector`, `BallDetectorKind`, `BallTracker`, `BallTrackerConfig`, `BallTrail`, `OverlayGeometry`, `OverlayGravity`, `FrameOrientation`, `ClipTrackRunner`, `ClipTrackResult`, `ClipTrackProgress`, `ClipTrackError`, `ClipTrackStore`, `ClipTrackService`, `ClipTrackStatus`, `TrackingPreferences`, `BallTrackOverlay` (player), `BallOverlayView` (live), `BallTrackingAnalyzer`, `BallTrackingSnapshot`.
- Known judgement calls, flagged for the executor: the `VisionTrajectoryDetector` synthetic test may need relaxing (Task 4); `VideoPlayer` aspect-fit assumption (Task 11 Step 1); `rotationDegrees` is treated as clockwise and only 0/180 are reachable while Record is landscape-only.
