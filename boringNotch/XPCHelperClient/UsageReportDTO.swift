//
//  UsageReportDTO.swift
//  BoringNotch
//
//  Shared Codable payload passed across the XPC boundary for CLI usage data.
//  This file is duplicated verbatim in boringNotch/XPCHelperClient/ and
//  BoringNotchXPCHelper/ — keep both copies identical.
//

import Foundation

struct UsageReportDTO: Codable, Equatable {
    enum Status: String, Codable {
        case ok
        case cliNotInstalled
        case notLoggedIn
        case error
    }

    struct Quota: Codable, Equatable {
        var percentRemaining: Double   // 0...100
        var resetText: String?         // "Resets in 4h 7m"
        var resetsAt: Date?            // for client-side countdown when parseable
    }

    var provider: String
    var status: Status
    var errorDescription: String?
    var session: Quota?
    var weekly: Quota?
    var capturedAt: Date

    /// Shared JSON coders — `.secondsSince1970` dates on both sides of the XPC boundary.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}
