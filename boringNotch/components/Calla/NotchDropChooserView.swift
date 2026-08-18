import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// The two things a dropped file can be for, side by side.
///
/// Shown while the file is still in the air. Both halves are drop targets and the
/// one under the pointer lights up, so the answer to "what happens if I let go
/// here" is on screen at the moment the question is being asked — which is the
/// whole complaint this exists to fix.
///
/// The wording is what each half *does*, not what it is called: "Keep and send"
/// rather than "Shelf", because the transfer to a paired device is the part that
/// is surprising if you did not expect it.
struct NotchDropChooserView: View {
    @ObservedObject private var router = NotchDropRouter.shared
    @EnvironmentObject var coordinator: BoringViewCoordinator

    /// Runs the Shelf's own path — unchanged, including the transfer.
    var onShelf: ([NSItemProvider]) -> Void
    /// Hands the files to the copilot. Nothing is sent anywhere.
    var onMeeting: ([NSItemProvider]) -> Void
    /// Dwelling on a half opens that half's own pane, so the file can be dropped
    /// straight into it — onto a particular meeting, or onto the Shelf queue.
    var onSpringLoad: (NotchDropSide) -> Void

    @State private var springTask: Task<Void, Never>?
    /// Width of the two halves together, for the midpoint split.
    @State private var halvesWidth: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(spacing: 10) {
                half(
                    side: .shelf,
                    symbol: "paperplane.fill",
                    title: "Send",
                    detail: "Keeps it on the Shelf and sends it to your phone",
                    tint: .white)
                half(
                    side: .meeting,
                    symbol: "brain",
                    title: "Remember",
                    detail: "Attaches it to a meeting for the copilot to read",
                    tint: Color.effectiveAccent)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { halvesWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in halvesWidth = width }
                })
            // One target across both halves rather than one each. Two adjacent
            // targets race on the crossing — both can read as entered — and the
            // gap between them was a dead zone where a release fell through to
            // the notch's outer target and only re-asked the question.
            .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: SplitDelegate(
                width: { halvesWidth },
                onHover: { router.hover($0) },
                onDrop: { side, providers in deliver(side, providers: providers) }))
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Spring-loading, the way a Finder folder opens if you hold a drag over
        // it. Holding still is the gesture for "this one, show me inside" —
        // which for Remember means the meeting list, and there is no other way
        // to aim a file at a particular meeting mid-drag.
        .onChange(of: router.hovering) { _, side in
            springTask?.cancel()
            // Only a held *drag* springs a half open. With the files already in
            // hand the halves are buttons, and resting the pointer on one is
            // not the same as choosing it.
            guard let side, router.pending.isEmpty else { return }
            springTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(420))
                guard !Task.isCancelled, router.hovering == side else { return }
                NotchDropRouter.log.info("springLoad \(String(describing: side), privacy: .public)")
                onSpringLoad(side)
            }
        }
        .onDisappear { springTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.5))
            Text(router.pending.isEmpty ? "DROP ON ONE SIDE" : "WHERE SHOULD IT GO?")
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.5))
            Spacer(minLength: 0)
            if !router.pending.isEmpty {
                Button("Cancel") {
                    router.finish()
                    coordinator.currentView = .home
                }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.5))
            }
        }
    }

    /// One half. A drop target *and* a button — after a drop that arrived without
    /// a side, the same panel has to be clickable rather than requiring the file
    /// to be dragged a second time.
    private func half(
        side: NotchDropSide,
        symbol: String,
        title: String,
        detail: String,
        tint: Color
    ) -> some View {
        let active = router.hovering == side

        return VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(active ? tint : tint.opacity(0.55))
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Text(detail)
                .font(.system(size: 9.5))
                .foregroundStyle(Color.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(active ? tint.opacity(0.16) : Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(
                    active ? tint : Color.white.opacity(0.14),
                    style: StrokeStyle(lineWidth: active ? 1.5 : 1, dash: active ? [] : [4, 3])))
        .scaleEffect(active ? 1.02 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)
        .contentShape(Rectangle())
        // Pointer hover, not drag hover. Once the files have already landed the
        // chooser is a pair of buttons waiting for a click, and no drag session
        // is left to light a half up — so the only feedback for "this one" was
        // the click itself, after the choice had already been made.
        .onHover { inside in
            guard !router.pending.isEmpty else { return }
            // Only clear what this half lit. Leaving one half is reported after
            // entering the next, so clearing unconditionally would blank the
            // highlight the neighbour just set.
            if inside { router.hover(side) } else if router.hovering == side { router.hover(nil) }
        }
        .onTapGesture { deliver(side, providers: router.deliverableProviders) }
    }

    private func deliver(_ side: NotchDropSide, providers: [NSItemProvider]) {
        NotchDropRouter.log.info("deliver \(String(describing: side), privacy: .public) with \(providers.count) provider(s)")
        guard !providers.isEmpty else {
            NotchDropRouter.log.error("deliver aborted: no providers")
            return
        }
        // Claimed before `finish()` clears `isChoosing`, so the guards on
        // `close()` and the close debounce stay armed across the Remember
        // path's awaits. The destination releases it.
        router.beginDelivering()
        router.finish()
        switch side {
        case .shelf: onShelf(providers)
        case .meeting: onMeeting(providers)
        }
    }

    /// One target over both halves, splitting on the midpoint.
    ///
    /// A delegate rather than `isTargeted:` because the side has to come from
    /// where the pointer is, which only `DropInfo.location` knows.
    private struct SplitDelegate: DropDelegate {
        let width: () -> CGFloat
        let onHover: (NotchDropSide?) -> Void
        let onDrop: (NotchDropSide, [NSItemProvider]) -> Void

        @MainActor
        private func side(at info: DropInfo) -> NotchDropSide {
            NotchDropRouter.shared.side(forX: info.location.x, width: width())
        }

        func dropEntered(info: DropInfo) { onHover(side(at: info)) }
        func dropExited(info: DropInfo) { onHover(nil) }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            onHover(side(at: info))
            return DropProposal(operation: .copy)
        }

        func performDrop(info: DropInfo) -> Bool {
            let providers = info.itemProviders(
                for: [.fileURL, .url, .utf8PlainText, .plainText, .data])
            guard !providers.isEmpty else { return false }
            onDrop(side(at: info), providers)
            return true
        }
    }
}
