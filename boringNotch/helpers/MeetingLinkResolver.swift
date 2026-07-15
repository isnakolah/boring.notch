//
//  MeetingLinkResolver.swift
//  boringNotch
//
//  Rewrites known web meeting links (Zoom, Teams) to their native-app URL scheme
//  so joining a meeting opens the app directly instead of the default browser.
//  Providers without a reliable desktop scheme (Google Meet, Webex, …) return
//  nil and keep opening in the browser.
//
//  Whether the app is actually installed can't be queried here: the main app is
//  sandboxed, so `NSWorkspace.urlForApplication(toOpen:)` on a foreign URL scheme
//  is blocked and returns nil. The caller instead attempts to open the returned
//  URL and falls back to the web URL when no handler accepts it.
//

import Foundation

enum MeetingLinkResolver {

    /// Returns the native-app URL for a recognized meeting link (Zoom/Teams), or
    /// `nil` for unrecognized/unparseable links. Installation is not checked here
    /// (see file note); the caller opens this and falls back to the web URL.
    static func nativeURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }

        if host == "zoom.us" || host.hasSuffix(".zoom.us")
            || host == "zoom.com" || host.hasSuffix(".zoom.com")
            || host == "zoomgov.com" || host.hasSuffix(".zoomgov.com") {
            return zoomURL(from: url)
        } else if host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com")
            || host == "teams.live.com" || host.hasSuffix(".teams.live.com") {
            return teamsURL(from: url)
        }
        return nil
    }

    // MARK: - Zoom

    /// `https://<sub>.zoom.us/j/<id>?pwd=<pw>` → `zoommtg://zoom.us/join?action=join&confno=<id>&pwd=<pw>`
    private static func zoomURL(from url: URL) -> URL? {
        // Join links put the numeric meeting id somewhere in the path — /j/<id>,
        // /w/<id>, /s/<id>, /wc/join/<id>, /wc/<id>/join, … — so take the first
        // all-digit component long enough to be a meeting id (9–11 digits today).
        // Vanity links (/my/<name>) have none and fall back to the browser.
        let confno = url.pathComponents.first { part in
            part.count >= 8 && part.allSatisfy(\.isNumber)
        }
        guard let confno else { return nil }

        var query = "action=join&confno=\(confno)"
        // pwd (meeting passcode) and tk (registration token) both gate entry;
        // dropping either would make the app prompt or reject the join.
        for name in ["pwd", "tk"] {
            if let value = queryValue(url, name: name), !value.isEmpty,
               let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                query += "&\(name)=\(encoded)"
            }
        }
        return URL(string: "zoommtg://zoom.us/join?\(query)")
    }

    // MARK: - Teams

    /// `https://teams.microsoft.com/l/meetup-join/...` → `msteams:/l/meetup-join/...`
    /// `https://teams.microsoft.com/meet/<id>?p=<code>` → `msteams:/meet/<id>?p=<code>`
    ///
    /// Reuses the original percent-encoded path/query rather than `url.path`,
    /// which decodes `%3a`/`%40` and would corrupt the thread id in the deep link.
    private static func teamsURL(from url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        let prefix = "\(scheme)://\(host)"
        guard url.absoluteString.hasPrefix(prefix) else { return nil }
        let rest = String(url.absoluteString.dropFirst(prefix.count))
        guard rest.contains("/l/meetup-join") || rest.contains("/l/meeting")
            || rest.hasPrefix("/meet/") else {
            return nil
        }
        return URL(string: "msteams:\(rest)")
    }

    // MARK: - Helpers

    private static func queryValue(_ url: URL, name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}
