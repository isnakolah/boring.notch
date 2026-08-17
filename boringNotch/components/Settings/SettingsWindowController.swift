//
//  SettingsWindowController.swift
//  boringNotch
//
//  Created by Alexander on 2025-06-14.
//

import AppKit
import SwiftUI
import Defaults
import Sparkle

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var updaterController: SPUStandardUpdaterController?
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Wide enough for the sidebar plus a card column without the panes
        // having to reflow. Set once, here, rather than by whichever deep link
        // happened to be used last.
        window.minSize = NSSize(width: 860, height: 560)

        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdaterController(_ controller: SPUStandardUpdaterController) {
        self.updaterController = controller
        // Recreate the content view with the proper updater controller
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "Boring Notch Settings"
        window.titlebarAppearsTransparent = false
        // Each pane names itself in its own header now, so a title in the bar
        // is the same word twice. The bar itself stays: dropping it would put
        // the traffic lights on top of the sidebar's notch preview.
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        
        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle, .fullScreenAuxiliary]
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        // Configure window to be a standard document-style window
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("BoringNotchSettingsWindow")
        
        // Create the SwiftUI content
        let settingsView = SettingsView(updaterController: updaterController)
        let hostingView = NSHostingView(rootView: settingsView)
        window.contentView = hostingView
        
        // Handle window closing
        window.delegate = self
    }
    
    func showWindow() {
        // Set app to regular mode first
        NSApp.setActivationPolicy(.regular)
        
        // If window is already visible, bring it to front properly
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Show the window with proper ordering
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        
        // Activate the app and ensure window gets focus
        NSApp.activate(ignoringOtherApps: true)
        
        // Force window to front after activation
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }

    func showShelfWindow() { show(tab: "Shelf") }

    func showTutorWindow() { show(tab: "Tutor") }

    func showCopilotWindow(tab: String = "Copilot") { show(tab: tab) }

    /// Open Settings on a given pane.
    ///
    /// Each deep link used to rebuild `contentView` from scratch, and the Tutor
    /// one also resized the window to 1080x720 and left it that way for the rest
    /// of the session — so opening Tutor once permanently changed the size of
    /// every other pane. One window, one size the user chose, one content view.
    private func show(tab: String) {
        guard let window else { return }
        window.contentView = NSHostingView(
            rootView: SettingsView(initialTab: tab, updaterController: updaterController))
        showWindow()
    }
    
    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        
        // Set app back to accessory mode immediately
        NSApp.setActivationPolicy(.accessory)
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: .boringNotchSettingsWillClose, object: nil)
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure app is in regular mode when window becomes key
        NSApp.setActivationPolicy(.regular)
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
    
}

extension Notification.Name {
    static let boringNotchSettingsWillClose = Notification.Name("BoringNotchSettingsWillClose")
}
