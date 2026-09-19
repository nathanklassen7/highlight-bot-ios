# Highlight Bot iOS — Implementation Plan

## Summary

Build a native iOS app (Swift, SwiftUI, AVFoundation) that continuously records into a rolling buffer of 5-second fMP4 segments and, on a trigger (screen tap, hardware button, Bluetooth shutter, later voice or ball tracking), assembles the last *n* seconds into a shareable `.mp4` without interrupting recording. Sharing uses the system share sheet only; there is no Slack integration.

The architecture is a single capture session that fans raw frames out to two consumers: the encoder (for the ring buffer) and a pluggable frame-analysis pipeline (empty for now, reserved for ball tracking). Triggers are modeled as interchangeable sources feeding one event stream, so voice and vision triggers are additive, not rewrites.

Recommended first step is a two-day spike to confirm the segmented `AVAssetWriter` behaviour on a real device before building anything else. Everything downstream depends on it.

---

## 1. Key technical decisions

### 1.1 Rolling buffer: segmented `AVAssetWriter` (fMP4), not `AVCaptureMovieFileOutput`

Three ways to get a rolling buffer on iOS were considered:

| Approach | Verdict |
| --- | --- |
| `AVCaptureMovieFileOutput`, restart every 5s | Rejected. Each stop/start drops frames and re-initialises the encoder, so clips have visible gaps at segment joins. Also cannot coexist cleanly with a frame-analysis output. |
| Own `AVAssetWriter` per segment, double-buffered writers | Works but complex: two encoders briefly running, manual keyframe alignment, easy to get audio/video drift. |
| **One `AVAssetWriter` in segmented mode** (`outputFileTypeProfile = .mpeg4AppleHLS`, `preferredOutputSegmentInterval = 5s`) | **Chosen.** One encoder session, zero gaps, segments delivered as `Data` via `AVAssetWriterDelegate.assetWriter(_:didOutputSegmentData:segmentType:segmentReport:)`. Writer forces a keyframe at every segment boundary. Available since iOS 14. |

Input to the writer comes from `AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput`, not from the writer's own capture connection. This is what makes ball tracking possible later: the same `CMSampleBuffer`s that feed the encoder are also visible to a `FrameAnalyzer`.

**Trigger tail.** At trigger time the current segment holds 0–`segmentInterval` s of undelivered footage. The original design called `assetWriter.flushSegment()` to force it out; the SDK header rules that out (it throws with a fixed interval, and the indefinite-interval mode disables writer-side compression). **Implemented fallback:** `RecordingPipeline.saveClip` waits for the next fixed boundary (≤ `segmentInterval` + margin), then the clip is `init segment + last k media segments`. With the 2 s default (§6) the clip ends 0–2 s after the trigger. The spike (§4, Phase 0) confirms the tail latency on device.

**Clip granularity.** MVP saves whole segments, so a request for "last 20s" yields 20–25s. Exact trimming is a follow-up (passthrough `AVAssetExportSession` with a `timeRange`; cuts land on the nearest keyframe so it is still approximate). Segment interval is a single config constant; 5s is a reasonable default, not a hard requirement.

### 1.2 Ring buffer is disk-backed, index in memory

At 1080p60 / ~10 Mbps a 5s segment is ~6 MB. A 20s buffer is trivial in RAM, but "more features later" likely means longer buffers (60s = ~75 MB) and iOS kills memory-hungry camera apps quickly. Segments go to `tmp/ring/<sessionID>/<seq>.m4s` on a utility queue; the in-memory index tracks `(seq, sessionID, startPTS, duration, byteCount)`. Eviction keeps `≥ bufferSeconds + segmentInterval` of footage. Cost of the disk path is negligible; robustness gain is large.

**Sessions.** Every writer start (app launch, return from background, camera interruption ending) produces a new init segment. Segments from different sessions are not contiguous and cannot be concatenated. The ring tags each segment with a `sessionID` and clip assembly only joins segments from the current session. This is the piece the Pi code does not have and the one most likely to bite if skipped.

### 1.3 Saving never stops recording

The Pi implementation stops the encoder, reads the buffer, encodes, then restarts. On iOS, saving is a read-only copy from the ring: concatenate init + segments into a temp fMP4, then run a passthrough `AVAssetExportSession` (no re-encode, typically <1s) to produce a flat `.mp4` that plays everywhere. Recording state stays `.recording`; the UI shows a "saving" badge. Multiple triggers in quick succession queue up independently.

### 1.4 Hardware triggers via `AVCaptureEventInteraction` (iOS 17.2+)

