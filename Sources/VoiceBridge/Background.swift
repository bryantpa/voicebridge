import AppKit
import SwiftUI

@MainActor final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var window: NSWindow!
    private var model: Model!
    private var statusItem: NSStatusItem!
    private var statusTimer: Timer?
    private let summaryItem = NSMenuItem(title: "VoiceBridge — stopped", action: nil, keyEquivalent: "")
    private let routeItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "Start Microphone", action: #selector(toggleMicrophone), keyEquivalent: "")
    private let bypassItem = NSMenuItem(title: "Bypass Processing", action: #selector(toggleBypass), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A project build and /Applications copy can otherwise run together.
        // Keep one owner of the microphone and one menu-bar icon.
        if let id=Bundle.main.bundleIdentifier,
           let existing=NSRunningApplication.runningApplications(withBundleIdentifier:id)
            .first(where:{$0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated}) {
            existing.activate(options:[])
            NSApp.terminate(nil)
            return
        }
        model = Model()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 784, height: 1040),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "VoiceBridge — microphone diagnostics"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: Panel(model: model))
        window.center()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.setAccessibilityLabel("VoiceBridge")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        summaryItem.isEnabled = false
        routeItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(routeItem)
        menu.addItem(.separator())
        add("Show Diagnostics…", action: #selector(showDiagnostics), to: menu)
        toggleItem.target = self
        menu.addItem(toggleItem)
        bypassItem.target = self
        menu.addItem(bypassItem)
        add("Show Reports", action: #selector(showReports), to: menu)
        menu.addItem(.separator())
        add("Quit VoiceBridge", action: #selector(quit), to: menu)
        statusItem.menu = menu

        let mainMenu = NSMenu(), appItem = NSMenuItem(), appMenu = NSMenu()
        add("Show Diagnostics…", action: #selector(showDiagnostics), to: appMenu)
        let close = NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(close)
        let quitItem = NSMenuItem(title: "Quit VoiceBridge", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        appMenu.addItem(quitItem)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        NSApp.mainMenu = mainMenu

        updateMenu()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMenu() }
        }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
        showDiagnostics()
    }

    private func add(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    private func updateMenu() {
        let state = model.starting ? "starting…" : (model.running ? (model.sending ? "microphone on" : "analysis only") : "stopped")
        summaryItem.title = "VoiceBridge — \(state)"
        routeItem.title = model.running ? (model.bypass ? "Processing bypassed" : (model.echoEnabled && model.backend == "RNNoise" ? "Noise + echo reduction" : model.backend)) : "Open diagnostics for settings"
        toggleItem.title = model.running ? "Stop Microphone" : "Start Microphone"
        toggleItem.isEnabled = !model.starting
        bypassItem.isEnabled = model.running
        bypassItem.state = model.bypass ? .on : .off
        let symbol = model.running ? (model.sending ? "mic.fill" : "waveform") : "mic.slash"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "VoiceBridge — \(state)")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "VoiceBridge — \(state)"
    }

    func menuWillOpen(_ menu: NSMenu) { updateMenu() }
    @objc private func showDiagnostics() {
        window.deminiaturize(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.meterVisible = true
        model.diagnostics?.event("diagnostics_shown")
    }
    @objc private func toggleMicrophone() {
        if model.running { model.stop(reason: "Microphone stopped from menu bar.") } else { model.start() }
        updateMenu()
        if !model.running { showDiagnostics() }
    }
    @objc private func toggleBypass() { model.setBypass(!model.bypass); updateMenu() }
    @objc private func showReports() { model.revealReports() }
    @objc private func quit() { NSApp.terminate(nil) }
    // Closed, minimized, covered, or on another Space: stop redrawing the meter.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        model.meterVisible = window.occlusionState.contains(.visible)
    }
    func windowWillClose(_ notification: Notification) {
        model.meterVisible = false
        model.saveSettings()
        model.diagnostics?.event("diagnostics_hidden", ["running": model.running, "sending": model.sending])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard model != nil else {return false}
        showDiagnostics()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        statusTimer?.invalidate()
        model?.saveSettings()
        model?.stop(reason: "App quit")
    }
}
