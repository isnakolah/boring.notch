import Foundation

// A node in the survey tree.
//
// Both sizes are retained deliberately (C1). `allocated` is what Sweep reports —
// what the volume would get back. `apparent` is what the file claims to be. Their
// ratio is consumed as evidence in Phase 06: a file far smaller on disk than it
// claims is a sparse image, and reporting its apparent size would overstate
// reclaimable space by tens of gigabytes.
struct Node: Identifiable, Equatable {
    var url: URL
    /// On-disk bytes. The only figure ever shown to the user (C1).
    var allocated: Int64
    /// Logical bytes. Retained for the sparseness ratio, never displayed.
    var apparent: Int64
    var isDirectory: Bool
    var modified: Date?
    var accessed: Date?
    /// Sweep could not enumerate this node. It is not zero bytes — it is unknown,
    /// and totals that include it are marked incomplete rather than wrong (C8).
    var isUnreadable: Bool = false
    /// A second (or later) hard link to bytes already counted in this walk. Its
    /// `allocated` is zero, because deleting this path would free nothing while
    /// the other link remains (C1).
    var isAdditionalLink: Bool = false
    var children: [Node] = []
    /// Authoritative subtree total, set by the sizer so it survives pruning of
    /// leaf children (P-005). nil for hand-built nodes, which fall back to summing
    /// retained children.
    var subtreeAllocated: Int64?
    var subtreeApparent: Int64?

    var id: String { url.path }

    /// How much of the apparent size is actually on disk, 0…1.
    ///
    /// `nil` when there is nothing to compare — an empty file is not sparse, it is
    /// empty, and dividing by zero to say otherwise would invent evidence.
    var allocationRatio: Double? {
        guard apparent > 0 else { return nil }
        return Double(allocated) / Double(apparent)
    }

    /// Total allocated bytes for this node and everything beneath it. Uses the
    /// authoritative figure the sizer recorded when present, so a directory whose
    /// leaf files were pruned still reports its true size; otherwise sums the
    /// retained children (hand-built nodes in tests).
    var totalAllocated: Int64 {
        subtreeAllocated ?? children.reduce(allocated) { $0 + $1.totalAllocated }
    }

    var totalApparent: Int64 {
        subtreeApparent ?? children.reduce(apparent) { $0 + $1.totalApparent }
    }

    /// True when any node in this subtree could not be read, so a caller can say
    /// "at least this much" instead of presenting an incomplete total as exact.
    var containsUnreadable: Bool {
        isUnreadable || children.contains { $0.containsUnreadable }
    }
}

// Progress during a walk. Reported often enough to animate, cheap enough not to
// dominate the walk itself.
struct SurveyProgress: Equatable {
    var root: URL
    var entriesScanned: Int
    var bytesSoFar: Int64
    var currentPath: String?
}
