import Foundation

public enum TranscriptionModel: String, CaseIterable, Identifiable, Sendable {
    /// General audio model: hears the audio and follows the prompt, including the never-guess rule.
    case gptAudio = "gpt-audio-1.5"
    /// Dedicated speech-to-text: most accurate, but takes no instructions, so it won't mark [inaudible].
    case gptTranscribe = "gpt-transcribe"

    public var id: String { rawValue }
    public var summary: String {
        switch self {
        case .gptAudio: "Follows the prompt below, including the never-guess [inaudible] rule."
        case .gptTranscribe: "OpenAI's dedicated transcriber. Very accurate, but it ignores instructions, so it won't mark [inaudible] and the prompt below isn't used."
        }
    }
}

public enum OpenAIError: LocalizedError, Equatable {
    case badKey
    case http(Int, String)
    case refused(String)
    case unexpectedResponse

    public var errorDescription: String? {
        switch self {
        case .badKey: "OpenAI rejected the API key. Check it in Settings."
        case .http(let status, let message): "OpenAI error \(status): \(message)"
        case .refused(let reason): "The model declined: \(reason)"
        case .unexpectedResponse: "OpenAI sent a response the app didn't understand."
        }
    }
}

public struct OpenAIClient: Sendable {
    /// Writes the short file-name title. Swap here if it's ever retired; failures fall back to the audio file's name.
    public static let titleModel = "gpt-5-mini"
    static let baseURL = URL(string: "https://api.openai.com/v1/")!

    private let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: Transcription

    public func transcribe(wav: Data, model: TranscriptionModel, prompt: String, part: Int, of total: Int) async throws -> String {
        switch model {
        case .gptAudio: try await transcribeWithChat(wav: wav, model: model.rawValue, prompt: prompt, part: part, of: total)
        case .gptTranscribe: try await transcribeWithSpeechToText(wav: wav, model: model.rawValue)
        }
    }

    private func transcribeWithChat(wav: Data, model: String, prompt: String, part: Int, of total: Int) async throws -> String {
        let instruction = total > 1
            ? "Transcribe this recording. It is part \(part) of \(total) of one longer voice note, split at a pause."
            : "Transcribe this recording."
        let audio = wav.base64EncodedString()
        func body(withAudioOutput: Bool) -> [String: Any] {
            var body: [String: Any] = [
                "model": model,
                "modalities": withAudioOutput ? ["text", "audio"] : ["text"],
                "messages": [
                    ["role": "system", "content": prompt],
                    ["role": "user", "content": [
                        ["type": "text", "text": instruction],
                        ["type": "input_audio", "input_audio": ["data": audio, "format": "wav"]],
                    ]],
                ],
            ]
            if withAudioOutput { body["audio"] = ["voice": "alloy", "format": "wav"] }
            return body
        }
        do {
            return try Self.messageText(try await postJSON("chat/completions", body(withAudioOutput: false)))
        } catch OpenAIError.http(400, let message) where message.localizedCaseInsensitiveContains("modalit") {
            // OpenAI's docs only show audio models with audio output switched on; fall back to that if text-only is refused.
            return try Self.messageText(try await postJSON("chat/completions", body(withAudioOutput: true)))
        }
    }

    private func transcribeWithSpeechToText(wav: Data, model: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        field("response_format", "json")
        field("prompt", "A personal voice note dictated in British English.")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.baseURL.appending(path: "audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let text = try await send(request)["text"] as? String else { throw OpenAIError.unexpectedResponse }
        return text
    }

    // MARK: Title

    public func title(for transcript: String) async throws -> String {
        let body: [String: Any] = [
            "model": Self.titleModel,
            "messages": [
                ["role": "system", "content": "You name voice notes. Reply with a single title of 3 to 8 words that captures the main idea of the transcript, using the speaker's own terms where possible. British English. No quotation marks, no full stop, no prefix such as 'Title:'."],
                ["role": "user", "content": String(transcript.prefix(12_000))],
            ],
        ]
        let text = try Self.messageText(try await postJSON("chat/completions", body))
        return text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    // MARK: HTTP

    private func postJSON(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    /// Sends with up to two retries for rate limits, server errors and dropped connections.
    private func send(_ request: URLRequest) async throws -> [String: Any] {
        var request = request
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch let error as URLError where attempt < maxAttempts && Self.isTransient(error) {
                try await Task.sleep(for: .seconds(Self.backoff(attempt)))
                continue
            }
            let (data, response) = result
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (200..<300).contains(status), let json { return json }

            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? HTTPURLResponse.localizedString(forStatusCode: status)
            if status == 401 { throw OpenAIError.badKey }
            let retryable = (status == 429 && !message.localizedCaseInsensitiveContains("quota")) || status >= 500
            if retryable && attempt < maxAttempts {
                let wait = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Self.backoff(attempt)
                try await Task.sleep(for: .seconds(min(wait, 30)))
                continue
            }
            throw OpenAIError.http(status, message)
        }
        throw OpenAIError.unexpectedResponse
    }

    static func messageText(_ json: [String: Any]) throws -> String {
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else {
            throw OpenAIError.unexpectedResponse
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty { throw OpenAIError.refused(refusal) }
        if let content = message["content"] as? String, !content.isEmpty { return content }
        if let transcript = (message["audio"] as? [String: Any])?["transcript"] as? String { return transcript }
        throw OpenAIError.unexpectedResponse
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost].contains(error.code)
    }

    private static func backoff(_ attempt: Int) -> Double { attempt == 1 ? 2 : 8 }
}