`AVCaptureEventInteraction` delivers volume-button, Camera Control (iPhone 16), and Bluetooth camera-shutter presses as capture events while the app is foreground. The existing AB Shutter3 remote presents as a volume-up keypress, so it works with no pairing code in the app. This sets the minimum deployment target to iOS 17.2, which also gives SwiftData and the Observation framework for free.

### 1.5 Codec and format

Default **H.264, 1080p, 60 fps, ~10 Mbps, AAC audio**, matching the Pi config and maximising share compatibility (Android recipients of a text). HEVC as a user setting for smaller files. Pixel format `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` end to end; no CPU colour conversion.

---

## 2. Architecture

### 2.1 Repo layout

This is a standalone repo (`highlight-bot-ios`), a sibling of the Raspberry Pi repo `highlight-bot`, which is cloned onto the Pi and must stay free of iOS sources. The Pi repo is reference material only; the files worth reading for intent are `src/state_machine.py`, `src/recording_manager.py`, `src/video_utils.py`, `src/event_bus.py`, and `src/bluetooth_shutter_controller.py`.

Split pure logic into a Swift package so it compiles and tests on macOS without a device.

```
highlight-bot-ios/
  README.md
  docs/ios-app-plan.md          # this document
  HighlightBot.xcodeproj
  HighlightBot/                 # App target (SwiftUI, AVFoundation glue)
    App/                        # Entry, DI container, scene lifecycle
    Capture/                    # CaptureEngine, SegmentedRecorder, FrameTap
    Triggers/                   # TapTrigger, HardwareTrigger (+ future Voice/Vision)
    Features/
      Record/                   # Live preview screen
      Library/                  # Clip grid, player, share, delete
      Settings/
    Support/                    # Permissions, thermal, storage, logging
  HighlightCore/                # SPM package: no UIKit/AVFoundation-capture deps
    Sources/HighlightCore/
      RingBuffer/               # SegmentRingBuffer, Segment, eviction policy
      Session/                  # SessionCoordinator (state machine), TriggerBus
      Clips/                    # ClipAssembler (segment math), ClipStore models
      Config/                   # RecordingConfig, defaults, validation
    Tests/HighlightCoreTests/
```

### 2.2 Components and data flow

```
                  ┌────────────────────┐
  Camera + Mic ──▶│   CaptureEngine    │──▶ AVCaptureVideoPreviewLayer (GPU, UI)
                  │ (AVCaptureSession) │
                  └────────┬───────────┘
              video+audio  │ CMSampleBuffer  (capture queue, must stay fast)
                           ▼
                  ┌────────────────────┐        ┌────────────────────┐
                  │  SampleFanout      │──────▶ │  FrameTap          │─▶ FrameAnalyzer[] (future: ball tracking)
                  └────────┬───────────┘        │  (drops if busy)   │
                           ▼                    └────────────────────┘
                  ┌────────────────────┐
                  │ SegmentedRecorder  │  AVAssetWriter, fMP4, 5s segments
                  └────────┬───────────┘
                           │ (init | media) Data + report
                           ▼
                  ┌────────────────────┐
                  │ SegmentRingBuffer  │  disk-backed, per-session, evicts by seconds
                  └────────┬───────────┘
                           │ snapshot(lastSeconds:)
                           ▼
  TriggerBus ─▶ SessionCoordinator ─▶ ClipAssembler ─▶ ClipStore ─▶ Library UI ─▶ ShareLink
  (tap, hw btn,        (state machine)   (concat + passthrough export)
   BT shutter,
   future voice/vision)
```

**Component contracts** (the parts worth pinning down before writing code):

- `CaptureEngine` — owns `AVCaptureSession`, device/format selection, orientation, interruption and runtime-error handling, thermal downgrade (60→30 fps on `.serious`). Exposes `AsyncStream<CaptureEvent>` (started, stopped, interrupted, resumed, formatChanged). Runs on a dedicated serial `DispatchQueue`.
- `CaptureSource` protocol — `CaptureEngine` is one implementation. A `FileReplayCaptureSource` that replays a recorded `.mov` through the same pipeline makes the app runnable in the Simulator and, later, lets you develop ball tracking against recorded games instead of standing on a court.
- `SegmentedRecorder` — appends sample buffers, owns the writer lifecycle, emits `Segment(kind: .initialization | .media, sessionID, seq, data, report)`. Provides `flushSegment()` and `restart()` (new session).
- `SegmentRingBuffer` (actor) — `append(_:)`, `snapshot(lastSeconds: TimeInterval) -> ClipPlan?` returning the init segment URL plus ordered media segment URLs for the current session only. Eviction runs after each append.
- `TriggerBus` — `AsyncStream<TriggerEvent>` where `TriggerEvent { source: TriggerSource, kind: .saveClip(seconds: TimeInterval?) | .startRecording | .stopRecording, timestamp }`. `TriggerSource` is a protocol with `start()/stop()`; sources register with the bus. Tap and hardware button ship in MVP; voice and vision plug in here later with zero changes to the coordinator.
- `SessionCoordinator` (actor) — state machine ported from `state_machine.py`, simplified: states `idle`, `starting`, `recording(pendingSaves: Int)`, `interrupted`. Saving is a task, not a state. Also owns the inactivity timeout (Pi default 2h; on a phone 30–60 min is more sensible since the screen stays on).
- `ClipAssembler` — pure function in `HighlightCore` decides which segments to use; the app-side `ClipExporter` does the concat + passthrough export and thumbnail generation (`AVAssetImageGenerator`).
- `ClipStore` — SwiftData model `Clip { id, createdAt, duration, fileURL, thumbnailURL, triggerSource, sizeBytes }` plus files in `Documents/Clips/`. Enable `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` so clips are visible in the Files app as a free backup path.
- `FrameTap` — subscribes to video sample buffers, forwards `CVPixelBuffer` + timestamp to registered `FrameAnalyzer`s on its own queue, **drops frames when an analyzer is still busy**. Never blocks the capture queue. Ships as an empty registry in MVP so the hot path is already shaped correctly.

