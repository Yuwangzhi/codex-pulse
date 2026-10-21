import SwiftUI
import CodexPulseCore

private let relayAccent = Color(red: 0.78, green: 0.43, blue: 0.25)
private func speed(_ value: Double?) -> String { value.map { String(format: "%.1f t/s", $0) } ?? "—" }
private func seconds(_ value: Double?) -> String { value.map { String(format: "%.2f s", $0 / 1000) } ?? "—" }
private func dollars(_ value: Double) -> String { String(format: "$%.4f", value) }
private func tokens(_ value: Int64) -> String { DisplayFormat.tokens(value) }

struct RelaySummaryView: View {
    @ObservedObject var monitor: RelayMonitor
    var open: () -> Void
    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("Claude Code · 中转", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(relayAccent)
                    Spacer()
                    Text("查看详情 →").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if let error = monitor.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.secondary)
                } else if monitor.snapshot != nil {
                    HStack {
                        summaryValue("今日请求", "\(monitor.todayTotals.requests)")
                        Spacer()
                        summaryValue("今日 Token", tokens(monitor.todayTotals.tokens))
                        Spacer()
                        summaryValue("费用估算", dollars(monitor.todayTotals.cost))
                    }
                    Text("独立持续监测 · CC Switch 代理记录 · 每 6 秒刷新")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                } else { Text("正在读取 CC Switch…").font(.system(size: 11)).foregroundStyle(.secondary) }
            }.padding(15).background(relayAccent.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(relayAccent.opacity(0.18)))
        }.buttonStyle(.plain)
    }
    private func summaryValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

