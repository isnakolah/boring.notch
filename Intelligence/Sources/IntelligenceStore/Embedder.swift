import Foundation
import NaturalLanguage

/// Turns text into a vector, on this Mac, with nothing downloaded at call time if
/// it can be avoided.
///
/// Three tiers, in order, because the good one is not always there:
///
///  1. `NLContextualEmbedding` (macOS 14+) — a real transformer, multilingual,
///     but its weights are an on-demand asset. `requestAssets` may need the
///     network the first time, so it is only ever called from `prepare()`, which
///     runs during the two-minute pre-roll and never on a question.
///  2. `NLEmbedding.sentenceEmbedding(for: .english)` — ships with the OS, no
///     download, English only. Good enough to rank a few hundred notes.
///  3. Nothing. Vectors are left NULL and search falls back to BM25 alone.
///
/// Tier 3 is a first-class outcome, not an error path. A copilot that refuses to
/// answer because an embedding asset did not download is strictly worse than one
/// that ranks its knowledge lexically, and lexical search over a personal corpus
/// of hand-written notes is genuinely good — the user's own words are usually in
/// the question.
public actor Embedder {
    public enum Backend: String, Sendable {
        case contextual
        case sentence
        case none
    }

    private var contextual: NLContextualEmbedding?
    private var sentence: NLEmbedding?
    private var prepared = false

    public private(set) var backend: Backend = .none

    public init() {}

    /// Which weights produced the stored vectors.
    ///
    /// Recorded alongside them because a vector from one backend and a vector from
    /// another are not comparable — cosine between them is noise, not a weak
    /// match. When this changes, `CallaStore` drops every stored vector and
    /// re-embeds rather than quietly ranking on garbage.
    public var revision: String {
        switch backend {
        case .contextual: "contextual-v\(contextual?.revision ?? 0)-d\(contextual?.dimension ?? 0)"
        case .sentence: "sentence-en-d\(sentence?.dimension ?? 0)"
        case .none: "none"
        }
    }

    /// Loads the best backend available. Safe to call more than once; only the
    /// first does work.
    ///
    /// Deliberately never throws. Every failure here degrades to a worse tier, and
    /// the caller has no useful way to react to "the asset server was busy".
    public func prepare() async {
        guard !prepared else { return }
        prepared = true

        if let model = NLContextualEmbedding(language: .english) {
            if model.hasAvailableAssets {
                if (try? model.load()) != nil {
                    contextual = model
                    backend = .contextual
                    return
                }
            } else {
                let downloaded = await withCheckedContinuation { continuation in
                    model.requestAssets { result, _ in
                        continuation.resume(returning: result == .available)
                    }
                }
                if downloaded, (try? model.load()) != nil {
                    contextual = model
                    backend = .contextual
                    return
                }
            }
        }

        if let model = NLEmbedding.sentenceEmbedding(for: .english) {
            sentence = model
            backend = .sentence
            return
        }

        backend = .none
    }

    /// A unit-length vector, or nil when there is no backend or the text is empty.
    ///
    /// Normalised on the way out so ranking is a dot product rather than a cosine
    /// with two square roots per candidate — the search scans every chunk, so the
    /// per-comparison cost is the one that matters.
    public func embed(_ text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let contextual {
            guard let result = try? contextual.embeddingResult(for: trimmed, language: .english) else { return nil }
            // Token vectors, mean-pooled: `NLContextualEmbedding` is per-token and
            // has no sentence head of its own.
            var sum = [Double](repeating: 0, count: contextual.dimension)
            var count = 0
            result.enumerateTokenVectors(in: trimmed.startIndex ..< trimmed.endIndex) { vector, _ in
                for (index, value) in vector.enumerated() where index < sum.count {
                    sum[index] += value
                }
                count += 1
                return true
            }
            guard count > 0 else { return nil }
            return normalise(sum.map { Float($0 / Double(count)) })
        }

        if let sentence {
            let vector = sentence.vector(for: trimmed)
            // sentenceEmbedding answers nil for text it cannot place at all —
            // a chunk of pure punctuation, say. Not an error, just no vector.
            guard let vector else { return nil }
            return normalise(vector.map(Float.init))
        }

        return nil
    }

    private func normalise(_ vector: [Float]) -> [Float]? {
        var total: Float = 0
        for value in vector { total += value * value }
        let magnitude = total.squareRoot()
        guard magnitude > 0, magnitude.isFinite else { return nil }
        return vector.map { $0 / magnitude }
    }
}

/// Vectors on disk, as little-endian float32.
///
/// Explicit byte handling rather than `withUnsafeBytes` over the array: the file
/// is read by three processes and, one day, possibly a different architecture, and
/// a blob whose layout depends on the host's endianness is a bug that only ever
/// shows up somewhere inconvenient.
enum VectorBlob {
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func decode(_ data: Data) -> [Float] {
        let count = data.count / 4
        guard count > 0 else { return [] }
        var vector = [Float]()
        vector.reserveCapacity(count)
        for index in 0 ..< count {
            let start = data.startIndex + index * 4
            let bits = data[start ..< start + 4].reduce(into: UInt32(0)) { result, byte in
                result = (result >> 8) | (UInt32(byte) << 24)
            }
            vector.append(Float(bitPattern: bits))
        }
        return vector
    }

    /// Both sides are unit-length, so this is the cosine. Mismatched lengths score
    /// zero rather than crashing — that is the "the backend changed under us" case,
    /// and the re-embed will fix it.
    static func similarity(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var total: Float = 0
        for index in 0 ..< lhs.count { total += lhs[index] * rhs[index] }
        return Double(total)
    }
}
