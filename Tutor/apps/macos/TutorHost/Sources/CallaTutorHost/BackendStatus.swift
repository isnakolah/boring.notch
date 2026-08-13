import Foundation

/// Whether this Mac is actually plugged into Calla's intelligence.
///
/// The host itself never talks to the Gateway — the separate node agent holds
/// that WebSocket and forwards envelopes into this host's socket. So "is it
/// connected" is not something the host can answer by introspection, and
/// without it a lesson that never starts looks identical to one nobody asked
/// for. Two independent facts answer it: what the node agent last logged about
/// its connection, and when this host last received a request from it.
@MainActor
final class BackendStatus: ObservableObject {
    enum Link: Equatable {
        case connected(gateway: String)
        case disconnected(reason: String)
        case agentNotRunning
        case unknown

        var isHealthy: Bool { if case .connected = self { return true } else { return false } }
    }

    static let shared = BackendStatus()

    @Published private(set) var link: Link = .unknown
    /// When the link stopped being healthy, so a blip can be told from a
    /// failure. "Reconnecting…" that never resolves is a lie the learner has no
    /// way to see through.
    @Published private(set) var unhealthySince: Date?

    /// Long enough that an ordinary reconnect never trips it.
    private let stuckAfter: TimeInterval = 30

    var isStuck: Bool {
        guard let unhealthySince else { return false }
        return Date().timeIntervalSince(unhealthySince) >= stuckAfter
    }
    /// When the Gateway last sent this host anything at all.
    @Published private(set) var lastRequestAt: Date?
    /// The operation in that request, so "connected but idle" is legible.
    @Published private(set) var lastOperation: String?

    /// The last thing that went wrong, in words worth putting in the menu bar.
    ///
    /// These used to exist only in `step-timing.log`, which meant the answer to
    /// "why did nothing happen" was in a file — and a learner who cannot see a
    /// refusal cannot tell it apart from Calla thinking. Cleared as soon as
    /// something works, so it reports the present rather than accumulating a
    /// history nobody asked for.
    struct Problem: Equatable {
        let summary: String
        /// The failure code or cause, for anyone who wants to search the log.
        let detail: String
        let at: Date
    }
    @Published private(set) var problem: Problem?

    /// A question is out and nothing has come back yet.
    private var awaitingReply: Date?
    private var replyWatchdog: Timer?
    /// Generous: a Gateway turn legitimately takes tens of seconds.
    private let replyDeadline: TimeInterval = 120

    /// Record a refused operation, with the code the host answered with.
    func noteRefusal(operation: String, code: String) {
        // A stopped lesson refusing a late turn is the system working, not a
        // fault, and saying so would train the learner to ignore this line.
        guard code != "lesson_stopped", code != "capture_paused" else { return }
        problem = Problem(summary: Self.explain(code: code, operation: operation),
                          detail: "\(operation) refused: \(code)", at: Date())
    }

    /// Something worked, so whatever was wrong no longer is.
    func noteSuccess() {
        problem = nil
        clearReplyWatch()
    }

    /// The learner has read it.
    func clearProblem() {
        problem = nil
    }

    /// A question has gone to the Gateway. If nothing draws before the deadline,
    /// say so — a turn that produces an empty answer is otherwise completely
    /// invisible here, because the sender backgrounds the remote command and only
    /// ever reports that it started.
    func expectReply() {
        awaitingReply = Date()
        replyWatchdog?.invalidate()
        let timer = Timer(timeInterval: replyDeadline, repeats: false) { _ in
            MainActor.assumeIsolated { BackendStatus.shared.replyOverdue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        replyWatchdog = timer
    }

    func clearReplyWatch() {
        awaitingReply = nil
        replyWatchdog?.invalidate()
        replyWatchdog = nil
    }

    private func replyOverdue() {
        guard awaitingReply != nil else { return }
        clearReplyWatch()
        problem = Problem(
            summary: "Calla did not answer. The question reached the Gateway but nothing came back.",
            detail: "no guide, narrate or point within \(Int(replyDeadline))s of asking",
            at: Date())
    }

    /// Plain language for the codes a learner can actually do something about.
    private static func explain(code: String, operation: String) -> String {
        switch code {
        case "no_focused_window":
            return "Calla could not see the application's window. Bring it to the front and ask again."
        case "accessibility_not_permitted":
            return "That step needs Accessibility. Grant it in Settings › Permissions."
        case "invalid_session":
            return "Calla sent a request with no valid lesson. Start a new lesson."
        case "invalid_coordinates", "target_hint_forbidden":
            return "Calla tried to act on raw coordinates, which is never allowed. The step was refused."
        case "missing_target", "invalid_descriptor":
            return "Calla could not identify the control it meant. It should look again."
        case "unsupported_operation", "unsupported_version", "protocol_error":
            return "The Gateway and this Mac disagree about the protocol. One of them needs updating."
        case "host_error":
            return "Something failed on this Mac during \(operation)."
        default:
            return "Calla's \(operation) was refused (\(code))."
        }
    }

    private let logURL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Logs/Calla/node-host.log")
    private var timer: Timer?
    /// Somebody is looking: a lesson is running, or a window that shows this is
    /// open. Set by the menu and Settings while they are on screen.
    var observers = 0
    var isWatched: Bool { observers > 0 || TutorHostController.shared.lessonActive }

    func noteRequest(operation: String) {
        lastRequestAt = Date()
        lastOperation = operation
    }

    func startWatching() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated {
                // Reading a log tail every five seconds forever is a wake-up
                // nobody asked for. The answer is only ever looked at while a
                // lesson is running or while somebody has the menu or Settings
                // open, and none of those can start without something else
                // calling `refresh` first.
                guard BackendStatus.shared.isWatched else { return }
                BackendStatus.shared.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let next = readLink()
        if next.isHealthy {
            unhealthySince = nil
        } else if unhealthySince == nil {
            unhealthySince = Date()
        }
        link = next
    }

    /// The node agent's log is the only place its connection state is visible,
    /// so read the last line that reports one. Reading the tail rather than the
    /// file keeps this cheap as the log grows.
    private func readLink() -> Link {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return .agentNotRunning }
        defer { try? handle.close() }
        let tailBytes = 16 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else {
            return .unknown
        }
        for line in text.split(separator: "\n").reversed() {
            if line.contains("gateway connected") {
                let gateway = line.split(separator: " ").last.map(String.init) ?? "the Gateway"
                return .connected(gateway: gateway)
            }
            if line.contains("gateway connect failed") {
                return .disconnected(reason: "the Gateway refused the connection")
            }
            if line.contains("gateway closed") {
                return .disconnected(reason: "the connection dropped")
            }
        }
        return .unknown
    }
}
