import Testing
@testable import TranscriberCore

struct StitcherTests {
    @Test func dropsSilentChunksAndJoinsSensibly() {
        let joined = Stitcher.join(["First thought.", "[no speech]", "and then I", "carried on", "  "])
        #expect(joined == "First thought.\n\nand then I carried on")
    }

    @Test func allSilentGivesNoSpeech() {
        #expect(Stitcher.join(["[No speech]", ""]) == DefaultPrompt.noSpeech)
    }

    @Test func inaudibleAtChunkEndIsNotASentenceEnd() {
        #expect(Stitcher.join(["It was [inaudible]", "by the river."]) == "It was [inaudible] by the river.")
        #expect(Stitcher.join(["She said “go.”", "Next."]) == "She said “go.”\n\nNext.")
    }
}