### 2.3 Concurrency model

- Swift 6 language mode with strict concurrency from day one. It is much cheaper to start there than migrate later, and the pipeline is inherently multi-queue.
- AVFoundation callbacks arrive on the queues we give them; wrap them into actors/`AsyncStream`s at the boundary. `CMSampleBuffer` is not `Sendable`; the capture callback appends to the writer synchronously on the capture queue and hands `CVPixelBuffer` (retained) to `FrameTap`, so nothing crosses an isolation boundary unsafely.
- UI reads state via `@Observable` view models that subscribe to coordinator streams on `@MainActor`.

### 2.4 Performance rules (enforced, not aspirational)

1. Preview uses `AVCaptureVideoPreviewLayer`. Never render preview from the data output.
2. The video data callback does one thing: `writerInput.append(sampleBuffer)` and a non-blocking enqueue to `FrameTap`. Target <1 ms; measure with `os_signpost`.
3. `alwaysDiscardsLateVideoFrames = false` on the recording output so the encoder gets every frame; dropping happens only in `FrameTap`.
4. Segment persistence and clip export run on a `.utility` queue; export uses passthrough, never re-encode.
5. Log `capturedFrames`, `droppedFrames` (from `captureOutput(_:didDrop:from:)`), segment write latency, and export duration to `os_log`. Surface a debug overlay in Settings.
6. Watch `ProcessInfo.thermalState` and available disk (`volumeAvailableCapacityForImportantUsage`); degrade fps first, then resolution; refuse to start recording under ~500 MB free.
7. `UIApplication.isIdleTimerDisabled = true` while recording; provide a dimmed "screen off" mode (black overlay, tap still works) to save battery during long sessions.

---

## 3. UI (MVP)

Two screens plus settings. Keep it deliberately minimal so the record screen is a giant target you can hit without looking.

- **Record** — full-screen preview; whole screen is the trigger tap target. Overlay: recording indicator, buffer fill (0→n s), "saving…" badge, last-clip thumbnail (tap to open), a quick picker for *n* (10 / 20 / 30 / 60 s). Long-press (or a small button) toggles recording, mirroring the Pi short/long press semantics.
- **Library** — grid of clips newest-first with thumbnail, duration, time. Tap plays (`AVPlayer`). Swipe/menu: Share (`ShareLink` → Messages, AirDrop, any app), Save to Photos (`PHPhotoLibrary`, add-only permission), Delete.
- **Settings** — buffer seconds, resolution/fps, codec (H.264/HEVC), inactivity timeout, storage usage with "delete all", debug metrics toggle.

Orientation: lock to landscape for MVP (sports footage, and it removes an entire class of rotation bugs). Revisit if needed.

---

## 4. Phased delivery

### Phase 0 — Spike (1–2 days, on device)
Goal: retire the one real technical unknown before writing app structure.
- Minimal Xcode project: capture session → video/audio data outputs → segmented `AVAssetWriter`, segments to disk.
- Verify: (a) no gaps at segment joins when concatenated; (b) `flushSegment()` behaviour with a fixed interval — does the tail come out immediately and does the next segment start clean; (c) assembled fMP4 plays in `AVPlayer` and after passthrough export shares to Messages/Photos without complaint; (d) export time for a 20s clip; (e) sustained 1080p60 with zero `didDrop` callbacks for 10 minutes.
- Exit criteria: all five confirmed, or fallback (shorter segment interval) chosen and confirmed.

