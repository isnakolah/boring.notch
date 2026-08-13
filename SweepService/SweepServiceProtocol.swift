import Foundation

@objc protocol SweepServiceProtocol {
    func send(_ request: Data, with reply: @escaping (Data) -> Void)
}
