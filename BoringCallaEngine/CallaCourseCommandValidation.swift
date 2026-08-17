import Foundation

/// Pure validation boundary shared by XPC command handling and its unit tests.
/// No Gateway, runtime socket, or user preference is touched here.
enum CallaCourseCommandValidation {
    static func identifier(_ value: String?) -> String? {
        guard let value, value.range(of: "^[A-Za-z0-9._-]{1,160}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func bundleID(_ value: String?) -> String? {
        guard let value, value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{1,126}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    static func outline(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.lengthOfBytes(using: .utf8) <= 96 * 1024 else { return nil }
        return clean
    }

    static func version(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.range(of: "^[0-9][0-9A-Za-z._ -]{0,63}$", options: .regularExpression) != nil else { return nil }
        return clean
    }

    static func zipURL(_ value: String?, fileManager: FileManager = .default) -> URL? {
        guard let value, value.hasPrefix("/"), !value.contains("\u{0}"), value.hasSuffix(".zip") else { return nil }
        let url = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) < 250 * 1024 * 1024 else { return nil }
        return url
    }
}
