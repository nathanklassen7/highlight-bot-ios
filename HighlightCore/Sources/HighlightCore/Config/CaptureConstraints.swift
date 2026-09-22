import Foundation

/// The part of `RecordingConfig` that the camera constrains: which lens,
/// which size, how many frames per second. Orientation is not here because
/// it is chosen when recording starts and stored as metadata; no rule reads it.
public enum CaptureSetupField: Sendable, Equatable, CaseIterable {
    case lens
    case resolution
    case frameRate
}

/// One hardware or product limit: for the matching lenses and resolutions,
/// the frame rate may not exceed `maxFrameRate`. Nil matchers mean "any".
public struct CaptureLimit: Sendable, Equatable {
    public var lenses: Set<CameraLens>?
    public var resolutions: Set<CaptureResolution>?
    public var maxFrameRate: Int
    /// Footer copy explaining the limit to the user.
    public var reason: String

    public init(
        lenses: Set<CameraLens>? = nil,
        resolutions: Set<CaptureResolution>? = nil,
        maxFrameRate: Int,
        reason: String
    ) {
        self.lenses = lenses
        self.resolutions = resolutions
        self.maxFrameRate = maxFrameRate
        self.reason = reason
    }

    public func applies(lens: CameraLens, resolution: CaptureResolution) -> Bool {
        (lenses?.contains(lens) ?? true) && (resolutions?.contains(resolution) ?? true)
    }
}

/// Single home for what the camera can do. Every screen that edits a lens,
/// resolution, or frame rate asks here, and `SettingsStore` runs `resolve`
/// after every change so a config never leaves the store in a state the
/// camera cannot run.
public enum CaptureConstraints {
    /// Frame rates the UI can offer, before any limit applies.
    public static let frameRateOptions: [Int] = [30, 60, 120]

    /// The rules. Adding a limit is one entry; nothing else changes.
    public static let limits: [CaptureLimit] = [
        CaptureLimit(
            resolutions: [.p1080],
            maxFrameRate: 60,
            reason: "1080p tops out at 60 fps; 120 fps captures at 720p."
        ),
        CaptureLimit(
            lenses: [.selfie],
            maxFrameRate: 60,
            reason: "Selfie tops out at 60 fps."
        ),
    ]

    // MARK: - Queries

    /// Highest frame rate this lens and resolution can run.
    public static func maxFrameRate(lens: CameraLens, resolution: CaptureResolution) -> Int {
        let caps = limits
            .filter { $0.applies(lens: lens, resolution: resolution) }
            .map(\.maxFrameRate)
        return caps.min() ?? frameRateOptions.max() ?? 0
    }

    /// Frame rates a picker should list for this lens and resolution.
    public static func availableFrameRates(lens: CameraLens, resolution: CaptureResolution) -> [Int] {
        let ceiling = maxFrameRate(lens: lens, resolution: resolution)
        return frameRateOptions.filter { $0 <= ceiling }
    }

    /// Resolutions a picker should list for this lens: every preset with at
    /// least one runnable frame rate. Picking one may lower the frame rate;
    /// `resolve` handles that.
    public static func availableResolutions(lens: CameraLens) -> [CaptureResolution] {
        CaptureResolution.allCases.filter { !availableFrameRates(lens: lens, resolution: $0).isEmpty }
    }

    /// Limits that touch this lens at any resolution, for explanatory copy.
    public static func limits(affecting lens: CameraLens) -> [CaptureLimit] {
        limits.filter { limit in
            CaptureResolution.allCases.contains { limit.applies(lens: lens, resolution: $0) }
        }
    }

    // MARK: - Resolution

    /// The one field that differs between two configs, or nil when none or
    /// several do. Tells `resolve` what the user just asked for.
    public static func changedField(from old: RecordingConfig, to new: RecordingConfig) -> CaptureSetupField? {
        var changed: [CaptureSetupField] = []
        if old.lens != new.lens { changed.append(.lens) }
        if old.width != new.width || old.height != new.height { changed.append(.resolution) }
        if old.frameRate != new.frameRate { changed.append(.frameRate) }
        return changed.count == 1 ? changed[0] : nil
    }

    /// Returns `config` adjusted until every limit holds.
    ///
    /// `keeping` is the field the user just changed and therefore wins:
    /// - `.frameRate`: keep the rate and move to the largest resolution that
    ///   runs it (the current one if it already does). If no resolution can,
    ///   the rate drops to the ceiling instead.
    /// - `.lens`, `.resolution`, or nil: keep those and lower the frame rate
    ///   to the ceiling.
    ///
    /// Width and height are also snapped to the matching preset so a
    /// half-updated size cannot survive. Idempotent: resolving a resolved
    /// config, with any `keeping`, returns it unchanged.
    public static func resolve(_ config: RecordingConfig, keeping field: CaptureSetupField? = nil) -> RecordingConfig {
        var resolved = config
        let current = config.resolution
        resolved.width = current.width
        resolved.height = current.height

        if field == .frameRate,
           let fit = resolution(running: config.frameRate, lens: config.lens, preferring: current) {
            resolved.resolution = fit
            return resolved
        }

        let ceiling = maxFrameRate(lens: resolved.lens, resolution: resolved.resolution)
        resolved.frameRate = min(resolved.frameRate, ceiling)
        return resolved
    }

    /// The preferred resolution if it runs `frameRate`, else the largest that does.
    private static func resolution(
        running frameRate: Int,
        lens: CameraLens,
        preferring preferred: CaptureResolution
    ) -> CaptureResolution? {
        let others = CaptureResolution.allCases
            .filter { $0 != preferred }
            .sorted { $0.pixelCount > $1.pixelCount }
        return ([preferred] + others).first { maxFrameRate(lens: lens, resolution: $0) >= frameRate }
    }
}
