import AppKit
import Combine
import Defaults
import Foundation

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

    /// A drag is over the notch and the choice is on screen.
    @Published private(set) var isChoosing = false
    /// The half under the pointer, or nil while it is between them.
    @Published private(set) var hovering: NotchDropSide?
    /// Files that landed before a side was picked, so the choice can still be
    /// made afterwards rather than the drop being lost.
    @Published private(set) var pending: [NSItemProvider] = []

    /// Whether the split is offered at all.
    ///
    /// With the copilot off there is only one thing a drop can mean, and a
    /// chooser with one option is an obstacle.
    var isSplitAvailable: Bool { Defaults[.callaCopilotEnabled] }

    private init() {}

    func beginChoosing() {
        guard isSplitAvailable else { return }
        isChoosing = true
    }

    func hover(_ side: NotchDropSide?) {
        guard isChoosing, hovering != side else { return }
        hovering = side
    }

    /// A drop that arrived without a side — the pointer was between the halves,
    /// or the drag was fast enough to be caught by the closed-notch target. The
    /// files are held and the choice stays on screen.
    func hold(_ providers: [NSItemProvider]) {
        pending = providers
    }

    func finish() {
        isChoosing = false
        hovering = nil
        pending = []
    }

    /// Which half a point falls in. The midpoint, with no dead zone: a gap in
    /// the middle would mean releasing there does nothing, and a drag that
    /// silently fails is the worst outcome available here.
    func side(forX x: CGFloat, width: CGFloat) -> NotchDropSide {
        x < width / 2 ? .shelf : .meeting
    }
}
