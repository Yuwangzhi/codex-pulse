import SwiftUI
import AppKit
import CodexPulseCore

private let pulse = Color(red: 0.12, green: 0.66, blue: 0.49)

struct DashboardView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Picker("页面", selection: $store.selectedTab) {
                Text("概览").tag(0); Text("任务").tag(1); Text("设置").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if store.selectedTab == 0 { overview }
                    else if store.selectedTab == 1 { taskList }
                    else { settings }
                }.padding(.horizontal, 20).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .frame(width: 440, height: 670)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(pulse)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(pulse)
                .frame(width: 44, height: 44).background(pulse.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 3) {
                Text("Codex Pulse").font(.system(size: 19, weight: .bold, design: .rounded))
                Text(store.isDemo ? "菜单栏里的工作节奏 · 演示数据" : "菜单栏里的工作节奏")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(store.connected ? pulse : Color.orange).frame(width: 6, height: 6)
                Text(store.isDemo ? "DEMO" : (store.connected ? "LIVE" : "连接中"))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }.padding(.horizontal, 9).padding(.vertical, 6)
                .background(.primary.opacity(0.04), in: Capsule()).help(store.connectionMessage)
        }
    }

    @ViewBuilder private var overview: some View {
        HStack(spacing: 10) {
            metric("活跃任务", value: store.localError == nil ? "\(store.runningCount)" : "—", icon: "bolt.fill", tint: pulse)
            metric("待确认", value: store.localError == nil ? "\(store.quietCount)" : "—", icon: "clock", tint: .orange)
            metric("连续使用", value: store.usage?.summary.currentStreakDays.map { "\($0) 天" } ?? "—", icon: "flame", tint: .secondary)
        }
        quotaCard
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                sectionTitle("任务动态", detail: "每 2 秒更新")
                Spacer()
                Button("查看全部") { store.selectedTab = 1 }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(pulse)
            }
            if let error = store.localError { notice(error) }
            else if store.sessions.isEmpty { emptyState("暂无本地任务", detail: "开始一个 Codex 任务后，会自动出现在这里。") }
            else {
                ForEach(Array(store.sessions.prefix(3))) { session in sessionRow(session) }
            }
        }
        usageCard
    }

    private func metric(_ title: String, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).foregroundStyle(.secondary)
            }.font(.system(size: 10))
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionTitle("可用额度", detail: nil)
                Spacer()
                if let plan = store.quota?.rateLimits.planType {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(pulse).padding(.horizontal, 7).padding(.vertical, 4)
                        .background(pulse.opacity(0.1), in: Capsule())
                }
            }
            if let quota = store.quota {
                if quota.ordinaryUsageAllowed == false { notice("账号当前普通额度不可用，请在 Codex 中查看详情。") }
                if let bucket = quota.buckets.first { quotaBucket(bucket) }
                if quota.buckets.count > 1 {
                    DisclosureGroup("其他模型额度 · \(quota.buckets.count - 1)", isExpanded: $store.showExtraQuotas) {
                        VStack(alignment: .leading, spacing: 14) {
                            ForEach(Array(quota.buckets.dropFirst())) { bucket in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(bucket.name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                    quotaBucket(bucket)
                                }
                            }
                        }.padding(.top, 10)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let credits = quota.rateLimits.credits {
                    Divider()
                    HStack {
                        Label("积分余额", systemImage: "circle.hexagongrid").foregroundStyle(.secondary)
                        Spacer()
                        Text(credits.display).fontWeight(.semibold).monospacedDigit()
                    }.font(.system(size: 12)).help("Codex 返回的积分单位，不等同于美元或剩余 Token。")
                }
                if let count = quota.rateLimitResetCredits?.availableCount {
                    HStack {
                        Text("可用额度重置次数").foregroundStyle(.secondary)
                        Spacer(); Text("\(count)").monospacedDigit()
                    }.font(.system(size: 11))
                }
                if store.quotaStale || store.quotaError != nil || !store.connected {
                    notice("上次快照 · " + (store.quotaError ?? "等待重新同步，额度可能已变化。"))
                }
            } else {
                emptyState("等待额度数据", detail: store.quotaError ?? store.connectionMessage)
            }
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.2.circlepath")
                Text("\(DisplayFormat.age(store.quotaUpdated, now: store.now)) · 每 60 秒同步")
            }.font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
    }

    private func quotaBucket(_ bucket: QuotaBucket) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let window = bucket.primary { quotaWindow(window) }
            if let window = bucket.secondary { quotaWindow(window) }
            if bucket.primary == nil && bucket.secondary == nil {
                Text("此额度未提供百分比").font(.caption).foregroundStyle(.secondary)
            }
            if bucket.spendControlReached == true || bucket.rateLimitReachedType != nil {
                notice("此额度已达到服务端限制")
            }
        }
    }

    private func quotaWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12))
                Spacer()
                Text("\(Int(window.remaining))%").font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.07))
                    Capsule().fill(window.remaining <= 10 ? Color.red : (window.remaining <= 25 ? .orange : pulse))
                        .frame(width: geometry.size.width * window.remaining / 100)
                }
            }.frame(height: 5).accessibilityLabel("\(window.label)，剩余百分之\(Int(window.remaining))")
            if let reset = window.resetsAt {
                let date = Date(timeIntervalSince1970: reset)
                Text(date > store.now ? "\(date.formatted(.dateTime.month().day().hour().minute())) 重置" : "重置时间已过，等待服务端更新")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var usageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Token 用量", detail: "账号统计 · 每 5 分钟同步")
            if let usage = store.usage {
                HStack(alignment: .firstTextBaseline) {
                    Text(DisplayFormat.tokens(usage.summary.lifetimeTokens))
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("累计 Token").font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if let last = usage.recentDays.last {
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(DisplayFormat.tokens(last.tokens)).font(.system(size: 13, weight: .medium)).monospacedDigit()
                            Text("\(last.startDate) 统计").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
                if !usage.recentDays.isEmpty {
                    HStack(alignment: .bottom, spacing: 7) {
                        ForEach(usage.recentDays) { day in
                            VStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(day.id == usage.recentDays.last?.id ? pulse : pulse.opacity(0.3))
                                    .frame(height: max(2, 34 * Double(day.tokens) / Double(max(1, usage.recentDays.map(\.tokens).max() ?? 1))))
                                Text(String(day.startDate.suffix(5))).font(.system(size: 8)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                                .help("\(day.startDate)：\(day.tokens.formatted()) Token")
                                .accessibilityLabel("\(day.startDate)，\(day.tokens) Token")
                        }
                    }.frame(height: 48, alignment: .bottom)
                    Text("最近 7 个有记录的日期 · 以服务端日期为准")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                if let error = store.usageError { notice(error) }
                Text("更新于 \(DisplayFormat.age(store.usageUpdated, now: store.now))")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            } else { emptyState("等待用量数据", detail: store.usageError ?? "正在读取账号使用统计…") }
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
    }

    @ViewBuilder private var taskList: some View {
        sectionTitle("本机最近任务", detail: "最多 60 个未归档会话")
        Picker("筛选", selection: $store.taskFilter) {
            ForEach(["全部", "执行中", "待确认", "已完成"], id: \.self) { Text($0) }
        }.pickerStyle(.segmented).labelsHidden()
        if let error = store.localError { notice(error) }
        let filtered = store.sessions.filter { store.taskFilter == "全部" || $0.state.label == store.taskFilter }
        if filtered.isEmpty { emptyState("没有符合条件的任务", detail: "任务状态来自本机 Codex 日志。") }
        ForEach(filtered) { session in
            VStack(alignment: .leading, spacing: 9) {
                sessionRow(session)
                HStack {
                    Text(session.model.isEmpty ? "模型未记录" : session.model).lineLimit(1)
                    Spacer()
                    Text("本轮 \(DisplayFormat.tokens(session.turnTokens)) Token")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                HStack {
                    Text("会话累计 \(DisplayFormat.tokens(session.totalTokens)) Token")
                    Spacer()
                    if let context = session.contextPercent { Text("上下文约 \(Int(context))%") }
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
        Text("“执行中”表示最近 2 分钟观察到未结束任务的活动；无新事件转为“待确认”。完成与中断仅依据明确日志事件。云端任务及其他设备不在本机列表内。")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: stateIcon(session.state)).font(.system(size: 12))
                .foregroundStyle(stateColor(session.state)).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                    Spacer(minLength: 6)
                    Text(session.state.label).font(.system(size: 9)).foregroundStyle(stateColor(session.state))
                }
                Text(session.activity).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(session.project).lineLimit(1)
                    Spacer()
                    Text(DisplayFormat.age(session.lastEventAt, now: store.now))
                }.font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }.contentShape(Rectangle()).contextMenu {
            Button("在 Finder 中打开项目") { NSWorkspace.shared.open(URL(fileURLWithPath: session.cwd)) }
            Button("复制会话 ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(session.id, forType: .string) }
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("偏好设置", detail: "本机读取，无需额外 API Key")
            Toggle("刘海灵动岛", isOn: $store.notchEnabled).font(.system(size: 12))
            Text("悬停展开，移开收起；点击图钉固定。仅显示在带刘海的内屏，外接显示器仍可使用菜单栏。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("登录时启动 Codex Pulse", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
                .font(.system(size: 12)).disabled(store.isDemo)
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Text("Codex 数据目录").font(.system(size: 12, weight: .medium))
                TextField("~/.codex", text: $store.homePath).textFieldStyle(.roundedBorder)
                Text("支持自定义 CODEX_HOME；不读取或复制登录凭据。").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Codex CLI 路径").font(.system(size: 12, weight: .medium))
                HStack {
                    TextField("自动检测", text: $store.executablePath).textFieldStyle(.roundedBorder)
                    Button("选择…") { store.chooseCLI() }
                }
            }
            Button("保存并重新连接") { store.applySettings() }.buttonStyle(.borderedProminent).disabled(store.isDemo)
            if let error = store.settingsError { notice(error) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                settingsRow("任务日志", "每 2 秒 · 增量读取")
                settingsRow("账号额度", "每 60 秒 · Codex 接口")
                settingsRow("Token 统计", "每 5 分钟 · Codex 接口")
                settingsRow("本地读取", DisplayFormat.age(store.localUpdated, now: store.now))
            }
            Text("额度由已登录的 Codex CLI 查询；Pulse 不发起模型任务、不消耗重置次数。额度百分比、积分与 Token 分别展示，未返回的数据保留为未知。")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("数据接口说明 ↗", destination: URL(string: "https://learn.chatgpt.com/docs/app-server")!).font(.system(size: 11))
            Text("Codex Pulse 0.1.0 · macOS 14+").font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("立即刷新")
            Button("打开 Codex") { openCodex() }
            Spacer()
            Text("本机监测").font(.system(size: 10)).foregroundStyle(.tertiary)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("退出 Codex Pulse")
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(.primary.opacity(0.025)).overlay(alignment: .top) { Divider() }
    }

    private func openCodex() {
        let ids = ["com.openai.codex", "com.openai.chat"]
        for id in ids {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return
            }
        }
        store.settingsError = "未找到 Codex 桌面应用。"; store.selectedTab = 2
    }
    private func settingsRow(_ title: String, _ detail: String) -> some View {
        HStack { Text(title); Spacer(); Text(detail).foregroundStyle(.secondary) }.font(.system(size: 11))
    }
    private func sectionTitle(_ text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 9)).foregroundStyle(.secondary) }
        }
    }
    private func emptyState(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 6)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func stateColor(_ state: TaskState) -> Color {
        switch state { case .running: return pulse; case .quiet: return .orange; case .completed: return .secondary; case .interrupted: return .red; case .unknown: return .secondary }
    }
    private func stateIcon(_ state: TaskState) -> String {
        switch state { case .running: return "bolt.fill"; case .quiet: return "clock"; case .completed: return "checkmark.circle.fill"; case .interrupted: return "stop.circle"; case .unknown: return "questionmark.circle" }
    }
}
