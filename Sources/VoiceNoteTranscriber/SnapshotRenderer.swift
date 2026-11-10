#if DEBUG
import AppKit
import SwiftUI
import TranscriberCore

/// Debug-only: renders the main views with made-up sample notes to PNG files, in light and dark mode,
/// for design review and the README screenshots. It never reads your Keychain or your notes folder.
///
///   ./scripts/render-screenshots.sh     (builds, then runs: VoiceNoteTranscriber --render-snapshots docs/images)
@MainActor
enum SnapshotRenderer {
    static let isActive = CommandLine.arguments.contains("--render-snapshots")

    static func run(outputDirectory: String) {
        Task {
            let out = URL(fileURLWithPath: outputDirectory, isDirectory: true)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let samples = FileManager.default.temporaryDirectory.appending(path: "vnt-snapshots-\(UUID().uuidString)")
            let queue = TranscriptionQueue.shared
            fill(queue, samplesIn: samples)

            let appearances: [(String, NSAppearance)] = [("light", NSAppearance(named: .aqua)!), ("dark", NSAppearance(named: .darkAqua)!)]
            for (name, appearance) in appearances {
                await render(MainWindowMock(queue: queue), appearance, NSSize(width: 900, height: 580),
                             out.appending(path: "note-\(name).png"))
                await render(EmptyDropView(chooseFiles: {}).environment(queue), appearance, NSSize(width: 640, height: 420),
                             out.appending(path: "drop-\(name).png"))
                await render(SettingsView().environment(queue), appearance, NSSize(width: 580, height: 740),
                             out.appending(path: "settings-\(name).png"))
            }
            try? FileManager.default.removeItem(at: samples)
            print("Snapshots written to \(out.path)")
            exit(0)
        }
    }

    /// Sample notes written to a temporary folder and read back through the real library code, plus one job in progress.
    private static func fill(_ queue: TranscriptionQueue, samplesIn folder: URL) {
        let now = Date(timeIntervalSince1970: 1_794_327_120) // 10 Nov 2026, 16:12
        let samples: [(title: String, text: String, duration: TimeInterval, hoursAgo: Double)] = [
            ("Opening scene for the lighthouse chapter", """
            So the opening should start with her already on the stairs, not arriving. The reader comes in mid-climb, and the first thing she notices is that the lamp is [inaudible], which tells you something has gone wrong before anyone says a word.

            Then the keeper's log. I keep coming back to the idea that the log is written in two hands, and the second hand starts on the night of the storm.

            Other speaker: Sorry, is this the way to the harbour?

            Yes, straight down. Anyway, the second hand is neater than the first, which is the [inaudible] detail I want to hold back until chapter three.
            """, 1489, 0),
            ("Ending should mirror the first chapter", "Sample text.", 312, 25.5),
            ("Names for the keeper", "Sample text.", 95, 76.5),
            ("What the storm sounds like from inside", "Sample text.", 723, 153),
            ("Research list for the harbour town", "Sample text.", 418, 214),
        ]
        for sample in samples {
            let metadata = NoteMetadata(recordedAt: now.addingTimeInterval(-sample.hoursAgo * 3_600),
                                        duration: sample.duration, sourceFileName: "New Recording.m4a", model: "gpt-audio-1.5")
            _ = try? NoteWriter.write(transcript: sample.text, title: sample.title, metadata: metadata, format: .markdown, to: folder)
        }
        queue.notes = NoteLibrary.load(from: folder)
        let job = Job(source: URL(fileURLWithPath: "/tmp/Canal walk.m4a"))
        job.state = .transcribing(part: 3, of: 7)
        queue.jobs = [job]
        queue.selection = queue.notes.first.map { .note($0.id) }
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    private static func render<V: View>(_ view: V, _ appearance: NSAppearance, _ size: NSSize, _ url: URL) async {
        let hosting = NSHostingView(rootView: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        hosting.appearance = appearance
        let window = KeyWindow(contentRect: NSRect(x: -6000, y: -6000, width: size.width, height: size.height),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(600))
        hosting.layoutSubtreeIfNeeded()
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        if let png = framed(rep, dark: appearance.name == .darkAqua) {
            try? png.write(to: url)
        }
    }

    /// Rounds the corners and adds a hairline border and a soft shadow on a transparent canvas,
    /// like a window on the desktop.
    private static func framed(_ rep: NSBitmapImageRep, dark: Bool) -> Data? {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        let scale = CGFloat(w) / rep.size.width
        let pad = Int(36 * scale), radius = 14 * scale
        let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w + 2 * pad, pixelsHigh: h + 2 * pad,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let canvas, let image = rep.cgImage else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
        let ctx = NSGraphicsContext.current!.cgContext
        let rect = CGRect(x: pad, y: pad, width: w, height: h)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale,
                      color: NSColor.black.withAlphaComponent(dark ? 0.45 : 0.22).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.setStrokeColor(NSColor(white: dark ? 1 : 0, alpha: dark ? 0.18 : 0.12).cgColor)
        ctx.setLineWidth(1 * scale)
        ctx.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        return canvas.representation(using: .png, properties: [:])
    }
}

/// The main window as it looks with a note selected. The real sidebar is Liquid Glass, which an off-screen
/// render can't capture, so its rows (the real `JobRow` and `NoteRow`) are laid out on a plain panel instead.
private struct MainWindowMock: View {
    let queue: TranscriptionQueue

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 280)
            VStack(spacing: 0) {
                HStack {
                    Text("Voice Note Transcriber").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "plus").font(.title3).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .frame(height: 52)
                Divider()
                if let note = queue.selectedNote {
                    NoteDetailView(note: note)
                }
            }
        }
        .environment(queue)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                         Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) {
                    Circle().fill($0).frame(width: 12, height: 12)
                }
            }
            .padding(.leading, 6)
            .padding(.top, 6)
            .padding(.bottom, 22)
            header("Queue")
            ForEach(queue.jobs) { row(JobRow(job: $0), selected: false) }
            header("Notes").padding(.top, 12)
            ForEach(queue.notes) { note in
                row(NoteRow(note: note), selected: queue.selection == .note(note.id))
            }
            Spacer()
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.primary.opacity(0.045))
                .strokeBorder(Color.primary.opacity(0.08))
        }
        .padding(8)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 2)
    }

    private func row(_ content: some View, selected: Bool) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.primary.opacity(0.09) : .clear))
    }
}
#endif
