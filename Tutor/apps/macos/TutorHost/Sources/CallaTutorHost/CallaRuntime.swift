import Foundation

/// Boring owns every new Tutor runtime file. This source is compiled only into
/// Boring's private runtime; it never reads or imports the retired Calla app
/// container. `CALLA_RUNTIME_ROOT` is set by BoringCallaEngine before launch.
enum CallaRuntime {
    struct CapabilityHandshake: Codable {
        let engineBuild: String
        let nodeContractHash: String
        let receivedAt: Date

        enum CodingKeys: String, CodingKey {
            case engineBuild = "engine_build"
            case nodeContractHash = "node_contract_hash"
            case receivedAt = "received_at"
        }
    }

    static let root: URL = {
        let fallback = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/boringNotch/Calla", isDirectory: true)
        guard let value = ProcessInfo.processInfo.environment["CALLA_RUNTIME_ROOT"],
              value.hasPrefix("/"), !value.contains("..") else { return fallback }
        return URL(fileURLWithPath: value, isDirectory: true).standardizedFileURL
    }()

    static var preferencesFile: URL { root.appendingPathComponent("engine-preferences.json") }

    static func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    static func cache(_ name: String) -> URL {
        root.appendingPathComponent("cache", isDirectory: true).appendingPathComponent(name)
    }

    /// Gateway-to-node capability proof. Boring reads this bounded receipt to
    /// show a real paired-node status; no model-visible operation writes it.
    static func recordCapabilityHandshake(engineBuild: String, nodeContractHash: String) {
        let destination = file("capability-handshake.json")
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".capability-handshake-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let value = CapabilityHandshake(engineBuild: engineBuild, nodeContractHash: nodeContractHash, receivedAt: Date())
            try JSONEncoder().encode(value).write(to: temporary, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary,
                                                          backupItemName: nil, options: [])
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }
}
