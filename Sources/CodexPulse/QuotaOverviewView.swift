import SwiftUI
import CodexPulseCore

struct QuotaOverviewView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("额度与用量").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新 GPT、Grok 剩余和 Claude 官方已用额度")
                    .accessibilityLabel("刷新三家额度")
            }
            ForEach(store.quotaMenu) { item in
                HStack(alignment: .top, spacing: 12) {
                    Text(item.title).font(.system(size: 12, weight: .semibold)).frame(width: 45, alignment: .leading)
                        .padding(.top, 3)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.value + (item.stale && item.value != "—" ? "*" : ""))
                            .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(item.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let updated = item.updatedAt {
                            Text((item.stale ? "上次记录 · " : "") + DisplayFormat.age(updated, now: store.now) + "读取")
                                .font(.system(size: 9)).foregroundStyle(item.stale ? Color.orange : Color.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityElement(children: .combine)
            }
            HStack(alignment: .top, spacing: 12) {
                Text("Claude").font(.system(size: 12, weight: .semibold))
                    .frame(width: 45, alignment: .leading).padding(.top, 3)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 24) {
                        claudeWindow("5 小时剩余", value: store.statusLayout.right[0], window: store.claude.snapshot?.fiveHour)
                        claudeWindow("每周剩余", value: store.statusLayout.right[1], window: store.claude.snapshot?.sevenDay)
                    }
                    Text(store.claude.detail).font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let updated = store.claude.snapshot?.readAt {
                        Text((store.claude.isStale(now: store.now) ? "上次记录 · " : "") + DisplayFormat.age(updated, now: store.now) + "读取")
                            .font(.system(size: 9)).foregroundStyle(store.claude.isStale(now: store.now) ? Color.orange : Color.secondary)
                    }
                    if store.claude.error == .authorization {
                        Button("授权并刷新 Claude") { store.claude.refresh(force: true, allowInteraction: true) }
                            .font(.system(size: 11)).disabled(store.isDemo || store.claude.busy)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .combine)
            if let error = store.agents.grokQuotaError {
                Button("授权并刷新 Grok") {
                    store.agents.refreshGrokQuota(force: true, allowInteraction: true)
                }.font(.system(size: 11)).disabled(store.isDemo || store.agents.grokQuotaBusy)
                    .help(error)
            }
            Text("* 上次记录 / 旧缓存　— 来源未提供")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(15).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
    private func claudeWindow(_ title: String, value: String, window: ClaudeUsageWindow?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .frame(minHeight: 24)
            if !value.isEmpty, let reset = window?.resetsAt {
                Text(reset.formatted(date: .abbreviated, time: .shortened) + "重置")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
    }
}
