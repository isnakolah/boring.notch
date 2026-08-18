//
//  ShelfView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var shelfShare = ShelfShareService.shared
    @StateObject private var quickLookService = QuickLookService()

    // 18 + 3 + 56 + 3 + 24 = 104, the same content canvas as Usage and
    // Pomodoro. The rail takes the majority so queue rows can be legible.
    private static let rowSpacing: CGFloat = 3
    private static let railHeight: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ShelfToolbar(
                shelfShare: shelfShare,
                itemCount: tvm.items.count,
                selectedCount: selection.selectedIDs.count,
                summary: summary,
                canClear: !tvm.isEmpty,
                onClear: { tvm.clear() }
            )

            queueRail
                .frame(height: Self.railHeight)

            ShelfSendBar(
                shelfShare: shelfShare,
                itemCount: queuedItems.count,
                onSend: { Task { await shelfShare.shareShelfItems(queuedItems) } },
                onChooseFiles: { tvm.chooseFiles() },
                onOpenSettings: { SettingsWindowController.shared.showShelfWindow() }
            )
        }
        // Toolbar 18 + 6 + rail 48 + 6 + send 26 = 104, the same content canvas
        // as Usage and Pomodoro. Every row is fixed, so send status never
        // stretches the open notch.
        .frame(height: 104)
        // One drop target for the whole tab: dropping queues, sending is always
        // an explicit press.
        .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data, .image], isTargeted: $vm.dropZoneTargeting) { providers in
            handleDrop(providers: providers)
        }
        .onChange(of: tvm.items.map(\.id)) {
            if !shelfShare.isSending { shelfShare.clearTransfers() }
        }
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }

    // MARK: - Queue rail

    private var queueRail: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(isDropTargeted ? Color.effectiveAccent.opacity(0.10) : Color.white.opacity(0.04))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? Color.effectiveAccent.opacity(0.8) : Color.white.opacity(0.06),
                        lineWidth: isDropTargeted ? 1.5 : 1
                    )
            }
            .overlay { railContent.padding(4) }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            // The scroll content swallows taps aimed at a backdrop, so this has
            // to cover the whole rail — and then skip the clicks a chip already
            // handled, or selecting would immediately deselect.
            .onTapGesture {
                guard !selection.consumeChipClick() else { return }
                selection.clear()
            }
            .transaction { $0.animation = vm.animation }
    }

    @ViewBuilder
    private var railContent: some View {
        if tvm.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
                Text("Drop files here to queue")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
            }
            .foregroundStyle(.white.opacity(0.35))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // Two columns, filling row-major, scrolling down.
            //
            // It was two rows scrolling sideways, which put the fifth item off
            // the right-hand edge with nothing to say it was there — and a
            // sideways scroller of wide, short chips reads as a broken list
            // rather than a grid. Down is the direction a list of things grows.
            ScrollView(.vertical) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2),
                    alignment: .leading,
                    spacing: 4
                ) {
                    ForEach(tvm.items) { item in
                        ShelfQueueChip(
                            item: item,
                            isSelected: selection.isSelected(item.id),
                            transfer: shelfShare.transfers[item.id],
                            onRemove: { tvm.remove(item) }
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .environmentObject(quickLookService)
            .onAppear { ShelfStateViewModel.shared.cleanupInvalidItems() }
        }
    }

    // MARK: - Derived state

    private var isDropTargeted: Bool { vm.dropZoneTargeting || vm.dragDetectorTargeting }

    /// Selection narrows what Send targets, so the summary has to say so.
    private var queuedItems: [ShelfItem] {
        let selected = selection.selectedItems(in: tvm.items)
        return selected.isEmpty ? tvm.items : selected
    }

    private var summary: String {
        guard !tvm.isEmpty else { return "" }
        if selection.hasSelection {
            return "\(queuedItems.count) of \(tvm.items.count) selected"
        }
        return tvm.items.count == 1 ? "1 item" : "\(tvm.items.count) items"
    }

    // MARK: - Actions

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }

    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }

        let urls: [URL] = selection.selectedItems(in: tvm.items).compactMap { item in
            if let fileURL = item.fileURL { return fileURL }
            if case .link(let url) = item.kind { return url }
            return nil
        }

        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }
}
