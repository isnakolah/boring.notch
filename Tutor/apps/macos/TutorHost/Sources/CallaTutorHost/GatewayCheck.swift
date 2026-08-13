import Foundation

/// Read-only Gateway readiness probe. It uses existing private SSH route and
/// reports only booleans; no prompt, screen data, logs, or credentials travel.
@MainActor
final class GatewayCheck: ObservableObject {
    static let shared = GatewayCheck()

    struct Result: Decodable {
        let ok: Bool
        let gateway: Bool?
        let plugin: Bool?
        let courseControl: Bool?
        let summary: String
        enum CodingKeys: String, CodingKey {
            case ok, gateway, plugin, summary
            case courseControl = "course_control"
        }
    }

    @Published private(set) var running = false
    @Published private(set) var result: Result?
    @Published private(set) var failure: String?

    func run() {
        guard !running, let script = Self.scriptURL() else { failure = "Could not find Gateway check beside Calla."; return }
        running = true; result = nil; failure = nil
        let task = Process(); task.executableURL = script
        let output = Pipe(); task.standardOutput = output; task.standardError = output
        task.terminationHandler = { process in
            let data = output.fileHandleForReading.readDataToEndOfFile()
            Task { @MainActor in
                GatewayCheck.shared.running = false
                guard process.terminationStatus == 0,
                      let result = try? JSONDecoder().decode(Result.self, from: data) else {
                    GatewayCheck.shared.failure = "Could not reach private Gateway. Check Tailscale, then try again."
                    return
                }
                GatewayCheck.shared.result = result
            }
        }
        do { try task.run() } catch { running = false; failure = "Gateway check could not start." }
    }

    private static func scriptURL() -> URL? {
        if let resource = Bundle.main.url(forResource: "calla-gateway-check", withExtension: "sh") { return resource }
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<7 {
            let candidate = directory.appendingPathComponent("scripts/calla-gateway-check.sh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }
}
