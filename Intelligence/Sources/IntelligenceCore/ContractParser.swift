import Foundation

/// Pulls a task's contract out of whatever the model actually said.
///
/// Model output is never as clean as the prompt asked for: it arrives wrapped in
/// prose, inside a ```json fence, with a sentinel line after it, or truncated
/// mid-object. This is pure so all of that is testable without a model.
public enum ContractParser {
    /// A JSON object satisfying `contract`, re-encoded, plus the text with the
    /// sentinel removed.
    public struct Parsed: Sendable, Equatable {
        public let text: String
        public let payload: Data?
    }

    public static func parse(_ raw: String, contract: OutputContract) throws -> Parsed {
        let clean = stripANSI(raw)

        switch contract {
        case .freeform:
            return Parsed(text: clean.trimmingCharacters(in: .whitespacesAndNewlines), payload: nil)

        case let .json(keys):
            return try parseJSON(clean, keys: keys, marker: nil)

        case let .sentinelJSON(keys, marker):
            return try parseJSON(clean, keys: keys, marker: marker)
        }
    }

    /// Whether a reply looks complete, for transports that see text arrive
    /// incrementally. With a sentinel this is exact; without one we can only
    /// check that some object with the required keys is already present.
    public static func isComplete(_ raw: String, contract: OutputContract) -> Bool {
        let clean = stripANSI(raw)
        if let marker = contract.marker {
            return clean.contains(marker)
        }
        if contract.requiredKeys.isEmpty { return !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return (try? parseJSON(clean, keys: contract.requiredKeys, marker: nil)) != nil
    }

    // MARK: - JSON

    private static func parseJSON(_ text: String, keys: [String], marker: String?) throws -> Parsed {
        var body = text
        if let marker {
            // Everything after the sentinel is the harness talking to itself.
            if let range = body.range(of: marker) {
                body = String(body[body.startIndex ..< range.lowerBound])
            }
        }
        let stripped = body.trimmingCharacters(in: .whitespacesAndNewlines)

        for candidate in jsonCandidates(in: stripped).reversed() {
            guard let data = candidate.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            guard keys.allSatisfy({ object[$0] != nil }) else { continue }
            let normalised = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return Parsed(text: stripped, payload: normalised)
        }
        throw IntelligenceFailure.unparseable(
            "no JSON object with keys \(keys.sorted()) in \(stripped.count) chars of reply"
        )
    }

    /// Every balanced `{...}` run in the text, outermost first, in order of
    /// appearance. Brace counting respects strings and escapes, so a `}` inside
    /// a value does not end the object.
    static func jsonCandidates(in text: String) -> [String] {
        var candidates: [String] = []
        let characters = Array(text)
        var index = 0

        while index < characters.count {
            guard characters[index] == "{" else {
                index += 1
                continue
            }
            var depth = 0
            var inString = false
            var escaped = false
            var cursor = index

            while cursor < characters.count {
                let character = characters[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\", inString {
                    escaped = true
                } else if character == "\"" {
                    inString.toggle()
                } else if !inString {
                    if character == "{" {
                        depth += 1
                    } else if character == "}" {
                        depth -= 1
                        if depth == 0 {
                            candidates.append(String(characters[index ... cursor]))
                            break
                        }
                    }
                }
                cursor += 1
            }
            // Unbalanced (truncated reply): nothing further can close either.
            if depth != 0 { break }
            index = cursor + 1
        }
        return candidates
    }

    // MARK: - Terminal noise

    /// CSI/OSC escape sequences, in case a reply ever comes off a terminal. The
    /// fast path reads JSONL rather than a TUI, but the print transport's stderr
    /// and any future pty reader can still carry them.
    static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var iterator = text.makeIterator()
        var pending: Character?

        while let character = pending ?? iterator.next() {
            pending = nil
            guard character == "\u{1B}" else {
                out.append(character)
                continue
            }
            guard let next = iterator.next() else { break }
            if next == "[" {
                while let terminator = iterator.next() {
                    if terminator.isLetter || terminator == "~" { break }
                }
            } else if next == "]" {
                // OSC: ends at BEL or ST (ESC \).
                while let terminator = iterator.next() {
                    if terminator == "\u{07}" { break }
                    if terminator == "\u{1B}" {
                        _ = iterator.next()
                        break
                    }
                }
            } else if next != "\u{1B}" {
                continue
            } else {
                pending = next
            }
        }
        return out
    }
}
