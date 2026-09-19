import Foundation
import CoreMedia
import CoreVideo
import os

/// Something that inspects video frames off the capture queue (future ball
/// tracking, scene detection). `FrameTap` drops frames for an analyzer that
/// is still busy with the previous one, so `analyze` may take as long as it
/// needs without ever stalling the encoder.
protocol FrameAnalyzer: AnyObject, Sendable {
    var name: String { get }
    /// Called off the capture queue. Frames are dropped while this is running.
    func analyze(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) async
}

/// Fans video frames out to registered `FrameAnalyzer`s without blocking the
/// caller. Ships with zero analyzers; the hot path then costs one lock
/// acquisition and an empty-array check.
final class FrameTap: Sendable {
    /// A retained pixel buffer plus its timestamp, moved into an analyzer task.
    /// `@unchecked Sendable`: a `CVPixelBuffer` delivered by capture is immutable
    /// after delivery and reference counting is thread-safe, so handing one
    /// (retained) reference to a single task is safe.
    private struct FramePayload: @unchecked Sendable {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
    }

    private struct Entry: Sendable {
        let analyzer: any FrameAnalyzer
        var isBusy: Bool
    }

    private struct State: Sendable {
        var entries: [String: Entry] = [:]
        var dropped: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// Registers (or replaces) an analyzer by name.
    func register(_ analyzer: any FrameAnalyzer) {
        state.withLock { $0.entries[analyzer.name] = Entry(analyzer: analyzer, isBusy: false) }
    }

    func unregister(name: String) {
        state.withLock { _ = $0.entries.removeValue(forKey: name) }
    }

    /// Frames dropped because the target analyzer was still busy. Expected to
    /// be non-zero whenever an analyzer is slower than the capture rate.
    var droppedCount: Int {
        state.withLock { $0.dropped }
    }

    var analyzerNames: [String] {
        state.withLock { Array($0.entries.keys) }
    }

    /// Non-blocking. Dispatches one `Task` per idle analyzer; busy analyzers
    /// count a drop. Called on the capture queue: keep it allocation-free
    /// when no analyzers are registered.
    func enqueue(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        let ready: [any FrameAnalyzer] = state.withLock { s in
            if s.entries.isEmpty { return [] }
            var out: [any FrameAnalyzer] = []
            for (name, entry) in s.entries {
                if entry.isBusy {
                    s.dropped += 1
                } else {
                    s.entries[name]?.isBusy = true
                    out.append(entry.analyzer)
                }
            }
            return out
        }
        if ready.isEmpty { return }

        let payload = FramePayload(pixelBuffer: pixelBuffer, presentationTime: presentationTime)
        for analyzer in ready {
            Task(priority: .utility) { [payload] in
                await analyzer.analyze(pixelBuffer: payload.pixelBuffer, presentationTime: payload.presentationTime)
                self.markIdle(analyzer.name)
            }
        }
    }

    private func markIdle(_ name: String) {
        state.withLock { $0.entries[name]?.isBusy = false }
    }
}

#if DEBUG
/// Test analyzer that just sleeps, for exercising the drop path in the debug
/// overlay. Register it, watch `analyzerDroppedFrames` climb.
final class NoopFrameAnalyzer: FrameAnalyzer {
    let name: String
    private let delayMillis: Int

    init(name: String = "noop", delayMillis: Int = 100) {
        self.name = name
        self.delayMillis = delayMillis
    }

    func analyze(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) async {
        try? await Task.sleep(for: .milliseconds(delayMillis))
    }
}
#endif
