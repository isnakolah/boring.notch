import Foundation

/// A brain the layer can ask for a completion.
///
/// Conform, declare which tasks you support and a `ModelCatalog`, register with
/// the router. Nothing else in the layer needs to know you exist.
public protocol IntelligenceProvider: Actor {
    nonisolated var kind: ProviderKind { get }

    /// Tasks whose contract and conversation policy this provider can honour.
    /// The Gateway, for instance, speaks only the copilot's wire protocol.
    nonisolated func supports(_ task: IntelligenceTask) -> Bool

    /// Declared independently from task support: a provider can answer a Tutor
    /// request but still be ineligible when it cannot safely accept its image.
    nonisolated var attachmentCapability: AttachmentCapability { get }

    /// Cheap and cached. Called before every routing decision, so it must not
    /// spawn a process on each call.
    func availability() async -> Availability

    func respond(to request: IntelligenceRequest) async throws -> IntelligenceResponse

    /// Providers that cannot stream should emit one `.text` then `.done`.
    func stream(_ request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceDelta, Error>

    /// Release whatever the session held: a conversation id, a resident process,
    /// a websocket.
    func closeSession(_ sessionKey: String) async
}

public extension IntelligenceProvider {
    nonisolated var attachmentCapability: AttachmentCapability { .none }
    /// Default streaming shim for providers with no incremental transport.
    func stream(_ request: IntelligenceRequest) -> AsyncThrowingStream<IntelligenceDelta, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let response = try await respond(to: request)
                    continuation.yield(.text(response.text))
                    continuation.yield(.done(response))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
