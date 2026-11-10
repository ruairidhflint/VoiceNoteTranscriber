import Foundation

/// Joins per-chunk transcripts back into one.
public enum Stitcher {
    public static func join(_ parts: [String]) -> String {
        let kept = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(DefaultPrompt.noSpeech) != .orderedSame }
        guard var result = kept.first else { return DefaultPrompt.noSpeech }
        for part in kept.dropFirst() {
            // Chunks are cut at pauses: a finished sentence gets a paragraph break, a mid-sentence pause just a space.
            result += endsSentence(result) ? "\n\n" : " "
            result += part
        }
        return result
    }

    static func endsSentence(_ text: String) -> Bool {
        var trimmed = Substring(text)
        while let last = trimmed.last, "\"'”’)".contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return false }
        return ".?!…".contains(last)
    }
}
