import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

private struct Preferences: Codable, Equatable {
    let captureEnabled: Bool
    let allowedBundleIDs: [String]
    let captureLongEdge: Int
    let tooltipWidth: Int
    let hideTooltipOnHover: Bool
    let cursorSize: Int
    let tooltipOpacity: Double
    let showStatusHUD: Bool
    let learnerID: String
    let hiddenCourseIDs: [String]
}

private struct Status: Codable {
    var running = false
    var socketPath = ""
    var screenRecordingGranted = false
    var accessibilityGranted = false
    var gatewayReachable = false
    var nodeConnected = false
    var releaseVersion: String? = nil
    var previousGatewayRelease: String? = nil
    var lastGatewayUpdate: String? = nil
    var lastGatewayUpdateAt: Date? = nil
    var engineBuild: String? = nil
    var lastResult = "Engine not started"
    var courses: [CourseSummary] = []
}

private struct CourseSummary: Codable {
    let id: String
    let title: String
    let summary: String
    let lessonCount: Int

    enum CodingKeys: String, CodingKey { case id, title, summary; case lessonCount = "lesson_count" }
}

private struct CatalogueCourse: Decodable {
    let id: String
    let title: String
    let summary: String
    let lessons: [CatalogueLesson]
}

private struct CatalogueLesson: Decodable { let id: String }

private struct CapabilityHandshake: Decodable {
    let engineBuild: String
    let nodeContractHash: String
    let receivedAt: Date

    enum CodingKeys: String, CodingKey {
        case engineBuild = "engine_build"
        case nodeContractHash = "node_contract_hash"
        case receivedAt = "received_at"
    }
}

/// Boring keeps a bounded local summary of each private Gateway transaction so
/// Settings can show result after the XPC process restarts. Gateway remains
/// authoritative for full receipts under its release root.
private struct GatewayUpdateRecord: Codable {
    let currentRelease: String?
    let previousRelease: String?
    let summary: String
    let completedAt: Date

    enum CodingKeys: String, CodingKey {
        case currentRelease = "current_release"
        case previousRelease = "previous_release"
        case summary
        case completedAt = "completed_at"
    }
}

/// Privileged Tutor process. Preferences arrive as complete snapshots from
/// Boring UI; this process never reads Boring or legacy Calla preferences.
final class BoringCallaEngine: NSObject, BoringCallaEngineProtocol {
    private let queue = DispatchQueue(label: "theboringteam.boringnotch.calla-engine")
    private let fileManager = FileManager.default
    private var preferences: Preferences?
    private var isRunning = false
    private var lastResult = "Engine not started"
    private var runtime: Process?
    private var nodeRuntime: Process?
    private var gatewayUpdate: Process?
    private var gatewayReachable = false
    private var gatewayMonitor: DispatchSourceTimer?

