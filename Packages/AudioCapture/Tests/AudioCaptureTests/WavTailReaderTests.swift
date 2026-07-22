import Foundation
import Testing
@testable import AudioCapture

@Suite struct WavTailReaderTests {

    private func liveWAV(seconds: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).wav")
        let writer = try WavWriter(url: url)
        let frames = Int(seconds * 16_000)
        try writer.append((0..<frames).map { Int16(truncatingIfNeeded: $0 &* 7) })
        // No finish(): the reader must work on a mid-write file whose
        // header sizes are stale.
        try writer.checkpoint()
        return url
    }

    @Test func readsTheTrailingWindowOfALiveFile() throws {
        let url = try liveWAV(seconds: 3)
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = WavTailReader.tailSamples(of: url, seconds: 1)
        #expect(tail?.count == 16_000)
        // Values are normalized to [-1, 1).
        #expect(tail!.allSatisfy { $0 >= -1 && $0 < 1 })
    }

    @Test func shortFileReturnsEverything() throws {
        let url = try liveWAV(seconds: 0.5)
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = WavTailReader.tailSamples(of: url, seconds: 10)
        #expect(tail?.count == 8_000)
    }

    @Test func missingOrEmptyFilesReturnNil() throws {
        #expect(WavTailReader.tailSamples(
            of: URL(filePath: "/tmp/does-not-exist-\(UUID()).wav"), seconds: 1) == nil)
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).wav")
        _ = try WavWriter(url: empty) // header only, no samples
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(WavTailReader.tailSamples(of: empty, seconds: 1) == nil)
    }
}
