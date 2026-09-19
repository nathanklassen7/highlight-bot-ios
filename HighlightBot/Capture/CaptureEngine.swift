import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import QuartzCore
import os
import OSLog
import HighlightCore

/// Errors raised while configuring or starting the camera.
enum CaptureError: LocalizedError {
    case noCamera
    case noSuitableFormat
    case cannotAddInput(String)
    case cannotAddOutput(String)
    case notConfigured
    case failedToStart

    var errorDescription: String? {
        switch self {
        case .noCamera: return "No back camera is available."
        case .noSuitableFormat: return "The camera has no usable video format."
        case .cannotAddInput(let what): return "Cannot add \(what) input to the capture session."
        case .cannotAddOutput(let what): return "Cannot add \(what) output to the capture session."
        case .notConfigured: return "Capture session has not been configured."
        case .failedToStart: return "Capture session failed to start."
        }
    }
}

/// The real camera. Owns one `AVCaptureSession` with a video data output and,
/// when `recordAudio` is on, an audio data output. Both deliver on a dedicated
/// serial queue and are forwarded verbatim to the current `SampleConsumer`.
///
/// Threading: all session/device configuration happens on `queue`. Public
/// async methods hop onto it and resume a continuation when done.
/// `@unchecked Sendable`: every mutable member is only touched on `queue`
/// (or via `forwarder`, which has its own lock).
final class CaptureEngine: CaptureSource, @unchecked Sendable {
    let events: AsyncStream<CaptureEvent>

    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation
    private let queue = DispatchQueue(label: "com.highlightbot.capture", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let forwarder = SampleForwarder()

    // Guarded by `queue`.
    private var videoDevice: AVCaptureDevice?
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var config: RecordingConfig?
    private var currentFrameRate: Int = 0
    private var isConfigured = false

    private var observers: [NSObjectProtocol] = []

    /// Preview orientation state. Everything here is touched only on the main
    /// actor; `rotation` publishes the capture angle for other queues.
    @MainActor private weak var previewLayer: AVCaptureVideoPreviewLayer?
    @MainActor private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    @MainActor private var rotationObservation: NSKeyValueObservation?
    private let rotation = OSAllocatedUnfairLock<CGFloat>(initialState: 0)

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(16))
        events = stream
        eventContinuation = continuation
        installNotificationObservers()
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        eventContinuation.finish()
    }

    // MARK: - CaptureSource

    @MainActor
    func makePreviewLayer() -> CALayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        previewLayer = layer
        // The preview connection only exists once the session has a video input.
        // If we are already configured, wire orientation now; otherwise
        // `configureOnQueue` does it as soon as the device is chosen.
        queue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            nonisolated(unsafe) let chosenDevice = device
            Task { @MainActor in self.installRotationCoordinator(device: chosenDevice) }
        }
        return layer
    }

    var captureRotationAngle: CGFloat {
        rotation.withLock { $0 }
    }

    /// Keeps the preview upright for whichever way the phone is held and
    /// publishes the matching capture angle. Idempotent per device.
    @MainActor
    private func installRotationCoordinator(device: AVCaptureDevice) {
        if let existing = rotationCoordinator, existing.device == device, previewLayer != nil {
            applyPreviewRotation(existing.videoRotationAngleForHorizonLevelPreview)
            return
        }
        rotationObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyPreviewRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        let initialCapture = Self.landscapeAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotation.withLock { $0 = initialCapture }
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            let preview = coordinator.videoRotationAngleForHorizonLevelPreview
            let capture = coordinator.videoRotationAngleForHorizonLevelCapture
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyPreviewRotation(preview)
                self.rotation.withLock { current in
                    current = Self.landscapeAngle(capture, last: current)
                }
            }
        }
    }

    @MainActor
    private func applyPreviewRotation(_ angle: CGFloat) {
        let landscape = rotation.withLock { current in
            let snapped = Self.landscapeAngle(angle, last: current)
            return snapped
        }
        guard let connection = previewLayer?.connection,
              connection.isVideoRotationAngleSupported(landscape) else { return }
        connection.videoRotationAngle = landscape
    }

    /// Clips are landscape-only. Portrait device tilts (90°/270°) must not be
    /// written into the file transform; keep the last landscape heading instead.
    private static func landscapeAngle(_ angle: CGFloat, last: CGFloat = 0) -> CGFloat {
        var a = angle.truncatingRemainder(dividingBy: 360)
        if a < 0 { a += 360 }
        if a < 45 || a >= 315 { return 0 }
        if a >= 135 && a < 225 { return 180 }
        return last == 180 ? 180 : 0
    }

    func setConsumer(_ consumer: (any SampleConsumer)?) {
        forwarder.setConsumer(consumer)
    }

    func configure(_ config: RecordingConfig) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try self.configureOnQueue(config)
                    continuation.resume()
                } catch {
                    Log.capture.error("configure failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    guard self.isConfigured else { throw CaptureError.notConfigured }
                    try self.activateAudioSessionIfNeeded()
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    guard self.session.isRunning else { throw CaptureError.failedToStart }
                    Log.capture.info("Capture session running at \(self.currentFrameRate) fps")
                    self.emit(.started)
                    continuation.resume()
                } catch {
                    Log.capture.error("start failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.session.isRunning {
                    self.session.stopRunning()
                }
                self.deactivateAudioSession()
                Log.capture.info("Capture session stopped")
                self.emit(.stopped)
                continuation.resume()
            }
        }
    }

    func setFrameRate(_ fps: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                defer { continuation.resume() }
                guard let device = self.videoDevice else { return }
                guard fps > 0, Self.formatSupports(device.activeFormat, fps: fps) else {
                    Log.capture.notice("setFrameRate(\(fps)) unsupported by active format; ignoring")
                    return
                }
                guard fps != self.currentFrameRate else { return }
                do {
                    try device.lockForConfiguration()
                    let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                    device.activeVideoMinFrameDuration = duration
                    device.activeVideoMaxFrameDuration = duration
                    device.unlockForConfiguration()
                    self.currentFrameRate = fps
                    let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                    Log.capture.notice("Frame rate changed to \(fps) fps")
                    self.emit(.formatChanged(width: Int(dims.width), height: Int(dims.height), frameRate: fps))
                } catch {
                    Log.capture.error("setFrameRate lockForConfiguration failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    // MARK: - Configuration (on queue)

    private func configureOnQueue(_ config: RecordingConfig) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // Tear down anything from a previous configure so reconfiguration is safe.
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        videoDeviceInput = nil
        audioDeviceInput = nil
        videoOutput = nil
        audioOutput = nil

        // .inputPriority lets the device's activeFormat win over a preset.
        if session.canSetSessionPreset(.inputPriority) {
            session.sessionPreset = .inputPriority
        }
        // We configure AVAudioSession ourselves (category/mode/options) in start().
        session.automaticallyConfiguresApplicationAudioSession = false
        // Keep the device in its default (sRGB / 420v-friendly) colour space; wide
        // colour would push the session toward 10-bit 'x420' formats we don't want.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CaptureError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput("camera") }
        session.addInput(input)
        videoDevice = device
        videoDeviceInput = input
        // AVCaptureDevice is safe to reference from another thread; the compiler
        // just cannot prove it.
        nonisolated(unsafe) let chosenDevice = device
        Task { @MainActor [weak self] in self?.installRotationCoordinator(device: chosenDevice) }

        guard let choice = Self.chooseFormat(for: device, config: config) else {
            throw CaptureError.noSuitableFormat
        }
        try device.lockForConfiguration()
        device.activeFormat = choice.format
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(choice.frameRate))
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
        currentFrameRate = choice.frameRate

        let video = AVCaptureVideoDataOutput()
        // Rule 2.4/3: the encoder must see every frame; dropping is FrameTap's job.
        video.alwaysDiscardsLateVideoFrames = false
        video.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        video.setSampleBufferDelegate(forwarder, queue: queue)
        guard session.canAddOutput(video) else { throw CaptureError.cannotAddOutput("video data") }
        session.addOutput(video)
        videoOutput = video

        if let connection = video.connection(with: .video) {
            // 0° is the back camera's native orientation (landscape, home indicator on
            // the right), so no per-frame rotation happens. Orientation for the file is
            // applied as writer metadata from `captureRotationAngle` instead.
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
        }

        if config.recordAudio {
            if let mic = AVCaptureDevice.default(for: .audio) {
                let micInput = try AVCaptureDeviceInput(device: mic)
                if session.canAddInput(micInput) {
                    session.addInput(micInput)
                    audioDeviceInput = micInput
                    let audio = AVCaptureAudioDataOutput()
                    audio.setSampleBufferDelegate(forwarder, queue: queue)
                    if session.canAddOutput(audio) {
                        session.addOutput(audio)
                        audioOutput = audio
                    } else {
                        Log.capture.error("Cannot add audio data output; recording video only")
                    }
                } else {
                    Log.capture.error("Cannot add microphone input; recording video only")
                }
            } else {
                Log.capture.error("No microphone available; recording video only")
            }
        }

        self.config = config
        isConfigured = true

        Log.capture.info("Configured \(choice.width)x\(choice.height)@\(choice.frameRate) pixelFormat=\(Self.fourCC(choice.pixelFormat), privacy: .public) exact=\(choice.isExact)")
        if !choice.isExact {
            emit(.formatChanged(width: choice.width, height: choice.height, frameRate: choice.frameRate))
        }
    }

    private func activateAudioSessionIfNeeded() throws {
        guard config?.recordAudio == true, audioDeviceInput != nil else { return }
        let audioSession = AVAudioSession.sharedInstance()
        // Built-in mic only. Allowing Bluetooth HFP would route the microphone through
        // any connected headset/watch/car at narrowband quality, which sounds like loud
        // scratching when the link is marginal. Court-side audio wants the phone mic.
        try audioSession.setCategory(.playAndRecord, mode: .videoRecording, options: [.defaultToSpeaker])
        try audioSession.setActive(true)
    }

    private func deactivateAudioSession() {
        guard config?.recordAudio == true else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            Log.capture.notice("AVAudioSession deactivate failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notifications

    private func installNotificationObservers() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] notification in
            let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap { AVCaptureSession.InterruptionReason(rawValue: $0) }
            let text = Self.describe(reason)
            Log.capture.notice("Capture interrupted: \(text, privacy: .public)")
            self?.emit(.interrupted(reason: text))
        })

        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            Log.capture.notice("Capture interruption ended")
            self?.emit(.resumed)
        })

        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            let message = error?.localizedDescription ?? "unknown runtime error"
            Log.capture.error("Capture runtime error: \(message, privacy: .public)")
            guard let self else { return }
            if error?.code == .mediaServicesWereReset {
                self.recoverFromMediaServicesReset()
            } else {
                self.emit(.runtimeError(message))
            }
        })
    }

    /// Media services reset kills the session and the encoder. Treat it as an
    /// interruption: restart the session on our queue and report `.resumed`
    /// so the pipeline starts a fresh writer session, or `.runtimeError` if
    /// the restart did not take.
    private func recoverFromMediaServicesReset() {
        emit(.interrupted(reason: "media services were reset"))
        queue.async {
            guard self.isConfigured else { return }
            if !self.session.isRunning {
                self.session.startRunning()
            }
            if self.session.isRunning {
                Log.capture.notice("Capture session restarted after media services reset")
                self.emit(.resumed)
            } else {
                self.emit(.runtimeError("Capture session could not restart after media services reset"))
            }
        }
    }

    private func emit(_ event: CaptureEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - Format selection

    private struct FormatChoice {
        let format: AVCaptureDevice.Format
        let width: Int
        let height: Int
        let frameRate: Int
        let pixelFormat: OSType
        /// True when width, height, frame rate, and pixel format all match the request.
        let isExact: Bool
    }

    /// Picks the format closest to `config`: exact dimensions first, then 420v
    /// pixel format, then a frame-rate range covering the requested fps.
    /// Among equals, prefer formats that can also run at 30 fps (so thermal
    /// downgrade does not need a session reconfigure), then unbinned formats,
    /// then the lowest max frame rate that still satisfies the request
    /// (high-fps slo-mo formats often disable features like stabilisation).
    private static func chooseFormat(for device: AVCaptureDevice, config: RecordingConfig) -> FormatChoice? {
        let wanted = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let wantedArea = config.width * config.height

        var best: FormatChoice?
        var bestScore = Int.min

        for format in device.formats {
            let description = format.formatDescription
            guard CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video else { continue }
            let dims = CMVideoFormatDescriptionGetDimensions(description)
            let width = Int(dims.width)
            let height = Int(dims.height)
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            let maxFPS = Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
            guard maxFPS > 0 else { continue }

            let dimsMatch = width == config.width && height == config.height
            let pixelMatch = subtype == wanted
            let fpsOK = formatSupports(format, fps: config.frameRate)

            var score = 0
            if dimsMatch {
                score += 1_000_000
            } else {
                // Closest area wins among non-matching sizes; cap so it never beats a tier.
                score -= min(abs(width * height - wantedArea) / 10_000, 900_000)
            }
            if pixelMatch { score += 100_000 }
            if fpsOK { score += 10_000 }
            // 120/240 formats are often locked to that rate; thermal drops to 30
            // in place, so a range that still includes 30 is worth more than
            // staying unbinned on a locked slo-mo format.
            if formatSupports(format, fps: min(30, config.frameRate)) { score += 2_000 }
            if !format.isVideoBinned { score += 1_000 }
            // Prefer the lowest max fps that still covers the request.
            score -= min(maxFPS, 999)

            if score > bestScore {
                bestScore = score
                let chosenFPS = fpsOK ? config.frameRate : min(config.frameRate, maxFPS)
                best = FormatChoice(
                    format: format,
                    width: width,
                    height: height,
                    frameRate: max(1, chosenFPS),
                    pixelFormat: subtype,
                    isExact: dimsMatch && pixelMatch && fpsOK
                )
            }
        }
        return best
    }

    private static func formatSupports(_ format: AVCaptureDevice.Format, fps: Int) -> Bool {
        let target = Float64(fps)
        return format.videoSupportedFrameRateRanges.contains { range in
            range.minFrameRate <= target && target <= range.maxFrameRate
        }
    }

    private static func fourCC(_ code: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason?) -> String {
        guard let reason else { return "unknown" }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "app moved to background"
        case .audioDeviceInUseByAnotherClient: return "audio device in use by another app"
        case .videoDeviceInUseByAnotherClient: return "camera in use by another app"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "camera unavailable in multitasking"
        case .videoDeviceNotAvailableDueToSystemPressure: return "camera unavailable due to system pressure"
        default: return "reason \(reason.rawValue)"
        }
    }
}

// MARK: - Sample forwarding

/// The AVFoundation delegate object. Holds the current consumer behind a lock
/// and forwards each sample buffer without touching it. Kept separate from
/// `CaptureEngine` so the hot path has no other state in reach.
/// `@unchecked Sendable`: the only mutable member is guarded by `lock`.
private final class SampleForwarder: NSObject,
                                     AVCaptureVideoDataOutputSampleBufferDelegate,
                                     AVCaptureAudioDataOutputSampleBufferDelegate,
                                     @unchecked Sendable {
    private let lock = NSLock()
    private var consumer: (any SampleConsumer)?

    func setConsumer(_ consumer: (any SampleConsumer)?) {
        lock.lock()
        self.consumer = consumer
        lock.unlock()
    }

    private func currentConsumer() -> (any SampleConsumer)? {
        lock.lock(); defer { lock.unlock() }
        return consumer
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let consumer = currentConsumer() else { return }
        if output is AVCaptureVideoDataOutput {
            consumer.consumeVideo(sampleBuffer)
        } else {
            consumer.consumeAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        currentConsumer()?.didDropVideoFrame()
    }
}
