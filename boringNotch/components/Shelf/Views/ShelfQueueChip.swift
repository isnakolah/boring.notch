//
//  ShelfQueueChip.swift
//  boringNotch
//
//  A single queued item in the Shelf rail.
//

import AppKit
import SwiftUI

/// A full-width row rather than a square tile: at 450pt the rail can afford two
/// columns of ~210pt, which leaves real room for a filename instead of the
/// eight characters a 104pt tile allowed.
struct ShelfQueueChip: View {
    static let size = CGSize(width: 210, height: 22)

    let item: ShelfItem
    let isSelected: Bool
    let transfer: ShelfTransferState?
    let onRemove: () -> Void

    @EnvironmentObject private var quickLookService: QuickLookService
    @StateObject private var viewModel: ShelfItemViewModel
    @State private var meta: ShelfItemMetadata?
    @State private var isHovering = false

    init(item: ShelfItem, isSelected: Bool, transfer: ShelfTransferState?, onRemove: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.transfer = transfer
        self.onRemove = onRemove
        _viewModel = StateObject(wrappedValue: ShelfItemViewModel(item: item))
    }

    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        rowContent
            .frame(width: Self.size.width, height: Self.size.height)
            .background { background }
            .overlay(alignment: .bottom) { progressBar }
            .clipShape(Self.shape)
            .contentShape(Self.shape)
            .overlay { dragHandler }
            .onHover { hovering in
                withAnimation(.smooth(duration: 0.2)) { isHovering = hovering }
            }
            .task(id: item.id) {
                meta = await ShelfItemMetadataCache.shared.metadata(for: item)
            }
            .onAppear {
                viewModel.onQuickLookRequest = { urls in
                    quickLookService.show(urls: urls, selectFirst: true)
                }
            }
            .help(meta?.displayName ?? "")
    }

    private var rowContent: some View {
        HStack(spacing: 7) {
            thumbnail
            name
            Spacer(minLength: 4)
            trailingSlot
        }
        .padding(.horizontal, 7)
    }

    private var name: some View {
        Text(meta?.displayName ?? " ")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .truncationMode(.tail)
            .redacted(reason: meta == nil ? .placeholder : [])
    }

    private var background: some View {
        Self.shape
            .fill(fillColor)
            .overlay { Self.shape.strokeBorder(strokeColor, lineWidth: 1) }
    }

    private var dragHandler: some View {
        ShelfDragHandler(
            item: item,
            viewModel: viewModel,
            dragPreviewImage: viewModel.thumbnail,
            passthroughRects: isHovering ? Self.actionHitRects : [],
            onRightClick: { event, view in viewModel.handleRightClick(event: event, view: view) },
            onClick: { event, view in viewModel.handleClick(event: event, view: view) }
        )
    }

    /// Kept in sync with the layout below so the AppKit drag overlay lets these
    /// two clicks through.
    private static let actionHitRects: [CGRect] = [
        CGRect(x: 4, y: 1, width: 22, height: 20),                  // Quick Look, over the thumbnail
        CGRect(x: size.width - 24, y: 1, width: 22, height: 20)     // remove
    ]

    // MARK: - Pieces

    private var thumbnail: some View {
        ZStack {
            Image(nsImage: viewModel.thumbnail ?? item.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .opacity(isHovering ? 0.2 : 1)

            if isHovering {
                Image(systemName: "eye")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .transition(.opacity)
            }
        }
        .frame(width: 16, height: 16)
        .onTapGesture { viewModel.quickLookSelection() }
    }

    @ViewBuilder
    private var trailingSlot: some View {
        if isHovering {
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .transition(.opacity)
            .help("Remove from queue")
        } else if let badge = stateBadge {
            Image(systemName: badge.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(badge.color)
        } else if isSelected {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.effectiveAccent)
        } else {
            Text(detailText)
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(detailColor)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    @ViewBuilder
    private var progressBar: some View {
        if case .sending(let fraction) = transfer {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.12))
                    Rectangle()
                        .fill(Color.effectiveAccent)
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 2)
            .animation(.smooth(duration: 0.25), value: fraction)
        }
    }

    // MARK: - Derived state

    private var fillColor: Color {
        if isSelected { return Color.effectiveAccent.opacity(0.18) }
        return Color.white.opacity(isHovering ? 0.10 : 0.05)
    }

    private var strokeColor: Color {
        isSelected ? Color.effectiveAccent.opacity(0.7) : Color.white.opacity(0.07)
    }

    private var detailText: String {
        switch transfer {
        case .pending: "Queued"
        case .sending(let fraction): "\(Int(fraction * 100))%"
        case .sent: "Sent"
        case .failed(let reason): reason
        case nil: meta?.detail ?? ""
        }
    }

    private var detailColor: Color {
        switch transfer {
        case .sending: Color.effectiveAccent
        case .failed: .orange
        default: .white.opacity(0.42)
        }
    }

    private var stateBadge: (symbol: String, color: Color)? {
        switch transfer {
        case .sent: ("checkmark.circle.fill", .green)
        case .failed: ("exclamationmark.triangle.fill", .orange)
        default: nil
        }
    }
}
