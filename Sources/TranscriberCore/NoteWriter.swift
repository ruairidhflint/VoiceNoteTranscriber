import Foundation

public enum OutputFormat: String, CaseIterable, Identifiable, Sendable {
    case markdown = "md"
    case plainText = "txt"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .markdown: "Markdown (.md)"
        case .plainText: "Plain text (.txt)"
        }
    }
}

public struct NoteMetadata: Sendable, Equatable {
    public var recordedAt: Date
    public var duration: TimeInterval
    public var sourceFileName: String
    public var model: String

    public init(recordedAt: Date, duration: TimeInterval, sourceFileName: String, model: String) {
        self.recordedAt = recordedAt
        self.duration = duration
        self.sourceFileName = sourceFileName
        self.model = model
    }
}

/// Names, renders, saves and renames transcript files: `2026-11-10 14.32 – Title.md`.
public enum NoteWriter {
    // MARK: Naming

    public static func sanitizeTitle(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.newlines).union(.controlCharacters)
        var title = String(String.UnicodeScalarView(raw.unicodeScalars.map { forbidden.contains($0) ? " " : $0 }))
        title = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if title.lowercased().hasPrefix("title ") { title = String(title.dropFirst(6)) }
        title = title.trimmingCharacters(in: CharacterSet(charactersIn: " .'‘’“”-–—#*_`"))
        if title.count > 80 {
            let cut = title.prefix(80)
            title = String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
        }
        return title.isEmpty ? "Untitled" : title
    }

    public static func fileName(title: String, recordedAt: Date, format: OutputFormat, copy: Int = 1) -> String {
        let base = "\(stamp(recordedAt)) – \(sanitizeTitle(title))"
        return (copy > 1 ? "\(base) (\(copy))" : base) + "." + format.rawValue
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: date)
    }

    // MARK: Rendering

    public static func render(transcript: String, metadata: NoteMetadata, format: OutputFormat) -> String {
        switch format {
        case .markdown:
            let iso = DateFormatter()
            iso.locale = Locale(identifier: "en_US_POSIX")
            iso.dateFormat = "yyyy-MM-dd HH:mm"
            return """
            ---
            recorded: \(iso.string(from: metadata.recordedAt))
            duration: \(formatDuration(metadata.duration))
            source: \(yamlQuoted(metadata.sourceFileName))
            model: \(metadata.model)
            ---

            \(transcript)

            """
        case .plainText:
            return """
            Recorded: \(metadata.recordedAt.formatted(date: .long, time: .shortened))
            Duration: \(formatDuration(metadata.duration))
            Source: \(metadata.sourceFileName)
            Model: \(metadata.model)

            \(transcript)

            """
        }
    }

    public static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        if h > 0 { return String(format: "%dh %02dm %02ds", h, m, s) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    static func yamlQuoted(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: Files

    public static func write(transcript: String, title: String, metadata: NoteMetadata, format: OutputFormat, to folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = availableURL(in: folder, title: title, recordedAt: metadata.recordedAt, format: format)
        try render(transcript: transcript, metadata: metadata, format: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Renames a saved note after its title is edited. Returns the new location.
    public static func rename(_ url: URL, toTitle title: String, recordedAt: Date, format: OutputFormat) throws -> URL {
        let target = availableURL(in: url.deletingLastPathComponent(), title: title, recordedAt: recordedAt, format: format, current: url)
        guard target.path != url.path else { return url }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// First name not already taken, adding " (2)", " (3)"… if needed. `current` counts as free (the file being renamed).
    static func availableURL(in folder: URL, title: String, recordedAt: Date, format: OutputFormat, current: URL? = nil) -> URL {
        var copy = 1
        while true {
            let candidate = folder.appending(path: fileName(title: title, recordedAt: recordedAt, format: format, copy: copy))
            // Case-insensitive: on APFS "Title.md" and "title.md" are the same file.
            if let current, candidate.path.lowercased() == current.path.lowercased() { return candidate }
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            copy += 1
        }
    }
}
