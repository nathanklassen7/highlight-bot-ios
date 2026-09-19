import Foundation

/// Tag normalization and the canonical sport list. Tags are plain strings on
/// `ClipRecord`; this is the single place that decides what a valid tag looks
/// like so every entry point (Record, Library, Player) agrees.
public enum ClipTag {
    /// Canonical sport names, in display order. Always offered in the tag
    /// picker; the app maps each to a fixed pill color.
    public static let suggestedSports: [String] = [
        "Hockey",
        "Soccer",
        "Basketball",
        "Baseball",
        "Football",
        "Tennis",
        "Pickleball",
        "Volleyball",
        "Lacrosse",
        "Golf",
    ]

    /// Longest tag we store, in characters, after normalization.
    public static let maxLength = 40

    /// Trims, collapses internal whitespace, and canonicalizes sport casing
    /// (`"hockey"` → `"Hockey"`). Returns nil for empty input.
    public static func normalize(_ raw: String) -> String? {
        let collapsed = raw
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        let clipped = String(collapsed.prefix(maxLength))
        if let sport = suggestedSports.first(where: { $0.caseInsensitiveCompare(clipped) == .orderedSame }) {
            return sport
        }
        return clipped
    }

    /// True if `tag` is one of `suggestedSports` (case-insensitive).
    public static func isSuggestedSport(_ tag: String) -> Bool {
        suggestedSports.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// Case-insensitive union that keeps the first casing seen. Input order
    /// is preserved (`base` first, then new entries from `additions`).
    public static func merge(_ base: [String], _ additions: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in base + additions {
            let key = tag.lowercased()
            if seen.insert(key).inserted {
                result.append(tag)
            }
        }
        return result
    }

    /// Normalizes every entry, drops empties, and de-duplicates.
    public static func normalized(_ tags: [String]) -> [String] {
        merge([], tags.compactMap(normalize))
    }

    /// Case-insensitive stable sort for display.
    public static func sortedForDisplay(_ tags: [String]) -> [String] {
        tags.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Case-insensitive membership test.
    public static func contains(_ tags: [String], _ tag: String) -> Bool {
        tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
    }

    /// `tags` minus `tag`, case-insensitive.
    public static func removing(_ tag: String, from tags: [String]) -> [String] {
        tags.filter { $0.caseInsensitiveCompare(tag) != .orderedSame }
    }
}
