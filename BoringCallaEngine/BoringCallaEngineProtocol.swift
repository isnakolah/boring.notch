import Foundation

@objc protocol BoringCallaEngineProtocol {
    func start(with reply: @escaping (Data) -> Void)
    func stop(with reply: @escaping (Data) -> Void)
    func applyPreferences(_ preferences: Data, with reply: @escaping (Data) -> Void)
    func status(with reply: @escaping (Data) -> Void)
    func requestGatewayUpdate(with reply: @escaping (Data) -> Void)
    func requestScreenRecording(with reply: @escaping (Data) -> Void)
    func requestAccessibility(with reply: @escaping (Data) -> Void)
    func startCourse(_ courseID: String, with reply: @escaping (Data) -> Void)
    func resumeCourse(with reply: @escaping (Data) -> Void)
    func stopLesson(with reply: @escaping (Data) -> Void)
    func ask(_ text: String, with reply: @escaping (Data) -> Void)
}
