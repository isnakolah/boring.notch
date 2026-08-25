import Foundation

/// Every prompt the copilot sends, as files rather than Swift literals.
///
/// They used to be string constants spread across `CopilotTasks`, `PromptComposer`
/// and — a second, already-diverged copy — the Settings pane. Prompt wording is
/// the part of this system that most wants iterating on and least wants a
/// rebuild, and a copy the app shows that is not the copy the host sends is
/// worse than no preview at all.
///
/// Resolution, most specific first:
///
///   1. an explicit override string (what the user typed in Settings)
///   2. the user's own pack directory, if that file exists in it
///   3. the bundled pack
///   4. a compiled-in constant
///
/// Step 4 exists so this can never fail mid-call. A missing or unreadable file
/// degrades to the wording that shipped; it does not degrade to an empty prompt,
/// which would take the output contract with it and make the notch go quiet.
public struct PromptPack: Sendable {
    /// One prompt, addressed by its path inside the pack.
    public enum ID: String, Sendable, CaseIterable {
        case liveBase = "live/base.md"
        case laneBrief = "lanes/brief.md"
        case laneExec = "lanes/exec.md"
        case laneSummary = "lanes/summary.md"
        case houseRules = "composer/house-rules.md"
        case contractJSON = "composer/contract-json.md"
        case contractSentinel = "composer/contract-sentinel.md"

        /// Placeholders this file must contain to do its job. A prompt that has
        /// lost its contract instructions still produces confident prose, and the
        /// only symptom is that nothing ever parses.
        public var requiredPlaceholders: [String] {
            switch self {
            case .contractJSON: return ["{{keys}}"]
            case .contractSentinel: return ["{{keys}}", "{{marker}}"]
            default: return []
            }
        }
    }

    public static func personaPath(_ persona: String) -> String {
        "live/personas/\(persona).md"
    }

    /// Where a user's editable copy lives. Nil for the bundled-only pack.
    public let overrideDirectory: URL?

    public init(overrideDirectory: URL? = nil) {
        self.overrideDirectory = overrideDirectory
    }

    // MARK: - Reading

    public func text(_ id: ID) -> String {
        text(atPath: id.rawValue) ?? Self.builtIn(id)
    }

    /// A persona block. Unknown personas fall back to `generic`, which is what
    /// makes a user-defined persona id safe to pass through: it either has a file
    /// or it behaves like a general conversation.
    public func persona(_ persona: String) -> String {
        if let text = text(atPath: Self.personaPath(persona)) { return text }
        if let generic = text(atPath: Self.personaPath("generic")) { return generic }
        return Self.builtInGenericPersona
    }

    /// Persona ids the pack defines, so a persona can be added by dropping a file
    /// in rather than editing an allowlist.
    public func personaIDs() -> [String] {
        var ids = Set<String>()
        for root in searchRoots() {
            let directory = root.appendingPathComponent("live/personas", isDirectory: true)
            let entries = (try? FileManager.default.contentsOfDirectory(
                atPath: directory.path)) ?? []
            for entry in entries where entry.hasSuffix(".md") {
                ids.insert(String(entry.dropLast(3)))
            }
        }
        return ids.sorted()
    }

