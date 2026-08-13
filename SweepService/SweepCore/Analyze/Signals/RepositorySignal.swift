import Foundation

// A node inside a Git work tree is read two ways:
//   - ignored by Git → reclaimable: Git itself declares it not source (0.7);
//   - present but not ignored → treated as tracked source, a protective veto:
//     Sweep will not delete what a repository is keeping.
//
// Determining this from the disk (rather than shelling out to git, which no fake
// filesystem could answer) means finding the enclosing `.git` and matching the
// node against the work tree's `.gitignore`. Not-ignored resolving to a veto is
// the conservative reading: anything a repository holds that it is not ignoring is
// assumed to be source, which is the safe default.
struct RepositorySignal: Signal {
    let name = "Repository"

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard let workTree = enclosingWorkTree(of: node.url, fileSystem: context.fileSystem) else {
            return []       // not in a repository at all — this signal says nothing
        }

        let relative = relativePath(of: node.url, under: workTree)
        guard !relative.isEmpty else { return [] }

        if isIgnored(relative, isDirectory: node.isDirectory, workTree: workTree, fileSystem: context.fileSystem) {
            return [Evidence(
                signal: name,
                polarity: .reclaimable,
                weight: 0.7,
                reason: "Ignored by Git in the enclosing repository, so it is not tracked source.",
                category: .buildArtifact)]
        }

        return [Evidence(
            signal: name,
            polarity: .protective,
            weight: 1.0,        // veto — tracked source is never offered
            reason: "Tracked inside a Git repository — this is source, not a leftover.",
            category: nil)]
    }

    // MARK: Work tree and ignore resolution

    private func enclosingWorkTree(of url: URL, fileSystem: FileSystem) -> URL? {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" && !dir.path.isEmpty {
            if fileSystem.fileExists(at: dir.appendingPathComponent(".git")) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private func relativePath(of url: URL, under workTree: URL) -> String {
        let full = url.standardizedFileURL.path
        let base = workTree.standardizedFileURL.path
        guard full.hasPrefix(base) else { return "" }
        return String(full.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // A deliberately small subset of gitignore semantics: comments, negation,
    // anchored and unanchored patterns, directory-only patterns, and `*` globbing
    // on a single component. Enough to recognise the common cases (`node_modules/`,
    // `build/`, `*.log`) that mark regenerable output.
    private func isIgnored(_ relative: String, isDirectory: Bool, workTree: URL, fileSystem: FileSystem) -> Bool {
        guard let lines = fileSystem.readLines(at: workTree.appendingPathComponent(".gitignore")) else {
            return false
        }
        let components = relative.split(separator: "/").map(String.init)
        let lastComponent = components.last ?? relative

        var ignored = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            var pattern = line
            let negated = pattern.hasPrefix("!")
            if negated { pattern.removeFirst() }
            let directoryOnly = pattern.hasSuffix("/")
            if directoryOnly { pattern.removeLast() }
            if directoryOnly && !isDirectory && !components.dropLast().contains(pattern) { continue }

            let anchored = pattern.hasPrefix("/")
            if anchored { pattern.removeFirst() }

            let matched: Bool
            if pattern.contains("/") {
                matched = anchored ? relative == pattern || relative.hasPrefix(pattern + "/")
                                   : relative.hasSuffix(pattern) || relative.contains(pattern + "/")
            } else if pattern.contains("*") {
                matched = glob(pattern, matches: lastComponent)
            } else {
                // Bare name matches any path component (git's default).
                matched = anchored ? components.first == pattern : components.contains(pattern)
            }

            if matched { ignored = !negated }
        }
        return ignored
    }

    private func glob(_ pattern: String, matches name: String) -> Bool {
        // Single-segment `*` glob: `*.log`, `build-*`.
        let escaped = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: "[^/]*")
        return name.range(of: "^\(escaped)$", options: .regularExpression) != nil
    }
}
