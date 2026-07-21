import Foundation

/// Errors thrown by ``WavWriter``.
public enum WavWriterError: Error, Equatable {
    /// The destination file could not be created or opened.
    case cannotCreateFile(path: String)
    /// A write to the underlying file failed (e.g. disk full).
    case writeFailed
    /// The writer was used after ``WavWriter/finish()``.
    case alreadyFinished
}

/// Streams 16-bit little-endian PCM into a WAV (RIFF) file, patching the
/// header sizes on ``finish()``.
///
/// Not thread-safe by design: exactly one consumer task owns a writer.
public final class WavWriter {

    /// Fixed PCM header size: RIFF(12) + fmt(24) + data header(8).
    private static let headerSize = 44

    private let handle: FileHandle
    private let sampleRate: Int
    private var dataBytes: Int = 0
    private var finished = false

    /// The file being written.
    public let url: URL

    /// Creates the file at `url` (replacing any existing file) and writes a
    /// placeholder header for mono 16-bit PCM at `sampleRate` Hz.
    public init(url: URL, sampleRate: Int = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            throw WavWriterError.cannotCreateFile(path: url.path)
        }
        self.handle = handle
        try write(Self.header(sampleRate: sampleRate, dataBytes: 0))
    }

    /// Appends `count` samples. Real-time safety is not required here — this
    /// runs on the drain task, never the audio callback.
    public func append(_ samples: UnsafePointer<Int16>, count: Int) throws {
        guard !finished else { throw WavWriterError.alreadyFinished }
        guard count > 0 else { return }
        // WAV is little-endian; so is every supported macOS host (arm64/x86_64).
        let data = Data(bytes: samples, count: count * MemoryLayout<Int16>.size)
        try write(data)
        dataBytes += data.count
    }

    /// Appends samples from an array.
    public func append(_ samples: [Int16]) throws {
        try samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            try append(base, count: buf.count)
        }
    }

    /// Duration of audio written so far, in seconds.
    public var duration: TimeInterval {
        TimeInterval(dataBytes / 2) / TimeInterval(sampleRate)
    }

    /// Re-patches the header with the current sizes without closing, so a
    /// crash mid-recording leaves a readable file. No fsync — the threat
    /// model is app/system crash, not power loss.
    public func checkpoint() throws {
        guard !finished else { throw WavWriterError.alreadyFinished }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
            try handle.seekToEnd()
        } catch {
            // Never leave the offset inside the header — a subsequent append
            // would overwrite it and the first samples.
            _ = try? handle.seekToEnd()
            throw WavWriterError.writeFailed
        }
    }

    /// Patches the RIFF/data chunk sizes and closes the file.
    public func finish() throws {
        guard !finished else { return }
        finished = true
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: Self.header(sampleRate: sampleRate, dataBytes: dataBytes))
            try handle.synchronize()
        } catch {
            throw WavWriterError.writeFailed
        }
    }

    deinit {
        if !finished {
            try? handle.close()
        }
    }

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw WavWriterError.writeFailed
        }
    }

    /// Canonical 44-byte PCM WAV header: mono, 16-bit, `sampleRate` Hz.
    private static func header(sampleRate: Int, dataBytes: Int) -> Data {
        var d = Data(capacity: headerSize)
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataBytes)                    // RIFF chunk size
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8))
        u32(16)                                // fmt chunk size
        u16(1)                                 // PCM
        u16(1)                                 // mono
        u32(sampleRate)
        u32(sampleRate * 2)                    // byte rate (16-bit mono)
        u16(2)                                 // block align
        u16(16)                                // bits per sample
        d.append(contentsOf: Array("data".utf8))
        u32(dataBytes)
        return d
    }
}
