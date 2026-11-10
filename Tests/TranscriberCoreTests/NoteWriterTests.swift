import Foundation
import Testing
@testable import TranscriberCore

struct NoteWriterTests {
    let recorded = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 14, minute: 32))!
    let metadata: NoteMetadata

    init() {
        metadata = NoteMetadata(recordedAt: recorded, duration: 1489, sourceFileName: "New Recording 23.m4a", model: "gpt-audio-1.5")
    }

    @Test func sanitisesTitles() {
        #expect(NoteWriter.sanitizeTitle("Title: My \"big\" idea / plan.") == "My big idea plan")
        #expect(NoteWriter.sanitizeTitle("  \n ") == "Untitled")
        #expect(NoteWriter.sanitizeTitle(".hidden") == "hidden")
        #expect(NoteWriter.sanitizeTitle(String(repeating: "word ", count: 40)).count <= 80)
    }

    @Test func namesFilesWithDateAndTitle() {
        #expect(NoteWriter.fileName(title: "Lighthouse opening", recordedAt: recorded, format: .markdown)
                == "2026-11-10 14.32 – Lighthouse opening.md")
        #expect(NoteWriter.fileName(title: "x", recordedAt: recorded, format: .plainText, copy: 2)
                == "2026-11-10 14.32 – x (2).txt")
    }

    @Test func formatsDurations() {
        #expect(NoteWriter.formatDuration(1489) == "24m 49s")
        #expect(NoteWriter.formatDuration(45) == "45s")
        #expect(NoteWriter.formatDuration(3723) == "1h 02m 03s")
    }

    @Test func rendersDetailsHeader() {
        let md = NoteWriter.render(transcript: "Hello.", metadata: metadata, format: .markdown)
        #expect(md.hasPrefix("---\nrecorded: 2026-11-10 14:32\nduration: 24m 49s\nsource: \"New Recording 23.m4a\"\nmodel: gpt-audio-1.5\n---\n\nHello.\n"))
        let txt = NoteWriter.render(transcript: "Hello.", metadata: metadata, format: .plainText)
        #expect(txt.contains("Duration: 24m 49s\nSource: New Recording 23.m4a\nModel: gpt-audio-1.5\n\nHello.\n"))
    }

    @Test func writesAvoidsCollisionsAndRenames() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "notewriter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try NoteWriter.write(transcript: "One.", title: "Idea", metadata: metadata, format: .markdown, to: folder)
        let second = try NoteWriter.write(transcript: "Two.", title: "Idea", metadata: metadata, format: .markdown, to: folder)
        #expect(first.lastPathComponent == "2026-11-10 14.32 – Idea.md")
        #expect(second.lastPathComponent == "2026-11-10 14.32 – Idea (2).md")

        let renamed = try NoteWriter.rename(second, toTitle: "Better name", recordedAt: recorded, format: .markdown)
        #expect(renamed.lastPathComponent == "2026-11-10 14.32 – Better name.md")
        #expect(!FileManager.default.fileExists(atPath: second.path))
        #expect(try String(contentsOf: renamed, encoding: .utf8).contains("Two."))

        // Renaming to its own name is a no-op; renaming onto another note's name gets a suffix.
        #expect(try NoteWriter.rename(renamed, toTitle: "Better name", recordedAt: recorded, format: .markdown) == renamed)
        let clash = try NoteWriter.rename(renamed, toTitle: "Idea", recordedAt: recorded, format: .markdown)
        #expect(clash.lastPathComponent == "2026-11-10 14.32 – Idea (2).md")
    }
}
