import AppKit
import SwiftUI

@main
struct VoiceNoteTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var queue = TranscriptionQueue.shared

    var body: some Scene {
        Window("Voice Note Transcriber", id: "main") {
            ContentView()
                .environment(queue)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 860, height: 580)

        Settings {
            SettingsView()
                .environment(queue)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon or opened with Finder's "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        TranscriptionQueue.shared.add(urls)
    }

    /// Belt and braces alongside the folder watcher: re-read the library whenever you come back to the app.
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await TranscriptionQueue.shared.refreshLibrary() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    #if DEBUG
    /// Debug builds only: `--render-snapshots <dir>` renders README screenshots with sample data, then quits.
    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-snapshots"), args.indices.contains(flag + 1) else { return }
        SnapshotRenderer.run(outputDirectory: args[flag + 1])
    }
    #endif
}
