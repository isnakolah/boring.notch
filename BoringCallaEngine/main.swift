import Foundation

private final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: BoringCallaEngineProtocol.self)
        connection.exportedObject = BoringCallaEngine()
        connection.resume()
        return true
    }
}

private let delegate = ServiceDelegate()
private let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
