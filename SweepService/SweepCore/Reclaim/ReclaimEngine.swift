import Foundation

// One item in a planned sweep: a target and how it will be reclaimed.
struct ReclaimItem: Identifiable, Equatable {
    let target: Target
    let method: ReclaimMethod
    var id: String { target.id }

    var isActionable: Bool { method.isActionable }
}

// A planned sweep, ready to confirm. Carries the confirmation rules of C5.
struct ReclaimPlan: Equatable {
    let items: [ReclaimItem]
    /// Source finding frozen at review time. Execution keeps using these items,
    /// even if background analysis replaces current UI summaries.
    let sourceTimestamp: Date
    let sourceState: String

    init(items: [ReclaimItem], sourceTimestamp: Date = Date(), sourceState: String = "fresh") {
        self.items = items
        self.sourceTimestamp = sourceTimestamp
        self.sourceState = sourceState
    }

    var actionable: [ReclaimItem] { items.filter(\.isActionable) }
    var disabled: [ReclaimItem] { items.filter { !$0.isActionable } }

    /// Allocated bytes across actionable items.
    var totalBytes: Int64 { actionable.reduce(0) { $0 + $1.target.bytes } }

    /// Bytes this sweep would free outright. Split from the trashed figure
    /// because the two are not the same promise, and the sheet says so before
    /// the user commits rather than after (C5).
    var permanentBytes: Int64 {
        actionable.filter { $0.method.isPermanent }.reduce(0) { $0 + $1.target.bytes }
    }

    /// Bytes that would move to the Trash — still occupied until it is emptied.
    var trashBytes: Int64 {
        actionable.filter { !$0.method.isPermanent }.reduce(0) { $0 + $1.target.bytes }
    }

    var permanentCount: Int { actionable.filter { $0.method.isPermanent }.count }

    /// A single button confirms a trash-only sweep; anything permanent or any
    /// danger item requires the typed gate.
    var isTrashOnly: Bool {
        !actionable.isEmpty && actionable.allSatisfy { $0.method == .trash }
    }

    /// Any danger target in the selection forces the typed `DELETE` gate (C5).
    /// Danger targets are not selectable in the first place, so this is a belt on
    /// top of the braces — but the rule is stated where the sweep is confirmed.
    var requiresTypedConfirmation: Bool {
        actionable.contains { $0.target.risk == .danger || $0.method.isPermanent }
    }

    /// True when one item's path lies inside another's — the double count C2
    /// forbids, and a sweep that would delete a tree and then look for something
    /// inside it. `SelectionModel.selectedTargets` cannot produce this, because
    /// it reduces the selection to its maximal paths first; the check lives here
    /// so a caller that builds a plan some other way cannot quietly reintroduce
    /// it, and the engine refuses such a plan outright.
    var containsNestedPaths: Bool {
        let paths = Set(items.map { $0.target.url.path })
        return items.contains { SelectionModel.hasAncestor(of: $0.target.url.path, in: paths) }
    }
}

// What a completed sweep did. Freed is the MEASURED volume delta; trashed is
// counted separately as not-yet-freed (C5).
struct ReclaimReport: Equatable {
    var measuredFreedBytes: Int64
    var trashedBytes: Int64
    var reclaimedItems: Int
    var failures: [String]
    /// The targets actually reclaimed, so the regrowth store can record them (C7).
    var reclaimed: [ReclaimedRecord]

    var hasTrash: Bool { trashedBytes > 0 }
}

// The minimum a reclaimed target contributes to the regrowth history.
struct ReclaimedRecord: Equatable {
    let path: String
    let fingerprint: String
    let bytes: Int64
}

enum ReclaimEngineError: Error, Equatable {
    case confirmationRequired
    case protectedTargetInPlan
    case nestedPathsInPlan
}

// Executes a confirmed plan and reports what actually happened. It samples the
// volume before and after so the freed figure is measured, never summed.
struct ReclaimEngine {
    let trash: Reclaimer
    let hard: Reclaimer
    let commandFactory: @Sendable (KnownTools.Teardown) -> Reclaimer
    let sampleVolume: @Sendable () -> VolumeInfo?

    func execute(
        _ plan: ReclaimPlan,
        typedConfirmation: String?,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> ReclaimReport {
        // A protected target must never be in an executable plan.
        if plan.items.contains(where: { $0.target.risk == .danger && $0.isActionable }) {
            throw ReclaimEngineError.protectedTargetInPlan
        }
        // Nor may a plan hold a path and something inside it: the same bytes
        // would be counted twice and the second delete would work on a tree the
        // first one removed.
        if plan.containsNestedPaths {
            throw ReclaimEngineError.nestedPathsInPlan
        }
        if plan.requiresTypedConfirmation && typedConfirmation != "DELETE" {
            throw ReclaimEngineError.confirmationRequired
        }

        let before = sampleVolume()

        var trashedBytes: Int64 = 0
        var reclaimed: [ReclaimedRecord] = []
        var failures: [String] = []
        let items = plan.actionable
        for (index, item) in items.enumerated() {
            do {
                let bytes = try await reclaimer(for: item.method).reclaim(item.target) { _ in }
                if case .trash = item.method { trashedBytes += bytes }
                reclaimed.append(ReclaimedRecord(
                    path: item.target.url.path,
                    fingerprint: item.target.fingerprint,
                    bytes: item.target.bytes))
            } catch {
                // A single failure never aborts the sweep (C5); it is collected.
                failures.append("\(item.target.title): \(message(for: error))")
            }
            progress(Double(index + 1) / Double(max(1, items.count)))
        }

        let after = sampleVolume()
        let measuredFreed: Int64
        if let before, let after {
            measuredFreed = VolumeReader.freedBytes(before: before, after: after)
        } else {
            measuredFreed = 0
        }

        return ReclaimReport(
            measuredFreedBytes: measuredFreed,
            trashedBytes: trashedBytes,
            reclaimedItems: reclaimed.count,
            failures: failures,
            reclaimed: reclaimed)
    }

    private func reclaimer(for method: ReclaimMethod) -> Reclaimer {
        switch method {
        case .trash: return trash
        case .hardDelete: return hard
        case .command(let teardown): return commandFactory(teardown)
        case .disabled: return NoopReclaimer()
        }
    }

    private func message(for error: Error) -> String {
        if let e = error as? ReclaimError {
            switch e {
            case .refusedProtectedTarget: return "protected — refused"
            case .teardownFailed(let m): return m
            case .fileOperationFailed(let m): return m
            }
        }
        return error.localizedDescription
    }
}

// Never actually used to reclaim (disabled rows are filtered out), but keeps the
// dispatch total without an optional.
private struct NoopReclaimer: Reclaimer {
    func reclaim(_ target: Target, progress: @escaping @Sendable (Double) -> Void) async throws -> Int64 { 0 }
}
