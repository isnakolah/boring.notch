import Foundation

final class SweepServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = SweepService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: SweepServiceProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = SweepServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
