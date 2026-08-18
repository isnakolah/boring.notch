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
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        .onTapGesture { deliver(side, providers: router.pending) }
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], delegate: HalfDelegate(
            side: side,
            onHover: { router.hover($0) },
            onDrop: { providers in deliver(side, providers: providers) }))
    }

    private func deliver(_ side: NotchDropSide, providers: [NSItemProvider]) {
        guard !providers.isEmpty else { return }
        router.finish()
        switch side {
        case .shelf: onShelf(providers)
        case .meeting: onMeeting(providers)
        }
    }

    /// A delegate rather than `isTargeted:` so entering and leaving can be told
    /// apart per half — with two adjacent targets, `isTargeted` bindings race and
    /// both can read as true while the pointer crosses between them.
    private struct HalfDelegate: DropDelegate {
        let side: NotchDropSide
        let onHover: (NotchDropSide?) -> Void
        let onDrop: ([NSItemProvider]) -> Void

        func dropEntered(info: DropInfo) { onHover(side) }
        func dropExited(info: DropInfo) { onHover(nil) }
        func dropUpdated(info: DropInfo) -> DropProposal? {
            onHover(side)
            return DropProposal(operation: .copy)
        }

        func performDrop(info: DropInfo) -> Bool {
            let providers = info.itemProviders(
                for: [.fileURL, .url, .utf8PlainText, .plainText, .data])
            guard !providers.isEmpty else { return false }
            onDrop(providers)
            return true
        }
    }
}
