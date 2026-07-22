import AVFoundation
import Foundation
import os

/// Import path (issue #3): turns an existing audio or video file into the
/// same 16 kHz mono WAV lanes the live pipeline produces. A stereo source is
/// split into separated channels (left = Me, right = Them); a mono source
/// becomes a single unattributed lane. Video containers just contribute
/// their audio track.
public enum MediaImportError: Error, Equatable {
    case unsupportedType
    case noAudioTrack
    case unreadable(String)
}

public struct ImportedAudio: Sendable {
    /// The "Me" lane; nil when the source was mono.
    public let micWAV: URL?
    /// The "Them" lane (or the only lane for mono sources).
    public let systemWAV: URL
    public let duration: TimeInterval
    public let sourceChannels: Int
}

public enum MediaImporter {

    private static let log = Logger(subsystem: "dev.collinsadi.saaa", category: "MediaImporter")

    /// Container types AVFoundation reliably decodes on macOS.
    public static let importableExtensions: Set<String> = [
        "wav", "mp3", "m4a", "aac", "aiff", "aif", "caf", "flac",
        "mp4", "mov", "m4v",
    ]

    public static func isImportable(_ url: URL) -> Bool {
        importableExtensions.contains(url.pathExtension.lowercased())
    }

    /// Expands dropped/picked URLs: folders yield their importable children
    /// (one level), files pass through the type filter.
    public static func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles])) ?? []
                result += children.filter(isImportable).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else if isImportable(url) {
                result.append(url)
            }
        }
        return result
    }

    /// Decodes the source's audio into WAV lane(s) inside `directory`.
    /// Decoding runs off the calling actor; the source file is never
    /// touched, only read.
    public static func extract(from source: URL, into directory: URL) async throws -> ImportedAudio {
        guard isImportable(source) else { throw MediaImportError.unsupportedType }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sourcePath = source.path
        let directoryPath = directory.path
        return try await Task.detached(priority: .userInitiated) {
            try await decode(sourcePath: sourcePath, directoryPath: directoryPath)
        }.value
    }

    // MARK: - Decode (worker thread)

    private static func decode(sourcePath: String, directoryPath: String) async throws -> ImportedAudio {
        let asset = AVURLAsset(url: URL(filePath: sourcePath))
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw MediaImportError.noAudioTrack
        }

        // Two output channels when the source has them (separated-lane
        // import), one otherwise. The reader downmixes anything wider.
        let sourceChannels = await channelCount(of: track)
        let laneCount = min(2, max(1, sourceChannels))

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw MediaImportError.unreadable(String(describing: error))
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: laneCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw MediaImportError.unreadable(String(describing: reader.error ?? MediaImportError.noAudioTrack))
        }

        let directory = URL(filePath: directoryPath)
        let systemWriter = try WavWriter(url: directory.appendingPathComponent("system.wav"))
        let micWriter = laneCount == 2
            ? try WavWriter(url: directory.appendingPathComponent("mic.wav"))
            : nil

        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
                let pointer else { continue }
            let sampleCount = length / MemoryLayout<Int16>.size
            pointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                let buffer = UnsafeBufferPointer(start: samples, count: sampleCount)
                if let micWriter {
                    // Interleaved stereo: even = left (Me), odd = right (Them).
                    var left: [Int16] = []
                    var right: [Int16] = []
                    left.reserveCapacity(sampleCount / 2)
                    right.reserveCapacity(sampleCount / 2)
                    for index in stride(from: 0, to: sampleCount - 1, by: 2) {
                        left.append(buffer[index])
                        right.append(buffer[index + 1])
                    }
                    try? micWriter.append(left)
                    try? systemWriter.append(right)
                } else {
                    try? systemWriter.append(Array(buffer))
                }
            }
        }
        if reader.status == .failed {
            throw MediaImportError.unreadable(String(describing: reader.error ?? MediaImportError.noAudioTrack))
        }
        try systemWriter.finish()
        try micWriter?.finish()
        let duration = systemWriter.duration
        guard duration > 0 else { throw MediaImportError.noAudioTrack }

        log.info("imported \(laneCount, privacy: .public)-lane audio, \(String(format: "%.1f", duration), privacy: .public)s")
        return ImportedAudio(
            micWAV: micWriter?.url,
            systemWAV: systemWriter.url,
            duration: duration,
            sourceChannels: sourceChannels)
    }

    private static func channelCount(of track: AVAssetTrack) async -> Int {
        let descriptions = (try? await track.load(.formatDescriptions)) ?? []
        for description in descriptions {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
                return Int(asbd.pointee.mChannelsPerFrame)
            }
        }
        return 1
    }
}
