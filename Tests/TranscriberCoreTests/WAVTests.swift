import Foundation
import Testing
@testable import TranscriberCore

struct WAVTests {
    @Test func headerDescribes16kMonoPCM() {
        let data = WAV.encode([1, -1, 300][...], sampleRate: 16_000)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        func u32(_ at: Int) -> UInt32 { data[at..<at + 4].enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        func u16(_ at: Int) -> UInt16 { UInt16(data[at]) | UInt16(data[at + 1]) << 8 }
        #expect(u16(20) == 1)        // PCM
        #expect(u16(22) == 1)        // mono
        #expect(u32(24) == 16_000)   // sample rate
        #expect(u16(34) == 16)       // bits
        #expect(u32(40) == 6)        // data size
        #expect(data[44] == 1 && data[46] == 0xFF && data[48] == 0x2C && data[49] == 0x01)
    }
}
