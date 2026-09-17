import SwiftUI
import AppKit
import CodexPulseCore

private let pulse = Color(red: 0.12, green: 0.66, blue: 0.49)

struct DashboardView: View {
    @ObservedObject var store: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
            Picker("页面", selection: $store.selectedTab) {
                Text("概览").tag(0); Text("任务").tag(1); Text("用量").tag(2); Text("设置").tag(3)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch store.selectedTab {
                    case 0: overview
                    case 1: taskList
                    case 2: usagePage
                    default: settings
                    }
                }.padding(.horizontal, 20).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: .leading)
            }.id(store.selectedTab)
            footer
        }
        .frame(width: 460, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(store.colorScheme).tint(pulse)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 23, weight: .medium)).foregroundStyle(pulse)
                .frame(width: 44, height: 44)
                .background(LinearGradient(colors: [pulse.opacity(0.19), pulse.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text("Codex Pulse").font(.system(size: 19, weight: .semibold, design: .rounded))
                HStack(spacing: 5) {
                    Circle().fill(store.connected ? pulse : .orange).frame(width: 5, height: 5)
                    Text(store.isDemo ? "演示数据 · 本地合成" : (store.connected ? store.headerStatusText : store.connectionMessage))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            accountMenu
            Button { store.dismissPanel?() } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 25, height: 25)
                    .background(.primary.opacity(0.05), in: Circle())
            }.buttonStyle(.plain).help("收起面板 · Esc").accessibilityLabel("收起面板")
        }
    }

    /// Quick account switching from the panel header. Account management lives in 设置.
    private var accountMenu: some View {
        Menu {
            ForEach(store.accounts) { account in
                Button {
                    store.selectAccount(account.id)
                } label: {
                    Label("\(account.displayName)（\(account.kind.shortLabel)）",
                          systemImage: account.id == store.selectedID ? "checkmark.circle.fill" : account.kind.symbol)
                }
            }
            Divider()
            Button { store.selectedTab = 3; store.beginAddAccount() } label: { Label("添加账户…", systemImage: "plus") }
            Button { store.refreshAllAccounts() } label: { Label("刷新全部账户", systemImage: "arrow.clockwise") }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(store.isDeepSeek ? Color.orange : pulse).frame(width: 5, height: 5)
                Text(store.selectedAccount?.displayName ?? "账户")
                    .font(.system(size: 10, weight: .medium)).lineLimit(1)
                Text(store.selectedAccount?.kind.shortLabel ?? "")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(.primary.opacity(0.05), in: Capsule())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("切换监测账户 · 当前 \(store.selectedAccount?.displayName ?? "无")")
    }

    @ViewBuilder private var overview: some View {
        HStack(spacing: 10) {
            metric("执行中", count: store.runningCount, icon: "bolt.fill", color: pulse)
            metric("待确认", count: store.quietCount, icon: "clock", color: .orange)
            metric("已完成", count: store.completedCount, icon: "checkmark.circle", color: .secondary)
        }
        if store.isCodex { quotaCard } else { balanceCard }
        localUsageCard
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("任务动态", detail: "每 2 秒更新")
                Spacer()
                Button("全部任务 →") { store.showTasks("全部") }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(pulse)
            }
            if let error = store.localError { notice(error) }
            else if store.sessions.isEmpty { emptyState("暂无本地任务", detail: "开始一个 Codex 任务后，会自动出现在这里。", icon: "terminal") }
            else {
                ForEach(Array(store.sessions.prefix(3))) { session in
                    Button { store.showTasks("全部"); store.expandedSessionID = session.id } label: {
                        sessionRow(session)
                    }.buttonStyle(.plain).padding(12).pulseCard()
                }
            }
        }
        Text("统计范围：本机最近 \(store.sessions.count) 个未归档会话")
            .font(.system(size: 10)).foregroundStyle(.secondary)
    }

    // MARK: - DeepSeek balance

    private var balanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("DeepSeek 余额", systemImage: "creditcard").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let currency = store.balance?.primary?.currency {
                    Text(currency.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.1), in: Capsule())
                }
            }
            if let balance = store.balance {
                if balance.isAvailable == false { notice("服务端标记该账户当前不可用，请确认账户状态与余额。") }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(balance.display).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                    Spacer(minLength: 0)
                    if let spend = store.observedSpend {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(spend >= 0 ? "今日观测消耗" : "今日观测充值")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(DisplayFormat.money(abs(spend), currency: balance.primary?.currency ?? "CNY", fractionDigits: 4))
                                .font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit()
                                .foregroundStyle(spend >= 0 ? .primary : pulse)
                        }
                    }
                }
                HStack(spacing: 18) {
                    if let granted = balance.primary?.grantedBalance {
                        Label("赠送 \(DisplayFormat.money(Double(granted), currency: balance.primary?.currency ?? "CNY"))", systemImage: "gift")
                    }
                    if let topped = balance.primary?.toppedUpBalance {
                        Label("充值 \(DisplayFormat.money(Double(topped), currency: balance.primary?.currency ?? "CNY"))", systemImage: "banknote")
                    }
                    Spacer(minLength: 0)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                if let note = store.credentialNotice {
                    Text(note).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1).help(note)
                }
                if store.balanceStale || store.balanceError != nil {
                    notice("上次快照 · " + (store.balanceError ?? "等待重新同步，余额可能已变化。"))
                }
            } else {
                emptyState("等待余额数据", detail: store.balanceError ?? store.connectionMessage, icon: "creditcard")
            }
            HStack(spacing: 4) {
                Circle().fill(store.balanceStale || store.balanceError != nil ? .orange : pulse).frame(width: 4, height: 4)
                Text("\(DisplayFormat.age(store.balanceUpdated, now: store.now))同步 · 每 30 秒，任务完成后立即刷新")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(16).pulseCard(accent: true)
    }

    // MARK: - Local token usage

    @ViewBuilder private var localUsageCard: some View {
        if let usage = store.localUsage, usage.hasData {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(store.isDeepSeek ? "Token 用量（本机日志）" : "本机 Token 用量", systemImage: "chart.bar")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("每 2 秒").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DisplayFormat.tokens(usage.today?.totalTokens)).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text("今日 Token").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(DisplayFormat.tokens(usage.totalTokens)).font(.system(size: 15, weight: .medium, design: .rounded)).monospacedDigit()
                        Text("近 \(usage.windowDays) 天合计").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                usageBars(usage)
                if let top = usage.models.first {
                    HStack(spacing: 14) {
                        ForEach(Array(usage.models.prefix(3))) { model in
                            Label("\(model.model) \(DisplayFormat.tokens(model.tokens))", systemImage: "cube")
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if usage.truncatedFiles > 0 || usage.unreadableFiles > 0 {
                    notice("\(usage.truncatedFiles) 个日志只读取了尾部、\(usage.unreadableFiles) 个不可读，较早轮次可能未计入。")
                }
                Text("口径：本机 Codex 日志中每次请求的增量 Token，按事件时间归入本地日期；不含其他设备或网页端的调用。")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(16).pulseCard()
        } else if let error = store.localError {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("本机 Token 用量", detail: "每 2 秒")
                notice(error)
            }.padding(16).pulseCard()
        }
    }

    private func usageBars(_ usage: UsageSnapshot) -> some View {
        let peak = max(1, usage.recentDays.map(\.totalTokens).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 8) {
            ForEach(usage.recentDays) { day in
                VStack(spacing: 6) {
                    Text(DisplayFormat.tokens(day.totalTokens)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                    RoundedRectangle(cornerRadius: 5)
                        .fill(day.date == usage.todayKey ? pulse : pulse.opacity(0.3))
                        .frame(height: max(3, 72 * Double(day.totalTokens) / Double(peak)))
                    Text(String(day.date.suffix(5))).font(.system(size: 9)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity)
                    .help("\(day.date)：\(day.totalTokens.formatted()) Token（输入 \(day.inputTokens.formatted()) · 缓存 \(day.cachedInputTokens.formatted()) · 输出 \(day.outputTokens.formatted())）")
                    .accessibilityLabel("\(day.date)，\(day.totalTokens) Token")
            }
        }.frame(height: 108, alignment: .bottom)
    }

    private func metric(_ title: String, count: Int, icon: String, color: Color) -> some View {
        Button { store.showTasks(title) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
                    .frame(width: 28, height: 28).background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.localUpdated == nil || store.localError != nil ? "—" : "\(count)")
                        .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(11).pulseCard()
        }.buttonStyle(.plain).help("查看\(title)的任务")
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("可用额度", systemImage: "chart.pie").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let plan = store.quota?.rateLimits.planType {
                    Text(plan.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(pulse).padding(.horizontal, 8).padding(.vertical, 4)
                        .background(pulse.opacity(0.1), in: Capsule())
                }
            }
            if let quota = store.quota {
                if quota.ordinaryUsageAllowed == false { notice("账号当前普通额度不可用，请在 Codex 中查看详情。") }
                if let bucket = quota.buckets.first { quotaBucket(bucket) }
                HStack(spacing: 18) {
                    if let credits = quota.rateLimits.credits {
                        Label("积分 \(credits.display)", systemImage: "circle.hexagongrid")
                            .help("Codex 返回的 credits 单位，不等同于美元或剩余 Token。")
                    }
                    Spacer(minLength: 0)
                    if let count = quota.rateLimitResetCredits?.availableCount {
                        Text("可重置 \(count) 次")
                    }
                }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 3)
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
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if store.quotaStale || store.quotaError != nil || !store.connected {
                    notice("上次快照 · " + (store.quotaError ?? "等待重新同步，额度可能已变化。"))
                }
            } else {
                emptyState("等待额度数据", detail: store.quotaError ?? store.connectionMessage, icon: "arrow.triangle.2.circlepath")
            }
            HStack(spacing: 4) {
                Circle().fill(store.quotaStale || store.quotaError != nil ? .orange : pulse).frame(width: 4, height: 4)
                Text("\(DisplayFormat.age(store.quotaUpdated, now: store.now))同步 · 每 60 秒更新")
            }.font(.system(size: 9)).foregroundStyle(.secondary)
        }.padding(16).pulseCard(accent: true)
    }

    private func quotaBucket(_ bucket: QuotaBucket) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let window = bucket.primary { quotaWindow(window) }
            if let window = bucket.secondary { quotaWindow(window) }
            if bucket.primary == nil && bucket.secondary == nil { Text("此额度未提供百分比").font(.caption).foregroundStyle(.secondary) }
            if bucket.spendControlReached == true || bucket.rateLimitReachedType != nil { notice("此额度已达到服务端限制") }
        }
    }

    private func quotaWindow(_ window: QuotaWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.label).font(.system(size: 12))
                Spacer()
                Text("\(Int(window.remaining))%").font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("剩余").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Capsule().fill(.primary.opacity(0.07)).overlay(alignment: .leading) {
                    Capsule().fill(window.remaining <= 10 ? Color.red : (window.remaining <= 25 ? .orange : pulse))
                        .frame(width: geometry.size.width * window.remaining / 100)
                }
            }.frame(height: 6).accessibilityLabel("\(window.label)，剩余百分之\(Int(window.remaining))")
            if let reset = window.resetsAt {
                let date = Date(timeIntervalSince1970: reset)
                Text(date > store.now ? "\(date.formatted(.dateTime.month().day().hour().minute())) 重置 · \(resetCountdown(date))" : "重置时间已过，等待服务端更新")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private func resetCountdown(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSince(store.now) / 60))
        if minutes >= 1440 { return "还有 \(minutes / 1440) 天 \((minutes % 1440) / 60) 小时" }
        if minutes >= 60 { return "还有 \(minutes / 60) 小时 \(minutes % 60) 分钟" }
        return "还有 \(max(1, minutes)) 分钟"
    }

    /// DeepSeek has no public usage endpoint, so the page shows the local log ledger; Codex keeps
    /// its server-side account usage and gains the same local ledger next to it.
    @ViewBuilder private var usagePage: some View {
        if store.isDeepSeek {
            sectionTitle("DeepSeek 用量", detail: "本机日志 · 每 2 秒")
            localUsageDetail(accent: true)
            if let error = store.balanceError { notice(error) }
            Text("DeepSeek 官方接口提供余额，不提供用量查询。用量取本机 Codex 日志里每次请求的增量 Token，按事件时间归入本机时区的日期；网页端或其他设备的调用不在其中。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else {
            serverUsagePage
            sectionTitle("本机 Token 用量", detail: "每 2 秒 · 增量读取")
            localUsageDetail(accent: false)
            Text("服务端统计与本机日志是两种口径：服务端按账号范围统计，本机日志只覆盖这台机器记录的请求。两者不一致时以服务端为准。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func localUsageDetail(accent: Bool) -> some View {
        if let usage = store.localUsage, usage.hasData {
            VStack(alignment: .leading, spacing: 8) {
                Label("近 \(usage.windowDays) 天 Token", systemImage: "chart.bar.xaxis")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text(DisplayFormat.tokens(usage.totalTokens))
                    .font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(usage.totalTokens.formatted() + " Token · 读取 \(usage.filesRead) 份日志")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).pulseCard(accent: accent)
            HStack(spacing: 12) {
                usageMetric("今日", value: DisplayFormat.tokens(usage.today?.totalTokens))
                usageMetric("单日峰值", value: DisplayFormat.tokens(usage.days.map(\.totalTokens).max()))
            }
            let inputTokens = usage.days.reduce(Int64(0)) { $0 + $1.inputTokens }
            let cachedTokens = usage.days.reduce(Int64(0)) { $0 + $1.cachedInputTokens }
            let outputTokens = usage.days.reduce(Int64(0)) { $0 + $1.outputTokens }
            HStack(spacing: 12) {
                usageMetric("输入", value: DisplayFormat.tokens(inputTokens))
                usageMetric("缓存命中", value: DisplayFormat.tokens(cachedTokens))
                usageMetric("输出", value: DisplayFormat.tokens(outputTokens))
            }
            if !usage.recentDays.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("最近使用", detail: "最近 \(usage.recentDays.count) 个有记录的日期")
                    usageBars(usage)
                }.padding(16).pulseCard()
            }
            if !usage.models.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("按模型", detail: "近 \(usage.windowDays) 天")
                    ForEach(usage.models) { model in
                        HStack {
                            Text(model.model).lineLimit(1)
                            Spacer()
                            Text(DisplayFormat.tokens(model.tokens) + " Token").monospacedDigit().foregroundStyle(.secondary)
                        }.font(.system(size: 11))
                    }
                }.padding(16).pulseCard()
            }
            if usage.truncatedFiles > 0 || usage.unreadableFiles > 0 {
                notice("\(usage.truncatedFiles) 份日志只读取了尾部、\(usage.unreadableFiles) 份不可读；这些文件里更早的轮次未计入。")
            }
        } else {
            emptyState("等待本机用量数据", detail: store.localError ?? "正在读取本机 Codex 日志…", icon: "chart.bar")
        }
    }

    @ViewBuilder private var serverUsagePage: some View {
        sectionTitle("账号使用趋势", detail: "每 5 分钟同步")
        if let usage = store.usage {
            VStack(alignment: .leading, spacing: 8) {
                Label("累计 Token", systemImage: "chart.bar.xaxis").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(DisplayFormat.tokens(usage.summary.lifetimeTokens)).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
                if let tokens = usage.summary.lifetimeTokens { Text(tokens.formatted() + " Token").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(18).pulseCard(accent: true)
            HStack(spacing: 12) {
                usageMetric("连续使用", value: usage.summary.currentStreakDays.map { "\($0) 天" } ?? "—")
                usageMetric("单日峰值", value: DisplayFormat.tokens(usage.summary.peakDailyTokens))
            }
            if !usage.recentDays.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    sectionTitle("最近使用", detail: "最近 7 个有记录的日期")
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(usage.recentDays) { day in
                            VStack(spacing: 7) {
                                Text(DisplayFormat.tokens(day.tokens)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(day.id == usage.recentDays.last?.id ? pulse : pulse.opacity(0.3))
                                    .frame(height: max(3, 100 * Double(day.tokens) / Double(max(1, usage.recentDays.map(\.tokens).max() ?? 1))))
                                Text(String(day.startDate.suffix(5))).font(.system(size: 9)).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity)
                                .help("\(day.startDate)：\(day.tokens.formatted()) Token")
                                .accessibilityLabel("\(day.startDate)，\(day.tokens) Token")
                        }
                    }.frame(height: 136, alignment: .bottom)
                    if let last = usage.recentDays.last {
                        Divider()
                        HStack {
                            Text("最近统计 · \(last.startDate)").foregroundStyle(.secondary)
                            Spacer(); Text(DisplayFormat.tokens(last.tokens) + " Token").monospacedDigit()
                        }.font(.system(size: 11))
                    }
                }.padding(16).pulseCard()
            }
            if let error = store.usageError { notice(error) }
            Text("更新于 \(DisplayFormat.age(store.usageUpdated, now: store.now))。日期与统计范围以服务端返回为准；Token、积分和额度分别计量。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } else { emptyState("等待用量数据", detail: store.usageError ?? "正在读取账号使用统计…", icon: "chart.bar") }
    }

    private func usageMetric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).pulseCard()
    }

    @ViewBuilder private var taskList: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索任务、项目或模型", text: $store.searchText).textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button { store.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("清空搜索")
                }
            }.font(.system(size: 12)).padding(11).pulseCard()
            HStack {
                Picker("状态", selection: $store.taskFilter) {
                    ForEach(["全部", "执行中", "待确认", "已完成", "已中断", "未知"], id: \.self) { Text($0) }
                }.frame(maxWidth: .infinity)
                Picker("排序", selection: $store.sessionSort) {
                    ForEach(SessionSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: .infinity)
            }.font(.system(size: 11))
        }
        if let error = store.localError { notice(error) }
        let filtered = store.filteredSessions
        sectionTitle("\(filtered.count) 个任务", detail: "点击任务展开详情")
        if filtered.isEmpty { emptyState("没有符合条件的任务", detail: "试试其他关键词或状态筛选。", icon: "magnifyingglass") }
        ForEach(filtered) { session in
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        store.expandedSessionID = store.expandedSessionID == session.id ? nil : session.id
                    }
                } label: { sessionRow(session) }.buttonStyle(.plain)
                if store.expandedSessionID == session.id {
                    Divider()
                    HStack {
                        Text(session.model.isEmpty ? "模型未记录" : session.model).lineLimit(1)
                        Spacer()
                        Text("本轮 \(DisplayFormat.tokens(session.turnTokens)) Token")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                    HStack {
                        Text("累计 \(DisplayFormat.tokens(session.totalTokens)) Token")
                        Spacer()
                        if let context = session.contextPercent { Text("上下文约 \(Int(context))%") }
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(store.projectDirectory(for: session.cwd))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled).help(store.projectDirectory(for: session.cwd))
                    HStack {
                        Button { store.openProjectInFinder(session.cwd) } label: { Label("在 Finder 中打开", systemImage: "folder") }
                            .disabled(store.openingProject)
                        Spacer()
                        Button { copyID(session.id) } label: { Label("复制会话 ID", systemImage: "doc.on.doc") }
                    }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(pulse)
                }
            }.padding(13).pulseCard()
        }
        Text("本机最近 60 个未归档会话。执行中表示最近 2 分钟观察到活动；无新事件转为待确认。完成和中断以日志事件为准。")
            .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func sessionRow(_ session: SessionInfo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: stateIcon(session.state)).font(.system(size: 12))
                .foregroundStyle(stateColor(session.state)).frame(width: 27, height: 27)
                .background(stateColor(session.state).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 5)
                    Text(session.state.label).font(.system(size: 9)).foregroundStyle(stateColor(session.state))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(stateColor(session.state).opacity(0.08), in: Capsule()).fixedSize()
                }
                Text(session.activity).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text(session.project).lineLimit(1)
                    Spacer()
                    Text(DisplayFormat.age(session.lastEventAt, now: store.now))
                }.font(.system(size: 9)).foregroundStyle(.secondary.opacity(0.75))
            }
        }.contentShape(Rectangle()).contextMenu {
            Button("在 Finder 中打开") { store.openProjectInFinder(session.cwd) }.disabled(store.openingProject)
            Button("更改项目目录…") { store.chooseProjectDirectory(session.cwd) }.disabled(store.openingProject)
            Button("复制会话 ID") { copyID(session.id) }
        }
    }

    private func copyID(_ id: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(id, forType: .string)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("监测账户", detail: "\(store.accounts.count) 个 · 点按即切换")
            VStack(spacing: 8) {
                ForEach(store.accounts) { account in
                    accountRow(account)
                }
            }
            HStack(spacing: 10) {
                Button { store.beginAddAccount() } label: { Label("添加账户", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(store.isDemo)
                Button { store.refreshAllAccounts() } label: { Label("刷新全部", systemImage: "arrow.clockwise") }
                    .disabled(store.isDemo)
                Spacer(minLength: 0)
            }.font(.system(size: 11))
            if store.showAccountEditor { accountEditor }
            if let status = store.accountStatus { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
            if let error = store.settingsError { notice(error) }
            sectionTitle("外观与显示", detail: nil)
            VStack(alignment: .leading, spacing: 15) {
                Picker("界面主题", selection: $store.theme) {
                    ForEach(["跟随系统", "浅色", "深色"], id: \.self) { Text($0) }
                }.font(.system(size: 12))
                Toggle("状态栏仅显示图标", isOn: $store.compactStatus).font(.system(size: 12))
                Toggle("登录时启动", isOn: Binding(get: { store.loginEnabled }, set: { store.toggleLogin($0) }))
                    .font(.system(size: 12)).disabled(store.isDemo)
            }.padding(16).pulseCard()
            Text("点击面板外部、切换应用或按 Esc 即可收起。刷新快捷键为 ⌘R。")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            sectionTitle("刷新节奏", detail: "选中账户在前台按快节奏，后台账户只读余额")
            VStack(alignment: .leading, spacing: 10) {
                settingsRow("任务日志", "每 2 秒 · 增量读取")
                settingsRow("本机 Token 用量", "每 2 秒 · 增量读取")
                settingsRow("Codex 额度", "每 60 秒 · app-server")
                settingsRow("Codex 账号用量", "每 5 分钟 · app-server")
                settingsRow("DeepSeek 余额", "每 30 秒 · 任务完成后立即刷新")
                settingsRow("后台 DeepSeek 账户", "每 10 分钟 · 仅余额")
                settingsRow("本地读取", DisplayFormat.age(store.localUpdated, now: store.now))
            }.padding(16).pulseCard()
            Text("数据仅在本机展示。Pulse 不发起模型任务，也不消费额度重置次数。DeepSeek 余额请求只在该账户的内存里使用你的凭据：优先 macOS 钥匙串中保存的 Key，其次该账户 config.toml 里的 provider bearer token 或 env_key；不读取 auth.json，不写入日志，界面与诊断输出都不包含密钥。")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("Codex Pulse 0.3.0").foregroundStyle(.secondary)
                Spacer()
                Link("接口说明 ↗", destination: URL(string: "https://learn.chatgpt.com/docs/app-server")!)
            }.font(.system(size: 10))
        }
    }

    private func accountRow(_ account: AccountConfig) -> some View {
        let isSelected = account.id == store.selectedID
        return VStack(alignment: .leading, spacing: 8) {
            Button { store.selectAccount(account.id) } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: account.kind.symbol).font(.system(size: 12))
                        .foregroundStyle(account.kind == .deepseek ? .orange : pulse)
                        .frame(width: 26, height: 26)
                        .background((account.kind == .deepseek ? Color.orange : pulse).opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(account.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(account.kind.label).font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundStyle(account.kind == .deepseek ? .orange : pulse)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background((account.kind == .deepseek ? Color.orange : pulse).opacity(0.1), in: Capsule())
                            if isSelected {
                                Text("当前").font(.system(size: 8)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 2).background(.primary.opacity(0.07), in: Capsule())
                            }
                        }
                        Text(store.accountSummary(account)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        Text(account.expandedHome.path).font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 12) {
                Button(isSelected ? "已选中" : "切换到此账户") { store.selectAccount(account.id) }
                    .disabled(isSelected)
                Button("编辑…") { store.beginEditAccount(account) }.disabled(store.isDemo)
                if account.kind == .deepseek, account.hasStoredKey {
                    Button("清除本机 Key") { store.clearStoredKey(for: account.id) }.disabled(store.isDemo)
                }
                Spacer(minLength: 0)
                Button("删除") { store.deleteAccount(account.id) }
                    .disabled(store.isDemo || store.accounts.count <= 1)
            }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(pulse)
        }.padding(12).pulseCard()
    }

    private var accountEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(store.editingID == nil ? "添加账户" : "编辑账户", detail: nil)
            TextField("显示名称", text: $store.draftName).textFieldStyle(.roundedBorder)
            Picker("类型", selection: $store.draftKind) {
                ForEach(AccountKind.allCases, id: \.self) { kind in Text("\(kind.label) · \(kind.detail)").tag(kind) }
            }.font(.system(size: 11))
            Text("Codex 登录与 DeepSeek 提供商凭据都放在数据目录里；同一个目录可以按需要分别添加成两种类型。")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Codex 数据目录").font(.system(size: 11, weight: .medium))
            HStack {
                TextField("~/.codex", text: $store.draftHome).textFieldStyle(.roundedBorder)
                Button("选择…") { store.chooseAccountHome() }
            }
            Text("Codex CLI 路径").font(.system(size: 11, weight: .medium))
            HStack {
                TextField("自动检测", text: $store.draftCLI).textFieldStyle(.roundedBorder)
                Button("选择…") { store.chooseCLI() }
            }
            if store.draftKind == .deepseek {
                Text("余额接口").font(.system(size: 11, weight: .medium))
                TextField(ProviderConfig.defaultBaseURL, text: $store.draftBaseURL).textFieldStyle(.roundedBorder)
                TextField(ProviderConfig.defaultBalancePath, text: $store.draftBalancePath).textFieldStyle(.roundedBorder)
                Text("API Key（可选）").font(.system(size: 11, weight: .medium))
                SecureField(store.draftHasStoredKey ? "已保存在钥匙串，留空则继续使用" : "留空则读取 config.toml / 环境变量", text: $store.draftKey)
                    .textFieldStyle(.roundedBorder)
                Text("留空时不写入任何内容；填写后保存在 macOS 钥匙串，界面与诊断输出都不会显示它。")
                    .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let note = store.draftNote {
                Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("保存") { store.saveDraftAccount() }.buttonStyle(.borderedProminent).disabled(store.isDemo)
                Button("取消") { store.cancelAccountEditor() }
                Spacer(minLength: 0)
            }.font(.system(size: 11))
        }.padding(16).pulseCard(accent: true)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button { store.refresh() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text(store.refreshing ? "更新中…" : "刷新")
                }
            }.keyboardShortcut("r", modifiers: .command).disabled(store.refreshing).help("立即刷新 · ⌘R")
            Button("打开 Codex ↗") { openCodex() }
            Spacer()
            Text("Esc 收起").font(.system(size: 9)).foregroundStyle(.tertiary)
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.help("退出 Codex Pulse")
        }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 20).padding(.vertical, 13)
            .background(.primary.opacity(0.025)).overlay(alignment: .top) { Divider() }
    }

    private func openCodex() {
        for id in ["com.openai.codex", "com.openai.chat"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()); return
            }
        }
        store.settingsError = "未找到 Codex 桌面应用。"; store.selectedTab = 3
    }
    private func settingsRow(_ title: String, _ detail: String) -> some View {
        HStack { Text(title); Spacer(); Text(detail).foregroundStyle(.secondary) }.font(.system(size: 11))
    }
    private func sectionTitle(_ text: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(text).font(.system(size: 13, weight: .semibold))
            if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
    }
    private func emptyState(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .medium))
            Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
    }
    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func stateColor(_ state: TaskState) -> Color {
        switch state { case .running: return pulse; case .quiet: return .orange; case .completed: return .secondary; case .interrupted: return .red; case .unknown: return .secondary }
    }
    private func stateIcon(_ state: TaskState) -> String {
        switch state { case .running: return "bolt.fill"; case .quiet: return "clock"; case .completed: return "checkmark.circle"; case .interrupted: return "stop.circle"; case .unknown: return "questionmark.circle" }
    }
}

private extension View {
    func pulseCard(accent: Bool = false) -> some View {
        self.background {
            RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    if accent { RoundedRectangle(cornerRadius: 14).fill(LinearGradient(colors: [pulse.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)) }
                }
        }.overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.055), lineWidth: 1) }
    }
}
