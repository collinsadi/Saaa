import Core
import Foundation
import NaturalLanguage

/// On-device transcript embeddings for the hybrid retrieval and correction
/// memory (issue #7). Uses Apple's bundled sentence embedding — no network,
/// no assets to download. Everything degrades to nil when the model is
/// unavailable; retrieval then runs on keyword signals alone.
public enum TranscriptEmbedder {

    /// Samples the transcript and averages sentence vectors into one call
    /// vector.
    public static func vector(for transcript: Transcript, maxSegments: Int = 24) -> [Double]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        let texts = sample(
            transcript.segments.map(\.text).filter { $0.count >= 12 },
            limit: maxSegments)
        let vectors = texts.compactMap { embedding.vector(for: $0) }
        return average(vectors)
    }

    /// Evenly spaced sample preserving order — a long call should be
    /// represented end to end, not just its opening minutes.
    static func sample(_ texts: [String], limit: Int) -> [String] {
        guard texts.count > limit else { return texts }
        let stride = Double(texts.count) / Double(limit)
        return (0..<limit).map { texts[Int(Double($0) * stride)] }
    }

    /// Component-wise mean; nil for an empty or ragged input.
    public static func average(_ vectors: [[Double]]) -> [Double]? {
        guard let first = vectors.first,
              vectors.allSatisfy({ $0.count == first.count }) else { return nil }
        var sum = [Double](repeating: 0, count: first.count)
        for vector in vectors {
            for index in vector.indices { sum[index] += vector[index] }
        }
        return sum.map { $0 / Double(vectors.count) }
    }

    /// Cosine similarity; 0 for mismatched or zero-magnitude input.
    public static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, magA = 0.0, magB = 0.0
        for index in a.indices {
            dot += a[index] * b[index]
            magA += a[index] * a[index]
            magB += b[index] * b[index]
        }
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA.squareRoot() * magB.squareRoot())
    }
}