struct RelayDetailView: View {
    @ObservedObject var monitor: RelayMonitor
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Claude Code / 中转").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button { monitor.refresh(); monitor.refreshBalances(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新中转统计与额度")
            }
            Picker("统计时段", selection: $monitor.days) {
                Text("今日").tag(1); Text("7 天").tag(7); Text("30 天").tag(30)
            }.pickerStyle(.segmented)
            Picker("提供商", selection: $monitor.providerID) {
                Text("全部提供商").tag("")
                ForEach(monitor.providers) { provider in Text(provider.name).tag(provider.id) }
            }.font(.system(size: 11))
            if let error = monitor.error { caption(error, color: .orange) }
            if let snapshot = monitor.snapshot {
                Text("\(DisplayFormat.age(snapshot.generatedAt, now: Date()))同步 · 本机保留的代理记录")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                totalsCard
                providerCards
                modelCards
                requestCards
                caption("统计仅含经 CC Switch 代理的 Claude Code 请求，按本机自然日归集。Codex 的日志与额度在其他页面独立统计，Claude Desktop 不混入。")
                caption("此时段另有 \(snapshot.importedRequests) 条导入的会话记录；可能与代理记录重叠，未合并进上述合计。CC Switch 已清理的历史请求无法回补。")
                caption("费用是 CC Switch 按价格表和倍率计算的 USD 估算，实际扣费以中转为准。请求吞吐 = 输出 Token ÷ 整次耗时（含等待、思考及网络）；首字延迟为代理记录值。首字后吞吐 = 输出 Token ÷（总耗时 − 首字延迟），仅统计区间 ≥250 ms 的流式请求。上游缓冲与思考 Token 会影响数值，不代表纯生成速度。")
            } else if monitor.error == nil { ProgressView("读取中…").frame(maxWidth: .infinity) }
        }
    }
    private var totalsCard: some View {
        let t = monitor.totals
        return VStack(alignment: .leading, spacing: 10) {
            HStack { stat("请求", "\(t.requests)"); Spacer(); stat("成功 / 失败", "\(t.successes) / \(t.requests - t.successes)"); Spacer(); stat("费用估算", dollars(t.cost)) }
            Divider()
            HStack { stat("输入", tokens(t.input)); Spacer(); stat("输出", tokens(t.output)); Spacer(); stat("Token 合计", tokens(t.tokens)) }
            HStack { stat("缓存读取", tokens(t.cacheRead)); Spacer(); stat("缓存写入", tokens(t.cacheWrite)); Spacer(); stat("请求吞吐", speed(t.throughput)) }
            Divider()
            HStack { stat("平均首字延迟", seconds(t.firstTokenMS)); Spacer(); stat("首字后吞吐", speed(t.generationSpeed)) }
            if t.generationSpeed == nil { caption("缺少首字计时或首字后区间不足 250 ms，保持未知。") }
        }.padding(15).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
    }
    private var providerCards: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("中转额度与消耗").font(.system(size: 12, weight: .semibold))
            ForEach(monitor.providers.filter { p in (monitor.providerID.isEmpty || p.id == monitor.providerID) && (p.current || !p.baseURL.isEmpty || (monitor.snapshot?.requests.contains { $0.providerID == p.id } ?? false)) }) { provider in
                let state = monitor.balances[provider.id]
                let t = RelayTotals((monitor.snapshot?.requests ?? []).filter { $0.providerID == provider.id })
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top) {
                        Text(provider.name).font(.system(size: 11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 3)
                        if provider.current { Text("当前").font(.system(size: 9, weight: .medium)).foregroundStyle(relayAccent) }
                    }
                    Text("\(t.requests) 次 · \(tokens(t.tokens)) Token · 估算 \(dollars(t.cost))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if !monitor.balanceEnabled { caption("额度查询已关闭") }
                    else if let q = state?.quota, let state {
                        if let remaining = q.accountRemaining {
                            HStack { stat("账户余额", state.amount(remaining)); Spacer(); stat("此 Key 累计消耗", state.amount(q.used)) }
                        } else if !q.unlimited {
                            HStack { stat("此 Key 剩余额度", state.amount(q.remaining)); Spacer(); stat("此 Key 累计消耗", state.amount(q.used)) }
                        } else {
                            stat("此 Key 累计消耗", state.amount(q.used))
                            caption("此 Key 不单独限额；接口未返回账户余额。")
                        }
                        if q.unlimited && q.accountRemaining != nil { caption("此 Key 不单独限额，仍受账户余额约束。") }
                        if let expires = q.expires { caption("Key 到期：\(expires.formatted(.dateTime.year().month().day().hour().minute()))") }
                        if let updated = state.updated {
                            let stale = Date().timeIntervalSince(updated) > 180
                            caption("\(stale ? "上次记录 · " : "服务端额度 · ")\(DisplayFormat.age(updated, now: Date()))同步", color: stale ? .orange : .secondary)
                        }
                        caption("同站不同 Key 的账户余额可能相同，不可相加。")
                    } else { caption(state?.error ?? (provider.baseURL.isEmpty ? "历史记录，无可用额度查询配置" : "等待额度查询…")) }
                }.padding(13).background(relayAccent.opacity(0.065), in: RoundedRectangle(cornerRadius: 11))
            }
        }
    }
    private var modelCards: some View {
        let groups = Dictionary(grouping: monitor.requests, by: \.model)
        let models = groups.keys.sorted { RelayTotals(groups[$0] ?? []).cost > RelayTotals(groups[$1] ?? []).cost }
        return VStack(alignment: .leading, spacing: 8) {
            Text("按模型").font(.system(size: 12, weight: .semibold))
            if models.isEmpty { caption("此时段没有代理请求。") }
            ForEach(models, id: \.self) { model in
                let t = RelayTotals(groups[model] ?? [])
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model).font(.system(size: 11, weight: .medium)).lineLimit(2)
                        Text("\(t.requests) 次 · 输出 \(tokens(t.output)) · \(speed(t.throughput)) 请求吞吐").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(dollars(t.cost)).font(.system(size: 11, design: .monospaced))
                }.padding(11).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private var requestCards: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近请求 · 最多 12 条").font(.system(size: 12, weight: .semibold))
            ForEach(Array(monitor.requests.prefix(12))) { r in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(r.model).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("\(r.status)").foregroundStyle(r.successful ? Color.secondary : Color.orange)
                        Text(r.date.formatted(.dateTime.hour().minute().second()))
                    }.font(.system(size: 10))
                    Text(monitor.name(r.providerID)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    Text("输出 \(tokens(r.output)) · 总耗时 \(seconds(r.latencyMS)) · 首字 \(seconds(r.firstTokenMS))")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    Text("请求吞吐 \(speed(r.throughput)) · 估算 \(dollars(r.cost))")
                        .font(.system(size: 10, design: .monospaced))
                }.padding(11).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 14, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
    }
    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(color).fixedSize(horizontal: false, vertical: true)
    }
}
