import Foundation

// The output of a full survey+analysis, in the shape the surfaces consume.
// Targets already have descendants folded (Phase 06), so summing target bytes
// never double-counts a parent and child.
struct AnalysisResult: Equatable {
    var volume: VolumeInfo?
    var targets: [Target]
    var unreadableRoots: [URL]
    var generatedAt: Date

    /// Offered targets — everything the user may act on. Danger (veto) targets are
    /// withheld, shown but never offered.
    var offered: [Target] {
        targets.filter { $0.risk != .danger }
            .sorted { rank($0) > rank($1) }
    }

    /// Withheld targets — what Sweep declined to offer, kept visible so the user
    /// can see what it protected and why. `RustRover2026.1` lives here.
    var withheld: [Target] {
        targets.filter { $0.risk == .danger }
            .sorted { $0.bytes > $1.bytes }
    }

    /// What could be reclaimed if every offered target were acted on.
    var reclaimableBytes: Int64 {
        offered.reduce(0) { $0 + $1.bytes }
    }

    /// Per-category rollups over offered targets, largest first. Their byte sum
    /// equals `reclaimableBytes` — the same folding, counted once.
    var rollups: [CategoryRollup] {
        var byCategory: [Category: (count: Int, bytes: Int64)] = [:]
        for target in offered {
            let current = byCategory[target.category] ?? (0, 0)
            byCategory[target.category] = (current.count + 1, current.bytes + target.bytes)
        }
        return byCategory
            .map { CategoryRollup(category: $0.key, count: $0.value.count, bytes: $0.value.bytes) }
            .sorted { $0.bytes > $1.bytes }
    }

    var needsPermission: Bool { !unreadableRoots.isEmpty }

    // Offered targets rank by size, so the findings that matter surface first and
    // the weak staleness-only tail (P-004) sorts to the bottom rather than
    // crowding the top. Risk is not part of the ordering — a big caution item is
    // more worth seeing than a tiny safe one.
    private func rank(_ target: Target) -> Int64 { target.bytes }
}

struct CategoryRollup: Identifiable, Equatable {
    let category: Category
    let count: Int
    let bytes: Int64
    var id: String { category.label }
}
