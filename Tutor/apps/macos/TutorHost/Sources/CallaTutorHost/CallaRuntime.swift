import Foundation

/// Boring owns every new Tutor runtime file. This source is compiled only into
/// Boring's private runtime; it never reads or imports the retired Calla app
/// container. `CALLA_RUNTIME_ROOT` is set by BoringCallaEngine before launch.
enum CallaRuntime {
    struct ActiveLesson: Codable {
        let courseID: String
        let lessonID: String
        let lessonTitle: String
        let active: Bool

        enum CodingKeys: String, CodingKey { case courseID = "course_id", lessonID = "lesson_id", lessonTitle = "lesson_title", active }
    }
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
    /// Permission state as seen by the process that actually captures. The
    /// engine cannot answer this for itself: `CGPreflightScreenCaptureAccess`
    /// in the XPC service reports the service's own grant, not this host's.
    /// Metadata only — never a capture, coordinates, or a window title.
    struct HostStatus: Codable {
        let screenRecordingGranted: Bool
        let accessibilityGranted: Bool
        let captureActive: Bool
        let updatedAt: Date

        enum CodingKeys: String, CodingKey {
            case screenRecordingGranted = "screen_recording_granted"
            case accessibilityGranted = "accessibility_granted"
            case captureActive = "capture_active"
            case updatedAt = "updated_at"
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

    /// Boring's private log directory, written by BoringCallaEngine's child
    /// stdio redirection. The retired `~/Library/Logs/Calla` is shared with the
    /// legacy install, where two hosts' lines were indistinguishable.
    static var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    static func log(_ name: String) -> URL { logs.appendingPathComponent(name) }

    /// Atomic, owner-only receipt write. Shared by every `record*` below so a
    /// half-written file can never be read as authoritative state.
    private static func writeReceipt<Value: Encodable>(_ value: Value, to destination: URL) {
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent)-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
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

    /// Written by `TutorSettings.refreshPermissionStatus`, read by the engine.
    /// Deliberately a file and not a socket operation: the engine polls status
    /// every 2-4s, and a socket round trip would block on this host's main
    /// actor, which a lesson turn holds for tens of seconds.
    static func recordHostStatus(screenRecordingGranted: Bool, accessibilityGranted: Bool, captureActive: Bool) {
        writeReceipt(HostStatus(screenRecordingGranted: screenRecordingGranted,
                                accessibilityGranted: accessibilityGranted,
                                captureActive: captureActive,
                                updatedAt: Date()),
                     to: file("host-status.json"))
    }

    /// Gateway-to-node capability proof. Boring reads this bounded receipt to
    /// show a real paired-node status; no model-visible operation writes it.
    static func recordCapabilityHandshake(engineBuild: String, nodeContractHash: String) {
        writeReceipt(CapabilityHandshake(engineBuild: engineBuild,
                                         nodeContractHash: nodeContractHash,
                                         receivedAt: Date()),
                     to: file("capability-handshake.json"))
    }

    /// Boring reads this tiny state receipt for its own notch and Settings UI.
    /// It contains route identity only—never a capture, coordinates, prompt, or
    /// model response.
    static func recordActiveLesson(courseID: String, lessonID: String, lessonTitle: String) {
        let destination = file("active-lesson.json")
        let value = ActiveLesson(courseID: courseID, lessonID: lessonID,
                                 lessonTitle: String(lessonTitle.prefix(160)), active: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: destination, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    static func clearActiveLesson() {
        try? FileManager.default.removeItem(at: file("active-lesson.json"))
    }
}
