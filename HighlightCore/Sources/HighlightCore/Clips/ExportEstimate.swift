import Foundation

/// How much encoding work one clip contributes to an export, in terms the
/// estimator can price: how long the output runs, how dense its frames are,
/// and how much of it the compositor has to retime rather than copy.
public struct ExportWorkload: Equatable, Sendable {
    /// Seconds of output this clip produces (after trim and slow-mo).
    public var outputSeconds: Double
    /// Source frames per second.
    public var frameRate: Double
    /// Source width × height in pixels.
    public var pixelCount: Double
    /// Output seconds produced by retiming (slow-mo stretch or replay). The
    /// video compositor renders these frames instead of passing them through.
    public var retimedSeconds: Double

    public init(outputSeconds: Double, frameRate: Double, pixelCount: Double, retimedSeconds: Double) {
        self.outputSeconds = outputSeconds
        self.frameRate = frameRate
        self.pixelCount = pixelCount
        self.retimedSeconds = retimedSeconds
    }

    /// One unit is one second of 1080p60 straight re-encode.
    public static let referenceFrameRate: Double = 60
    public static let referencePixelCount: Double = 1920 * 1080
    /// Extra cost per retimed output second, relative to a straight second.
    public static let retimingWeight: Double = 0.5

    /// Encoding load in reference seconds. Frame rate and pixel count scale
    /// the cost linearly; unknown (zero) values fall back to the reference so
    /// a clip is never priced at nothing.
    public var units: Double {
        let fps = frameRate > 0 ? frameRate : Self.referenceFrameRate
        let pixels = pixelCount > 0 ? pixelCount : Self.referencePixelCount
        let density = (fps / Self.referenceFrameRate) * (pixels / Self.referencePixelCount)
        let base = max(outputSeconds, 0) * density
        let retimed = max(retimedSeconds, 0) * density * Self.retimingWeight
        return base + retimed
    }
}

/// Predicts how long an export will take and, once it is running, how long
/// is left. The up-front number comes from the workload and a per-device
/// speed (`secondsPerUnit`); as the encoder reports progress the projection
/// from elapsed time takes over, so a slow or fast device corrects itself
/// within the first third of the job.
public struct ExportTimeEstimate: Equatable, Sendable {
    /// Wall seconds per unit on an unknown device. Conservative for recent
    /// iPhones so the first estimate tends to shrink rather than grow.
    public static let defaultSecondsPerUnit: Double = 0.3
    /// Never promise less than this; the export session has fixed setup cost.
    public static let minimumTotalSeconds: Double = 1

    /// Progress below this is setup noise; the model estimate stands alone.
    private static let projectionStart: Double = 0.05
    /// By this progress the elapsed-time projection has full weight.
    private static let projectionFull: Double = 0.30

    public let units: Double
    public let secondsPerUnit: Double

    public init(units: Double, secondsPerUnit: Double = Self.defaultSecondsPerUnit) {
        self.units = max(units, 0)
        self.secondsPerUnit = secondsPerUnit > 0 ? secondsPerUnit : Self.defaultSecondsPerUnit
    }

    public init(workloads: [ExportWorkload], secondsPerUnit: Double = Self.defaultSecondsPerUnit) {
        self.init(units: workloads.reduce(0) { $0 + $1.units }, secondsPerUnit: secondsPerUnit)
    }

    /// Predicted wall time for the whole export.
    public var totalSeconds: Double {
        max(units * secondsPerUnit, Self.minimumTotalSeconds)
    }

    /// Seconds left given the encoder's `progress` (0...1) and wall `elapsed`
    /// seconds so far. Never negative.
    public func remainingSeconds(progress: Double, elapsed: Double) -> Double {
        let p = min(max(progress, 0), 1)
        let model = totalSeconds * (1 - p)
        guard p >= Self.projectionStart, elapsed > 0 else { return max(model, 0) }
        let projected = elapsed / p * (1 - p)
        let weight = min((p - Self.projectionStart) / (Self.projectionFull - Self.projectionStart), 1)
        return max(model * (1 - weight) + projected * weight, 0)
    }

    /// Folds one finished export's observed speed into the stored one. Equal
    /// weights so a single odd run (thermal throttling, background load)
    /// moves the number but does not own it. Junk observations are ignored.
    public static func calibrated(previous: Double?, observedSecondsPerUnit observed: Double) -> Double {
        guard observed.isFinite, observed > 0 else { return previous ?? defaultSecondsPerUnit }
        guard let previous, previous > 0 else { return observed }
        return (previous + observed) / 2
    }
}
