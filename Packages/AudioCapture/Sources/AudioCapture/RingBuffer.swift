import Synchronization

/// A lock-free single-producer / single-consumer ring buffer of `Float32`
/// samples.
///
/// The producer is the real-time Core Audio IO callback: `write(_:count:)`
/// performs no allocation, no locking, and no Swift reference-counting traffic
/// beyond the already-retained callback capture. The consumer is a background
/// drain task that resamples and persists.
///
/// Overrun policy: when the buffer is full, incoming samples are dropped and
/// counted — the real-time thread must never block or grow storage.
public final class RingBuffer: @unchecked Sendable {

    private let storage: UnsafeMutablePointer<Float32>
    private let capacity: Int
    private let mask: Int

    /// Total samples ever written (monotonic). Producer-written, release order.
    private let head = Atomic<Int>(0)
    /// Total samples ever read (monotonic). Consumer-written, release order.
    private let tail = Atomic<Int>(0)
    /// Samples dropped because the buffer was full.
    private let dropped = Atomic<Int>(0)

    /// Creates a buffer holding `minimumCapacity` samples, rounded up to the
    /// next power of two. For 48 kHz stereo float, 1 << 19 (524 288 samples)
    /// buys ~5.4 s of headroom per channel pair.
    public init(minimumCapacity: Int) {
        var cap = 1
        while cap < minimumCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        storage = .allocate(capacity: cap)
        storage.initialize(repeating: 0, count: cap)
    }

    deinit {
        storage.deallocate()
    }

    /// Number of samples currently readable.
    public var count: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .relaxed)
    }

    /// Samples dropped so far due to overrun.
    public var droppedSamples: Int {
        dropped.load(ordering: .relaxed)
    }

    /// Producer side — real-time safe. Copies up to `count` samples from
    /// `samples`; returns the number actually written (the rest are dropped
    /// and counted).
    ///
    /// `frameAlign` (e.g. the interleaved channel count) guarantees that an
    /// overrun truncation never commits a partial frame, which would flip
    /// channel phase for all subsequent content.
    @discardableResult
    public func write(_ samples: UnsafePointer<Float32>, count: Int, frameAlign: Int = 1) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        let n = min(count, free) / frameAlign * frameAlign
        if n > 0 {
            let start = h & mask
            let firstRun = min(n, capacity - start)
            (storage + start).update(from: samples, count: firstRun)
            if n > firstRun {
                storage.update(from: samples + firstRun, count: n - firstRun)
            }
            head.store(h + n, ordering: .releasing)
        }
        if n < count {
            dropped.wrappingAdd(count - n, ordering: .relaxed)
        }
        return n
    }

    /// Consumer side. Copies up to `count` samples into `buffer`; returns the
    /// number actually read.
    @discardableResult
    public func read(into buffer: UnsafeMutablePointer<Float32>, count: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let available = h - t
        let n = min(count, available)
        if n > 0 {
            let start = t & mask
            let firstRun = min(n, capacity - start)
            buffer.update(from: storage + start, count: firstRun)
            if n > firstRun {
                (buffer + firstRun).update(from: storage, count: n - firstRun)
            }
            tail.store(t + n, ordering: .releasing)
        }
        return n
    }
}
