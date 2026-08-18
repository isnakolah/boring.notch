//
//  ShelfSendBar.swift
//  boringNotch
//
//  Full-width send action whose fill doubles as aggregate progress.
//

import SwiftUI

struct ShelfSendBar: View {
    static let height: CGFloat = 24

    @ObservedObject var shelfShare: ShelfShareService
    let itemCount: Int
    let onSend: () -> Void
    let onChooseFiles: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Button(action: primaryAction) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isEnabled ? Color.effectiveAccent.opacity(0.20) : Color.white.opacity(0.06))

                // The progress fill IS the indicator — no overlay spinner.
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.effectiveAccent.opacity(0.55))
                        .frame(width: geo.size.width * shelfShare.sendFraction)
                }
                .animation(.smooth(duration: 0.3), value: shelfShare.sendFraction)

                HStack(spacing: 5) {
                    Image(systemName: symbolName)
                        .font(.system(size: 11, weight: .semibold))
                    Text(title)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                .foregroundStyle(isEnabled ? .white : .white.opacity(0.45))
                .frame(maxWidth: .infinity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isEnabled ? Color.effectiveAccent.opacity(0.45) : Color.white.opacity(0.07),
                        lineWidth: 1
                    )
            }
            .frame(height: Self.height)
        }
        .buttonStyle(.plain)
        .disabled(shelfShare.isSending)
    }

    // MARK: - State

    private var isEnabled: Bool {
        !shelfShare.isSending && (itemCount == 0 || (shelfShare.isAvailable && shelfShare.selectedDestinationReady))
    }

    private var symbolName: String {
        if shelfShare.isSending { return "arrow.up.circle" }
        if itemCount == 0 { return "plus.circle" }
        return shelfShare.selectedDestinationReady ? "arrow.up.circle.fill" : "exclamationmark.circle"
    }

    private var title: String {
        let destination = shelfShare.selectedDestination.title
        if shelfShare.isSending {
            let percent = Int(shelfShare.sendFraction * 100)
            return "Sending \(shelfShare.completedFileCount) of \(shelfShare.totalFileCount) · \(percent)%"
        }
        if itemCount == 0 { return "Add files to queue" }
        guard shelfShare.isAvailable else { return "Turn on a send provider in Shelf settings" }
        guard shelfShare.selectedDestinationReady else { return "Pair \(destination) in Shelf settings" }
        return itemCount == 1 ? "Send 1 item to \(destination)" : "Send \(itemCount) items to \(destination)"
    }

    private func primaryAction() {
        if itemCount == 0 { onChooseFiles(); return }
        guard shelfShare.selectedDestinationReady else { onOpenSettings(); return }
        onSend()
    }
}
