import Foundation

/// Splits long recordings into a few minutes per request, cutting at natural pauses so no sentence is sliced in half.
public enum Chunker {
    public struct Options: Sendable {
        /// Preferred chunk length.
        public var target: TimeInterval = 240
        /// Never cut sooner than this…
        public var minimum: TimeInterval = 120
        /// …or later than this. Recordings shorter than this are sent whole.
        public var maximum: TimeInterval = 330

        public init() {}
    }

    /// Returns sample ranges covering the whole recording, in order, with no gaps or overlaps.
    public static func split(_ samples: [Int16], sampleRate: Int, options: Options = .init()) -> [Range<Int>] {
        let count = samples.count
        guard Double(count) > options.maximum * Double(sampleRate) else { return [0..<count] }

        let hop = sampleRate / 10 // 100 ms frames
        let fps = 10.0
        let levels = frameLevels(samples, hop: hop)
        let threshold = quietThreshold(levels)

        var ranges: [Range<Int>] = []
        var start = 0 // frame index
        while Double(levels.count - start) > options.maximum * fps {
            let window = (start + Int(options.minimum * fps))...min(start + Int(options.maximum * fps), levels.count - 1)
            let cut = bestCut(levels: levels, in: window, target: start + Int(options.target * fps), threshold: threshold)
            ranges.append((start * hop)..<(cut * hop))
            start = cut
        }
        ranges.append((start * hop)..<count)
        return ranges
    }

    /// Loudness of each frame in dBFS.
    static func frameLevels(_ samples: [Int16], hop: Int) -> [Double] {
        samples.withUnsafeBufferPointer { buffer in
            stride(from: 0, to: buffer.count, by: hop).map { i in
                let end = min(i + hop, buffer.count)
                var sum = 0.0
                for j in i..<end {
                    let s = Double(buffer[j])
                    sum += s * s
                }
                let meanSquare = sum / Double(end - i)
                return meanSquare > 0 ? 10 * log10(meanSquare / (32768.0 * 32768.0)) : -120
            }
        }
    }

    /// "Quiet" means within 6 dB of the background noise floor (the 10th-percentile frame).
    static func quietThreshold(_ levels: [Double]) -> Double {
        let sorted = levels.sorted()
        return sorted[sorted.count / 10] + 6
    }

    /// The middle of the longest pause in the window, nudged towards the target; the quietest frame if there's no pause.
    static func bestCut(levels: [Double], in window: ClosedRange<Int>, target: Int, threshold globalThreshold: Double) -> Int {
        // The global threshold assumes ≥10% of the recording is pauses. If pauses are rarer it rises into speech,
        // so also require frames to be within 8 dB of this window's quietest moment.
        let localThreshold = max(levels[window].min()!, -90) + 8
        let threshold = min(globalThreshold, localThreshold)
        var best: (score: Double, frame: Int)?
        var runStart: Int?
        for frame in window.lowerBound...(window.upperBound + 1) {
            let quiet = frame <= window.upperBound && levels[frame] < threshold
            if quiet {
                if runStart == nil { runStart = frame }
            } else if let s = runStart {
                let length = frame - s
                if length >= 3 { // at least 0.3 s
                    let middle = s + length / 2
                    // A 1 s longer pause outweighs being ~3 min further from the target.
                    let score = Double(length) - Double(abs(middle - target)) * 0.005
                    if best == nil || score > best!.score { best = (score, middle) }
                }
                runStart = nil
            }
        }
        if let best { return best.frame }
        return window.min { a, b in
            levels[a] != levels[b] ? levels[a] < levels[b] : abs(a - target) < abs(b - target)
        }!
    }
}