    private var root: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("boringNotch/Calla", isDirectory: true)
    }

    private var socketURL: URL { root.appendingPathComponent("tutor-host.sock") }
    private var runtimePIDURL: URL { root.appendingPathComponent("runtime.pid") }
    private var nodePIDURL: URL { root.appendingPathComponent("node.pid") }

    func start(with reply: @escaping (Data) -> Void) {
        queue.async {
            NSLog("[CallaEngine] start requested")
            do {
                let wasRunning = self.isRunning
                try self.prepareRuntimeDirectories()
                self.restorePreferences()
                self.reclaimStaleOwnedChildren()
                try self.startRuntime()
                try self.startNodeRuntime()
                self.startGatewayMonitor()
                self.isRunning = true
                self.lastResult = "Engine ready; Tutor runtime and Calla Mac node starting"
                if self.isInstalledBoringApp, !wasRunning {
                    self.requestGatewayUpdate(trigger: "launch")
                }
                NSLog("[CallaEngine] runtime launched")
            } catch {
                self.isRunning = false
                self.lastResult = "Engine startup failed: \(error.localizedDescription)"
                NSLog("[CallaEngine] startup failed: %@", error.localizedDescription)
            }
            reply(self.encodedStatus())
        }
    }

    func stop(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.stopGatewayMonitor()
            if let runtime = self.runtime { self.terminateProcessTree(runtime.processIdentifier) }
            self.runtime = nil
            self.clearOwnedPID(at: self.runtimePIDURL)
            if let nodeRuntime = self.nodeRuntime { self.terminateProcessTree(nodeRuntime.processIdentifier) }
            self.nodeRuntime = nil
            self.clearOwnedPID(at: self.nodePIDURL)
            self.gatewayReachable = false
            self.isRunning = false
            self.lastResult = "Engine stopped"
            reply(self.encodedStatus())
        }
    }

    func applyPreferences(_ data: Data, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard let decoded = try? JSONDecoder().decode(Preferences.self, from: data) else {
                self.lastResult = "Rejected invalid preference snapshot"
                reply(self.encodedStatus())
                return
            }
            guard [1024, 1600, 2048].contains(decoded.captureLongEdge),
                  [300, 340, 380, 440, 520].contains(decoded.tooltipWidth),
                  [24, 30, 38].contains(decoded.cursorSize),
                  (0.5...1.0).contains(decoded.tooltipOpacity),
                  decoded.allowedBundleIDs.allSatisfy({ !$0.isEmpty }),
                  decoded.hiddenCourseIDs.allSatisfy({ !$0.isEmpty }),
                  decoded.learnerID.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil else {
                self.lastResult = "Rejected invalid preference values"
                reply(self.encodedStatus())
                return
            }
            self.preferences = decoded
            do {
                try self.writePreferences(decoded)
            } catch {
                self.lastResult = "Could not persist preference snapshot: \(error.localizedDescription)"
                reply(self.encodedStatus())
                return
            }
            self.lastResult = self.isRunning ? "Live preference snapshot applied" : "Preferences saved for engine start"
            reply(self.encodedStatus())
        }
    }

    func status(with reply: @escaping (Data) -> Void) {
        queue.async { reply(self.encodedStatus()) }
    }

    func requestGatewayUpdate(with reply: @escaping (Data) -> Void) {
        queue.async {
            guard self.isInstalledBoringApp else {
                self.lastResult = "Debug Gateway updates stage from Xcode build"
                reply(self.encodedStatus())
                return
            }
            self.requestGatewayUpdate(trigger: "manual retry")
            reply(self.encodedStatus())
        }
    }

    func requestScreenRecording(with reply: @escaping (Data) -> Void) {
        queue.async {
            // This request must originate in the executable that owns capture.
            // Selecting an embedded XPC bundle in System Settings does not make
            // it the TCC client on current macOS.
            self.invokeRuntime(operation: "request_screen_recording", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func requestAccessibility(with reply: @escaping (Data) -> Void) {
        queue.async {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            self.lastResult = "Accessibility request shown for approved action"
            reply(self.encodedStatus())
        }
    }

    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            guard courseID.range(of: "^[A-Za-z0-9._-]{1,160}$", options: .regularExpression) != nil else {
                self.lastResult = "Rejected invalid course identifier"
                reply(self.encodedStatus())
                return
            }
            self.invokeRuntime(operation: "course_start", payload: ["course_id": courseID])
            reply(self.encodedStatus())
        }
    }

    func resumeCourse(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.invokeRuntime(operation: "course_resume", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func stopLesson(with reply: @escaping (Data) -> Void) {
        queue.async {
            self.invokeRuntime(operation: "course_stop", payload: [:])
            reply(self.encodedStatus())
        }
    }

    func ask(_ text: String, with reply: @escaping (Data) -> Void) {
        queue.async {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.count <= 800 else {
                self.lastResult = "Ask needs one short question"
                reply(self.encodedStatus())
                return
            }
            self.invokeRuntime(operation: "course_ask", payload: ["text": clean])
            reply(self.encodedStatus())
        }
    }

    private func prepareRuntimeDirectories() throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in ["catalogue", "courses", "learning", "overlay", "logs", "cache"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    private func writePreferences(_ preferences: Preferences) throws {
        let destination = root.appendingPathComponent("engine-preferences.json")
        let temporary = root.appendingPathComponent(".engine-preferences-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(preferences)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    /// XPC may restart before Boring redraws Settings. Restore only the
    /// engine's own last complete Boring snapshot, never legacy Calla data.
    private func restorePreferences() {
        let file = root.appendingPathComponent("engine-preferences.json")
        guard let data = try? Data(contentsOf: file),
              let stored = try? JSONDecoder().decode(Preferences.self, from: data) else { return }
        preferences = stored
    }

    private func startRuntime() throws {
        guard runtime?.isRunning != true else { return }
        let resource = Bundle.main.resourceURL?
            .appendingPathComponent("CallaRuntime/CallaTutorHost.app/Contents/MacOS/CallaTutorHost")
        guard let executable = resource, fileManager.isExecutableFile(atPath: executable.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "CallaRuntime/CallaTutorHost.app"])
        }
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["CALLA_RUNTIME_ROOT"] = root.path
        environment["CALLA_RUNTIME_MODE"] = "boring"
        process.environment = environment
        let pidFile = runtimePIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.clearOwnedPID(at: pidFile, matching: child.processIdentifier)
                self?.isRunning = false
                self?.lastResult = "Tutor runtime stopped (status \(child.terminationStatus))"
            }
        }
        try process.run()
        runtime = process
        try writeOwnedPID(process.processIdentifier, to: runtimePIDURL)
    }

    /// Node process has no UI and never owns preferences. Its plugin location
    /// is installed by Boring's narrow runtime installer; the engine only
    /// keeps the one Boring-owned Calla Mac connection alive while Boring runs.
    private func startNodeRuntime() throws {
        guard ProcessInfo.processInfo.environment["CALLA_DISABLE_NODE"] != "1" else { return }
        guard nodeRuntime?.isRunning != true else { return }
        guard let appResources = appCallaResources(),
              fileManager.fileExists(atPath: appResources.appendingPathComponent("openclaw/openclaw.plugin.json").path),
              fileManager.isExecutableFile(atPath: appResources.appendingPathComponent("scripts/calla-node-host.sh").path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: "Calla node resources"])
        }
        let process = Process()
        process.executableURL = appResources.appendingPathComponent("scripts/calla-node-host.sh")
        process.currentDirectoryURL = appResources
        var environment = ProcessInfo.processInfo.environment
        // Fixed private Tailscale Serve route for nomonhomelab. Short DNS is
        // intentionally not used: it resolves but does not present gateway
        // TLS identity on this owner network.
        environment["CALLA_NODE_GATEWAY_HOST"] = "nomonhomelab.tailec0dca.ts.net"
        environment["CALLA_NODE_GATEWAY_PORT"] = "443"
        environment["CALLA_NODE_GATEWAY_TLS"] = "true"
        environment["CALLA_NODE_DISPLAY_NAME"] = "Calla Mac"
        environment["CALLA_RUNTIME_ROOT"] = root.path
        process.environment = environment
        let pidFile = nodePIDURL
        process.terminationHandler = { [weak self] child in
            self?.queue.async {
                self?.clearOwnedPID(at: pidFile, matching: child.processIdentifier)
                guard self?.isRunning == true else { return }
                self?.lastResult = "Calla Mac node stopped (status \(child.terminationStatus)); re-pairing will retry"
            }
        }
        try process.run()
        nodeRuntime = process
        try writeOwnedPID(process.processIdentifier, to: nodePIDURL)
    }

    private func appCallaResources() -> URL? {
        // XPC bundle lives at App/Contents/XPCServices/Engine.xpc. Production
        // and Debug both place immutable plugin resources at App/Contents/Resources/Calla.
        let xpc = Bundle.main.bundleURL
        return xpc.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Calla", isDirectory: true)
    }

    /// launchd can reclaim an XPC instance before its descendants. Reclaim
    /// only Boring-recorded PIDs; never scan or kill generic OpenClaw work.
    private func reclaimStaleOwnedChildren() {
        if runtime?.isRunning != true {
            reclaimOwnedProcess(at: runtimePIDURL)
            runtime = nil
        }
        if nodeRuntime?.isRunning != true {
            reclaimOwnedProcess(at: nodePIDURL)
            nodeRuntime = nil
        }
    }

    private func reclaimOwnedProcess(at file: URL) {
        guard let value = try? String(contentsOf: file, encoding: .utf8),
              let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 1, pid != getpid() else {
            clearOwnedPID(at: file)
            return
        }
        terminateProcessTree(pid)
        clearOwnedPID(at: file)
    }

    private func writeOwnedPID(_ pid: pid_t, to file: URL) throws {
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent)-\(UUID().uuidString)")
        guard let data = "\(pid)\n".data(using: .utf8) else { return }
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: file.path) {
            _ = try fileManager.replaceItemAt(file, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: file)
        }
    }

    private func clearOwnedPID(at file: URL, matching pid: pid_t? = nil) {
        if let pid,
           let value = try? String(contentsOf: file, encoding: .utf8),
           value.trimmingCharacters(in: .whitespacesAndNewlines) != "\(pid)" { return }
        try? fileManager.removeItem(at: file)
    }

    private func terminateProcessTree(_ pid: pid_t) {
        guard pid > 1, pid != getpid() else { return }
        for descendant in childProcesses(of: pid).reversed() { Darwin.kill(descendant, SIGTERM) }
        Darwin.kill(pid, SIGTERM)
    }

    private func childProcesses(of rootPID: pid_t) -> [pid_t] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid="]
        process.standardOutput = output
        guard (try? process.run()) != nil else { return [] }
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else { return [] }
        let parents = text.split(separator: "\n").reduce(into: [pid_t: [pid_t]]()) { result, line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return }
            result[parent, default: []].append(pid)
        }
        func descendants(_ parent: pid_t) -> [pid_t] {
            let children = parents[parent, default: []]
            return children + children.flatMap(descendants)
        }
        return descendants(rootPID)
    }

    private func startGatewayMonitor() {
        guard gatewayMonitor == nil else { return }
        probeGateway()
        let monitor = DispatchSource.makeTimerSource(queue: queue)
        monitor.schedule(deadline: .now() + 15, repeating: 15)
        monitor.setEventHandler { [weak self] in self?.probeGateway() }
        monitor.resume()
        gatewayMonitor = monitor
    }

    private func stopGatewayMonitor() {
        gatewayMonitor?.cancel()
        gatewayMonitor = nil
    }

    /// Fixed private Tailscale Serve route. Capability receipt separately
    /// proves Tutor contract, while this tracks current route reachability.
    private func probeGateway() {
        guard let url = URL(string: "https://nomonhomelab.tailec0dca.ts.net/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            let reachable = (response as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
            self?.queue.async { self?.gatewayReachable = reachable }
        }.resume()
    }

    private var isInstalledBoringApp: Bool {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return app.path.hasPrefix("/Applications/")
    }

    /// Installed Boring owns one immutable Gateway artifact. Debug deployment
    /// is staged by Xcode instead. This merely requests private owner-SSH
    /// update; the Gateway manifest short-circuits unchanged digests.
    private func requestGatewayUpdate(trigger: String) {
        guard gatewayUpdate?.isRunning != true else {
            lastResult = "Gateway update already running"
            return
        }
        guard let resources = appCallaResources() else {
            lastResult = "Gateway update unavailable: Calla resources missing"
            return
        }
        let script = resources.appendingPathComponent("scripts/gateway-update.sh")
        let artifact = resources.appendingPathComponent("Gateway/calla-gateway.tar.gz")
        guard fileManager.isExecutableFile(atPath: script.path), fileManager.fileExists(atPath: artifact.path) else {
            lastResult = "Gateway update unavailable: bundled release missing"
            return
        }
        let output = Pipe()
        let process = Process()
        process.executableURL = script
        process.arguments = ["--bundle", artifact.path]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] child in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.queue.async {
                self?.gatewayUpdate = nil
                self?.recordGatewayUpdate(output: text, succeeded: child.terminationStatus == 0,
                                          terminationStatus: child.terminationStatus)
            }
        }
        do {
            try process.run()
            gatewayUpdate = process
            lastResult = "Gateway update requested (\(trigger))"
        } catch {
            lastResult = "Gateway update could not start: \(error.localizedDescription)"
        }
    }

    private func invokeRuntime(operation: String, payload: [String: Any]) {
        guard isRunning, fileManager.fileExists(atPath: socketURL.path) else {
            lastResult = "Tutor runtime is still starting"
            return
        }
        let request: [String: Any] = [
            "protocol_version": 2,
            "request_id": UUID().uuidString.lowercased(),
            "operation": operation,
            "session_id": "calla-boring-ui",
            "payload": payload,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            let response = try RuntimeSocketClient.invoke(path: socketURL.path, request: data)
            guard let object = try JSONSerialization.jsonObject(with: response) as? [String: Any],
                  let ok = object["ok"] as? Bool else {
                throw TutorRuntimeError.invalidResponse
            }
            if ok {
                lastResult = (object["payload"] as? [String: Any])?["status"] as? String ?? "Tutor command complete"
            } else {
                let message = ((object["error"] as? [String: Any])?["message"] as? String) ?? "Tutor command refused"
                lastResult = message
            }
        } catch {
            lastResult = "Tutor command failed: \(error.localizedDescription)"
        }
    }

    private func recordGatewayUpdate(output: String, succeeded: Bool, terminationStatus: Int32) {
        let previous = currentGatewayUpdate()
        let marker = output.split(separator: "\n").last(where: { $0.hasPrefix("CALLA_GATEWAY_RESULT\t") })
        let fields = marker?.split(separator: "\t", omittingEmptySubsequences: false) ?? []
        let outcome = fields.count > 1 ? String(fields[1]) : ""
        let current = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : previous?.currentRelease
        let prior = fields.count > 3 && !fields[3].isEmpty ? String(fields[3]) : previous?.previousRelease
        let cleanOutput = output.split(separator: "\n")
            .filter { !$0.hasPrefix("CALLA_GATEWAY_RESULT\t") }
            .suffix(8)
            .joined(separator: "\n")
        let fallback: String
        if succeeded, outcome == "unchanged" {
            fallback = "Gateway release unchanged"
        } else if succeeded {
            fallback = "Gateway update complete"
        } else {
            fallback = "Gateway update failed: exit \(terminationStatus)"
        }
        let summary = cleanOutput.isEmpty ? fallback : cleanOutput
        let record = GatewayUpdateRecord(currentRelease: current, previousRelease: prior,
                                         summary: summary, completedAt: Date())
        do {
            try writeGatewayUpdate(record)
            lastResult = summary
        } catch {
            lastResult = "\(summary) (could not persist receipt: \(error.localizedDescription))"
        }
    }

    private func currentGatewayUpdate() -> GatewayUpdateRecord? {
        let file = root.appendingPathComponent("gateway-update.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(GatewayUpdateRecord.self, from: data)
    }

    private func writeGatewayUpdate(_ record: GatewayUpdateRecord) throws {
        let destination = root.appendingPathComponent("gateway-update.json")
        let temporary = root.appendingPathComponent(".gateway-update-\(UUID().uuidString)")
        let data = try JSONEncoder().encode(record)
        try data.write(to: temporary, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: temporary, backupItemName: nil, options: [])
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private func encodedStatus() -> Data {
        let handshake = currentCapabilityHandshake()
        let gatewayUpdate = currentGatewayUpdate()
        let hasVerifiedHandshake = handshake != nil
        let status = Status(
            running: isRunning,
            socketPath: socketURL.path,
            screenRecordingGranted: CGPreflightScreenCaptureAccess(),
            accessibilityGranted: AXIsProcessTrusted(),
            gatewayReachable: gatewayReachable,
            nodeConnected: gatewayReachable && hasVerifiedHandshake && nodeRuntime?.isRunning == true,
            releaseVersion: gatewayUpdate?.currentRelease,
            previousGatewayRelease: gatewayUpdate?.previousRelease,
            lastGatewayUpdate: gatewayUpdate?.summary,
            lastGatewayUpdateAt: gatewayUpdate?.completedAt,
            engineBuild: handshake?.engineBuild,
            lastResult: lastResult,
            courses: currentCourses()
        )
        return (try? JSONEncoder().encode(status)) ?? Data()
    }

    private func currentCourses() -> [CourseSummary] {
        let file = root.appendingPathComponent("catalogue.json")
        guard let data = try? Data(contentsOf: file),
              let courses = try? JSONDecoder().decode([CatalogueCourse].self, from: data) else { return [] }
        let hidden = Set(preferences?.hiddenCourseIDs ?? [])
        return courses.filter { !hidden.contains($0.id) }.prefix(100).map {
            CourseSummary(id: $0.id, title: $0.title, summary: $0.summary, lessonCount: $0.lessons.count)
        }
    }

    private func currentCapabilityHandshake() -> CapabilityHandshake? {
        let file = root.appendingPathComponent("capability-handshake.json")
        guard let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(CapabilityHandshake.self, from: data),
              !value.engineBuild.isEmpty,
              value.nodeContractHash.range(of: "^[A-Fa-f0-9]{16,128}$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }
}

private enum TutorRuntimeError: LocalizedError {
    case socketUnavailable
    case invalidResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .socketUnavailable: return "Tutor runtime socket is unavailable"
        case .invalidResponse: return "Tutor runtime returned an invalid response"
        case .responseTooLarge: return "Tutor runtime response exceeded limit"
        }
    }
}

/// Engine-to-runtime half of the owner-only local socket. The node has a
/// JavaScript client; Boring UI must cross XPC through this bounded native one.
private enum RuntimeSocketClient {
    private static let maximumResponseBytes = 1_500_000

    static func invoke(path: String, request: Data) throws -> Data {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TutorRuntimeError.socketUnavailable }
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 12, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let byteCount = path.utf8.count + 1
        guard byteCount <= MemoryLayout.size(ofValue: address.sun_path) else { throw TutorRuntimeError.socketUnavailable }
        _ = path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path.0) { strncpy($0, source, byteCount) }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sa_family_t>.size + byteCount))
            }
        }
        guard connected == 0 else { throw TutorRuntimeError.socketUnavailable }
        var message = request
        message.append(0x0A)
        let sent = message.withUnsafeBytes { write(descriptor, $0.baseAddress, message.count) }
        guard sent == message.count else { throw TutorRuntimeError.socketUnavailable }
        _ = shutdown(descriptor, SHUT_WR)
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let received = read(descriptor, &buffer, buffer.count)
            if received == 0 { break }
            guard received > 0 else { throw TutorRuntimeError.socketUnavailable }
            response.append(buffer, count: received)
            if response.count > maximumResponseBytes { throw TutorRuntimeError.responseTooLarge }
            if response.contains(0x0A) { break }
        }
        guard let newline = response.firstIndex(of: 0x0A) else { throw TutorRuntimeError.invalidResponse }
        return response.prefix(upTo: newline)
    }
}
