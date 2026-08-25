import Foundation

/// Checks a suggestion's factual assertions against what is actually known.
///
/// The prompts have said "never invent employers, dates, numbers or systems the
/// user has not mentioned" since the beginning (`CopilotTasks`), and a real call
/// produced this anyway:
///
///     them: "And what's your academic background? I don't see that in the CV"
///     copilot: "I hold a degree in Computer Science, focusing on software
///               engineering and systems design."
///
/// The user had said "electrical engineering though not to completion". A prompt
/// cannot be the only thing standing between a model and a sentence the user is
/// about to say out loud to an interviewer, so this is the mechanical backstop:
/// every proper noun and every number in a first-person claim must appear
/// somewhere in the evidence, or the headline is not offered as speakable.
///
/// Deterministic and synchronous. No second model call, so it costs nothing on
/// the latency path that matters.
public enum ClaimGuard {
    /// What a suggestion is allowed to draw on: retrieved notes, the user's own
    /// profile text, and everything the user has already said on this call.
    ///
    /// Deliberately *not* what the other party said. "Do you have a CS degree?"
    /// must not license "I have a CS degree" — the question is where the words
    /// came from, and treating it as evidence is exactly how a leading question
    /// turns into a fabricated answer.
    public struct Evidence: Sendable {
        private var tokens: Set<String>
        private var digits: Set<String>
        /// Names the other party has used. These license *repeating a name* and
        /// nothing else.
        private var heardNames: Set<String>

        public init(sources: [String] = []) {
            tokens = []
            digits = []
            heardNames = []
            for source in sources { add(source) }
        }

        public mutating func add(_ text: String) {
            for token in ClaimGuard.tokenize(text) {
                if token.first?.isNumber == true {
                    digits.insert(token)
                } else {
                    tokens.insert(token)
                }
            }
        }

        /// Records what the other party said, as name material only.
        ///
        /// Saying the interviewer's own company back to them is not a
        /// fabrication — "I'm drawn to Rainforest Alliance's work in East Africa"
        /// is the ordinary shape of an interview answer, and flagging it made the
        /// guard noisy on the calls it should have been quietest on. What a
        /// question must never license is a *quantity* or a *credential*: "do you
        /// have a CS degree?" is not evidence of a CS degree, and "we need ten
        /// years" is not evidence of ten years. So names cross over and numbers
        /// and fields of study do not.
        public mutating func addHeardNames(_ text: String) {
            for token in ClaimGuard.tokenize(text) {
                guard token.first?.isNumber != true else { continue }
                guard !ClaimGuard.credentialSubjects.contains(token) else { continue }
                heardNames.insert(token)
            }
        }

        /// A copy extended with material that applies to one request only —
        /// chunks retrieved for this question, which should vouch for this answer
        /// without becoming standing evidence for the rest of the call.
        public func adding(_ sources: [String]) -> Evidence {
            guard !sources.isEmpty else { return self }
            var copy = self
            for source in sources { copy.add(source) }
            return copy
        }

        public func addingHeardNames(_ sources: [String]) -> Evidence {
            guard !sources.isEmpty else { return self }
            var copy = self
            for source in sources { copy.addHeardNames(source) }
            return copy
        }

        func supports(_ token: String) -> Bool {
            if token.first?.isNumber == true { return digits.contains(token) }
            if tokens.contains(token) { return true }
            // Credentials and fields of study are never licensed by hearsay.
            if !ClaimGuard.credentialSubjects.contains(token), heardNames.contains(token) {
                return true
            }
            // Cheap morphology: the notes say "engineering", the claim says
            // "engineer". Refusing that would make the guard fire on almost
            // every real sentence, and a guard nobody can satisfy gets removed.
            return tokens.contains { other in
                (other.hasPrefix(token) || token.hasPrefix(other))
                    && min(other.count, token.count) >= 5
            }
        }
    }

    public struct Verdict: Sendable, Equatable {
        /// Tokens asserted with no support anywhere in the evidence.
        public var unsupported: [String]
        public var isGrounded: Bool { unsupported.isEmpty }

        public init(unsupported: [String]) { self.unsupported = unsupported }
    }

    /// Checks one line of suggested speech.
    ///
    /// Only first-person assertions are checked. "Ask what their SLA is" names a
    /// term the user has never heard and is still perfectly good advice; "I built
    /// their SLA tooling" is a claim, and the difference is who the sentence says
    /// did the thing.
    public static func check(_ text: String, against evidence: Evidence) -> Verdict {
        guard isFirstPersonClaim(text) else { return Verdict(unsupported: []) }

        var unsupported: [String] = []
        for token in checkableTokens(in: text) where !evidence.supports(token) {
            if !unsupported.contains(token) { unsupported.append(token) }
        }
        return Verdict(unsupported: unsupported)
    }

    /// Checks a whole suggestion. `angles` are fragments of the same answer, so
    /// they are held to the same standard as the headline.
    public static func check(
        headline: String,
        angles: [String],
        against evidence: Evidence
    ) -> Verdict {
        var unsupported = check(headline, against: evidence).unsupported
        for angle in angles {
            for token in check(angle, against: evidence).unsupported
            where !unsupported.contains(token) {
                unsupported.append(token)
            }
        }
        return Verdict(unsupported: unsupported)
    }

    // MARK: - Shape

    /// Whether the line claims something about the user rather than telling them
    /// what to ask or do.
    static func isFirstPersonClaim(_ text: String) -> Bool {
        let words = tokenizeKeepingCase(text)
        guard !words.isEmpty else { return false }
        return words.contains { firstPersonMarkers.contains($0.lowercased()) }
    }

