//
//  MeetingLinkResolver.swift
//  boringNotch
//
//  Rewrites known web meeting links (Zoom, Teams) to their native-app URL scheme
//  when the corresponding app is installed, so joining a meeting opens the app
//  directly instead of the default browser. Providers without a reliable desktop
//  scheme (Google Meet, Webex, …) return nil and keep opening in the browser.
//

import AppKit
import Foundation

enum MeetingLinkResolver {

    /// Returns a native-app URL for the meeting if a registered handler is
    /// installed, otherwise `nil` (caller should fall back to the web URL).
    static func nativeURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }

        let candidate: URL?
        if host == "zoom.us" || host.hasSuffix(".zoom.us") {
            candidate = zoomURL(from: url)
        } else if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com")
            || host == "teams.live.com" || host.hasSuffix(".teams.live.com") {
            candidate = teamsURL(from: url)
        } else {
            candidate = nil
        }

        guard let candidate,
              NSWorkspace.shared.urlForApplication(toOpen: candidate) != nil else {
            return nil
        }
        return candidate
    }

    // MARK: - Zoom

    /// `https://<sub>.zoom.us/j/<id>?pwd=<pw>` → `zoommtg://zoom.us/join?action=join&confno=<id>&pwd=<pw>`
    private static func zoomURL(from url: URL) -> URL? {
        let parts = url.pathComponents.filter { $0 != "/" }
        // Standard join links look like /j/<id> or /wc/join/<id>.
        guard let jIndex = parts.firstIndex(where: { $0 == "j" || $0 == "join" }),
              jIndex + 1 < parts.count else {
            return nil
        }
        let confno = parts[jIndex + 1].filter(\.isNumber)
        guard !confno.isEmpty else { return nil }

        var query = "action=join&confno=\(confno)"
        if let pwd = queryValue(url, name: "pwd"), !pwd.isEmpty,
           let encoded = pwd.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            query += "&pwd=\(encoded)"
        }
        return URL(string: "zoommtg://zoom.us/join?\(query)")
    }

    // MARK: - Teams

    /// `https://teams.microsoft.com/l/meetup-join/...` → `msteams:/l/meetup-join/...`
    private static func teamsURL(from url: URL) -> URL? {
        guard url.path.contains("/l/meetup-join") || url.path.contains("/l/meeting") else {
            return nil
        }
        var deepLink = "msteams:\(url.path)"
        if let query = url.query, !query.isEmpty {
            deepLink += "?\(query)"
        }
        return URL(string: deepLink)
    }

    // MARK: - Helpers

    private static func queryValue(_ url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
