import Foundation
import Testing
@testable import HighlightCore

@Suite("ClipTag")
struct ClipTagTests {
    @Test("normalize trims and collapses whitespace")
    func normalizeWhitespace() {
        #expect(ClipTag.normalize("  U12   tournament \n") == "U12 tournament")
    }

    @Test("normalize rejects empty and whitespace-only input")
    func normalizeEmpty() {
        #expect(ClipTag.normalize("") == nil)
        #expect(ClipTag.normalize("   \t\n") == nil)
    }

    @Test("normalize canonicalizes sport casing")
    func normalizeSportCasing() {
        #expect(ClipTag.normalize("hockey") == "Hockey")
        #expect(ClipTag.normalize(" PICKLEBALL ") == "Pickleball")
        #expect(ClipTag.normalize("Soccer") == "Soccer")
    }

    @Test("normalize leaves custom casing alone")
    func normalizeCustomCasing() {
        #expect(ClipTag.normalize("Rec League") == "Rec League")
    }

    @Test("normalize clips to maxLength")
    func normalizeMaxLength() {
        let long = String(repeating: "a", count: ClipTag.maxLength + 10)
        #expect(ClipTag.normalize(long)?.count == ClipTag.maxLength)
    }

    @Test("merge keeps first casing and drops case-insensitive duplicates")
    func merge() {
        let merged = ClipTag.merge(["Hockey", "Rec League"], ["hockey", "rec league", "Playoffs"])
        #expect(merged == ["Hockey", "Rec League", "Playoffs"])
    }

    @Test("normalized de-duplicates after normalizing")
    func normalizedList() {
        #expect(ClipTag.normalized(["hockey", "Hockey ", "", "  Golf"]) == ["Hockey", "Golf"])
    }

    @Test("isSuggestedSport is case-insensitive")
    func isSuggestedSport() {
        #expect(ClipTag.isSuggestedSport("tennis"))
        #expect(!ClipTag.isSuggestedSport("Curling"))
    }

    @Test("contains and removing are case-insensitive")
    func containsAndRemoving() {
        let tags = ["Hockey", "Playoffs"]
        #expect(ClipTag.contains(tags, "hockey"))
        #expect(!ClipTag.contains(tags, "Golf"))
        #expect(ClipTag.removing("HOCKEY", from: tags) == ["Playoffs"])
    }

    @Test("sortedForDisplay is case-insensitive")
    func sorted() {
        #expect(ClipTag.sortedForDisplay(["b", "A", "c"]) == ["A", "b", "c"])
    }
}
