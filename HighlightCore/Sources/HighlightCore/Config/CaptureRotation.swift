import Foundation

/// Normalizes horizon-level rotation angles before they reach the writer.
/// The app converts from `CGFloat` at the boundary; Core stays Foundation-only.
public enum CaptureRotation: Sendable {
    /// Maps any angle to the nearest of 0°, 90°, 180°, or 270° after folding
    /// into `[0, 360)`.
    ///
    /// Halfway values (45°, 135°, 225°, 315°) snap **up** to the next quarter
    /// turn so tie-breaking is stable and matches rounding toward +90° (315° →
    /// 0°, not 270°).
    public static func snapped(_ angle: Double) -> Double {
        let normalized = Self.normalized(angle)
        let base = floor(normalized / 90) * 90
        let remainder = normalized - base
        if remainder < 45 {
            return base == 360 ? 0 : base
        }
        let snapped = base + 90
        return snapped >= 360 ? 0 : snapped
    }

    private static func normalized(_ angle: Double) -> Double {
        var value = angle.truncatingRemainder(dividingBy: 360)
        if value < 0 { value += 360 }
        return value
    }
}
