import Foundation

/// Finds a spoken command in a speech recognizer's cumulative transcript.
///
/// Speech recognizers deliver partial results as a growing (and sometimes
/// revised) transcript for one request. Feed each partial to `consume`; it
/// returns only the matches that are new since the last call, so one
/// utterance fires once even though it appears in every later partial.
///
/// Matching is on letters and digits only, lowercased, with everything else
/// (spaces, punctuation) removed, so "Clip it!", "clip-it" and "clipit" are
/// the same. Call `reset()` whenever the recognizer starts a fresh request.
public struct KeywordSpotter: Sendable, Equatable {
    /// "clip it" plus the misrecognitions seen most often for it.
    public static let clipIt = KeywordSpotter(phrases: ["clip it", "clip at", "clip hit", "clip pit"])

    private let phrases: [[Character]]
    private var reportedMatches = 0

    /// - Parameter phrases: Spoken phrases to look for; normalised the same
    ///   way as transcripts. Empty phrases are ignored.
    public init(phrases: [String]) {
        self.phrases = phrases
            .map { Array(Self.normalize($0)) }
            .filter { !$0.isEmpty }
    }

    /// Feed the latest transcript of the current request. Returns the number
    /// of matches not already reported. Never negative: if a revision drops
    /// a match the count stays where it was.
    public mutating func consume(_ transcript: String) -> Int {
        let count = Self.countMatches(in: Array(Self.normalize(transcript)), phrases: phrases)
        let new = max(0, count - reportedMatches)
        reportedMatches = max(reportedMatches, count)
        return new
    }

    /// Forget the current transcript (the recognizer was restarted).
    public mutating func reset() {
        reportedMatches = 0
    }

    // MARK: - Private

    private static func normalize(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Non-overlapping count of any phrase in `text`, scanning left to right.
    private static func countMatches(in text: [Character], phrases: [[Character]]) -> Int {
        guard !phrases.isEmpty, !text.isEmpty else { return 0 }
        var count = 0
        var index = 0
        while index < text.count {
            var advanced = false
            for phrase in phrases where index + phrase.count <= text.count {
                if text[index..<(index + phrase.count)].elementsEqual(phrase) {
                    count += 1
                    index += phrase.count
                    advanced = true
                    break
                }
            }
            if !advanced { index += 1 }
        }
        return count
    }
}
