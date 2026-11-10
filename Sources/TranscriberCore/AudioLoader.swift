import AVFoundation
import Foundation

/// Decoded audio: 16 kHz, mono, 16-bit samples.
public struct LoadedAudio: Sendable {
    public let samples: [Int16]
    public let sampleRate: Int
    /// When the recording was made, from the file's own metadata if present.
    public let recordedAt: Date?

    public var duration: TimeInterval { Double(samples.count) / Double(sampleRate) }
}

public enum AudioLoaderError: LocalizedError {
    case noAudioTrack
    case unreadable(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .noAudioTrack: "This file has no audio in it."
        case .unreadable(let reason): "Couldn't read the audio: \(reason)"
        case .empty: "The audio file is empty."
        }
    }
}

public enum AudioLoader {
    public static let sampleRate = 16_000

    /// Decodes anything AVFoundation can read (m4a, mp3, wav, aiff, caf, aac, the audio of mp4/mov…)
    /// to 16 kHz mono 16-bit PCM — plenty for speech, and small enough to upload.
    public static func load(_ url: URL) async throws -> LoadedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioLoaderError.noAudioTrack
        }
        let recordedAt = await recordingDate(of: asset, at: url)
        let samples = try await Task.detached(priority: .userInitiated) {
            try decode(asset: asset, track: track)
        }.value
        guard !samples.isEmpty else { throw AudioLoaderError.empty }
        return LoadedAudio(samples: samples, sampleRate: sampleRate, recordedAt: recordedAt)
    }

    private static func decode(asset: AVAsset, track: AVAssetTrack) throws -> [Int16] {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch {
            throw AudioLoaderError.unreadable(error.localizedDescription)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw AudioLoaderError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }

        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: length / 2))
            samples.withUnsafeMutableBufferPointer { all in
                let destination = UnsafeMutableRawPointer(all.baseAddress! + start)
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: destination)
            }
        }
        if reader.status == .failed {
            throw AudioLoaderError.unreadable(reader.error?.localizedDescription ?? "unknown error")
        }
        return samples
    }

    /// The date embedded in the recording (iPhone Voice Memos set this), falling back to the file's creation date.
    /// Note: an AirDropped file's own creation date is when it arrived, not when it was recorded.
    static func recordingDate(of asset: AVURLAsset, at url: URL) async -> Date? {
        if let item = try? await asset.load(.creationDate),
           let date = try? await item.load(.dateValue) {
            return date
        }
        return try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }
}
