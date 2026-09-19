import Foundation
import AVFoundation
import CoreMedia
import UniformTypeIdentifiers
import OSLog
import HighlightCore

/// One `AVAssetWriter` in fMP4 segmented mode (`.mpeg4AppleHLS`). Emits an
/// initialization segment followed by fixed-interval media segments through
/// `onSegment`; the ring buffer persists them. Each media segment starts on
/// a keyframe the writer forces at the boundary, so any run of consecutive
/// segments from one session concatenates into a playable stream.
///
/// Threading:
/// - `appendVideo`/`appendAudio` run on the caller's (capture) queue. They
///   take `lock`, append, release. This is the whole hot path.
/// - `start()`/`stop()`/`restart()` mutate the writer under the same `lock`.
/// - `flushSegment()` is serialized on the injected `queue` (and is currently
///   a no-op; see `supportsOnDemandFlush`).
/// - The delegate callback arrives on AVFoundation's own queue and only reads
///   session bookkeeping under `lock`.
///
/// Session start is lazy: `AVAssetWriter.initialSegmentStartTime` cannot be
/// changed after `startWriting()`, and we do not know the first PTS until the
/// first video sample arrives. So `start()` builds the writer and inputs, and
/// the first `appendVideo` sets `initialSegmentStartTime`, calls
/// `startWriting()`, then `startSession(atSourceTime:)` with that PTS.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class SegmentedRecorder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let config: RecordingConfig
    private let queue: DispatchQueue
    private let onSegment: @Sendable (IncomingSegment) -> Void

    private let lock = NSLock()
    // All of the following are guarded by `lock`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var sessionStartPTS: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var sessionID: SessionID?
    private var mediaSeq = 0
    private var skippedAppendCount = 0
    private var didLogFailure = false
    private var lastWriteMillis: Double = 0
    private var lastSegmentSeq = -1

    init(config: RecordingConfig,
         queue: DispatchQueue,
         onSegment: @escaping @Sendable (IncomingSegment) -> Void) {
        self.config = config
        self.queue = queue
        self.onSegment = onSegment
        super.init()
    }

    // MARK: - Observability

    /// Session the writer is currently producing (or last produced) segments for.
    var currentSessionID: SessionID? {
        lock.lock(); defer { lock.unlock() }
        return sessionID
    }

    /// True between `start()` and `stop()`, even before the first frame arrives.
    var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return writer != nil
    }

    /// Time from the writer's delegate callback to `onSegment` returning, in ms.
    var lastSegmentWriteMillis: Double {
        lock.lock(); defer { lock.unlock() }
        return lastWriteMillis
    }

    /// Sequence number of the most recently emitted segment (-1 before any).
    var lastEmittedSegmentSeq: Int {
        lock.lock(); defer { lock.unlock() }
        return lastSegmentSeq
    }

    /// Appends skipped because the input was not ready. Non-zero means the
    /// encoder is falling behind; should stay 0 at the target bitrate.
    var skippedAppends: Int {
        lock.lock(); defer { lock.unlock() }
        return skippedAppendCount
    }

    // MARK: - Lifecycle

    /// Creates a fresh writer and a new `SessionID`. Idempotent while running.
    func start() {
        lock.lock(); defer { lock.unlock() }
        guard writer == nil else { return }

        let newSessionID = SessionID()
        let newWriter = AVAssetWriter(contentType: .mpeg4Movie)
        newWriter.outputFileTypeProfile = .mpeg4AppleHLS
        // Timescale 600 keeps fractional intervals exact if the constant ever changes.
        newWriter.preferredOutputSegmentInterval = CMTime(seconds: config.segmentInterval, preferredTimescale: 600)
        newWriter.delegate = self

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(for: config))
        video.expectsMediaDataInRealTime = true
        guard newWriter.canAdd(video) else {
            Log.recorder.error("Writer rejected video input settings")
            return
        }
        newWriter.add(video)

        var audio: AVAssetWriterInput?
        if config.recordAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            input.expectsMediaDataInRealTime = true
            if newWriter.canAdd(input) {
                newWriter.add(input)
                audio = input
            } else {
                Log.recorder.error("Writer rejected audio input settings; recording video only")
            }
        }

        writer = newWriter
        videoInput = video
        audioInput = audio
        sessionID = newSessionID
        sessionStarted = false
        sessionStartPTS = .invalid
        lastVideoPTS = .invalid
        mediaSeq = 0
        lastSegmentSeq = -1
        skippedAppendCount = 0
        didLogFailure = false
        Log.recorder.info("Recorder prepared session \(newSessionID.description, privacy: .public) (\(self.config.width)x\(self.config.height)@\(self.config.frameRate) \(self.config.codec.rawValue, privacy: .public))")
    }

    /// Whether an on-demand flush is possible. Always `false` today.
    ///
    /// Per the AVAssetWriter.h header (verified against the Xcode 26 SDK):
    /// `-flushSegment` "throws an exception ... if the value of the
    /// preferredOutputSegmentInterval property is not kCMTimeIndefinite", and
    /// in the indefinite mode "only passthrough is available" — the writer will
    /// not compress. Since this recorder relies on the writer's encoder with a
    /// fixed interval, calling `writer.flushSegment()` would crash. The writer
    /// instead closes each segment on a forced keyframe exactly at
    /// `initialSegmentStartTime + N * segmentInterval`, so the trigger tail
    /// arrives within one `segmentInterval`; `RecordingPipeline.saveClip` waits
    /// for that boundary. Switching to indefinite mode would require driving a
    /// VideoToolbox compression session ourselves (a Phase 0 spike decision).
    var supportsOnDemandFlush: Bool { false }

    /// Requests the in-progress segment be emitted early. Returns `true` only
    /// if the writer honours the request; `false` means the caller should wait
    /// for the next fixed-interval boundary instead. See `supportsOnDemandFlush`.
    @discardableResult
    func flushSegment() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async {
                self.lock.lock()
                let writing = self.writer != nil && self.sessionStarted
                self.lock.unlock()
                // Intentionally never calls AVAssetWriter.flushSegment(); see supportsOnDemandFlush.
                Log.recorder.debug("flushSegment: fixed-interval mode, waiting for boundary (writing=\(writing))")
                continuation.resume(returning: false)
            }
        }
    }

    /// Seconds until the writer closes the current segment, based on the
    /// session start and the last appended video PTS. Nil before the session
    /// starts. Used by the pipeline to size its wait after a trigger.
    var secondsUntilNextBoundary: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard sessionStarted, sessionStartPTS.isValid, lastVideoPTS.isValid else { return nil }
        let elapsed = (lastVideoPTS - sessionStartPTS).seconds
        guard elapsed.isFinite, elapsed >= 0, config.segmentInterval > 0 else { return nil }
        let intoSegment = elapsed.truncatingRemainder(dividingBy: config.segmentInterval)
        return config.segmentInterval - intoSegment
    }

    /// Marks inputs finished and waits for `finishWriting`, which delivers the
    /// final media segment through the delegate before returning. Session
    /// bookkeeping (`sessionID`, start PTS) is kept until the next `start()`
    /// so that final segment is tagged correctly.
    func stop() async {
        let (writer, video, audio, started) = takeWriter()

        guard let writer else { return }
        guard started, writer.status == .writing else {
            // Never started a session: nothing on disk, nothing to finish.
            Log.recorder.info("Recorder stopped before any frame arrived")
            return
        }

        video?.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            Log.recorder.error("finishWriting failed: \(writer.error?.localizedDescription ?? "unknown", privacy: .public)")
        } else {
            Log.recorder.info("Recorder stopped (status \(writer.status.rawValue))")
        }
    }

    /// Detaches the writer and inputs from the recorder so no further appends
    /// reach them. Synchronous because `NSLock` may not be used from async code.
    private func takeWriter() -> (AVAssetWriter?, AVAssetWriterInput?, AVAssetWriterInput?, Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (writer, videoInput, audioInput, sessionStarted)
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
        return result
    }

    /// Stop, then start with a new `SessionID`. The ring buffer treats the new
    /// initialization segment as a session boundary and evicts the old one.
    func restart() async {
        await stop()
        start()
    }

    // MARK: - Appending (capture queue)

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let writer, let input = videoInput else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        lastVideoPTS = pts

        if !sessionStarted {
            // startWriting() may only be attempted once per writer; a failed writer stays failed
            // until restart() replaces it.
            guard writer.status == .unknown else {
                logFailureOnce(writer, context: "startWriting (writer already failed)")
                return
            }
            // VERIFY on device: AVAssetWriter.h says a numeric initialSegmentStartTime is required
            // when preferredOutputSegmentInterval is positive and "cannot be set after writing has
            // started", so it is set here, immediately before startWriting(), to the first
            // sample's PTS, and startSession uses the same time (as in the WWDC20 fMP4 sample).
            // Segment boundaries then fall at firstPTS + N * segmentInterval.
            writer.initialSegmentStartTime = pts
            guard writer.startWriting() else {
                logFailureOnce(writer, context: "startWriting")
                return
            }
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            sessionStartPTS = pts
            Log.recorder.info("Writer session started at pts=\(pts.seconds, format: .fixed(precision: 3))")
        }

        guard writer.status == .writing else {
            logFailureOnce(writer, context: "append")
            return
        }
        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                logFailureOnce(writer, context: "appendVideo")
            }
        } else {
            skippedAppendCount += 1
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard sessionStarted, let writer, writer.status == .writing, let input = audioInput else { return }
        if input.isReadyForMoreMediaData {
            if !input.append(sampleBuffer) {
                logFailureOnce(writer, context: "appendAudio")
            }
        } else {
            skippedAppendCount += 1
        }
    }

    /// Must be called with `lock` held.
    private func logFailureOnce(_ writer: AVAssetWriter, context: String) {
        guard !didLogFailure else { return }
        didLogFailure = true
        let message = writer.error?.localizedDescription ?? "status \(writer.status.rawValue)"
        Log.recorder.error("Writer failure during \(context, privacy: .public): \(message, privacy: .public)")
    }

    // MARK: - AVAssetWriterDelegate

    func assetWriter(_ writer: AVAssetWriter,
                     didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType,
                     segmentReport: AVAssetSegmentReport?) {
        let startNanos = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        guard let sessionID = self.sessionID else {
            lock.unlock()
            return
        }
        let startPTS = sessionStartPTS
        let seq: Int
        let kind: SegmentKind
        switch segmentType {
        case .initialization:
            seq = 0
            kind = .initialization
        case .separable:
            mediaSeq += 1
            seq = mediaSeq
            kind = .media
        @unknown default:
            lock.unlock()
            Log.recorder.error("Unknown segment type \(segmentType.rawValue)")
            return
        }
        lock.unlock()

        var startTime: TimeInterval = 0
        var duration: TimeInterval = 0
        if kind == .media {
            if let report = segmentReport?.trackReports.first(where: { $0.mediaType == .video }),
               startPTS.isValid {
                let rebased = report.earliestPresentationTimeStamp - startPTS
                startTime = max(0, rebased.seconds)
                duration = max(0, report.duration.seconds)
            } else {
                // No report (or no video track report): assume nominal spacing.
                startTime = Double(seq - 1) * config.segmentInterval
                duration = config.segmentInterval
            }
        }

        let segment = IncomingSegment(
            sessionID: sessionID,
            seq: seq,
            kind: kind,
            data: segmentData,
            startTime: startTime,
            duration: duration
        )
        onSegment(segment)

        let millis = Double(DispatchTime.now().uptimeNanoseconds - startNanos) / 1_000_000
        lock.lock()
        lastWriteMillis = millis
        lastSegmentSeq = seq
        lock.unlock()

        Log.recorder.debug("segment session=\(sessionID.description, privacy: .public) seq=\(seq) kind=\(kind.rawValue, privacy: .public) bytes=\(segmentData.count) start=\(startTime, format: .fixed(precision: 3)) dur=\(duration, format: .fixed(precision: 3)) handoffMs=\(millis, format: .fixed(precision: 2))")
    }

    // MARK: - Settings

    private static func videoSettings(for config: RecordingConfig) -> [String: Any] {
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: config.videoBitrate,
            AVVideoExpectedSourceFrameRateKey: config.frameRate,
            AVVideoMaxKeyFrameIntervalDurationKey: config.segmentInterval,
            AVVideoAllowFrameReorderingKey: false,
        ]
        let codec: AVVideoCodecType
        switch config.codec {
        case .h264:
            codec = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        case .hevc:
            codec = .hevc
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: config.width,
            AVVideoHeightKey: config.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// AAC mono 48 kHz. The phone mic is mono; letting the writer convert the
    /// source rate/channels avoids a hard failure if the audio session picks
    /// a different rate.
    /// Computed rather than a `static let` because `[String: Any]` is not
    /// `Sendable` and Swift 6 rejects non-Sendable global state.
    private static var audioSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ]
    }
}
