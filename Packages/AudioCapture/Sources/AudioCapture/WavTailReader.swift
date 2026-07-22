import Foundation

/// Reads the trailing window of a LIVE 16 kHz mono Int16 WAV that is still
/// being written (issue #8 streaming path). The header may be stale between
/// checkpoints, so it is ignored entirely: PCM data is trusted from byte 44
/// to EOF, aligned to sample boundaries.
public enum WavTailReader {

    static let headerSize: UInt64 = 44

    /// The last `seconds` of audio as normalized Float samples, or nil when
    /// the file has no data yet.
    public static func tailSamples(
        of url: URL, seconds: Double, sampleRate: Int = 16_000
    ) -> [Float]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > headerSize + 1 else { return nil }

        let bytesWanted = UInt64(max(0, seconds) * Double(sampleRate)) * 2
        var start = end > headerSize + bytesWanted ? end - bytesWanted : headerSize
        start -= (start - headerSize) % 2
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), data.count >= 2 else { return nil }

        let count = data.count / 2
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let words = raw.bindMemory(to: Int16.self)
            for index in 0..<count {
                samples[index] = Float(Int16(littleEndian: words[index])) / 32_768
            }
        }
        return samples
    }
}
