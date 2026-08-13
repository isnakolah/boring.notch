//
//  ShelfToolbar.swift
//  boringNotch
//
//  Destination picker, reachability and queue summary for the Shelf tab.
//

import SwiftUI

struct ShelfToolbar: View {
    static let height: CGFloat = 18

    @ObservedObject var shelfShare: ShelfShareService
    let itemCount: Int
    let selectedCount: Int
    let summary: String
    let canClear: Bool
    let onClear: () -> Void

    @Namespace private var destinationNamespace

    var body: some View {
        HStack(spacing: 6) {
            destinationPicker
            statusIndicator
            Spacer(minLength: 4)
            summaryLabel
            if canClear {
                Circle()
                    .fill(.white.opacity(0.25))
                    .frame(width: 2, height: 2)
                    .padding(.horizontal, 1)
                clearButton
            }
            settingsButton
        }
        .frame(height: Self.height)
    }

    // MARK: - Destination

    private var destinationPicker: some View {
        HStack(spacing: 2) {
            ForEach(LocalSendDestination.allCases) { destination in
                let isSelected = shelfShare.selectedDestination == destination
                Button {
                    withAnimation(.smooth(duration: 0.3)) { shelfShare.select(destination) }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: destination.symbolName)
                            .font(.system(size: 9, weight: .semibold))
                        Text(destination.title)
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(isSelected ? Color.effectiveAccent : Color.white.opacity(0.5))
                    .padding(.horizontal, 8)
                    .frame(height: Self.height)
                    .background {
                        if isSelected {
                            Capsule()
                                .fill(Color.effectiveAccent.opacity(0.22))
                                .matchedGeometryEffect(id: "shelfDestination", in: destinationNamespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    /// A dot alone when the destination is reachable; the word only shows up
    /// when something is actually wrong, which keeps the row narrow.
    private var statusIndicator: some View {
        Button {
            shelfShare.refreshDiscovery()
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 5, height: 5)
                    .opacity(shelfShare.isDiscovering ? 0.4 : 1)
                if let statusWord {
                    Text(statusWord)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .buttonStyle(.plain)
        .help("Refresh devices")
        .animation(.smooth(duration: 0.3), value: shelfShare.isDiscovering)
    }

    private var statusColor: Color {
        if shelfShare.selectedDestinationReady { return .green }
        return shelfShare.isPaired(shelfShare.selectedDestination) ? .orange : .white.opacity(0.25)
    }

    private var statusWord: String? {
        if shelfShare.selectedDestinationReady { return nil }
        return shelfShare.isPaired(shelfShare.selectedDestination) ? "Offline" : "Not paired"
    }

    // MARK: - Summary and controls

    private var summaryLabel: some View {
        Text(shelfShare.lastError ?? summary)
            .font(.system(size: 9, weight: .medium))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(summaryColor)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    private var summaryColor: Color {
        if shelfShare.lastError != nil { return .orange }
        return selectedCount > 0 ? Color.effectiveAccent : .white.opacity(0.45)
    }

    private var clearButton: some View {
        Button(action: onClear) {
            Text("Clear")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(shelfShare.isSending)
        .help("Remove everything from the queue")
    }

    private var settingsButton: some View {
        Button {
            SettingsWindowController.shared.showShelfWindow()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
                .frame(width: Self.height, height: Self.height)
        }
        .buttonStyle(.plain)
        .help("Shelf settings")
    }
}