    private static let firstPersonMarkers: Set<String> = [
        "i", "i'm", "im", "i've", "ive", "i'd", "id", "i'll", "my", "mine", "me",
        "we", "we're", "we've", "our", "ours", "us",
    ]

    /// The tokens in a claim worth checking: capitalised words that are not
    /// sentence-initial (proper nouns), numbers, and a short list of credential
    /// vocabulary that is load-bearing even in lowercase.
    ///
    /// Sentence position is tracked, not approximated by word index. A first pass
    /// treated every capital after index 0 as a proper noun, which made "Yes.
    /// I'm happy to" report `i'm` as an invented entity — and `i'm`, `let's` and
    /// `sorry` were three of the eight most-flagged tokens across 54 real calls.
    /// A guard that cries wolf on the word "I'm" is one nobody will keep.
    static func checkableTokens(in text: String) -> [String] {
        var result: [String] = []
        for (word, isSentenceInitial) in positionedWords(in: text) {
            let lower = fold(word)
            if stopWords.contains(lower) || stopWords.contains(word.lowercased()) { continue }
            if word.first?.isNumber == true {
                result.append(lower)
                continue
            }
            // Markers are what make a sentence a credential claim; they are never
            // the invented part. Requiring evidence for the word "degree" made
            // "I did electrical engineering, though I did not complete the
            // degree" read as a fabrication against a note that says exactly
            // that.
            if credentialMarkers.contains(lower) { continue }
            if credentialSubjects.contains(lower) {
                result.append(lower)
                continue
            }
            guard !isSentenceInitial, let first = word.first, first.isUppercase else { continue }
            result.append(lower)
        }
        return result
    }

    /// Each word with whether it opens a sentence. Terminal punctuation resets
    /// the flag; an apostrophe or a hyphen inside a word does not.
    static func positionedWords(in text: String) -> [(word: String, isSentenceInitial: Bool)] {
        var result: [(String, Bool)] = []
        var current = ""
        var atSentenceStart = true
        var pendingBreak = false

        func flush() {
            guard !current.isEmpty else { return }
            result.append((current, atSentenceStart))
            atSentenceStart = false
            current = ""
        }

        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "\u{2019}" {
                if pendingBreak {
                    atSentenceStart = true
                    pendingBreak = false
                }
                current.append(character == "\u{2019}" ? "'" : character)
                continue
            }
            flush()
            if terminators.contains(character) { pendingBreak = true }
        }
        flush()
        return result
    }

    static let terminators: Set<Character> = [".", "!", "?", "\u{2026}", ":", ";", "\n"]

    /// Category words that signal a credential claim without ever being the
    /// specific thing claimed. Deliberately *excluded* from checking: they are
    /// ordinary English, and demanding evidence for them makes the guard fire on
    /// true statements.
    static let credentialMarkers: Set<String> = [
        "degree", "bachelor", "bachelors", "master", "masters", "phd", "doctorate",
        "diploma", "certification", "certificate", "certified", "graduated",
        "major", "majored", "minored", "gpa", "honours", "honors",
        "years", "year", "months", "month", "experience", "background",
    ]

    /// Fields of study and practice. These *are* the payload of a credential
    /// claim, and they are usually lowercase, so capitalisation alone would miss
    /// them: "I have a degree in electrical engineering" contains no proper noun.
    static let credentialSubjects: Set<String> = [
        "engineering", "science", "sciences", "mathematics", "maths", "physics",
        "chemistry", "biology", "economics", "finance", "accounting", "law",
        "medicine", "nursing", "psychology", "philosophy", "linguistics",
        "statistics", "architecture", "design", "journalism", "marketing",
    ]

    static let stopWords: Set<String> = [
        "i", "a", "an", "the", "and", "or", "but", "so", "to", "of", "in", "on",
        "at", "for", "with", "from", "by", "as", "is", "am", "are", "was", "were",
        "be", "been", "have", "has", "had", "do", "does", "did", "it", "its",
        "that", "this", "these", "those", "my", "we", "our", "us", "me", "you",
        "your", "they", "their", "them", "he", "she", "his", "her",
        // Contractions of the pronouns above. They are always capitalised
        // mid-line and are never entities.
        "i'm", "i've", "i'll", "i'd", "we're", "we've", "we'll", "we'd",
        "let's", "lets", "it's", "that's", "there's", "here's", "what's",
        // Conversational openers that arrive capitalised after a full stop.
        "yes", "no", "ok", "okay", "sure", "sorry", "please", "thanks",
        "thank", "right", "well", "so", "actually", "maybe", "perhaps",
    ]

    static func tokenize(_ text: String) -> [String] {
        tokenizeKeepingCase(text).map { fold($0) }
    }

    /// Lowercases and drops a possessive ending, so "Alliance's" and "Alliance"
    /// are one token. Without this a claim that says the company's name in the
    /// possessive reads as naming a company nobody mentioned.
    ///
    /// Only applied when something real is left: "it's" must not become "it".
    static func fold(_ word: String) -> String {
        let lower = word.lowercased()
        guard lower.hasSuffix("'s"), lower.count >= 5 else { return lower }
        return String(lower.dropLast(2))
    }

    /// Splits on anything that is not a letter, a digit or an intra-word
    /// apostrophe, so "I've" survives and "end-to-end" becomes three tokens.
    static func tokenizeKeepingCase(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for character in text {
            if character.isLetter || character.isNumber || character == "'" || character == "\u{2019}" {
                current.append(character == "\u{2019}" ? "'" : character)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
