import Foundation

// The allocated-size walker (C1).
//
// Rules enforced here, all of them load-bearing:
//   - allocated bytes, never apparent — a 48 GB sparse disk image occupying
//     34 GB is 34 GB of reclaimable space, and summing apparent size would
//     overstate the total by tens of gigabytes;
//   - symlinks are skipped, never followed and never counted, so a link into a
//     large tree cannot double it;
//   - entries on another volume are skipped, which is what stops firmlinks and
//     mounted volumes from being counted twice;
//   - hard-linked bytes are counted once per walk, because deleting one of two
//     links frees nothing and counting both overstates what can be reclaimed —
//     npm and pnpm stores hard-link aggressively, and on the machine that
//     motivated this the error was 1.9 GB in one directory;
//   - excluded paths (C4) are not descended into;
//   - a directory that cannot be read is flagged, not recorded as zero;
//   - the walk is cancellable and reports progress as it goes.
//
// The walk is a recursive descent over `FileSystem` rather than a FileManager
// enumerator. Descending explicitly is what makes per-directory unreadability
// observable — an enumerator's error handler cannot attribute a failure to the
// node it belongs to.
//
// Phase 12 rewrote the mechanics without changing any of the above:
//   - the recursion is synchronous, with cancellation checked on the progress
//     interval rather than twice per entry. An async recursive call per file
//     meant an async frame per file;
//   - it works in `String` paths and builds a `URL` only for a node it keeps, so
//     the millions of entries that are folded and dropped never allocate one;
//   - a directory is kept only within the retention depth, when it is
//     unreadable, or when something beneath it is kept (P-005).
struct Sizer: Sendable {

    let fileSystem: FileSystem
    let exclusions: Exclusions
    /// How often to report progress and check for cancellation, in entries.
    let progressInterval: Int
    /// The depth to which directories are retained unconditionally. Nomination
    /// descends `SurveyConfig.markerDepth` levels and the signals that read a
    /// nominated node's children look one level below that, so this is that
    /// depth plus one. Deeper directories survive only by carrying something a
    /// later stage reads.
    let retentionDepth: Int

    init(fileSystem: FileSystem = RealFileSystem(),
         exclusions: Exclusions = Exclusions(),
         progressInterval: Int = 250,
         retentionDepth: Int = SurveyConfig.defaultMarkerDepth + 1) {
        self.fileSystem = fileSystem
        self.exclusions = exclusions
        self.progressInterval = progressInterval
        self.retentionDepth = retentionDepth
    }

    /// Sizes a single root. Throws `CancellationError` if the task is cancelled,
    /// so a partial total is never mistaken for a complete one.
    ///
    /// Asynchronous so it stays part of the task tree — the recursion beneath it
    /// is synchronous, and reads this task's cancellation on the same interval it
    /// reports progress.
    func size(root: URL, onProgress: (@Sendable (SurveyProgress) -> Void)? = nil) async throws -> Node {
        let standardized = root.standardizedFileURL
        guard let rootAttributes = fileSystem.attributes(of: standardized) else {
            // A root that cannot even be stat'd is unreadable, not empty.
            return Node(url: root, allocated: 0, apparent: 0, isDirectory: true,
                        modified: nil, accessed: nil, isUnreadable: true)
        }
        let counter = WalkCounter()
        let subtree = try walk(
            attributes: rootAttributes,
            depth: 0,
            rootVolumeID: rootAttributes.volumeID,
            root: standardized,
            counter: counter,
            onProgress: onProgress)
        // A directory root is always retained; a file root is retained only if a
        // signal reads it, so it may need building here.
        return subtree.node ?? leaf(from: rootAttributes, countedBytes: subtree.allocated, isRepeatLink: false)
    }

