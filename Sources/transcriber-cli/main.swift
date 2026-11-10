import Foundation
import TranscriberCore

// Command-line twin of the app, for trying the pipeline on real files.
//   transcriber-cli chunks <audio>       decode + show where the recording would be split (no network)
//   transcriber-cli transcribe <audio> [--model gpt-audio-1.5|gpt-transcribe] [--out <folder>] [--txt]

let args = Array(CommandLine.arguments.dropFirst())
let usage = "usage: transcriber-cli chunks <audio> | transcribe <audio> [--model gpt-audio-1.5|gpt-transcribe] [--out <folder>] [--txt]"
guard args.count >= 2 else {
    print(usage)
    exit(2)
}
let file = URL(fileURLWithPath: args[1])

switch args[0] {
case "chunks":
    let audio = try await AudioLoader.load(file)
    print("duration: \(NoteWriter.formatDuration(audio.duration)), recorded: \(audio.recordedAt.map { "\($0)" } ?? "unknown")")
    let ranges = Chunker.split(audio.samples, sampleRate: audio.sampleRate)
    for (i, range) in ranges.enumerated() {
        let start = Double(range.lowerBound) / Double(audio.sampleRate)
        let end = Double(range.upperBound) / Double(audio.sampleRate)
        print(String(format: "part %d: %02d:%04.1f → %02d:%04.1f  (%.0fs)",
                     i + 1, Int(start) / 60, start.truncatingRemainder(dividingBy: 60),
                     Int(end) / 60, end.truncatingRemainder(dividingBy: 60), end - start))
    }

case "transcribe":
    guard let key = Keychain.read() else {
        FileHandle.standardError.write(Data("No API key in the Keychain (service \(Keychain.service), account \(Keychain.account)).\n".utf8))
        exit(1)
    }
    let modelIndex = args.firstIndex(of: "--model").map { $0 + 1 }
    let outIndex = args.firstIndex(of: "--out").map { $0 + 1 }
    let model = modelIndex.flatMap { args.indices.contains($0) ? TranscriptionModel(rawValue: args[$0]) : nil } ?? .gptAudio
    let out = outIndex.flatMap { args.indices.contains($0) ? URL(fileURLWithPath: args[$0], isDirectory: true) : nil }
        ?? FileManager.default.temporaryDirectory.appending(path: "voice-notes")
    let settings = PipelineSettings(
        apiKey: key, model: model, prompt: DefaultPrompt.text, outputFolder: out,
        format: args.contains("--txt") ? .plainText : .markdown)
    let started = Date()
    let result = try await TranscriptionPipeline.run(source: file, settings: settings) { stage in
        print("  \(stage)")
    }
    if let warning = result.titleWarning { print("warning: \(warning)") }
    let inaudible = result.transcript.components(separatedBy: DefaultPrompt.inaudible).count - 1
    print(String(format: "done in %.0fs: %d words, %d [inaudible]", Date().timeIntervalSince(started),
                 result.transcript.split(whereSeparator: \.isWhitespace).count, inaudible))
    print(result.outputURL.path)

default:
    print(usage)
    exit(2)
}
