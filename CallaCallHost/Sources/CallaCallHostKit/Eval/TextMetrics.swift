import Foundation

/// Word- and character-error rates, plus the normalisation both rest on.
///
/// Kept separate from the corpus loader so the arithmetic can be tested with
/// hand-written strings and no files on disk.
public enum TextMetrics {
    /// Lowercase, strip punctuation, collapse whitespace, spell out nothing.
    ///
    /// The two transcripts being compared come from the same family of models
    /// through different paths, so they disagree about punctuation and casing on
    /// almost every line. Counting that as error would drown the differences that
    /// actually matter — a wrong word, a dropped clause.
    public static func normalize(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "'" {
                current.append(character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// Levenshtein distance over any equatable sequence, in O(min(n, m)) space.
    ///
    /// Two rows rather than a full matrix: an hour of call is tens of thousands
    /// of words per leg, and the full matrix would be gigabytes.
    public static func editDistance<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        // Iterate over the longer one so the rows stay as short as possible.
        let (long, short) = lhs.count >= rhs.count ? (lhs, rhs) : (rhs, lhs)

        var previous = Array(0...short.count)
        var current = [Int](repeating: 0, count: short.count + 1)
        for (i, longElement) in long.enumerated() {
            current[0] = i + 1
            for (j, shortElement) in short.enumerated() {
                let substitution = previous[j] + (longElement == shortElement ? 0 : 1)
                current[j + 1] = min(substitution, previous[j + 1] + 1, current[j] + 1)
            }
            swap(&previous, &current)
        }
        return previous[short.count]
    }

    /// Word error rate against a reference. `nil` when the reference is empty —
    /// dividing by zero would report a perfect or infinite score for a call that
    /// simply has no reference to score against.
    public static func wordErrorRate(hypothesis: String, reference: String) -> Double? {
        let reference = normalize(reference)
        guard !reference.isEmpty else { return nil }
        return Double(editDistance(normalize(hypothesis), reference)) / Double(reference.count)
    }

    public static func characterErrorRate(hypothesis: String, reference: String) -> Double? {
        let reference = Array(normalize(reference).joined(separator: " "))
        guard !reference.isEmpty else { return nil }
        let hypothesis = Array(normalize(hypothesis).joined(separator: " "))
        return Double(editDistance(hypothesis, reference)) / Double(reference.count)
    }
}
