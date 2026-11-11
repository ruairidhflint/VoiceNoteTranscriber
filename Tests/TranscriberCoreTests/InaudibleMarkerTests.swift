import Foundation
import Testing
@testable import TranscriberCore

struct InaudibleMarkerTests {
    /// Builds tokens from (text, probability) pairs; the transcript is their concatenation unless given.
    private func mark(_ pairs: [(String, Double)], text: String? = nil, threshold: Double = 0.5) -> String {
        let tokens = pairs.map { TokenLogprob($0.0, probability: $0.1) }
        return InaudibleMarker.mark(text ?? pairs.map(\.0).joined(), tokens: tokens, threshold: threshold)
    }

    @Test func doubtfulWordBecomesInaudibleAndKeepsItsPunctuation() {
        let result = mark([("We", 0.99), (" walked", 0.98), (" past", 0.97), (" Darthing", 0.2), (",", 0.9), (" then", 0.95), (" home", 0.99), (".", 0.99)])
        #expect(result == "We walked past [inaudible], then home.")
    }

    @Test func confidentWordsAreUntouched() {
        let text = "It's a lovely morning."
        #expect(mark([("It's", 0.99), (" a", 0.9), (" lovely", 0.8), (" morning", 0.7), (".", 0.99)]) == text)
    }

    @Test func wordConfidenceIsTheProductOfItsTokens() {
        // Each piece is 60% likely, but the made-up word as a whole is only 22%.
        let result = mark([("In", 0.99), (" Wonder", 0.6), ("mush", 0.6), ("ly", 0.6), (" again", 0.99)])
        #expect(result == "In [inaudible] again")
    }

    @Test func neighbouringDoubtfulWordsBecomeOneMarker() {
        let result = mark([("He", 0.99), (" said", 0.99), (" the", 0.3), (" hazard", 0.2), (" from", 0.4), (" the", 0.99), (" right", 0.99)])
        #expect(result == "He said [inaudible] the right")
    }

    @Test func markersDontMergeAcrossSentencesOrLines() {
        let result = mark([("It", 0.99), (" was", 0.99), (" green", 0.2), (".", 0.99), (" Blue", 0.2), (" sky", 0.99), (".\n\n", 0.99), ("Red", 0.2), (" door", 0.99)])
        #expect(result == "It was [inaudible]. [inaudible] sky.\n\n[inaudible] door")
    }

    @Test func punctuationProbabilityDoesntCount() {
        // Unsure whether to end the sentence, sure of the words.
        #expect(mark([("Yes", 0.99), (".", 0.05), (" Fine", 0.99)]) == "Yes. Fine")
    }

    @Test func linesUpWithSpacesTheTokensDontHave() {
        // OpenAI's text puts a space between sentences that the tokens leave out.
        let result = mark([("Not", 0.99), (" me", 0.99), (".", 0.99), ("Art", 0.1), (" of", 0.99), (" it", 0.99)], text: "Not me. Art of it")
        #expect(result == "Not me. [inaudible] of it")
    }

    @Test func fallsBackToTheTokensIfTheTextDisagrees() {
        let result = mark([("Hello", 0.99), (" wrld", 0.1)], text: "Hello world")
        #expect(result == "Hello [inaudible]")
    }

    @Test func offLeavesWordsButStillTidiesMarkers() {
        let result = mark([("By", 0.99), (" the", 0.1), (" [unclear]", 0.9)], threshold: 0)
        #expect(result == "By the [inaudible]")
    }

    @Test func modelMarkersMergeWithOurs() {
        let result = mark([("By", 0.99), (" the", 0.1), (" (inaudible)", 0.9), (" river", 0.99)])
        #expect(result == "By [inaudible] river")
    }

    @Test func accentedLettersCountAsPartOfTheWord() {
        #expect(mark([("A", 0.99), (" café", 0.1), (" nearby", 0.99)]) == "A [inaudible] nearby")
    }

    @Test func readsTokensFromTheAPIResponse() throws {
        let json = #"[{"token": "Hi", "logprob": -0.01, "bytes": [72, 105]}, {"token": " there", "logprob": -2.5, "bytes": [32, 116, 104, 101, 114, 101]}]"#
        let value = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let tokens = try #require(OpenAIClient.tokenLogprobs(value))
        #expect(tokens.map(\.bytes) == [Array("Hi".utf8), Array(" there".utf8)])
        #expect(tokens.map(\.logprob) == [-0.01, -2.5])
        #expect(OpenAIClient.tokenLogprobs(nil) == nil)
        #expect(OpenAIClient.tokenLogprobs([[String: Any]]()) == nil)
    }
}