### Phase 1 — Skeleton (2–3 days)
- Xcode project + `HighlightCore` package, Swift 6, iOS 17.2 target, `.gitignore` for Xcode, CI running `swift test` on macOS for the package.
- `CaptureEngine` with preview, permissions flow (camera, mic), interruption handling.
- `SessionCoordinator` and `TriggerBus` with a `TapTrigger`. State visible in UI.
- `FileReplayCaptureSource` so the Simulator runs the full pipeline from a bundled test video.

### Phase 2 — Rolling buffer and save (3–4 days)
- `SegmentedRecorder`, `SegmentRingBuffer`, eviction, session tagging.
- `ClipAssembler` + `ClipExporter`, thumbnails, `ClipStore`.
- Tap → clip on disk, appears in Library, plays. Unit tests for ring eviction, session boundaries, and segment selection math.

### Phase 3 — Library and sharing (2 days)
- Library grid, player, `ShareLink`, Save to Photos, delete, storage accounting, Files app exposure.

### Phase 4 — Hardware triggers and robustness (2–3 days)
- `HardwareTrigger` via `AVCaptureEventInteraction` (volume, Camera Control, AB Shutter3).
- Background/foreground restart with new session; low-storage and thermal handling; inactivity timeout; dimmed screen mode.
- Settings screen.

### Phase 5 — Performance pass (1–2 days)
- Instruments: Time Profiler, Allocations, Energy. Confirm capture callback <1 ms, zero drops at 1080p60, steady memory over 30 min, export <2 s.
- Fix, then freeze the debug metrics overlay as a permanent hidden feature.

Rough total: 2.5–3 weeks of focused work for a solid MVP.

---

## 5. Future features and how they attach

**Ball tracking.** Register a `BallTrackingAnalyzer: FrameAnalyzer` with `FrameTap`. Apple's Vision framework has `VNDetectTrajectoriesRequest`, built specifically for tracking thrown/hit balls in sports video, and it runs on the Neural Engine. It needs a stable camera and a sequence of frames, both of which the architecture already provides. Downsample to 720p or lower for analysis (the encoder still gets full-res). Output flows two ways: as `TriggerEvent`s into `TriggerBus` (auto-clip on a detected shot) and as per-clip metadata into `ClipStore` (trajectory overlays, "scored" tags). `FileReplayCaptureSource` lets you iterate on detection against recorded games.

**Voice commands.** Shipped as `VoiceTrigger: TriggerSource` using `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, listening for "clip it" only. Audio is tapped from the existing `AVCaptureAudioDataOutput` via `SampleFanout` → `AudioSampleListener` (a session allows only one audio data output). `HighlightCore.KeywordSpotter` dedupes matches across partial results; the request is restarted after each match, on error, and every 45 s. Key open risk is recognition range and false positives from crowd noise; alternative if accuracy is poor: a custom keyword classifier via Sound Analysis + Create ML, or `SpeechAnalyzer` on iOS 26.

**Other Pi features worth porting later:** slow-mo replay (already have 60 fps; play at 0.25× with `AVPlayer.rate`), trim/edit, live preview streaming to a second device (Multipeer or local HTTP).

---

## 6. Decided defaults

These were open questions during planning and are now settled. Treat them as requirements, not suggestions.

| Decision | Value |
| --- | --- |
| Default buffer length *n* | 20 s (matches the Pi); user-selectable 10 / 20 / 30 / 60 s |
| Orientation | Landscape-only for MVP |
| Minimum iOS | 17.2 (required for `AVCaptureEventInteraction`) |
| Audio | Recorded by default (AAC); mic permission requested at first launch |
| Clip container | `.mp4`, H.264 video + AAC audio, for maximum cross-platform share compatibility; HEVC available as a setting |
| Capture defaults | 1080p, 60 fps, ~10 Mbps |
| Segment interval | **2 s** (single config constant). Originally 5 s; changed during implementation because the `AVAssetWriter.h` header states `flushSegment()` throws unless `preferredOutputSegmentInterval` is indefinite, and indefinite mode only supports passthrough (no writer-side compression). A save therefore waits for the next fixed boundary, so the interval bounds save latency. Confirm on device in Phase 0. |

## 7. Risks

- `flushSegment()` semantics with fixed segment intervals: the spike exists to settle this.
- `flushSegment()` semantics with fixed segment intervals: the spike exists to settle this.
- Sharing fMP4 directly is not universally accepted; the plan always passes through `AVAssetExportSession` passthrough to a flat MP4. If passthrough fails for some format combination, a re-encode fallback costs ~real-time duration.
- iOS suspends capture in the background, so the app must be foreground with the screen on. This is inherent; the dimmed-screen mode is the mitigation.
- Thermal throttling in direct sun at 1080p60 is likely over long sessions; the degrade path (60→30 fps) must be tested outdoors, not just assumed.
