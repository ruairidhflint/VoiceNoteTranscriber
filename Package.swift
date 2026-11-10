// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "VoiceNoteTranscriber",
    platforms: [.macOS(.v26)],
    targets: [
        // Everything that isn't UI: audio decoding, chunking, OpenAI calls, note writing, Keychain.
        .target(name: "TranscriberCore"),
        .testTarget(name: "TranscriberCoreTests", dependencies: ["TranscriberCore"]),
    ]
)
