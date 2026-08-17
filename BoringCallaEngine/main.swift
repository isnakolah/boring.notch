import Foundation

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let engine = BoringCallaEngine()
        connection.exportedInterface = NSXPCInterface(with: BoringCallaEngineProtocol.self)
        connection.exportedObject = engine
        // A quit, a force quit and a crash all end the same way from here: the
        // connection dies. Without this, whatever the engine started — the call
        // host holding the microphone, a resident `agy` language server holding
        // ~190MB — is reparented to launchd and runs until the machine restarts.
        connection.invalidationHandler = { engine.shutdownEverything() }
        connection.interruptionHandler = { engine.shutdownEverything() }
        connection.resume()
        return true
    }
}

private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
