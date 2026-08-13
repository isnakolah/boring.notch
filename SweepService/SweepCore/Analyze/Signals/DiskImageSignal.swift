import Foundation

// A disk image is opaque: Sweep can read its allocated size but cannot see what is
// inside it, so it must not be offered for reclaim on its own judgement. This is
// protective. When the file is also sparse — allocated far below apparent — the
// reason reports the on-disk figure, because that is what would actually be freed
// and the apparent size would mislead.
struct DiskImageSignal: Signal {
    let name = "Disk image"

    func evaluate(_ node: Node, owner: Owner?, context: SignalContext) -> [Evidence] {
        guard !node.isDirectory, StructuralMarkers.hasDiskImageExtension(node.url) else { return [] }

        let sparse = (node.allocationRatio ?? 1.0) < 0.9
        let size = Format.bytes(node.allocated)
        let reason = sparse
            ? "A \(size) sparse disk image — Sweep cannot see what is inside it."
            : "A \(size) disk image — Sweep cannot see what is inside it."

        return [Evidence(
            signal: name,
            polarity: .protective,
            weight: 0.9,
            reason: reason,
            category: .diskImage)]
    }
}
