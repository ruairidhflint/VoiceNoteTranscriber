import AppKit
import Foundation
import Observation
import TranscriberCore
import UniformTypeIdentifiers

enum Prefs {
    static let modelKey = "model"
    static let formatKey = "format"
    static let folderKey = "outputFolder"
    static let promptKey = "prompt"
    static let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Documents/Voice Notes", directoryHint: .isDirectory)

    static var outputFolder: URL {
        UserDefaults.standard.string(forKey: folderKey).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? defaultFolder
    }

    static func pipelineSettings(apiKey: String) -> PipelineSettings {
        let defaults = UserDefaults.standard
        let prompt = defaults.string(forKey: promptKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return PipelineSettings(
            apiKey: apiKey,
            model: defaults.string(forKey: modelKey).flatMap(TranscriptionModel.init(rawValue:)) ?? .gptAudio,
            prompt: (prompt?.isEmpty == false ? prompt : nil) ?? DefaultPrompt.text,
            outputFolder: outputFolder,
            format: defaults.string(forKey: formatKey).flatMap(OutputFormat.init(rawValue:)) ?? .markdown)
    }
}

enum JobState: Equatable {
    case queued
    case decoding
    case transcribing(part: Int, of: Int)
    case titling
    case saving
    case failed(String)

    init(_ stage: PipelineStage) {
        switch stage {
        case .decoding: self = .decoding
        case .transcribing(let part, let total): self = .transcribing(part: part, of: total)
        case .titling: self = .titling
        case .saving: self = .saving
        }
    }

    var isWorking: Bool {
        switch self {
        case .queued, .failed: false
        default: true
        }
    }

    var label: String {
        switch self {
        case .queued: "Waiting"
        case .decoding: "Reading audio…"
        case .transcribing(let part, let total): total > 1 ? "Transcribing part \(part) of \(total)…" : "Transcribing…"
        case .titling: "Writing title…"
        case .saving: "Saving…"
        case .failed: "Failed"
        }
    }
}

/// An audio file waiting, being transcribed, or failed. Once saved it leaves the queue and appears in the library.
@MainActor @Observable
final class Job: Identifiable {
    let id = UUID()
    let source: URL
    var state: JobState = .queued

    var name: String { source.deletingPathExtension().lastPathComponent }

    init(source: URL) {
        self.source = source
    }
}

enum SidebarItem: Hashable {
    case job(Job.ID)
    case note(SavedNote.ID)
}

@MainActor @Observable
final class TranscriptionQueue {
    static let shared = TranscriptionQueue()

    /// Audio being transcribed (or that failed).
    var jobs: [Job] = []
    /// Every saved note in the output folder, newest first.
    var notes: [SavedNote] = []
    var selection: SidebarItem?
    /// E.g. "couldn't write a title", shown on a freshly saved note until the app quits.
    var noteWarnings: [SavedNote.ID: String] = [:]
    private(set) var hasAPIKey = false

    @ObservationIgnored private var apiKey: String?
    @ObservationIgnored private var isRunning = false
    @ObservationIgnored private let watcher = FolderWatcher()
    @ObservationIgnored private var pendingReload: Task<Void, Never>?

    init() {
        #if DEBUG
        if SnapshotRenderer.isActive { return } // sample data only: don't touch the Keychain
        #endif
        apiKey = Keychain.read()
        hasAPIKey = apiKey != nil
    }

    var selectedJob: Job? {
        guard case .job(let id) = selection else { return nil }
        return jobs.first { $0.id == id }
    }

    var selectedNote: SavedNote? {
        guard case .note(let id) = selection else { return nil }
        return notes.first { $0.id == id }
    }

    // MARK: API key

    func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        try Keychain.save(trimmed)
        apiKey = trimmed
        hasAPIKey = true
    }

    func removeKey() {
        Keychain.delete()
        apiKey = nil
        hasAPIKey = false
    }

    // MARK: Library

