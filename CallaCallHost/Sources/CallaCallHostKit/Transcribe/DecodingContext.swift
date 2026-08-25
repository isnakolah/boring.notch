import Foundation

/// Builds the `initial_prompt` handed to whisper for each utterance.
///
/// The live leg decodes VAD-bounded fragments — often one or two seconds — with
/// `no_context` set, so each one is transcribed by a model that has never heard
/// this call, does not know who is on it, and cannot see that the previous
/// fragment ended mid-clause. Names come back mangled and clause boundaries come
/// back wrong.
///
/// Two things go in, in the order whisper reads them:
///
///   1. a **vocabulary line** — the people and terms this call is about, from the
///      calendar event and the user's own profile. Fixed for the whole call.
///   2. the **tail of what this leg last said**, so a fragment is decoded as the
///      continuation it usually is.
///
/// Per leg, deliberately. Conditioning the microphone on what the other party
/// just said would push the user's words toward theirs, which is the opposite of
/// what the two-leg design is for.
public struct DecodingContext: Sendable {
    /// Kept short. The prompt competes with the audio for the decoder's
    /// attention, and a long one makes whisper more willing to repeat it back.
    public static let historyCharacterLimit = 240
    /// Enough for a participant list and a handful of product names.
    public static let vocabularyTermLimit = 24

    private let vocabularyLine: String
    private var history: [TurnSource: String] = [:]

    public init(vocabulary: [String] = []) {
        vocabularyLine = Self.renderVocabulary(vocabulary)
    }

    /// The prompt for the next utterance on this leg.
    public func prompt(for source: TurnSource) -> String? {
        let recent = history[source] ?? ""
        let parts = [vocabularyLine, recent].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    /// Records accepted text so the next fragment on this leg is decoded as its
    /// continuation. Only text that survived the artifact and confidence filters
    /// should reach here — conditioning on a hallucination invites another.
    public mutating func record(_ text: String, for source: TurnSource) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let combined = ((history[source] ?? "") + " " + trimmed)
            .trimmingCharacters(in: .whitespaces)
        history[source] = String(combined.suffix(Self.historyCharacterLimit))
    }

    public mutating func reset() { history.removeAll() }

    /// Renders the terms as a sentence rather than a list.
    ///
    /// whisper's prompt is decoded as if it were preceding speech, so a bare
    /// comma-separated list reads as a strange utterance and gets echoed back
    /// into the transcript. A plain sentence biases the vocabulary without
    /// inviting repetition.
    static func renderVocabulary(_ terms: [String]) -> String {
        var seen = Set<String>()
        var kept: [String] = []
        for term in terms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 1, trimmed.count <= 40 else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            kept.append(trimmed)
            if kept.count >= vocabularyTermLimit { break }
        }
        guard !kept.isEmpty else { return "" }
        return "This conversation mentions \(kept.joined(separator: ", "))."
    }

    /// Pulls likely proper nouns out of free profile text.
    ///
    /// Capitalised words that are not sentence-initial, which is the same rule
    /// `ClaimGuard` uses to decide what counts as a named thing — and for the
    /// same reason: those are the tokens a general model is least likely to get
    /// right and most damaging to get wrong.
    public static func terms(fromProfileText text: String) -> [String] {
        var terms: [String] = []
        for (word, isSentenceInitial) in ClaimGuard.positionedWords(in: text) {
            guard !isSentenceInitial, let first = word.first, first.isUppercase else { continue }
            guard word.count > 2 else { continue }
            terms.append(word)
        }
        return terms
    }
}
