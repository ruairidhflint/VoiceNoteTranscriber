import AppKit
import SwiftUI
import TranscriberCore

// MARK: - Queue (audio being transcribed)

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 10) {
            statusIcon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.name).lineLimit(1)
                Text(job.state.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        default: ProgressView().controlSize(.small)
        }
    }
}

struct JobMenu: View {
    @Environment(TranscriptionQueue.self) private var queue
    let job: Job

    var body: some View {
        if case .failed = job.state {
            Button("Retry") { queue.retry(job) }
        }
        Button("Remove from Queue") { queue.remove(job) }
            .disabled(job.state.isWorking)
    }
}

struct JobDetailView: View {
    let job: Job

    var body: some View {
        switch job.state {
        case .failed(let message): FailedView(job: job, message: message)
        case .transcribing(let part, let total) where total > 1:
            WorkingView(job: job, progress: Double(part - 1) / Double(total))
        default: WorkingView(job: job, progress: nil)
        }
    }
}

private struct WorkingView: View {
    let job: Job
    let progress: Double?

    var body: some View {
        VStack(spacing: 12) {
            if let progress {
                ProgressView(value: progress).frame(width: 260)
            } else if job.state != .queued {
                ProgressView()
            }
            Text(job.state.label).font(.headline)
            Text(job.source.lastPathComponent).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedView: View {
    @Environment(TranscriptionQueue.self) private var queue
    let job: Job
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Couldn't transcribe \(job.source.lastPathComponent)").font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 440)
            HStack {
                Button("Retry") { queue.retry(job) }.keyboardShortcut(.defaultAction)
                Button("Remove") { queue.remove(job) }
            }
            .padding(.top, 4)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Notes (saved transcripts in the output folder)

struct NoteRow: View {
    let note: SavedNote

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(note.title).lineLimit(1)
            Text([note.recordedAt.formatted(date: .abbreviated, time: .shortened), note.duration]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

struct NoteMenu: View {
    @Environment(TranscriptionQueue.self) private var queue
    let note: SavedNote

    var body: some View {
        Button("Open in Default App") { NSWorkspace.shared.open(note.url) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
        Divider()
        Button("Move to Trash") { Task { await queue.moveToTrash(note) } }
    }
}

struct NoteDetailView: View {
    @Environment(TranscriptionQueue.self) private var queue
    let note: SavedNote
    @State private var draftTitle = ""
    @State private var copied = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .help("Edit the title to rename the saved file")

            Text([note.recordedAt.formatted(date: .abbreviated, time: .shortened), note.duration, note.model]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let warning = queue.noteWarnings[note.id] {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            Divider()

            ScrollView {
                Text(highlighted(note.transcript))
                    .font(.body)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            }

            Divider()

            HStack {
                Button(copied ? "Copied" : "Copy Transcript", systemImage: copied ? "checkmark" : "doc.on.doc", action: copy)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([note.url])
                }
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(note.url) }
                    .help("Open in your default app for .\(note.format.rawValue) files")
                Spacer()
                Text(note.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .onAppear { draftTitle = note.title }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitTitle() }
        }
    }

    private func commitTitle() {
        let title = draftTitle
        Task { await queue.rename(note, to: title) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.transcript, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    /// Makes [inaudible] stand out so it's easy to spot what needs a re-listen.
    private func highlighted(_ text: String) -> AttributedString {
        var attributed = AttributedString(text)
        var searchStart = attributed.startIndex
        while let range = attributed[searchStart...].range(of: DefaultPrompt.inaudible) {
            attributed[range].foregroundColor = .orange
            attributed[range].font = .body.weight(.semibold)
            searchStart = range.upperBound
        }
        return attributed
    }
}
