import Foundation
import Testing
@testable import TranscriberCore

struct NoteLibraryTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "library-\(UUID().uuidString)")

    func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func meta(_ recorded: Date, source: String = "New Recording 23.m4a") -> NoteMetadata {
        NoteMetadata(recordedAt: recorded, duration: 95, sourceFileName: source, model: "gpt-audio-1.5")
    }

    @Test func listsOnlyTheAppsNotesNewestFirst() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try NoteWriter.write(transcript: "Older idea.", title: "Older", metadata: meta(date(9, 8, 0)), format: .markdown, to: folder)
        _ = try NoteWriter.write(transcript: "Plain one.\n\nSecond para.", title: "Plain", metadata: meta(date(10, 9, 30), source: "Canal \"walk\".m4a"), format: .plainText, to: folder)
        _ = try NoteWriter.write(transcript: "Newest.", title: "Newest", metadata: meta(date(11, 7, 15)), format: .markdown, to: folder)
        try "# Some other Obsidian note\n\nNot ours.".write(to: folder.appending(path: "Other.md"), atomically: true, encoding: .utf8)
        try "---\ntags: [x]\n---\n\nFront matter, but not ours.".write(to: folder.appending(path: "Tagged.md"), atomically: true, encoding: .utf8)

        let notes = NoteLibrary.load(from: folder)
        #expect(notes.map(\.title) == ["Newest", "Plain", "Older"])

        let plain = notes[1]
        #expect(plain.format == .plainText)
        #expect(plain.transcript == "Plain one.\n\nSecond para.")
        #expect(plain.source == "Canal \"walk\".m4a")
        #expect(plain.duration == "1m 35s")
        #expect(plain.model == "gpt-audio-1.5")
        #expect(abs(plain.recordedAt.timeIntervalSince(date(10, 9, 30))) < 60)
        #expect(notes[0].transcript == "Newest.")
    }

    @Test func survivesRenamingInFinder() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try NoteWriter.write(transcript: "Text.", title: "Original", metadata: meta(date(10, 9, 1)), format: .markdown, to: folder)
        let renamed = folder.appending(path: "My own name.md")
        try FileManager.default.moveItem(at: url, to: renamed)

        let note = try #require(NoteLibrary.load(from: folder).first)
        #expect(note.title == "My own name")
        #expect(note.recordedAt == date(10, 9, 1)) // from the header, not the (now missing) file-name date
        #expect(note.url.lastPathComponent == "My own name.md")
    }

    @Test func splitsDatedFileNames() {
        let (stamp, title) = NoteLibrary.splitFileName("2026-11-10 09.01 – Mourning as a fan")
        #expect(title == "Mourning as a fan")
        #expect(stamp == date(10, 9, 1))
        #expect(NoteLibrary.splitFileName("Just a name").1 == "Just a name")
    }
}
