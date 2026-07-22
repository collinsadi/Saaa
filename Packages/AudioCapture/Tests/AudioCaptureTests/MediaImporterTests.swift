import Foundation
import Testing
@testable import AudioCapture

@Suite struct MediaImporterTests {

    // MARK: - Fixtures: hand-built PCM WAVs (real headers, known content)

    private func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeWAV(
        to url: URL, channels: Int, seconds: Double, sampleRate: Int = 16_000
    ) throws {
        let frames = Int(seconds * Double(sampleRate))
        var samples: [Int16] = []
        samples.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            let value = Int16((frame % 80) * 300 - 12_000)
            for channel in 0..<channels {
                samples.append(channel == 0 ? value : value / 2)
            }
        }
        var data = Data()
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataSize = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1) // PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate * channels * 2))
        append16(UInt16(channels * 2))
        append16(16)
        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(dataSize))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        try data.write(to: url)
    }

    // MARK: - Tests

    @Test func monoImportsAsSingleUnattributedLane() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("mono.wav")
        try writeWAV(to: source, channels: 1, seconds: 1.0)

        let imported = try await MediaImporter.extract(
            from: source, into: dir.appendingPathComponent("out"))
        #expect(imported.micWAV == nil)
        #expect(imported.sourceChannels == 1)
        #expect(abs(imported.duration - 1.0) < 0.1)
        #expect(FileManager.default.fileExists(atPath: imported.systemWAV.path))
    }

    @Test func stereoSplitsIntoSeparatedLanes() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("stereo.wav")
        try writeWAV(to: source, channels: 2, seconds: 1.0)

        let imported = try await MediaImporter.extract(
            from: source, into: dir.appendingPathComponent("out"))
        let micWAV = try #require(imported.micWAV)
        #expect(imported.sourceChannels == 2)
        #expect(abs(imported.duration - 1.0) < 0.1)
        // Both lanes carry the full duration and differ in content
        // (left is the louder channel in the fixture).
        let micData = try Data(contentsOf: micWAV)
        let systemData = try Data(contentsOf: imported.systemWAV)
        #expect(abs(micData.count - systemData.count) < 64)
        #expect(micData != systemData)
    }

    @Test func unsupportedExtensionThrows() async {
        await #expect(throws: MediaImportError.unsupportedType) {
            _ = try await MediaImporter.extract(
                from: URL(filePath: "/tmp/notes.txt"),
                into: FileManager.default.temporaryDirectory)
        }
    }

    @Test func garbageFileThrows() async throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("junk.wav")
        try Data(repeating: 0x5A, count: 2_048).write(to: source)

        await #expect(throws: MediaImportError.self) {
            _ = try await MediaImporter.extract(
                from: source, into: dir.appendingPathComponent("out"))
        }
    }

    @Test func expandFiltersAndOpensFolders() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeWAV(to: dir.appendingPathComponent("b.wav"), channels: 1, seconds: 0.1)
        try writeWAV(to: dir.appendingPathComponent("a.wav"), channels: 1, seconds: 0.1)
        try Data().write(to: dir.appendingPathComponent("notes.txt"))

        let direct = MediaImporter.expand([
            dir.appendingPathComponent("a.wav"),
            dir.appendingPathComponent("notes.txt"),
        ])
        #expect(direct.map(\.lastPathComponent) == ["a.wav"])

        let folder = MediaImporter.expand([dir])
        #expect(folder.map(\.lastPathComponent) == ["a.wav", "b.wav"])
    }
}
