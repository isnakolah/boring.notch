import Foundation

/// Private, short-lived attachment staging for Tutor's local `agy --print`
/// route.  `agy` resolves `@relative-name` itself; the model never receives a
/// file URL, filesystem path, tool permission, or image bytes in prompt text.
struct TutorAgyAttachmentStager {
    let workspace: URL
    private let manager: FileManager

    init(workspace: URL, manager: FileManager = .default) {
        self.workspace = workspace
        self.manager = manager
    }

    func prepare() throws {
        try manager.createDirectory(at: workspace, withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: workspace.path)
        cleanup()
    }

    func stageJPEG(_ data: Data) throws -> URL {
        guard data.count >= 4, data.starts(with: [0xFF, 0xD8, 0xFF]), data.suffix(2) == Data([0xFF, 0xD9]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try prepare()
        let destination = workspace.appendingPathComponent("capture-\(UUID().uuidString.lowercased()).jpg")
        try data.write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }

    func attachmentReference(for stagedJPEG: URL) -> String? {
        guard stagedJPEG.deletingLastPathComponent().standardizedFileURL == workspace.standardizedFileURL,
              stagedJPEG.lastPathComponent.range(of: "^capture-[a-f0-9-]{36}\\.jpg$", options: .regularExpression) != nil else {
            return nil
        }
        return "@\(stagedJPEG.lastPathComponent)"
    }

    func cleanup(_ stagedJPEG: URL? = nil) {
        if let stagedJPEG {
            try? manager.removeItem(at: stagedJPEG)
            return
        }
        guard let names = try? manager.contentsOfDirectory(atPath: workspace.path) else { return }
        for name in names where name.range(of: "^capture-[a-f0-9-]{36}\\.jpg$", options: .regularExpression) != nil {
            try? manager.removeItem(at: workspace.appendingPathComponent(name))
        }
    }

    /// Only suitable for diagnostics.  Never include prompt, path, filename,
    /// base64, or JPEG bytes in logs.
    static let safeInvocationDescription = "agy --print [Tutor JPEG attachment]"
}
