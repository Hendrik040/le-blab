import Foundation

/// Builds a WAV container around in-memory PCM so batch uploads never touch disk.
public enum WAVEncoder {
    public static func wav(fromPCM16Mono pcm: Data, sampleRate: Int = PCMFormat.sampleRate) -> Data {
        var out = Data(capacity: 44 + pcm.count)
        func u32(_ v: UInt32) { var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var le = v.littleEndian; withUnsafeBytes(of: &le) { out.append(contentsOf: $0) } }
        let byteRate = UInt32(sampleRate * 2)
        out.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        out.append(contentsOf: Array("WAVE".utf8))
        out.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1)                 // PCM
        u16(1)                 // mono
        u32(UInt32(sampleRate))
        u32(byteRate)
        u16(2)                 // block align
        u16(16)                // bits per sample
        out.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        out.append(pcm)
        return out
    }
}
