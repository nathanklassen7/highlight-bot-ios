import Foundation

/// File-name generation for exported clips.
public enum ClipNaming {
    /// `yyyy-MM-dd'T'HH-mm-ss'Z'-XXXX` using UTC and 4 random hex characters.
    /// The caller appends the extension.
    public static func baseName(for date: Date) -> String {
        var generator = SystemRandomNumberGenerator()
        return baseName(for: date, using: &generator)
    }

    /// Deterministic variant for tests: the random suffix comes from `generator`.
    public static func baseName(for date: Date, using generator: inout some RandomNumberGenerator) -> String {
        let suffix = String(format: "%04X", UInt16.random(in: .min ... .max, using: &generator))
        return "\(timestamp(for: date))-\(suffix)"
    }

    /// `yyyy-MM-dd'T'HH-mm-ss'Z'` in UTC.
    static func timestamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d-%02d-%02dZ",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }
}
