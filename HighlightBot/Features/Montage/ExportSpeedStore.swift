import Foundation
import HighlightCore

/// Remembers how fast this device encodes, in wall seconds per
/// `ExportWorkload` unit, so the next montage's time estimate starts from
/// what actually happened last time rather than the built-in default.
enum ExportSpeedStore {
    private static let key = "montage.exportSecondsPerUnit"

    static func secondsPerUnit() -> Double {
        let stored = UserDefaults.standard.double(forKey: key)
        return stored > 0 ? stored : ExportTimeEstimate.defaultSecondsPerUnit
    }

    /// Folds one finished export into the stored speed. Bounded so one
    /// thermally throttled run must not own the next estimate.
    static func record(observedSecondsPerUnit observed: Double) {
        let previous = UserDefaults.standard.double(forKey: key)
        let next = ExportTimeEstimate.calibrated(previous: previous > 0 ? previous : nil, observedSecondsPerUnit: observed)
        UserDefaults.standard.set(min(max(next, 0.02), 5), forKey: key)
    }
}
