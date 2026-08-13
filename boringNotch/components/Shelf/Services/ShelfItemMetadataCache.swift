//
//  ShelfItemMetadataCache.swift
//  boringNotch
//
//  Name, size and preview for shelf queue chips.
//

import AppKit
import Foundation

/// Everything a queue chip needs to draw itself.
struct ShelfItemMetadata: Equatable, Sendable {
    var displayName: String
    var detail: String?
    var url: URL?
}

/// `ShelfItem.displayName` and `.icon` resolve a security-scoped bookmark from
/// disk on every access, and the resolve can schedule a bookmark refresh that
/// republishes `items` — so reading them from a view body puts the shelf in a
/// render loop. Chips read this instead, once per item.
@MainActor
final class ShelfItemMetadataCache: ObservableObject {
    static let shared = ShelfItemMetadataCache()

    private var store: [UUID: ShelfItemMetadata] = [:]
    private var inFlight: [UUID: Task<ShelfItemMetadata, Never>] = [:]

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private init() {}

    func cached(_ id: UUID) -> ShelfItemMetadata? { store[id] }

    /// The resolved file URL, if we have already looked this item up. Used to
    /// evict the thumbnail cache on removal without re-resolving the bookmark.
    func cachedURL(for id: UUID) -> URL? { store[id]?.url }

    func metadata(for item: ShelfItem) async -> ShelfItemMetadata {
        if let hit = store[item.id] { return hit }
        if let running = inFlight[item.id] { return await running.value }

        let task = Task { [weak self] () -> ShelfItemMetadata in
            let resolved = await self?.resolve(item) ?? ShelfItemMetadata(displayName: "", detail: nil, url: nil)
            self?.store[item.id] = resolved
            self?.inFlight[item.id] = nil
            return resolved
        }
        inFlight[item.id] = task
        return await task.value
    }

    func invalidate(_ id: UUID) {
        inFlight[id]?.cancel()
        inFlight[id] = nil
        store[id] = nil
    }

    func invalidateAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        store.removeAll()
    }

    // MARK: - Resolution

    private func resolve(_ item: ShelfItem) async -> ShelfItemMetadata {
        switch item.kind {
        case .file:
            // Bookmark resolution has to happen on the main actor, but the disk
            // reads behind it do not.
            let url = ShelfStateViewModel.shared.resolveFileURL(for: item)
            let name = item.displayName
            guard let url else {
                return ShelfItemMetadata(displayName: name, detail: nil, url: nil)
            }
            // A 104pt chip cannot show "deep-research-report.md", and middle
            // truncation eats exactly the part that tells files apart. Move the
            // extension down to the detail line, where there is room.
            let ext = url.pathExtension.uppercased()
            let stem = ext.isEmpty ? name : name.replacingOccurrences(
                of: ".\(url.pathExtension)",
                with: "",
                options: [.anchored, .backwards, .caseInsensitive]
            )
            let size = Self.format(await Self.inspect(url))
            let detail = [ext.isEmpty ? nil : ext, size]
                .compactMap { $0 }
                .joined(separator: " · ")
            return ShelfItemMetadata(
                displayName: stem,
                detail: detail.isEmpty ? nil : detail,
                url: url
            )

        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.components(separatedBy: .newlines).first ?? trimmed
            return ShelfItemMetadata(
                displayName: name.isEmpty ? "Text" : name,
                detail: "\(trimmed.count) characters",
                url: nil
            )

        case .link(let url):
            return ShelfItemMetadata(
                displayName: item.displayName,
                detail: url.host() ?? "Link",
                url: url
            )
        }
    }

    private enum FileFacts: Sendable {
        case bytes(Int64)
        case directory(count: Int)
        case unknown
    }

    /// Disk reads run off the main actor; formatting stays on it so the shared
    /// non-Sendable ByteCountFormatter never escapes.
    private nonisolated static func inspect(_ url: URL) async -> FileFacts {
        await Task.detached(priority: .utility) { () -> FileFacts in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]) else { return .unknown }
            if values.isDirectory == true {
                return .directory(count: (try? FileManager.default.contentsOfDirectory(atPath: url.path).count) ?? 0)
            }
            guard let size = values.fileSize else { return .unknown }
            return .bytes(Int64(size))
        }.value
    }

    private static func format(_ facts: FileFacts) -> String? {
        switch facts {
        case .bytes(let size): byteFormatter.string(fromByteCount: size)
        case .directory(let count): count == 1 ? "1 item" : "\(count) items"
        case .unknown: nil
        }
    }
}
