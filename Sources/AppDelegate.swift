//
//  AppDelegate.swift
//  TallBar - Universal Adaptive Tall Menu Bar for macOS
//

import AppKit
import CoreGraphics

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let manager = TallBarDisplayManager.shared()
    
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar agent (no Dock icon)
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()

        // Universal adaptive workflow: auto-activate on launch for current main screen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.enableTallBar()
        }

        // Adaptive display listener: handles display hotplug, wake, and resolution changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.disableTallBar()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItemIcon()
        rebuildMenu()
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        
        let iconName = manager.isActive ? "rectangle.topthird.inset.filled" : "menubar.dock.rectangle"
        if let image = NSImage(systemSymbolName: iconName, accessibilityDescription: "TallBar") {
            image.isTemplate = true
            button.image = image
        } else if let fallback = NSImage(systemSymbolName: "display", accessibilityDescription: "TallBar") {
            fallback.isTemplate = true
            button.image = fallback
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // App Title
        let titleItem = NSMenuItem(title: "TallBar", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        menu.addItem(titleItem)

        // Adaptive Status Info
        if manager.isActive {
            let size = manager.activeLogicalSize
            let rate = Int(round(manager.activeRefreshRate))
            let rateStr = rate > 0 ? " @ \(rate)Hz" : ""
            let resStr = size.width > 0 ? "\(Int(size.width))x\(Int(size.height))\(rateStr)" : "Active"
            let statusItem = NSMenuItem(title: "● Tall Bar: \(resStr)", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        } else {
            let statusItem = NSMenuItem(title: "○ Standard Menu Bar", action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Toggle action
        let toggleTitle = manager.isActive ? "Disable Tall Menu Bar" : "Enable Tall Menu Bar"
        let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleTallBar), keyEquivalent: "t")
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit TallBar", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    @objc private func toggleTallBar() {
        if manager.isActive {
            disableTallBar()
        } else {
            enableTallBar()
        }
    }

    private func enableTallBar() {
        manager.enableTallBar { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    NSLog("[TallBar] Tall menu bar enabled successfully")
                } else {
                    NSLog("[TallBar] Failed to enable tall menu bar")
                }
                self?.updateStatusItemIcon()
                self?.rebuildMenu()
            }
        }
    }

    private func disableTallBar() {
        manager.disableTallBar()
        updateStatusItemIcon()
        rebuildMenu()
    }

    @objc private func screenParametersChanged() {
        // If a display reconnects or screen wake occurs while active
        if manager.isActive && manager.virtualDisplayID == 0 {
            enableTallBar()
        }
    }

    @objc private func quitApp() {
        manager.disableTallBar()
        NSApp.terminate(nil)
    }
}
