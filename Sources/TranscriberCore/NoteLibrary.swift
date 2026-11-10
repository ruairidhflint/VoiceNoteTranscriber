import Foundation

/// A transcript previously saved by the app, read back from the output folder.
public struct SavedNote: Sendable, Identifiable, Hashable {
    /// The file path; stable until the file is renamed.
    public var id: String { url.path }
    public let url: URL
    public let title: String
    public let recordedAt: Date
    public let duration: String?
    public let source: String?
    public let model: String?
    public let transcript: String
    public let format: OutputFormat
}

/// The output folder is the library: whatever is in it (renamed, moved or deleted in Finder) is what the app shows.
/// Only files carrying the app's details header are listed, so pointing it at e.g. an Obsidian vault won't list other notes.
public enum NoteLibrary {
    /// Notes in the folder (not subfolders), newest recording first.
    public static func load(from folder: URL) -> [SavedNote] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: .skipsHiddenFiles)) ?? []
        return files
            .compactMap { read(folder.appending(path: $0.lastPathComponent)) }
            .sorted { ($0.recordedAt, $1.title) > ($1.recordedAt, $0.title) }
    }

    public static func read(_ url: URL) -> SavedNote? {
        guard let format = OutputFormat(rawValue: url.pathExtension.lowercased()),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return parse(text, url: url, format: format, fileDate: fileDate)
    }

    static func parse(_ text: String, url: URL, format: OutputFormat, fileDate: Date) -> SavedNote? {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        let header: [String: String]
        let body: Substring
        switch format {
        case .markdown:
            guard text.hasPrefix("---\n"),
                  let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex)
            else { return nil }
            header = fields(text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound], lowercasedKeys: true)
            body = text[end.upperBound...]
        case .plainText:
            let end = text.range(of: "\n\n")
            header = fields(text[..<(end?.lowerBound ?? text.endIndex)], lowercasedKeys: true)
            body = end.map { text[$0.upperBound...] } ?? ""
        }
        // The app always writes both of these; other notes in the folder won't have them.
        guard let source = header["source"], let model = header["model"] else { return nil }

        let (stamp, title) = splitFileName(url.deletingPathExtension().lastPathComponent)
        let recorded = header["recorded"].flatMap { parseRecorded($0, format: format) } ?? stamp ?? fileDate
        return SavedNote(
            url: url,
            title: title,
            recordedAt: recorded,
            duration: header["duration"],
            source: format == .markdown ? unquoteYAML(source) : source,
            model: model,
            transcript: body.trimmingCharacters(in: .whitespacesAndNewlines),
            format: format)
    }

    /// "2026-11-10 14.32 – Title" → (date, "Title"). Names without the date prefix (e.g. renamed in Finder) are all title.
    static func splitFileName(_ name: String) -> (Date?, String) {
        guard let match = name.wholeMatch(of: /(\d{4}-\d{2}-\d{2} \d{2}\.\d{2})\s+[–—-]\s+(.+)/) else { return (nil, name) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return (formatter.date(from: String(match.1)), String(match.2))
    }

    private static func fields(_ block: Substring, lowercasedKeys: Bool) -> [String: String] {
        var result: [String: String] = [:]
        for line in block.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            result[lowercasedKeys ? key.lowercased() : key] = value
        }
        return result
    }

    private static func parseRecorded(_ value: String, format: OutputFormat) -> Date? {
        switch format {
        case .markdown:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.date(from: value)
        case .plainText:
            return try? Date(value, strategy: Date.FormatStyle(date: .long, time: .shortened).parseStrategy)
        }
    }

    private static func unquoteYAML(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }
}
