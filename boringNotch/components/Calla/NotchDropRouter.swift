import AppKit
import OSLog
import Combine
import Defaults
import Foundation
import UniformTypeIdentifiers

/// Which half of the notch a dragged file is over.
enum NotchDropSide: Equatable {
    /// Keep it, and send it on — exactly what dropping has always done.
    case shelf
    /// Give it to the copilot for a meeting.
    case meeting
}

/// Decides what a file dropped on the notch is *for*.
///
/// Dropping used to do three things at once — land in the Shelf, start a transfer
/// to the paired device, and (once the copilot could read documents) open a
/// meeting picker — with nothing on screen to say which. That is not a flow, it is
/// three flows sharing a gesture.
///
/// So the gesture asks. While a file is over the notch it splits in two, and the
/// half under the pointer is the one that will run. Nothing happens until release,
/// and in particular nothing is *sent* unless the Shelf half is chosen: a document
/// meant for a meeting should not also be transmitted to a phone.
@MainActor
final class NotchDropRouter: ObservableObject {
    static let shared = NotchDropRouter()

    /// Tracing for the drop flow, which spans four drop targets in two
    /// frameworks and could not be reasoned about from the code alone.
    ///   log show --predicate 'subsystem == "theboringteam.boringnotch"' --last 5m
    static let log = Logger(subsystem: "theboringteam.boringnotch", category: "drop")

    /// A drag is over the notch and the choice is on screen.
    @Published private(set) var isChoosing = false
    /// The half under the pointer, or nil while it is between them.
    @Published private(set) var hovering: NotchDropSide?
    /// Files that landed before a side was picked, so the choice can still be
    /// made afterwards rather than the drop being lost.
    @Published private(set) var pending: [NSItemProvider] = []
    /// A side has been chosen and its pane is on its way up.
    ///
    /// The Remember path only sets `currentView` after reading the files and
    /// asking EventKit for meetings, and `isChoosing` is already false by then —
    /// so for the length of that await nothing was guarding the view, and
    /// whatever wrote to it last won. This keeps the guard armed until the
    /// destination is actually on screen.
    @Published private(set) var isDelivering = false

    /// Whether the drop flow owns `coordinator.currentView` right now. Nothing
    /// else may write it while this is true.
    var ownsCurrentView: Bool { isChoosing || isDelivering }

    /// Whether the split is offered at all.
    ///
    /// With the copilot off there is only one thing a drop can mean, and a
    /// chooser with one option is an obstacle.
    var isSplitAvailable: Bool { Defaults[.callaCopilotEnabled] }

    private init() {}

    func beginChoosing() {
        guard isSplitAvailable else {
            Self.log.info("beginChoosing refused: split unavailable (copilot off)")
            return
        }
        Self.log.info("beginChoosing")
        isChoosing = true
    }

    func hover(_ side: NotchDropSide?) {
        guard isChoosing, hovering != side else { return }
        Self.log.info("hover \(String(describing: side), privacy: .public)")
        hovering = side
    }

    /// Claims the view until the chosen pane is up.
    ///
    /// Watchdogged, because a destination that never arrives — a failed read, a
    /// cancelled task — would otherwise pin the notch to one view for the rest
    /// of the session.
    func beginDelivering() {
        Self.log.info("beginDelivering")
        isDelivering = true
        deliveryWatchdog?.cancel()
        deliveryWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            Self.log.error("delivery watchdog fired: no destination arrived")
            self?.isDelivering = false
        }
    }

    func endDelivering() {
        Self.log.info("endDelivering")
        deliveryWatchdog?.cancel()
        deliveryWatchdog = nil
        isDelivering = false
    }

    /// A drop that arrived without a side — the pointer was between the halves,
    /// or the drag was fast enough to be caught by the closed-notch target. The
    /// files are held and the choice stays on screen.
    ///
    /// The file URLs are resolved *now*, while the drag session is still alive.
    /// An `NSItemProvider` from a finished drop is not reliably loadable
    /// afterwards, so holding the providers and reading them when a half is
    /// finally clicked returned nothing — and "nothing readable here" is exactly
    /// the condition that falls back to the Shelf, which is why choosing
    /// Remember landed on the Shelf anyway.
    func hold(_ providers: [NSItemProvider]) {
        Self.log.info("hold \(providers.count) provider(s)")
        pending = providers
        generation &+= 1
        let generation = generation
        resolveTask?.cancel()
        resolveTask = Task { [weak self] in
            let urls = await Self.resolveFileURLs(providers)
            Self.log.info("resolved \(urls.count) url(s): \(urls.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
            // A resolve that finishes after its drop was finished belongs to
            // nobody. Writing it back handed the *next* drop the *previous*
            // drop's files.
            guard let self, !Task.isCancelled, generation == self.generation, !urls.isEmpty else { return }
            self.pendingURLs = urls
        }
    }

    /// Which drop the in-flight resolve belongs to.
    private var generation: UInt64 = 0
    private var resolveTask: Task<Void, Never>?
    private var deliveryWatchdog: Task<Void, Never>?

    /// The same files as `pending`, already resolved to URLs.
    @Published private(set) var pendingURLs: [URL] = []

    /// Providers rebuilt from the resolved URLs, so a click on a half has
    /// something loadable to work with however long it has been.
    var deliverableProviders: [NSItemProvider] {
        if !pendingURLs.isEmpty {
            return pendingURLs.map { NSItemProvider(contentsOf: $0) }.compactMap { $0 }
        }
        return pending
    }

    /// Pulls file URLs out of a drop, whichever way the provider was made.
    ///
    /// `public.url` as well as `public.file-url`: a provider built with
    /// `NSItemProvider(object: NSURL)` — which is how the AppKit drop target
    /// packages a Finder drag — registers only the former, so a file-URL-only
    /// resolver read every one of those drops as carrying nothing. That looked
    /// exactly like "no readable files here", and it is why Remember reported
    /// nothing to attach.
    static func resolveFileURLs(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let identifiers = [UTType.fileURL.identifier, UTType.url.identifier]
                .filter(provider.hasItemConformingToTypeIdentifier)
            for identifier in identifiers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: identifier) { item, _ in
                        if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else {
                            continuation.resume(returning: item as? URL)
                        }
                    }
                }
                if let url, url.isFileURL {
                    urls.append(url)
                    break
                }
            }
        }
        return urls
    }

    func finish() {
        Self.log.info("finish")
        isChoosing = false
        hovering = nil
        pending = []
        pendingURLs = []
        generation &+= 1
        resolveTask?.cancel()
        resolveTask = nil
    }

    /// Which half a point falls in. The midpoint, with no dead zone: a gap in
    /// the middle would mean releasing there does nothing, and a drag that
    /// silently fails is the worst outcome available here.
    func side(forX x: CGFloat, width: CGFloat) -> NotchDropSide {
        x < width / 2 ? .shelf : .meeting
    }
}