    /// Re-reads the output folder and (re)attaches the Finder watcher. Cheap; called on launch, on activation,
    /// when the folder setting changes, and whenever the folder's contents change.
    func refreshLibrary() async {
        #if DEBUG
        if SnapshotRenderer.isActive { return } // keep the sample notes, don't read your folder
        #endif
        let folder = Prefs.outputFolder
        if watcher.folder?.path != folder.path || !watcher.isWatching {
            watcher.watch(folder) { [weak self] in self?.scheduleRefresh() }
        }
        let loaded = await Task.detached(priority: .userInitiated) { NoteLibrary.load(from: folder) }.value
        guard folder.path == Prefs.outputFolder.path else { return } // setting changed while loading
        notes = loaded
        if case .note(let id) = selection, !loaded.contains(where: { $0.id == id }) {
            selection = nil // deleted or renamed outside the app
        }
    }

    /// Coalesces bursts of file-system events (a save is often several) into one reload.
    func scheduleRefresh() {
        pendingReload?.cancel()
        pendingReload = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshLibrary()
        }
    }

    func rename(_ note: SavedNote, to newTitle: String) async {
        let clean = NoteWriter.sanitizeTitle(newTitle)
        guard clean != note.title else { return }
        do {
            let url = try NoteWriter.rename(note.url, toTitle: clean, recordedAt: note.recordedAt, format: note.format)
            if let warning = noteWarnings.removeValue(forKey: note.id) { noteWarnings[url.path] = warning }
            selection = .note(url.path)
            await refreshLibrary()
        } catch {
            noteWarnings[note.id] = "Couldn't rename the file: \(error.localizedDescription)"
        }
    }

    func moveToTrash(_ note: SavedNote) async {
        do {
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
            if selection == .note(note.id) { selection = nil }
            await refreshLibrary()
        } catch {
            noteWarnings[note.id] = "Couldn't move to Trash: \(error.localizedDescription)"
        }
    }

    // MARK: Queue

    func add(_ urls: [URL]) {
        let files = Self.audioFiles(in: urls)
        guard !files.isEmpty else {
            NSSound.beep()
            return
        }
        let new = files.map(Job.init)
        jobs.append(contentsOf: new)
        if selection == nil, let first = new.first { selection = .job(first.id) }
        runIfNeeded()
    }

    func retry(_ job: Job) {
        job.state = .queued
        runIfNeeded()
    }

    func remove(_ job: Job) {
        guard !job.state.isWorking else { return }
        jobs.removeAll { $0.id == job.id }
        if selection == .job(job.id) { selection = nil }
    }

    private func runIfNeeded() {
        guard !isRunning else { return }
        isRunning = true
        Task {
            while let job = jobs.first(where: { $0.state == .queued }) {
                await process(job)
            }
            isRunning = false
        }
    }

    private func process(_ job: Job) async {
        guard let apiKey else {
            job.state = .failed("Add your OpenAI API key in Settings (⌘,), then retry.")
            return
        }
        job.state = .decoding
        do {
            let result = try await TranscriptionPipeline.run(source: job.source, settings: Prefs.pipelineSettings(apiKey: apiKey)) { stage in
                await MainActor.run { job.state = JobState(stage) }
            }
            if let warning = result.titleWarning { noteWarnings[result.outputURL.path] = warning }
            // Load the new note before the job disappears, so the sidebar doesn't flicker.
            await refreshLibrary()
            jobs.removeAll { $0.id == job.id }
            if selection == .job(job.id) { selection = .note(result.outputURL.path) }
        } catch {
            job.state = .failed(error.localizedDescription)
        }
    }

    /// Audio files among the dropped items; dropped folders contribute their audio files (not recursively).
    static func audioFiles(in urls: [URL]) -> [URL] {
        urls.flatMap { url -> [URL] in
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let contents = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
                return contents.filter(isAudio).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            }
            return isAudio(url) ? [url] : []
        }
    }

    static func isAudio(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }
}
