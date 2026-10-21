import SwiftUI
import CodexPulseCore

struct QuotaOverviewView: View {
    @ObservedObject var store: MonitorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("剩余额度").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).help("刷新三家额度；Grok 读取客户端最新缓存")
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
            Text("* 上次记录 / 旧缓存　— 来源未提供")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
        }.padding(15).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
    }
}
