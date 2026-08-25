import CallaContracts
import Darwin
import Foundation

/// Owner-only request/reply Unix socket. JSON archive files remain recovery
/// records; live start/release/stop/snapshot traffic never waits for polling.
public final class CallHostControlChannel: @unchecked Sendable {
    public typealias Handler = @Sendable (CallHostCommand) async -> CallHostEvent

    private let path: URL
    private var descriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    public init(path: URL = CallHostPaths.socketFile) { self.path = path }

    deinit { stop() }

    public func start(handler: @escaping Handler) throws {
        try CallHostPaths.ensureRoot()
        CallHostPaths.remove(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENFILE) }
        descriptor = fd
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let maximumPathLength = MemoryLayout.size(ofValue: address.sun_path) - 1
        path.path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                let destination = UnsafeMutableRawPointer(destination).assumingMemoryBound(to: CChar.self)
                strncpy(destination, source, maximumPathLength)
            }
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(fd, 8) == 0 else {
            let error = errno
            Darwin.close(fd); descriptor = -1
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EINVAL)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        acceptTask = Task.detached(priority: .userInitiated) {
            while !Task.isCancelled {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                Task.detached {
                    defer { Darwin.close(client) }
                    guard let command = Self.read(CallHostCommand.self, from: client) else { return }
                    let event = await handler(command)
                    Self.write(event, to: client)
                }
            }
        }
    }

    public func stop() {
        acceptTask?.cancel(); acceptTask = nil
        if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
        CallHostPaths.remove(path)
    }

    private static func read<T: Decodable>(_ type: T.Type, from fd: Int32) -> T? {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 64 * 1024 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count > 0 { data.append(buffer, count: Int(count)); continue }
            if count == 0 { break }
            if errno == EINTR { continue }
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to fd: Int32) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        _ = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
    }
}
