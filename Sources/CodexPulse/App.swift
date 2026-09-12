import AppKit
import SwiftUI
import Combine
import CodexPulseCore

@main
struct CodexPulseMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var store: MonitorStore!
    private var cancellable: AnyCancellable?
    private var preview: NSWindow?
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let demo = args.contains("--demo")
        let diagnosing = args.contains("--diagnose")
        store = MonitorStore(demo: demo)
        if !diagnosing {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Codex Pulse")
                button.imagePosition = .imageLeading
                button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                button.target = self; button.action = #selector(togglePopover)
                button.setAccessibilityLabel("Codex Pulse，点击查看任务与额度")
            }
            popover.contentSize = NSSize(width: 460, height: 690)
            popover.behavior = .transient
            popover.delegate = self
            popover.contentViewController = NSHostingController(rootView: DashboardView(store: store))
            cancellable = store.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.updateStatus() }
            }
            updateStatus()
        }
        store.dismissPanel = { [weak self] in self?.closePopover() }
        store.start()
        if let index = args.firstIndex(of: "--tab"), args.count > index + 1, let tab = Int(args[index + 1]) {
            store.selectedTab = min(3, max(0, tab))
        }
        if args.contains("--preview") || args.contains("--screenshot") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 690),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = demo ? "Codex Pulse · 演示" : "Codex Pulse"
            window.contentView = NSHostingView(rootView: DashboardView(store: store))
            if args.contains("--dark") { window.appearance = NSAppearance(named: .darkAqua) }
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            preview = window
            if let index = args.firstIndex(of: "--screenshot"), args.count > index + 1 {
                let path = args[index + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 2 : 15)) { [weak self] in
                    self?.capture(path: path)
                }
            }
        }
        if args.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.togglePopover() }
        }
        if diagnosing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self else { return }
                let summary: [String: Any] = [
                    "cliFound": RPCClient.locateCLI() != nil,
                    "connected": self.store.connected,
                    "quotaAvailable": self.store.quota != nil,
                    "quotaBucketCount": self.store.quota?.buckets.count ?? 0,
                    "usageAvailable": self.store.usage != nil,
                    "localReadOK": self.store.localError == nil && self.store.localUpdated != nil,
                    "sessionCount": self.store.sessions.count,
                    "runningCount": self.store.runningCount,
                    "quietCount": self.store.quietCount
                ]
                if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { print(text) }
                NSApp.terminate(nil)
            }
        }
    }

    private func capture(path: String) {
        guard let view = preview?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { NSApp.terminate(nil); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
        NSApp.terminate(nil)
    }

    private func updateStatus() {
        item?.button?.title = store.compactStatus ? "" : " " + store.statusLabel
        item?.button?.toolTip = "Codex Pulse · \(store.runningCount) 个活跃任务 · 主额度剩余比例"
    }
    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { closePopover() }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
            installDismissMonitors()
        }
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // Global mouse events cover other apps; local events cover our own windows.
        // Neither monitor consumes another application's click.
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePopover() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
            guard let self, self.popover.isShown, !self.store.isPresentingDialog else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.closePopover(); return nil }
            } else if let window = event.window,
                      window !== self.popover.contentViewController?.view.window,
                      window !== self.item?.button?.window,
                      window.level < .popUpMenu {
                self.closePopover()
            }
            return event
        }
    }

    private func closePopover() {
        guard let store, !store.isPresentingDialog else { return }
        popover.performClose(nil)
        removeDismissMonitors()
    }
    private func removeDismissMonitors() {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        outsideMonitor = nil; localMonitor = nil
    }
    func popoverDidShow(_ notification: Notification) {
        if CommandLine.arguments.contains("--ui-check") { print("UI: popover shown"); fflush(stdout) }
    }
    func popoverShouldClose(_ popover: NSPopover) -> Bool { !store.isPresentingDialog }
    func popoverDidClose(_ notification: Notification) {
        removeDismissMonitors()
        if CommandLine.arguments.contains("--ui-check") { print("UI: popover closed"); fflush(stdout) }
    }
    func applicationDidResignActive(_ notification: Notification) { closePopover() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { removeDismissMonitors(); store?.stop() }
}
