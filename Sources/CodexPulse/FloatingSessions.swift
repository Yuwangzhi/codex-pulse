import AppKit
import SwiftUI
import CodexPulseCore

private extension AgentPhase {
    func textTint(_ scheme: ColorScheme) -> Color {
        switch self {
        case .attention: return .red
        case .running: return scheme == .dark ? .yellow : Color(red: 0.55, green: 0.35, blue: 0)
        case .completed, .idle: return scheme == .dark ? .green : Color(red: 0.04, green: 0.43, blue: 0.22)
        case .unknown, .interrupted, .ended: return .secondary
        }
    }
    var lamp: Int? {
        switch self {
        case .attention: return 0
        case .running: return 1
        case .completed, .idle: return 2
        default: return nil
        }
    }
}

struct TrafficLight: View {
    let phase: AgentPhase
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3) { index in
                let color: Color = [Color.red, Color.yellow, Color.green][index]
                Circle().fill(phase.lamp == index ? color : color.opacity(0.12))
                    .frame(width: 7, height: 7)
                    .shadow(color: phase.lamp == index ? color.opacity(0.45) : .clear, radius: 4)
            }
        }.padding(.vertical, 6).padding(.horizontal, 5)
            .background(.black.opacity(0.17), in: Capsule())
            .accessibilityLabel(phase.label)
    }
}

struct TrafficSessionRow: View {
    @Environment(\.colorScheme) private var scheme
    let session: TrafficSession
    let now: Date
    var body: some View {
        HStack(spacing: 11) {
            TrafficLight(phase: session.phase)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(session.agent).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(session.project.isEmpty ? "未命名项目" : session.project)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Text(session.phase.label).foregroundStyle(session.phase.textTint(scheme))
                    if session.detail != session.phase.label {
                        Text(session.detail).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 10))
            }
            Text(DisplayFormat.age(session.updatedAt, now: now))
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                .fixedSize()
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
    }
}

struct AgentSessionsSection: View {
    @ObservedObject var store: MonitorStore
    var compact = false
    var body: some View {
        let rows = store.agents.traffic(now: store.now)
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Label("Claude Code · Grok", systemImage: "circle.grid.2x2")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.floatingEnabled.toggle() } label: {
                    Image(systemName: store.floatingEnabled ? "pip.fill" : "pip")
                }.buttonStyle(.plain).help(store.floatingEnabled ? "隐藏悬浮状态灯" : "显示悬浮状态灯")
                    .accessibilityLabel(store.floatingEnabled ? "隐藏悬浮状态灯" : "显示悬浮状态灯")
            }
            if rows.isEmpty {
                Text("等待新会话。监控启用后，新开的 Claude Code / Grok 会话会显示在这里。")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array((compact ? Array(rows.prefix(3)) : rows))) { session in
                    TrafficSessionRow(session: session, now: store.now)
                        .contextMenu { projectActions(session) }
                }
                if compact && rows.count > 3 {
                    Button("查看全部 \(rows.count) 个会话 →") { store.revealTrafficSession() }
                        .font(.system(size: 10)).buttonStyle(.plain)
                }
            }
            if let error = store.agents.error { Text(error).font(.system(size: 10)).foregroundStyle(.orange) }
            if let desktop = store.agents.grokBot {
                GrokBotCard(snapshot: desktop, running: store.agents.grokBotRunning, now: store.now)
            } else if let error = store.agents.grokBotError {
                Text(error).font(.system(size: 10)).foregroundStyle(.orange)
            }
            Text("终端 Grok 通过会话事件显示状态；桌面 Grok Bot 单独显示客户端缓存。")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(14).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    @ViewBuilder private func projectActions(_ session: TrafficSession) -> some View {
        Button("在 Finder 中打开项目") { store.openProjectInFinder(session.cwd) }.disabled(session.cwd.isEmpty)
        Button("复制会话 ID") {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id, forType: .string)
        }
    }
}

