import Foundation
import IntelligenceCore

/// Private, short-lived JPEG staging for the tool-free Tutor `agy --print`
/// transport.  `agy` expands only the relative `@capture-…jpg` reference;
/// the prompt never contains image bytes, a file URL, or a filesystem path.
struct AgyAttachmentStager {
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

    func stageTutorJPEG(_ attachment: IntelligenceAttachment) throws -> URL {
        guard attachment.mimeType == "image/jpeg", attachment.isJPEG,
              attachment.bytes.count <= 3 * 1024 * 1024,
              attachment.pixelWidth > 0, attachment.pixelHeight > 0
        else {
            throw IntelligenceFailure.unsupportedAttachment("Tutor requires one bounded JPEG attachment")
        }
        try prepare()
        let staged = workspace.appendingPathComponent("capture-\(UUID().uuidString.lowercased()).jpg")
        try attachment.bytes.write(to: staged, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
        return staged
    }

    func reference(for stagedJPEG: URL) -> String? {
        guard stagedJPEG.deletingLastPathComponent().standardizedFileURL == workspace.standardizedFileURL,
              stagedJPEG.lastPathComponent.range(of: "^capture-[a-f0-9-]{36}\\.jpg$", options: .regularExpression) != nil
        else { return nil }
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
}
