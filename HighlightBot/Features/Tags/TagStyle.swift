import HighlightCore
import SwiftUI

/// Fixed pill colors. Suggested sports each get their own; every other tag
/// shares `custom`. Keys are the canonical names in `ClipTag.suggestedSports`,
/// which `ClipTag.normalize` already enforces, so lookup is exact-match.
enum TagStyle {
    static let custom = Color(red: 0.42, green: 0.46, blue: 0.54)

    private static let sportColors: [String: Color] = [
        "Hockey": Color(red: 0.24, green: 0.60, blue: 0.90),
        "Soccer": Color(red: 0.20, green: 0.66, blue: 0.36),
        "Basketball": Color(red: 0.93, green: 0.49, blue: 0.14),
        "Baseball": Color(red: 0.85, green: 0.24, blue: 0.26),
        "Football": Color(red: 0.55, green: 0.36, blue: 0.22),
        "Tennis": Color(red: 0.62, green: 0.72, blue: 0.14),
        "Pickleball": Color(red: 0.12, green: 0.62, blue: 0.62),
        "Volleyball": Color(red: 0.86, green: 0.68, blue: 0.10),
        "Lacrosse": Color(red: 0.55, green: 0.36, blue: 0.80),
        "Golf": Color(red: 0.13, green: 0.47, blue: 0.27),
    ]

    static func color(for tag: String) -> Color {
        if let exact = sportColors[tag] { return exact }
        if let sport = ClipTag.suggestedSports.first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }),
           let color = sportColors[sport] {
            return color
        }
        return custom
    }
}
