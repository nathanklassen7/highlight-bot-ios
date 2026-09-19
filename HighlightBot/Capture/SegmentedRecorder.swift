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
/// Writer start is eager: `startWriting()` is where VideoToolbox builds the
/// hardware encoder (100–300 ms). Doing that inside the first capture callback
/// stalls the data output long enough to drop frames, so `start()` does it
/// before any consumer is attached. `initialSegmentStartTime` must be set
/// before `startWriting()` but need not equal the first frame's PTS; it is
/// read from the source's capture clock, and segment boundaries fall at
/// `initialSegmentStartTime + N * segmentInterval`. The first `appendVideo`
/// then only calls `startSession(atSourceTime:)` with the real first PTS.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class SegmentedRecorder: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    private let config: RecordingConfig
    private let queue: DispatchQueue
    private let onSegment: @Sendable (IncomingSegment) -> Void
    /// Display rotation stamped into the video track (degrees). Metadata only.
    private let videoRotationAngle: CGFloat
    /// Clock the source stamps samples with; used to choose the writer start time.
    private let clock: CMClock

    private let lock = NSLock()
    // All of the following are guarded by `lock`.
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var sessionStarted = false
    /// `initialSegmentStartTime`; segment boundaries are measured from here.
    private var writerStartTime: CMTime = .invalid
    private var sessionStartPTS: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var sessionID: SessionID?
    private var mediaSeq = 0
    private var skippedVideoAppendCount = 0
    private var skippedAudioAppendCount = 0
    private var didLogFailure = false
    private var lastWriteMillis: Double = 0
    private var lastSegmentSeq = -1

    init(config: RecordingConfig,
         queue: DispatchQueue,
         videoRotationAngle: CGFloat = 0,
         clock: CMClock = CMClockGetHostTimeClock(),
         onSegment: @escaping @Sendable (IncomingSegment) -> Void) {
        self.config = config
        self.queue = queue
        self.videoRotationAngle = videoRotationAngle
        self.clock = clock
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

    /// Appends skipped because an input was not ready (video + audio).
    var skippedAppends: Int {
        lock.lock(); defer { lock.unlock() }
        return skippedVideoAppendCount + skippedAudioAppendCount
    }

    /// Video appends skipped. Non-zero means the encoder is falling behind;
    /// should stay 0 at the target bitrate.
    var skippedVideoAppends: Int {
        lock.lock(); defer { lock.unlock() }
        return skippedVideoAppendCount
    }

    /// Audio appends skipped. Every skip is an audible gap (click/scratch).
    var skippedAudioAppends: Int {
        lock.lock(); defer { lock.unlock() }
        return skippedAudioAppendCount
    }

    // MARK: - Lifecycle

    /// Creates a fresh writer and a new `SessionID`, and starts writing so the
    /// encoder is warm before frames arrive. Call before attaching the
    /// recorder as a consumer; not from the capture queue. Idempotent while
    /// running.
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
        if videoRotationAngle != 0 {
            video.transform = CGAffineTransform(rotationAngle: videoRotationAngle * .pi / 180)
        }
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

        // VERIFY on device: AVAssetWriter.h requires a numeric initialSegmentStartTime when
        // preferredOutputSegmentInterval is positive, set before startWriting(). Using the
        // capture clock's "now" (rather than the first PTS) lets startWriting() — and the
        // encoder allocation it triggers — run here instead of inside the first capture
        // callback. Frames arrive after this point, so their PTS is ≥ this time.
        let startTime = CMClockGetTime(clock)
        newWriter.initialSegmentStartTime = startTime
        guard newWriter.startWriting() else {
            let message = newWriter.error?.localizedDescription ?? "status \(newWriter.status.rawValue)"
            Log.recorder.error("startWriting failed: \(message, privacy: .public)")
            return
        }

        writer = newWriter
        videoInput = video
        audioInput = audio
        sessionID = newSessionID
        sessionStarted = false
        writerStartTime = startTime
        sessionStartPTS = .invalid
        lastVideoPTS = .invalid
        mediaSeq = 0
        lastSegmentSeq = -1
        skippedVideoAppendCount = 0
        skippedAudioAppendCount = 0
        didLogFailure = false
        Log.recorder.info("Recorder writing session \(newSessionID.description, privacy: .public) (\(self.config.width)x\(self.config.height)@\(self.config.frameRate) \(self.config.codec.rawValue, privacy: .public)) from \(startTime.seconds, format: .fixed(precision: 3))")
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
    /// writer start time and the last appended video PTS. Nil before the
    /// session starts. Used by the pipeline to size its wait after a trigger.
    var secondsUntilNextBoundary: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard sessionStarted, writerStartTime.isValid, lastVideoPTS.isValid else { return nil }
        let elapsed = (lastVideoPTS - writerStartTime).seconds
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
            // Writing but no session was ever started (no frame arrived): the
            // writer holds no samples. Cancel rather than finish so it does not
            // try to emit segments for an empty session.
            if writer.status == .writing {
                writer.cancelWriting()
            }
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
            guard writer.status == .writing else {
                logFailureOnce(writer, context: "startSession (writer not writing)")
                return
            }
            // A frame captured before the writer start time (in flight when the
            // consumer attached) cannot belong to the first segment; skip it.
            guard pts >= writerStartTime else { return }
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
            sessionStartPTS = pts
            Log.recorder.info("Writer session started at pts=\(pts.seconds, format: .fixed(precision: 3)) (\((pts - self.writerStartTime).seconds * 1_000, format: .fixed(precision: 0)) ms after writer start)")
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
            skippedVideoAppendCount += 1
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
            skippedAudioAppendCount += 1
            if skippedAudioAppendCount == 1 || skippedAudioAppendCount % 50 == 0 {
                Log.recorder.notice("Audio input not ready; skipped \(self.skippedAudioAppendCount) audio buffers so far (audible gap)")
            }
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
