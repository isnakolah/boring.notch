import Foundation

/// Protocol for JSON-RPC transport - abstracts the stdin/stdout communication.
protocol RPCTransport: Sendable {
    /// Sends a JSON-RPC message.
    func send(_ data: Data) throws

    /// Receives the next JSON-RPC message.
    func receive() async throws -> Data

    /// Closes the transport.
    func close()
}
