import AppKit
import SwiftUI
import Combine
import CodexPulseCore

/// Keep the camera housing empty; all readable content sits beside or below it.
struct NotchGeometry {
    let centerX: CGFloat
    let top: CGFloat
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat
    var compactWidth: CGFloat { cameraWidth + 152 }
    var compactHeight: CGFloat { cameraHeight + 6 }
    var expandedWidth: CGFloat { max(440, compactWidth) }
    var expandedHeight: CGFloat { cameraHeight + 340 }

    init?(screen: NSScreen) {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return nil }
        cameraWidth = right.minX - left.maxX
        cameraHeight = screen.safeAreaInsets.top
        centerX = (left.maxX + right.minX) / 2
        top = screen.frame.maxY
    }
    func frame(expanded: Bool) -> NSRect {
        let width = expanded ? expandedWidth : compactWidth
        let height = expanded ? expandedHeight : compactHeight
        return NSRect(x: centerX - width / 2, y: top - height, width: width, height: height)
    }
}

@MainActor
final class NotchState: ObservableObject {
    @Published var expanded = false
    @Published var pinned = false
    @Published var geometry: NotchGeometry?
}

private final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchController {
    private let store: MonitorStore
    private let state = NotchState()
    private var panel: NSPanel?
    private var subscription: AnyCancellable?
    private var displayObserver: NSObjectProtocol?
    private var collapseWork: DispatchWorkItem?
    var onDetails: (() -> Void)?

    init(store: MonitorStore) {
        self.store = store
        subscription = store.$notchEnabled.removeDuplicates().sink { [weak self] enabled in
            DispatchQueue.main.async { self?.updateDisplay(enabled: enabled) }
        }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateDisplay(enabled: self.store.notchEnabled)
            }
        }
    }

    private func updateDisplay(enabled: Bool) {
        guard enabled, let geometry = NSScreen.screens.compactMap({ NotchGeometry(screen: $0) }).first else {
            collapseWork?.cancel(); panel?.orderOut(nil)
            state.expanded = false; state.pinned = false
            return
        }
        state.geometry = geometry
        if panel == nil {
            let island = IslandPanel(contentRect: geometry.frame(expanded: false),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            island.isOpaque = false; island.backgroundColor = .clear; island.hasShadow = false
            island.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
            island.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            island.hidesOnDeactivate = false; island.isReleasedWhenClosed = false
            island.isMovable = false; island.animationBehavior = .none
            island.contentView = NSHostingView(rootView: NotchView(store: store, state: state,
                hover: { [weak self] inside in self?.hover(inside) },
                togglePin: { [weak self] in self?.togglePin() },
                collapse: { [weak self] in self?.collapse() },
                details: { [weak self] in self?.collapse(); self?.onDetails?() }))
            panel = island
        }
        panel?.setFrame(geometry.frame(expanded: state.expanded), display: true)
        panel?.orderFrontRegardless()
    }

    private func hover(_ inside: Bool) {
        collapseWork?.cancel()
        if inside { setExpanded(true) }
        else if !state.pinned {
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.state.pinned else { return }
                self.setExpanded(false)
            }
            collapseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    private func togglePin() {
        collapseWork?.cancel(); state.pinned.toggle(); setExpanded(true)
    }
    private func collapse() {
        collapseWork?.cancel(); state.pinned = false; setExpanded(false)
    }
    private func setExpanded(_ expanded: Bool) {
        guard state.expanded != expanded, let geometry = state.geometry else { return }
        state.expanded = expanded
        // Resize at the screen's physical top edge, independently of the active display.
        panel?.setFrame(geometry.frame(expanded: expanded), display: true)
        panel?.hasShadow = expanded
    }

    func captureDemo(path: String, expanded: Bool) {
        guard store.isDemo else { return }
        collapseWork?.cancel(); state.pinned = expanded; setExpanded(expanded)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, let view = self.panel?.contentView,
                  let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                NSApp.terminate(nil); return
            }
            view.cacheDisplay(in: view.bounds, to: image)
            if let data = image.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            if let panel = self.panel { print("Notch frame: \(panel.frame)") }
            NSApp.terminate(nil)
        }
    }

    func stop() {
        collapseWork?.cancel(); subscription?.cancel()
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        panel?.orderOut(nil); panel?.close(); panel = nil
    }
}

