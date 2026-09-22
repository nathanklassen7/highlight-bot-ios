import Foundation
import Testing
@testable import HighlightCore

@Suite("CaptureConstraints")
struct CaptureConstraintsTests {
    private func config(
        _ lens: CameraLens,
        _ resolution: CaptureResolution,
        _ frameRate: Int
    ) -> RecordingConfig {
        RecordingConfig(width: resolution.width, height: resolution.height, frameRate: frameRate, lens: lens)
    }

    // MARK: Queries

    @Test("frame rate ceiling per lens and resolution")
    func ceilings() {
        #expect(CaptureConstraints.maxFrameRate(lens: .wide, resolution: .p720) == 120)
        #expect(CaptureConstraints.maxFrameRate(lens: .ultraWide, resolution: .p720) == 120)
        #expect(CaptureConstraints.maxFrameRate(lens: .wide, resolution: .p1080) == 60)
        #expect(CaptureConstraints.maxFrameRate(lens: .ultraWide, resolution: .p1080) == 60)
        #expect(CaptureConstraints.maxFrameRate(lens: .selfie, resolution: .p720) == 60)
        #expect(CaptureConstraints.maxFrameRate(lens: .selfie, resolution: .p1080) == 60)
    }

    @Test("menus list only runnable values")
    func menus() {
        #expect(CaptureConstraints.availableFrameRates(lens: .wide, resolution: .p720) == [30, 60, 120])
        #expect(CaptureConstraints.availableFrameRates(lens: .wide, resolution: .p1080) == [30, 60])
        #expect(CaptureConstraints.availableFrameRates(lens: .selfie, resolution: .p720) == [30, 60])
        for lens in CameraLens.allCases {
            #expect(CaptureConstraints.availableResolutions(lens: lens) == CaptureResolution.allCases)
        }
    }

    @Test("limits affecting a lens drive the footer copy")
    func limitsAffecting() {
        let selfie = CaptureConstraints.limits(affecting: .selfie)
        #expect(selfie.count == 2)
        #expect(selfie.contains { $0.lenses == [.selfie] })
        #expect(selfie.contains { $0.resolutions == [.p1080] })

        let wide = CaptureConstraints.limits(affecting: .wide)
        #expect(wide.count == 1)
        #expect(wide.first?.resolutions == [.p1080])
    }

    @Test("a limit applies only to its lenses and resolutions")
    func limitMatching() {
        let limit = CaptureLimit(lenses: [.selfie], resolutions: [.p1080], maxFrameRate: 30, reason: "test")
        #expect(limit.applies(lens: .selfie, resolution: .p1080))
        #expect(!limit.applies(lens: .selfie, resolution: .p720))
        #expect(!limit.applies(lens: .wide, resolution: .p1080))

        let anyLens = CaptureLimit(resolutions: [.p720], maxFrameRate: 30, reason: "test")
        #expect(anyLens.applies(lens: .wide, resolution: .p720))
        #expect(anyLens.applies(lens: .selfie, resolution: .p720))
        #expect(!anyLens.applies(lens: .wide, resolution: .p1080))
    }

    // MARK: Change detection

    @Test("changedField names the single field that moved")
    func changedField() {
        let base = config(.wide, .p1080, 60)
        #expect(CaptureConstraints.changedField(from: base, to: base) == nil)
        #expect(CaptureConstraints.changedField(from: base, to: config(.selfie, .p1080, 60)) == .lens)
        #expect(CaptureConstraints.changedField(from: base, to: config(.wide, .p720, 60)) == .resolution)
        #expect(CaptureConstraints.changedField(from: base, to: config(.wide, .p1080, 120)) == .frameRate)
        // Two fields at once (reset, load) has no single intent.
        #expect(CaptureConstraints.changedField(from: base, to: config(.selfie, .p720, 60)) == nil)

        // A width-only write is a resolution change even before height catches up.
        var halfWritten = base
        halfWritten.width = 1280
        #expect(CaptureConstraints.changedField(from: base, to: halfWritten) == .resolution)

        // Fields outside the capture setup are not the constraints' business.
        var audioOff = base
        audioOff.recordAudio = false
        #expect(CaptureConstraints.changedField(from: base, to: audioOff) == nil)
    }

