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

/// A camera or a file replay. Not an actor: each implementation owns its own
/// serial queue and hops onto it for configuration and lifecycle work.
protocol CaptureSource: AnyObject {
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
    /// Rotation, in degrees, that makes recorded video horizon-level given the
    /// data output delivers frames in the sensor's native orientation. Read at
    /// recording start and stamped into the file as metadata (no per-frame work).
    var captureRotationAngle: CGFloat { get }
}
