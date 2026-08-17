import Foundation

/// Finds the `agy` binary.
///
/// Internal only, never user-supplied — the same principle as the copilot's
/// fixed Gateway URL: a transcript must not be steerable to an arbitrary
/// executable. A GUI app inherits a minimal `PATH`, so the well-known install
/// locations are checked directly before falling back to a login shell.
public enum AgyLocator {
    public static let knownPaths = [
        "~/.local/bin/agy",
        "/opt/homebrew/bin/agy",
        "/usr/local/bin/agy",
    ]

    public static func locate() -> String? {
        for candidate in knownPaths {
            let path = (candidate as NSString).expandingTildeInPath
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return viaLoginShell()
    }

    /// Last resort: ask the user's own shell where `agy` is. One process, cached
    /// by the caller.
    private static func viaLoginShell() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "command -v agy"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// `agy --version`, for the Settings row. Cheap, but still a process — the
    /// provider caches it.
    public static func version(of binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