    // MARK: Resolve

    @Test("a valid config resolves to itself for every intent")
    func resolveIsIdentityWhenValid() {
        let valid = [
            config(.wide, .p720, 120),
            config(.wide, .p1080, 60),
            config(.ultraWide, .p720, 30),
            config(.selfie, .p1080, 60),
            config(.selfie, .p720, 30),
        ]
        for original in valid {
            #expect(CaptureConstraints.resolve(original) == original)
            for field in CaptureSetupField.allCases {
                #expect(CaptureConstraints.resolve(original, keeping: field) == original)
            }
        }
    }

    @Test("picking a frame rate moves the resolution to one that runs it")
    func keepFrameRate() {
        let picked120at1080 = config(.wide, .p1080, 120)
        let resolved = CaptureConstraints.resolve(picked120at1080, keeping: .frameRate)
        #expect(resolved.frameRate == 120)
        #expect(resolved.resolution == .p720)
        #expect(resolved.lens == .wide)

        // Already-fitting resolution is kept rather than swapped for the largest.
        let picked60at720 = config(.wide, .p720, 60)
        #expect(CaptureConstraints.resolve(picked60at720, keeping: .frameRate) == picked60at720)
    }

    @Test("a frame rate no resolution can run falls back to the ceiling")
    func keepFrameRateFallsBack() {
        let selfie120 = config(.selfie, .p720, 120)
        let resolved = CaptureConstraints.resolve(selfie120, keeping: .frameRate)
        #expect(resolved.lens == .selfie)
        #expect(resolved.resolution == .p720)
        #expect(resolved.frameRate == 60)
    }

    @Test("picking a resolution or lens lowers the frame rate")
    func keepResolutionOrLens() {
        let picked1080at120 = config(.wide, .p1080, 120)
        let byResolution = CaptureConstraints.resolve(picked1080at120, keeping: .resolution)
        #expect(byResolution.resolution == .p1080)
        #expect(byResolution.frameRate == 60)

        let pickedSelfieAt120 = config(.selfie, .p720, 120)
        let byLens = CaptureConstraints.resolve(pickedSelfieAt120, keeping: .lens)
        #expect(byLens.lens == .selfie)
        #expect(byLens.resolution == .p720)
        #expect(byLens.frameRate == 60)

        // No intent (load, reset) behaves the same way.
        #expect(CaptureConstraints.resolve(picked1080at120) == byResolution)
    }

    @Test("resolve snaps a half-written size to its preset")
    func resolveSnapsDimensions() {
        var halfWritten = config(.wide, .p1080, 120)
        halfWritten.width = 1280
        let resolved = CaptureConstraints.resolve(halfWritten, keeping: .resolution)
        #expect(resolved.width == 1280)
        #expect(resolved.height == 720)
        #expect(resolved.frameRate == 120)
    }

    @Test("resolve is idempotent under any follow-up intent")
    func resolveConverges() {
        let starts = [
            config(.wide, .p1080, 120),
            config(.selfie, .p720, 120),
            config(.selfie, .p1080, 120),
            config(.ultraWide, .p1080, 120),
        ]
        for start in starts {
            for first in CaptureSetupField.allCases {
                let once = CaptureConstraints.resolve(start, keeping: first)
                // The store's second pass sees the field the resolver moved.
                let moved = CaptureConstraints.changedField(from: start, to: once)
                let twice = CaptureConstraints.resolve(once, keeping: moved)
                #expect(twice == once)
            }
        }
    }

    @Test("resolve leaves non-capture fields alone")
    func resolvePreservesOtherFields() {
        var start = config(.selfie, .p1080, 120)
        start.codec = .hevc
        start.recordAudio = false
        start.bufferSeconds = 30
        let resolved = CaptureConstraints.resolve(start, keeping: .lens)
        #expect(resolved.codec == .hevc)
        #expect(resolved.recordAudio == false)
        #expect(resolved.bufferSeconds == 30)
        #expect(resolved.frameRate == 60)
    }
}