    /// Sizes several roots concurrently, one `TaskGroup` child per root (C1).
    /// Cancelling the enclosing task cancels every child.
    func size(roots: [URL], onProgress: (@Sendable (SurveyProgress) -> Void)? = nil) async throws -> [Node] {
        try await withThrowingTaskGroup(of: (Int, Node).self) { group in
            for (index, root) in roots.enumerated() {
                group.addTask {
                    (index, try await size(root: root, onProgress: onProgress))
                }
            }
            var results: [(Int, Node)] = []
            for try await result in group {
                results.append(result)
            }
            // Restore the caller's ordering; completion order is nondeterministic.
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    // What a walked subtree contributes to its parent. `node` is nil when the
    // subtree was folded away — its bytes are still counted in `allocated`.
    private struct Subtree {
        var allocated: Int64
        var apparent: Int64
        var node: Node?
    }

    private func walk(
        attributes: FileAttributes,
        depth: Int,
        rootVolumeID: UInt64?,
        root: URL,
        counter: WalkCounter,
        onProgress: (@Sendable (SurveyProgress) -> Void)?
    ) throws -> Subtree {

        // Bytes reachable by more than one path are counted the first time they
        // are seen and zeroed afterwards, so a total is what the volume would
        // actually get back rather than the sum of every directory entry.
        let isRepeatLink = attributes.linkCount > 1
            && !attributes.isDirectory
            && !counter.claimLink(attributes.fileID)
        let countedBytes = isRepeatLink ? 0 : attributes.allocated

        counter.scanned(bytes: countedBytes)
        if counter.shouldReport(every: progressInterval) {
            try Task.checkCancellation()
            onProgress?(SurveyProgress(
                root: root,
                entriesScanned: counter.entries,
                bytesSoFar: counter.bytes,
                currentPath: attributes.path))
        }

        guard attributes.isDirectory else {
            // A leaf is kept only when a signal reads it: a disk image, or a
            // CACHEDIR.TAG. Everything else folds into its parent and is dropped.
            let keep = StructuralMarkers.hasDiskImageExtension(name: attributes.name)
                || attributes.name == StructuralMarkers.cacheTagName
            return Subtree(
                allocated: countedBytes,
                apparent: attributes.apparent,
                node: keep ? leaf(from: attributes, countedBytes: countedBytes, isRepeatLink: isRepeatLink) : nil)
        }

        // The scan root keeps the URL the caller handed in, so a caller comparing
        // against its own root URL (the unreadable-roots list) still matches.
        let url = depth == 0 ? root : URL(fileURLWithPath: attributes.path, isDirectory: true)
        let children: [FileAttributes]
        do {
            children = try fileSystem.entries(of: url)
        } catch {
            // Present but unreadable — Full Disk Access, or permissions. Flagged,
            // never counted as zero (C8).
            var node = directory(from: attributes, url: url, countedBytes: countedBytes)
            node.isUnreadable = true
            return Subtree(allocated: countedBytes, apparent: attributes.apparent, node: node)
        }

        var subtreeAlloc = countedBytes
        var subtreeApp = attributes.apparent
        var retained: [Node] = []

        for child in children {
            // Symlinks: skipped entirely. Following them would count the target
            // twice and could walk out of the volume or into a cycle.
            if child.isSymbolicLink { continue }

            // Another volume: skipped, so firmlinked system content and mounted
            // disks are not folded into this root's total.
            guard exclusions.isOnBootVolume(child, rootVolumeID: rootVolumeID) else { continue }

            // C4: excluded subtrees are not descended into.
            if exclusions.descentReason(path: child.path,
                                        parentPath: attributes.path,
                                        name: child.name) != nil { continue }

            let result = try walk(
                attributes: child,
                depth: depth + 1,
                rootVolumeID: rootVolumeID,
                root: root,
                counter: counter,
                onProgress: onProgress)

            subtreeAlloc += result.allocated
            subtreeApp += result.apparent
            if let node = result.node { retained.append(node) }
        }

        // A directory is worth keeping only when a later stage can still reach
        // it: within the retention depth, or because something beneath it was
        // kept. Everything else is folded into this subtree's total and dropped.
        guard depth < retentionDepth || !retained.isEmpty else {
            return Subtree(allocated: subtreeAlloc, apparent: subtreeApp, node: nil)
        }

        var node = directory(from: attributes, url: url, countedBytes: countedBytes)
        node.children = retained
        node.subtreeAllocated = subtreeAlloc
        node.subtreeApparent = subtreeApp
        return Subtree(allocated: subtreeAlloc, apparent: subtreeApp, node: node)
    }

    // MARK: Node construction
    //
    // Both set the authoritative subtree total, so a node whose leaf children
    // were folded away still reports its true size (P-005).

    private func leaf(from attributes: FileAttributes, countedBytes: Int64, isRepeatLink: Bool) -> Node {
        var node = Node(url: URL(fileURLWithPath: attributes.path, isDirectory: attributes.isDirectory),
                        allocated: countedBytes,
                        apparent: attributes.apparent,
                        isDirectory: attributes.isDirectory,
                        modified: attributes.modified,
                        accessed: attributes.accessed,
                        isAdditionalLink: isRepeatLink)
        node.subtreeAllocated = countedBytes
        node.subtreeApparent = attributes.apparent
        return node
    }

    private func directory(from attributes: FileAttributes, url: URL, countedBytes: Int64) -> Node {
        var node = Node(url: url,
                        allocated: countedBytes,
                        apparent: attributes.apparent,
                        isDirectory: true,
                        modified: attributes.modified,
                        accessed: attributes.accessed)
        node.subtreeAllocated = countedBytes
        node.subtreeApparent = attributes.apparent
        return node
    }
}

// Shared counters across a recursive walk. A class so the recursion accumulates
// into one instance instead of threading totals back up. Each walk is
// single-threaded — roots run concurrently, a root's descent does not — so it
// needs no lock.
private final class WalkCounter {
    private(set) var entries = 0
    private(set) var bytes: Int64 = 0
    private var lastReport = 0
    private var seenLinks: Set<UInt64> = []

    /// True when this walk has not counted these bytes yet. A file with no usable
    /// identifier is counted — under-reporting a real file would be worse than
    /// the rare double count.
    func claimLink(_ fileID: UInt64?) -> Bool {
        guard let fileID else { return true }
        return seenLinks.insert(fileID).inserted
    }

    func scanned(bytes newBytes: Int64) {
        entries += 1
        bytes += newBytes
    }

    func shouldReport(every interval: Int) -> Bool {
        guard entries - lastReport >= interval else { return false }
        lastReport = entries
        return true
    }
}