private struct IslandShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = min(24, rect.height / 2)
        var path = Path()
        path.move(to: .zero); path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - radius), control: CGPoint(x: 0, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct NotchView: View {
    @ObservedObject var store: MonitorStore
    @ObservedObject var state: NotchState
    let hover: (Bool) -> Void
    let togglePin: () -> Void
    let collapse: () -> Void
    let details: () -> Void
    private let mint = Color(red: 0.32, green: 0.89, blue: 0.68)
    private var remaining: String {
        guard store.connected, !store.quotaStale, store.quotaError == nil,
              let remaining = store.quota?.rateLimits.primary?.remaining else { return "—" }
        return "\(Int(remaining))%"
    }

    var body: some View {
        if let geometry = state.geometry {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button(action: togglePin) {
                        HStack(spacing: 5) {
                            Image(systemName: "waveform.path.ecg").foregroundStyle(mint)
                            Text(store.localError == nil ? "\(store.runningCount)" : "—").monospacedDigit()
                        }.font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }.help("活跃任务 · 点击固定展开面板")
                    Color.clear.frame(width: geometry.cameraWidth, height: geometry.cameraHeight)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    Button(action: state.expanded ? collapse : togglePin) {
                        HStack(spacing: 5) {
                            Text(remaining).monospacedDigit().foregroundStyle(mint)
                            if state.expanded { Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)) }
                        }.font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                    }.help(state.expanded ? "收起灵动岛" : "主额度剩余比例")
                }.frame(height: geometry.cameraHeight)
                if state.expanded { expandedContent.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 18) }
                else { Color.clear.frame(height: 6) }
            }
            .frame(width: state.expanded ? geometry.expandedWidth : geometry.compactWidth,
                   height: state.expanded ? geometry.expandedHeight : geometry.compactHeight, alignment: .top)
            .background(.black, in: IslandShape()).clipShape(IslandShape())
            .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
            .onHover(perform: hover)
            .onExitCommand(perform: collapse)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Pulse").font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(store.isDemo ? "演示数据" : (store.connected ? "正在关注你的任务" : "正在连接 Codex…"))
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Button(action: togglePin) {
                    Image(systemName: state.pinned ? "pin.fill" : "pin")
                        .foregroundStyle(state.pinned ? mint : .white.opacity(0.45))
                        .frame(width: 30, height: 30).background(.white.opacity(0.08), in: Circle())
                }.help(state.pinned ? "取消固定，移开鼠标后收起" : "固定展开")
            }
            HStack(spacing: 10) {
                tile("活跃任务", value: store.localError == nil ? "\(store.runningCount)" : "—")
                tile("待确认", value: store.localError == nil ? "\(store.quietCount)" : "—")
                tile("积分", value: store.quota?.rateLimits.credits?.display ?? "—")
            }
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(store.quota?.rateLimits.primary?.label ?? "账号额度")
                    Spacer()
                    Text("\(remaining) 剩余").foregroundStyle(mint).monospacedDigit()
                }.font(.system(size: 11, weight: .medium))
                GeometryReader { proxy in
                    Capsule().fill(.white.opacity(0.1)).overlay(alignment: .leading) {
                        Capsule().fill(mint).frame(width: proxy.size.width * ((remaining == "—" ? 0 : store.quota?.rateLimits.primary?.remaining) ?? 0) / 100)
                    }
                }.frame(height: 4)
                Text("\(DisplayFormat.age(store.quotaUpdated, now: store.now))同步 · \(store.quotaStale || store.quotaError != nil || !store.connected ? "等待额度更新" : "Codex 账号额度")")
                    .font(.system(size: 9)).foregroundStyle(.white.opacity(0.35))
            }
            VStack(alignment: .leading, spacing: 10) {
                if store.sessions.isEmpty {
                    Text(store.localError ?? "暂无本机任务").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(Array(store.sessions.prefix(2))) { session in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(session.state == .running ? mint : .white.opacity(0.3)).frame(width: 5, height: 5).padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Text(session.activity).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
                        }
                        Spacer()
                        Text(session.state.label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.45))
                    }
                }
            }.frame(height: 74, alignment: .top)
            HStack {
                Button(action: details) { Label("详细面板", systemImage: "arrow.up.right.square") }
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("立即刷新")
                Button(action: collapse) { Image(systemName: "chevron.up") }.help("收起")
            }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
        }
    }

    private func tile(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 9)).foregroundStyle(.white.opacity(0.4))
            Text(value).font(.system(size: 21, weight: .medium, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
