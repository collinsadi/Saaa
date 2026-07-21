import Foundation
import Testing
@testable import AudioCapture

@Suite struct RingBufferTests {

    @Test func roundTripsSamplesInOrder() {
        let ring = RingBuffer(minimumCapacity: 16)
        let input: [Float32] = [1, 2, 3, 4, 5]
        input.withUnsafeBufferPointer { #expect(ring.write($0.baseAddress!, count: 5) == 5) }
        var out = [Float32](repeating: 0, count: 5)
        out.withUnsafeMutableBufferPointer { #expect(ring.read(into: $0.baseAddress!, count: 5) == 5) }
        #expect(out == input)
        #expect(ring.count == 0)
    }

    @Test func wrapsAroundCapacityBoundary() {
        let ring = RingBuffer(minimumCapacity: 8) // capacity 8
        var scratch = [Float32](repeating: 0, count: 8)

        // Advance the indices to 6 so the next write straddles the boundary.
        let pad = [Float32](repeating: 9, count: 6)
        pad.withUnsafeBufferPointer { _ = ring.write($0.baseAddress!, count: 6) }
        scratch.withUnsafeMutableBufferPointer { _ = ring.read(into: $0.baseAddress!, count: 6) }

        let input: [Float32] = [10, 11, 12, 13] // occupies slots 6,7,0,1
        input.withUnsafeBufferPointer { #expect(ring.write($0.baseAddress!, count: 4) == 4) }
        var out = [Float32](repeating: 0, count: 4)
        out.withUnsafeMutableBufferPointer { #expect(ring.read(into: $0.baseAddress!, count: 4) == 4) }
        #expect(out == input)
    }

    @Test func dropsOnOverrunWithoutBlocking() {
        let ring = RingBuffer(minimumCapacity: 4) // capacity 4
        let input = [Float32](repeating: 1, count: 10)
        let written = input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: 10) }
        #expect(written == 4)
        #expect(ring.droppedSamples == 6)
        #expect(ring.count == 4)
    }

    @Test func readOnEmptyReturnsZero() {
        let ring = RingBuffer(minimumCapacity: 4)
        var out = [Float32](repeating: 0, count: 4)
        let read = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
        #expect(read == 0)
    }

    /// Concurrent producer/consumer stress: every value written must be read
    /// exactly once, in order, with no corruption.
    @Test func concurrentProducerConsumerPreservesSequence() async {
        let ring = RingBuffer(minimumCapacity: 1 << 12)
        let total = 500_000

        let producer = Thread {
            var next: Float32 = 0
            var chunk = [Float32](repeating: 0, count: 311)
            var sent = 0
            while sent < total {
                let n = min(chunk.count, total - sent)
                for i in 0..<n { chunk[i] = next + Float32(i) }
                let written = chunk.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: n) }
                next += Float32(written)
                sent += written
                if written == 0 { usleep(50) }
            }
        }
        producer.start()

        var expected: Float32 = 0
        var received = 0
        var out = [Float32](repeating: 0, count: 733)
        var ordered = true
        while received < total {
            let n = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 733) }
            if n == 0 {
                try? await Task.sleep(for: .microseconds(50))
                continue
            }
            for i in 0..<n where out[i] != expected + Float32(i) { ordered = false }
            expected += Float32(n)
            received += n
        }
        // Note: droppedSamples is nonzero here by design — this producer
        // retries partial writes, and the ring counts each shortfall. The
        // real RT producer writes once per IO cycle and never retries.
        #expect(ordered)
        #expect(received == total)
    }
}
