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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var store: MonitorStore!
    private var cancellable: AnyCancellable?
    private var preview: NSWindow?
    private var notch: NotchController?

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
            popover.contentSize = NSSize(width: 440, height: 670)
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: DashboardView(store: store))
            cancellable = store.objectWillChange.sink { [weak self] in
                DispatchQueue.main.async { self?.updateStatus() }
            }
            updateStatus()
            if !args.contains("--screenshot") && !args.contains("--preview") {
                notch = NotchController(store: store)
                notch?.onDetails = { [weak self] in self?.togglePopover() }
            }
        }
        store.start()
        if demo, let index = args.firstIndex(of: "--notch-screenshot"), args.count > index + 1 {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.notch?.captureDemo(path: path, expanded: args.contains("--expanded"))
            }
        }
        if args.contains("--preview") || args.contains("--screenshot") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 670),
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
        item?.button?.title = " " + store.statusLabel
        item?.button?.toolTip = "Codex Pulse · \(store.runningCount) 个活跃任务 · 主额度剩余比例"
    }
    @objc private func togglePopover() {
        guard let button = item?.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { notch?.stop(); store?.stop() }
}
