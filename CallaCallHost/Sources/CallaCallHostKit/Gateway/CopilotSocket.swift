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
        public var latencyMs: Int

        enum CodingKeys: String, CodingKey {
            case callID = "call_id"
            case afterSeq = "after_seq"
            case headline
            case angles
            case confirm
            case latencyMs = "latency_ms"
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

    public func startCall(callID: String, persona: String, startedAt: Date) async throws {
        try await send([
            "v": 1,
            "type": "call_start",
            "call_id": callID,
            "persona": persona,
            "started_at": Int(startedAt.timeIntervalSince1970),
        ])
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
            guard let suggestion = try? JSONDecoder().decode(CopilotFrame.Suggestion.self, from: data) else {
                socketLog.error("suggestion frame did not decode")
                return
            }
            onSuggestion?(suggestion)
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
