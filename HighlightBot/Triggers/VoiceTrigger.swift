import Foundation
import CoreMedia
import Speech
import HighlightCore

/// Saves a clip when someone says "clip it" while recording.
///
/// Audio comes from the capture session's microphone output via
/// `AudioSampleListener`, so no second audio pipeline is opened. Recognition
/// is `SFSpeechRecognizer` pinned to on-device mode: court audio never leaves
/// the phone, and it works without a network.
///
/// Listening is explicit: the container calls `beginListening()` when a
/// session starts with the voice trigger enabled and `endListening()` when it
/// stops. Outside that window `consumeAudio` costs one lock and a nil check.
///
/// One recognition request is live at a time. It is replaced after every
/// match (which clears the transcript and doubles as a short cooldown), on
/// error, and every `requestLifetime` seconds because long requests degrade.
/// `@unchecked Sendable`: all mutable state is guarded by `lock`.
final class VoiceTrigger: NSObject, TriggerSource, AudioSampleListener, @unchecked Sendable {
    let id: TriggerSourceID = .voice

    /// Spoken command. Recognition is English-only; the phrase is too.
    static let phrase = "clip it"
    private static let locale = Locale(identifier: "en-US")

    /// How long one recognition request runs before being replaced.
    private let requestLifetime: TimeInterval = 45
    /// Pause before retrying after the recognizer reports an error.
    private let errorRetryDelay: TimeInterval = 1.5
    /// Pause before retrying while the recognizer reports itself unavailable.
    private let unavailableRetryDelay: TimeInterval = 3

    private let recognizer: SFSpeechRecognizer?
    /// All recognizer callbacks and request lifecycle work run here.
    private let workQueue = DispatchQueue(label: "com.highlightbot.voice", qos: .utility)

    private let lock = NSLock()
    // Guarded by `lock`.
    private var emitter: (@Sendable (TriggerEvent) -> Void)?
    private var wantsListening = false
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var spotter = KeywordSpotter.clipIt
    /// Bumped whenever the live request changes; stale callbacks compare
    /// against it and bail.
    private var generation = 0

    override init() {
        recognizer = SFSpeechRecognizer(locale: Self.locale)
        super.init()
        let callbacks = OperationQueue()
        callbacks.name = "com.highlightbot.voice.callbacks"
        callbacks.maxConcurrentOperationCount = 1
        callbacks.underlyingQueue = workQueue
        recognizer?.queue = callbacks
    }

    // MARK: - Availability

    /// Why listening cannot start right now, or nil when it can. Cheap;
    /// the container checks it when a session starts with voice enabled.
    static func availabilityProblem() -> String? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            return "Voice trigger needs Speech Recognition permission. Allow it in Settings."
        case .denied, .restricted:
            return "Speech Recognition is turned off for HighlightBot. Enable it in Settings to use the voice trigger."
        @unknown default:
            return "Speech Recognition is unavailable."
        }
        guard let recognizer = SFSpeechRecognizer(locale: locale) else {
            return "Speech Recognition does not support English on this device."
        }
        guard recognizer.supportsOnDeviceRecognition else {
            return "On-device English speech recognition is not available. Enable English dictation in Settings › General › Keyboard."
        }
        return nil
    }

    // MARK: - TriggerSource

    func start(emit: @escaping @Sendable (TriggerEvent) -> Void) async throws {
        lock.withLock { emitter = emit }
    }

    func stop() async {
        endListening()
        lock.withLock { emitter = nil }
    }

    // MARK: - Listening

    /// True between `beginListening()` and `endListening()`.
    var isListening: Bool {
        lock.withLock { wantsListening }
    }

    /// Start recognising. Safe to call repeatedly.
    func beginListening() {
        let alreadyListening = lock.withLock { () -> Bool in
            defer { wantsListening = true }
            return wantsListening
        }
        guard !alreadyListening else { return }
        workQueue.async { [weak self] in self?.startRequestIfWanted() }
    }

    /// Stop recognising and drop the live request. Safe to call repeatedly.
    func endListening() {
        let task = lock.withLock { () -> SFSpeechRecognitionTask? in
            wantsListening = false
            generation += 1
            let task = self.task
            self.task = nil
            request = nil
            return task
        }
        task?.cancel()
    }

    // MARK: - AudioSampleListener (capture queue)

    func consumeAudio(_ sampleBuffer: CMSampleBuffer) {
        let request = lock.withLock { self.request }
        request?.appendAudioSampleBuffer(sampleBuffer)
    }

    // MARK: - Request lifecycle (workQueue)

    private func startRequestIfWanted() {
        guard lock.withLock({ wantsListening }) else { return }

        guard let recognizer,
              SFSpeechRecognizer.authorizationStatus() == .authorized,
              recognizer.supportsOnDeviceRecognition
        else { return }
        guard recognizer.isAvailable else {
            scheduleStart(after: unavailableRetryDelay)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = [Self.phrase]
        request.taskHint = .search
        request.addsPunctuation = false

        let generation: Int? = lock.withLock {
            guard wantsListening else { return nil }
            self.generation += 1
            spotter.reset()
            self.request = request
            return self.generation
        }
        guard let generation else { return }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            self?.handle(result: result, error: error, generation: generation)
        }
        let stillCurrent = lock.withLock { () -> Bool in
            guard self.generation == generation else { return false }
            self.task = task
            return true
        }
        if !stillCurrent {
            task.cancel()
            return
        }

        let lifetime = requestLifetime
        workQueue.asyncAfter(deadline: .now() + lifetime) { [weak self] in
            guard let self, self.lock.withLock({ self.generation == generation && self.wantsListening }) else { return }
            self.replaceRequest()
        }
    }

    private func scheduleStart(after delay: TimeInterval) {
        workQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.startRequestIfWanted()
        }
    }

    /// Cancel the live request and start another (after `delay`).
    private func replaceRequest(delay: TimeInterval = 0) {
        let task = lock.withLock { () -> SFSpeechRecognitionTask? in
            generation += 1
            let task = self.task
            self.task = nil
            request = nil
            return task
        }
        task?.cancel()
        if delay > 0 {
            scheduleStart(after: delay)
        } else {
            startRequestIfWanted()
        }
    }

    private func handle(result: SFSpeechRecognitionResult?, error: (any Error)?, generation: Int) {
        let (newMatches, emit, isFinal, current) = lock.withLock { () -> (Int, (@Sendable (TriggerEvent) -> Void)?, Bool, Bool) in
            guard self.generation == generation, wantsListening else { return (0, nil, false, false) }
            var matches = 0
            if let result {
                matches = spotter.consume(result.bestTranscription.formattedString)
            }
            return (matches, emitter, result?.isFinal ?? false, true)
        }
        guard current else { return }

        if newMatches > 0 {
            guard let emit else { return }
            for _ in 0..<newMatches {
                emit(TriggerEvent(source: id, kind: .saveClip(seconds: nil)))
            }
            replaceRequest()
            return
        }

        if let error {
            // Cancellation of a superseded task is expected and already filtered
            // by the generation check; anything else here is a real end.
            replaceRequest(delay: errorRetryDelay)
        } else if isFinal {
            replaceRequest()
        }
    }
}
