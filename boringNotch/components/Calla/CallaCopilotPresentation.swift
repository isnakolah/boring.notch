import Foundation

/// What the copilot puts in the notch's fixed ~488x130pt slab.
///
/// Pure and separately tested, like `CallaNotchPresentation`. During a live call
/// this surface is read in the half-second before the user has to speak, so the
/// decision of what earns that space is worth being exact about rather than
/// scattering conditionals through SwiftUI.
enum CallaCopilotPresentation {
    enum Mode: String, Equatable {
        /// A call is running and a pointer is on screen.
        case suggesting
        /// A call is running with nothing worth saying yet.
        case listening
        /// A call is running but only our own side is being captured.
        case halfDeaf
        /// Installed and idle.
        case ready
        /// The capture host is missing.
        case unavailable
    }

    enum Tone: String, Equatable {
        case active
        case ready
        case warning
    }

    struct Pill: Equatable {
        let text: String
        let tone: Tone
    }

    static func mode(
        available: Bool,
        running: Bool,
        systemAudioActive: Bool,
        hasSuggestion: Bool
    ) -> Mode {
        guard available else { return .unavailable }
        guard running else { return .ready }
        // Say it plainly when the other party is not being heard: the pointers
        // are built almost entirely from what *they* said, so a mic-only call
        // silently produces near-useless output.
        if !systemAudioActive { return .halfDeaf }
        return hasSuggestion ? .suggesting : .listening
    }

    static func pill(for mode: Mode) -> Pill {
        switch mode {
        case .suggesting: return Pill(text: "Live", tone: .active)
        case .listening: return Pill(text: "Listening", tone: .active)
        case .halfDeaf: return Pill(text: "Mic only", tone: .warning)
        case .ready: return Pill(text: "Ready", tone: .ready)
        case .unavailable: return Pill(text: "Not installed", tone: .warning)
        }
    }

    static func primaryActionTitle(running: Bool) -> String {
        running ? "End call" : "Start call"
    }

    /// Elapsed call time as `m:ss`, or `h:mm:ss` once it earns the hour.
    static func elapsed(since start: Date?, now: Date) -> String? {
        guard let start else { return nil }
        let total = Int(max(0, now.timeIntervalSince(start)))
        let seconds = total % 60
        let minutes = (total / 60) % 60
        let hours = total / 3600
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// One status line under the headline.
    static func subtitle(turnCount: Int, elapsed: String?, gatewayConnected: Bool) -> String {
        var parts: [String] = []
        if let elapsed { parts.append(elapsed) }
        if turnCount > 0 { parts.append("\(turnCount) turn\(turnCount == 1 ? "" : "s")") }
        if !gatewayConnected { parts.append("gateway offline") }
        return parts.joined(separator: " · ")
    }

    /// The headline is the question the user has to answer *right now*, so it
    /// gets one line and never wraps the slab open.
    static func headlineLine(_ value: String?, limit: Int = 90) -> String? {
        guard let flattened = flatten(value), !flattened.isEmpty else { return nil }
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Angles that fit the slab. Two at most in the notch — a third is real
    /// content, but reading it costs more time than it saves mid-sentence, so
    /// it lives in the window instead.
    static func angleLines(_ angles: [String], limit: Int = 2, characters: Int = 78) -> [String] {
        angles
            .compactMap { flatten($0) }
            .filter { !$0.isEmpty }
            .prefix(limit)
            .map { $0.count > characters ? String($0.prefix(characters)).trimmingCharacters(in: .whitespaces) + "…" : $0 }
    }

    /// Newlines would grow the slab past the notch shape, so they collapse.
    private static func flatten(_ value: String?) -> String? {
        guard let value else { return nil }
        return value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
