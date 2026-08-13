import Foundation

// The sole protocol through which anything in Sweep deletes. Every deletion goes
// through a `Reclaimer`; no `FileManager.removeItem`/`trashItem` call exists
// outside this directory (enforced structurally). Returns the bytes it acted on,
// so the engine can account for what was trashed versus permanently removed — but
// the *freed* figure the user sees is always the measured volume delta (C5), never
// this sum.
protocol Reclaimer: Sendable {
    func reclaim(_ target: Target, progress: @escaping @Sendable (Double) -> Void) async throws -> Int64
}

enum ReclaimError: Error, Equatable {
    case refusedProtectedTarget         // a danger/vetoed target reached the reclaimer
    case teardownFailed(String)
    case fileOperationFailed(String)
}

extension Reclaimer {
    func reclaim(_ target: Target) async throws -> Int64 {
        try await reclaim(target) { _ in }
    }
}

// Moves a target to the Trash. The bytes are NOT freed until the Trash is emptied,
// which the engine reports separately and honestly (C5).
struct TrashReclaimer: Reclaimer {
    func reclaim(_ target: Target, progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        try guardProtected(target)
        progress(0)
        do {
            try FileManager.default.trashItem(at: target.url, resultingItemURL: nil)
        } catch {
            throw ReclaimError.fileOperationFailed(error.localizedDescription)
        }
        progress(1)
        return target.bytes
    }
}

// Permanently removes a target. Used for items over 5 GB (Trashing frees nothing)
// and where the user overrides to permanent (C5).
struct HardReclaimer: Reclaimer {
    func reclaim(_ target: Target, progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 {
        try guardProtected(target)
        progress(0)
        do {
            try FileManager.default.removeItem(at: target.url)
        } catch {
            throw ReclaimError.fileOperationFailed(error.localizedDescription)
        }
        progress(1)
        return target.bytes
    }
}

// A defensive check present in every reclaimer: a protected (danger/vetoed) target
// must never be deletable, even if one somehow reaches this far. The veto is
// absolute at the point of action, not only in the verdict.
private func guardProtected(_ target: Target) throws {
    if target.risk == .danger {
        throw ReclaimError.refusedProtectedTarget
    }
}

// Exposed so the command reclaimer (a struct in another file) shares the guard.
extension Reclaimer {
    func assertReclaimable(_ target: Target) throws {
        try guardProtected(target)
    }
}
