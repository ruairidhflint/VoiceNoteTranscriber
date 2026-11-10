// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceNoteTranscriber",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything that isn't UI: audio decoding, chunking, OpenAI calls, note writing, Keychain.
        .target(name: "TranscriberCore"),
        // The SwiftUI app. Packaged into a .app bundle by install.sh.
        .executableTarget(name: "VoiceNoteTranscriber", dependencies: ["TranscriberCore"]),
        // Command-line twin of the app, for testing the pipeline on real files.
        .executableTarget(name: "transcriber-cli", dependencies: ["TranscriberCore"]),
        .testTarget(name: "TranscriberCoreTests", dependencies: ["TranscriberCore"]),
    ]
)
