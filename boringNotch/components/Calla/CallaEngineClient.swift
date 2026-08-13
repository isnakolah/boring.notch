import Foundation
import Defaults

@objc protocol BoringCallaEngineProtocol {
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    func requestAccessibility(with reply: @escaping (Data) -> Void)
    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void)
    func resumeCourse(with reply: @escaping (Data) -> Void)
    func stopLesson(with reply: @escaping (Data) -> Void)
    func ask(_ text: String, with reply: @escaping (Data) -> Void)
}

struct CallaEnginePreferences: Codable, Equatable {
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

    static var current: CallaEnginePreferences {
        let learnerID = learnerIdentifier()
        return CallaEnginePreferences(
            captureEnabled: Defaults[.callaCaptureEnabled],
            allowedBundleIDs: Defaults[.callaAllowedBundleIDs],
            captureLongEdge: Defaults[.callaCaptureLongEdge],
            tooltipWidth: Defaults[.callaTooltipWidth],
            hideTooltipOnHover: Defaults[.callaHideTooltipOnHover],
            cursorSize: Defaults[.callaCursorSize],
            tooltipOpacity: Defaults[.callaTooltipOpacity],
            showStatusHUD: Defaults[.callaShowStatusHUD],
            learnerID: learnerID,
            hiddenCourseIDs: Defaults[.callaHiddenCourseIDs]
        )
    }

    private static func learnerIdentifier() -> String {
        let stored = Defaults[.callaLearnerID]
        if stored.range(of: "^[A-Za-z0-9-]{8,80}$", options: .regularExpression) != nil { return stored }
        let identifier = "learner-" + UUID().uuidString.lowercased()
        Defaults[.callaLearnerID] = identifier
        return identifier
    }
}

struct CallaEngineStatus: Codable, Equatable {
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
    var courses: [CallaCourseSummary] = []
}

struct CallaCourseSummary: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let lessonCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, summary
        case lessonCount = "lesson_count"
    }
}

@MainActor
final class CallaEngineClient: ObservableObject {
    static let shared = CallaEngineClient()

    @Published private(set) var status = CallaEngineStatus()
    private var connection: NSXPCConnection?

    private init() {}

    func start() {
        invoke { $0.start(with: $1) }
    }

    func stop() {
        invoke { $0.stop(with: $1) }
    }

    func applyCurrentPreferences() {
        guard let data = try? JSONEncoder().encode(Preferences.current) else { return }
        invoke { $0.applyPreferences(data, with: $1) }
    }

    func refresh() {
        invoke { $0.status(with: $1) }
    }

    func requestGatewayUpdate() {
        invoke { $0.requestGatewayUpdate(with: $1) }
    }

    func requestAccessibility() {
        invoke { $0.requestAccessibility(with: $1) }
    }

    func startCourse(_ courseID: String, completion: ((CallaEngineStatus) -> Void)? = nil) {
        invoke({ $0.startCourse(courseID, with: $1) }, completion: completion)
    }

    func resumeCourse() {
        invoke { $0.resumeCourse(with: $1) }
    }

    func stopLesson() {
        invoke { $0.stopLesson(with: $1) }
    }

    func ask(_ text: String) {
        invoke { $0.ask(text, with: $1) }
    }

    func reportLocalFailure(_ message: String) {
        status.lastResult = message
    }

    private func invoke(_ call: @escaping (BoringCallaEngineProtocol, @escaping (Data) -> Void) -> Void,
                        completion: ((CallaEngineStatus) -> Void)? = nil) {
        let connection = connection ?? makeConnection()
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("[CallaEngine] XPC unavailable: %@", error.localizedDescription)
            Task { @MainActor in
                self?.status.lastResult = "Engine unavailable: \(error.localizedDescription)"
                self?.status.running = false
            }
        }) as? BoringCallaEngineProtocol else { return }
        call(proxy) { [weak self] data in
            guard let result = try? JSONDecoder().decode(CallaEngineStatus.self, from: data) else { return }
            Task { @MainActor in
                self?.status = result
                completion?(result)
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "theboringteam.boringnotch.BoringCallaEngine")
        connection.remoteObjectInterface = NSXPCInterface(with: BoringCallaEngineProtocol.self)
        connection.resume()
        self.connection = connection
        return connection
    }
}

private typealias Preferences = CallaEnginePreferences
