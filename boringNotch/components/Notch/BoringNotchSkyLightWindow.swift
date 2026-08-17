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
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyClickThrough() }
        }
        applyClickThrough()
    }

    private func applyClickThrough() {
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
