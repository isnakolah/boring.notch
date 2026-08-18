//
//  BoringNotchSkyLightWindow.swift
//  boringNotch
//
//  Created by Alexander on 2025-10-20.
//

import Cocoa
import SkyLightWindow
import Defaults
import Combine
import UniformTypeIdentifiers

extension SkyLightOperator {
    func undelegateWindow(_ window: NSWindow) {
        typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32
        
        let handler = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_NOW)
        guard let SLSRemoveWindowsFromSpaces = unsafeBitCast(
            dlsym(handler, "SLSRemoveWindowsFromSpaces"),
            to: F_SLSRemoveWindowsFromSpaces?.self
        ) else {
            return
        }
        
        // Remove the window from the SkyLight space
        _ = SLSRemoveWindowsFromSpaces(
            connection,
            [window.windowNumber] as CFArray,
            [space] as CFArray
        )
    }
}

class BoringNotchSkyLightWindow: NSPanel {
    private var isSkyLightEnabled: Bool = false
    
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: styleMask,
            backing: backing,
            defer: flag
        )
        
        configureWindow()
        setupObservers()
        startTrackingPointer()
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        buttonPollTimer?.invalidate()
    }
    
    private func configureWindow() {
        isFloatingPanel = true
        isOpaque = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        backgroundColor = .clear
        isMovable = false
        level = .mainMenu + 3
        hasShadow = false
        isReleasedWhenClosed = false
        
        // Force dark appearance regardless of system setting
        appearance = NSAppearance(named: .darkAqua)
        
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
        
        // Apply initial sharing type setting
        updateSharingType()
    }
    
    private func setupObservers() {
        // Listen for changes to the hideFromScreenRecording setting
        Defaults.publisher(.hideFromScreenRecording)
            .sink { [weak self] _ in
                self?.updateSharingType()
            }
            .store(in: &observers)
    }

    // MARK: - Click-through

    /// The part of the panel that paints something, in window coordinates.
    ///
    /// Reported by the content view, which is the only thing that knows how big
    /// the notch currently is. `.zero` until the first layout, which reads as
    /// "take every click" — the old behaviour, and the safe way to be wrong.
    private var interactiveRect: CGRect = .zero

    private var mouseMonitor: Any?

    /// Runs only while a mouse button is held, and only to watch for a drag.
    ///
    /// A drag is tracked inside the *source* app's own drag loop, so the events
    /// a global monitor sees during one are not something to rely on. Polling
    /// the pressed buttons and the drag pasteboard is; it stops on mouse-up, so
    /// an idle Mac pays nothing for it.
    private var buttonPollTimer: Timer?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragPasteboardChangeCount = -1

    /// A drag carrying something droppable is in flight somewhere on screen.
    ///
    /// Click-through is suspended for its whole duration. Proximity is not
    /// enough here: AppKit decides which windows are drag destinations as the
    /// session runs, and a panel that was ignoring mouse events when the drag
    /// reached it is simply not one — the notch never sees the drag, so it
    /// never opens. The window has to be droppable *before* the pointer
    /// arrives, which means before we know where the pointer is headed.
    private var dragSessionActive = false {
        didSet {
            guard dragSessionActive != oldValue else { return }
            applyClickThrough()
        }
    }

    /// How far outside `interactiveRect` still counts as a hit.
    ///
    /// The flag is flipped from a mouse-moved monitor, so it is always at least
    /// one event behind the pointer. The ring absorbs that lag: a click landing
    /// inside it hits the panel and is handled normally, where the same click a
    /// frame earlier would have fallen through to the desktop.
    private let hitSlack: CGFloat = 12

    /// Hands every click outside the notch to whatever is underneath.
    ///
    /// The panel is built once at `windowSize` and never resized — the notch is
    /// only ever a fraction of it, and the rest is transparent. But the window
    /// server does not hit-test by pixel: every click inside those points lands
    /// on this window, and a transparent SwiftUI region drops it rather than
    /// forwarding it. That is the dead strip under the notch. Without this the
    /// strip is as tall as the tallest mode the panel can ever open to, whether
    /// or not it is open.
    func setInteractiveRect(_ rect: CGRect) {
        guard rect != interactiveRect else { return }
        interactiveRect = rect
        applyClickThrough()
    }

    private func startTrackingPointer() {
        guard mouseMonitor == nil else { return }
        // A *global* monitor, because once the window ignores mouse events it
        // stops receiving the very move that would hand them back.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.type == .leftMouseDown {
                    // Recorded before any drag begins: the pasteboard advancing
                    // past this is what tells us one did.
                    self.dragPasteboardChangeCount = self.dragPasteboard.changeCount
                    self.startButtonPolling()
                }
                self.updateDragSession()
                self.applyClickThrough()
            }
        }
        applyClickThrough()
    }

    private func startButtonPolling() {
        guard buttonPollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.updateDragSession()
                self.applyClickThrough()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        buttonPollTimer = timer
    }

    private func stopButtonPolling() {
        buttonPollTimer?.invalidate()
        buttonPollTimer = nil
    }

    private func updateDragSession() {
        guard NSEvent.pressedMouseButtons != 0 else {
            dragSessionActive = false
            dragPasteboardChangeCount = -1
            stopButtonPolling()
            return
        }
        guard !dragSessionActive,
              dragPasteboard.changeCount != dragPasteboardChangeCount,
              hasDroppableDragContent else { return }
        dragSessionActive = true
    }

    /// Only content the notch has somewhere to put counts. A window drag or a
    /// text selection should still fall straight through.
    private var hasDroppableDragContent: Bool {
        let droppable: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            .string
        ]
        return dragPasteboard.types?.contains(where: droppable.contains) ?? false
    }

    private func applyClickThrough() {
        guard !dragSessionActive else {
            ignoresMouseEvents = false
            return
        }
        guard !interactiveRect.isEmpty else {
            ignoresMouseEvents = false
            return
        }
        let local = convertPoint(fromScreen: NSEvent.mouseLocation)
        ignoresMouseEvents = !interactiveRect.insetBy(dx: -hitSlack, dy: -hitSlack).contains(local)
    }

    private func updateSharingType() {
        // One switch decides this, including during a live call. Hiding the
        // panel from captures is exactly what someone on a call wants, but it
        // also hides it from the user's own recordings and screenshots, so it
        // stays theirs to set rather than being forced on for the call.
        if Defaults[.hideFromScreenRecording] {
            sharingType = .none
        } else {
            sharingType = .readWrite
        }
    }
    
    func enableSkyLight() {
        if !isSkyLightEnabled {
            SkyLightOperator.shared.delegateWindow(self)
            isSkyLightEnabled = true
        }
    }
    
    func disableSkyLight() {
        if isSkyLightEnabled {
            SkyLightOperator.shared.undelegateWindow(self)
            isSkyLightEnabled = false
        }
    }
    
    private var observers: Set<AnyCancellable> = []
    
    /// Text fields in the notch (the Pomodoro session title) need the panel to
    /// take key focus, but only while it is open — a closed notch stealing key
    /// would pull the caret out of whatever the user is typing in.
    nonisolated(unsafe) static var acceptsKeyFocus = false

    override var canBecomeKey: Bool { Self.acceptsKeyFocus }
    override var canBecomeMain: Bool { false }
}