struct FloatingSessionsView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        let sessions = Array(store.trafficSessions.prefix(8))
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(.green)
                Text("AI Pulse").font(.system(size: 12, weight: .semibold, design: .rounded))
                if store.isDemo { Text("演示").font(.system(size: 9)).foregroundStyle(.secondary) }
                Spacer()
                Button { store.revealTrafficSession() } label: { Image(systemName: "arrow.up.right.square") }
                    .help("打开全部任务").accessibilityLabel("打开全部任务")
                Button { store.floatingEnabled = false } label: { Image(systemName: "xmark") }
                    .help("隐藏悬浮窗，可在设置中重新显示").accessibilityLabel("隐藏悬浮窗")
            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary).padding(14)
            Divider().padding(.horizontal, 12)
            if sessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("等待会话").font(.system(size: 12, weight: .medium))
                    Text("新开的 Claude Code / Grok 会话，以及最近的 Codex 任务，会在这里亮灯。")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button("打开监控设置") { store.selectedTab = 3; store.revealDashboard?() }
                        .font(.system(size: 11)).buttonStyle(.link)
                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 3) {
                    ForEach(sessions) { session in
                        Button { store.revealTrafficSession(session) } label: {
                            TrafficSessionRow(session: session, now: store.now)
                                .padding(.horizontal, 12).padding(.vertical, 4)
                        }.buttonStyle(.plain).help("在 AI Pulse 中查看任务")
                    }
                }.padding(.vertical, 6)
            }
            Divider().padding(.horizontal, 12)
            HStack(spacing: 10) {
                legend(.red, "等你"); legend(.yellow, "执行"); legend(.green, "已回复")
                Spacer(minLength: 0)
                if store.trafficSessions.count > 8 {
                    Text("+\(store.trafficSessions.count - 8)").font(.system(size: 9)).foregroundStyle(.secondary)
                } else { Text("灰 · 待确认").font(.system(size: 9)).foregroundStyle(.tertiary) }
            }.padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: 340).background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.12), lineWidth: 1))
        .preferredColorScheme(store.colorScheme)
    }
    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 4, height: 4); Text(text).font(.system(size: 9)) }
            .foregroundStyle(.secondary)
    }
}

struct AgentMonitoringSettings: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("悬浮状态灯").font(.system(size: 13, weight: .semibold))
            Toggle("显示桌面悬浮窗", isOn: $store.floatingEnabled)
            Text("拖动空白处移动；每个会话独立亮灯。红色等你回应，黄色执行中，绿色就绪 / 本轮已回复，灰色待确认。显示近期会话和仍在运行的任务，最多 8 行。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            ForEach(MonitoredAgent.allCases, id: \.self) { agent in
                HStack {
                    Toggle("\(agent.label) 会话监控", isOn: Binding(
                        get: { store.agents.hookStatus[agent] ?? false },
                        set: { store.agents.configure(agent, enabled: $0) }
                    )).disabled(store.isDemo)
                    Spacer()
                    if store.agents.hookStatus[agent] == true {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
            }
            if let message = store.agents.setupMessage {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text("启用时备份并合并事件配置，原有设置保留；新开 Claude Code / Grok 会话后生效。仅保存会话、项目、工具名和状态，不保存对话内容。Codex 沿用现有本机任务日志。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("桌面 Grok Bot：只读当前账户的本地额度缓存，标注读取时间；不读取凭据或对话。客户端尚未提供明确任务状态，因此显示灰灯待确认。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).padding(16)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct GrokBotCard: View {
    let snapshot: GrokBotSnapshot
    let running: Bool
    let now: Date
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack {
                Text("Grok Bot · 桌面版").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(running ? (snapshot.signedIn ? "已登录" : "未登录") : "未运行")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let quota = snapshot.quota {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(quota.remainingPercent.formatted(.number.precision(.fractionLength(1))))%")
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("额度剩余").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if quota.isStale(now: now) { Text("上次记录").font(.system(size: 9)).foregroundStyle(.orange) }
                }
                ProgressView(value: quota.remainingPercent, total: 100).tint(.green)
                if let reset = quota.resetAt {
                    Text("\(reset.formatted(date: .abbreviated, time: .shortened)) 重置")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Text("客户端缓存 · \(DisplayFormat.age(quota.readAt, now: now))读取")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else {
                Text("尚无当前账户的额度缓存。打开 Grok Bot 的用量页面后会自动读取。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
final class FloatingSessionsController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var previousCount = -1
    private let store: MonitorStore
    init(store: MonitorStore) { self.store = store }
    func update() {
        guard store.floatingEnabled else { panel?.orderOut(nil); return }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "AI Pulse · 悬浮状态灯"
            panel.identifier = NSUserInterfaceItemIdentifier("ai-pulse-floating-sessions")
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isMovableByWindowBackground = true
            panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: FloatingSessionsView(store: store))
            if (store.isDemo || !panel.setFrameUsingName("AIPulseFloatingSessions")), let screen = NSScreen.main {
                panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - 360, y: screen.visibleFrame.maxY - 280))
            }
            self.panel = panel
        }
        let count = min(8, store.trafficSessions.count)
        if count != previousCount, let panel {
            let height: CGFloat = count == 0 ? 224 : CGFloat(90 + count * 55)
            var frame = panel.frame
            frame.origin.y += frame.height - height; frame.size.height = height
            let screen = panel.screen ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
            }
            panel.setFrame(frame, display: true); previousCount = count
        }
        panel?.orderFrontRegardless()
    }
    func windowDidMove(_ notification: Notification) {
        if !store.isDemo { panel?.saveFrame(usingName: "AIPulseFloatingSessions") }
    }
    func close() { panel?.orderOut(nil); panel = nil }
    func capture(path: String) -> Bool {
        guard let view = panel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
