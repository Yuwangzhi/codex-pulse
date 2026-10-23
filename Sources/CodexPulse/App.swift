import AppKit
import SwiftUI
import Combine
import CodexPulseCore

@main
struct CodexPulseMain {
    @MainActor static func main() {
        if AgentHookCommand.handle(CommandLine.arguments) { return }
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
    private var floating: FloatingSessionsController?
    private var outsideMonitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        let demo = args.contains("--demo")
        let diagnosing = args.contains("--diagnose") || args.contains("--usage-check")
        let usageCheck = args.contains("--usage-check")
        store = MonitorStore(demo: demo, demoClaude: !args.contains("--demo-no-claude"))
        if demo && args.contains("--dark") { store.theme = "深色" }
        if !diagnosing {
            floating = FloatingSessionsController(store: store)
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            self.item = item
            // Keep our placement/visibility separate from unnamed status items and restore
            // the only normal entry point when the app is explicitly launched again.
            item.autosaveName = "AIPulseQuota"
            item.isVisible = true
            if let button = item.button {
                button.image = nil
                button.imagePosition = .noImage
                button.font = .monospacedDigitSystemFont(ofSize: 9, weight: .medium)
                button.cell?.usesSingleLineMode = false
                button.cell?.wraps = true
                button.target = self; button.action = #selector(togglePopover)
                button.setAccessibilityLabel("AI Pulse，点击展开额度详情")
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
        store.dismissPanel = { [weak self] in
            guard let self, !self.store.isPresentingDialog else { return }
            self.closePopover()
            self.preview?.orderOut(nil)
        }
        store.revealDashboard = { [weak self] in
            self?.showPopover()
        }
        store.start()
        floating?.update()
        if let index = args.firstIndex(of: "--status-screenshot"), args.count > index + 1 {
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 2 : 20)) { [weak self] in
                self?.captureStatus(path: path)
            }
        }
        if let index = args.firstIndex(of: "--floating-screenshot"), args.count > index + 1 {
            store.floatingEnabled = true
            floating?.update()
            let path = args[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                _ = self?.floating?.capture(path: path)
                NSApp.terminate(nil)
            }
        }
        if let index = args.firstIndex(of: "--tab"), args.count > index + 1, let tab = Int(args[index + 1]) {
            store.selectedTab = min(4, max(0, tab))
        }
        if args.contains("--preview") || args.contains("--screenshot") {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 690),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = demo ? "AI Pulse · 演示" : "AI Pulse"
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
            let delay: TimeInterval = usageCheck ? 12 : 20
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                var summary = self.store.diagnostics(detailed: usageCheck)
                summary["cliFound"] = RPCClient.locateCLI() != nil
                summary["mode"] = usageCheck ? "usage-check" : "diagnose"
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
    private func captureStatus(path: String) {
        guard let button = item?.button,
              let rep = button.bitmapImageRepForCachingDisplay(in: button.bounds) else { NSApp.terminate(nil); return }
        button.cacheDisplay(in: button.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
        NSApp.terminate(nil)
    }

    private func updateStatus() {
        let layout = store.statusLayout
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let leftWidth = ceil(layout.left.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        let rightWidth = ceil(layout.right.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0)
        let width = leftWidth + (layout.hasRightColumn ? 10 + rightWidth : 0)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .left
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: width, options: [:])]
        paragraph.minimumLineHeight = 10
        paragraph.maximumLineHeight = 10
        let title = NSAttributedString(string: store.statusLabel, attributes: [
            .font: font,
            .paragraphStyle: paragraph,
            .baselineOffset: -3
        ])
        item?.length = width + 12
        item?.button?.attributedTitle = title
        item?.button?.toolTip = store.statusTooltip
        item?.button?.setAccessibilityLabel("AI Pulse，\(store.statusTooltip)")
        floating?.update()
        writeStatusCheck()
    }

    private var statusItemOnScreen: Bool {
        guard let item, item.isVisible, let window = item.button?.window, window.isVisible else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    // Opt-in, local UI regression evidence. No account names, quotas or credentials.
    private func writeStatusCheck() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--status-check"), args.count > index + 1,
              let item else { return }
        let summary: [String: Any] = [
            "bundleID": Bundle.main.bundleIdentifier ?? "",
            "autosaveName": item.autosaveName ?? "",
            "visible": item.isVisible,
            "windowVisible": item.button?.window?.isVisible ?? false,
            "anchorOnScreen": statusItemOnScreen,
            "frame": NSStringFromRect(item.button?.window?.frame ?? .zero),
            "popoverShown": popover.isShown,
            "checkedAt": Date().timeIntervalSince1970
        ]
        if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: args[index + 1]), options: [.atomic])
        }
    }
    @objc private func togglePopover() {
        if popover.isShown { closePopover() }
        else {
            store.selectedTab = 0
            showPopover()
        }
    }
    private func showPopover() {
        guard !popover.isShown, let button = item?.button else { return }
        if preview?.isVisible == true { showDashboardWindow(); return }
        // An off-screen AppKit anchor cannot position a usable popover.
        guard statusItemOnScreen else { showDashboardWindow(); return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        installDismissMonitors()
    }

    private func showDashboardWindow() {
        if preview == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 690),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AI Pulse"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: DashboardView(store: store))
            window.center()
            preview = window
        }
        preview?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        // Re-register even when the local flag is already true: Control Center
        // can leave its hosted item suppressed after a permission toggle.
        item?.isVisible = false
        item?.isVisible = true
        // Control Center may hide the hosted item while its AppKit anchor still
        // reports visible. A normal window is always reachable on explicit reopen.
        closePopover()
        store.selectedTab = 0
        showDashboardWindow()
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { removeDismissMonitors(); floating?.close(); store?.stop() }
}
