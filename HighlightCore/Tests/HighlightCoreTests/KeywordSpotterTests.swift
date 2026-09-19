import Testing
@testable import HighlightCore

@Suite("KeywordSpotter")
struct KeywordSpotterTests {
    @Test("matches the phrase once in a plain transcript")
    func plainMatch() {
        var spotter = KeywordSpotter.clipIt
        #expect(spotter.consume("clip it") == 1)
    }

    @Test("ignores case and punctuation")
    func normalizes() {
        var spotter = KeywordSpotter.clipIt
        #expect(spotter.consume("  Clip, it!  ") == 1)
    }

    @Test("does not report the same match twice as partial results grow")
    func dedupesAcrossPartials() {
        var spotter = KeywordSpotter.clipIt
        #expect(spotter.consume("clip") == 0)
        #expect(spotter.consume("clip it") == 1)
        #expect(spotter.consume("clip it that was") == 0)
        #expect(spotter.consume("clip it that was a good one") == 0)
    }

    @Test("reports a second utterance in the same transcript")
    func secondUtterance() {
        var spotter = KeywordSpotter.clipIt
        #expect(spotter.consume("clip it") == 1)
        #expect(spotter.consume("clip it nice clip it") == 1)
    }

    @Test("a revision that drops and restores a match fires only once")
    func revisionDoesNotDoubleCount() {
        var spotter = KeywordSpotter.clipIt
        #expect(spotter.consume("clip it") == 1)
        #expect(spotter.consume("clipped") == 0)
        #expect(spotter.consume("clip it") == 0)
    }

    @Test("reset starts a fresh transcript")
    func reset() {
        var spotter = KeywordSpotter.clipIt
        #expect(spotter.consume("clip it") == 1)
        spotter.reset()
        #expect(spotter.consume("clip it") == 1)
    }

    @Test("accepts run-together and common misrecognitions")
    func variants() {
        for text in ["clipit", "Clip-it", "clip at", "clip hit", "clip pit"] {
            var spotter = KeywordSpotter.clipIt
            #expect(spotter.consume(text) == 1, "\(text)")
        }
    }

    @Test("ignores unrelated speech")
    func noFalseMatch() {
        for text in ["", "nice shot", "clip", "it", "eclipse it", "clip the wing"] {
            var spotter = KeywordSpotter.clipIt
            #expect(spotter.consume(text) == 0, "\(text)")
        }
    }

    @Test("custom phrases")
    func customPhrases() {
        var spotter = KeywordSpotter(phrases: ["save that"])
        #expect(spotter.consume("clip it") == 0)
        #expect(spotter.consume("clip it save that") == 1)
    }
}
