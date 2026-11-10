import SwiftUI
import TranscriberCore
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(TranscriptionQueue.self) private var queue
    @AppStorage(Prefs.folderKey) private var folder = Prefs.defaultFolder.path
    @State private var isDropTargeted = false
    @State private var isImporting = false

    var body: some View {
        @Bindable var queue = queue
        Group {
            if queue.jobs.isEmpty && queue.notes.isEmpty {
                EmptyDropView(chooseFiles: { isImporting = true })
            } else {
                NavigationSplitView {
                    List(selection: $queue.selection) {
                        if !queue.jobs.isEmpty {
                            Section("Queue") {
                                ForEach(queue.jobs) { job in
                                    JobRow(job: job)
                                        .tag(SidebarItem.job(job.id))
                                        .contextMenu { JobMenu(job: job) }
                                }
                            }
                        }
                        if !queue.notes.isEmpty {
                            Section("Notes") {
                                ForEach(queue.notes) { note in
                                    NoteRow(note: note)
                                        .tag(SidebarItem.note(note.id))
                                        .contextMenu { NoteMenu(note: note) }
                                }
                            }
                        }
                    }
                    .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 380)
                } detail: {
                    if let job = queue.selectedJob {
                        JobDetailView(job: job).id(job.id)
                    } else if let note = queue.selectedNote {
                        NoteDetailView(note: note).id(note.id)
                    } else {
                        NoSelectionView(chooseFiles: { isImporting = true })
                    }
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            queue.add(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.tint, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.audio, .audiovisualContent], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { queue.add(urls) }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Voice Notes…", systemImage: "plus") { isImporting = true }
                    .help("Add voice notes (or drop them anywhere in the window)")
            }
        }
        .task(id: folder) { await queue.refreshLibrary() }
    }
}

struct EmptyDropView: View {
    @Environment(TranscriptionQueue.self) private var queue
    let chooseFiles: () -> Void
    @AppStorage(Prefs.folderKey) private var folder = Prefs.defaultFolder.path
    @AppStorage(Prefs.formatKey) private var format = OutputFormat.markdown.rawValue

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("Drop voice notes here")
                .font(.title2.weight(.semibold))
            Text("m4a, mp3, wav, aiff and more · saved as \(format == "txt" ? "plain text" : "Markdown") to \(abbreviated(folder))")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Files…", action: chooseFiles)
                .controlSize(.large)
                .padding(.top, 4)
            if !queue.hasAPIKey {
                SettingsLink {
                    Label("Add your OpenAI API key in Settings", systemImage: "key")
                }
                .buttonStyle(.link)
                .padding(.top, 8)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(.quaternary)
                .padding(18)
        }
    }
}

/// Detail pane when nothing is selected: a reminder that the whole window is a drop target.
struct NoSelectionView: View {
    @Environment(TranscriptionQueue.self) private var queue
    let chooseFiles: () -> Void
    @AppStorage(Prefs.folderKey) private var folder = Prefs.defaultFolder.path

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tint)
            Text("Drop voice notes to transcribe").font(.headline)
            Text("\(queue.notes.count) \(queue.notes.count == 1 ? "note" : "notes") in \(abbreviated(folder))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: chooseFiles).padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

func abbreviated(_ path: String) -> String {
    (path as NSString).abbreviatingWithTildeInPath
}
