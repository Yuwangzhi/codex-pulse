import Foundation

/// Three comparable labels, while retaining the actual unit and source of each reading.
/// A relay key without its own limit is not an unlimited account balance.
public struct QuotaMenuValue: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var value: String
    public var detail: String
    public var updatedAt: Date?
    public var stale = false
    public var menuText: String { "\(title) \(value)" + (stale && value != "—" ? "*" : "") }

    public static func gpt(bucket: QuotaBucket?, updatedAt: Date?, connected: Bool, hasError: Bool,
                           accountName: String, now: Date) -> Self {
        var result = Self(id: "gpt", title: "GPT", value: "—", detail: "GPT / Codex 额度尚未读取")
        guard let bucket, let updatedAt,
              let window = [bucket.primary, bucket.secondary].compactMap({ $0 }).min(by: { $0.remaining < $1.remaining }) else { return result }
        result.value = "\(Int(window.remaining))%"
        result.detail = "\(accountName) · \(window.label)，取限制最紧的窗口"
        if let reset = window.resetsAt { result.detail += "\n\(Date(timeIntervalSince1970: reset).formatted(date: .abbreviated, time: .shortened))重置" }
        result.updatedAt = updatedAt
        result.stale = !connected || hasError || now.timeIntervalSince(updatedAt) > 120
        return result
    }

    public static func grok(snapshot: GrokBotSnapshot?, now: Date) -> Self {
        var result = Self(id: "grok", title: "Grok", value: "—", detail: "等待 Grok Bot 当前账户的额度缓存")
        guard let snapshot, snapshot.signedIn, let quota = snapshot.quota else { return result }
        result.value = "\(Int(quota.remainingPercent))%"
        result.detail = quota.source == .server ? "Grok Bot · 服务端额度 · 每 60 秒查询" : "Grok Bot · 客户端额度缓存"
        if let reset = quota.resetAt { result.detail += "\n\(reset.formatted(date: .abbreviated, time: .shortened))重置" }
        result.updatedAt = quota.readAt
        result.stale = quota.isStale(now: now)
        return result
    }

    public static func claude(provider: RelayProvider?, quota: RelayQuota?, unitsPerDollar: Double?,
                              currency: String?, exchangeRate: Double = 1, updatedAt: Date?,
                              hasError: Bool, now: Date) -> Self {
        var result = Self(id: "claude", title: "Claude", value: "—", detail: "尚未读取当前 Claude 中转提供商")
        guard let provider else { return result }
        result.detail = "\(provider.name) · 正在查询中转额度"
        guard let quota else {
            if hasError { result.detail = "\(provider.name) · 当前中转额度查询不可用" }
            return result
        }
        // Never choose a different provider or add balances of several keys/accounts together.
        let raw: Double
        let keyOnly: Bool
        if let amount = quota.accountRemaining, amount.isFinite { raw = amount; keyOnly = false }
        else if !quota.unlimited, let amount = quota.remaining, amount.isFinite { raw = amount; keyOnly = true }
        else {
            result.detail = "\(provider.name) · 接口未返回账户余额" + (quota.unlimited ? "；Key 未单独限额" : "")
            return result
        }
        if let units = unitsPerDollar, units.isFinite, units > 0,
           let currency, ["USD", "CNY"].contains(currency), exchangeRate.isFinite, exchangeRate > 0 {
            result.value = DisplayFormat.money(raw / units * exchangeRate, currency: currency)
        } else { result.value = String(format: "%.0f", raw) + "单位" }
        if keyOnly { result.value = "Key " + result.value }
        result.detail = "\(provider.name) · " + (keyOnly ? "当前 Key 剩余额度" : "中转账户余额")
        result.updatedAt = updatedAt
        result.stale = hasError || (updatedAt.map { now.timeIntervalSince($0) > 180 } ?? true)
        if keyOnly, let expires = quota.expires, expires <= now { result.stale = true; result.detail += " · Key 已到期" }
        return result
    }
}
