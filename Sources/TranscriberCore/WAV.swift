import Foundation

public enum WAV {
    /// A plain 16-bit mono PCM WAV file.
    public static func encode(_ samples: ArraySlice<Int16>, sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func ascii(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF"); u32(36 + dataSize); ascii("WAVE")
        ascii("fmt "); u32(16)
        u16(1)                          // PCM
        u16(1)                          // mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2))     // byte rate
        u16(2)                          // block align
        u16(16)                         // bits per sample
        ascii("data"); u32(dataSize)
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { u16(UInt16(bitPattern: sample)) }
        }
        return data
    }
}
