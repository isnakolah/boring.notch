import Foundation

// Removes a file Sweep itself created — specifically its own LaunchAgent plist
// when launch-at-login is turned off (Phase 02's fallback).
//
// It lives in Reclaim/ on purpose: the AGENTS invariant is that no
// `FileManager.removeItem`/`trashItem` call exists outside this directory, so
// every deletion in the binary is auditable in one place. This is not the target
// reclaimer (that is the `Reclaimer` protocol, Phase 08) and it must never be used
// to remove user data or a survey target — only Sweep's own configuration
// artifacts, by absolute path, that Sweep wrote itself.
enum OwnedFileRemoval {
    static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
