import Foundation

public struct PipelineSettings: Sendable {
    public var apiKey: String
    public var model: TranscriptionModel
    public var prompt: String
    public var outputFolder: URL
    public var format: OutputFormat
    /// For gpt-transcribe: how unsure it must be of a word before the word becomes [inaudible].
    public var strictness: InaudibleStrictness

    public init(
        apiKey: String, model: TranscriptionModel, prompt: String, outputFolder: URL, format: OutputFormat,
        strictness: InaudibleStrictness = .balanced
    ) {
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.outputFolder = outputFolder
        self.format = format
        self.strictness = strictness
    }
}

public enum PipelineStage: Sendable, Equatable {
    case decoding
    case transcribing(part: Int, of: Int)
    case titling
    case saving
}

public struct PipelineResult: Sendable {
    public let transcript: String
    public let title: String
    public let outputURL: URL
    public let metadata: NoteMetadata
    /// Set when the AI title failed and the file name was used instead.
    public let titleWarning: String?
}

/// Audio file in, saved note out: decode → split at pauses → transcribe each part → join → title → save.
public enum TranscriptionPipeline {
    public static func run(
        source: URL,
        settings: PipelineSettings,
        progress: @Sendable (PipelineStage) async -> Void
    ) async throws -> PipelineResult {
        await progress(.decoding)
        let audio = try await AudioLoader.load(source)
        let ranges = await Task.detached(priority: .userInitiated) {
            Chunker.split(audio.samples, sampleRate: audio.sampleRate)
        }.value

        let client = OpenAIClient(apiKey: settings.apiKey)
        var parts: [String] = []
        for (index, range) in ranges.enumerated() {
            try Task.checkCancellation()
            await progress(.transcribing(part: index + 1, of: ranges.count))
            let wav = WAV.encode(audio.samples[range], sampleRate: audio.sampleRate)
            parts.append(try await client.transcribe(
                wav: wav, model: settings.model, prompt: settings.prompt, strictness: settings.strictness,
                part: index + 1, of: ranges.count))
        }
        let transcript = Stitcher.join(parts)

        let fallbackTitle = source.deletingPathExtension().lastPathComponent
        var title = fallbackTitle
        var titleWarning: String?
        if transcript != DefaultPrompt.noSpeech {
            await progress(.titling)
            do {
                title = try await client.title(for: transcript)
            } catch {
                titleWarning = "Couldn't write a title (\(error.localizedDescription)), so the audio file's name was used."
            }
        }

        await progress(.saving)
        let metadata = NoteMetadata(
            recordedAt: audio.recordedAt ?? Date(),
            duration: audio.duration,
            sourceFileName: source.lastPathComponent,
            model: settings.model.rawValue)
        let url = try NoteWriter.write(
            transcript: transcript, title: title, metadata: metadata, format: settings.format, to: settings.outputFolder)
        return PipelineResult(
            transcript: transcript, title: NoteWriter.sanitizeTitle(title), outputURL: url,
            metadata: metadata, titleWarning: titleWarning)
    }
}
