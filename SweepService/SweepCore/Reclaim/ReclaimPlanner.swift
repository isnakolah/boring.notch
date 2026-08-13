import Foundation

// How a specific target will be reclaimed, decided once, before the sweep.
enum ReclaimMethod: Equatable {
    case trash
    case hardDelete
    case command(KnownTools.Teardown)
    /// The registry matched but the tool cannot run and a direct delete would be
    /// unsafe — the row is shown disabled with this reason, never reclaimed
    /// silently and never failing mid-sweep (C5).
    case disabled(reason: String)

    var isActionable: Bool {
        if case .disabled = self { return false }
        return true
    }
    var isPermanent: Bool {
        switch self {
        case .hardDelete, .command: return true
        case .trash, .disabled: return false
        }
    }
}

// Evaluates a teardown's precondition against the live system. Injected so the
// planner is testable without a running Docker daemon.
protocol PreconditionChecking: Sendable {
    func isSatisfied(_ precondition: KnownTools.Precondition) -> Bool
}

struct SystemPreconditionChecker: PreconditionChecking {
    let runner: any ProcessRunning
    let runningBundleIdentifiers: @Sendable () -> Set<String>

    func isSatisfied(_ precondition: KnownTools.Precondition) -> Bool {
        switch precondition {
        case .none:
            return true
        case .appsNotRunning(let ids):
            let running = runningBundleIdentifiers()
            return ids.allSatisfy { !running.contains($0) }
        case .commandSucceeds(let binary, let args):
            guard let path = runner.resolveOnLoginPath(binary) else { return false }
            return (try? runner.run(path, args, timeout: 30))?.succeeded ?? false
        case .commandOutputContainsOnly(let binary, let args, let allowed):
            guard let path = runner.resolveOnLoginPath(binary),
                  let result = try? runner.run(path, args, timeout: 30), result.succeeded
            else { return false }
            let lines = result.standardOutput
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lines.allSatisfy { $0 == allowed }
        }
    }
}

// Decides the reclaim method for each target. The registry is enrichment: it can
// only ever *upgrade* a direct delete to a safer vendor command, or — when the
// vendor's tool is unavailable and a direct delete would be unsafe — disable the
// row. It can never prevent an unmatched target from being reclaimed directly.
struct ReclaimPlanner {
    let registry: KnownTools
    let runner: any ProcessRunning
    let preconditions: PreconditionChecking
    /// The global default: when true, actionable trash defaults become permanent.
    let permanentDefault: Bool

    func method(for target: Target) -> ReclaimMethod {
        // Absolute safety: a protected target is never actionable, whatever the
        // registry says.
        if target.risk == .danger { return .disabled(reason: "Withheld — protected by a veto.") }

        let directDefault: ReclaimMethod = {
            if permanentDefault { return .hardDelete }
            return target.defaultReclaim.isPermanent ? .hardDelete : .trash
        }()

        guard let teardown = registry.teardown(for: target.owner) else {
            return directDefault      // unmatched owner → direct reclaim
        }

        // Registry matched. Prefer the vendor command, but only if it can run.
        guard runner.resolveOnLoginPath(teardown.binary) != nil else {
            return teardown.directDeleteSafeIfBinaryMissing
                ? directDefault
                : .disabled(reason: "Needs \(teardown.binary), which isn't installed.")
        }
        guard preconditions.isSatisfied(teardown.precondition) else {
            return teardown.directDeleteSafeIfBinaryMissing
                ? directDefault
                : .disabled(reason: preconditionReason(teardown))
        }
        return .command(teardown)
    }

    private func preconditionReason(_ teardown: KnownTools.Teardown) -> String {
        switch teardown.precondition {
        case .appsNotRunning:
            return "Quit \(teardown.owner) first."
        case .commandSucceeds:
            return "\(teardown.owner) isn't running."
        case .commandOutputContainsOnly:
            return "\(teardown.owner) has active instances — stop them first."
        case .none:
            return "Unavailable."
        }
    }
}
