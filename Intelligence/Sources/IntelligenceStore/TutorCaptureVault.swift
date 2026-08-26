import CryptoKit
import Foundation

/// File-system half of persistent Tutor captures. SQLite stores only a random
/// relative ciphertext path and metadata. Plaintext exists only in caller memory
/// and in a random temporary file during the atomic write.
public struct TutorCaptureVault {
    public struct StoredCapture: Sendable, Equatable {
        public let id: String
        public let relativePath: String
        public let ciphertextDigest: String
        public let byteCount: Int
    }

    public enum Failure: Error, Equatable, Sendable, LocalizedError {
        case invalidJPEG
        case tooLarge
        case missingCapture
        case unreadableCiphertext
        case unsafePath

        public var errorDescription: String? {
            switch self {
            case .invalidJPEG: "Tutor capture is not a JPEG"
            case .tooLarge: "Tutor capture exceeds 3 MiB"
            case .missingCapture: "Tutor capture is unavailable"
            case .unreadableCiphertext: "Tutor capture cannot be decrypted"
            case .unsafePath: "Tutor capture path is invalid"
            }
        }
    }

    private let root: URL
    private let key: SymmetricKey
    private let fileManager: FileManager

    public init(root: URL, key: SymmetricKey, fileManager: FileManager = .default) throws {
        self.root = root.standardizedFileURL
        self.key = key
        self.fileManager = fileManager
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }

    public func storeJPEG(_ jpeg: Data, id: String = UUID().uuidString.lowercased()) throws -> StoredCapture {
        guard jpeg.count <= 3 * 1024 * 1024 else { throw Failure.tooLarge }
        guard Self.isJPEG(jpeg) else { throw Failure.invalidJPEG }
        let safeID = id.replacingOccurrences(of: "-", with: "")
        guard safeID.range(of: "^[A-Za-z0-9]{16,64}$", options: .regularExpression) != nil else { throw Failure.unsafePath }
        let relative = "\(safeID).aesgcm"
        let destination = root.appendingPathComponent(relative)
        let temporary = root.appendingPathComponent(".\(safeID).\(UUID().uuidString).tmp")
        let ciphertext: Data
        do {
            ciphertext = try AES.GCM.seal(jpeg, using: key).combined ?? { throw Failure.unreadableCiphertext }()
        } catch let error as Failure { throw error }
        catch { throw Failure.unreadableCiphertext }
        do {
            try ciphertext.write(to: temporary, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // Atomic rename: no reader can observe a partial ciphertext.
            try fileManager.moveItem(at: temporary, to: destination)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
        return StoredCapture(id: id, relativePath: relative, ciphertextDigest: Self.digest(ciphertext), byteCount: ciphertext.count)
    }

    public func readJPEG(relativePath: String) throws -> Data {
        let file = try resolve(relativePath)
        guard fileManager.fileExists(atPath: file.path) else { throw Failure.missingCapture }
        do {
            let combined = try Data(contentsOf: file, options: .mappedIfSafe)
            let box = try AES.GCM.SealedBox(combined: combined)
            return try AES.GCM.open(box, using: key)
        } catch { throw Failure.unreadableCiphertext }
    }

    /// Deletes only a write that did not gain a database reference. No history
    /// UI calls this; engine recovery uses it after a failed DB transaction.
    public func removeUncommitted(relativePath: String) {
        guard let file = try? resolve(relativePath) else { return }
        try? fileManager.removeItem(at: file)
    }

    public func removeTemporaryFiles() {
        guard let items = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix(".") && item.pathExtension == "tmp" {
            try? fileManager.removeItem(at: item)
        }
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func resolve(_ relativePath: String) throws -> URL {
        guard relativePath.range(of: "^[A-Za-z0-9]+\\.aesgcm$", options: .regularExpression) != nil else { throw Failure.unsafePath }
        let result = root.appendingPathComponent(relativePath).standardizedFileURL
        guard result.deletingLastPathComponent() == root else { throw Failure.unsafePath }
        return result
    }

    private static func isJPEG(_ data: Data) -> Bool {
        data.count >= 4 && data.starts(with: [0xFF, 0xD8, 0xFF]) && data.suffix(2) == Data([0xFF, 0xD9])
    }
}
