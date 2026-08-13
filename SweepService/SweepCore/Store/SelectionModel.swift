import Foundation

// The selection state for the Targets surface, enforcing C3 in one place:
//   - only `safe` targets are pre-selected;
//   - a `danger` (vetoed) target can never be selected, not by a tap and not by
//     select-all. The veto is absolute at the point of action too, not only in the
//     verdict.
//
// Phase 12 added components: a row's folded descendants, selectable inside its
// disclosure. That makes it possible to select a path and one of its ancestors at
// the same time, so this type is also where C2's "the same bytes are counted
// once" is enforced — `selectedTargets` returns the *maximal* set, dropping any
// selection that already sits inside another. Everything downstream (the byte
// figure, the plan, the sweep) reads that reduced set, so there is one place to
// get it right rather than three.
//
// Kept out of the view so the rules are unit-testable without SwiftUI.
final class SelectionModel: ObservableObject {

    @Published private(set) var selected: Set<String> = []
    private(set) var targets: [Target]
    /// Every selectable thing, rows and components alike, by id.
    private let byID: [String: Target]

    init(targets: [Target]) {
        self.targets = targets
        var index: [String: Target] = [:]
        func register(_ target: Target) {
            index[target.id] = target
            for component in target.components { register(component) }
        }
        for target in targets { register(target) }
        self.byID = index
        // Pre-select only safe rows. A component is never pre-selected: one inside
        // a safe row is already covered by the row, and one inside a caution row
        // would be pre-selecting part of something C3 says not to pre-select.
        self.selected = Set(targets.filter { $0.risk == .safe }.map(\.id))
    }

    /// Whether a target may be selected at all. Vetoed targets never can be —
    /// this applies to a component exactly as it does to a row.
    func isSelectable(_ target: Target) -> Bool {
        target.risk != .danger
    }

    func isSelected(_ id: String) -> Bool { selected.contains(id) }

    func toggle(_ target: Target) {
        guard isSelectable(target) else { return }
        if selected.contains(target.id) {
            selected.remove(target.id)
        } else {
            selected.insert(target.id)
        }
    }

    /// Select every selectable row — safe and caution, never danger. Components
    /// are not swept in: a row's selection already covers everything beneath it.
    func selectAll() {
        selected = Set(targets.filter(isSelectable).map(\.id))
    }

    func selectRecommended() {
        selected = Set(targets.filter { $0.risk == .safe }.map(\.id))
    }

    func clear() {
        selected = []
    }

    /// What a sweep would actually act on: the selection with every entry that
    /// lies inside another selected entry removed. Selecting a row and a
    /// component of that row is one item, not two, and its bytes count once.
    var selectedTargets: [Target] {
        var ordered: [Target] = []
        func collect(_ target: Target) {
            if selected.contains(target.id) { ordered.append(target) }
            for component in target.components { collect(component) }
        }
        for target in targets { collect(target) }
        guard ordered.count > 1 else { return ordered }
        let paths = Set(ordered.map { $0.url.path })
        return ordered.filter { !Self.hasAncestor(of: $0.url.path, in: paths) }
    }

    var selectedBytes: Int64 {
        selectedTargets.reduce(0) { $0 + $1.bytes }
    }

    var hasDangerSelected: Bool {
        // Always false by construction; asserted by test as a safety net.
        selectedTargets.contains { $0.risk == .danger }
    }

    /// Whether any strict ancestor of `path` is in `paths`. Walks up the path
    /// rather than comparing every pair, so this stays linear in depth.
    static func hasAncestor(of path: String, in paths: Set<String>) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while parent.count > 1 {
            if paths.contains(parent) { return true }
            let next = (parent as NSString).deletingLastPathComponent
            if next == parent { break }
            parent = next
        }
        return false
    }
}
