import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import OSLog
import HighlightCore

/// Errors from `FileReplayCaptureSource`.
enum ReplayError: LocalizedError {
    case fileNotFound(URL)
    case noVideoTrack
    case readerFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url): return "Replay file not found: \(url.lastPathComponent)"
        case .noVideoTrack: return "Replay file has no video track."
        case .readerFailed(let message): return "Asset reader failed: \(message)"
        }
    }
}

/// Replays a movie file through the capture pipeline in real time, so the
/// full recorder → ring → export path runs in the Simulator and, later, ball
/// tracking can be developed against recorded games.
///
/// Samples are decoded with `AVAssetReader` (video as 420v pixel buffers,
/// audio as LPCM, exactly what the camera delivers), re-stamped onto the host
/// clock so timestamps increase monotonically across loops and restarts, and
/// paced by sleeping until each sample's new PTS. A dedicated `Thread` drives
/// the loop; `stop()` sets a flag and waits for it to exit.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class FileReplayCaptureSource: CaptureSource, @unchecked Sendable {
    let events: AsyncStream<CaptureEvent>

    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    private let fileURL: URL
    private let loop: Bool

    private let lock = NSLock()
    // Guarded by `lock`.
    private var consumer: (any SampleConsumer)?
    /// Captured on the main actor in `makePreviewLayer()`; safe to use off-main,
    /// unlike the owning `CALayer`.
    private var displayRenderer: AVSampleBufferVideoRenderer?
    private var config: RecordingConfig = .default
    private var stopRequested = false
    private var thread: Thread?
    private var asset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var audioTrack: AVAssetTrack?
    private var assetDuration: CMTime = .invalid

    init(fileURL: URL, loop: Bool = true) {
        self.fileURL = fileURL
        self.loop = loop
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(16))
        events = stream
        eventContinuation = continuation
    }

    deinit {
        eventContinuation.finish()
    }

    // MARK: - CaptureSource

    @MainActor
    func makePreviewLayer() -> CALayer {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspectFill
        // VERIFY: with no controlTimebase the layer interprets PTS against the host
        // clock. Replayed samples are stamped on the host clock and enqueued right at
        // their PTS, so they display immediately without extra attachments.
        let renderer = layer.sampleBufferRenderer
        lock.lock()
        displayRenderer = renderer
        lock.unlock()
        return layer
    }

    func setConsumer(_ consumer: (any SampleConsumer)?) {
        lock.lock()
        self.consumer = consumer
        lock.unlock()
    }

    func configure(_ config: RecordingConfig) async throws {
        lock.withLock { self.config = config }
    }

    func start() async throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            let error = ReplayError.fileNotFound(fileURL)
            Log.capture.error("\(error.localizedDescription, privacy: .public)")
            emit(.runtimeError(error.localizedDescription))
            throw error
        }

        let alreadyRunning = lock.withLock { thread != nil }
        if alreadyRunning { return }

        let asset = AVURLAsset(url: fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let video = videoTracks.first else {
            emit(.runtimeError(ReplayError.noVideoTrack.localizedDescription))
            throw ReplayError.noVideoTrack
        }
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let naturalSize = try await video.load(.naturalSize)
        let nominalFPS = try await video.load(.nominalFrameRate)

        let requested: RecordingConfig = lock.withLock {
            self.asset = asset
            videoTrack = video
            audioTrack = config.recordAudio ? audio : nil
            assetDuration = duration
            stopRequested = false
            return config
        }

        let width = Int(naturalSize.width.rounded())
        let height = Int(naturalSize.height.rounded())
        let fps = max(1, Int(nominalFPS.rounded()))
        if width != requested.width || height != requested.height || fps != requested.frameRate {
            emit(.formatChanged(width: width, height: height, frameRate: fps))
        }

        let replayThread = Thread { [self] in
            self.replayLoop()
        }
        replayThread.name = "com.highlightbot.replay"
        replayThread.qualityOfService = .userInteractive
        lock.withLock { thread = replayThread }
        replayThread.start()

        Log.capture.info("Replay started: \(self.fileURL.lastPathComponent, privacy: .public) \(width)x\(height)@\(fps) loop=\(self.loop)")
        emit(.started)
    }

    func stop() async {
        let running: Thread? = lock.withLock {
            stopRequested = true
            return thread
        }
        guard let running else { return }

        // The loop checks the flag once per sample (≤ 1 frame interval), so this
        // normally returns within a few tens of milliseconds.
        var waited = 0
        while !running.isFinished && waited < 40 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        lock.withLock {
            if thread === running { thread = nil }
        }
        emit(.stopped)
    }

    /// Replay cannot change the file's frame rate.
    func setFrameRate(_ fps: Int) async {}

    // MARK: - Replay loop (dedicated thread)

    private func isStopRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func replayLoop() {
        lock.lock()
        let asset = self.asset
        let videoTrack = self.videoTrack
        let audioTrack = self.audioTrack
        let assetDuration = self.assetDuration
        lock.unlock()
        guard let asset, let videoTrack else { return }

        let hostClock = CMClockGetHostTimeClock()
        // All output timestamps are host-clock based, so the recorder sees the
        // same kind of monotonically increasing PTS the camera would produce.
        let base = CMClockGetTime(hostClock)
        var loopOffset = CMTime.zero
        var pass = 0

        repeat {
            pass += 1
            var passEnd = CMTime.zero
            do {
                try runPass(asset: asset,
                            videoTrack: videoTrack,
                            audioTrack: audioTrack,
                            outputBase: base + loopOffset,
                            hostClock: hostClock,
                            passEnd: &passEnd)
            } catch {
                Log.capture.error("Replay pass \(pass) failed: \(error.localizedDescription, privacy: .public)")
                emit(.runtimeError(error.localizedDescription))
                break
            }
            let advance = assetDuration.isValid && assetDuration.seconds > 0 ? assetDuration : passEnd
            loopOffset = loopOffset + advance
        } while loop && !isStopRequested()

        Log.capture.info("Replay loop exited after \(pass) pass(es)")
    }

    /// Reads the asset once, delivering every sample at `outputBase + pts`.
    private func runPass(asset: AVURLAsset,
                         videoTrack: AVAssetTrack,
                         audioTrack: AVAssetTrack?,
                         outputBase: CMTime,
                         hostClock: CMClock,
                         passEnd: inout CMTime) throws {
        let reader = try AVAssetReader(asset: asset)

        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw ReplayError.readerFailed("cannot add video output") }
        reader.add(videoOutput)

        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
            ])
            output.alwaysCopiesSampleData = false
            if reader.canAdd(output) {
                reader.add(output)
                audioOutput = output
            }
        }

        guard reader.startReading() else {
            throw ReplayError.readerFailed(reader.error?.localizedDescription ?? "startReading returned false")
        }
        defer { reader.cancelReading() }

        var pendingVideo = videoOutput.copyNextSampleBuffer()
        var pendingAudio = audioOutput?.copyNextSampleBuffer()

        while !isStopRequested() {
            // Interleave by presentation time so audio and video arrive in order.
            let takeAudio: Bool
            switch (pendingVideo, pendingAudio) {
            case (nil, nil):
                return
            case (nil, .some):
                takeAudio = true
            case (.some, nil):
                takeAudio = false
            case let (.some(video), .some(audio)):
                takeAudio = CMSampleBufferGetPresentationTimeStamp(audio) < CMSampleBufferGetPresentationTimeStamp(video)
            }

            guard let sample = takeAudio ? pendingAudio : pendingVideo else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetDuration(sample)
            if duration.isValid {
                let end = pts + duration
                if end > passEnd { passEnd = end }
            } else if pts > passEnd {
                passEnd = pts
            }

            let offset = outputBase
            let outputPTS = pts + offset
            waitUntil(outputPTS, on: hostClock)

            if let retimed = Self.retimed(sample, offset: offset) {
                deliver(retimed, isVideo: !takeAudio)
            }

            if takeAudio {
                pendingAudio = audioOutput?.copyNextSampleBuffer()
            } else {
                pendingVideo = videoOutput.copyNextSampleBuffer()
            }
        }
    }

    private func waitUntil(_ time: CMTime, on clock: CMClock) {
        let now = CMClockGetTime(clock)
        let wait = (time - now).seconds
        if wait > 0.0005 {
            Thread.sleep(forTimeInterval: wait)
        }
    }

    private func deliver(_ sample: CMSampleBuffer, isVideo: Bool) {
        lock.lock()
        let consumer = self.consumer
        let renderer = self.displayRenderer
        lock.unlock()

        if isVideo {
            consumer?.consumeVideo(sample)
            if let renderer {
                if renderer.status == .failed {
                    renderer.flush()
                }
                if renderer.isReadyForMoreMediaData {
                    renderer.enqueue(sample)
                }
            }
        } else {
            consumer?.consumeAudio(sample)
        }
    }

    /// Copies `sample` with every timing entry shifted by `offset`. Uses the
    /// buffer's own timing array so multi-sample audio buffers keep their
    /// per-sample durations.
    private static func retimed(_ sample: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var entryCount: CMItemCount = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entryCount)
        guard status == noErr, entryCount > 0 else { return nil }

        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: Int(entryCount))
        status = timing.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: entryCount, arrayToFill: buffer.baseAddress, entriesNeededOut: &entryCount)
        }
        guard status == noErr else { return nil }

        for index in timing.indices {
            timing[index].presentationTimeStamp = timing[index].presentationTimeStamp + offset
            if timing[index].decodeTimeStamp.isValid {
                timing[index].decodeTimeStamp = timing[index].decodeTimeStamp + offset
            }
        }

        var copy: CMSampleBuffer?
        status = timing.withUnsafeBufferPointer { buffer -> OSStatus in
            CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault,
                sampleBuffer: sample,
                sampleTimingEntryCount: entryCount,
                sampleTimingArray: buffer.baseAddress,
                sampleBufferOut: &copy
            )
        }
        guard status == noErr else { return nil }
        return copy
    }

    private func emit(_ event: CaptureEvent) {
        eventContinuation.yield(event)
    }
}
