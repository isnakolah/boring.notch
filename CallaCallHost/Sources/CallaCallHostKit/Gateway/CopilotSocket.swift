import Foundation
import os.log

private let socketLog = Logger(subsystem: "theboringteam.boringnotch.callhost", category: "gateway")

/// Frames on the wire to the gateway plugin.
///
/// Mirrors `apps/call-copilot/integrations/openclaw/src/protocol.mjs`. The
/// gateway validates every field and answers a bad frame with an `error` rather
/// than dropping the call, but it is cheaper to be correct here.
public enum CopilotFrame {
    public struct Suggestion: Codable, Sendable, Equatable {
        public var callID: String
        public var afterSeq: Int
        public var headline: String
        public var angles: [String]
        public var confirm: [String]
        /// Where the conversation has got to. Sent on every reply, including
        /// the ones with no headline — between questions it is the only thing
        /// the panel has to show, and a blank panel is worse than a plain one.
        public var summary: String = ""
        /// Raised and not yet resolved, most likely to be turned back on you
        /// first. Ranks below a live headline, above the summary.
        public var openQuestions: [String] = []
        public var latencyMs: Int

        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case afterSeq = "after_seq"
            case headline
            case angles
            case confirm
            case summary
            case openQuestions = "open_questions"
            case latencyMs = "latency_ms"
        }

        /// Hand-written because a synthesized one demands every key.
        ///
        /// The property defaults above are *not* consulted by the synthesized
        /// decoder — a missing `summary` makes the whole frame throw, and one
        /// throw here drops the suggestion entirely. `summary` and
        /// `open_questions` were added to this struct after the gateway release
        /// that is deployed, so every suggestion from it failed to decode and
        /// the copilot returned nothing at all. A newer app has to tolerate an
        /// older gateway; only the fields a suggestion is meaningless without
        /// are required.
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            callID = try container.decode(String.self, forKey: .callID)
            afterSeq = try container.decode(Int.self, forKey: .afterSeq)
            headline = try container.decodeIfPresent(String.self, forKey: .headline) ?? ""
            angles = try container.decodeIfPresent([String].self, forKey: .angles) ?? []
            confirm = try container.decodeIfPresent([String].self, forKey: .confirm) ?? []
            summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
            openQuestions = try container.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
            latencyMs = try container.decodeIfPresent(Int.self, forKey: .latencyMs) ?? 0
        }

        public init(
            callID: String,
            afterSeq: Int,
            headline: String,
            angles: [String] = [],
            confirm: [String] = [],
            summary: String = "",
            openQuestions: [String] = [],
            latencyMs: Int = 0
        ) {
            self.callID = callID
            self.afterSeq = afterSeq
            self.headline = headline
            self.angles = angles
            self.confirm = confirm
            self.summary = summary
            self.openQuestions = openQuestions
            self.latencyMs = latencyMs
        }
    }

    case ready(persona: String)
    case ack(seq: Int)
    case suggestion(Suggestion)
    case error(code: String, message: String)
}

/// Persistent websocket to the gateway's `/call-copilot/stream` route.
///
/// One connection per call: the Mac reconnects when a call starts, so a dropped
/// socket is unambiguously the end of that call's session rather than a state to
/// reconcile.
public actor CopilotSocket {
    public enum Failure: Swift.Error, LocalizedError {
        case notConnected

        public var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected to the Calla gateway"
            }
        }
    }

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private let encoder = JSONEncoder()

    public var onSuggestion: ((CopilotFrame.Suggestion) -> Void)?
    public var onError: ((String, String) -> Void)?
    public var onClose: (() -> Void)?

    public private(set) var connected = false

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
        encoder.outputFormatting = [.sortedKeys]
    }

    public func setHandlers(
        onSuggestion: @escaping (CopilotFrame.Suggestion) -> Void,
        onError: ((String, String) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.onSuggestion = onSuggestion
        self.onError = onError
        self.onClose = onClose
    }

    public func connect() {
        guard task == nil else { return }
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        connected = true
        socketLog.notice("connecting to \(self.url.absoluteString, privacy: .public)")

        receiveLoop = Task { [weak self] in await self?.receive() }
        // The gateway route sits behind Tailscale Serve; an idle connection can
        // be reaped by an intermediary long before a quiet stretch of call ends.
        keepAlive = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await self?.ping()
            }
        }
    }

    public func startCall(callID: String,
                          persona: String,
                          startedAt: Date,
                          profile: CallProfile? = nil) async throws {
        var frame: [String: Any] = [
            "v": 1,
            "type": "call_start",
            "call_id": callID,
            "persona": persona,
            "started_at": Int(startedAt.timeIntervalSince1970),
        ]
        // Sent once, at the top of the call. The gateway keeps it for the life
        // of the session and puts it in the cached prompt prefix, so carrying
        // it per turn would only defeat that cache.
        if let profile {
            var fields: [String: Any] = [:]
            if let about = profile.about { fields["about"] = about }
            if let persona = profile.personaGuidance { fields["persona_guidance"] = persona }
            if let base = profile.baseGuidance { fields["base_guidance"] = base }
            if !fields.isEmpty { frame["profile"] = fields }
        }
        try await send(frame)
    }

    public func send(turn: CallTurn, callID: String) async throws {
        try await send([
            "v": 1,
            "type": "turn",
            "call_id": callID,
            "seq": turn.seq,
            "source": turn.source.rawValue,
            "t0": turn.t0,
            "t1": turn.t1,
            "text": turn.text,
        ])
    }

    public func endCall(callID: String) async throws {
        try await send(["v": 1, "type": "call_end", "call_id": callID])
    }

    public func disconnect() {
        receiveLoop?.cancel()
        keepAlive?.cancel()
        receiveLoop = nil
        keepAlive = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        connected = false
    }

    // MARK: - Internal

    private func send(_ payload: [String: Any]) async throws {
        guard let task else { throw Failure.notConnected }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.notConnected }
        try await task.send(.string(text))
    }

    private func ping() {
        task?.sendPing { error in
            if let error {
                socketLog.error("ping failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func receive() async {
        while !Task.isCancelled, let task {
            do {
                let message = try await task.receive()
                switch message {
                case .string(let text): handle(text: text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { handle(text: text) }
                @unknown default: break
                }
            } catch {
                if !Task.isCancelled {
                    socketLog.error("receive failed: \(error.localizedDescription, privacy: .public)")
                }
                connected = false
                onClose?()
                return
            }
        }
    }

    private func handle(text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            socketLog.error("unparseable frame from gateway")
            return
        }

        switch type {
        case "suggestion":
            do {
                onSuggestion?(try JSONDecoder().decode(CopilotFrame.Suggestion.self, from: data))
            } catch {
                // The error itself, not just the fact of one. This decode is the
                // seam between the Swift and Node halves, and a bare "did not
                // decode" turns a one-line field-name drift into a hunt.
                socketLog.error("""
                    suggestion frame did not decode: \(String(describing: error), privacy: .public) \
                    — keys: \(object.keys.sorted().joined(separator: ","), privacy: .public)
                    """)
            }
        case "error":
            let code = object["code"] as? String ?? "error"
            let message = object["message"] as? String ?? ""
            socketLog.error("gateway error \(code, privacy: .public): \(message, privacy: .public)")
            onError?(code, message)
        case "ready", "ack":
            break
        default:
            socketLog.notice("ignoring unknown frame type \(type, privacy: .public)")
        }
    }
}
