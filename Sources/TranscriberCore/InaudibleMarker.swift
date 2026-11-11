import Foundation

/// How readily words the transcriber wasn't sure of are replaced with [inaudible].
public enum InaudibleStrictness: String, CaseIterable, Identifiable, Sendable {
    case off, light, balanced, strict

    public var id: String { rawValue }

    /// A word becomes [inaudible] when the model's confidence in it is below this.
    public var threshold: Double {
        switch self {
        case .off: 0
        case .light: 0.3
        case .balanced: 0.5
        case .strict: 0.7
        }
    }

    public var label: String {
        switch self {
        case .off: "Off"
        case .light: "Light"
        case .balanced: "Balanced"
        case .strict: "Strict"
        }
    }

    public var summary: String {
        switch self {
        case .off: "Every word is kept as OpenAI heard it, even when it wasn't sure."
        case .strict: "Any word OpenAI was less than 70% sure of becomes [inaudible]. Expect a lot of them."
        default: "Any word OpenAI was less than \(Int(threshold * 100))% sure of becomes [inaudible]."
        }
    }
}

/// One token of a transcript with the model's log probability for it, as returned by `/v1/audio/transcriptions`
/// with `include[]=logprobs`.
public struct TokenLogprob: Sendable, Equatable {
    public let bytes: [UInt8]
    public let logprob: Double

    public init(bytes: [UInt8], logprob: Double) {
        self.bytes = bytes
        self.logprob = logprob
    }

    public init(_ token: String, probability: Double) {
        self.init(bytes: Array(token.utf8), logprob: log(probability))
    }
}

/// Turns words the transcriber wasn't confident about into [inaudible], so a doubtful word is never passed off as heard.
///
/// A word's confidence is the product of the probabilities of the tokens that spell it, so a made-up word
/// built from several half-sure tokens scores low even when no single token does. Neighbouring doubtful words
/// in the same phrase become one [inaudible].
public enum InaudibleMarker {
    public static func mark(_ text: String, tokens: [TokenLogprob], threshold: Double) -> String {
        guard threshold > 0, !tokens.isEmpty else { return normalise(text) }
        let tokenBytes = tokens.flatMap(\.bytes)
        let tokenIndex = tokens.enumerated().flatMap { index, token in Array(repeating: index, count: token.bytes.count) }

        // The returned text can have spaces the tokens don't (between sentences), so line them up ignoring whitespace.
        // If they disagree on anything else, the tokens are what the probabilities describe, so use their text.
        var bytes = Array(text.utf8)
        var owner = align(bytes, to: tokenBytes, tokenIndex: tokenIndex)
        if owner == nil {
            bytes = tokenBytes
            owner = tokenIndex.map(Optional.some)
        }
        guard let owner else { return normalise(text) }

        let words = words(in: bytes)
        let doubtful = words.map { word -> Bool in
            guard let core = word.core else { return false }
            let used = Set(core.compactMap { owner[$0] })
            return exp(used.reduce(0) { $0 + tokens[$1].logprob }) < threshold
        }

        var out: [UInt8] = []
        var cursor = 0
        var index = 0
        while index < words.count {
            let word = words[index]
            out += bytes[cursor..<word.range.lowerBound] // whitespace before the word
            guard doubtful[index], let core = word.core else {
                out += bytes[word.range]
                cursor = word.range.upperBound
                index += 1
                continue
            }
            // Extend over following doubtful words in the same phrase: no punctuation or line break between them.
            var last = index
            var lastCore = core
            while last + 1 < words.count, doubtful[last + 1], let nextCore = words[last + 1].core,
                  lastCore.upperBound == words[last].range.upperBound,
                  nextCore.lowerBound == words[last + 1].range.lowerBound,
                  !bytes[words[last].range.upperBound..<nextCore.lowerBound].contains(UInt8(ascii: "\n")) {
                last += 1
                lastCore = nextCore
            }
            out += bytes[word.range.lowerBound..<core.lowerBound]
            out += Array(DefaultPrompt.inaudible.utf8)
            out += bytes[lastCore.upperBound..<words[last].range.upperBound]
            cursor = words[last].range.upperBound
            index = last + 1
        }
        out += bytes[cursor...]
        return normalise(String(decoding: out, as: UTF8.self))
    }

    /// The model's own markers, like "[unclear]" or "(inaudible)", become the app's [inaudible]; repeats collapse to one.
    static func normalise(_ text: String) -> String {
        text
            .replacing(/[\[(]+(?i:inaudible|unclear|indistinct|unintelligible)[\])]+/, with: DefaultPrompt.inaudible)
            .replacing(/\[inaudible\](?:[ \t]+\[inaudible\])+/, with: DefaultPrompt.inaudible)
    }

    /// For each byte of `text`, the token it came from, or nil for whitespace the tokens don't have.
    /// Nil overall if the two differ in anything but whitespace.
    static func align(_ text: [UInt8], to tokens: [UInt8], tokenIndex: [Int]) -> [Int?]? {
        var owner = [Int?](repeating: nil, count: text.count)
        var i = 0, j = 0
        while i < text.count || j < tokens.count {
            if i < text.count, j < tokens.count, text[i] == tokens[j] {
                owner[i] = tokenIndex[j]
                i += 1
                j += 1
            } else if i < text.count, isSpace(text[i]) {
                i += 1
            } else if j < tokens.count, isSpace(tokens[j]) {
                j += 1
            } else {
                return nil
            }
        }
        return owner
    }

    /// Whitespace-separated words, each with its core: the span from its first letter or digit to its last,
    /// leaving surrounding punctuation outside. Nil core for words that are only punctuation.
    static func words(in bytes: [UInt8]) -> [(range: Range<Int>, core: Range<Int>?)] {
        var result: [(Range<Int>, Range<Int>?)] = []
        var i = 0
        while i < bytes.count {
            if isSpace(bytes[i]) { i += 1; continue }
            var j = i
            while j < bytes.count, !isSpace(bytes[j]) { j += 1 }
            let first = (i..<j).first { isContent(bytes[$0]) }
            let last = (i..<j).last { isContent(bytes[$0]) }
            result.append((i..<j, first.flatMap { f in last.map { f..<($0 + 1) } }))
            i = j
        }
        return result
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x0A || byte == 0x09 || byte == 0x0D
    }

    /// Letters and digits. Non-ASCII bytes count too, so accented letters (and curly apostrophes inside words) stay in the core.
    private static func isContent(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
}
