import Foundation
import AVFoundation
import CoreMedia
import QuartzCore
import HighlightCore

/// Lifecycle notifications from a `CaptureSource`.
enum CaptureEvent: Sendable, Equatable {
    case started
    case stopped
    /// Capture paused by the system (phone call, backgrounding, another app
    /// took the camera). Recording will resume when `.resumed` arrives.
    case interrupted(reason: String)
    case resumed
    /// The source could not honour the requested format and is delivering
    /// this one instead, or the frame rate changed (thermal downgrade).
    case formatChanged(width: Int, height: Int, frameRate: Int)
    case runtimeError(String)
}

/// Receives raw samples on the capture queue. Implementations must return
/// fast (<1 ms): append to the writer and hand off, nothing else.
protocol SampleConsumer: AnyObject {
    func consumeVideo(_ sampleBuffer: CMSampleBuffer)
    func consumeAudio(_ sampleBuffer: CMSampleBuffer)
    /// The capture output dropped a frame before it reached us. Should never
    /// happen with `alwaysDiscardsLateVideoFrames = false`; counted for metrics.
    func didDropVideoFrame()
}

/// Receives a copy of every microphone buffer on the capture queue, after
/// the recorder has appended it. Same <1 ms rule as `SampleConsumer`: hand
/// the buffer off and return. Used by the voice trigger.
protocol AudioSampleListener: AnyObject, Sendable {
    func consumeAudio(_ sampleBuffer: CMSampleBuffer)
}

/// A camera or a file replay. Not an actor: each implementation owns its own
/// serial queue and hops onto it for configuration and lifecycle work, which
/// is what makes conformers `Sendable`.
protocol CaptureSource: AnyObject, Sendable {
    /// Single-consumer stream of lifecycle events. Created once per source.
    var events: AsyncStream<CaptureEvent> { get }
    /// `AVCaptureVideoPreviewLayer` for the camera, `AVSampleBufferDisplayLayer` for replay.
    @MainActor func makePreviewLayer() -> CALayer
    /// Install (or clear) the object that receives samples. Safe to call while running.
    func setConsumer(_ consumer: (any SampleConsumer)?)
    /// Select device, format, frame rate, and outputs. Must precede `start()`.
    func configure(_ config: RecordingConfig) async throws
    func start() async throws
    func stop() async
    /// Lower or restore the frame rate (thermal). No-op if unsupported.
    func setFrameRate(_ fps: Int) async
    /// Turn the camera torch on or off. No-op when the device has no torch or
    /// no camera has been configured yet.
    func setTorch(_ on: Bool) async
    /// Rotation, in degrees, that makes recorded video horizon-level given the
    /// data output delivers frames in the sensor's native orientation. Read at
    /// recording start and stamped into the file as metadata (no per-frame work).
    var captureRotationAngle: CGFloat { get }
    /// Pin `captureRotationAngle` and the preview to their current heading, or
    /// let both follow the horizon again. This is what keeps a recorded session
    /// single-orientation: the writer stamps the transform once, so the angle
    /// must not move until the session ends. Synchronous, and therefore already
    /// in effect when it returns, because `RecordingPipeline` freezes and then
    /// reads `captureRotationAngle` for the recorder it is building.
    func setRotationFrozen(_ frozen: Bool)
    /// The clock sample timestamps are expressed in. Lets the recorder pick a
    /// writer start time before the first frame arrives.
    var captureClock: CMClock { get }
}
