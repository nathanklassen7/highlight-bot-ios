import Foundation
import CoreMedia
import os
import OSLog

/// The one object on the capture queue. Every video sample goes to the
/// recorder (synchronously, on this thread) and its pixel buffer to the
/// `FrameTap` (non-blocking). Audio goes to the recorder and, if one is set,
/// the `AudioSampleListener` (voice trigger).
///
/// Timing of each video callback is recorded so the debug overlay and the
/// Phase 0 spike can check the <1 ms budget (`lastCallbackMicros`).
final class SampleFanout: SampleConsumer, Sendable {
    struct Counters: Sendable, Equatable {
        var capturedFrames: Int = 0
        var audioBuffers: Int = 0
        /// Frames dropped by the capture output itself (`didDrop`). Should stay 0.
        var droppedFrames: Int = 0
        /// Wall-clock duration of the most recent `consumeVideo`, in microseconds.
        var lastCallbackMicros: Double = 0
        /// Slowest `consumeVideo` seen so far, in microseconds.
        var maxCallbackMicros: Double = 0
    }

    let recorder: SegmentedRecorder
    let frameTap: FrameTap
    let audioListener: (any AudioSampleListener)?
    private let counters = OSAllocatedUnfairLock(initialState: Counters())

    init(recorder: SegmentedRecorder, frameTap: FrameTap, audioListener: (any AudioSampleListener)? = nil) {
        self.recorder = recorder
        self.frameTap = frameTap
        self.audioListener = audioListener
    }

    func consumeVideo(_ sampleBuffer: CMSampleBuffer) {
        let startNanos = DispatchTime.now().uptimeNanoseconds
        let interval = Signposts.capture.beginInterval("videoCallback")

        recorder.appendVideo(sampleBuffer)
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            frameTap.enqueue(
                pixelBuffer: pixelBuffer,
                presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )
        }

        Signposts.capture.endInterval("videoCallback", interval)
        let micros = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000
        counters.withLock {
            $0.capturedFrames += 1
            $0.lastCallbackMicros = micros
            if micros > $0.maxCallbackMicros { $0.maxCallbackMicros = micros }
        }
    }

    func consumeAudio(_ sampleBuffer: CMSampleBuffer) {
        // The recorder ignores audio when `recordAudio` is off (no audio input),
        // so the mic can feed the listener alone.
        recorder.appendAudio(sampleBuffer)
        audioListener?.consumeAudio(sampleBuffer)
        counters.withLock { $0.audioBuffers += 1 }
    }

    func didDropVideoFrame() {
        let total = counters.withLock { c -> Int in
            c.droppedFrames += 1
            return c.droppedFrames
        }
        Log.capture.error("Capture output dropped a video frame (total \(total))")
    }

    func snapshotCounters() -> Counters {
        counters.withLock { $0 }
    }
}
