import Darwin
import Foundation

/// Private Gateway-node ingress. This is deliberately a tiny transport: it
/// accepts one bounded JSON frame, verifies same-user peer plus per-launch
/// capability token, then gives Engine a byte payload. It knows nothing about
/// lessons, providers, captures, or persistence.
final class TutorEngineIngress {
    static let maximumFrameBytes = 64 * 1024

    private let path: String
    private let expectedUID: uid_t
    private let handler: @Sendable (Data) -> Data
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    init(path: String, expectedUID: uid_t = getuid(), handler: @escaping @Sendable (Data) -> Data) {
        self.path = path
        self.expectedUID = expectedUID
        self.handler = handler
    }

    deinit { stop() }

    func start() throws {
        let parent = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IngressError.socket("create") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8.count + 1
        guard bytes <= MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw IngressError.socket("path") }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { strncpy($0, source, bytes) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sa_family_t>.size + bytes))
            }
        }
        guard bound == 0 else { close(fd); throw IngressError.socket("bind") }
        guard chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); throw IngressError.socket("listen") }
        descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel(); source = nil; descriptor = -1; _ = unlink(path)
    }

    private func acceptConnection() {
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { return }
        var on: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let handler = handler
        let expectedUID = expectedUID
        DispatchQueue.global(qos: .userInitiated).async {
            defer { close(client) }
            guard Self.peerUID(client) == expectedUID else {
                Self.write(Self.error("unauthorized_peer", "Engine ingress requires same-user peer"), to: client)
                return
            }
            do {
                let request = try Self.read(from: client)
                let response = handler(request)
                guard response.count <= Self.maximumFrameBytes else {
                    Self.write(Self.error("response_limit", "Engine ingress response exceeds limit"), to: client)
                    return
                }
                Self.write(response, to: client)
            } catch let error as IngressError {
                Self.write(Self.error(error.code, error.localizedDescription), to: client)
            } catch {
                Self.write(Self.error("invalid_frame", "Engine ingress rejected request"), to: client)
            }
        }
    }

    private static func peerUID(_ descriptor: Int32) -> uid_t? {
        var uid: uid_t = 0; var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 ? uid : nil
    }

    private static func read(from descriptor: Int32) throws -> Data {
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maximumFrameBytes {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { throw IngressError.socket("read") }
            if count == 0 { break }
            data.append(buffer, count: count)
            if data.last == 0x0A { break }
        }
        guard data.count > 0, data.count <= maximumFrameBytes, data.last == 0x0A else { throw IngressError.frame }
        data.removeLast()
        guard String(data: data, encoding: .utf8) != nil else { throw IngressError.frame }
        return data
    }

    private static func write(_ data: Data, to descriptor: Int32) {
        var frame = data; frame.append(0x0A)
        frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < frame.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private static func error(_ code: String, _ message: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["ok": false, "code": code, "message": message], options: [.sortedKeys])) ?? Data("{\"ok\":false}".utf8)
    }

    private enum IngressError: LocalizedError {
        case socket(String), frame
        var code: String { switch self { case .socket: "socket_error"; case .frame: "frame_limit" } }
        var errorDescription: String? {
            switch self { case .socket(let stage): "Engine ingress socket \(stage) failed"; case .frame: "Engine ingress requires one UTF-8 frame under 64 KiB" }
        }
    }
}