    private func text(atPath path: String) -> String? {
        for root in searchRoots() {
            let url = root.appendingPathComponent(path)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // An empty file means "I edited this to nothing", which is a mistake
            // rather than an instruction. Fall through to the next source.
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// The user's directory first, then the bundled one.
    private func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let overrideDirectory { roots.append(overrideDirectory) }
        if let bundled = Self.bundledRoot { roots.append(bundled) }
        return roots
    }

    public static var bundledRoot: URL? {
        Bundle.module.url(forResource: "Prompts", withExtension: nil)
    }

    // MARK: - Contract rendering

    /// Fills a contract template. Kept here rather than in `PromptComposer` so
    /// the placeholder names and the files that use them stay together.
    public func contractInstruction(_ contract: OutputContract) -> String? {
        switch contract {
        case .freeform:
            return nil
        case let .json(keys):
            return text(.contractJSON)
                .replacingOccurrences(of: "{{keys}}", with: Self.renderKeys(keys))
        case let .sentinelJSON(keys, marker):
            return text(.contractSentinel)
                .replacingOccurrences(of: "{{keys}}", with: Self.renderKeys(keys))
                .replacingOccurrences(of: "{{marker}}", with: marker)
        }
    }

    static func renderKeys(_ keys: [String]) -> String {
        keys.map { "`\($0)`" }.joined(separator: ", ")
    }

    // MARK: - Export and lint

    /// Writes the **bundled** pack somewhere the user can edit it.
    ///
    /// Bundled, not effective. Exporting what is currently in force sounds
    /// right and is not: the user's own directory wins resolution, so an export
    /// would read that directory and write it straight back, and a file left
    /// behind by an older version would perpetuate itself forever. `--force`
    /// would restore nothing, which is the one thing it exists to do.
    ///
    /// Never overwrites without `overwrite`: the point of exporting is usually
    /// to start editing, and clobbering yesterday's edit would be worse than
    /// doing nothing.
    @discardableResult
    public func export(to directory: URL, overwrite: Bool = false) throws -> [String] {
        let defaults = PromptPack()
        var written: [String] = []
        var paths = ID.allCases.map(\.rawValue)
        paths.append(contentsOf: defaults.personaIDs().map(Self.personaPath))
        paths.append("pack.json")

        for path in paths {
            let destination = directory.appendingPathComponent(path)
            if !overwrite, FileManager.default.fileExists(atPath: destination.path) { continue }
            let body: String
            if path == "pack.json" {
                guard let bundled = Self.bundledRoot,
                      let contents = try? String(
                          contentsOf: bundled.appendingPathComponent(path), encoding: .utf8)
                else { continue }
                body = contents
            } else if let id = ID(rawValue: path) {
                body = defaults.text(id)
            } else {
                body = defaults.persona(
                    String(path.dropFirst("live/personas/".count).dropLast(3)))
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try (body + "\n").write(to: destination, atomically: true, encoding: .utf8)
            written.append(path)
        }
        return written
    }

    public struct Problem: Sendable, Equatable {
        public var path: String
        public var detail: String
    }

    /// Checks that every prompt the tasks rely on is present and still says what
    /// the code needs it to say.
    ///
    /// This is the check that a bad edit currently gets instead of a silent
    /// notch: the Settings pane already warns that "a bad edit here makes every
    /// suggestion unreadable", and until now nothing could tell you before the
    /// call started.
    public func lint(requiredPersonas: [String] = []) -> [Problem] {
        var problems: [Problem] = []
        for id in ID.allCases {
            let body = text(id)
            if body.isEmpty {
                problems.append(Problem(path: id.rawValue, detail: "resolved to nothing"))
                continue
            }
            for placeholder in id.requiredPlaceholders where !body.contains(placeholder) {
                problems.append(Problem(
                    path: id.rawValue,
                    detail: "is missing \(placeholder); nothing the model returns will parse"))
            }
        }
        let available = Set(personaIDs())
        for persona in requiredPersonas where !available.contains(persona) {
            problems.append(Problem(
                path: Self.personaPath(persona),
                detail: "missing; this persona will fall back to generic"))
        }
        return problems
    }

    // MARK: - Last resort

    /// Used only when a file is missing from both the user's pack and the bundle
    /// — a corrupted install, or a target that did not copy resources. Short on
    /// purpose: its job is to keep the contract intact, not to be good.
    static func builtIn(_ id: ID) -> String {
        switch id {
        case .liveBase:
            return """
            You sit beside someone during a live call and tell them what to say \
            next. Advise the user (`Me:`) only, never the other party (`Them:`). \
            `headline` is at most 14 words and speakable as-is; `angles` is at \
            most 2 fragments; `confirm` is anything the other side asserted that \
            is worth checking. Never state a fact about the user that is not in \
            the input.
            """
        case .laneBrief:
            return """
            Keep the running account. Each message is the turns since the last \
            one; write `points` about those alone, at most 2 lines of at most 12 \
            words. `open_questions` is at most 3 unanswered fragments. Never \
            invent numbers, names or commitments.
            """
        case .laneExec:
            return """
            Compress the earlier conversation into `standing`: at most 2 lines of \
            at most 20 words, durable fact only. `open_questions` is at most 3 \
            still-unanswered fragments. Never invent anything.
            """
        case .laneSummary:
            return """
            The call has ended. Write `summary` as the user's own notes: what was \
            agreed, what was promised by whom. `open_questions` is what was left \
            open. Add nothing that was not said.
            """
        case .houseRules:
            return """
            ## Rules
            Answer directly from the input. Never call tools, never read or write \
            files, never search. No preamble, no closing remarks, no restating \
            the question.
            """
        case .contractJSON:
            return """
            ## Output
            Reply with a single JSON object and nothing else. Required keys: {{keys}}.
            """
        case .contractSentinel:
            return """
            ## Output
            Reply with a single JSON object and nothing else. Required keys: \
            {{keys}}. After the object, output a final line containing exactly {{marker}}
            """
        }
    }

    static let builtInGenericPersona = """
    General conversation. Keep the user precise and moving, and surface anything \
    left ambiguous.
    """
}
