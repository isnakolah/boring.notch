//
//  ShelfDragHandler.swift
//  boringNotch
//
//  AppKit click/drag routing for shelf items.
//

import AppKit
import Defaults
import SwiftUI

/// SwiftUI's `.onDrag` cannot express what the shelf needs: one drag session
/// carrying several files, a completion hook to release security-scoped access,
/// `copyOnDrag` (needs `sourceOperationMaskFor`), and `autoRemoveShelfItems`
/// (needs the resulting `NSDragOperation`). So click and drag both go through
/// AppKit here, and only the small hover buttons stay in SwiftUI.
struct ShelfDragHandler: NSViewRepresentable {
    let item: ShelfItem
    let viewModel: ShelfItemViewModel
    let dragPreviewImage: NSImage?
    /// Rects, in the handler's own coordinate space, that this view must not
    /// swallow — the SwiftUI buttons layered above it.
    var passthroughRects: [CGRect] = []
    let onRightClick: (NSEvent, NSView) -> Void
    let onClick: (NSEvent, NSView) -> Void

    func makeNSView(context: Context) -> DraggableClickView {
        let view = DraggableClickView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: DraggableClickView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: DraggableClickView) {
        view.item = item
        view.viewModel = viewModel
        if let dragPreviewImage { view.dragPreviewImage = dragPreviewImage }
        view.passthroughRects = passthroughRects
        view.onRightClick = onRightClick
        view.onClick = onClick
    }

    final class DraggableClickView: NSView, NSDraggingSource {
        var item: ShelfItem!
        weak var viewModel: ShelfItemViewModel?
        var dragPreviewImage: NSImage?
        var passthroughRects: [CGRect] = []
        var onRightClick: ((NSEvent, NSView) -> Void)?
        var onClick: ((NSEvent, NSView) -> Void)?

        private var mouseDownEvent: NSEvent?
        private let dragThreshold: CGFloat = 3.0
        private var draggedURLs: [URL] = []
        private var draggedItems: [ShelfItem] = []

        /// Top-left origin, so `passthroughRects` can be written in the same
        /// coordinate space as the SwiftUI layout above.
        override var isFlipped: Bool { true }

        /// The notch is a non-activating panel, so without this the first click
        /// on a chip is swallowed to activate the window and never reaches
        /// `mouseDown` — selection would need two clicks.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        /// Lets clicks fall through to the SwiftUI remove / Quick Look buttons
        /// stacked above this overlay.
        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = convert(point, from: superview)
            if passthroughRects.contains(where: { $0.contains(local) }) { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick?(event, self)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownEvent = event
            onClick?(event, self)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let mouseDownEvent else {
                super.mouseDragged(with: event)
                return
            }

            let dragDistance = hypot(
                event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                event.locationInWindow.y - mouseDownEvent.locationInWindow.y
            )

            if dragDistance > dragThreshold {
                startDragSession(with: event)
                self.mouseDownEvent = nil
            } else {
                super.mouseDragged(with: event)
            }
        }

        private func startDragSession(with event: NSEvent) {
            let selectedItems = ShelfSelectionModel.shared.selectedItems(in: ShelfStateViewModel.shared.items)
            let itemsToDrag: [ShelfItem]

            if selectedItems.count > 1 && selectedItems.contains(where: { $0.id == item.id }) {
                itemsToDrag = selectedItems
            } else {
                itemsToDrag = [item]
            }

            draggedItems = itemsToDrag

            var draggingItems: [NSDraggingItem] = []
            for dragItem in itemsToDrag {
                guard let pasteboardItem = createPasteboardItem(for: dragItem) else { continue }
                let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
                let image = dragPreviewImage ?? dragItem.icon
                draggingItem.setDraggingFrame(
                    NSRect(x: 0, y: 0, width: image.size.width, height: image.size.height),
                    contents: image
                )
                draggingItems.append(draggingItem)
            }

            guard !draggingItems.isEmpty else { return }
            beginDraggingSession(with: draggingItems, event: event, source: self)
        }

        private func createPasteboardItem(for item: ShelfItem) -> NSPasteboardItem? {
            let pasteboardItem = NSPasteboardItem()

            switch item.kind {
            case .file:
                guard let url = ShelfStateViewModel.shared.resolveAndUpdateBookmark(for: item) else {
                    pasteboardItem.setString(item.displayName, forType: .string)
                    return pasteboardItem
                }
                // Held open until draggingSession(_:endedAt:operation:) fires.
                if url.startAccessingSecurityScopedResource() {
                    draggedURLs.append(url)
                }
                pasteboardItem.setString(url.absoluteString, forType: .fileURL)
                pasteboardItem.setString(url.path, forType: .string)
                return pasteboardItem

            case .text(let string):
                pasteboardItem.setString(string, forType: .string)
                return pasteboardItem

            case .link(let url):
                pasteboardItem.setString(url.absoluteString, forType: .URL)
                pasteboardItem.setString(url.absoluteString, forType: .string)
                return pasteboardItem
            }
        }

        // MARK: - NSDraggingSource

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            if Defaults[.copyOnDrag] { return [.copy] }

            switch context {
            case .outsideApplication: return [.copy, .move]
            case .withinApplication: return [.copy, .move, .generic]
            @unknown default: return [.copy]
            }
        }

        func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
            ShelfSelectionModel.shared.beginDrag()
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            ShelfSelectionModel.shared.endDrag()

            for url in draggedURLs { url.stopAccessingSecurityScopedResource() }
            draggedURLs.removeAll()

            if Defaults[.autoRemoveShelfItems] && !operation.isEmpty {
                for item in draggedItems { ShelfStateViewModel.shared.remove(item) }
            }
            draggedItems.removeAll()
        }

        func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }
    }
}
