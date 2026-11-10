import Testing
@testable import TranscriberCore

struct ChunkerTests {
    /// Synthetic "speech": loud noise with quiet gaps at known places. Low sample rate keeps the test fast.
    static func synthetic(seconds: Int, rate: Int, gaps: [(start: Double, length: Double)]) -> [Int16] {
        var seed: UInt32 = 42
        func noise(_ amplitude: Int32) -> Int16 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Int16(Int32(seed >> 16) % (2 * amplitude) - amplitude)
        }
        return (0..<(seconds * rate)).map { i in
            let t = Double(i) / Double(rate)
            let inGap = gaps.contains { t >= $0.start && t < $0.start + $0.length }
            return noise(inGap ? 20 : 4000)
        }
    }

    @Test func shortRecordingIsSentWhole() {
        let samples = Self.synthetic(seconds: 200, rate: 1000, gaps: [])
        #expect(Chunker.split(samples, sampleRate: 1000) == [0..<samples.count])
    }

    @Test func longRecordingIsCutInsidePauses() {
        let rate = 1000
        // A 1 s pause every 45 s, plus a long 3 s pause at 250 s.
        var gaps = stride(from: 30.0, to: 720, by: 45).map { (start: $0, length: 1.0) }
        gaps.append((start: 250, length: 3))
        let samples = Self.synthetic(seconds: 720, rate: rate, gaps: gaps)
        let ranges = Chunker.split(samples, sampleRate: rate)

        #expect(ranges.count >= 3)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            #expect(a.upperBound == b.lowerBound, "chunks must be contiguous")
        }
        for range in ranges {
            #expect(Double(range.count) / Double(rate) <= 330.5)
        }
        for range in ranges.dropLast() {
            let cut = Double(range.upperBound) / Double(rate)
            #expect(gaps.contains { cut >= $0.start && cut <= $0.start + $0.length }, "cut at \(cut)s is not in a pause")
        }
        // The long pause near the 240 s target should win over the short ones.
        let firstCut = Double(ranges[0].upperBound) / Double(rate)
        #expect(firstCut >= 250 && firstCut <= 253)
    }

    @Test func recordingWithNoPausesStillGetsSplit() {
        let samples = Self.synthetic(seconds: 700, rate: 1000, gaps: [])
        let ranges = Chunker.split(samples, sampleRate: 1000)
        #expect(ranges.count >= 3)
        #expect(ranges.allSatisfy { Double($0.count) / 1000 <= 330.5 })
        #expect(ranges.last?.upperBound == samples.count)
    }
}
