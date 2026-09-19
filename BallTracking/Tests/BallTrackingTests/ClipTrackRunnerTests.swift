import CoreGraphics
import CoreMedia
import Foundation
import os
import Testing
@testable import BallTracking

struct ClipTrackRunnerTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "balltracking-tests-\(name)-\(UUID().uuidString).mov")
    }

    @Test("tracks a synthetic ball across a generated movie with the luma detector")
    func tracksSyntheticMovie() async throws {
        let url = temporaryURL("straight")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticMovie.write(to: url) { i in CGPoint(x: 40 + Double(i) * 12, y: 180) }

        let runner = ClipTrackRunner(detectorKind: .luma)
        let reported = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let result = try await runner.run(url: url,
                                          progress: { progress in reported.withLock { $0.append(progress.fraction) } },
                                          isCancelled: { false })

        #expect(result.track.frames.count == 40)
        #expect(result.track.detector == "luma")
        #expect(abs(result.track.frameRate - 50) < 0.5)
        #expect(result.track.displaySize == CGSize(width: 640, height: 360))
        #expect(result.track.trackingFraction > 0.6)
        let last = result.track.frames.last!
        #expect(last.state == .tracking)
        #expect(abs((last.position?.x ?? 0) - (40 + 39 * 12) / 640) < 0.03)
        #expect(result.meanDetectMillis > 0)
        let fractions = reported.withLock { $0 }
        #expect(!fractions.isEmpty)
        #expect(fractions.last == 1.0)
    }

    @Test("applies the track's preferredTransform so positions are display-oriented")
    func appliesTransform() async throws {
        let url = temporaryURL("rotated")
        defer { try? FileManager.default.removeItem(at: url) }
        let rotate180 = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 640, ty: 360)
        try await SyntheticMovie.write(to: url, transform: rotate180) { i in CGPoint(x: 40 + Double(i) * 12, y: 100) }

        let result = try await ClipTrackRunner(detectorKind: .luma).run(url: url, progress: nil, isCancelled: { false })
        let last = result.track.frames.last!
        #expect(last.state == .tracking)
        // Stored x ≈ 508/640 = 0.79 → displayed 0.21; stored y 100/360 = 0.28 → 0.72.
        #expect(abs((last.position?.x ?? 0) - (1 - 508.0 / 640.0)) < 0.03)
        #expect(abs((last.position?.y ?? 0) - (1 - 100.0 / 360.0)) < 0.03)
    }

    @Test("cancellation throws and stops early")
    func cancels() async throws {
        let url = temporaryURL("cancel")
        defer { try? FileManager.default.removeItem(at: url) }
        try await SyntheticMovie.write(to: url) { i in CGPoint(x: 40 + Double(i) * 12, y: 180) }
        await #expect(throws: ClipTrackError.cancelled) {
            _ = try await ClipTrackRunner(detectorKind: .luma).run(url: url, progress: nil, isCancelled: { true })
        }
    }

    @Test("missing file surfaces an error")
    func missingFile() async {
        let url = temporaryURL("missing")
        await #expect(throws: (any Error).self) {
            _ = try await ClipTrackRunner(detectorKind: .luma).run(url: url, progress: nil, isCancelled: { false })
        }
    }
}
